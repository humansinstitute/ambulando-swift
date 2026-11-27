import Foundation

/// Ambulando's normalized rows. These are a transport/cache projection, never a second canonical writer.
public struct GoalsRelationalRows: Sendable, Equatable {
    public var goals: [JSONValue]
    public var checkpoints: [JSONValue]
    public var associations: [JSONValue]
    public init(goals: [JSONValue], checkpoints: [JSONValue], associations: [JSONValue]) {
        self.goals = goals; self.checkpoints = checkpoints; self.associations = associations
    }

    public func documents(workspaceId: String, channelId: String, owner: String) throws -> [GoalDocument] {
        var ids = Set<String>()
        for row in goals {
            try Self.scope(row, workspaceId, channelId, owner)
            guard let id = row["id"]?.stringValue, lowerUUID(id) == id, ids.insert(id).inserted else { throw Self.invalid }
        }
        for row in checkpoints + associations {
            try Self.scope(row, workspaceId, channelId, owner)
            guard let parent = row["goal_id"]?.stringValue, ids.contains(parent) else { throw Self.invalid }
        }
        return try goals.compactMap { row in
            guard row["tombstoned_at"] == nil || row["tombstoned_at"] == .null else { return nil }
            let id = row["id"]!.stringValue!
            let revision = try Self.revision(row)
            var value = try Self.extensions(row)
            for key in ["name", "description", "status"] {
                guard let text = row[key]?.stringValue else { throw Self.invalid }
                value = value.setting(key, .string(text))
            }
            value = value.setting("schema", .string(Goal.schema)).setting("schema_version", .int(Goal.version))
            for key in ["start_date", "target_date", "focus_rank", "default_channel_id"] {
                if let field = row[key], field != .null {
                    guard field.stringValue != nil else { throw Self.invalid }
                    value = value.setting(key, field)
                }
            }
            let children = try Self.ordered(checkpoints.filter { $0["goal_id"] == .string(id) })
            let refs = associations.filter { $0["goal_id"] == .string(id) }
            value = value.setting("checkpoints", .array(try children.map { cp in
                _ = try Self.revision(cp)
                guard let cpId = cp["checkpoint_id"]?.stringValue, let title = cp["title"]?.stringValue,
                      let reached = cp["reached"]?.boolValue else { throw Self.invalid }
                var result = try Self.extensions(cp).setting("id", .string(cpId)).setting("title", .string(title)).setting("reached", .bool(reached))
                for key in ["date", "description"] {
                    if let field = cp[key], field != .null { guard field.stringValue != nil else { throw Self.invalid }; result = result.setting(key, field) }
                }
                return result
            }))
            guard refs.allSatisfy({ ["link", "pin"].contains($0["lane"]?.stringValue ?? "") }) else { throw Self.invalid }
            for (lane, key) in [("link", "links"), ("pin", "pinned_refs")] {
                value = value.setting(key, .array(try Self.ordered(refs.filter { $0["lane"] == .string(lane) }).map { ref in
                    _ = try Self.revision(ref)
                    guard let kind = ref["kind"]?.stringValue, let record = ref["record_id"]?.stringValue else { throw Self.invalid }
                    var result = try Self.extensions(ref).setting("type", .string(kind)).setting("record_id", .string(record))
                    if let field = ref["target_channel_id"], field != .null { guard field.stringValue != nil else { throw Self.invalid }; result = result.setting("channel_id", field) }
                    return result
                }))
            }
            let goal = try Goal.parse(value.serialized())
            // Compatibility identity shell. No storage object or File head is represented as current SQL content.
            let shell = JSONValue.object([("id", .string(id)), ("workspace_id", .string(workspaceId)), ("channel_id", .string(channelId)),
                ("display_name", .string(GoalFiles.fileName(goal))), ("content_type", .string(Goal.mime)),
                ("metadata", .object([("goal", .object([("schema_version", .int(1))]))])),
                ("created_at", row["created_at"] ?? .string("")), ("updated_at", row["updated_at"] ?? .string(""))])
            return GoalDocument(file: try FileRecord(raw: shell.serialized()), versionId: revision, goal: goal, storage: .relational)
        }
    }

    static let invalid = GoalError.invalid("The Goals database snapshot is incomplete or invalid. Saved content was retained; connect to refresh.")
    static func revision(_ row: JSONValue) throws -> String {
        let text = row["revision"]?.stringValue ?? row["revision"]?.intValue.map(String.init)
        guard let text, let number = Int64(text), number > 0, String(number) == text else { throw invalid }
        return text
    }
    private static func scope(_ row: JSONValue, _ workspace: String, _ channel: String, _ owner: String) throws {
        guard row.isObject, row["workspace_id"] == .string(workspace), row["channel_id"] == .string(channel), row["owner_npub"] == .string(owner) else { throw invalid }
    }
    private static func extensions(_ row: JSONValue) throws -> JSONValue {
        guard let text = row["extensions"]?.stringValue, text.utf8.count <= Goal.maxBytes else { throw invalid }
        let value = try JSONValue.parse(text)
        guard value.isObject else { throw invalid }
        return value
    }
    private static func ordered(_ rows: [JSONValue]) throws -> [JSONValue] {
        let positions = try rows.map { row -> Int in
            guard let p = row["position"]?.intValue, p >= 0 else { throw invalid }; return p
        }
        guard Set(positions).count == rows.count, positions.sorted() == Array(0..<rows.count) else { throw invalid }
        return rows.sorted { $0["position"]!.intValue! < $1["position"]!.intValue! }
    }
}

/// All tables/pages must be from one generation. A concurrent commit restarts the entire read, never just a child page.
public enum GoalsRelationalSnapshot {
    public typealias Query = @Sendable (_ table: String, _ after: String?, _ generation: String?) async throws -> JSONValue
    public static func load(query: Query, tables: [String] = ["goals", "goal_checkpoints", "goal_associations"], generation initial: String? = nil) async throws -> (String, [String: [JSONValue]]) {
        var generation = initial, result: [String: [JSONValue]] = [:]
        for table in tables {
            var after: String?, seen = Set<String>(), rows: [JSONValue] = []
            for page in 0..<1000 {
                try Task.checkCancellation()
                let response = try await query(table, after, generation)
                guard response["version"] == .int(1), let current = response["generation"]?.stringValue,
                      !current.isEmpty, generation == nil || generation == current,
                      let batch = response["rows"]?.arrayValue, batch.count <= 200,
                      let more = response["has_more"]?.boolValue else { throw GoalsRelationalRows.invalid }
                generation = current
                for row in batch {
                    guard let id = row["id"]?.stringValue, after == nil || id > after!, seen.insert(id).inserted else { throw GoalsRelationalRows.invalid }
                    after = id; rows.append(row)
                }
                if !more {
                    guard response["next_after"] == nil || response["next_after"] == .null else { throw GoalsRelationalRows.invalid }
                    result[table] = rows; break
                }
                guard !batch.isEmpty, response["next_after"]?.stringValue == after, page < 999 else { throw GoalsRelationalRows.invalid }
            }
        }
        guard let generation else { throw GoalsRelationalRows.invalid }
        if let first = tables.first {
            let check = try await query(first, nil, generation)
            guard check["version"] == .int(1), check["generation"] == .string(generation) else { throw GoalsRelationalRows.invalid }
        }
        return (generation, result)
    }
}
