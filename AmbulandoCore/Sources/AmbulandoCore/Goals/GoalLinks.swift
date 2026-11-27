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
        let scopesById = Dictionary(try scopes(workspaceId: workspaceId).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let scopeNames = scopesById.mapValues(\.name)
        let channelsById = Dictionary(try channels(workspaceId: workspaceId).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func parentAvailable(_ channelId: String?) -> Bool {
            guard let channelId, let channel = channelsById[channelId], let scope = scopesById[channel.scopeId] else { return false }
            return goalRecordAvailable(channel.raw) && goalRecordAvailable(scope.raw)
        }
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
                guard let t = try task(workspaceId: workspaceId, id: link.recordId), parentAvailable(t.channelId), goalRecordAvailable(t.raw) else { return unavailable(link) }
                return ResolvedGoalLink(link: link, title: t.title, location: place(t.channelId, t.scopeId), detail: TaskState(rawValue: t.state)?.label ?? t.state, channelId: t.channelId, available: true)
            case .doc:
                guard let d = try doc(workspaceId: workspaceId, id: link.recordId), !d.archived, parentAvailable(d.channelId), goalRecordAvailable(d.raw) else { return unavailable(link) }
                return ResolvedGoalLink(link: link, title: d.title, location: place(d.channelId, d.scopeId), detail: "Document", channelId: d.channelId, available: true)
            case .file:
                guard let f = try file(workspaceId: workspaceId, id: link.recordId), !f.archived, parentAvailable(f.channelId), goalRecordAvailable(f.raw) else { return unavailable(link) }
                return ResolvedGoalLink(link: link, title: f.displayName, location: place(f.channelId, f.scopeId), detail: "File", channelId: f.channelId, available: true)
            case .chat:
                guard let t = try thread(workspaceId: workspaceId, id: link.recordId), !t.deleted, !t.archived, parentAvailable(t.channelId), goalRecordAvailable(t.raw) else { return unavailable(link) }
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


extension StoreReader {
    /// Exact native metadata discovery; unrelated saved rows cannot exhaust the general list's limit.
    public func associatedGoalLinks(workspaceId: String, goalId: String, explicit: [GoalLink]) async throws -> [ResolvedGoalLink] {
        var refs = explicit
        var seen = Set(refs.map(\.key))
        for (table, type) in [("threads", GoalLinkType.chat), ("docs", .doc), ("files", .file)] {
            let statement = try db.prepare("""
                SELECT r.id,r.channel_id,r.raw,c.raw,s.raw FROM \(table) r
                JOIN channels c ON c.workspace_id=r.workspace_id AND c.id=r.channel_id
                JOIN scopes s ON s.workspace_id=c.workspace_id AND s.id=c.scope_id
                WHERE r.workspace_id=? AND r.archived=0
                AND json_extract(CAST(r.raw AS TEXT),'$.metadata.ambulando_goal.goal_file_id')=?
                ORDER BY r.updated_at DESC,r.id LIMIT 501
                """)
            try statement.bind([.text(workspaceId), .text(goalId)])
            var candidates = 0
            while try statement.step() {
                candidates += 1
                guard candidates <= 500 else { throw GoalError.invalid("More than 500 goal outputs match this type. The associated-work view is incomplete.") }
                guard let raw = try? JSONValue.parse(statement.blob(2)), goalRecordAvailable(raw),
                      goalRecordAvailable(statement.blob(3)), goalRecordAvailable(statement.blob(4)),
                      (try? GoalAssociation.read(raw["metadata"] ?? .object([]))) == goalId,
                      let id = statement.text(0) else { continue }
                let link = GoalLink(type: type, recordId: id, channelId: statement.text(1))
                if seen.insert(link.key).inserted { refs.append(link) }
            }
        }
        return try await resolveGoalLinks(workspaceId: workspaceId, links: refs)
    }
}
