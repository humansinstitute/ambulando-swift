import Foundation

/// Non-chat mutations, kept durably until Tower accepts them (the chat outbox stays separate: it freezes signed
/// message bytes). Each row is bound to its connection, origin, signer and workspace; requests are built only from it.
public enum WriteKind: String, Sendable, Codable, CaseIterable {
    case taskCreate = "task.create"
    case taskState = "task.state"
    case taskPatch = "task.patch"
    case taskAssign = "task.assign"
    case taskComment = "task.comment"
    case docCreate = "doc.create"
    case docComment = "doc.comment"
    case docCommentStatus = "doc.comment.status"
    case messageEdit = "message.edit"
    case messageDelete = "message.delete"
    case reactionAdd = "reaction.add"
    case reactionRemove = "reaction.remove"
    case viewMark = "view.mark"
    case fileUpload = "file.upload"
}

public enum WriteState: String, Sendable, Codable {
    case queued, sending
    /// Network or server problem; retried automatically.
    case retrying
    /// Tower refused it; the user retries or discards.
    case failed
    /// Someone else changed the record first; the user's change is kept for them to apply anyway or discard.
    case conflict
}

public struct WriteItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let connectionId: String
    public let origin: String
    public let signerNpub: String
    public let workspaceId: String
    public let appNpub: String
    public let kind: WriteKind
    public let targetId: String?
    public let groupKey: String
    public let payload: Data
    public let request: Data?
    public let state: WriteState
    public let attempts: Int
    public let lastStatus: Int?
    public let lastCode: String?
    public let lastError: String?
    public let createdAt: String

    public var payloadObject: [String: Any] { ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]) ?? [:] }
    public func string(_ key: String) -> String? { payloadObject[key] as? String }
    public var isPending: Bool { state != .failed && state != .conflict }
}

/// What the screen intends; the queue fills in identity and grouping.
public struct WriteIntent: Sendable {
    public let kind: WriteKind
    public let targetId: String?
    public let payload: [String: any Sendable]
    public init(kind: WriteKind, targetId: String?, payload: [String: any Sendable]) { self.kind = kind; self.targetId = targetId; self.payload = payload }

    /// Writes to the same record run in order; independent records do not wait on each other.
    var groupKey: String { targetId.map { "\(kind.rawValue.split(separator: ".").first ?? ""):\($0)" } ?? kind.rawValue }
}

/// Records Tower returned for an accepted write, stored in the same transaction that retires it.
public struct WriteAcknowledgement: Sendable {
    public var tasks: [TaskRecord] = []
    public var comments: [CommentRecord] = []
    public var messages: [MessageRecord] = []
    public var reactions: [ReactionRecord] = []
    public var removedReactionIds: [String] = []
    public var viewStates: [ViewStateRecord] = []
    public var files: [FileRecord] = []
    public var docs: [DocRecord] = []
    public init() {}
}

extension StoreWriter {
    static let writeColumns = """
    id, connection_id, origin, signer_npub, workspace_id, app_npub, kind, target_id, group_key, payload, request, state, attempts,
    last_status, last_code, last_error, created_at
    """

    @discardableResult
    public func enqueueWrite(id: String = UUID().uuidString.lowercased(), connection: ConnectionRecord, workspace: WorkspaceRecord,
                             intent: WriteIntent) async throws -> WriteItem {
        let stamp = now()
        let payload = try JSONSerialization.data(withJSONObject: intent.payload, options: [.sortedKeys])
        try db.prepare("""
        INSERT INTO writes(id, connection_id, origin, signer_npub, workspace_id, app_npub, kind, target_id, group_key, payload, request, state,
                           attempts, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,NULL,?,0,?,?)
        """).run([.text(id), .text(connection.id), .text(connection.origin), .text(connection.signerNpub), .text(workspace.id), .text(workspace.appNpub),
                  .text(intent.kind.rawValue), intent.targetId.sql, .text(intent.groupKey), .blob(payload), .text(WriteState.queued.rawValue),
                  .text(stamp), .text(stamp)])
        await emit([ChangeKey(.writes, workspace.id)])
        return WriteItem(id: id, connectionId: connection.id, origin: connection.origin, signerNpub: connection.signerNpub, workspaceId: workspace.id,
                         appNpub: workspace.appNpub, kind: intent.kind, targetId: intent.targetId, groupKey: intent.groupKey, payload: payload,
                         request: nil, state: .queued, attempts: 0, lastStatus: nil, lastCode: nil, lastError: nil, createdAt: stamp)
    }

    public func markWrite(id: String, state: WriteState, status: Int? = nil, code: String? = nil, error: String? = nil, countAttempt: Bool = false) async throws {
        try db.prepare("""
        UPDATE writes SET state = ?, last_status = ?, last_code = ?, last_error = ?, attempts = attempts + ?, updated_at = ? WHERE id = ?
        """).run([.text(state.rawValue), status.map { .int(Int64($0)) } ?? .null, code.sql, error.sql, .int(countAttempt ? 1 : 0), .text(now()), .text(id)])
        if let w = try writeWorkspace(id) { await emit([ChangeKey(.writes, w)]) }
    }

    /// Merges keys into a row's payload (upload progress, the ambiguity flag, "apply anyway").
    public func updateWritePayload(id: String, merging values: [String: any Sendable]) async throws {
        let s = try db.prepare("SELECT payload FROM writes WHERE id = ?")
        try s.bind([.text(id)])
        guard try s.step() else { return }
        var payload = ((try? JSONSerialization.jsonObject(with: s.blob(0))) as? [String: Any]) ?? [:]
        for (key, value) in values { payload[key] = value }
        try db.prepare("UPDATE writes SET payload = ?, updated_at = ? WHERE id = ?")
            .run([.blob(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])), .text(now()), .text(id)])
    }

    /// Stores the exact request bytes once (signed instructions); later attempts resend them unchanged.
    @discardableResult
    public func freezeWrite(id: String, request: Data) async throws -> Bool {
        try db.prepare("UPDATE writes SET request = ?, updated_at = ? WHERE id = ? AND request IS NULL").run([.blob(request), .text(now()), .text(id)])
        return db.changes > 0
    }

    /// Tower accepted the write: store what it returned and retire the row together.
    public func acknowledgeWrite(id: String, workspaceId: String, _ ack: WriteAcknowledgement) async throws {
        var keys: Set<ChangeKey> = [ChangeKey(.writes, workspaceId)]
        try db.transaction {
            if !ack.tasks.isEmpty { _ = try writeTasks(ack.tasks.filter { $0.workspaceId == workspaceId }); keys.insert(ChangeKey(.tasks, workspaceId)) }
            if !ack.messages.isEmpty { _ = try writeMessages(ack.messages.filter { $0.workspaceId == workspaceId }, keys: &keys) }
            if !ack.docs.isEmpty { _ = try writeDocs(ack.docs.filter { $0.workspaceId == workspaceId }); keys.insert(ChangeKey(.docs, workspaceId)) }
            if !ack.reactions.isEmpty { try writeReactions(ack.reactions.filter { $0.workspaceId == workspaceId }); keys.insert(ChangeKey(.reactions, workspaceId)) }
            for reaction in ack.removedReactionIds {
                try db.prepare("DELETE FROM reactions WHERE workspace_id = ? AND id = ?").run([.text(workspaceId), .text(reaction)])
                keys.insert(ChangeKey(.reactions, workspaceId))
            }
            try db.prepare("DELETE FROM writes WHERE id = ?").run([.text(id)])
        }
        await emit(keys)
        // Rows with their own upsert rules (comments, files, view states) use them after the retire commit.
        if !ack.comments.isEmpty { try await upsertComments(workspaceId: workspaceId, ack.comments) }
        if !ack.files.isEmpty { try await upsertFiles(workspaceId: workspaceId, ack.files) }
        if !ack.viewStates.isEmpty { try await upsertViewStates(workspaceId: workspaceId, ack.viewStates) }
    }

    public func discardWrite(id: String) async throws {
        let workspace = try writeWorkspace(id)
        try db.prepare("DELETE FROM writes WHERE id = ? AND state <> ?").run([.text(id), .text(WriteState.sending.rawValue)])
        if let workspace { await emit([ChangeKey(.writes, workspace)]) }
    }

    public func retryWrite(id: String, force: Bool = false) async throws {
        if force { try await updateWritePayload(id: id, merging: ["force": true]) }
        try db.prepare("UPDATE writes SET state = ?, updated_at = ? WHERE id = ? AND state IN (?, ?, ?)")
            .run([.text(WriteState.queued.rawValue), .text(now()), .text(id), .text(WriteState.failed.rawValue), .text(WriteState.retrying.rawValue),
                  .text(WriteState.conflict.rawValue)])
        if let w = try writeWorkspace(id) { await emit([ChangeKey(.writes, w)]) }
    }

    /// After relaunch nothing is in flight. An interrupted write may have reached Tower, so it is flagged ambiguous
    /// and reconciled before it is sent again.
    public func resetInterruptedWrites() async throws {
        let s = try db.prepare("SELECT id FROM writes WHERE state = ?")
        try s.bind([.text(WriteState.sending.rawValue)])
        var ids: [String] = []
        while try s.step() { ids.append(s.text(0)!) }
        for id in ids { try await updateWritePayload(id: id, merging: ["ambiguous": true]) }
        try db.prepare("UPDATE writes SET state = ? WHERE state = ?").run([.text(WriteState.queued.rawValue), .text(WriteState.sending.rawValue)])
        if !ids.isEmpty { await emit([ChangeKey(.writes)]) }
    }

    private func writeWorkspace(_ id: String) throws -> String? {
        let s = try db.prepare("SELECT workspace_id FROM writes WHERE id = ?")
        try s.bind([.text(id)])
        return try s.step() ? s.text(0) : nil
    }
}

extension StoreReader {
    static func write(_ s: SQLiteConnection.Statement) -> WriteItem? {
        guard let kind = WriteKind(rawValue: s.text(6) ?? "") else { return nil }
        return WriteItem(id: s.text(0)!, connectionId: s.text(1)!, origin: s.text(2)!, signerNpub: s.text(3)!, workspaceId: s.text(4)!, appNpub: s.text(5)!,
                         kind: kind, targetId: s.text(7), groupKey: s.text(8)!, payload: s.blob(9), request: s.isNull(10) ? nil : s.blob(10),
                         state: WriteState(rawValue: s.text(11) ?? "") ?? .failed, attempts: Int(s.int(12)),
                         lastStatus: s.isNull(13) ? nil : Int(s.int(13)), lastCode: s.text(14), lastError: s.text(15), createdAt: s.text(16)!)
    }

    public func writes(connectionId: String, signerNpub: String) throws -> [WriteItem] {
        let s = try db.prepare("SELECT \(StoreWriter.writeColumns) FROM writes WHERE connection_id = ? AND signer_npub = ? ORDER BY created_at, rowid")
        try s.bind([.text(connectionId), .text(signerNpub)])
        var rows: [WriteItem] = []
        while try s.step() { if let w = Self.write(s) { rows.append(w) } }
        return rows
    }

    /// Unfinished writes of one workspace (optionally for one record), oldest first, for pending overlays.
    public func writes(connectionId: String, workspaceId: String, targetId: String? = nil) throws -> [WriteItem] {
        let s = try db.prepare("""
        SELECT \(StoreWriter.writeColumns) FROM writes WHERE connection_id = ? AND workspace_id = ? AND (? IS NULL OR target_id = ?) ORDER BY created_at, rowid
        """)
        try s.bind([.text(connectionId), .text(workspaceId), targetId.sql, targetId.sql])
        var rows: [WriteItem] = []
        while try s.step() { if let w = Self.write(s) { rows.append(w) } }
        return rows
    }

    public func writeItem(id: String) throws -> WriteItem? {
        let s = try db.prepare("SELECT \(StoreWriter.writeColumns) FROM writes WHERE id = ?")
        try s.bind([.text(id)])
        return try s.step() ? Self.write(s) : nil
    }
}
