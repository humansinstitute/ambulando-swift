import Foundation

/// The `fd` object Tower adds to an APNs alert (contract v1). It names where the notification points and carries no
/// message text: the visible `aps.alert` is generic by default, so nothing here is a preview.
public struct PushPayload: Sendable, Equatable {
    public static let version = 1

    public let origin: TowerOrigin
    public let workspaceId: String
    public let category: String?
    public let outboxEventId: String?
    public let channelId: String?
    public let threadId: String?
    public let taskId: String?
    public let docId: String?

    public enum ParseError: Error, Equatable {
        case missing
        case unsupportedVersion
        case invalidOrigin
        case invalidId(String)
    }

    /// Parses `userInfo` from a notification response. An unknown version, a non-HTTPS origin or a non-UUID id is
    /// refused rather than guessed; ids are lowercased so they compare with stored records.
    public static func parse(userInfo: [AnyHashable: Any]) throws -> PushPayload {
        guard let fd = userInfo["fd"] as? [String: Any] else { throw ParseError.missing }
        guard (fd["v"] as? Int) == version else { throw ParseError.unsupportedVersion }
        guard let rawOrigin = fd["origin"] as? String, let origin = try? TowerOrigin(rawOrigin) else { throw ParseError.invalidOrigin }
        func id(_ key: String) throws -> String? {
            guard let value = fd[key], !(value is NSNull) else { return nil }
            guard let text = value as? String, UUID(uuidString: text) != nil else { throw ParseError.invalidId(key) }
            return text.lowercased()
        }
        guard let workspaceId = try id("workspace_id") else { throw ParseError.invalidId("workspace_id") }
        return PushPayload(origin: origin, workspaceId: workspaceId, category: fd["category"] as? String,
                           outboxEventId: try id("outbox_event_id"), channelId: try id("channel_id"),
                           threadId: try id("thread_id"), taskId: try id("task_id"), docId: try id("doc_id"))
    }
}
