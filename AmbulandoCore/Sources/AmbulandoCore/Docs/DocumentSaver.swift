import Foundation

public enum DocSaveResult: Sendable, Equatable {
    /// Tower made this the canonical body; the draft is gone and `doc` is the new base.
    case saved(DocRecord, DocBodyRecord)
    /// The document moved on since the edit began. Tower kept the submission as a recovery version
    /// (`document_recovery_created`) and the draft stays on this iPhone.
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

    public init(store: LocalStore, identity: IdentityService, transport: HTTPTransport) {
        self.store = store; self.identity = identity; self.transport = transport
    }

    func api(_ connection: ConnectionRecord) async throws -> TowerAPI {
        guard case .unlocked(let npub) = await identity.state, npub == connection.signerNpub else { throw IdentityError.locked }
        return TowerAPI(client: TowerClient(origin: try TowerOrigin(connection.origin), transport: transport, signer: identity))
    }

    static func leaseKey(_ workspaceId: String, _ docId: String) -> String { "\(workspaceId):\(docId)" }

    public func hasLease(workspaceId: String, docId: String) -> Bool { leases[Self.leaseKey(workspaceId, docId)] != nil }

    /// Acquires (or keeps) the edit lease. Throws `LeaseError.held` when another editor has it.
    @discardableResult
    public func acquire(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String) async throws -> EditLease {
        let key = Self.leaseKey(workspace.id, docId)
        if let lease = leases[key] { return lease }
        let lease = try await api(connection).acquireLease(workspaceId: workspace.id, appNpub: workspace.appNpub, entityType: "document", entityId: docId)
        leases[key] = lease
        return lease
    }

    /// Renews a held lease; a lease Tower no longer honours is forgotten so the next save acquires a fresh one.
    public func renew(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String) async throws {
        let key = Self.leaseKey(workspace.id, docId)
        guard let lease = leases[key] else { return }
        do { leases[key] = try await api(connection).renewLease(workspaceId: workspace.id, appNpub: workspace.appNpub, lease: lease) }
        catch let error as LeaseError { leases[key] = nil; throw error }
    }

    public func release(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String) async {
        let key = Self.leaseKey(workspace.id, docId)
        guard let lease = leases.removeValue(forKey: key) else { return }
        try? await api(connection).releaseLease(workspaceId: workspace.id, appNpub: workspace.appNpub, lease: lease)
    }

    /// Forgets every lease (lock, workspace switch); Tower expires them on its own.
    public func forgetAll() { leases.removeAll() }

    public func save(_ draft: DocDraft, connection: ConnectionRecord, workspace: WorkspaceRecord) async -> DocSaveResult {
        guard draft.connectionId == connection.id, draft.workspaceId == workspace.id else { return .notSaved("This draft belongs to another workspace.") }
        guard !UploadToken.contains(in: String(decoding: draft.body, as: UTF8.self)) else { return .notSaved(ComposerUploadError.unresolved.localizedDescription) }
        do {
            try await store.writer.saveDocDraft(draft.with(state: .saving))
            let api = try await api(connection)
            let lease: EditLease
            do { lease = try await acquire(connection, workspace, docId: draft.docId) }
            catch LeaseError.held(let by, let until) {
                let message = LeaseError.held(by: by, until: until).errorDescription ?? "Someone else is editing."
                try await store.writer.saveDocDraft(draft.with(state: .editing, error: message))
                return .leaseHeld(message)
            }
            let body = DocumentBody(bytes: draft.body, contentType: draft.contentType)
            let summary = body.markdown
            let fileName = String(draft.title.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression).prefix(80)) + "-\(draft.docId).document.json"
            let objectId = try await api.store(workspaceId: workspace.id, appNpub: workspace.appNpub, bytes: draft.body, contentType: draft.contentType,
                                               fileName: fileName, prepared: nil) { _ in }
            let request = try rawJSON(["row_version": draft.baseRowVersion, "base_available": true, "base_body_sha256_hex": draft.baseSha256,
                                       "storage_object_id": objectId, "lease_token": lease.token, "title": draft.title, "summary": summary])
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
                try await store.writer.deleteDocDraft(key: draft.key, workspaceId: workspace.id)
                return .saved(doc, saved)
            }
            if reply.status == 409, code == "document_recovery_created" {
                let recovery = (object?["recovery"] as? [String: Any])?["id"] as? String
                let message = "The document changed before your save. Tower kept your version as a recovery copy, and your draft stays on this iPhone."
                try await store.writer.saveDocDraft(draft.with(state: .recovery, error: message, recoveryId: recovery))
                return .recovery(id: recovery, message: message)
            }
            if reply.status == 409, code == "stale_row_version" {
                let message = "The document changed before your save. Your draft stays on this iPhone."
                try await store.writer.saveDocDraft(draft.with(state: .conflict, error: message))
                return .recovery(id: nil, message: message)
            }
            if reply.status == 409 {
                leases[Self.leaseKey(workspace.id, draft.docId)] = nil
                let message = LeaseError.invalid(code ?? "lease").errorDescription ?? "The edit lease expired."
                try await store.writer.saveDocDraft(draft.with(state: .editing, error: message))
                return .notSaved(message)
            }
            let outcome = WriteSender.classify(status: reply.status, body: reply.body, attempts: 1, what: "edit this document")
            let message: String = switch outcome {
            case .permanent(_, _, let m), .retryable(_, _, let m): m
            case .conflict(let m): m
            case .done: "Saved."
            }
            try await store.writer.saveDocDraft(draft.with(state: .failed, error: message))
            return .notSaved(message)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription.map { "Not saved yet: \($0)" }
                ?? "Not saved yet: \(OutboxSender.networkMessage(error))"
            try? await store.writer.saveDocDraft(draft.with(state: .editing, error: message))
            return .notSaved(message)
        }
    }
}
