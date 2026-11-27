import Foundation

/// App-owned native-record reference; workspace and access always come from the containing record.
public enum GoalAssociation {
    public static let key = "ambulando_goal"

    public static func read(_ metadata: JSONValue) throws -> String? {
        guard let value = metadata[key] else { return nil }
        guard value.isObject, value["version"] == .int(1), let id = value["goal_file_id"]?.stringValue,
              lowerUUID(id) == id else { throw GoalError.invalid("The goal association is invalid or needs a newer app.") }
        return id
    }

    public static func metadata(goalFileId: String, base: JSONValue = .object([])) throws -> JSONValue {
        guard base.isObject, lowerUUID(goalFileId) == goalFileId else { throw GoalError.invalid("The goal reference is invalid.") }
        let current = try read(base)
        guard current == nil || current == goalFileId else { throw GoalError.conflict("This record already belongs to another goal.") }
        if current == goalFileId { return base }
        return base.setting(key, .object([("version", .int(1)), ("goal_file_id", .string(goalFileId))]))
    }
}

extension TowerAPI {
    /// Resolve a primary reference, independently of explicit goal mentions. A 403 permits identity-only propagation,
    /// never private goal content or ACL changes. Accessible wrong-kind, missing and unsupported goals are refused.
    public func threadGoalMetadata(workspaceId: String, appNpub: String, threadId: String, expectedChannelId: String? = nil,
                                   resolveGoal: (@Sendable (String) async throws -> GoalDocument)? = nil) async throws -> JSONValue {
        let row = try await thread(workspaceId: workspaceId, appNpub: appNpub, threadId: threadId)
        guard row.workspaceId == workspaceId, row.id == threadId, !row.archived, !row.deleted,
              expectedChannelId == nil || row.channelId == expectedChannelId else { throw TowerError.malformed("goal discussion identity") }
        let raw = try JSONValue.parse(row.raw)
        guard let id = try GoalAssociation.read(raw["metadata"] ?? .object([])) else { return .object([]) }
        do {
            if let resolveGoal { _ = try await resolveGoal(id) }
            else { _ = try await readGoal(workspaceId: workspaceId, appNpub: appNpub, fileId: id) }
        }
        catch TowerError.http(let status, _, _) where status == 403 { /* Keep only the readable thread's reference. */ }
        return try GoalAssociation.metadata(goalFileId: id)
    }

    /// Generic thread creation is not idempotent. Persist the local receipt in beforeCreate and never replay an uncertain POST.
    public func createGoalDiscussion(workspaceId: String, appNpub: String, goalFileId: String, channelId: String, scopeId: String,
                                     expectedDefault: String?, requestId: String, beforeCreate: @Sendable () async throws -> Void = {},
                                     resolveGoal: (@Sendable (String) async throws -> GoalDocument)? = nil) async throws -> ThreadRecord {
        guard lowerUUID(requestId) == requestId else { throw TowerError.unsafePath }
        let goal: Goal
        if let resolveGoal { goal = try await resolveGoal(goalFileId).goal }
        else { goal = try await readGoal(workspaceId: workspaceId, appNpub: appNpub, fileId: goalFileId).goal }
        guard goal.status != .archived else { throw GoalError.conflict("Restore this goal before discussing it.") }
        guard goal.defaultChannelId == expectedDefault else { throw GoalError.conflict("The default channel changed elsewhere. Reopen Discuss goal.") }
        guard try await scopes(workspaceId: workspaceId, appNpub: appNpub).contains(where: { $0.id == scopeId && $0.workspaceId == workspaceId && goalRecordAvailable($0.raw) }) else { throw GoalError.invalid("This channel’s scope is unavailable.") }
        guard try await channels(workspaceId: workspaceId, scopeId: scopeId, appNpub: appNpub).contains(where: { $0.id == channelId && $0.scopeId == scopeId && $0.workspaceId == workspaceId && goalRecordAvailable($0.raw) }) else { throw GoalError.invalid("This channel is unavailable. Choose a channel explicitly.") }
        let metadata = try GoalAssociation.metadata(goalFileId: goalFileId).setting("ambulando_discussion_request_id", .string(requestId))
        let body = JSONValue.object([("title", .string(String(goal.name.prefix(120)))), ("metadata", metadata)]).serialized()
        try await beforeCreate()
        let data = try await client.request(method: "POST", path: Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/threads", appNpub: appNpub, jsonBody: body)
        guard let raw = try JSONValue.parse(data)["thread"], raw.isObject else { throw TowerError.malformed("goal discussion") }
        let row = try ThreadRecord(raw: raw.serialized())
        guard row.workspaceId == workspaceId, row.channelId == channelId, try GoalAssociation.read(raw["metadata"] ?? .object([])) == goalFileId else { throw TowerError.malformed("goal discussion") }
        return row
    }

    /// Look up an uncertain start in the original channel. No create retry is performed; an incomplete list is disclosed.
    public func findGoalDiscussion(workspaceId: String, appNpub: String, channelId: String, goalFileId: String, requestId: String) async throws -> ThreadRecord? {
        guard lowerUUID(goalFileId) == goalFileId, lowerUUID(requestId) == requestId else { throw TowerError.unsafePath }
        let data = try await client.request(path: Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/threads",
            query: [URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "include_archived", value: "true")], appNpub: appNpub)
        let root = try JSONValue.parse(data)
        guard let values = root["threads"]?.arrayValue else { throw TowerError.malformed("goal discussions") }
        guard values.count < 200, root["next_cursor"] == nil || root["next_cursor"] == .null || root["next_cursor"] == .string("") else {
            throw GoalError.invalid("The discussion list is incomplete. Check the original channel before starting another discussion.")
        }
        var matches: [ThreadRecord] = []
        for value in values {
            let row = try ThreadRecord(raw: value.serialized())
            guard row.workspaceId == workspaceId, row.channelId == channelId else { throw TowerError.malformed("goal discussion identity") }
            guard !row.deleted, !row.archived, value["metadata"]?["ambulando_discussion_request_id"]?.stringValue == requestId else { continue }
            if try GoalAssociation.read(value["metadata"] ?? .object([])) == goalFileId { matches.append(row) }
        }
        guard matches.count <= 1 else { throw GoalError.invalid("Several discussions match this start. Choose the original in its channel.") }
        return matches.first
    }
}

/// Shared availability predicate over native metadata, without treating a cached record as an access grant.
func goalRecordAvailable(_ bytes: Data) -> Bool {
    guard let raw = try? JSONValue.parse(bytes) else { return false }
    return goalRecordAvailable(raw)
}
func goalRecordAvailable(_ raw: JSONValue) -> Bool {
    let state = raw["record_state"]?.stringValue
    return raw["access_removed"]?.boolValue != true && (raw["archived_at"] == nil || raw["archived_at"] == .null) && (raw["deleted_at"] == nil || raw["deleted_at"] == .null)
        && !["archived", "deleted", "revoked", "access_removed"].contains(state ?? "")
}
