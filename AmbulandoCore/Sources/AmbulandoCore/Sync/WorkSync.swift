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
            await engine.enqueue(Self.tasksKey(workspace.id, channel), priority: priority, force: force, retries: SyncBackoff.readRetries) {
                try await sync.identity.requireReader(npub: connection.signerNpub)
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
            try await sync.identity.requireReader(npub: connection.signerNpub)
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
            await engine.enqueue(Self.docsKey(workspace.id, channel), priority: priority, force: force, retries: SyncBackoff.readRetries) {
                try await sync.identity.requireReader(npub: connection.signerNpub)
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
            try await sync.identity.requireReader(npub: connection.signerNpub)
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
            await engine.enqueue(Self.filesKey(workspace.id, channel), priority: priority, force: force, retries: SyncBackoff.readRetries) {
                try await sync.identity.requireReader(npub: connection.signerNpub)
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
        await engine.enqueue(Self.inboxKey(workspace.id), priority: priority, force: force, retries: SyncBackoff.readRetries) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
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
            try await sync.identity.requireReader(npub: connection.signerNpub)
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

/// Downloaded file content, content-addressed under Caches so the system may purge it. A cached copy is used only
/// when its bytes still hash to the file's current sha256.
public struct FileCache: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[/\\\\:\\x00-\\x1f]", with: "_", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "file" : cleaned).prefix(120))
    }

    public func url(for file: FileRecord) -> URL {
        let version = file.sha256.map { String($0.prefix(16)) } ?? "v\(file.rowVersion)"
        return root.appendingPathComponent(file.workspaceId, isDirectory: true)
            .appendingPathComponent("\(file.id)-\(version)", isDirectory: true)
            .appendingPathComponent(Self.safeName(file.displayName))
    }

    public func cached(_ file: FileRecord) -> URL? {
        let url = url(for: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let sha = file.sha256 {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), SHA256Hex.of(data) == sha else { return nil }
        }
        return url
    }

    func store(_ bytes: Data, for file: FileRecord) throws -> URL {
        let url = url(for: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    /// Moves a verified downloaded file into the cache.
    func store(fileAt source: URL, for file: FileRecord) throws -> URL {
        let url = url(for: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return url
    }

    /// Removes cached content of one workspace (disconnect, workspace removal).
    public func purge(workspaceId: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(workspaceId, isDirectory: true)) }
}

extension WorkspaceSync {
    public static func downloadKey(_ w: String, _ f: String) -> String { "download:\(w):\(f)" }

    /// User-initiated download through the typed object route; the verified bytes land in the cache.
    public func download(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, file: FileRecord, cache: FileCache) async {
        let sync = self
        await engine.enqueue(Self.downloadKey(workspace.id, file.id), priority: .user, force: true) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            if let transfers = sync.transfers, let objectId = file.storageObjectId, let sha = file.sha256,
               let presigned = try? await api.presignedDownloadURL(objectId: objectId), presigned.sha256 == nil || presigned.sha256 == sha {
                // Unsigned background download from the object store; verified against the file's sha256 before caching.
                let key = "download:" + file.id + ":" + sha
                let downloaded = try await transfers.download(key: key, url: presigned.url, towerHost: api.client.origin.url.host)
                defer { Task { await transfers.forget(key) } }
                guard try SHA256Hex.ofFile(downloaded) == sha else { throw TowerError.malformed("file checksum") }
                _ = try cache.store(fileAt: downloaded, for: file)
                await sync.store.writer.touch([ChangeKey(.files, workspace.id)])
                return
            }
            let object = try await api.fileObject(workspaceId: workspace.id, appNpub: workspace.appNpub, fileId: file.id)
            try Task.checkCancellation()
            let current = FileRecord(workspaceId: file.workspaceId, id: file.id, scopeId: file.scopeId, channelId: file.channelId, folderId: file.folderId,
                                     storageObjectId: file.storageObjectId, displayName: file.displayName, description: file.description,
                                     contentType: object.contentType ?? file.contentType, sizeBytes: object.bytes.count, sha256: object.sha256,
                                     archived: file.archived, rowVersion: file.rowVersion, createdAt: file.createdAt, updatedAt: file.updatedAt, raw: file.raw)
            _ = try cache.store(object.bytes, for: current)
            await sync.store.writer.touch([ChangeKey(.files, workspace.id)])
        }
    }

    /// Chat attachment bytes (signed `GET /api/v4/storage/:id/content` on the pinned origin), cached by object id.
    public func downloadAttachment(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, objectId: String, cache: FileCache) async {
        let sync = self
        await engine.enqueue("attachment:\(workspace.id):\(objectId)", priority: .visible) {
            let target = cache.root.appendingPathComponent(workspace.id, isDirectory: true).appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(objectId)
            guard !FileManager.default.fileExists(atPath: target.path) else { return }
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            let bytes = try await sync.api(origin: try TowerOrigin(connection.origin)).storageContent(objectId: objectId)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            await sync.store.writer.touch([ChangeKey(.messages, workspace.id)])
        }
    }
}

extension FileCache {
    public func attachment(workspaceId: String, objectId: String) -> URL? {
        let url = root.appendingPathComponent(workspaceId, isDirectory: true).appendingPathComponent("attachments", isDirectory: true).appendingPathComponent(objectId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
