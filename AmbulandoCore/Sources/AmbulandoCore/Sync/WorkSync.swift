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
    /// Most individual reads per inbox pass, including records Tower reports gone.
    static let inboxHydrationAttempts = 120

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

    /// Hydrate the active channel before mention lookup, including every page. Normal File ACLs apply.
    public func refreshMentionFiles(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channelId: String) async throws {
        let sync = self
        try await engine.perform("mention-files:\(workspace.id):\(channelId)", priority: .user) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            let rows: [Data]
            do { rows = try await api.client.list(path: TowerAPI.base(workspace.id) + "/channels/" + TowerAPI.uuid(channelId) + "/files", appNpub: workspace.appNpub, key: "files") }
            catch TowerError.http(let status, _, _) where status == 403 || status == 404 {
                try await sync.store.writer.upsertFiles(workspaceId: workspace.id, [], completeChannel: channelId)
                throw TowerError.http(status: status, code: "channel_files_unavailable", stage: "File mentions")
            }
            let files = try rows.map(FileRecord.init(raw:))
            guard files.allSatisfy({ $0.workspaceId == workspace.id && $0.channelId == channelId }) else { throw TowerError.malformed("mention files") }
            try Task.checkCancellation()
            try await sync.store.writer.upsertFiles(workspaceId: workspace.id, files, completeChannel: channelId)
        }
    }

    // MARK: Inbox

    /// View states (unread and attention), then the few records they point at that are not stored yet.
    public func refreshInbox(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, priority: SyncPriority = .visible, force: Bool = false, reuseBaseline: Bool = false) async {
        await refreshAttentionTypes(connection, workspace, force: force)
        let sync = self
        await engine.enqueue(Self.inboxKey(workspace.id), priority: priority, force: force, retries: SyncBackoff.readRetries) {
            try await sync.synchronizeInbox(connection, workspace, reuseBaseline: reuseBaseline && !force)
        }
    }

    /// Shared by visible refresh and event materialization. Events await every dirty rerun before committing their cursor.
    func synchronizeInbox(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, reuseBaseline: Bool = false) async throws {
        let key = try WorkspaceBoundary(connection: connection, workspace: workspace).id
        let sync = self
        try await inboxSnapshots.refresh(key, reuseBaseline: reuseBaseline) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            let states = try await api.viewStates(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            try await sync.store.writer.upsertViewStates(workspaceId: workspace.id, states, complete: true)
            var fetched = 0, attempts = 0
            for state in states where (state.unread || state.needsAttention) && fetched < Self.inboxHydrationLimit && attempts < Self.inboxHydrationAttempts {
                try Task.checkCancellation()
                let resource = "\(key)/\(state.resourceType.rawValue):\(state.resourceId)"
                if await sync.inboxSnapshots.isGone(resource) { continue }
                /// One bounded read; only an existing record counts against the budget, a gone one is remembered.
                func hydrate<T>(_ read: () async throws -> T, save: (T) async throws -> Void) async throws {
                    attempts += 1
                    let value: T
                    do { value = try await read() }
                    catch where Self.isRecordMissing(error) { await sync.inboxSnapshots.markGone(resource); return }
                    catch where Self.isRecordGone(error) { return }   // forbidden now: retried next pass, never remembered
                    catch is CancellationError { throw CancellationError() }
                    catch { fetched += 1; return }
                    fetched += 1
                    try await save(value)
                }
                switch state.resourceType {
                case .task:
                    guard try await sync.store.reader.task(workspaceId: workspace.id, id: state.resourceId) == nil else { continue }
                    try await hydrate({ try await api.task(workspaceId: workspace.id, appNpub: workspace.appNpub, taskId: state.resourceId) }) { try await sync.store.writer.upsertTasks(workspaceId: workspace.id, [$0]) }
                case .document:
                    guard try await sync.store.reader.doc(workspaceId: workspace.id, id: state.resourceId) == nil else { continue }
                    try await hydrate({ try await api.doc(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: state.resourceId) }) { try await sync.store.writer.upsertDocs(workspaceId: workspace.id, [$0]) }
                case .thread:
                    guard try await sync.store.reader.thread(workspaceId: workspace.id, id: state.resourceId) == nil else { continue }
                    try await hydrate({ try await api.thread(workspaceId: workspace.id, appNpub: workspace.appNpub, threadId: state.resourceId) }) { try await sync.store.writer.upsertThreads(workspaceId: workspace.id, [$0]) }
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

    /// Deletes only exact revoked File versions and unshared attachments within this cache's boundary.
    /// User-owned drafts and upload staging are outside the cache and are never traversed.
    public func purge(workspaceId: String, fileIds: Set<String>, attachmentIds: Set<String>) throws {
        guard UUID(uuidString: workspaceId) != nil else { return }
        let workspace = root.appendingPathComponent(workspaceId, isDirectory: true)
        let ids = fileIds.filter { UUID(uuidString: $0) != nil }
        guard FileManager.default.fileExists(atPath: workspace.path) else { return }
        let entries = try FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)
        for entry in entries where ids.contains(where: { entry.lastPathComponent.hasPrefix($0 + "-") }) {
            try FileManager.default.removeItem(at: entry)
        }
        for id in attachmentIds where UUID(uuidString: id) != nil {
            let target = workspace.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent(id)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
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
            let cacheLease = await sync.store.writer.fileCacheLease()
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            if let transfers = sync.transfers, let objectId = file.storageObjectId, let sha = file.sha256,
               let presigned = try? await api.presignedDownloadURL(objectId: objectId), presigned.sha256 == nil || presigned.sha256 == sha {
                // Unsigned background download from the object store; verified against the file's sha256 before caching.
                let key = "download:" + file.id + ":" + sha
                let downloaded = try await transfers.download(key: key, url: presigned.url, towerHost: api.client.origin.url.host)
                defer { Task { await transfers.forget(key) } }
                guard try SHA256Hex.ofFile(downloaded) == sha else { throw TowerError.malformed("file checksum") }
                _ = try await sync.store.writer.cacheFile(at: downloaded, for: file, cache: cache, lease: cacheLease)
                await sync.store.writer.touch([ChangeKey(.files, workspace.id)])
                return
            }
            let object = try await api.fileObject(workspaceId: workspace.id, appNpub: workspace.appNpub, fileId: file.id)
            try Task.checkCancellation()
            let current = FileRecord(workspaceId: file.workspaceId, id: file.id, scopeId: file.scopeId, channelId: file.channelId, folderId: file.folderId,
                                     storageObjectId: file.storageObjectId, displayName: file.displayName, description: file.description,
                                     contentType: object.contentType ?? file.contentType, sizeBytes: object.bytes.count, sha256: object.sha256,
                                     archived: file.archived, rowVersion: file.rowVersion, createdAt: file.createdAt, updatedAt: file.updatedAt, raw: file.raw)
            _ = try await sync.store.writer.cacheFile(object.bytes, for: current, cache: cache, lease: cacheLease)
            await sync.store.writer.touch([ChangeKey(.files, workspace.id)])
        }
    }

    /// Foreground file export uses the authenticated typed route and returns only verified cached bytes.
    /// It does not mistake an object-store transfer or an enqueued job for a completed save.
    public func fileForExport(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, file: FileRecord, cache: FileCache) async throws -> URL {
        let sync = self
        return try await engine.perform(Self.downloadKey(workspace.id, file.id)) {
            let cacheLease = await sync.store.writer.fileCacheLease()
            try await sync.identity.requireReader(npub: connection.signerNpub)
            if let cached = cache.cached(file) { return cached }
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            let object = try await api.fileObject(workspaceId: workspace.id, appNpub: workspace.appNpub, fileId: file.id)
            try Task.checkCancellation()
            if let expected = file.sha256, expected != object.sha256 { throw TowerError.malformed("file changed; refresh Files and retry") }
            let url = try await sync.store.writer.cacheFile(object.bytes, for: file, cache: cache, lease: cacheLease)
            await sync.store.writer.touch([ChangeKey(.files, workspace.id)])
            return url
        }
    }

    /// Chat attachment bytes (signed `GET /api/v4/storage/:id/content` on the pinned origin), cached by object id.
    public func downloadAttachment(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, objectId: String, cache: FileCache) async {
        let sync = self
        await engine.enqueue("attachment:\(workspace.id):\(objectId)", priority: .visible) {
            let target = cache.root.appendingPathComponent(workspace.id, isDirectory: true).appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(objectId)
            guard !FileManager.default.fileExists(atPath: target.path) else { return }
            let cacheLease = await sync.store.writer.fileCacheLease()
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            let bytes = try await sync.api(origin: try TowerOrigin(connection.origin)).storageContent(objectId: objectId)
            try Task.checkCancellation()
            try await sync.store.writer.cacheAttachment(bytes, at: target, lease: cacheLease)
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
