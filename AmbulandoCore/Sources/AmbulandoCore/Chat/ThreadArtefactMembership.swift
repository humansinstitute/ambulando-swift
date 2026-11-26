import Foundation
import CoreFoundation

/// App-owned references. Membership supplies neither source access nor a selected revision.
public struct ThreadArtefactMember: Hashable, Sendable, Identifiable {
    public let kind: String
    public let id: String
    public var identity: String { kind + ":" + id }
    public init(kind: String, id: String) throws {
        guard ["doc", "file"].contains(kind), UUID(uuidString: id) != nil else { throw ThreadArtefactMembership.Error.format }
        self.kind = kind; self.id = id.lowercased()
    }
}

public enum ThreadArtefactMembership {
    public static let key = "ambulando_thread_artefacts"
    public static let limit = 32
    public enum Error: LocalizedError, Sendable {
        case format, limit, changed, uncertain, unsupported
        public var errorDescription: String? {
            switch self {
            case .unsupported: "This source cannot be attached here. Open it in its normal viewer."
            case .format: "Unsupported thread attachment format. Update the app before changing attachments. Chat remains available."
            case .limit: "A thread supports up to 32 attachments. Remove one before adding another."
            case .changed: "Attachments changed repeatedly. Refresh and retry. Existing work is preserved."
            case .uncertain: "The latest attachments differ from this action. They were refreshed; retry explicitly if still wanted."
            }
        }
    }
    public static func metadata(_ row: ThreadRecord) throws -> Data {
        guard let raw = try JSONSerialization.jsonObject(with: row.raw) as? [String: Any] else { throw Error.format }
        guard raw["metadata"] == nil || raw["metadata"] is [String: Any] else { throw Error.format }
        return try JSONSerialization.data(withJSONObject: raw["metadata"] as? [String: Any] ?? [:], options: [.sortedKeys])
    }
    /// nil means absent, unlike the authoritative initialized empty array.
    public static func read(_ metadata: Data) throws -> [ThreadArtefactMember]? {
        guard let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] else { throw Error.format }
        guard let value = object[key] else { return nil }
        guard let value = value as? [String: Any], Set(value.keys) == ["version", "items"],
              let version = value["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let items = value["items"] as? [[String: Any]], items.count <= limit else { throw Error.format }
        var result: [ThreadArtefactMember] = []
        for item in items {
            guard Set(item.keys) == ["kind", "id"], let kind = item["kind"] as? String, let id = item["id"] as? String else { throw Error.format }
            let member = try ThreadArtefactMember(kind: kind, id: id)
            if !result.contains(member) { result.append(member) }
        }
        return result
    }
    public static func replacing(_ metadata: Data, with members: [ThreadArtefactMember]) throws -> Data {
        var unique: [ThreadArtefactMember] = []
        for member in members where !unique.contains(member) { unique.append(member) }
        guard unique.count <= limit else { throw Error.limit }
        guard var object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] else { throw Error.format }
        object[key] = ["version": 1, "items": unique.map { ["kind": $0.kind, "id": $0.id] }]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// Per-intent CAS reconciliation; never replay an ambiguous commit on a newer base.
public enum ThreadArtefactMembershipSync {
    public struct Transport: Sendable {
        public var read: @Sendable () async throws -> ThreadRecord
        public var write: @Sendable (ThreadRecord, Data) async throws -> ThreadRecord
        public var verify: @Sendable (ThreadArtefactMember) async throws -> Void
        public init(read: @escaping @Sendable () async throws -> ThreadRecord,
                    write: @escaping @Sendable (ThreadRecord, Data) async throws -> ThreadRecord,
                    verify: @escaping @Sendable (ThreadArtefactMember) async throws -> Void) {
            self.read = read; self.write = write; self.verify = verify
        }
    }
    public static func change(_ member: ThreadArtefactMember, adding: Bool, transport: Transport) async throws -> ThreadRecord {
        if adding { try await transport.verify(member) }
        var base = try await transport.read()
        var ambiguous = false
        for _ in 0..<4 {
            let metadata = try ThreadArtefactMembership.metadata(base)
            let members = try ThreadArtefactMembership.read(metadata)
            func satisfied(_ members: [ThreadArtefactMember]?) -> Bool { (adding || members != nil) && (members?.contains(member) == true) == adding }
            if satisfied(members) { return base }
            let desired = adding ? (members ?? []) + [member] : (members ?? []).filter { $0 != member }
            let replacement = try ThreadArtefactMembership.replacing(metadata, with: desired)
            do {
                let saved = try await transport.write(base, replacement)
                guard satisfied(try ThreadArtefactMembership.read(ThreadArtefactMembership.metadata(saved))) else { throw ThreadArtefactMembership.Error.uncertain }
                return saved
            } catch is CancellationError { throw CancellationError() }
            catch {
                if let tower = error as? TowerError, case .http(let status, _, _) = tower {
                    if status == 409 {
                        let observed = try await transport.read()
                        if ambiguous {
                            if satisfied(try ThreadArtefactMembership.read(ThreadArtefactMembership.metadata(observed))) { return observed }
                            guard observed.rowVersion == base.rowVersion else { throw ThreadArtefactMembership.Error.uncertain }
                        }
                        base = observed; continue
                    }
                    if (400..<500).contains(status) { throw error }
                }
                ambiguous = true
                let observed = try await transport.read()
                if satisfied(try ThreadArtefactMembership.read(ThreadArtefactMembership.metadata(observed))) { return observed }
                guard observed.rowVersion == base.rowVersion else { throw ThreadArtefactMembership.Error.uncertain }
                // Same unchanged CAS base is safe after a lost response. Never use an advanced base here.
                base = observed
            }
        }
        throw ThreadArtefactMembership.Error.changed
    }
    public static func migrate(_ legacy: [ThreadArtefactMember], transport: Transport) async throws -> ThreadRecord {
        let base = try await transport.read()
        let metadata = try ThreadArtefactMembership.metadata(base)
        guard try ThreadArtefactMembership.read(metadata) == nil, !legacy.isEmpty else { return base }
        var verified: [ThreadArtefactMember] = []
        for member in legacy where !verified.contains(member) {
            do { try await transport.verify(member); verified.append(member) }
            catch let error as TowerError {
                if case .http(let status, _, _) = error, [403, 404].contains(status) { continue }
                throw error
            }
        }
        guard !verified.isEmpty else { return base }
        do { return try await transport.write(base, ThreadArtefactMembership.replacing(metadata, with: verified)) }
        catch {
            let observed = try await transport.read()
            if try ThreadArtefactMembership.read(ThreadArtefactMembership.metadata(observed)) != nil { return observed }
            throw error
        }
    }
}

extension TowerAPI {
    public func updateThreadMetadata(workspaceId: String, appNpub: String, base: ThreadRecord, metadata: Data) async throws -> ThreadRecord {
        guard base.workspaceId == workspaceId, (1...Int(Int32.max)).contains(base.rowVersion) else { throw TowerError.malformed("thread version") }
        let body: [String: Any] = ["row_version": base.rowVersion, "metadata": try JSONSerialization.jsonObject(with: metadata)]
        let data = try await client.request(method: "PATCH", path: Self.base(workspaceId) + "/threads/" + Self.uuid(base.id), appNpub: appNpub,
            jsonBody: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = object["thread"] as? [String: Any] else { throw TowerError.malformed("thread") }
        let row = try ThreadRecord(raw: JSONSerialization.data(withJSONObject: raw))
        guard row.workspaceId == workspaceId, row.id == base.id, row.channelId == base.channelId, row.rowVersion > base.rowVersion, !row.deleted else { throw TowerError.malformed("thread identity") }
        return row
    }
}

extension WorkspaceSync {
    public func threadMembershipTransport(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, threadId: String) throws -> ThreadArtefactMembershipSync.Transport {
        let api = api(origin: try TowerOrigin(connection.origin)), store = store
        return .init(read: {
            try await identity.requireSigner(npub: connection.signerNpub)
            let row = try await api.thread(workspaceId: workspace.id, appNpub: workspace.appNpub, threadId: threadId)
            guard row.workspaceId == workspace.id, row.id == threadId, !row.deleted else { throw TowerError.malformed("thread identity") }
            _ = try await store.writer.upsertThreads(workspaceId: workspace.id, [row]); return row
        }, write: { base, metadata in
            try await identity.requireSigner(npub: connection.signerNpub)
            let row = try await api.updateThreadMetadata(workspaceId: workspace.id, appNpub: workspace.appNpub, base: base, metadata: metadata)
            _ = try await store.writer.upsertThreads(workspaceId: workspace.id, [row]); return row
        }, verify: { member in
            _ = try await threadArtefactLabel(connection, workspace, member: member, forAttachment: true)
        })
    }
    /// Lightweight authorized metadata only: no bodies, board bytes, editor or Send context.
    public func threadArtefactLabel(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, member: ThreadArtefactMember, forAttachment: Bool = false) async throws -> String {
        try await identity.requireSigner(npub: connection.signerNpub)
        let api = api(origin: try TowerOrigin(connection.origin))
        if member.kind == "doc" {
            let doc = try await api.doc(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: member.id)
            guard doc.workspaceId == workspace.id, doc.id == member.id else { throw TowerError.malformed("source") }
            let raw = try JSONSerialization.jsonObject(with: doc.raw) as? [String: Any] ?? [:]
            guard raw["deleted_at"] as? String == nil, !["deleted", "revoked", "access_removed"].contains(raw["record_state"] as? String ?? "") else { throw TowerError.http(status: 404, code: "source_unavailable", stage: nil) }
            if forAttachment, doc.archived { throw ThreadArtefactMembership.Error.unsupported }
            _ = try await store.writer.upsertDocs(workspaceId: workspace.id, [doc])
            return doc.title
        } else {
            let data = try await api.client.request(path: TowerAPI.base(workspace.id) + "/files/" + TowerAPI.uuid(member.id), appNpub: workspace.appNpub)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = object["file"] as? [String: Any] else { throw TowerError.malformed("source") }
            let file = try FileRecord(raw: JSONSerialization.data(withJSONObject: raw))
            guard file.workspaceId == workspace.id, file.id == member.id, raw["deleted_at"] as? String == nil, !["deleted", "revoked", "access_removed"].contains(raw["record_state"] as? String ?? "") else { throw TowerError.malformed("source") }
            if forAttachment, file.archived || ArtefactType.file(file) == nil { throw ThreadArtefactMembership.Error.unsupported }
            _ = try await store.writer.upsertFiles(workspaceId: workspace.id, [file])
            return file.displayName
        }
    }
}
