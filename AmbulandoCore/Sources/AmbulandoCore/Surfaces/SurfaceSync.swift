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

    /// Channels whose agent activity is read first, at the caller's priority (Tower lists activity per channel). The rest of
    /// the context's channels follow at background priority, so none is left unread.
    public static let agentActivityChannelLimit = 12
    /// Boards of one canvas fetched first, at the caller's priority; the others follow at background priority, and any
    /// board shown or opened is also requested on demand (coalescing with its queued job).
    public static let boardFetchLimit = 6

    /// Schedules every board of a snapshot: the first batch at `priority`, the rest in the background.
    func scheduleBoards(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scene: CanvasScene, priority: SyncPriority) async {
        for (index, board) in scene.boards.enumerated() {
            await refreshBoard(connection, workspace, board: board, priority: index < Self.boardFetchLimit ? priority : .background)
        }
    }

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
            await sync.scheduleBoards(connection, workspace, scene: try CanvasScene.parse(fetched.snapshot.bytes), priority: priority)
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
        for (index, channel) in channelIds.enumerated() {
            await refreshAgentActivity(connection, workspace, channelId: channel, priority: index < Self.agentActivityChannelLimit ? priority : .background, force: force)
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
            let page = try await sync.api(origin: try TowerOrigin(connection.origin)).personalWapps(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            try await sync.store.writer.replacePersonalWapps(connectionId: connection.id, workspaceId: workspace.id, page.wapps, complete: page.complete)
            try await sync.store.writer.saveListSync(workspaceId: workspace.id, key: Self.toolboxKey(workspace.id), complete: page.complete)
            await sync.store.writer.touch([ChangeKey(.toolbox, workspace.id)])
        }
    }

    // MARK: HTML naplets

    /// The HTML of an HTML naplet, read when it is opened as web content. It is not stored on the phone: publisher HTML
    /// is shown live, and Tower re-authorizes the File on every read.
    public func napletHTML(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, napletId: String) async throws -> (title: String, html: String) {
        try await identity.requireReader(npub: connection.signerNpub)
        return try await api(origin: try TowerOrigin(connection.origin)).napletHTML(workspaceId: workspace.id, appNpub: workspace.appNpub, canvasId: canvasId, napletId: napletId)
    }

    // MARK: Conversations known by id

    public static func threadRecordKey(_ w: String, _ t: String) -> String { "thread-record:\(w):\(t)" }

    /// A thread referenced by a pin or a canvas naplet that is not stored yet: its record (for the channel), then its
    /// messages. A 403/404 leaves nothing stored and is reported on the job key.
    public func ensureThread(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, threadId: String, priority: SyncPriority = .user) async {
        let sync = self
        await engine.enqueue(Self.threadRecordKey(workspace.id, threadId), priority: priority) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let thread = try await sync.api(origin: try TowerOrigin(connection.origin)).thread(workspaceId: workspace.id, appNpub: workspace.appNpub, threadId: threadId)
            guard thread.workspaceId == workspace.id, thread.id == threadId.lowercased() else { throw TowerError.malformed("thread") }
            // Only a channel this viewer can see locally is used (the channel list is the access authority on the phone).
            guard try await sync.store.reader.channel(workspaceId: workspace.id, id: thread.channelId) != nil else { throw TowerError.http(status: 404, code: "channel_not_found", stage: nil) }
            try Task.checkCancellation()
            try await sync.store.writer.upsertThreads(workspaceId: workspace.id, [thread])
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
            try await sync.store.writer.setState("pin-order-support:\(connection.id):\(workspace.id)", result.ordering ? "1" : "0")
            try await sync.store.writer.upsertPins(connectionId: connection.id, workspaceId: workspace.id, result.pins, complete: true)
        }
    }
}
