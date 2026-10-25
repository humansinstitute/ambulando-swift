import Foundation

/// Canvas and naplet editing through the Tower routes the web canvas uses (sol `canvas/sync-service.js`, `manager.js`;
/// Tower `routes/flightdeck-pg.ts`):
///
/// - `POST /canvases` (create; title ≤ 200, workspace visibility as the web's default)
/// - `PATCH /canvases/:c` (rename; `expected_row_version`, `can_manage`)
/// - `POST /canvases/:c/naplets` (add; Tower authorizes the source for this viewer)
/// - `PATCH /canvases/:c/naplets/:n` (move/resize: the whole saved layout with `expected_row_version`)
/// - `DELETE /canvases/:c/naplets/:n` (remove; `expected_row_version`)
///
/// Like scope and channel management these are confirmed online requests: the user sees the result or the reason it
/// failed, and nothing is queued for a later replay (Tower's create routes carry no idempotency key). After each
/// accepted write the snapshot (or list) is read again and stored, as sol `refreshProjection` does, and a keyed refresh
/// is queued behind any read already in flight so an older answer cannot stay on screen. A stale version is never
/// retried with a newer one: the board is re-read and the user decides again.
///
/// Drawing elements (`/elements`) and Excalidraw board contents are not edited here.
public struct CanvasEditor: Sendable {
    let sync: WorkspaceSync

    public init(sync: WorkspaceSync) { self.sync = sync }

    /// Tower's layout bounds for naplets (`normalizeFlightDeckPgCanvasLayout`).
    public static let minSize = (width: 220.0, height: 160.0)
    public static let maxSize = (width: 1200.0, height: 1000.0)
    public static let maxTitle = 200

    /// Naplet source types Tower accepts on `POST /naplets` and this build can offer.
    public enum SourceType: String, Sendable, CaseIterable {
        case document, taskList = "task_list", chatThread = "chat_thread", html, excalidraw, canvas
    }

    /// Clamps a frame to what Tower will store, rounded to whole points.
    public static func clamped(_ layout: CanvasLayout) -> CanvasLayout {
        CanvasLayout(x: layout.x.rounded(), y: layout.y.rounded(),
                     width: min(maxSize.width, max(minSize.width, layout.width.rounded())),
                     height: min(maxSize.height, max(minSize.height, layout.height.rounded())),
                     z: min(100_000, max(1, layout.z)))
    }

    // MARK: Canvases

    /// Creates a canvas visible to the whole workspace and returns it once the list has been read again.
    public func createCanvas(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, title: String) async throws -> CanvasRecord {
        let name = try Self.title(title)
        let object = try await send(connection, workspace, method: "POST", path: try TowerAPI.base(workspace.id) + "/canvases",
                                    body: ["title": name, "visibility": ["mode": "workspace", "actor_ids": [], "group_ids": []]], canvasId: nil)
        guard let row = object["canvas"] as? [String: Any] else { throw CanvasEditError.savedButNotRefreshed("no canvas in Tower's answer") }
        let created = try CanvasRecord(raw: rawJSON(row), workspaceId: workspace.id)
        try await reloadList(connection, workspace)
        return created
    }

    /// Renames a canvas at the version this device last read. Visibility is left as it is.
    public func renameCanvas(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvas: CanvasRecord, title: String) async throws {
        let name = try Self.title(title)
        guard canvas.canManage else { throw CanvasEditError.forbidden }
        _ = try await send(connection, workspace, method: "PATCH", path: try Self.canvasPath(workspace, canvas.id),
                           body: ["title": name, "expected_row_version": canvas.rowVersion], canvasId: canvas.id)
        try await reloadList(connection, workspace)
        try await reloadSnapshotIfStored(connection, workspace, canvasId: canvas.id)
    }

    // MARK: Naplets

    /// Adds a naplet for a source this viewer can read. Tower decides access; a refused source adds nothing.
    public func addNaplet(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, type: SourceType, sourceId: String,
                          title: String? = nil, layout: CanvasLayout) async throws {
        var body: [String: Any] = ["source": ["type": type.rawValue, "id": try TowerAPI.uuid(sourceId)], "layout": Self.layoutObject(Self.clamped(layout), base: [:])]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { body["title"] = try Self.title(title) }
        _ = try await send(connection, workspace, method: "POST", path: try Self.canvasPath(workspace, canvasId) + "/naplets", body: body, canvasId: canvasId)
        try await reloadSnapshot(connection, workspace, canvasId: canvasId)
    }

    /// Moves and/or resizes a naplet. The saved layout is patched, so keys this build does not draw are kept.
    /// Locked naplets keep their frame (as on the web, only their removal is offered).
    public func updateLayout(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, naplet: CanvasNaplet,
                             to layout: CanvasLayout) async throws {
        guard naplet.isReady else { throw CanvasEditError.locked }
        let base = ((try? JSONSerialization.jsonObject(with: naplet.savedLayout)) as? [String: Any]) ?? [:]
        _ = try await send(connection, workspace, method: "PATCH", path: try Self.napletPath(workspace, canvasId, naplet.id),
                           body: ["layout": Self.layoutObject(Self.clamped(layout), base: base), "expected_row_version": naplet.rowVersion], canvasId: canvasId)
        try await reloadSnapshot(connection, workspace, canvasId: canvasId)
    }

    /// Removes a naplet from the board. Its source (document, tasks, file…) is not touched.
    public func removeNaplet(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, naplet: CanvasNaplet) async throws {
        _ = try await send(connection, workspace, method: "DELETE", path: try Self.napletPath(workspace, canvasId, naplet.id),
                           body: ["expected_row_version": naplet.rowVersion], canvasId: canvasId)
        try await reloadSnapshot(connection, workspace, canvasId: canvasId)
    }

    // MARK: Requests

    static func title(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CanvasEditError.invalid("A title is required.") }
        guard name.count <= maxTitle else { throw CanvasEditError.invalid("Titles can be at most \(maxTitle) characters.") }
        return name
    }

    static func layoutObject(_ layout: CanvasLayout, base: [String: Any]) -> [String: Any] {
        var out = base
        out["x"] = Int(layout.x); out["y"] = Int(layout.y); out["width"] = Int(layout.width); out["height"] = Int(layout.height); out["z"] = layout.z
        return out
    }

    private static func canvasPath(_ workspace: WorkspaceRecord, _ canvasId: String) throws -> String {
        try TowerAPI.base(workspace.id) + "/canvases/" + TowerAPI.uuid(canvasId)
    }

    private static func napletPath(_ workspace: WorkspaceRecord, _ canvasId: String, _ napletId: String) throws -> String {
        try canvasPath(workspace, canvasId) + "/naplets/" + TowerAPI.uuid(napletId)
    }

    /// One signed write. A refusal is classified for the screen; a stale version or lost access also brings the stored
    /// board up to date so the user sees what changed.
    private func send(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, method: String, path: String,
                      body: [String: Any], canvasId: String?) async throws -> [String: Any] {
        do { try await sync.identity.requireSigner(npub: connection.signerNpub) } catch { throw CanvasEditError.locked }
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let client = TowerClient(origin: try TowerOrigin(connection.origin), transport: sync.transport, signer: sync.identity)
        let result: (status: Int, body: Data)
        do {
            result = try await client.exchange(method: method, path: path, appNpub: workspace.appNpub, jsonBody: json)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CanvasEditError.offline(error.localizedDescription)
        }
        let object = ((try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any]) ?? [:]
        guard (200..<300).contains(result.status) else {
            let error = CanvasEditError.classify(status: result.status, object: object)
            if let canvasId {
                switch error {
                case .conflict: try? await reloadSnapshot(connection, workspace, canvasId: canvasId)
                case .canvasUnavailable: try? await sync.store.writer.removeCanvas(workspaceId: workspace.id, id: canvasId)
                case .forbidden: await sync.refreshCanvases(connection, workspace, priority: .user, force: true)
                default: break
                }
            }
            throw error
        }
        return object
    }

    private func reloadList(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord) async throws {
        do {
            let canvases = try await sync.api(origin: try TowerOrigin(connection.origin)).canvases(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try await sync.store.writer.replaceCanvases(workspaceId: workspace.id, canvases)
        } catch {
            await sync.refreshCanvases(connection, workspace, priority: .user, force: true)
            throw CanvasEditError.savedButNotRefreshed(error.localizedDescription)
        }
        await sync.refreshCanvases(connection, workspace, priority: .user, force: true)
    }

    private func reloadSnapshot(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String) async throws {
        do {
            let fetched = try await sync.api(origin: try TowerOrigin(connection.origin)).canvasSnapshot(workspaceId: workspace.id, appNpub: workspace.appNpub, canvasId: canvasId)
            try await sync.store.writer.saveCanvasSnapshot(fetched.snapshot, canvas: fetched.canvas)
        } catch {
            await sync.refreshCanvas(connection, workspace, canvasId: canvasId, priority: .user, force: true)
            throw CanvasEditError.savedButNotRefreshed(error.localizedDescription)
        }
        // Queued behind any read that started before this write, so its older answer is replaced.
        await sync.refreshCanvas(connection, workspace, canvasId: canvasId, priority: .user, force: true)
    }

    private func reloadSnapshotIfStored(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String) async throws {
        guard try await sync.store.reader.canvasSnapshot(workspaceId: workspace.id, canvasId: canvasId) != nil else { return }
        try await reloadSnapshot(connection, workspace, canvasId: canvasId)
    }
}

public enum CanvasEditError: LocalizedError, Equatable, Sendable {
    case locked
    case offline(String)
    case forbidden
    /// Someone else changed this canvas or item first (`409 stale_row_version`); the board has been read again.
    case conflict
    /// The canvas is no longer visible to this viewer (`404 canvas_unavailable`); its stored copy was removed.
    case canvasUnavailable
    /// Tower would not let this viewer place the chosen source (`400 canvas_source_unavailable`).
    case sourceUnavailable
    case invalid(String)
    case unexpected(String)
    /// Tower saved the change, but reading it back failed; it shows after the next refresh.
    case savedButNotRefreshed(String)

    public var errorDescription: String? {
        switch self {
        case .locked: "Unlock to edit canvases."
        case .offline(let detail): "Couldn't reach Tower, nothing was changed. \(detail)"
        case .forbidden: "You can view this canvas but not change it."
        case .conflict: "This canvas changed elsewhere, so your change was not saved. The board now shows the latest version; try again."
        case .canvasUnavailable: "This canvas is no longer available to you."
        case .sourceUnavailable: "That item can't be added: it is no longer available to you."
        case .invalid(let message), .unexpected(let message): message
        case .savedButNotRefreshed(let detail): "Saved on Tower, but the board couldn't be refreshed yet (\(detail)). It will update on the next refresh."
        }
    }

    public var retryable: Bool {
        switch self {
        case .offline, .unexpected, .savedButNotRefreshed: true
        default: false
        }
    }

    static func classify(status: Int, object: [String: Any]) -> CanvasEditError {
        let code = (object["code"] as? String) ?? ""
        switch (status, code) {
        case (403, _): return .forbidden
        case (404, "canvas_unavailable"): return .canvasUnavailable
        case (404, _): return .conflict
        case (409, _): return .conflict
        case (400, "canvas_source_unavailable"): return .sourceUnavailable
        case (400, _), (422, _):
            let rows = (object["fields"] as? [[String: Any]]) ?? ((object["details"] as? [String: Any])?["fields"] as? [[String: Any]]) ?? []
            let fields = rows.compactMap { $0["message"] as? String }
            return .invalid(fields.isEmpty ? "Tower refused the change (\(code.isEmpty ? "HTTP \(status)" : code))." : fields.joined(separator: " "))
        default:
            return .unexpected("Tower returned HTTP \(status)\(code.isEmpty ? "" : " (\(code))"). Nothing was changed.")
        }
    }
}

/// Something this viewer has on this device that can be placed on a canvas (sol `loadSourceOptions`). Tower still
/// authorizes the source when it is added.
public struct CanvasSourceChoice: Sendable, Equatable, Identifiable, Hashable {
    public let type: CanvasEditor.SourceType
    public let sourceId: String
    public let title: String
    public var id: String { "\(type.rawValue):\(sourceId)" }
}

extension StoreReader {
    /// Other canvases, documents, channel task lists, conversations, HTML artefacts and Excalidraw board files stored
    /// for the workspace, sorted by title. Archived and deleted records are left out.
    public func canvasSourceChoices(workspaceId: String, excludingCanvas canvasId: String) throws -> [CanvasSourceChoice] {
        var out: [CanvasSourceChoice] = []
        out += try canvases(workspaceId: workspaceId).filter { $0.id != canvasId }.map { .init(type: .canvas, sourceId: $0.id, title: $0.title) }
        out += try docs(workspaceId: workspaceId).map { .init(type: .document, sourceId: $0.id, title: $0.title.isEmpty ? "Untitled document" : $0.title) }
        out += try channels(workspaceId: workspaceId).map { .init(type: .taskList, sourceId: $0.id, title: "\($0.name.isEmpty ? "Channel" : $0.name) tasks") }
        let threads = try db.prepare("""
        SELECT id, COALESCE(NULLIF(title, ''), NULLIF(latest, ''), 'Conversation') FROM threads
        WHERE workspace_id = ? AND archived = 0 AND deleted = 0 ORDER BY updated_at DESC, id LIMIT 300
        """)
        try threads.bind([.text(workspaceId)])
        while try threads.step() { out.append(.init(type: .chatThread, sourceId: threads.text(0)!, title: String(threads.text(1)!.prefix(120)))) }
        for file in try files(workspaceId: workspaceId) {
            let type = (file.contentType ?? "").lowercased(), name = file.displayName.lowercased()
            if type == "application/vnd.excalidraw+json" || name.hasSuffix(".excalidraw") {
                out.append(.init(type: .excalidraw, sourceId: file.id, title: file.displayName.replacingOccurrences(of: ".excalidraw", with: "", options: [.caseInsensitive, .anchored, .backwards])))
            } else if type.contains("html") || name.hasSuffix(".html") || name.hasSuffix(".htm") || name.hasSuffix(".xhtml") {
                out.append(.init(type: .html, sourceId: file.id, title: file.displayName))
            }
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
