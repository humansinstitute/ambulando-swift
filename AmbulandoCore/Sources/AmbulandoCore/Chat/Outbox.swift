import Foundation

/// How a send attempt ended. Retryable outcomes resend the same frozen request later; permanent ones wait for the user.
public enum SendOutcome: Sendable, Equatable {
    case accepted(replayed: Bool)
    case retryable(status: Int?, code: String?, message: String)
    case permanent(status: Int, code: String?, message: String)
}

public enum OutboxRequest {
    /// Tower trims the body before verifying the kind 33358 content, so the client signs the trimmed text.
    public static func normalizedBody(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Builds the exact JSON bytes for `POST /channels/:c/messages`, including the kind 33358 instruction signature over
    /// `body` with the workspace, channel and (for replies) thread tags. These bytes are frozen and reused for every retry.
    /// `inheritedAgentRecipient` is a branched thread's agent (`metadata.inherited_agent_recipient_npub`): a reply that
    /// names nobody still goes to that agent through `metadata.agent_direct_recipient_npub`, as the web sends it.
    public static func build(_ item: OutboxItem, signer: EventSigner, inheritedAgentRecipient: String? = nil) async throws -> Data {
        let signed = try await MessageInstructionSignature.sign(body: item.body, workspaceId: item.workspaceId, channelId: item.channelId,
                                                                 threadId: item.threadId, signer: signer)
        guard signed.signerNpub == item.signerNpub else { throw IdentityError.signerMismatch }
        var object: [String: Any] = [
            "body": item.body,
            "client_request_id": item.id,
            "message_signature": signed.requestObject,
        ]
        if let thread = item.threadId { object["thread_id"] = thread } else { object["create_thread"] = true }
        if !item.mentions.isEmpty { object["mentions"] = item.mentions.map(\.requestObject) }
        let wire = item.attachments.compactMap(\.wire)
        guard wire.count == item.attachments.count, item.attachments.allSatisfy(\.complete) else { throw FileTransferError.notAttachable }
        // Storage links in the body are attachments too (sol `mergeChatStorageAttachments`).
        let attachments = StorageMarkdown.merged(wire, body: item.body)
        var metadata: [String: Any] = [:]
        if !attachments.isEmpty { metadata["attachments"] = attachments.map(\.requestObject) }
        if item.mentions.isEmpty, item.threadId != nil, let inheritedAgentRecipient, !inheritedAgentRecipient.isEmpty {
            metadata["agent_direct_recipient_npub"] = inheritedAgentRecipient
        }
        if !metadata.isEmpty { object["metadata"] = metadata }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Classifies Tower's answer. Codes follow the route: `idempotency_conflict` (409), `thread_not_found` /
    /// `channel_not_found` (404), `validation_error` (400) and authorization denials (403) are permanent.
    public static func classify(status: Int, body: Data, attempts: Int) -> SendOutcome {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if (200..<300).contains(status) { return .accepted(replayed: object?["replayed"] as? Bool == true) }
        let code = object?["code"] as? String
        let field = ((object?["details"] as? [String: Any])?["fields"] as? [[String: Any]])?.first?["message"] as? String
        switch (status, code) {
        case (409, "idempotency_conflict"):
            return .permanent(status: status, code: code, message: "Tower already has a different message with this request. Edit and send it as a new message.")
        case (404, "thread_not_found"):
            return .permanent(status: status, code: code, message: "This thread no longer exists.")
        case (404, "channel_not_found"):
            return .permanent(status: status, code: code, message: "This channel no longer exists.")
        case (403, _):
            return .permanent(status: status, code: code, message: "You do not have permission to post here.")
        case (401, _) where attempts < 3:
            return .retryable(status: status, code: code, message: "Tower did not accept the signature; retrying with a fresh one.")
        case (401, _):
            return .permanent(status: status, code: code, message: "Tower did not accept this identity's signature.")
        case (408, _), (425, _), (429, _), (500...599, _):
            return .retryable(status: status, code: code, message: "Tower is unavailable (HTTP \(status)); will retry.")
        default:
            return .permanent(status: status, code: code, message: field.map { "Tower rejected the message: \($0)" } ?? "Tower rejected the message (HTTP \(status)).")
        }
    }
}

/// Sends the durable outbox through `SyncEngine` at `user` priority (ahead of catch-up, never in its slots).
///
/// - Only rows for this connection, origin and the unlocked signer are sent; each request is built from the row,
///   never from what the screen currently shows.
/// - A row is signed once (explicit unlock required) and its exact bytes are frozen; each attempt gets a fresh NIP-98
///   header over those bytes. Tower's `client_request_id` replay makes a resend after a lost response safe.
/// - Order is kept per conversation: after a retryable failure later rows of that conversation wait for the next pass.
public struct OutboxSender: Sendable {
    public let store: LocalStore
    public let engine: SyncEngine
    public let identity: IdentityService
    public let transport: HTTPTransport
    /// Directory holding staged attachment bytes (privacy-stripped images) until their message is accepted.
    public let staging: URL?
    /// Background transfers for presigned attachment uploads (nil: in-process).
    public let transfers: BackgroundTransfers?

    public init(store: LocalStore, engine: SyncEngine, identity: IdentityService, transport: HTTPTransport, staging: URL? = nil,
                transfers: BackgroundTransfers? = nil) {
        self.store = store; self.engine = engine; self.identity = identity; self.transport = transport; self.staging = staging
        self.transfers = transfers
    }

    public static func key(_ connection: ConnectionRecord) -> String { "outbox:\(connection.id)" }

    /// Composes a message into the outbox (clearing that draft) and starts sending if unlocked.
    @discardableResult
    public func send(text: String, mentions selected: [Mention], target: ChatTarget, connection: ConnectionRecord,
                     workspace: WorkspaceRecord, attachments: [PendingAttachment] = []) async throws -> OutboxItem? {
        guard target.connectionId == connection.id, target.workspaceId == workspace.id else { throw TowerError.unsafePath }
        let (encoded, mentions) = MentionCodec.encode(text: text, selected: selected)
        let body = OutboxRequest.normalizedBody(encoded)
        guard !body.isEmpty || !attachments.isEmpty else { return nil }
        // A pasted item still uploading would otherwise be sent as its placeholder text.
        guard !UploadToken.contains(in: body) else { throw ComposerUploadError.unresolved }
        let item = try await store.writer.enqueueSend(target: target, origin: connection.origin, signerNpub: connection.signerNpub,
                                                      appNpub: workspace.appNpub, body: body, mentions: mentions, attachments: attachments)
        await kick(connection)
        return item
    }

    /// Removes an unsent message and its staged attachment bytes.
    public func discard(_ id: String, restoreDraft: Bool) async throws {
        let item = try await store.reader.outboxItem(id: id)
        let kept = try await store.writer.discardOutbox(id: id, restoreDraft: restoreDraft)
        if !kept, try await store.reader.outboxItem(id: id) == nil { removeStaged(item?.attachments ?? []) }
    }

    func removeStaged(_ attachments: [PendingAttachment]) {
        guard let staging else { return }
        for a in attachments { try? FileManager.default.removeItem(at: staging.appendingPathComponent(a.staged)) }
    }

    /// Uploads a row's staged images (prepare → upload → complete, resumable), recording progress on the row.
    func uploadAttachments(_ item: OutboxItem, api: TowerAPI) async throws -> OutboxItem {
        guard item.attachments.contains(where: { !$0.complete }) else { return item }
        guard let staging else { throw FileTransferError.notAttachable }
        var attachments = item.attachments
        for index in attachments.indices where !attachments[index].complete {
            let a = attachments[index]
            let bytes = try Data(contentsOf: staging.appendingPathComponent(a.staged))
            guard SHA256Hex.of(bytes) == a.sha256 else { throw FileTransferError.integrity }
            let previous = a.objectId.flatMap { id in a.uploadURL.map { PreparedObject(objectId: id, uploadURL: $0) } }
            let store = store, current = attachments
            let objectId = try await api.store(workspaceId: item.workspaceId, appNpub: item.appNpub, bytes: bytes, contentType: a.mimeType,
                                               fileName: a.filename, prepared: previous) { fresh in
                var next = current
                next[index].objectId = fresh.objectId; next[index].uploadURL = fresh.uploadURL
                try await store.writer.updateOutboxAttachments(id: item.id, next)
            }
            attachments[index].objectId = objectId
            attachments[index].complete = true
            try await store.writer.updateOutboxAttachments(id: item.id, attachments)
        }
        var updated = item
        updated.attachments = attachments
        return updated
    }

    public func retry(_ id: String, connection: ConnectionRecord) async throws {
        try await store.writer.retryOutbox(id: id)
        await kick(connection, force: true)
    }

    public func kick(_ connection: ConnectionRecord, force: Bool = false, after delay: Duration? = nil) async {
        let sender = self
        await engine.enqueue(Self.key(connection), priority: .user, force: force, delay: delay) { try await sender.drain(connection) }
    }

    /// One pass over the outbox. Locked or mismatched identity: nothing is signed or sent; rows simply wait.
    func drain(_ connection: ConnectionRecord) async throws {
        guard case .unlocked(let npub) = await identity.state, npub == connection.signerNpub else { return }
        let origin = try TowerOrigin(connection.origin)
        let client = TowerClient(origin: origin, transport: transport, signer: identity)
        var blocked = Set<String>()        // conversations waiting behind a retryable failure
        var nextRetry: Int?
        for item in try await store.reader.outbox(connectionId: connection.id, signerNpub: npub) {
            try Task.checkCancellation()
            guard item.origin == connection.origin, item.signerNpub == npub else { continue }
            let conversation = item.target.draftKey
            switch item.state {
            case .failed, .sending: continue
            case .awaitingSignature, .queued, .retrying: break
            }
            if blocked.contains(conversation) { continue }
            var request = item.request
            if request == nil {
                try await identity.requireSigner(npub: item.signerNpub)
                let ready: OutboxItem
                do {
                    ready = try await uploadAttachments(item, api: TowerAPI(client: client, transfers: transfers))
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    let permanent = error is FileTransferError
                    try await store.writer.markOutbox(id: item.id, state: permanent ? .failed : .retrying,
                                                      error: "Attachment upload: " + ((error as? LocalizedError)?.errorDescription ?? Self.networkMessage(error)),
                                                      countAttempt: true)
                    blocked.insert(conversation)
                    if !permanent { nextRetry = min(nextRetry ?? .max, item.attempts + 1) }
                    continue
                }
                let inherited = ready.threadId == nil ? nil : try await store.reader.thread(workspaceId: ready.workspaceId, id: ready.threadId!)?.inheritedAgentRecipient
                let built = try await OutboxRequest.build(ready, signer: identity, inheritedAgentRecipient: inherited)
                try await store.writer.freezeOutbox(id: item.id, request: built)
                request = try await store.reader.outboxItem(id: item.id)?.request
            }
            guard let request else { continue }
            try await store.writer.markOutbox(id: item.id, state: .sending, status: item.lastStatus, code: item.lastCode, error: item.lastError)
            let exchanged: Result<(status: Int, body: Data), Error>
            do {
                let path = try TowerAPI.base(item.workspaceId) + "/channels/" + TowerAPI.uuid(item.channelId) + "/messages"
                exchanged = .success(try await client.exchange(method: "POST", path: path, appNpub: item.appNpub, jsonBody: request))
            } catch {
                exchanged = .failure(error)
            }
            let outcome: SendOutcome
            switch exchanged {
            case .failure(let error):
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    // Interrupted (lock, workspace removal, app suspension): the request may have arrived; replay is safe.
                    try? await store.writer.markOutbox(id: item.id, state: .queued, status: item.lastStatus, code: item.lastCode, error: item.lastError)
                    throw CancellationError()
                }
                outcome = .retryable(status: nil, code: nil, message: Self.networkMessage(error))
            case .success(let reply):
                outcome = OutboxRequest.classify(status: reply.status, body: reply.body, attempts: item.attempts + 1)
                if case .accepted = outcome {
                    guard let ack = Self.acknowledgement(reply.body, item: item) else {
                        try await store.writer.markOutbox(id: item.id, state: .retrying, error: "Tower's reply could not be read; will check again.",
                                                          countAttempt: true)
                        blocked.insert(conversation); nextRetry = min(nextRetry ?? .max, item.attempts + 1)
                        continue
                    }
                    try await store.writer.acknowledgeSend(id: item.id, message: ack.message, thread: ack.thread)
                    removeStaged(item.attachments)
                    continue
                }
            }
            switch outcome {
            case .accepted: break
            case .retryable(let status, let code, let message):
                try await store.writer.markOutbox(id: item.id, state: .retrying, status: status, code: code, error: message, countAttempt: true)
                blocked.insert(conversation)
                nextRetry = min(nextRetry ?? .max, item.attempts + 1)
            case .permanent(let status, let code, let message):
                try await store.writer.markOutbox(id: item.id, state: .failed, status: status, code: code, error: message, countAttempt: true)
            }
        }
        if let failures = nextRetry { await kick(connection, after: SyncBackoff.delay(failures: failures, random: Double.random(in: 0...1))) }
    }

    static func networkMessage(_ error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "Offline; will send when the connection returns."
            case .timedOut: return "Tower did not answer in time; will retry."
            default: return "Network problem (\(url.code.rawValue)); will retry."
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? "Send failed; will retry."
    }

    /// Reads Tower's message (and thread) from a 200/201 reply. A new conversation's message is its thread's source.
    static func acknowledgement(_ body: Data, item: OutboxItem) -> (message: MessageRecord, thread: ThreadRecord?)? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let row = object["message"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let message = try? MessageRecord(raw: data), message.workspaceId == item.workspaceId, message.channelId == item.channelId else { return nil }
        let thread = (object["thread"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .flatMap { try? ThreadRecord(raw: $0) }
        var source = message.threadSourceId
        if source == nil, let thread, thread.id == message.threadId { source = thread.sourceMessageId ?? (item.createThread ? message.id : nil) }
        if source == nil, item.createThread, message.threadId != nil { source = message.id }
        let resolved = MessageRecord(workspaceId: message.workspaceId, id: message.id, channelId: message.channelId, threadId: message.threadId,
                                     threadSourceId: source, body: message.body, senderNpub: message.senderNpub ?? item.signerNpub,
                                     senderLabel: message.senderLabel, clientRequestId: message.clientRequestId ?? item.id,
                                     createdAt: message.createdAt, updatedAt: message.updatedAt, rowVersion: message.rowVersion,
                                     deleted: message.deleted, raw: message.raw)
        return (resolved, thread)
    }
}
