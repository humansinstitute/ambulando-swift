import AmbulandoCore
import Foundation
import Observation

/// One Excalidraw board as the screens see it: the shared `BoardController` (drafts, saves, versions; off the main
/// actor) and its latest state for SwiftUI. The inline naplet editor and the full-screen editor of the same board use
/// the same session, so they share one draft.
@MainActor @Observable
final class BoardSession {
    let key: String
    let fileId: String
    @ObservationIgnored let controller: BoardController
    private(set) var state = BoardState()
    var title: String
    /// Canvases showing this board; their snapshots are read again after a save (sol `refreshBoardsSnapshot`), so the
    /// stored projection, and the board on reopen, carry the new version.
    @ObservationIgnored var canvasIds: Set<String> = []
    @ObservationIgnored var afterSave: (Set<String>) -> Void = { _ in }

    init(key: String, fileId: String, title: String, controller: BoardController) {
        self.key = key
        self.fileId = fileId
        self.title = title
        self.controller = controller
    }

    /// States can arrive out of order across actor hops; only a newer one is shown.
    func apply(_ next: BoardState) { if next.revision > state.revision { state = next } }

    /// Snapshot projection of the board (its current version and whether this viewer may write).
    func sync(_ reference: BoardReference, title: String) {
        self.title = title
        let controller = controller
        Task { await controller.sync(reference, title: title) }
    }

    func save(summary: String = "") {
        let c = controller
        Task { if await c.save(summary: summary) { afterSave(canvasIds) } }
    }
    func mergeLatest() { let c = controller; Task { await c.mergeLatest() } }
    func discardAndLoadLatest() { let c = controller; Task { await c.loadLatest(force: true) } }
    func loadVersions() { let c = controller; Task { await c.loadVersions() } }
    func view(_ version: BoardVersion) { let c = controller; Task { await c.viewVersion(version) } }
    func returnToLatest() { let c = controller; Task { await c.returnToLatest() } }
    func restoreViewed() { let c = controller; Task { await c.restoreViewedVersion() } }
    func clearMessages() { let c = controller; Task { await c.clearMessages() } }
    func refreshSigner() { let c = controller; Task { await c.refreshSigner() } }
}

/// Board sessions of the current connection and workspace (bounded; boards no editor shows are dropped first).
@MainActor
final class BoardRegistry {
    private var sessions: [String: BoardSession] = [:]
    private var order: [String] = []
    static let limit = 8

    func session(_ key: String, make: () -> BoardSession) -> BoardSession {
        if let existing = sessions[key] {
            order.removeAll { $0 == key }; order.append(key)
            return existing
        }
        let created = make()
        sessions[key] = created
        order.append(key)
        while order.count > Self.limit, let oldest = order.first {
            order.removeFirst()
            sessions[oldest] = nil   // its draft stays on disk; a later open restores it
        }
        return created
    }

    func removeAll() { sessions = [:]; order = [] }
}

extension AppModel {
    /// The shared session for a board shown on a canvas, bound to the selected workspace and this connection. Nil when
    /// no workspace is open (locked devices still get a read-only session if the identity can read).
    func boardSession(_ reference: BoardReference, title: String, in workspace: WorkspaceRecord, canvasId: String) -> BoardSession? {
        guard let sync, let connection, workspace.id == selectedWorkspace?.id else { return nil }
        let key = [connection.id, workspace.id, reference.fileId].joined(separator: ":")
        guard let transport = try? sync.boardTransport(connection, workspace, fileId: reference.fileId, title: title) else { return nil }
        let session = boards.session(key) {
            let file = reference.fileId, signer = connection.signerNpub
            let drafts = BoardDraftStore(directory: Self.dataDirectory.appendingPathComponent("board-drafts", isDirectory: true)
                .appendingPathComponent(connection.id, isDirectory: true).appendingPathComponent(workspace.id, isDirectory: true))
            let controller = BoardController(fileId: file, title: title, author: signer, transport: transport, drafts: drafts, onState: { _ in })
            let session = BoardSession(key: key, fileId: file, title: title, controller: controller)
            session.afterSave = { [weak self] canvases in for id in canvases { self?.openCanvas(workspace, canvasId: id, force: true) } }
            Task { [weak session] in
                await controller.setOnState { state in Task { @MainActor in session?.apply(state) } }
            }
            return session
        }
        session.canvasIds.insert(canvasId)
        session.sync(reference, title: title)
        return session
    }
}
