import Foundation

public enum DocSaveResult: Sendable, Equatable {
    /// Tower made this the canonical body; the draft is gone and `doc` is the new base.
    case saved(DocRecord, DocBodyRecord)
    /// The document moved on since the edit began. The draft stays on this device for explicit review.
    /// A non-nil ID also identifies Tower's recovery when a save raced after preflight.
    case recovery(id: String?, message: String)
    /// Someone else holds the edit lease.
    case leaseHeld(String)
    /// The draft stays; the message says why (offline, refused, lease lost).
    case notSaved(String)
}

/// Edit lease and save flow for one document, on its own actor so hashing, encoding and transfers never run on the
/// main actor.
///
/// Contract (`PATCH /docs/:d`, `decideFlightDeckPgDocBodySave`): a body save uploads a new storage object
/// (prepare → upload → complete) and submits it with the base `row_version`, the base body's sha256 and a valid edit
/// lease token. A stale or unverifiable base never overwrites the head: Tower stores the submission as a recovery and
/// answers 409 `document_recovery_created`. The draft is written to SQLite before any network step and is removed only
/// after Tower confirms the canonical save, so a crash, lock or offline period cannot lose the edit.
public actor DocumentSaver {
    let store: LocalStore
    let identity: IdentityService
    let transport: HTTPTransport
    private var leases: [String: EditLease] = [:]
    private var saving: Set<String> = []
    private var acquiring: [String: Task<EditLease, Error>] = [:]
    private var lostSessions: Set<String> = []
    private var sessionIds: [String: String] = [:]
    private var selectedProtocols: [String: String] = [:]
    private var authorityGeneration: UInt64 = 0

    public init(store: LocalStore, identity: IdentityService, transport: HTTPTransport) {
        self.store = store; self.identity = identity; self.transport = transport
    }

    func api(_ connection: ConnectionRecord) async throws -> TowerAPI {
        guard case .unlocked(let npub) = await identity.state, npub == connection.signerNpub else { throw IdentityError.locked }
        return TowerAPI(client: TowerClient(origin: try TowerOrigin(connection.origin), transport: transport, signer: identity))
    }

    static func leaseKey(_ connectionId: String, _ workspaceId: String, _ docId: String, _ session: String?) -> String {
        "\(connectionId):\(workspaceId):\(docId):\(session ?? "default")"
    }

    public func hasLease(workspaceId: String, docId: String) -> Bool { leases.keys.contains { $0.contains(":\(workspaceId):\(docId):") } }

    /// Acquires (or keeps) the edit lease. Throws `LeaseError.held` when another editor has it.
    @discardableResult
    public func acquire(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String, editorSessionId: String? = nil) async throws -> EditLease {
        let key = Self.leaseKey(connection.id, workspace.id, docId, editorSessionId)
        if let lease = leases[key] { return lease }
        guard !lostSessions.contains(key) else { throw LeaseError.invalid("editor_superseded_or_expired") }
        let generation = authorityGeneration
        if let pending = acquiring[key] {
            let lease = try await pending.value
            guard generation == authorityGeneration, !lostSessions.contains(key) else { throw LeaseError.invalid("editor_closed") }
            return lease
        }
        let sessionId = editorSessionId ?? sessionIds[key] ?? UUID().uuidString.lowercased()
        sessionIds[key] = sessionId
        let pending = Task {
            let api = try await api(connection)
            let inspection: DocumentEditInspection?
            do { inspection = try await api.inspectDocumentEdit(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: docId) }
            catch TowerError.http(let status, _, _) where status == 404 { inspection = nil } // Older servers lack inspection.
            guard generation == authorityGeneration, !Task.isCancelled, !lostSessions.contains(key) else { throw LeaseError.invalid("editor_closed") }
            if selectedProtocols[key] == TowerAPI.concurrentDocumentEditProtocol, inspection?.concurrentSupported != true {
                throw LeaseError.invalid("concurrent_protocol_unavailable")
            }
            let protocolName = inspection?.concurrentSupported == true ? TowerAPI.concurrentDocumentEditProtocol : TowerAPI.documentEditProtocol
            selectedProtocols[key] = protocolName
            // An advertised concurrent mode is never silently downgraded on acquire failure.
            return try await api.acquireLease(workspaceId: workspace.id, appNpub: workspace.appNpub,
                entityType: "document", entityId: docId, editorSessionId: sessionId, documentProtocol: protocolName)
        }
        acquiring[key] = pending
        defer { acquiring[key] = nil }
        let lease = try await pending.value
        guard generation == authorityGeneration, !lostSessions.contains(key) else {
            try? await api(connection).releaseLease(workspaceId: workspace.id, appNpub: workspace.appNpub, lease: lease)
            throw LeaseError.invalid("editor_closed")
        }
        leases[key] = lease
        return lease
    }

    /// Renews a held lease; a lease Tower no longer honours is forgotten so the next save acquires a fresh one.
    public func renew(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String, editorSessionId: String? = nil) async throws {
        let key = Self.leaseKey(connection.id, workspace.id, docId, editorSessionId)
        guard let lease = leases[key] else { return }
        do {
            let renewed = try await api(connection).renewLease(workspaceId: workspace.id, appNpub: workspace.appNpub, lease: lease)
            if leases[key] == lease, !lostSessions.contains(key) { leases[key] = renewed }
        } catch let error as LeaseError { leases[key] = nil; lostSessions.insert(key); throw error }
    }

    public func release(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String, editorSessionId: String? = nil) async {
        let key = Self.leaseKey(connection.id, workspace.id, docId, editorSessionId)
        if editorSessionId != nil { lostSessions.insert(key) }
        guard let lease = leases.removeValue(forKey: key) else { return }
        try? await api(connection).releaseLease(workspaceId: workspace.id, appNpub: workspace.appNpub, lease: lease)
    }

    /// Forgets every lease (lock, workspace switch); Tower expires them on its own.
    public func forgetAll() {
        authorityGeneration &+= 1
        let active = Set(leases.keys).union(acquiring.keys)
        lostSessions.formUnion(active.filter { !$0.hasSuffix(":default") })
        for pending in acquiring.values { pending.cancel() }
        // Default background operations get a fresh identity after unlock; open editors keep their original identity.
        sessionIds = sessionIds.filter { !$0.key.hasSuffix(":default") }
        selectedProtocols = selectedProtocols.filter { !$0.key.hasSuffix(":default") }
        leases.removeAll()
    }

    /// An offline-expired editor retries only its original session and only on the unchanged remote base.
    /// A taken-over session is tombstoned by Tower and cannot pass acquire, even after the successor expires.
    public func resumeUnchangedSession(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String,
                                       editorSessionId: String) async -> Bool {
        let key = Self.leaseKey(connection.id, workspace.id, docId, editorSessionId)
        do {
            let api = try await api(connection)
            let inspection = try await api.inspectDocumentEdit(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: docId)
            guard inspection.leaseId == nil else { return false }
            let remote = try await api.docBody(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: docId)
            let draft = try await store.reader.docDraft(key: DocDraft.key(connectionId: connection.id, workspaceId: workspace.id, docId: docId))
            let cached = try await store.reader.docBody(workspaceId: workspace.id, docId: docId)
            guard let version = draft?.baseRowVersion ?? cached?.docRowVersion,
                  let sha = draft?.baseSha256 ?? cached?.sha256,
                  version == remote.doc.rowVersion, sha == remote.body.sha256 else { return false }
            lostSessions.remove(key)
            do { _ = try await acquire(connection, workspace, docId: docId, editorSessionId: editorSessionId); return true }
            catch { lostSessions.insert(key); return false }
        } catch { return false }
    }

    public func sessionLost(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String, editorSessionId: String) -> Bool {
        lostSessions.contains(Self.leaseKey(connection.id, workspace.id, docId, editorSessionId))
    }

    public func inspect(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String) async throws -> DocumentEditInspection {
        try await api(connection).inspectDocumentEdit(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: docId)
    }

    /// Explicit user action only. A supporting server revokes prior authority and advances the document version.
    public func takeover(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String,
                         editorSessionId: String, expectedLeaseId: String?) async throws -> (DocRecord, DocBodyRecord) {
        let api = try await api(connection)
        let inspected = try await api.inspectDocumentEdit(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: docId)
        // Tower authorizes the requesting actor; another holder is the reason for explicit takeover.
        guard inspected.supported, inspected.leaseId == expectedLeaseId
        else { throw LeaseError.invalid("takeover_not_available") }
        let lease = try await api.acquireLease(workspaceId: workspace.id, appNpub: workspace.appNpub, entityType: "document", entityId: docId,
                                               editorSessionId: editorSessionId, takeoverLeaseId: expectedLeaseId)
        let key = Self.leaseKey(connection.id, workspace.id, docId, editorSessionId)
        leases[key] = lease
        do {
            let fresh = try await api.docBody(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: docId)
            try await renew(connection, workspace, docId: docId, editorSessionId: editorSessionId)
            try await store.writer.saveDocBody(fresh.body, doc: fresh.doc, searchText: DocumentBody(bytes: fresh.body.bytes, contentType: fresh.body.contentType).markdown)
            return (fresh.doc, fresh.body)
        } catch {
            await release(connection, workspace, docId: docId, editorSessionId: editorSessionId)
            throw error
        }
    }

    public func save(_ draft: DocDraft, connection: ConnectionRecord, workspace: WorkspaceRecord, editorSessionId: String? = nil, asRecovery: Bool = false) async -> DocSaveResult {
        guard draft.connectionId == connection.id, draft.workspaceId == workspace.id else { return .notSaved("This draft belongs to another workspace.") }
        guard !UploadToken.contains(in: String(decoding: draft.body, as: UTF8.self)) else { return .notSaved(ComposerUploadError.unresolved.localizedDescription) }
        guard saving.insert(draft.key).inserted else { return .notSaved("A save is already in progress. Your latest edits stay on this device.") }
        defer { saving.remove(draft.key) }
        let submitted = draft.with(state: .saving)
        do {
            // Claim exactly this durable snapshot; a newer editor checkpoint must win.
            if let current = try await store.reader.docDraft(key: draft.key) {
                guard current.matchesContentAndBase(draft),
                      try await store.writer.replaceDocDraft(ifUnchanged: current, with: submitted)
                else { return .notSaved("Your draft changed before this save. Save again to sync the latest edits.") }
            } else {
                guard try await store.writer.insertDocDraftIfAbsent(submitted)
                else { return .notSaved("Your draft changed before this save. Save again to sync the latest edits.") }
            }
            let api = try await api(connection)
            if !asRecovery {
                // Verify current authority/content before upload as well as Tower's atomic CAS at commit.
                // An uncertain successful response can be acknowledged without submitting a duplicate version.
                let fresh = try await latest(connection, workspace, docId: draft.docId)
                if fresh.doc.title == draft.title, fresh.body.sha256 == SHA256Hex.of(draft.body) {
                    try await store.writer.finishDocDraftSave(submitted, saved: fresh.body)
                    return .saved(fresh.doc, fresh.body)
                }
                guard fresh.body.docRowVersion == draft.baseRowVersion, fresh.body.sha256 == draft.baseSha256,
                      fresh.body.storageObjectId == draft.baseStorageObjectId else {
                    let message = "Newer version available — Review changes. Your local draft is unchanged."
                    try await store.writer.replaceDocDraft(ifUnchanged: submitted, with: draft.with(state: .conflict, error: message))
                    return .recovery(id: nil, message: message)
                }
            }
            let lease: EditLease?
            do { lease = asRecovery ? nil : try await acquire(connection, workspace, docId: draft.docId, editorSessionId: editorSessionId) }
            catch LeaseError.held(let by, let until) {
                let message = LeaseError.held(by: by, until: until).errorDescription ?? "Someone else is editing."
                try await store.writer.replaceDocDraft(ifUnchanged: submitted, with: draft.with(state: .editing, error: message))
                return .leaseHeld(message)
            }
            let body = DocumentBody(bytes: draft.body, contentType: draft.contentType)
            let summary = body.markdown
            let fileName = String(draft.title.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression).prefix(80)) + "-\(draft.docId).document.json"
            let uploadKey = "doc.completed-upload:" + draft.key
            let hash = SHA256Hex.of(draft.body)
            let retained = try await store.reader.state(uploadKey).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            let objectId: String
            if retained?["sha256"] == hash, retained?["content_type"] == draft.contentType,
               let id = lowerUUID(retained?["object_id"]) { objectId = id }
            else {
                objectId = try await api.store(workspaceId: workspace.id, appNpub: workspace.appNpub, bytes: draft.body, contentType: draft.contentType,
                                               fileName: fileName, prepared: nil) { _ in }
                let receipt = try rawJSON(["sha256": hash, "content_type": draft.contentType, "object_id": objectId])
                try await store.writer.setState(uploadKey, String(decoding: receipt, as: UTF8.self))
            }
            let request = try rawJSON(["row_version": draft.baseRowVersion, "base_available": !asRecovery, "base_body_sha256_hex": draft.baseSha256,
                                       "storage_object_id": objectId, "lease_token": lease?.token ?? "", "title": draft.title, "summary": summary])
            let reply = try await api.client.exchange(method: "PATCH", path: try TowerAPI.base(workspace.id) + "/docs/" + TowerAPI.uuid(draft.docId),
                                                      appNpub: workspace.appNpub, jsonBody: request)
            let object = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
            let code = object?["code"] as? String
            if (200..<300).contains(reply.status), let row = object?["doc"] as? [String: Any], let doc = try? DocRecord(raw: rawJSON(row)),
               doc.workspaceId == workspace.id, doc.id == draft.docId {
                let sha = SHA256Hex.of(draft.body)
                let saved = DocBodyRecord(workspaceId: workspace.id, docId: doc.id, storageObjectId: objectId,
                                          sha256: ((object?["canonical_version"] as? [String: Any])?["body_sha256_hex"] as? String)?.lowercased() ?? sha,
                                          contentType: draft.contentType, docRowVersion: doc.rowVersion, bytes: draft.body,
                                          fetchedAt: ISO8601DateFormatter.tower.string(from: Date()))
                try await store.writer.saveDocBody(saved, doc: doc, searchText: summary)
                try await store.writer.finishDocDraftSave(submitted, saved: saved)
                try await store.writer.setState(uploadKey, nil)
                return .saved(doc, saved)
            }
            if reply.status == 409, code == "document_recovery_created" {
                let recovery = (object?["recovery"] as? [String: Any])?["id"] as? String
                let message = "The document changed before your save. Tower kept your version as a recovery copy, and your draft stays on this device."
                try await store.writer.replaceDocDraft(ifUnchanged: submitted, with: draft.with(state: .recovery, error: message, recoveryId: recovery))
                return .recovery(id: recovery, message: message)
            }
            if reply.status == 409, code == "stale_row_version" {
                let message = "The document changed before your save. Your draft stays on this device."
                try await store.writer.replaceDocDraft(ifUnchanged: submitted, with: draft.with(state: .conflict, error: message))
                return .recovery(id: nil, message: message)
            }
            if reply.status == 409 {
                let key = Self.leaseKey(connection.id, workspace.id, draft.docId, editorSessionId)
                leases[key] = nil; lostSessions.insert(key)
                let message = LeaseError.invalid(code ?? "lease").errorDescription ?? "The edit lease expired."
                try await store.writer.replaceDocDraft(ifUnchanged: submitted, with: draft.with(state: .editing, error: message))
                return .notSaved(message)
            }
            let outcome = WriteSender.classify(status: reply.status, body: reply.body, attempts: 1, what: "edit this document")
            let message: String = switch outcome {
            case .permanent(_, _, let m), .retryable(_, _, let m): m
            case .conflict(let m): m
            case .done: "Saved."
            }
            try await store.writer.replaceDocDraft(ifUnchanged: submitted, with: draft.with(state: .failed, error: message))
            return .notSaved(message)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription.map { "Not saved yet: \($0)" }
                ?? "Not saved yet: \(OutboxSender.networkMessage(error))"
            _ = try? await store.writer.replaceDocDraft(ifUnchanged: submitted, with: draft.with(state: .editing, error: message))
            return .notSaved(message)
        }
    }
}
