import AmbulandoCore
import Foundation

/// What the labelled, sandboxed web view shows: an HTML naplet. WApps and Context Tree artifact pages have HTTPS
/// addresses of their own and open as in-app browser tabs instead (`BrowserModel.launch`).
enum WebContentSource: Hashable, Codable {
    case htmlNaplet(canvasId: String, napletId: String, title: String)
}

/// The viewer's pins with the state of any pin or unpin still waiting in the write queue.
struct PinsSnapshot: Sendable, Equatable {
    var items: [PinnedItem] = []
    /// Latest queued pin write per resource (`type:id`), overlaid on the stored state until Tower acknowledges it.
    var pending: [String: WriteItem] = [:]
    var stored: [String: Bool] = [:]
    var loaded = false

    static func key(_ type: PinRecord.ResourceType, _ id: String) -> String { "\(type.rawValue):\(id)" }

    /// Pinned as the user last asked (a pending write wins over the stored row).
    func isPinned(_ type: PinRecord.ResourceType, _ id: String) -> Bool {
        if let write = pending[Self.key(type, id)], write.isPending, let pinned = write.payloadObject["pinned"] as? Bool { return pinned }
        return stored[Self.key(type, id)] ?? false
    }

    func failure(_ type: PinRecord.ResourceType, _ id: String) -> WriteItem? {
        pending[Self.key(type, id)].flatMap { $0.isPending ? nil : $0 }
    }
}

extension AppModel {
    // MARK: Surfaces (Canvas, Context, Agents, Toolbox)

    func openContextTree(_ workspace: WorkspaceRecord, scopeId: String, force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshContextTree(c, workspace, scopeId: scopeId, force: force) }
    }

    func openContextComponent(_ workspace: WorkspaceRecord, scopeId: String, componentId: String, force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshContextReferences(c, workspace, scopeId: scopeId, componentId: componentId, force: force) }
    }

    func openCanvases(_ workspace: WorkspaceRecord, force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshCanvases(c, workspace, force: force) }
    }

    func openCanvas(_ workspace: WorkspaceRecord, canvasId: String, force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshCanvas(c, workspace, canvasId: canvasId, force: force) }
    }

    /// Runs one confirmed canvas edit (`CanvasEditor`) for the selected workspace. Errors come back classified for the
    /// board; a result for a workspace the user has since left is dropped.
    func editCanvas<T: Sendable>(_ body: @escaping @Sendable (CanvasEditor, ConnectionRecord, WorkspaceRecord) async throws -> T) async -> Result<T, CanvasEditError> {
        guard let sync, let connection, let workspace = selectedWorkspace else { return .failure(.unexpected("No workspace is selected.")) }
        guard isUnlocked else { return .failure(.locked) }
        do {
            let value = try await body(CanvasEditor(sync: sync), connection, workspace)
            guard selectedWorkspace?.id == workspace.id else { return .failure(.unexpected("The workspace changed before Tower answered.")) }
            return .success(value)
        } catch let error as CanvasEditError {
            return .failure(error)
        } catch {
            return .failure(.unexpected(error.localizedDescription))
        }
    }

    /// Agents and the activity of the context's channels (bounded by `WorkspaceSync.agentActivityChannelLimit`).
    func openAgents(_ workspace: WorkspaceRecord, channelIds: [String], force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshAgents(c, workspace, channelIds: channelIds, force: force) }
    }

    /// A board shown on a canvas or opened full screen: requested at user priority (coalesces with a queued job; a stored
    /// current version is not fetched again).
    func openBoard(_ board: BoardReference, in workspace: WorkspaceRecord) {
        withWorkspace(workspace) { sync, c in await sync.refreshBoard(c, workspace, board: board, priority: .user) }
    }

    func openToolbox(_ workspace: WorkspaceRecord, force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshToolbox(c, workspace, force: force) }
    }

    func ensureThread(_ threadId: String, in workspace: WorkspaceRecord) {
        withWorkspace(workspace) { sync, c in await sync.ensureThread(c, workspace, threadId: threadId) }
    }

    /// Opens a conversation by id in Chat. A thread not stored yet is fetched first (bounded wait); one that cannot be read
    /// is reported instead of opening an empty screen.
    func openThreadById(_ threadId: String) {
        guard let store, let workspace = selectedWorkspace else { return }
        Task {
            if (try? await store.reader.thread(workspaceId: workspace.id, id: threadId)) == nil {
                ensureThread(threadId, in: workspace)
                for _ in 0..<50 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if (try? await store.reader.thread(workspaceId: workspace.id, id: threadId)) != nil { break }
                    if syncError(forKey: WorkspaceSync.threadRecordKey(workspace.id, threadId)) != nil { break }
                }
            }
            guard selectedWorkspace?.id == workspace.id else { return }
            if (try? await store.reader.thread(workspaceId: workspace.id, id: threadId)) != nil { openThreadMention(threadId) }
            else { notice = "This conversation is not available on this \(Device.name)." }
        }
    }

    // MARK: Pins

    func observePins(connection: ConnectionRecord, workspaceId: String) {
        guard let store else { return }
        let connectionId = connection.id
        pins.start(store: store, matches: { key in
            key.workspaceId == workspaceId && [.pins, .writes, .tasks, .docs, .threads, .channels, .messages].contains(key.table)
        }) {
            async let items = store.reader.pinnedItems(connectionId: connectionId, workspaceId: workspaceId)
            async let writes = store.reader.writes(connectionId: connectionId, workspaceId: workspaceId)
            var pending: [String: WriteItem] = [:]
            for write in try await writes where write.kind == .pinSet {
                guard let type = write.string("resource_type").flatMap(PinRecord.ResourceType.init(rawValue:)), let id = write.targetId else { continue }
                pending[PinsSnapshot.key(type, id)] = write   // rows are in creation order: the latest wins
            }
            let list = try await items
            return PinsSnapshot(items: list, pending: pending,
                                stored: Dictionary(list.map { (PinsSnapshot.key($0.pin.resourceType, $0.pin.resourceId), true) }, uniquingKeysWith: { a, _ in a }),
                                loaded: true)
        }
        if let workspace = workspaces.value.first(where: { $0.id == workspaceId }), let sync, canRead {
            Task { await sync.refreshPins(connection, workspace, priority: .background) }
        }
    }

    /// Pins or unpins through the durable write queue. The expected row version is the stored pin's (0 if never pinned);
    /// a stale one is resolved by the queue (re-read, then resent or found already done).
    func setPinned(_ pinned: Bool, type: PinRecord.ResourceType, id: String, in workspace: WorkspaceRecord) {
        guard let store, let connection else { return }
        let connectionId = connection.id
        Task {
            let stored = try? await store.reader.pin(connectionId: connectionId, workspaceId: workspace.id, type: type, resourceId: id)
            submit(WriteIntent(kind: .pinSet, targetId: id, payload: ["resource_type": type.rawValue, "pinned": pinned,
                                                                       "expected_row_version": stored?.rowVersion ?? 0,
                                                                       "mutation_id": UUID().uuidString.lowercased()]), in: workspace)
        }
    }
}
