import Foundation

/// One page of `GET /workspaces/:w/channels/:c/messages` (order `created_at ASC, id ASC`, opaque forward cursor).
public struct MessagePage: Sendable, Equatable {
    public let messages: [MessageRecord]
    public let nextCursor: String?
}

/// Chat routes, read from Tower `src/routes/flightdeck-pg.ts`. Paths are built only from validated UUIDs.
extension TowerAPI {
    static func uuid(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw TowerError.unsafePath }
        return value
    }

    public static let messagePageLimit = 200   // Tower parseLimit caps at 200

    public func messagesPage(workspaceId: String, appNpub: String, channelId: String, threadId: String? = nil,
                             cursor: String?, limit: Int = messagePageLimit) async throws -> MessagePage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let threadId { query.append(URLQueryItem(name: "thread_id", value: try Self.uuid(threadId))) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await client.request(path: try Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/messages",
                                            query: query, appNpub: appNpub)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["messages"] as? [[String: Any]] else { throw TowerError.malformed("messages") }
        let messages = try rows.map { try MessageRecord(raw: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])) }
        // A page that does not belong to the requested channel is never materialised.
        guard messages.allSatisfy({ $0.workspaceId == workspaceId && $0.channelId == channelId && (threadId == nil || $0.threadId == threadId) }) else {
            throw TowerError.malformed("messages")
        }
        let next = object["next_cursor"] as? String
        return MessagePage(messages: messages, nextCursor: next?.isEmpty == false ? next : nil)
    }

    /// Thread metadata for a channel. Tower returns one page (≤ 200) with `next_cursor: null`, so a full page is
    /// reported as possibly incomplete and is never used to remove local threads.
    public func threads(workspaceId: String, appNpub: String, channelId: String) async throws -> (threads: [ThreadRecord], complete: Bool) {
        let data = try await client.request(path: try Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/threads",
                                            query: [URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "include_archived", value: "true")],
                                            appNpub: appNpub)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["threads"] as? [[String: Any]] else { throw TowerError.malformed("threads") }
        let threads = try rows.map { try ThreadRecord(raw: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])) }
        return (threads.filter { $0.workspaceId == workspaceId && $0.channelId == channelId }, rows.count < 200)
    }

    public func thread(workspaceId: String, appNpub: String, threadId: String) async throws -> ThreadRecord {
        let data = try await client.request(path: try Self.base(workspaceId) + "/threads/" + Self.uuid(threadId), appNpub: appNpub)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let row = object["thread"] as? [String: Any] else {
            throw TowerError.malformed("thread")
        }
        return try ThreadRecord(raw: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
    }

    public func members(workspaceId: String, appNpub: String) async throws -> [MemberRecord] {
        let data = try await client.request(path: try Self.base(workspaceId) + "/members", appNpub: appNpub)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["members"] as? [[String: Any]] else { throw TowerError.malformed("members") }
        return rows.compactMap { try? MemberRecord(workspaceId: workspaceId, raw: JSONSerialization.data(withJSONObject: $0)) }
    }

    /// The actor's own scope order (`GET /me/scope-order`); scopes not listed keep their default order after these.
    public func scopeOrder(workspaceId: String, appNpub: String) async throws -> [String] {
        let data = try await client.request(path: try Self.base(workspaceId) + "/me/scope-order", appNpub: appNpub)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let order = object["scope_order"] as? [String: Any] else { throw TowerError.malformed("scope order") }
        return ((order["scope_ids"] as? [String]) ?? []).filter { UUID(uuidString: $0) != nil }.map { $0.lowercased() }
    }
}
