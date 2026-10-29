import Foundation

/// How one write attempt ended.
enum WriteOutcome: Sendable {
    case done(WriteAcknowledgement)
    case retryable(status: Int?, code: String?, message: String)
    case permanent(status: Int?, code: String?, message: String)
    case conflict(message: String)
}

/// Sends the durable write queue through `SyncEngine` at `user` priority, like the chat outbox.
///
/// - Only rows for this connection, origin and the unlocked signer are sent; requests are built from the row.
/// - Writes to one record run in order; a retryable failure holds the later writes of that record.
/// - Idempotency: task creation reuses `client_request_id` (Tower replays). Comments carry
///   `metadata.client_record_id` and reactions are looked up by author and emoji, and an attempt that may have reached
///   Tower (lost response, relaunch mid-send) is reconciled by reading before it is sent again. Set-style writes
///   (state, read position, assignee) are naturally idempotent. Message edits are signed once and frozen.
/// - Conflicts: task title/description/priority edits are checked against the version they were made on, because
///   Tower's PATCH does not check `row_version` for those fields. Someone else's change is never overwritten silently;
///   the row becomes `conflict` and keeps the user's text until they apply it anyway or discard it.
public struct WriteSender: Sendable {
    public let store: LocalStore
    public let engine: SyncEngine
    public let identity: IdentityService
    public let transport: HTTPTransport
    public let staging: URL
    /// Background transfers for presigned uploads (nil: uploads run in-process).
    public let transfers: BackgroundTransfers?
    /// Called after Tower accepted a notification change, so the inbox job can pick up the item versions it produced
    /// (the one sync owner schedules it; the sender never reads the inbox itself).
    public let afterNotificationWrite: (@Sendable (ConnectionRecord, String) async -> Void)?
    /// Called when Tower accepted a "create and link" document, before the write is retired: the screen that owns the
    /// source document puts the new page's id into its link. Throwing keeps the write queued, and the retry finds the
    /// already created page, so a source that could not be updated yet never loses the link or creates a second page.
    public let afterWikiCreate: (@Sendable (ConnectionRecord, WriteItem, DocRecord) async throws -> Void)?

    public init(store: LocalStore, engine: SyncEngine, identity: IdentityService, transport: HTTPTransport, staging: URL,
                transfers: BackgroundTransfers? = nil, afterNotificationWrite: (@Sendable (ConnectionRecord, String) async -> Void)? = nil,
                afterWikiCreate: (@Sendable (ConnectionRecord, WriteItem, DocRecord) async throws -> Void)? = nil) {
        self.store = store; self.engine = engine; self.identity = identity; self.transport = transport; self.staging = staging
        self.transfers = transfers; self.afterNotificationWrite = afterNotificationWrite; self.afterWikiCreate = afterWikiCreate
    }

    public static func key(_ connection: ConnectionRecord) -> String { "writes:\(connection.id)" }

    @discardableResult
    public func submit(_ intent: WriteIntent, connection: ConnectionRecord, workspace: WorkspaceRecord, id: String = UUID().uuidString.lowercased()) async throws -> WriteItem {
        guard workspace.id != "", connection.id != "" else { throw TowerError.unsafePath }
        let payload = try JSONSerialization.data(withJSONObject: intent.payload)
        guard !UploadToken.contains(in: String(decoding: payload, as: UTF8.self)) else { throw ComposerUploadError.unresolved }
        let item = try await store.writer.enqueueWrite(id: id, connection: connection, workspace: workspace, intent: intent)
        await kick(connection)
        return item
    }

    public func retry(_ id: String, connection: ConnectionRecord, force: Bool = false) async throws {
        try await store.writer.retryWrite(id: id, force: force)
        await kick(connection, force: true)
    }

    public func kick(_ connection: ConnectionRecord, force: Bool = false, after delay: Duration? = nil) async {
        let sender = self
        await engine.enqueue(Self.key(connection), priority: .user, force: force, delay: delay) { try await sender.drain(connection) }
    }

    func drain(_ connection: ConnectionRecord) async throws {
        guard case .unlocked(let npub) = await identity.state, npub == connection.signerNpub else { return }
        let client = TowerClient(origin: try TowerOrigin(connection.origin), transport: transport, signer: identity)
        let api = TowerAPI(client: client, transfers: transfers)
        var blocked = Set<String>()
        var nextRetry: Int?
        for item in try await store.reader.writes(connectionId: connection.id, signerNpub: npub) {
            try Task.checkCancellation()
            guard item.origin == connection.origin, item.signerNpub == npub else { continue }
            switch item.state {
            case .failed, .conflict, .sending: blocked.insert(item.groupKey); continue
            case .queued, .retrying: break
            }
            if blocked.contains(item.groupKey) { continue }
            try await store.writer.markWrite(id: item.id, state: .sending, status: item.lastStatus, code: item.lastCode, error: item.lastError)
            let outcome: WriteOutcome
            do {
                outcome = try await perform(item, api: api, client: client)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    try? await store.writer.updateWritePayload(id: item.id, merging: ["ambiguous": true])
                    try? await store.writer.markWrite(id: item.id, state: .queued, status: item.lastStatus, code: item.lastCode, error: item.lastError)
                    throw CancellationError()
                }
                outcome = Self.classify(error, attempts: item.attempts + 1)
                if case .retryable = outcome { try? await store.writer.updateWritePayload(id: item.id, merging: ["ambiguous": true]) }
            }
            switch outcome {
            case .done(let ack):
                if item.kind == .docCreate, item.string(WikiCreate.sourceKey) != nil, item.payloadObject[WikiCreate.boundKey] as? Bool != true,
                   let created = ack.docs.first, let bind = afterWikiCreate {
                    // Where the page is, kept on the write so a link that cannot be added yet can still be reached.
                    try? await store.writer.updateWritePayload(id: item.id, merging: [WikiCreate.createdKey: created.id])
                    do {
                        try await bind(connection, item, created)
                        try? await store.writer.updateWritePayload(id: item.id, merging: [WikiCreate.boundKey: true])
                    }
                    catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        let reason = (error as? LocalizedError)?.errorDescription ?? "The link will be added on the next attempt."
                        try await store.writer.markWrite(id: item.id, state: .retrying, status: nil, code: "wiki_link_pending",
                                                         error: "The page was created. \(reason)", countAttempt: true)
                        blocked.insert(item.groupKey)
                        nextRetry = min(nextRetry ?? .max, item.attempts + 1)
                        continue
                    }
                }
                try await store.writer.acknowledgeWrite(id: item.id, workspaceId: item.workspaceId, ack)
                if item.kind == .notificationState || item.kind == .notificationBulk { await afterNotificationWrite?(connection, item.workspaceId) }
                if item.kind == .fileUpload || item.kind == .docCreate, let staged = item.string("staged") { try? FileManager.default.removeItem(at: staging.appendingPathComponent(staged)) }
            case .retryable(let status, let code, let message):
                try await store.writer.markWrite(id: item.id, state: .retrying, status: status, code: code, error: message, countAttempt: true)
                blocked.insert(item.groupKey)
                nextRetry = min(nextRetry ?? .max, item.attempts + 1)
            case .permanent(let status, let code, let message):
                try await store.writer.markWrite(id: item.id, state: .failed, status: status, code: code, error: message, countAttempt: true)
                blocked.insert(item.groupKey)
            case .conflict(let message):
                try await store.writer.markWrite(id: item.id, state: .conflict, status: 409, code: "conflict", error: message, countAttempt: true)
                blocked.insert(item.groupKey)
            }
        }
        if let failures = nextRetry { await kick(connection, after: SyncBackoff.delay(failures: failures, random: Double.random(in: 0...1))) }
    }

    // MARK: Classification

    static func classify(status: Int, body: Data, attempts: Int, what: String) -> WriteOutcome {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = object?["code"] as? String ?? object?["error"] as? String
        let field = ((object?["details"] as? [String: Any])?["fields"] as? [[String: Any]])?.first?["message"] as? String
        switch status {
        case 401 where attempts < 3: return .retryable(status: status, code: code, message: "Tower did not accept the signature; retrying with a fresh one.")
        case 401: return .permanent(status: status, code: code, message: "Tower did not accept this identity's signature.")
        case 403: return .permanent(status: status, code: code, message: "You do not have permission to \(what).")
        case 404: return .permanent(status: status, code: code, message: "This \(what.split(separator: " ").last ?? "record") no longer exists.")
        case 408, 425, 429, 500...599: return .retryable(status: status, code: code, message: "Tower is unavailable (HTTP \(status)); will retry.")
        default: return .permanent(status: status, code: code, message: field.map { "Tower rejected this: \($0)" } ?? "Tower rejected this (HTTP \(status)\(code.map { ", \($0)" } ?? "")).")
        }
    }

    static func classify(_ error: Error, attempts: Int) -> WriteOutcome {
        if case TowerError.http(let status, let code, _) = error {
            return classify(status: status, body: (try? JSONSerialization.data(withJSONObject: ["code": code ?? ""])) ?? Data(), attempts: attempts, what: "make this change")
        }
        if error is LeaseError || error is FileTransferError || error is DocumentEditError {
            return .permanent(status: nil, code: nil, message: (error as? LocalizedError)?.errorDescription ?? "Not saved.")
        }
        if case TowerError.malformed(let what) = error { return .retryable(status: nil, code: nil, message: "Tower's \(what) reply could not be read; will check again.") }
        return .retryable(status: nil, code: nil, message: OutboxSender.networkMessage(error))
    }

    // MARK: Execution

    func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    func reply(_ data: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }

    func record<T>(_ data: Data, _ key: String, _ make: (Data) throws -> T) -> T? {
        guard let row = reply(data)[key] as? [String: Any], let raw = try? rawJSON(row) else { return nil }
        return try? make(raw)
    }

    func perform(_ item: WriteItem, api: TowerAPI, client: TowerClient) async throws -> WriteOutcome {
        let p = item.payloadObject
        let w = item.workspaceId, app = item.appNpub
        let base = try TowerAPI.base(w)
        let ambiguous = p["ambiguous"] as? Bool == true
        func send(_ method: String, _ path: String, _ body: [String: Any]?) async throws -> (status: Int, body: Data) {
            try await client.exchange(method: method, path: path, appNpub: app, jsonBody: try body.map(json))
        }
        switch item.kind {
        case .taskCreate:
            guard let channel = p["channel_id"] as? String else { return .permanent(status: nil, code: nil, message: "Missing channel.") }
            var body: [String: Any] = ["client_request_id": item.id, "title": p["title"] ?? "", "state": p["state"] ?? "new", "priority": p["priority"] ?? "sand"]
            if let d = p["description"] as? String, !d.isEmpty { body["description"] = d }
            if let a = p["assigned_to_npub"] as? String, !a.isEmpty { body["assigned_to_npub"] = a }
            // A task made from a conversation ("Get it done") keeps its thread and source link, as the web writes them.
            if let t = p["thread_id"] as? String, !t.isEmpty { body["thread_id"] = t }
            if let m = p["metadata"] as? [String: Any], !m.isEmpty { body["metadata"] = m }
            if let m = p["mentions"] as? [[String: Any]], !m.isEmpty { body["mentions"] = m }
            let r = try await send("POST", base + "/channels/" + TowerAPI.uuid(channel) + "/tasks", body)
            if (200..<300).contains(r.status), let task = record(r.body, "task", TaskRecord.init(raw:)) { return .done(ack(tasks: [task])) }
            if r.status == 409 { return .permanent(status: 409, code: "idempotency_conflict", message: "Tower already has a different task with this request.") }
            return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "create tasks in this channel")

        case .taskState:
            guard let task = item.targetId, let state = p["state"] as? String else { return .permanent(status: nil, code: nil, message: "Missing task.") }
            let r = try await send("POST", base + "/tasks/" + TowerAPI.uuid(task) + "/state", ["state": state])
            if (200..<300).contains(r.status), let t = record(r.body, "task", TaskRecord.init(raw:)) { return .done(ack(tasks: [t])) }
            return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "change this task")

        case .taskPatch:
            guard let taskId = item.targetId, let patch = p["patch"] as? [String: Any], let baseValues = p["base"] as? [String: Any],
                  let baseVersion = p["base_row_version"] as? Int else { return .permanent(status: nil, code: nil, message: "Missing task edit.") }
            let current = try await api.task(workspaceId: w, appNpub: app, taskId: taskId)
            let currentValues: [String: String] = ["title": current.title, "description": current.description ?? "", "priority": current.priority]
            let wanted = patch.mapValues { ($0 as? String) ?? "" }
            if wanted.allSatisfy({ currentValues[$0.key] == $0.value }) { return .done(ack(tasks: [current])) }
            if current.rowVersion != baseVersion, p["force"] as? Bool != true {
                let changed = wanted.keys.filter { currentValues[$0] != (baseValues[$0] as? String ?? "") }
                if !changed.isEmpty {
                    return .conflict(message: "Someone else changed the \(changed.sorted().joined(separator: " and ")) while you were editing. Your text is kept.")
                }
            }
            var body: [String: Any] = patch
            if let d = body["description"] as? String, d.isEmpty { body["description"] = NSNull() }
            let r = try await send("PATCH", base + "/tasks/" + TowerAPI.uuid(taskId), body)
            if (200..<300).contains(r.status), let t = record(r.body, "task", TaskRecord.init(raw:)) { return .done(ack(tasks: [t])) }
            return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "edit this task")

        case .taskAssign:
            guard let taskId = item.targetId, let baseVersion = p["base_row_version"] as? Int else { return .permanent(status: nil, code: nil, message: "Missing task.") }
            let wanted = (p["assigned_to_npub"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let previous = (p["base_assigned_to_npub"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var version = baseVersion
            for _ in 0..<2 {
                let r = try await send("PATCH", base + "/tasks/" + TowerAPI.uuid(taskId), ["assigned_to_npub": wanted ?? NSNull(), "row_version": version])
                if (200..<300).contains(r.status), let t = record(r.body, "task", TaskRecord.init(raw:)) { return .done(ack(tasks: [t])) }
                guard r.status == 409 else { return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "assign this task") }
                let current = try await api.task(workspaceId: w, appNpub: app, taskId: taskId)
                if current.assignedToNpub == wanted { return .done(ack(tasks: [current])) }
                // Only the row version moved (another field changed): the assignee is still what the user saw.
                guard current.assignedToNpub == previous || p["force"] as? Bool == true else {
                    return .conflict(message: "Someone else changed who this task is assigned to.")
                }
                version = current.rowVersion
            }
            return .retryable(status: 409, code: "stale_row_version", message: "The task kept changing; will retry.")

        case .taskComment, .docComment:
            let isTask = item.kind == .taskComment
            guard let parent = item.targetId, let text = p["body"] as? String else { return .permanent(status: nil, code: nil, message: "Missing comment.") }
            if ambiguous {
                let existing = isTask ? try await api.taskComments(workspaceId: w, appNpub: app, taskId: parent)
                                      : try await api.docComments(workspaceId: w, appNpub: app, docId: parent)
                if let mine = existing.first(where: { $0.clientRecordId == item.id }) { return .done(ack(comments: [mine])) }
            }
            var metadata: [String: Any] = ["client_record_id": item.id]
            if !isTask {
                metadata.merge(p["metadata"] as? [String: Any] ?? [:]) { current, _ in current }
                metadata["comment_status"] = "open"
            }
            // The canonical body and explicit actor identities travel together. Never route a plain display name.
            // Derive again from the durable body so retry/relaunch cannot send a removed or mismatched mention.
            let mentions = CommentMentions.actors(in: text).map(\.requestObject)
            metadata["mentions"] = mentions
            var body: [String: Any] = ["body": text, "metadata": metadata, "mentions": mentions]
            if let reply = p["parent_comment_id"] as? String { body["parent_comment_id"] = reply }
            let r = try await send("POST", base + (isTask ? "/tasks/" : "/docs/") + TowerAPI.uuid(parent) + "/comments", body)
            if (200..<300).contains(r.status), let c = record(r.body, "comment", { try CommentRecord(raw: $0, parent: isTask ? .task : .doc) }) {
                return .done(ack(comments: [c]))
            }
            return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: isTask ? "comment on this task" : "comment on this document")

        case .docCommentStatus:
            guard let comment = item.targetId, let doc = p["doc_id"] as? String, let status = p["status"] as? String,
                  var version = p["row_version"] as? Int else { return .permanent(status: nil, code: nil, message: "Missing comment.") }
            for _ in 0..<2 {
                let r = try await send("PATCH", base + "/docs/" + TowerAPI.uuid(doc) + "/comments/" + TowerAPI.uuid(comment), ["comment_status": status, "row_version": version])
                if (200..<300).contains(r.status), let c = record(r.body, "comment", { try CommentRecord(raw: $0, parent: .doc) }) { return .done(ack(comments: [c])) }
                guard r.status == 409 else { return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "resolve this comment") }
                guard let current = try await api.docComments(workspaceId: w, appNpub: app, docId: doc).first(where: { $0.id == comment }) else {
                    return .permanent(status: 404, code: nil, message: "This comment no longer exists.")
                }
                if current.status == status { return .done(ack(comments: [current])) }
                version = current.rowVersion
            }
            return .retryable(status: 409, code: "stale_row_version", message: "The comment kept changing; will retry.")

        case .messageEdit:
            guard let messageId = item.targetId else { return .permanent(status: nil, code: nil, message: "Missing message.") }
            let wantedBody = (p["body"] as? String) ?? ""
            var request = item.request
            if request == nil {
                guard let channel = p["channel_id"] as? String, let version = p["row_version"] as? Int else { return .permanent(status: nil, code: nil, message: "Missing message.") }
                let signed = try await MessageInstructionSignature.sign(body: wantedBody, workspaceId: w, channelId: channel, threadId: p["thread_id"] as? String,
                                                                         messageId: messageId, revision: version + 1, signer: identity)
                guard signed.signerNpub == item.signerNpub else { throw IdentityError.signerMismatch }
                let built = try json(["body": wantedBody, "row_version": version, "mentions": p["mentions"] ?? [], "message_signature": signed.requestObject])
                try await store.writer.freezeWrite(id: item.id, request: built)
                request = try await store.reader.writeItem(id: item.id)?.request
            }
            guard let request else { return .permanent(status: nil, code: nil, message: "Missing message.") }
            let r = try await client.exchange(method: "PATCH", path: base + "/messages/" + TowerAPI.uuid(messageId), appNpub: app, jsonBody: request)
            if (200..<300).contains(r.status), let m = record(r.body, "message", MessageRecord.init(raw:)) { return .done(ack(messages: [m])) }
            if r.status == 409 {
                if let current = try await api.message(workspaceId: w, appNpub: app, messageId: messageId), current.body == wantedBody {
                    return .done(ack(messages: [current]))
                }
                return .conflict(message: "This message changed on another device. Your edit was not applied.")
            }
            if r.status == 403 { return .permanent(status: 403, code: "message_author_required", message: "Only the author can edit this message.") }
            return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "edit this message")

        case .messageDelete:
            guard let messageId = item.targetId, let version = p["row_version"] as? Int else { return .permanent(status: nil, code: nil, message: "Missing message.") }
            let path = base + "/messages/" + (try TowerAPI.uuid(messageId))
            let request = try await client.exchange(method: "DELETE", path: path, appNpub: app, jsonBody: nil, query: [URLQueryItem(name: "row_version", value: String(version))])
            if (200..<300).contains(request.status), let m = record(request.body, "message", MessageRecord.init(raw:)) { return .done(ack(messages: [m.asDeleted])) }
            if request.status == 404 { return .done(ack(messages: try await deletedLocal(w, messageId))) }
            if request.status == 409 {
                let current = try await api.message(workspaceId: w, appNpub: app, messageId: messageId)
                if current == nil || current?.deleted == true { return .done(ack(messages: try await deletedLocal(w, messageId))) }
                return .conflict(message: "This message changed on another device, so it was not deleted.")
            }
            return Self.classify(status: request.status, body: request.body, attempts: item.attempts + 1, what: "delete this message")

        case .reactionAdd:
            guard let target = item.targetId, let emoji = p["emoji"] as? String, let type = p["target_type"] as? String else {
                return .permanent(status: nil, code: nil, message: "Missing reaction.")
            }
            if ambiguous, let mine = try await api.reactions(workspaceId: w, appNpub: app, targetType: type, targetId: target)
                .first(where: { $0.reactorNpub == item.signerNpub && $0.emoji == emoji }) { return .done(ack(reactions: [mine])) }
            let r = try await send("POST", base + "/reactions", ["target_type": type, "target_id": target, "emoji": emoji])
            if (200..<300).contains(r.status), let reaction = record(r.body, "reaction", ReactionRecord.init(raw:)) { return .done(ack(reactions: [reaction])) }
            return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "react here")

        case .reactionRemove:
            guard let reaction = p["reaction_id"] as? String else { return .permanent(status: nil, code: nil, message: "Missing reaction.") }
            let r = try await send("DELETE", base + "/reactions/" + TowerAPI.uuid(reaction), nil)
            if (200..<300).contains(r.status) || r.status == 404 { var a = WriteAcknowledgement(); a.removedReactionIds = [reaction]; return .done(a) }
            return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "remove this reaction")

        case .viewMark:
            let resources = (p["resources"] as? [[String: Any]]) ?? []
            guard !resources.isEmpty else { return .done(WriteAcknowledgement()) }
            let r: (status: Int, body: Data)
            if resources.count == 1, let type = resources[0]["resource_type"] as? String, let id = resources[0]["resource_id"] as? String,
               let version = resources[0]["viewed_activity_version"] as? Int {
                r = try await send("PUT", base + "/resource-view-states/" + type + "/" + TowerAPI.uuid(id), ["viewed_activity_version": version])
                if (200..<300).contains(r.status), let state = record(r.body, "state", ViewStateRecord.init(raw:)) { return .done(ack(viewStates: [state])) }
                // Gone, or already read past this version: nothing left to tell Tower.
                if r.status == 404 || r.status == 409 { return .done(WriteAcknowledgement()) }
            } else {
                let list = resources.prefix(500).compactMap { r -> [String: String]? in
                    guard let t = r["resource_type"] as? String, let i = r["resource_id"] as? String else { return nil }
                    return ["resource_type": t, "resource_id": i]
                }
                r = try await send("POST", base + "/resource-view-states/mark-viewed", ["resources": list])
                if (200..<300).contains(r.status) {
                    let states = ((reply(r.body)["states"] as? [[String: Any]]) ?? []).compactMap { try? ViewStateRecord(raw: rawJSON($0)) }
                    return .done(ack(viewStates: states))
                }
            }
            return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "mark this read")

        case .pinSet:
            return try await setPin(item, api: api, send: send)

        case .notificationState:
            return try await setNotificationState(item, api: api)

        case .notificationBulk:
            return try await bulkNotificationState(item, api: api)

        case .fileUpload, .docCreate:
            guard let channel = p["channel_id"] as? String, let staged = p["staged"] as? String, let contentType = p["content_type"] as? String,
                  let name = p["file_name"] as? String else { return .permanent(status: nil, code: nil, message: "Missing upload.") }
            let bytes = try Data(contentsOf: staging.appendingPathComponent(staged))
            let previous = (p["prepared_object_id"] as? String).flatMap { id in (p["prepared_upload_url"] as? String).map { PreparedObject(objectId: id, uploadURL: $0) } }
            let store = store, id = item.id
            let objectId = try await api.store(workspaceId: w, appNpub: app, bytes: bytes, contentType: contentType, fileName: name, prepared: previous) { fresh in
                try await store.writer.updateWritePayload(id: id, merging: ["prepared_object_id": fresh.objectId, "prepared_upload_url": fresh.uploadURL])
            }
            try Task.checkCancellation()
            if item.kind == .fileUpload {
                if ambiguous, let found = try await api.channelFiles(workspaceId: w, appNpub: app, channelId: channel).files.first(where: { $0.storageObjectId == objectId }) {
                    return .done(ack(files: [found]))
                }
                var body: [String: Any] = ["storage_object_id": objectId, "display_name": p["display_name"] ?? name]
                if let folder = p["folder_id"] as? String { body["folder_id"] = folder }
                let r = try await send("POST", base + "/channels/" + TowerAPI.uuid(channel) + "/files", body)
                if (200..<300).contains(r.status), let f = record(r.body, "file", FileRecord.init(raw:)) { return .done(ack(files: [f])) }
                if r.status == 409, let found = try await api.channelFiles(workspaceId: w, appNpub: app, channelId: channel).files.first(where: { $0.storageObjectId == objectId }) {
                    return .done(ack(files: [found]))
                }
                return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "upload files to this channel")
            } else {
                if ambiguous, let found = try await api.channelDocs(workspaceId: w, appNpub: app, channelId: channel).docs.first(where: { $0.storageObjectId == objectId }) {
                    return .done(ack(docs: [found]))
                }
                let summary = DocumentBody(bytes: bytes, contentType: contentType).markdown
                let r = try await send("POST", base + "/channels/" + TowerAPI.uuid(channel) + "/docs",
                                       ["title": p["title"] ?? "Untitled document", "storage_object_id": objectId, "summary": summary])
                if (200..<300).contains(r.status), let d = record(r.body, "doc", DocRecord.init(raw:)) { return .done(ack(docs: [d])) }
                if r.status == 409, let found = try await api.channelDocs(workspaceId: w, appNpub: app, channelId: channel).docs.first(where: { $0.storageObjectId == objectId }) {
                    return .done(ack(docs: [found]))
                }
                return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "create documents in this channel")
            }
        }
    }

    /// Pin or unpin. Tower checks `expected_row_version` and replays a known `mutation_id`, so resending after a lost
    /// reply is safe. On a version conflict the pins are re-read: if Tower already has what the user asked for, the write is
    /// done; otherwise it is resent once against the current version with a fresh mutation id (the user's latest intent wins,
    /// as it does on the web). A target the viewer may no longer read is refused permanently and shown as failed.
    func setPin(_ item: WriteItem, api: TowerAPI, send: (String, String, [String: Any]?) async throws -> (status: Int, body: Data)) async throws -> WriteOutcome {
        let p = item.payloadObject
        guard let typeName = p["resource_type"] as? String, let type = PinRecord.ResourceType(rawValue: typeName), let resource = item.targetId,
              let pinned = p["pinned"] as? Bool, var expected = p["expected_row_version"] as? Int, var mutation = p["mutation_id"] as? String else {
            return .permanent(status: nil, code: nil, message: "Missing pin.")
        }
        let path = try TowerAPI.base(item.workspaceId) + "/me/pins/" + type.rawValue + "/" + TowerAPI.uuid(resource)
        for attempt in 0..<2 {
            let r = try await send("PUT", path, ["pinned": pinned, "expected_row_version": expected, "mutation_id": mutation])
            if (200..<300).contains(r.status), let pin = record(r.body, "pin", PinRecord.init(raw:)) {
                var a = WriteAcknowledgement(); a.pins = [pin]; return .done(a)
            }
            let code = reply(r.body)["code"] as? String ?? reply(r.body)["error"] as? String
            guard r.status == 409, attempt == 0, code == "thread_pin_conflict" || code == "mutation_id_reused" else {
                if r.status == 403 { return .permanent(status: 403, code: code, message: "You can no longer pin this.") }
                return Self.classify(status: r.status, body: r.body, attempts: item.attempts + 1, what: "change this pin")
            }
            let current = try await api.personalPins(workspaceId: item.workspaceId, appNpub: item.appNpub).pins
                .first { $0.resourceType == type && $0.resourceId == resource }
            if (current?.pinned ?? false) == pinned {
                var a = WriteAcknowledgement(); a.pins = current.map { [$0] } ?? []; return .done(a)
            }
            expected = current?.rowVersion ?? 0
            mutation = UUID().uuidString.lowercased()
            try await store.writer.updateWritePayload(id: item.id, merging: ["expected_row_version": expected, "mutation_id": mutation])
        }
        return .conflict(message: "Your pin changed on another device; tap Retry to apply this change.")
    }

    /// One notification's read/dismiss/archive state, as the person saw it.
    ///
    /// The write carries the row version and change sequence of the *rendered* item and a `mutation_id`; Tower replays a known
    /// id and refuses a different request under it (`mutation_id_reused`: a rejection of this action, not a replay).
    /// On `state_conflict` the current item is adopted, and then:
    /// - already in the wanted state: done;
    /// - the card's content moved on (newer activity folded in) and the change would hide it (read, dismiss, archive): *not*
    ///   applied. The newer card stays as it is and the person is told;
    /// - only user-state changed elsewhere, or the change restores visibility (unread, undismiss, unarchive): the intent is
    ///   applied once to the current version with a fresh id.
    func setNotificationState(_ item: WriteItem, api: TowerAPI) async throws -> WriteOutcome {
        let p = item.payloadObject
        guard let id = item.targetId, let patch = p["patch"] as? [String: Any], var expected = p["expected_row_version"] as? Int,
              var observed = p["observed_change_seq"] as? Int, var mutation = p["mutation_id"] as? String else {
            return .permanent(status: nil, code: nil, message: "Missing notification change.")
        }
        let seenDigest = p["seen_digest"] as? String
        let read = patch["read"] as? Bool, dismissed = patch["dismissed"] as? Bool, archived = patch["archived"] as? Bool
        // Reading, dismissing or archiving takes something off the person's list of things to look at.
        let hides = read == true || dismissed == true || archived == true
        func satisfied(_ current: NotificationItem) -> Bool {
            (read == nil || current.isRead == read) && (dismissed == nil || current.isDismissed == dismissed) && (archived == nil || current.isArchived == archived)
        }
        let connection = item.connectionId, workspace = item.workspaceId
        func revert() async { try? await store.writer.clearNotificationPending(connectionId: connection, workspaceId: workspace, ids: [id]) }
        for attempt in 0..<2 {
            let reply = try await api.patchNotification(workspaceId: workspace, appNpub: item.appNpub, id: id, mutationId: mutation, expectedRowVersion: expected,
                                                        observedChangeSeq: hides ? observed : nil, read: read, dismissed: dismissed, archived: archived)
            switch reply {
            case .item(let updated):
                if let base = p["base_row_version"] as? Int, let seenDigest {
                    try? await store.writer.chainNotificationWrites(connectionId: connection, workspaceId: workspace, id: id, after: item.id,
                                                                    base: base, seenDigest: seenDigest, rowVersion: updated.rowVersion, changeSeq: updated.changeSeq)
                }
                var a = WriteAcknowledgement(); a.notifications = [updated]; return .done(a)
            case .stateConflict(let current):
                guard let current else {
                    await revert()
                    return .retryable(status: 409, code: "state_conflict", message: "This notification changed elsewhere; will check again.")
                }
                if satisfied(current) { var a = WriteAcknowledgement(); a.notifications = [current]; return .done(a) }
                try await store.writer.storeServerNotification(connectionId: connection, workspaceId: workspace, current)
                let moved = seenDigest != nil && current.activityDigest != seenDigest
                if (hides && moved) || attempt > 0 {
                    await revert()
                    return .conflict(message: hides && moved
                        ? "New activity arrived on this notification before your change reached Tower, so it was left as it is."
                        : "This notification kept changing, so your change was not applied.")
                }
                expected = current.rowVersion
                observed = current.changeSeq
                mutation = UUID().uuidString.lowercased()
                try await store.writer.updateWritePayload(id: item.id, merging: ["expected_row_version": expected, "observed_change_seq": observed, "mutation_id": mutation])
            case .mutationIdReused:
                await revert()
                return .permanent(status: 409, code: "mutation_id_reused", message: "Tower rejected this change because its request id was already used for a different change. Nothing was applied.")
            case .gone:
                // The item was removed (retention, access); the replayed tombstone takes it off the screen.
                await revert()
                return .done(WriteAcknowledgement())
            case .refused(let status, let code):
                let outcome = Self.classify(status: status, body: (try? JSONSerialization.data(withJSONObject: ["code": code ?? ""])) ?? Data(),
                                            attempts: item.attempts + 1, what: "change this notification")
                if case .permanent = outcome { await revert() }
                return outcome
            }
        }
        await revert()
        return .conflict(message: "This notification kept changing, so your change was not applied.")
    }

    /// "Mark all read" and the like, bounded by the sequence the user was shown (`up_to_seq`): anything newer stays unread.
    func bulkNotificationState(_ item: WriteItem, api: TowerAPI) async throws -> WriteOutcome {
        let p = item.payloadObject
        guard let op = p["op"] as? String, let mutation = p["mutation_id"] as? String else { return .permanent(status: nil, code: nil, message: "Missing notification change.") }
        let pending = (p["pending_ids"] as? [String]) ?? []
        for _ in 0..<1 {
            let outcome = try await api.bulkNotifications(workspaceId: item.workspaceId, appNpub: item.appNpub, mutationId: mutation, op: op,
                                                          ids: p["ids"] as? [String], upToSeq: p["up_to_seq"] as? Int, view: p["view"] as? String,
                                                          category: p["category"] as? String)
            switch outcome {
            case .done:
                var a = WriteAcknowledgement(); a.confirmedNotificationIds = pending; return .done(a)
            case .refused(let reply):
                if case .mutationIdReused = reply {
                    try? await store.writer.clearNotificationPending(connectionId: item.connectionId, workspaceId: item.workspaceId, ids: pending)
                    return .permanent(status: 409, code: "mutation_id_reused", message: "Tower rejected this change because its request id was already used for a different change. Nothing was applied.")
                }
                var status = 409, code: String?
                if case .refused(let s, let c) = reply { status = s; code = c }
                let result = Self.classify(status: status, body: (try? JSONSerialization.data(withJSONObject: ["code": code ?? ""])) ?? Data(),
                                           attempts: item.attempts + 1, what: "change these notifications")
                if case .permanent = result { try? await store.writer.clearNotificationPending(connectionId: item.connectionId, workspaceId: item.workspaceId, ids: pending) }
                return result
            }
        }
        return .retryable(status: 409, code: "mutation_id_reused", message: "Will check again.")
    }

    func deletedLocal(_ workspaceId: String, _ id: String) async throws -> [MessageRecord] {
        guard let local = try await store.reader.message(workspaceId: workspaceId, id: id) else { return [] }
        return [local.asDeleted]
    }

    func ack(tasks: [TaskRecord] = [], comments: [CommentRecord] = [], messages: [MessageRecord] = [], reactions: [ReactionRecord] = [],
             viewStates: [ViewStateRecord] = [], files: [FileRecord] = [], docs: [DocRecord] = []) -> WriteAcknowledgement {
        var a = WriteAcknowledgement()
        a.tasks = tasks; a.comments = comments; a.messages = messages; a.reactions = reactions; a.viewStates = viewStates; a.files = files; a.docs = docs
        return a
    }
}

extension MessageRecord {
    /// A tombstone that wins the row-version guard over the local copy.
    var asDeleted: MessageRecord {
        MessageRecord(workspaceId: workspaceId, id: id, channelId: channelId, threadId: threadId, threadSourceId: threadSourceId, body: deleted ? body : "",
                      senderNpub: senderNpub, senderLabel: senderLabel, clientRequestId: clientRequestId, createdAt: createdAt, updatedAt: updatedAt,
                      rowVersion: deleted ? rowVersion : rowVersion + 1, deleted: true, raw: raw)
    }
}
