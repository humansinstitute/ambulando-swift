import Foundation

/// In-process stand-in for the generic Tower routes Goals use: scopes, a scope's channels, members, channel grants, a
/// channel's Files, File reads and versioned saves.
///
/// Like the other sample towers it exists for deterministic tests and the labelled sample-data mode; it is **not** Tower
/// and is never evidence of live behaviour. It follows the rules the Goals client depends on (see docs/goals.md):
/// - every route needs a valid NIP-98 event over the exact URL, method and body bytes;
/// - one owner-private Goals channel (`metadata.system_key = ambulando.goals`) in a "Home" scope, granted to the owner
///   (`manage`) and one agent (`contribute`);
/// - a new File or version takes the bytes of a completed storage upload (`objectBytes`, served by the host's work tower);
/// - a version saved against anything but the current version is `409 stale_base_version`; each File read carries
///   `current_version` with its sha256.
/// It owns only its scope's channel list, its channel and its File ids. The host lists `scopeRow` with its own scopes and
/// gives the owner and agent the actor ids from `actorId(for:)`, so its member list and these grants agree.
public final class SampleGoalsTower: @unchecked Sendable {
    private let lock = NSLock()
    public let workspaceId: String
    public let scopeId: String
    public let channelId: String
    public let ownerActorId = "a0000000-0000-4000-8000-0000000000a1"
    public let agentActorId = "a0000000-0000-4000-8000-0000000000a2"
    public let agentNpub: String
    /// The owner (the sample identity) and the bytes of a completed upload by storage object id.
    public var owner: @Sendable () -> String
    public var objectBytes: (@Sendable (String) -> Data?)?
    private var files: [String: [String: Any]] = [:]
    private var versions: [String: [[String: Any]]] = [:]
    private var clock = 0
    /// Saved versions, for tests (`POST …/versions` that were accepted).
    public private(set) var acceptedSaves = 0
    /// Requests this stand-in answered (any route it owns), for tests that need to know whether Goals asked at all.
    public var requestCount: Int { lock.withLock { answered } }
    private var answered = 0

    public init(workspaceId: String, scopeId: String, channelId: String, agentNpub: String, owner: @escaping @Sendable () -> String) {
        self.workspaceId = workspaceId.lowercased(); self.scopeId = scopeId.lowercased(); self.channelId = channelId.lowercased()
        self.agentNpub = agentNpub; self.owner = owner
    }

    private func stamp() -> String {
        clock += 1
        return String(format: "2026-11-20T09:%02d:%02d.000Z", (clock / 60) % 60, clock % 60)
    }

    /// The "Home" scope row for the host's scope list.
    public var scopeRow: [String: Any] {
        ["id": scopeId, "workspace_id": workspaceId, "name": GoalsSpace.homeScope, "kind": "personal", "row_version": 1, "updated_at": "2026-11-20T09:00:00.000Z"]
    }

    /// The actor id the grants use for the owner or the agent, for the host's member list.
    public func actorId(for npub: String) -> String? {
        npub == owner() ? ownerActorId : npub == agentNpub ? agentActorId : nil
    }

    // MARK: Seeding

    /// Adds a goal File with one version holding `goal`'s canonical bytes; returns its id.
    @discardableResult
    public func seed(_ goal: Goal, id: String = UUID().uuidString.lowercased()) -> String {
        lock.withLock {
            let fileId = id.lowercased()
            files[fileId] = ["id": fileId, "workspace_id": workspaceId, "scope_id": scopeId, "channel_id": channelId,
                             "display_name": GoalFiles.fileName(goal), "content_type": Goal.mime, "metadata": GoalFiles.metadata,
                             "record_state": "active", "deleted_at": NSNull(), "archived_at": NSNull(), "row_version": 1,
                             "created_at": stamp(), "updated_at": stamp()]
            addVersion(fileId, goal.encode())
            return fileId
        }
    }

    /// Goal File ids, in id order.
    public func fileIds() -> [String] { lock.withLock { files.keys.sorted() } }

    /// Soft-deletes a goal File as Tower does: the row stays `active` with `deleted_at` set.
    public func softDelete(_ fileId: String) {
        lock.withLock { files[fileId.lowercased()]?["deleted_at"] = stamp() }
    }

    /// The current goal of a File, for tests.
    public func goal(_ fileId: String) -> Goal? {
        lock.withLock { current(fileId).flatMap { Data(base64Encoded: $0["bytes"] as? String ?? "") }.flatMap { try? Goal.parse($0) } }
    }

    private func current(_ fileId: String) -> [String: Any]? { versions[fileId]?.last }

    private func addVersion(_ fileId: String, _ bytes: Data) {
        let number = (versions[fileId]?.count ?? 0) + 1
        let row: [String: Any] = ["id": UUID().uuidString.lowercased(), "file_id": fileId, "version_number": number, "sha256_hex": SHA256Hex.of(bytes),
                                  "size_bytes": bytes.count, "content_type": Goal.mime, "created_at": stamp(), "bytes": bytes.base64EncodedString()]
        versions[fileId, default: []].append(row)
        files[fileId]?["row_version"] = number
        files[fileId]?["updated_at"] = row["created_at"]
    }

    private func fileOut(_ fileId: String) -> [String: Any]? {
        guard var row = files[fileId], var version = current(fileId) else { return nil }
        version["bytes"] = nil
        row["current_version"] = version
        return row
    }

    // MARK: Routing

    /// Handles a request for these routes, or returns nil for routes it does not own.
    public func handle(_ request: URLRequest) throws -> (Int, Any)? {
        guard let url = request.url else { return nil }
        let base = "/api/v4/flightdeck-pg/workspaces/\(workspaceId)/"
        guard url.path.hasPrefix(base) else { return nil }
        let p = url.path.dropFirst(base.count).split(separator: "/").map(String.init)
        let method = request.httpMethod ?? "GET"
        let owned: Bool = lock.withLock {
            switch p.first {
            case "scopes": return p.count == 3 && p[1] == scopeId && p[2] == "channels"
            case "channels": return p.count == 3 && p[1] == channelId && ["grants", "files"].contains(p[2])
            case "files": return p.count >= 2 && files[p[1]] != nil
            default: return false
            }
        }
        guard owned else { return nil }
        let body = request.httpBody ?? Data()
        guard SampleAuth.verify(request, body: body) else { return (401, ["code": "unauthorized", "error": "invalid NIP-98"]) }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let owner = owner(), bytesOf = objectBytes
        return lock.withLock { answered += 1; return route(p, method: method, object: object, owner: owner, bytesOf: bytesOf) }
    }

    private func error(_ status: Int, _ code: String) -> (Int, Any) { (status, ["code": code, "error": code]) }

    private func route(_ p: [String], method: String, object: [String: Any], owner: String, bytesOf: ((String) -> Data?)?) -> (Int, Any) {
        switch (method, p.count, p[0]) {
        case ("GET", 3, "scopes"):
            return (200, ["channels": [["id": channelId, "workspace_id": workspaceId, "scope_id": scopeId, "name": GoalsSpace.channelName, "kind": "channel",
                                        "metadata": GoalsSpace.metadata(owner: owner), "record_state": "active", "row_version": 1,
                                        "created_at": "2026-11-20T09:00:00.000Z", "updated_at": "2026-11-20T09:00:00.000Z"]], "next_cursor": NSNull()])
        case ("GET", 3, "channels") where p[2] == "grants":
            return (200, ["grants": [["principal_type": "actor", "principal_id": ownerActorId, "access_level": "manage",
                                      "principal": ["actor_id": ownerActorId, "npub": owner, "type": "actor"]],
                                     ["principal_type": "actor", "principal_id": agentActorId, "access_level": "contribute",
                                      "principal": ["actor_id": agentActorId, "npub": agentNpub, "type": "actor"]]]])
        case ("GET", 3, "channels"):
            let rows = files.keys.sorted().compactMap(fileOut)
            return (200, ["files": rows, "next_cursor": NSNull()])
        case ("POST", 3, "channels"):
            guard let objectId = object["storage_object_id"] as? String, let bytes = bytesOf?(objectId) else { return error(400, "validation_error") }
            let id = UUID().uuidString.lowercased()
            files[id] = ["id": id, "workspace_id": workspaceId, "scope_id": scopeId, "channel_id": channelId, "storage_object_id": objectId,
                         "display_name": object["display_name"] as? String ?? "goal.json", "content_type": Goal.mime,
                         "metadata": object["metadata"] ?? [:], "record_state": "active", "deleted_at": NSNull(), "archived_at": NSNull(),
                         "row_version": 1, "created_at": stamp(), "updated_at": stamp()]
            addVersion(id, bytes)
            return (201, ["file": fileOut(id)!])
        case ("GET", 2, "files"):
            return (200, ["file": fileOut(p[1])!])
        case ("GET", 5, "files") where p[2] == "versions" && p[4] == "object":
            guard let v = versions[p[1]]?.first(where: { $0["id"] as? String == p[3] }), let bytes = Data(base64Encoded: v["bytes"] as? String ?? "") else {
                return error(404, "file_version_object_not_found")
            }
            return (200, bytes)
        case ("POST", 3, "files") where p[2] == "versions":
            guard let base = object["base_version_id"] as? String, let objectId = object["storage_object_id"] as? String,
                  let bytes = bytesOf?(objectId) else { return error(400, "validation_error") }
            guard current(p[1])?["id"] as? String == base else { return error(409, "stale_base_version") }
            addVersion(p[1], bytes)
            acceptedSaves += 1
            var version = current(p[1])!
            version["bytes"] = nil
            return (201, ["version": version])
        default:
            return error(404, "not_found")
        }
    }
}
