import Foundation

/// Read paths for the Context Tree, Canvas, agents, Toolbox and personal pins. Like every other read, each is a keyed
/// `SyncEngine` job (bounded concurrency, coalescing, cancellation, backoff) whose results land in SQLite; screens only
/// observe the store. Parsing and verification happen inside the job. Nothing here writes to Tower: opening a canvas or
/// a board never changes it.
extension WorkspaceSync {
    public static func contextTreeKey(_ w: String, _ s: String) -> String { "context:\(w):\(s)" }
    public static func contextReferencesKey(_ w: String, _ c: String) -> String { "context-refs:\(w):\(c)" }
    public static func canvasesKey(_ w: String) -> String { "canvases:\(w)" }
    public static func canvasKey(_ w: String, _ c: String) -> String { "canvas:\(w):\(c)" }
    public static func boardKey(_ w: String, _ f: String) -> String { "board:\(w):\(f)" }
    public static func agentsKey(_ w: String) -> String { "agents:\(w)" }
    public static func agentActivityKey(_ w: String, _ c: String) -> String { "agent-activity:\(w):\(c)" }
    public static func toolboxKey(_ w: String) -> String { "toolbox:\(w)" }
    public static func pinsKey(_ w: String) -> String { "pins:\(w)" }

    /// Most channels whose agent activity is read for one context (Tower lists activity per channel).
    public static let agentActivityChannelLimit = 12
    /// Most board scenes fetched for one canvas snapshot.
    public static let boardFetchLimit = 6

    static func lost(_ error: Error) -> Bool {
        if case TowerError.http(let status, _, _) = error { return status == 403 || status == 404 }
        return false
    }

    // MARK: Context Tree

    /// A scope's components. A 404 (`context_not_found`: no access or archived) removes the stored tree.
    public func refreshContextTree(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scopeId: String,
                                   priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.contextTreeKey(workspace.id, scopeId), priority: priority, force: force) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            do {
                let components = try await api.contextComponents(workspaceId: workspace.id, appNpub: workspace.appNpub, scopeId: scopeId)
                try Task.checkCancellation()
                try await sync.store.writer.upsertContextComponents(workspaceId: workspace.id, scopeId: scopeId, components, complete: true)
                try await sync.store.writer.saveListSync(workspaceId: workspace.id, key: Self.contextTreeKey(workspace.id, scopeId), complete: true)
            } catch where Self.lost(error) {
                try await sync.store.writer.removeContextTree(workspaceId: workspace.id, scopeId: scopeId)
            }
        }
    }

    /// One component's references, with Tower's per-viewer resolution (user priority: the node was opened).
    public func refreshContextReferences(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scopeId: String, componentId: String,
                                         priority: SyncPriority = .user, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.contextReferencesKey(workspace.id, componentId), priority: priority, force: force) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            do {
                let references = try await api.contextReferences(workspaceId: workspace.id, appNpub: workspace.appNpub, scopeId: scopeId, componentId: componentId)
                try Task.checkCancellation()
                try await sync.store.writer.replaceContextReferences(workspaceId: workspace.id, scopeId: scopeId, componentId: componentId, references)
                try await sync.store.writer.saveListSync(workspaceId: workspace.id, key: Self.contextReferencesKey(workspace.id, componentId), complete: true)
            } catch where Self.lost(error) {
                try await sync.store.writer.removeContextComponent(workspaceId: workspace.id, id: componentId)
            }
        }
    }

    // MARK: Canvas

    public func refreshCanvases(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.canvasesKey(workspace.id), priority: priority, force: force) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let canvases = try await sync.api(origin: try TowerOrigin(connection.origin)).canvases(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            try await sync.store.writer.replaceCanvases(workspaceId: workspace.id, canvases)
        }
    }

    /// Opening a canvas: its snapshot, then the scenes of the boards on it that are not stored at their current version.
    public func refreshCanvas(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String,
                              priority: SyncPriority = .user, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.canvasKey(workspace.id, canvasId), priority: priority, force: force) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            let fetched: (canvas: CanvasRecord, snapshot: CanvasSnapshotRecord)
            do { fetched = try await api.canvasSnapshot(workspaceId: workspace.id, appNpub: workspace.appNpub, canvasId: canvasId) }
            catch where Self.lost(error) {
                try await sync.store.writer.removeCanvas(workspaceId: workspace.id, id: canvasId)
                return
            }
            try Task.checkCancellation()
            try await sync.store.writer.saveCanvasSnapshot(fetched.snapshot, canvas: fetched.canvas)
            for board in CanvasScene.parse(fetched.snapshot.bytes).boards.prefix(Self.boardFetchLimit) {
                await sync.refreshBoard(connection, workspace, board: board, priority: priority)
            }
        }
    }

    /// One board version's scene bytes (skipped when that version is already stored).
    public func refreshBoard(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, board: BoardReference, priority: SyncPriority = .user) async {
        let sync = self
        await engine.enqueue(Self.boardKey(workspace.id, board.fileId), priority: priority) {
            if let stored = try await sync.store.reader.boardScene(workspaceId: workspace.id, fileId: board.fileId),
               stored.versionId == board.versionId, stored.sha256 == board.sha256 { return }
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let scene = try await sync.api(origin: try TowerOrigin(connection.origin)).boardScene(workspaceId: workspace.id, appNpub: workspace.appNpub, board: board)
            try Task.checkCancellation()
            try await sync.store.writer.saveBoardScene(scene)
        }
    }

    // MARK: Agents

    /// Installed agents, then Tower's materialised activity for the given channels (bounded).
    public func refreshAgents(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channelIds: [String],
                              priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.agentsKey(workspace.id), priority: priority, force: force) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let agents = try await sync.api(origin: try TowerOrigin(connection.origin)).workspaceAgents(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            try await sync.store.writer.replaceWorkspaceAgents(workspaceId: workspace.id, agents)
        }
        for channel in channelIds.prefix(Self.agentActivityChannelLimit) {
            await refreshAgentActivity(connection, workspace, channelId: channel, priority: priority, force: force)
        }
    }

    public func refreshAgentActivity(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channelId: String,
                                     priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.agentActivityKey(workspace.id, channelId), priority: priority, force: force) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            do {
                let activity = try await api.agentActivities(workspaceId: workspace.id, appNpub: workspace.appNpub, channelId: channelId)
                try Task.checkCancellation()
                try await sync.store.writer.replaceAgentActivities(workspaceId: workspace.id, channelId: channelId, activity)
                try await sync.store.writer.saveListSync(workspaceId: workspace.id, key: Self.agentActivityKey(workspace.id, channelId), complete: true)
            } catch where Self.lost(error) {
                // No channel.read any more: nothing of that channel's activity stays on the phone.
                try await sync.store.writer.replaceAgentActivities(workspaceId: workspace.id, channelId: channelId, [])
            }
        }
    }

    // MARK: Toolbox

    public func refreshToolbox(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.toolboxKey(workspace.id), priority: priority, force: force) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let wapps = try await sync.api(origin: try TowerOrigin(connection.origin)).personalWapps(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            try await sync.store.writer.replacePersonalWapps(connectionId: connection.id, workspaceId: workspace.id, wapps)
        }
    }

    // MARK: Personal pins

    /// The complete pin set from the record-sync feed. The store mirrors Tower; a pin or unpin still in the write queue
    /// is overlaid by the screens (`PinState`), so a refresh never visually flips a pin the user just changed.
    public func refreshPins(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.pinsKey(workspace.id), priority: priority, force: force) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let result = try await sync.api(origin: try TowerOrigin(connection.origin)).personalPins(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            try await sync.store.writer.upsertPins(connectionId: connection.id, workspaceId: workspace.id, result.pins, complete: true)
        }
    }
}
