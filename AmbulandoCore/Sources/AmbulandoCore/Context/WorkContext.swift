import Foundation

/// The shared data context of the app: workspace → scope → channel, as chosen in the sidebar (Sol
/// `selectWorkContextScope` / `selectWorkContextChannel` / `openAllScopesOverview`). Chat, tasks, documents and files
/// read and write within it. The workspace is held by the selection itself; this value is stored per connection and
/// workspace, so it never refers to another workspace's records.
///
/// - `scopeId == nil`: Home, all scopes of the workspace (reads span them; a write still needs a channel).
/// - `scopeId` only: the scope's home (its channels).
/// - `scopeId` + `channelId`: one channel.
public struct WorkContext: Sendable, Equatable, Hashable, Codable {
    public var scopeId: String?
    public var channelId: String?

    public init(scopeId: String? = nil, channelId: String? = nil) {
        self.scopeId = scopeId
        self.channelId = scopeId == nil ? nil : channelId
    }

    public static let home = WorkContext()

    public var isHome: Bool { scopeId == nil }

    public static func stateKey(connectionId: String, workspaceId: String) -> String { "context:\(connectionId):\(workspaceId)" }

    public func encoded() -> String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }

    public static func decode(_ text: String?) -> WorkContext? {
        guard let text, let value = try? JSONDecoder().decode(WorkContext.self, from: Data(text.utf8)) else { return nil }
        return WorkContext(scopeId: value.scopeId, channelId: value.channelId)
    }

    /// The context with anything the user can no longer see removed: a channel that is gone (deleted, or access lost)
    /// falls back to its scope; a scope that is gone falls back to Home. A channel is kept only under its own scope.
    public func resolved(scopes: [ScopeRecord], channels: [ChannelRecord]) -> WorkContext {
        guard let scopeId, scopes.contains(where: { $0.id == scopeId }) else { return .home }
        guard let channelId else { return WorkContext(scopeId: scopeId) }
        return channels.contains(where: { $0.id == channelId && $0.scopeId == scopeId }) ? self : WorkContext(scopeId: scopeId)
    }

    /// Whether a record in `channelId` (under `scopeId`) belongs to this context.
    public func contains(scopeId recordScope: String?, channelId recordChannel: String?) -> Bool {
        guard let scopeId else { return true }
        if let channelId { return recordChannel == channelId }
        return recordScope == scopeId
    }
}

/// One scope and its channels in the sidebar.
public struct SidebarGroup: Sendable, Equatable, Identifiable {
    public let scope: ScopeRecord
    public let channels: [ChannelRecord]
    public let isDirectMessages: Bool
    public var id: String { scope.id }
}

/// Port of Sol's sidebar projection (`sidebar-navigation.js`, `channel-order.js`, `dm-scope.js`, `channel-labels.js`)
/// over the records Tower returns to this member. Tower lists only the scopes and channels the member can read, so
/// anything absent here is not shown and not queried.
public enum SidebarNavigation {
    /// Direct-message groups first, then the other scopes in the member's personal order (Tower `scope-order`), then any
    /// scope not in it. Channels by their persisted position within the scope, then creation time and id.
    public static func groups(scopes: [ScopeRecord], channels: [ChannelRecord], personalOrder: [String]) -> [SidebarGroup] {
        var seenScopes = Set<String>()
        let visible = scopes.filter { seenScopes.insert($0.id).inserted }
        let ordered = ScopeOrdering.apply(visible, order: personalOrder, id: \.id)
        var seenChannels = Set<String>()
        var byScope: [String: [ChannelRecord]] = [:]
        for channel in channels where seenScopes.contains(channel.scopeId) && seenChannels.insert(channel.id).inserted {
            byScope[channel.scopeId, default: []].append(channel)
        }
        let groups = ordered.map { scope in
            SidebarGroup(scope: scope, channels: sortChannels(byScope[scope.id] ?? []), isDirectMessages: isDirectMessageScope(scope))
        }
        return groups.filter(\.isDirectMessages) + groups.filter { !$0.isDirectMessages }
    }

    /// Sol `compareChannelsByScopePosition`: an integer position ≥ 1 first (ascending), then creation time, then id.
    public static func sortChannels(_ channels: [ChannelRecord]) -> [ChannelRecord] {
        let keyed = channels.map { ($0, ChannelDetails(raw: $0.raw)) }
        return keyed.sorted { a, b in
            let pa = persisted(a.0.position), pb = persisted(b.0.position)
            if pa != nil || pb != nil {
                guard let pa else { return false }
                guard let pb else { return true }
                if pa != pb { return pa < pb }
            }
            if a.1.createdAt != b.1.createdAt { return a.1.createdAt < b.1.createdAt }
            return a.0.id < b.0.id
        }.map(\.0)
    }

    private static func persisted(_ position: Double?) -> Int? {
        guard let position, position >= 1, position.rounded() == position else { return nil }
        return Int(position)
    }

    public static func isDirectMessageScope(_ scope: ScopeRecord) -> Bool {
        scope.kind?.lowercased() == "dm" || scope.name.trimmingCharacters(in: .whitespaces).lowercased() == "dms"
    }

    public static func isDirectMessageChannel(_ channel: ChannelRecord) -> Bool {
        if channel.kind?.lowercased() == "dm" { return true }
        let details = ChannelDetails(raw: channel.raw)
        if details.description.lowercased().hasPrefix("dm:") { return true }
        let title = channel.name.trimmingCharacters(in: .whitespaces).lowercased()
        if title.hasPrefix("dm:") { return true }
        return Set(details.participants).count == 2 && title.contains("dm")
    }

    /// Sol `resolveChannelLabel`: a channel's title, or for a direct message the other participants' names
    /// ("Note to self" when the viewer is the only participant).
    public static func label(_ channel: ChannelRecord, viewerNpub: String?, names: [String: String]) -> String {
        let title = channel.name.trimmingCharacters(in: .whitespaces)
        let direct = isDirectMessageChannel(channel)
        if !title.isEmpty && !direct { return title }
        let participants = participants(channel)
        if direct, participants.count == 1, participants.first == viewerNpub { return "Note to self" }
        let others = participants.filter { $0 != viewerNpub }
        if !others.isEmpty { return others.map { names[$0] ?? compact($0) }.joined(separator: ", ") }
        if direct {
            let stripped = title.replacingOccurrences(of: "^DM:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            if !stripped.isEmpty, stripped.range(of: "^npub1[0-9a-z]+$", options: [.regularExpression, .caseInsensitive]) == nil { return stripped }
            return "Direct message"
        }
        return title.isEmpty ? String(channel.id.prefix(8)) : title
    }

    public static func participants(_ channel: ChannelRecord) -> [String] {
        let details = ChannelDetails(raw: channel.raw)
        if !details.participants.isEmpty { return Array(Set(details.participants)).sorted() }
        if details.description.lowercased().hasPrefix("dm:") {
            return Array(Set(details.description.dropFirst(3).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
        }
        let regex = try? NSRegularExpression(pattern: "npub1[0-9a-z]{20,}", options: [.caseInsensitive])
        let range = NSRange(channel.name.startIndex..., in: channel.name)
        let found = regex?.matches(in: channel.name, range: range).compactMap { Range($0.range, in: channel.name).map { String(channel.name[$0]) } } ?? []
        return Array(Set(found)).sorted()
    }

    static func compact(_ npub: String) -> String { npub.count <= 16 ? npub : "\(npub.prefix(10))...\(npub.suffix(6))" }

    /// Sol "Unread & Active": channels, in sidebar order, that have unread or attention-needing activity.
    public static func unreadChannels(_ groups: [SidebarGroup], unreadChannelIds: Set<String>) -> [ChannelRecord] {
        var seen = Set<String>()
        return groups.flatMap(\.channels).filter { unreadChannelIds.contains($0.id) && seen.insert($0.id).inserted }
    }
}

/// Channel fields kept only in the stored Tower payload.
struct ChannelDetails {
    var createdAt = ""
    var description = ""
    var participants: [String] = []

    init(raw: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return }
        createdAt = object["created_at"] as? String ?? ""
        description = (object["description"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        participants = (object["participant_npubs"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
