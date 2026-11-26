import Foundation

/// A goal link as this device can currently show it. The title and location come from the source record in the local
/// store, never from the goal, so a rename or move is reflected and nothing is copied. A source this identity cannot
/// read (missing, access removed, not synced yet) is `available == false` with no content; the link stays removable.
public struct ResolvedGoalLink: Sendable, Equatable, Identifiable {
    public let link: GoalLink
    public let title: String?
    /// "Channel · Scope" of the source record, when known.
    public let location: String?
    /// A short state such as "In progress" or "Document".
    public let detail: String?
    public let channelId: String?
    public let available: Bool
    public var id: String { link.type.rawValue + ":" + link.recordId }

    public init(link: GoalLink, title: String?, location: String?, detail: String?, channelId: String?, available: Bool) {
        self.link = link; self.title = title; self.location = location; self.detail = detail; self.channelId = channelId; self.available = available
    }
}

extension StoreReader {
    public func resolveGoalLinks(workspaceId: String, links: [GoalLink]) async throws -> [ResolvedGoalLink] {
        guard !links.isEmpty else { return [] }
        let scopeNames = Dictionary(try scopes(workspaceId: workspaceId).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let channelsById = Dictionary(try channels(workspaceId: workspaceId).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func place(_ channelId: String?, _ scopeId: String?) -> String? {
            let channel = channelId.flatMap { channelsById[$0] }
            let scope = (scopeId ?? channel?.scopeId).flatMap { scopeNames[$0] }
            let parts = [channel?.name, scope].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        func unavailable(_ link: GoalLink) -> ResolvedGoalLink {
            ResolvedGoalLink(link: link, title: nil, location: nil, detail: nil, channelId: link.channelId, available: false)
        }
        return try links.map { link in
            switch link.type {
            case .task:
                guard let t = try task(workspaceId: workspaceId, id: link.recordId) else { return unavailable(link) }
                return ResolvedGoalLink(link: link, title: t.title, location: place(t.channelId, t.scopeId), detail: TaskState(rawValue: t.state)?.label ?? t.state, channelId: t.channelId, available: true)
            case .doc:
                guard let d = try doc(workspaceId: workspaceId, id: link.recordId), !d.archived else { return unavailable(link) }
                return ResolvedGoalLink(link: link, title: d.title, location: place(d.channelId, d.scopeId), detail: "Document", channelId: d.channelId, available: true)
            case .file:
                guard let f = try file(workspaceId: workspaceId, id: link.recordId), !f.archived else { return unavailable(link) }
                return ResolvedGoalLink(link: link, title: f.displayName, location: place(f.channelId, f.scopeId), detail: "File", channelId: f.channelId, available: true)
            case .chat:
                guard let t = try thread(workspaceId: workspaceId, id: link.recordId), !t.deleted, !t.archived else { return unavailable(link) }
                var title = t.title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                if title == nil, let source = t.sourceMessageId, let body = try message(workspaceId: workspaceId, id: source)?.body.split(separator: "\n").first {
                    title = String(body.prefix(80))
                }
                title = title ?? "Conversation"
                return ResolvedGoalLink(link: link, title: title, location: place(t.channelId, nil), detail: "Chat", channelId: t.channelId, available: true)
            }
        }
    }
}
