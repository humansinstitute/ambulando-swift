import Foundation

/// A public Nostr profile (kind 0) cached for one connection, keyed by the author's public key.
///
/// Only the fields the client shows are kept, each trimmed and bounded. `status` records whether the last relay check
/// found a profile; a `missing` row is a negative cache entry so absent profiles are not asked for on every launch.
public struct ProfileRecord: Sendable, Equatable {
    public enum Status: String, Sendable { case found, missing }

    public let pubkey: String
    public let npub: String
    public var displayName: String?
    public var name: String?
    public var picture: String?
    public var nip05: String?
    public var eventId: String?
    public var eventCreatedAt: Int?
    public var status: Status
    public var checkedAt: Date

    public init(pubkey: String, npub: String, displayName: String? = nil, name: String? = nil, picture: String? = nil, nip05: String? = nil,
                eventId: String? = nil, eventCreatedAt: Int? = nil, status: Status, checkedAt: Date) {
        self.pubkey = pubkey; self.npub = npub; self.displayName = displayName; self.name = name; self.picture = picture
        self.nip05 = nip05; self.eventId = eventId; self.eventCreatedAt = eventCreatedAt; self.status = status; self.checkedAt = checkedAt
    }

    /// The profile's own name, `display_name` before `name` (sol `resolveProfileName`).
    public var preferredName: String? { displayName ?? name }

    /// Builds a record from a verified kind-0 event. Unknown, non-string and oversized fields are dropped.
    public static func from(event: NostrEvent, checkedAt: Date) -> ProfileRecord? {
        guard event.kind == 0, let npub = NostrKeys.npub(publicKeyHex: event.pubkey) else { return nil }
        let fields = NostrProfileContent.parse(event.content)
        return ProfileRecord(pubkey: event.pubkey, npub: npub, displayName: fields.displayName, name: fields.name, picture: fields.picture?.absoluteString,
                             nip05: fields.nip05, eventId: event.id, eventCreatedAt: event.created_at, status: .found, checkedAt: checkedAt)
    }

    /// NIP-01 replaceable-event order: the newer `created_at` wins; on a tie the lower event id wins.
    public func isNewer(than other: ProfileRecord) -> Bool {
        guard let mine = eventCreatedAt, let mineId = eventId else { return false }
        guard let theirs = other.eventCreatedAt, let theirId = other.eventId else { return true }
        return mine > theirs || (mine == theirs && mineId < theirId)
    }
}

/// Field extraction from kind-0 `content` (a JSON object as text), following sol `people-profiles-manager.js`.
public enum NostrProfileContent {
    public static let maxContentBytes = 64 * 1024
    static let maxNameLength = 120
    static let maxNip05Length = 256

    public struct Fields: Sendable, Equatable {
        public var displayName: String?
        public var name: String?
        public var picture: URL?
        public var nip05: String?
    }

    public static func parse(_ content: String) -> Fields {
        guard content.utf8.count <= maxContentBytes, let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Fields() }
        func text(_ keys: [String], limit: Int) -> String? {
            for key in keys { if let value = clean(object[key], limit: limit) { return value } }
            return nil
        }
        // The first picture field holding an address the app will fetch (sol takes the first non-empty one).
        let picture = ["picture", "image", "avatar_url", "avatarUrl", "avatar"].lazy
            .compactMap { clean(object[$0], limit: AvatarURLPolicy.maxLength).flatMap(AvatarURLPolicy.validate) }.first
        return Fields(displayName: text(["display_name", "displayName"], limit: maxNameLength),
                      name: text(["name", "username"], limit: maxNameLength),
                      picture: picture,
                      nip05: text(["nip05"], limit: maxNip05Length))
    }

    /// A single-line, trimmed string within `limit` characters, or nil.
    static func clean(_ value: Any?, limit: Int) -> String? {
        guard let raw = value as? String else { return nil }
        let line = raw.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit)) : line
    }
}

/// Which avatar addresses the app will fetch. Avatars come from a profile, which anyone can write, so only plain
/// HTTPS to a public host name is accepted: no credentials in the URL, no IP literals or local names (the request
/// must not reach the user's own network), and a bounded length.
public enum AvatarURLPolicy {
    public static let maxLength = 2048

    public static func validate(_ value: String) -> URL? {
        guard value.count <= maxLength, let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), isPublicHostName(host), let url = components.url else { return nil }
        return url
    }

    static func isPublicHostName(_ host: String) -> Bool {
        guard !host.isEmpty, host.contains("."), !host.hasSuffix(".") else { return false }
        // IPv6 literals ("[::1]") and IPv4 literals ("10.0.0.1", also written as 0x0a.1 or a bare number).
        if host.contains(":") || host.hasPrefix("[") { return false }
        let labels = host.split(separator: ".")
        if let last = labels.last, last.allSatisfy(\.isNumber) || last.hasPrefix("0x") { return false }
        for suffix in ["localhost", "local", "internal", "home.arpa", "lan", "onion"] {
            if host == suffix || host.hasSuffix("." + suffix) { return false }
        }
        return true
    }
}

/// How a person is shown: name, initials for the fallback avatar, and the avatar address if one is known.
public struct PersonDisplay: Sendable, Equatable, Hashable {
    public enum NameSource: String, Sendable { case workspace, agent, message, nostr, npub }

    public let npub: String
    public let name: String
    public let initials: String
    public let avatarURL: URL?
    public let nameSource: NameSource

    public init(npub: String, name: String, avatarURL: URL?, nameSource: NameSource) {
        self.npub = npub; self.name = name; self.initials = PersonInitials.of(name); self.avatarURL = avatarURL; self.nameSource = nameSource
    }

    /// Someone the directory does not know: short npub and initials, no avatar.
    public static func unknown(_ npub: String) -> PersonDisplay { PersonDisplay(npub: npub, name: shortLabel(npub), avatarURL: nil, nameSource: .npub) }
}

/// Whether a name from Tower or a profile can be shown as a person's name. Tower fills some actors with a setup
/// placeholder ("Workspace Creator", ...) and some clients store the key itself as the name; neither may hide a real
/// public profile name, so both count as no name.
public enum PersonNamePolicy {
    /// Tower `flightdeck-pg-authorization.ts` `setupActorDisplayNames` plus the names its upsert treats as replaceable.
    static let placeholders: Set<String> = ["workspace creator", "flight deck pg creator", "flight deck pg workspace owner",
                                            "flight deck pg smoke viewer", "flight deck pg collaborator"]

    public static func usable(_ value: String?) -> String? {
        guard let name = NostrProfileContent.clean(value, limit: NostrProfileContent.maxNameLength) else { return nil }
        let lower = name.lowercased()
        if placeholders.contains(lower) { return nil }
        // A full or shortened npub ("npub1abc…xyz", "npub1abc...xyz") or a 64-character hex key.
        if lower.hasPrefix("npub1"), !lower.contains(" ") { return nil }
        if lower.count == 64, lower.allSatisfy(\.isHexDigit) { return nil }
        return name
    }
}

/// Initials as sol `utils/naming.js getInitials`: first letters of the first two words, otherwise the first two
/// characters, upper-cased; `?` for an empty label.
public enum PersonInitials {
    public static func of(_ label: String) -> String {
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "?" }
        // Like the web helper, but a word's first letter or digit ("You (sample)" → "YS", not "Y(").
        func lead(_ word: Substring) -> Character? { word.first { $0.isLetter || $0.isNumber } }
        let parts = cleaned.split(whereSeparator: \.isWhitespace).filter { lead($0) != nil }
        if parts.count >= 2, let a = lead(parts[0]), let b = lead(parts[1]) { return "\(a)\(b)".uppercased() }
        let letters = cleaned.filter { $0.isLetter || $0.isNumber }
        return String((letters.isEmpty ? cleaned : letters).prefix(2)).uppercased()
    }
}

/// Everything the app knows about the people of one workspace, resolved once per screen load (off the main actor).
///
/// Membership comes only from Tower (`members`, `workspace_agents`); a public profile decorates a person the client
/// already sees, never adds one. Name order follows sol `getSenderName`: the public profile (`display_name`, then
/// `name`), then the workspace's own name for the member (Tower `display_name`), the agent's name, the name Tower
/// attached to the message, then the short npub. Tower names that are setup placeholders or just a key are skipped
/// (`PersonNamePolicy`). Avatar: an agent's Tower `avatar_url`, then the profile picture, else initials.
public struct PeopleDirectory: Sendable, Equatable {
    public struct AgentInfo: Sendable, Equatable {
        public let name: String
        public let avatarURL: String?
        public init(name: String, avatarURL: String?) { self.name = name; self.avatarURL = avatarURL }
    }

    private var resolved: [String: PersonDisplay] = [:]
    public private(set) var memberNpubs: Set<String> = []
    private var agentNpubs: Set<String> = []

    public init() {}

    /// A workspace agent (Tower `workspace_agents`, or a member of kind agent).
    public func isAgent(_ npub: String) -> Bool { agentNpubs.contains(npub) }

    public init(members: [MemberRecord], agents: [String: AgentInfo], profiles: [ProfileRecord], extra: [String] = []) {
        let profileByNpub = Dictionary(profiles.map { ($0.npub, $0) }, uniquingKeysWith: { a, b in a.isNewer(than: b) ? a : b })
        var memberName: [String: String] = [:]
        agentNpubs = Set(agents.keys).union(members.filter { $0.kind == "agent" }.map(\.npub))
        for m in members {
            memberNpubs.insert(m.npub)
            if let name = PersonNamePolicy.usable(m.displayName) { memberName[m.npub] = name }
        }
        let everyone = Set(members.map(\.npub)).union(agents.keys).union(profileByNpub.keys).union(extra)
        for npub in everyone {
            let profile = profileByNpub[npub]
            let agent = agents[npub]
            let avatar = agent?.avatarURL.flatMap(AvatarURLPolicy.validate) ?? profile?.picture.flatMap(AvatarURLPolicy.validate)
            let (name, source): (String, PersonDisplay.NameSource) =
                if let name = profile?.preferredName.flatMap(PersonNamePolicy.usable) { (name, .nostr) }
                else if let name = memberName[npub] { (name, .workspace) }
                else if let name = agent.flatMap({ PersonNamePolicy.usable($0.name) }) { (name, .agent) }
                else { (shortLabel(npub), .npub) }
            resolved[npub] = PersonDisplay(npub: npub, name: name, avatarURL: avatar, nameSource: source)
        }
    }

    /// The person for `npub`. `senderLabel` is the name Tower attached to a message (`created_by_actor_label`); it is
    /// used only when neither the public profile nor the workspace directory names the person.
    public func person(_ npub: String?, senderLabel: String? = nil) -> PersonDisplay {
        guard let npub, !npub.isEmpty else {
            return PersonDisplay(npub: "", name: PersonNamePolicy.usable(senderLabel) ?? "Unknown", avatarURL: nil, nameSource: .message)
        }
        let base = resolved[npub] ?? .unknown(npub)
        guard base.nameSource == .npub, let label = PersonNamePolicy.usable(senderLabel) else { return base }
        return PersonDisplay(npub: npub, name: label, avatarURL: base.avatarURL, nameSource: .message)
    }

    public func name(_ npub: String?, senderLabel: String? = nil) -> String { person(npub, senderLabel: senderLabel).name }

    /// Name map for screens that only show text (tasks, documents).
    public var names: [String: String] { resolved.mapValues(\.name) }

    public var count: Int { resolved.count }
}
