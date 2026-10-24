import Foundation

/// Read paths for tasks, documents, files, the inbox and reactions. Like chat catch-up, every request is a keyed
/// `SyncEngine` job (bounded concurrency, coalescing, cancellation, backoff) and results land in SQLite; screens only
/// observe the store. Parsing happens inside the job, never on the main actor.
extension WorkspaceSync {
    public static func tasksKey(_ w: String, _ c: String) -> String { "tasks:\(w):\(c)" }
    public static func taskKey(_ w: String, _ t: String) -> String { "task:\(w):\(t)" }
    public static func docsKey(_ w: String, _ c: String) -> String { "docs:\(w):\(c)" }
    public static func docKey(_ w: String, _ d: String) -> String { "doc:\(w):\(d)" }
    public static func filesKey(_ w: String, _ c: String) -> String { "files:\(w):\(c)" }
    public static func inboxKey(_ w: String) -> String { "inbox:\(w)" }
    public static func reactionsKey(_ w: String, _ scope: String) -> String { "reactions:\(w):\(scope)" }

    /// Most targets refreshed for one conversation's reactions (Tower lists reactions per target).
    public static let reactionTargetLimit = 40
    /// Most inbox records fetched individually because they are not in local lists yet.
    public static let inboxHydrationLimit = 30

    func channelIds(_ workspace: WorkspaceRecord, scopeId: String?) async throws -> [String] {
        try await store.reader.channels(workspaceId: workspace.id).filter { scopeId == nil || $0.scopeId == scopeId }.map(\.id)
    }

    // MARK: Tasks

    /// One job per channel (the task list route is per channel).
    public func refreshTasks(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scopeId: String? = nil,
                             priority: SyncPriority = .visible, force: Bool = false) async {
        guard let channels = try? await channelIds(workspace, scopeId: scopeId) else { return }
        let sync = self
        for channel in channels {
            await engine.enqueue(Self.tasksKey(workspace.id, channel), priority: priority, force: force) {
                try await sync.identity.requireSigner(npub: connection.signerNpub)
                let tasks = try await sync.api(origin: try TowerOrigin(connection.origin)).channelTasks(workspaceId: workspace.id, appNpub: workspace.appNpub, channelId: channel)
                try Task.checkCancellation()
                try await sync.store.writer.upsertTasks(workspaceId: workspace.id, tasks, completeChannel: channel)
                try await sync.store.writer.saveListSync(workspaceId: workspace.id, key: Self.tasksKey(workspace.id, channel), complete: true)
            }
        }
    }

    /// Task detail: the task and its comments (user priority).
    public func refreshTask(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, taskId: String, priority: SyncPriority = .user, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.taskKey(workspace.id, taskId), priority: priority, force: force) {
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            let task = try await api.task(workspaceId: workspace.id, appNpub: workspace.appNpub, taskId: taskId)
            try await sync.store.writer.upsertTasks(workspaceId: workspace.id, [task])
            let comments = try await api.taskComments(workspaceId: workspace.id, appNpub: workspace.appNpub, taskId: taskId)
            try Task.checkCancellation()
            try await sync.store.writer.upsertComments(workspaceId: workspace.id, comments, complete: (.task, task.id))
        }
    }

    // MARK: Documents

    public func refreshDocs(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scopeId: String? = nil,
                            priority: SyncPriority = .visible, force: Bool = false) async {
        guard let channels = try? await channelIds(workspace, scopeId: scopeId) else { return }
        let sync = self
        for channel in channels {
            await engine.enqueue(Self.docsKey(workspace.id, channel), priority: priority, force: force) {
                try await sync.identity.requireSigner(npub: connection.signerNpub)
                let page = try await sync.api(origin: try TowerOrigin(connection.origin)).channelDocs(workspaceId: workspace.id, appNpub: workspace.appNpub, channelId: channel)
                try Task.checkCancellation()
                // A possibly truncated page is never used to remove local documents.
                try await sync.store.writer.upsertDocs(workspaceId: workspace.id, page.docs, completeChannel: page.complete ? channel : nil)
                try await sync.store.writer.saveListSync(workspaceId: workspace.id, key: Self.docsKey(workspace.id, channel), complete: page.complete)
            }
        }
    }

    /// Opening a document fetches its canonical body (verified) and comments.
    public func refreshDoc(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String, priority: SyncPriority = .user, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.docKey(workspace.id, docId), priority: priority, force: force) {
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            let fetched = try await api.docBody(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: docId)
            try Task.checkCancellation()
            let text = DocumentBody(bytes: fetched.body.bytes, contentType: fetched.body.contentType).markdown
            try await sync.store.writer.saveDocBody(fetched.body, doc: fetched.doc, searchText: text)
            let comments = try await api.docComments(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: docId)
            try Task.checkCancellation()
            try await sync.store.writer.upsertComments(workspaceId: workspace.id, comments, complete: (.doc, fetched.doc.id))
        }
    }

    // MARK: Files

    public func refreshFiles(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scopeId: String? = nil,
                             priority: SyncPriority = .visible, force: Bool = false) async {
        guard let channels = try? await channelIds(workspace, scopeId: scopeId) else { return }
        let sync = self
        for channel in channels {
            await engine.enqueue(Self.filesKey(workspace.id, channel), priority: priority, force: force) {
                try await sync.identity.requireSigner(npub: connection.signerNpub)
                let api = sync.api(origin: try TowerOrigin(connection.origin))
                let files = try await api.channelFiles(workspaceId: workspace.id, appNpub: workspace.appNpub, channelId: channel)
                try Task.checkCancellation()
                try await sync.store.writer.upsertFiles(workspaceId: workspace.id, files.files, completeChannel: files.complete ? channel : nil)
                let folders = try await api.channelFolders(workspaceId: workspace.id, appNpub: workspace.appNpub, channelId: channel)
                try Task.checkCancellation()
                try await sync.store.writer.upsertFolders(workspaceId: workspace.id, channelId: channel, folders.folders, complete: folders.complete)
                try await sync.store.writer.saveListSync(workspaceId: workspace.id, key: Self.filesKey(workspace.id, channel), complete: files.complete)
            }
        }
    }

    // MARK: Inbox

    /// View states (unread and attention), then the few records they point at that are not stored yet.
    public func refreshInbox(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.inboxKey(workspace.id), priority: priority, force: force) {
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            let states = try await api.viewStates(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            try await sync.store.writer.upsertViewStates(workspaceId: workspace.id, states, complete: true)
            var fetched = 0
            for state in states where (state.unread || state.needsAttention) && fetched < Self.inboxHydrationLimit {
                try Task.checkCancellation()
                switch state.resourceType {
                case .task:
                    guard try await sync.store.reader.task(workspaceId: workspace.id, id: state.resourceId) == nil else { continue }
                    fetched += 1
                    if let task = try? await api.task(workspaceId: workspace.id, appNpub: workspace.appNpub, taskId: state.resourceId) {
                        try await sync.store.writer.upsertTasks(workspaceId: workspace.id, [task])
                    }
                case .document:
                    guard try await sync.store.reader.doc(workspaceId: workspace.id, id: state.resourceId) == nil else { continue }
                    fetched += 1
                    if let doc = try? await api.doc(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: state.resourceId) {
                        try await sync.store.writer.upsertDocs(workspaceId: workspace.id, [doc])
                    }
                case .thread:
                    guard try await sync.store.reader.thread(workspaceId: workspace.id, id: state.resourceId) == nil else { continue }
                    fetched += 1
                    if let thread = try? await api.thread(workspaceId: workspace.id, appNpub: workspace.appNpub, threadId: state.resourceId) {
                        try await sync.store.writer.upsertThreads(workspaceId: workspace.id, [thread])
                    }
                }
            }
        }
    }

    // MARK: Reactions

    /// Reactions for the newest messages of one conversation (`scope` is a channel or thread id).
    public func refreshReactions(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scope: String, messageIds: [String],
                                 priority: SyncPriority = .visible) async {
        let targets = Array(messageIds.suffix(Self.reactionTargetLimit))
        guard !targets.isEmpty else { return }
        let sync = self
        await engine.enqueue(Self.reactionsKey(workspace.id, scope), priority: priority) {
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            var all: [ReactionRecord] = []
            var done: [String] = []
            for target in targets {
                try Task.checkCancellation()
                guard let list = try? await api.reactions(workspaceId: workspace.id, appNpub: workspace.appNpub, targetType: "message", targetId: target) else { continue }
                all += list
                done.append(target)
            }
            try await sync.store.writer.replaceReactions(workspaceId: workspace.id, targets: done, all)
        }
    }
}
