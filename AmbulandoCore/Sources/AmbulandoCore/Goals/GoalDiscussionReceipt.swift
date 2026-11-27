import Foundation

/// Durable routing for one possibly committed start. Reads never retry creation or clear this receipt.
public struct GoalDiscussionReceipt: Sendable, Equatable {
    public let workspaceId: String
    public let goalFileId: String
    public let channelId: String
    public let requestId: String
    public init(workspaceId: String, goalFileId: String, channelId: String, requestId: String) throws {
        guard [workspaceId, goalFileId, channelId, requestId].allSatisfy({ lowerUUID($0) == $0 }) else { throw GoalError.invalid("The pending discussion receipt contains an invalid identity.") }
        self.workspaceId = workspaceId; self.goalFileId = goalFileId; self.channelId = channelId; self.requestId = requestId
    }
    public func encode() -> String {
        String(decoding: JSONValue.object([("format", .string("ambulando.goal_discussion_pending")), ("version", .int(1)),
            ("workspace_id", .string(workspaceId)), ("goal_file_id", .string(goalFileId)), ("channel_id", .string(channelId)), ("request_id", .string(requestId))]).serialized(), as: UTF8.self)
    }
    public static func parse(_ raw: String, workspaceId: String, goalFileId: String) throws -> Self {
        guard raw.utf8.count <= 4096 else { throw GoalError.invalid("The pending discussion receipt is too large.") }
        let value = try JSONValue.parse(raw)
        let fields = ["format", "version", "workspace_id", "goal_file_id", "channel_id", "request_id"]
        guard let pairs = value.objectValue, pairs.count == fields.count, Set(pairs.map(\.0)) == Set(fields),
              value["format"] == .string("ambulando.goal_discussion_pending"), value["version"] == .int(1),
              let w = value["workspace_id"]?.stringValue, let g = value["goal_file_id"]?.stringValue,
              let c = value["channel_id"]?.stringValue, let r = value["request_id"]?.stringValue,
              w == workspaceId, g == goalFileId else { throw GoalError.invalid("The pending discussion belongs to another goal or has an unavailable format.") }
        return try Self(workspaceId: w, goalFileId: g, channelId: c, requestId: r)
    }
    public static func key(connectionId: String, workspaceId: String, goalFileId: String) throws -> String {
        guard [connectionId, workspaceId, goalFileId].allSatisfy({ lowerUUID($0) == $0 }) else { throw GoalError.invalid("The pending discussion storage target is invalid.") }
        return "goal.discussion.pending.\(connectionId).\(workspaceId).\(goalFileId)"
    }
}
