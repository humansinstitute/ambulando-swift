import Foundation

/// Published generic native-v1 table transport. Authentication remains the connection's user/agent signer.
public struct GoalsRelationalRepository: Sendable {
    public let api: TowerAPI
    public let workspaceId: String
    public let workspaceOwner: String
    public let appNpub: String
    public let channelId: String
    public let owner: String
    var cache: LocalContentSnapshot?
    var requireWriteSigner: (@Sendable () async throws -> Void)?
    public init(api: TowerAPI, workspaceId: String, workspaceOwner: String, appNpub: String, channelId: String, owner: String) {
        self.api = api; self.workspaceId = workspaceId; self.workspaceOwner = workspaceOwner
        self.appNpub = appNpub; self.channelId = channelId; self.owner = owner
    }
    public struct Snapshot: Sendable {
        public let generation: String
        public let authority: JSONValue
        public let tables: [String: [JSONValue]]
        /// Generic server status controls the writer. The app marker is migration provenance only.
        public var mode: String { "relational" }
        public func documents(workspaceId: String, channelId: String, owner: String) throws -> [GoalDocument] {
            try GoalsRelationalRows(goals: tables["goals"] ?? [], checkpoints: tables["goal_checkpoints"] ?? [], associations: tables["goal_associations"] ?? [])
                .documents(workspaceId: workspaceId, channelId: channelId, owner: owner)
        }
    }
    private func request(_ action: String, _ body: JSONValue) async throws -> JSONValue {
        guard NostrKeys.isValidNpub(workspaceOwner), NostrKeys.isValidNpub(appNpub), lowerUUID(workspaceId) == workspaceId,
              lowerUUID(channelId) == channelId, ["query", "batch", "status", "read"].contains(action) else { throw TowerError.unsafePath }
        let path = "/api/v4/workspaces/\(workspaceOwner)/apps/\(appNpub)/db/native-v1/\(workspaceId)/\(action)"
        if action == "batch" { try await requireWriteSigner?() }
        return try JSONValue.parse(try await api.client.request(method: "POST", path: path, appNpub: appNpub, jsonBody: body.serialized()))
    }

    /// UUID-only references resolve their stored channel through the server's normal row ACL, without a File projection.
    public static func resolve(api: TowerAPI, workspaceId: String, workspaceOwner: String, appNpub: String, id: String) async throws -> GoalsRelationalRepository? {
        guard lowerUUID(id) == id else { throw TowerError.unsafePath }
        let probe = GoalsRelationalRepository(api: api, workspaceId: workspaceId, workspaceOwner: workspaceOwner, appNpub: appNpub, channelId: id, owner: "")
        let result: JSONValue
        do { result = try await probe.request("read", .object([("version", .int(1)), ("table", .string("goals")), ("id", .string(id))])) }
        catch TowerError.http(let status, let code, _) where status == 404 && [nil, "not_found", "namespace_not_available", "row_not_found"].contains(code) { return nil }
        guard result["version"] == .int(1), let row = result["row"], let channel = result["channel_id"]?.stringValue,
              lowerUUID(channel) == channel, row["id"] == .string(id), row["workspace_id"] == .string(workspaceId), row["channel_id"] == .string(channel),
              let owner = row["owner_npub"]?.stringValue, NostrKeys.isValidNpub(owner) else { throw GoalsRelationalRows.invalid }
        return GoalsRelationalRepository(api: api, workspaceId: workspaceId, workspaceOwner: workspaceOwner, appNpub: appNpub, channelId: channel, owner: owner)
    }
    private func query(_ table: String, after: String?, generation: String?) async throws -> JSONValue {
        var body = JSONValue.object([("version", .int(1)), ("channel_id", .string(channelId)), ("table", .string(table)), ("limit", .int(200))])
        if let after { body = body.setting("after", .string(after)) }
        if let generation { body = body.setting("generation", .string(generation)) }
        return try await request("query", body)
    }
    /// No response is treated as an empty successful snapshot. Only an explicit absent namespace/route can mean legacy.
    public func snapshot() async throws -> Snapshot? {
        for attempt in 0..<3 {
            var active = false
            do {
                let status = try await request("status", .object([("channel_id", .string(channelId)), ("content_type", .string(Goal.mime))]))
                guard status["version"] == .int(1), let authority = status["authority"] else { throw GoalsRelationalRows.invalid }
                if authority == .null || authority["mode"] == .string("staging") {
                    if status["fence"]?["active"] == .bool(true) {
                        throw GoalSaveFailed(message: "Goals storage is being updated. Saved goals remain available; changes are paused.", retryable: true)
                    }
                    return nil
                }
                guard authority["mode"] == .string("active"), authority["content_type"] == .string(Goal.mime) else {
                    throw GoalSaveFailed(message: "Goals storage is paused. Saved goals remain available; reconnect before changing them.", retryable: true)
                }
                active = true
                let (generation, tables) = try await GoalsRelationalSnapshot.load(query: { try await self.query($0, after: $1, generation: $2) },
                    tables: ["goals_authority", "goals", "goal_checkpoints", "goal_associations"])
                let authorities = tables["goals_authority"] ?? []
                guard authorities.count == 1, let authority = authorities.first,
                      authority["id"] == .string(channelId), authority["workspace_id"] == .string(workspaceId),
                      authority["channel_id"] == .string(channelId), authority["owner_npub"] == .string(owner),
                      authority["contract_version"] == .int(1), authority["schema_version"] == .string("ambulando-goals-relational-1"),
                      let epoch = authority["epoch"]?.intValue, epoch > 0,
                      ["legacy", "frozen", "relational"].contains(authority["mode"]?.stringValue ?? "") else { throw GoalsRelationalRows.invalid }
                return Snapshot(generation: generation, authority: authority, tables: tables)
            } catch TowerError.http(let status, let code, _) where status == 409 && code == "snapshot_changed" && attempt < 2 { continue }
            catch TowerError.http(let status, let code, _) where !active && status == 404 && (code == "namespace_not_available" || code == "not_found" || code == nil) { return nil }
        }
        throw GoalsRelationalRows.invalid
    }

    /// Every edit includes the parent CAS and immutable normalized history in one idempotent transaction.
    public func save(goal: Goal, id: String, before: Snapshot, actor: String, operationId: String = UUID().uuidString.lowercased()) async throws -> GoalDocument {
        guard before.mode == "relational", lowerUUID(id) == id, lowerUUID(operationId) == operationId else { throw GoalsRelationalRows.invalid }
        try goal.validated()
        let pending = try await cache?.read(pendingSlot).map(JSONValue.parse)
        if try await recoverPending() {
            // The unchanged create form can safely finish with the recovered original UUID, rather than sending a new create.
            if let op = pending?["operations"]?.arrayValue?.first(where: { $0["table"] == .string("goals") && $0["kind"] == .string("insert") }),
               before.tables["goals"]?.contains(where: { $0["id"] == .string(id) }) != true,
               let recoveredId = op["id"]?.stringValue, let fresh = try await snapshot(),
               let document = try fresh.documents(workspaceId: workspaceId, channelId: channelId, owner: owner).first(where: { $0.id == recoveredId }),
               document.goal == goal { return document }
            throw GoalSaveFailed(message: "The previous save was recovered. Refresh Goals before making another change.", retryable: true)
        }
        let prior = before.tables["goals"]?.first { $0["id"] == .string(id) }
        let revision = try prior.map { try GoalsRelationalRows.revision($0) }.flatMap(Int.init) ?? 0
        guard revision < 9_007_199_254_740_991 else { throw GoalsRelationalRows.invalid }
        let now = ISO8601DateFormatter().string(from: Date())
        let rows = Self.rows(goal: goal, id: id, workspace: workspaceId, channel: channelId, owner: owner, revision: revision + 1,
                             createdAt: prior?["created_at"] ?? .string(now), timestamp: now, actor: actor)
        var operations: [JSONValue] = []
        for table in ["goals", "goal_checkpoints", "goal_associations"] {
            let old = (before.tables[table] ?? []).filter { table == "goals" ? $0["id"] == .string(id) : $0["goal_id"] == .string(id) }
            let next = rows[table] ?? []
            for row in next {
                let existing = old.first { $0["id"] == row["id"] }
                var data = Self.omit(row, ["id", "workspace_id", "channel_id", "revision"])
                var op = JSONValue.object([("kind", .string(existing == nil ? "insert" : "update")), ("table", .string(table)), ("id", row["id"]!)])
                if let existing {
                    op = op.setting("expected_revision", .number(try GoalsRelationalRows.revision(existing)))
                    data = Self.omit(data, ["created_at"] + (table == "goals" ? [] : ["goal_id"]))
                }
                operations.append(op.setting("data", data))
            }
            for row in old where !next.contains(where: { $0["id"] == row["id"] }) {
                operations.append(.object([("kind", .string("delete")), ("table", .string(table)), ("id", row["id"]!),
                    ("expected_revision", .number(try GoalsRelationalRows.revision(row)))]))
            }
        }
        let historyId = id + ":v:" + String(revision + 1)
        for (current, history) in [("goals", "goal_history"), ("goal_checkpoints", "goal_checkpoint_history"), ("goal_associations", "goal_association_history")] {
            for row in rows[current] ?? [] {
                var data = Self.omit(row, ["id", "workspace_id", "channel_id", "revision", "created_at"])
                    .setting("content_revision", .int(revision + 1))
                let historyRowId: String
                if current == "goals" { data = data.setting("goal_id", .string(id)); historyRowId = historyId }
                else { data = data.setting("history_id", .string(historyId)); historyRowId = historyId + String(row["id"]!.stringValue!.dropFirst(id.count)) }
                operations.append(.object([("kind", .string("insert")), ("table", .string(history)), ("id", .string(historyRowId)), ("data", data)]))
            }
        }
        let body = JSONValue.object([("version", .int(1)), ("operation_id", .string(operationId)), ("channel_id", .string(channelId)), ("operations", .array(operations))])
        try await cache?.save(pendingSlot, body.serialized())
        // A retry uses this identical body and operation UUID. Unknown outcomes never fall back to File storage.
        var result: JSONValue?
        for attempt in 0..<2 {
            do { result = try await request("batch", body); break }
            catch TowerError.http(let status, let code, _) where status == 409 && code == "row_conflict" {
                try await cache?.save(pendingSlot, JSONValue.null.serialized())
                throw GoalError.conflict("This goal changed elsewhere. Reload before saving again.")
            }
            catch is CancellationError { throw CancellationError() }
            catch { if attempt == 1 { throw error } }
        }
        guard result?["version"] == .int(1), result?["operation_id"] == .string(operationId),
              let results = result?["results"]?.arrayValue, results.count == operations.count else { throw GoalsRelationalRows.invalid }
        let returned = results.filter { $0["table"] == .string("goals") }.compactMap { $0["row"] }
        guard returned.count == 1, returned.first?["id"] == .string(id),
              try GoalsRelationalRows.revision(returned[0]) == String(revision + 1) else { throw GoalsRelationalRows.invalid }
        try await cache?.save(pendingSlot, JSONValue.null.serialized())
        return try GoalsRelationalRows(goals: returned, checkpoints: rows["goal_checkpoints"]!, associations: rows["goal_associations"]!)
            .documents(workspaceId: workspaceId, channelId: channelId, owner: owner)[0]
    }

    private var pendingSlot: String { "goals-pending:" + channelId }
    /// Replays only the sealed exact request, never a reconstructed/new POST. A successful receipt survives relaunch.
    @discardableResult
    public func recoverPending() async throws -> Bool {
        guard let bytes = try await cache?.read(pendingSlot), try JSONValue.parse(bytes) != .null else { return false }
        let body = try JSONValue.parse(bytes)
        guard body["channel_id"] == .string(channelId), body["version"] == .int(1), let operation = body["operation_id"]?.stringValue else { throw GoalsRelationalRows.invalid }
        let result: JSONValue
        do { result = try await request("batch", body) }
        catch TowerError.http(let status, let code, _) where status == 409 && code == "row_conflict" {
            try await cache?.save(pendingSlot, JSONValue.null.serialized())
            throw GoalError.conflict("The pending save conflicted with a newer change. Refresh before saving again.")
        }
        guard result["version"] == .int(1), result["operation_id"] == .string(operation) else { throw GoalsRelationalRows.invalid }
        try await cache?.save(pendingSlot, JSONValue.null.serialized())
        return true
    }

    static func omit(_ value: JSONValue, _ keys: [String]) -> JSONValue { .object((value.objectValue ?? []).filter { !keys.contains($0.0) }) }
    static func rows(goal: Goal, id: String, workspace: String, channel: String, owner: String, revision: Int, createdAt: JSONValue, timestamp: String, actor: String) -> [String: [JSONValue]] {
        let scope: [(String, JSONValue)] = [("workspace_id", .string(workspace)), ("channel_id", .string(channel)), ("owner_npub", .string(owner)), ("revision", .int(revision))]
        let known = Goal.known.union(["focus_rank"])
        var extensions = Self.omit(goal.extra, Array(known))
        // Invalid historical focus ranks stay unknown extensions, matching the shared app mapper.
        if GoalFocus.rank(goal) == nil, let rank = goal.extra["focus_rank"] { extensions = extensions.setting("focus_rank", rank) }
        let parent = JSONValue.object(scope + [
            ("id", .string(id)), ("name", .string(goal.name)), ("description", .string(goal.description)), ("status", .string(goal.status.rawValue)),
            ("start_date", goal.startDate.map(JSONValue.string) ?? .null), ("target_date", goal.targetDate.map(JSONValue.string) ?? .null),
            ("default_channel_id", goal.defaultChannelId.map(JSONValue.string) ?? .null), ("focus_rank", GoalFocus.rank(goal).map(JSONValue.string) ?? .null),
            ("extensions", .string(String(decoding: extensions.serialized(), as: UTF8.self))),
            ("present_fields", .array((goal.toJSON().objectValue ?? []).filter { known.contains($0.0) }.map { .string($0.0) })),
            ("created_at", createdAt), ("updated_at", .string(timestamp)), ("updated_by_npub", .string(actor)), ("tombstoned_at", .null)
        ])
        let cp = goal.checkpoints.enumerated().map { position, value in
            JSONValue.object(scope + [
                ("id", .string(id + ":cp:" + value.id)), ("goal_id", .string(id)), ("checkpoint_id", .string(value.id)), ("title", .string(value.title)),
                ("date", value.date.map(JSONValue.string) ?? .null), ("description", value.description.map(JSONValue.string) ?? .null),
                ("reached", .bool(value.reached)), ("position", .int(position)),
                ("extensions", .string(String(decoding: Self.omit(value.extra, Array(GoalCheckpoint.known)).serialized(), as: UTF8.self))),
                ("present_fields", .array((value.toJSON().objectValue ?? []).filter { GoalCheckpoint.known.contains($0.0) }.map { .string($0.0) }))
            ])
        }
        var refs: [JSONValue] = []
        for (lane, values) in [("link", goal.links), ("pin", goal.pinnedRefs)] {
            refs += values.enumerated().map { position, value in
                JSONValue.object(scope + [
                    ("id", .string(id + ":" + lane + ":" + value.type.rawValue + ":" + value.recordId)), ("goal_id", .string(id)),
                    ("lane", .string(lane)), ("kind", .string(value.type.rawValue)), ("record_id", .string(value.recordId)),
                    ("target_channel_id", value.channelId.map(JSONValue.string) ?? .null), ("position", .int(position)),
                    ("extensions", .string(String(decoding: Self.omit(value.extra, Array(GoalLink.known)).serialized(), as: UTF8.self))),
                    ("present_fields", .array((value.toJSON().objectValue ?? []).filter { GoalLink.known.contains($0.0) }.map { .string($0.0) }))
                ])
            }
        }
        return ["goals": [parent], "goal_checkpoints": cp, "goal_associations": refs]
    }
}
