import Foundation

// Goals ride existing Tower contracts only: each goal is one ordinary File (channel-artefacts v1) whose content is the
// goal JSON, kept in the owner's private Goals channel (see `GoalsSpace`). Tower's channel access is the only authority:
// owner isolation, revisions (`base_version_id`, 409 `stale_base_version`), sync and recovery are the File contract's.
// Nothing here is a new endpoint:
//
// - `GET  /channels/:c/files`, `GET /files/:f`, `GET /files/:f/versions/:v/object`
// - `POST /storage/prepare` … `complete`, `POST /channels/:c/files`, `POST /files/:f/versions` with `base_version_id`

public struct GoalDocument: Sendable, Equatable, Identifiable {
    /// A File UUID is the permanent reference identity, even after storage authority moves to SQL.
    public enum Storage: String, Sendable, Codable { case file, relational }
    public let file: FileRecord
    public let versionId: String
    public let goal: Goal
    public let storage: Storage
    public var id: String { file.id }
    public init(file: FileRecord, versionId: String, goal: Goal, storage: Storage = .file) {
        self.file = file; self.versionId = versionId; self.goal = goal; self.storage = storage
    }
}

public enum GoalFiles {
    public static let metadataKey = "goal"

    public static var metadata: [String: Any] { [metadataKey: ["schema_version": Goal.version]] }

    public static func isGoal(_ file: FileRecord) -> Bool {
        let raw = (try? JSONSerialization.jsonObject(with: file.raw)) as? [String: Any] ?? [:]
        let meta = (raw["metadata"] as? [String: Any])?[metadataKey] as? [String: Any]
        // A soft-deleted File stays record_state=active with deleted_at set, so any non-null deleted_at is a tombstone.
        let deletedAt = raw["deleted_at"]
        return !file.archived && raw["record_state"] as? String != "deleted" && (deletedAt == nil || deletedAt is NSNull)
            && file.contentType?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) == Goal.mime
            && flexibleInt(meta?["schema_version"]) == Goal.version
    }

    public static func fileName(_ goal: Goal) -> String {
        let cleaned = String(goal.name.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f || $0 == "/" || $0 == "\\" ? " " : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Goal" : String(cleaned.prefix(80))) + ".goal.json"
    }
}

/// How one save of a goal version ended. A conflict or refusal never overwrites anything.
public enum GoalSaveOutcome: Sendable, Equatable {
    case saved(versionId: String)
    /// Someone saved a newer version first (`stale_base_version`).
    case conflict
    case denied(String)
    case retryable(String)
}

/// The edit lost every attempt to concurrent saves, or Tower refused it. The goal is unchanged; nothing was overwritten.
public struct GoalSaveFailed: LocalizedError, Equatable, Sendable {
    public let message: String
    public let retryable: Bool
    public var errorDescription: String? { message }
}

/// Storage seam for one workspace's goal Files, so the edit loop is testable without a network.
public struct GoalTransport: Sendable {
    public var read: @Sendable (_ fileId: String) async throws -> GoalDocument
    /// Stores `bytes` and publishes them as the next version against `baseVersionId`, verifying what Tower recorded.
    public var save: @Sendable (_ fileId: String, _ baseVersionId: String, _ bytes: Data, _ name: String) async throws -> GoalSaveOutcome

    public init(read: @escaping @Sendable (String) async throws -> GoalDocument,
                save: @escaping @Sendable (String, String, Data, String) async throws -> GoalSaveOutcome) {
        self.read = read; self.save = save
    }
}

public enum GoalEditor {
    /// Applies `edits` to the newest saved goal and saves them as one new version against that version. If another save
    /// wins the race the edits are re-applied to the new head, so independent changes from two devices or an agent both
    /// survive; an edit whose expectation no longer holds throws `GoalError.conflict` and saves nothing.
    public static func edit(_ transport: GoalTransport, fileId: String, edits: [GoalEdit], attempts: Int = 4) async throws -> GoalDocument {
        precondition(!edits.isEmpty)
        var head = try await transport.read(fileId)
        for _ in 0..<attempts {
            try Task.checkCancellation()
            let next = try GoalEdit.applyAll(edits, to: head.goal)
            if next == head.goal { return head }
            switch try await transport.save(fileId, head.versionId, next.encode(), GoalFiles.fileName(next)) {
            case .saved(let versionId):
                return GoalDocument(file: head.file, versionId: versionId, goal: next, storage: head.storage)
            case .conflict:
                head = try await transport.read(fileId)
            case .denied(let message):
                throw GoalSaveFailed(message: message, retryable: false)
            case .retryable(let message):
                throw GoalSaveFailed(message: message, retryable: true)
            }
        }
        throw GoalSaveFailed(message: "This goal is being changed elsewhere. Try again in a moment.", retryable: true)
    }

    /// Saves a focus move (`GoalFocus.planMove`) one goal at a time, top first. Each write is that goal's own
    /// expectation-checked `setFocusRank` saved against its current version (a lost race re-applies only that write to
    /// the new head, and only while the rank it expected still holds). The first refusal stops the move: later writes
    /// are not attempted and the plan is never retried as a whole. `GoalFocusMoveFailed` reports what was saved; every
    /// intermediate state is a valid order, so the caller reloads and shows it.
    public static func move(_ transport: GoalTransport, writes: [GoalFocus.Write], attempts: Int = 4) async throws -> [GoalDocument] {
        var saved: [GoalDocument] = []
        for write in writes {
            do { saved.append(try await edit(transport, fileId: write.id, edits: [write.edit], attempts: attempts)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw GoalFocusMoveFailed(saved: saved, total: writes.count, underlying: error) }
        }
        return saved
    }
}

/// A focus move stopped at a refused write; `saved` were written before it, nothing after it was attempted.
public struct GoalFocusMoveFailed: LocalizedError, Sendable {
    public let saved: [GoalDocument]
    public let total: Int
    public let reason: String

    init(saved: [GoalDocument], total: Int, underlying: Error) {
        self.saved = saved; self.total = total
        reason = switch underlying {
        case let e as GoalError: e.localizedDescription
        case let e as GoalSaveFailed: e.message
        default: underlying.localizedDescription
        }
    }

    public var errorDescription: String? {
        saved.isEmpty ? reason : "Saved \(saved.count) of \(total) order changes. \(reason)"
    }
}

extension TowerAPI {
    /// Goal Files of one channel. A failed or truncated list is an error, never "no goals".
    public func goalFiles(workspaceId: String, appNpub: String, channelId: String) async throws -> [FileRecord] {
        let rows = try await client.list(path: Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/files", appNpub: appNpub, key: "files")
        let files = try rows.map(FileRecord.init(raw:))
        guard files.allSatisfy({ $0.workspaceId == workspaceId && $0.channelId == channelId.lowercased() }) else { throw TowerError.malformed("goal files") }
        return files.filter(GoalFiles.isGoal)
    }

    /// The file's current version, read directly (independent of history length) and verified against its hash.
    public func readGoal(workspaceId: String, appNpub: String, fileId: String) async throws -> GoalDocument {
        let o = try object(try await client.request(path: Self.base(workspaceId) + "/files/" + Self.uuid(fileId), appNpub: appNpub), "goal")
        guard let row = o["file"] as? [String: Any] else { throw TowerError.malformed("goal") }
        let file = try FileRecord(raw: rawJSON(row))
        guard file.workspaceId == workspaceId, file.id == fileId.lowercased() else { throw TowerError.malformed("goal") }
        guard GoalFiles.isGoal(file) else { throw GoalError.invalid("This is not a goal.") }
        return try await readGoal(workspaceId: workspaceId, appNpub: appNpub, file: file)
    }

    public func readGoal(workspaceId: String, appNpub: String, file: FileRecord) async throws -> GoalDocument {
        var versionId: String?, size: Int?, sha: String?
        if let current = (try? JSONSerialization.jsonObject(with: file.raw) as? [String: Any])?["current_version"] as? [String: Any],
           let id = lowerUUID(current["id"] as? String), let hash = (current["sha256_hex"] as? String)?.lowercased(), hash.count == 64 {
            versionId = id; size = flexibleInt(current["size_bytes"]); sha = hash
        } else {
            let list = try await boardVersions(workspaceId: workspaceId, appNpub: appNpub, fileId: file.id)
            guard let id = list.currentVersionId, let row = list.versions.first(where: { $0.id == id }) else { throw TowerError.malformed("goal version") }
            versionId = id; sha = row.sha256.isEmpty ? nil : row.sha256
        }
        guard let versionId else { throw TowerError.malformed("goal version") }
        if let size, size > Goal.maxBytes { throw GoalError.invalid("This goal is too large to read.") }
        let bytes = try await client.request(path: Self.base(workspaceId) + "/files/" + Self.uuid(file.id) + "/versions/" + Self.uuid(versionId) + "/object", appNpub: appNpub)
        guard bytes.count <= Goal.maxBytes else { throw GoalError.invalid("This goal is too large to read.") }
        if let sha, SHA256Hex.of(bytes) != sha { throw DocumentBodyError.integrity }
        return GoalDocument(file: file, versionId: versionId, goal: try Goal.parse(bytes))
    }

    public func createGoal(workspaceId: String, appNpub: String, channelId: String, goal: Goal) async throws -> GoalDocument {
        try goal.validated()
        let bytes = goal.encode(), name = GoalFiles.fileName(goal)
        let objectId = try await store(workspaceId: workspaceId, appNpub: appNpub, bytes: bytes, contentType: Goal.mime, fileName: name, prepared: nil, onPrepared: { _ in })
        let body = try rawJSON(["storage_object_id": objectId, "display_name": name, "metadata": GoalFiles.metadata])
        let reply = try object(try await client.request(method: "POST", path: Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/files", appNpub: appNpub, jsonBody: body), "goal file")
        guard let row = reply["file"] as? [String: Any] else { throw TowerError.malformed("goal file") }
        let file = try FileRecord(raw: rawJSON(row))
        guard file.workspaceId == workspaceId, file.channelId == channelId.lowercased() else { throw TowerError.malformed("goal file") }
        return try await readGoal(workspaceId: workspaceId, appNpub: appNpub, fileId: file.id)
    }

    /// The `GoalTransport` of one workspace as this identity. `requireSigner` throws when the identity is locked.
    public func goalTransport(workspaceId: String, appNpub: String, requireSigner: @escaping @Sendable () async throws -> Void) -> GoalTransport {
        GoalTransport(
            read: { try await self.readGoal(workspaceId: workspaceId, appNpub: appNpub, fileId: $0) },
            save: { fileId, base, bytes, name in
                try await requireSigner()
                let objectId = try await self.store(workspaceId: workspaceId, appNpub: appNpub, bytes: bytes, contentType: Goal.mime, fileName: name, prepared: nil, onPrepared: { _ in })
                let body = try rawJSON(["base_version_id": try Self.uuid(base), "storage_object_id": objectId, "client_mutation_id": UUID().uuidString.lowercased()])
                let reply: (status: Int, body: Data)
                do {
                    reply = try await self.client.exchange(method: "POST", path: Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/versions", appNpub: appNpub, jsonBody: body)
                } catch is CancellationError { throw CancellationError() }
                catch { return .retryable(error.localizedDescription) }
                let o = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
                let code = o["code"] as? String
                switch reply.status {
                case 200, 201:
                    guard let version = (o["version"] as? [String: Any]).flatMap(BoardVersion.init) else { return .retryable("Saved, but the new version could not be identified. Reload to check.") }
                    // Verify the exact version we wrote, not whatever is newest now.
                    if !version.sha256.isEmpty, version.sha256 != SHA256Hex.of(bytes) { throw GoalSaveFailed(message: "The saved goal did not match what was sent. Reload to check.", retryable: false) }
                    return .saved(versionId: version.id)
                case 409 where code == "stale_base_version": return .conflict
                case 408, 425, 429, 500...599: return .retryable("Tower is unavailable (HTTP \(reply.status)); try again.")
                case 401, 403: return .denied("You can’t change this goal.")
                case 404: return .denied("This goal is no longer available to you.")
                default: return .denied("Tower refused the save (HTTP \(reply.status)\(code.map { ", \($0)" } ?? "")).")
                }
            })
    }
}
