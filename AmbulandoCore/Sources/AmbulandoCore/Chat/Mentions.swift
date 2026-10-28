import Foundation

/// What an `@` mention names. People and agents are routed (Tower gets a structured `mentions` entry); the others are
/// record references carried by their body token only, as the web's `@` picker writes them (sol `searchMentions`):
/// `doc`, `task`, `channel`, `scope`, and `chat` for a conversation (`<channel id>#<root message id>`, the web's FD Ref).
public enum MentionType: String, Sendable, Codable, Hashable, CaseIterable {
    case agent, person, doc, task, chat, channel, scope

    /// A person or agent: routed to, and sent in the structured `mentions` list.
    public var isActor: Bool { self == .agent || self == .person }

    /// The word shown under a suggestion.
    public var label: String {
        switch self {
        case .agent: "Agent"
        case .person: "Person"
        case .doc: "Doc"
        case .task: "Task"
        case .chat: "Thread"
        case .channel: "Channel"
        case .scope: "Scope"
        }
    }
}

/// One mention identity. The visible body token and the structured `mentions` entry are both derived
/// from this value, so they can never disagree (sol agent-direct-chat.js / mention-composer.js).
public struct Mention: Sendable, Codable, Hashable {
    public let type: MentionType
    /// The person's or agent's npub, or the record id of a reference (the stored key keeps its original name).
    public let npub: String
    public let label: String

    public init(type: MentionType, npub: String, label: String) {
        self.type = type
        self.npub = npub
        self.label = Mention.cleanLabel(label, fallback: npub)
    }

    public init(member: MemberRecord) { self.init(type: member.mentionType, npub: member.npub, label: member.label) }

    /// Labels cannot contain the token delimiters; Tower caps label length, so keep it short.
    static func cleanLabel(_ label: String, fallback: String) -> String {
        let cleaned = label.replacingOccurrences(of: "[\\[\\]()\\n\\r]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        return String((cleaned.isEmpty ? fallback : cleaned).prefix(80))
    }

    /// `@[Label](mention:type:npub)` — the canonical stored form.
    public var token: String { "@[\(label)](mention:\(type.rawValue):\(npub))" }
    /// What the user sees and edits in the composer.
    public var visible: String { "@\(label)" }
    /// Request entry for `POST …/messages` `mentions` (people and agents only; see `MentionCodec.encode`).
    public var requestObject: [String: String] { ["type": type.rawValue, "npub": npub, "label": label] }
    /// The record id of a reference (the npub of a person or agent).
    public var id: String { npub }
}

/// A rendered piece of a message body.
public enum BodySegment: Sendable, Equatable {
    case text(String)
    case mention(Mention)
    /// A record reference such as `@[Plan](mention:document:<id>)`; rendered as a label, not followed.
    case reference(label: String, kind: String, id: String)
}

public enum MentionCodec {
    // Matches sol record-links.js MENTION_TOKEN_RE (any record kind), non-greedy label.
    private static let pattern = try! NSRegularExpression(pattern: "@\\[([^\\]]+)\\]\\(mention:([A-Za-z_][A-Za-z0-9_-]*):([^)\\s]+)\\)")

    public static func segments(_ body: String) -> [BodySegment] {
        let ns = body as NSString
        var out: [BodySegment] = []
        var cursor = 0
        for match in pattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor { out.append(.text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))) }
            let label = ns.substring(with: match.range(at: 1)), kind = ns.substring(with: match.range(at: 2)), id = ns.substring(with: match.range(at: 3))
            if let type = MentionType(rawValue: kind), type.isActor { out.append(.mention(Mention(type: type, npub: id, label: label))) }
            else { out.append(.reference(label: label, kind: kind, id: id)) }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { out.append(.text(ns.substring(from: cursor))) }
        return out
    }

    /// Plain-text preview with tokens shown as `@Label`.
    public static func plain(_ body: String) -> String {
        segments(body).map {
            switch $0 {
            case .text(let t): t
            case .mention(let m): m.visible
            case .reference(let label, _, _): label
            }
        }.joined()
    }

    /// Converts composer text (visible `@Label` tokens) plus the mentions the user picked into the wire body and the
    /// structured list. A picked mention whose visible text was edited away is dropped, never sent invisibly. Record
    /// references become their canonical token in the body; only people and agents are in the structured list.
    public static func encode(text: String, selected: [Mention]) -> (body: String, mentions: [Mention]) {
        var body = text
        var used: [Mention] = []
        var seen = Set<String>()
        // Longest labels first so "@Ann Lee" is not consumed by "@Ann".
        for mention in selected.sorted(by: { $0.visible.count > $1.visible.count }) where !seen.contains(mention.npub) {
            guard let range = visibleRange(of: mention, in: body) else { continue }
            body.replaceSubrange(range, with: mention.token)
            seen.insert(mention.npub)
            used.append(mention)
        }
        let order = selected.map(\.npub)
        used.sort { (order.firstIndex(of: $0.npub) ?? 0) < (order.firstIndex(of: $1.npub) ?? 0) }
        return (body, used.filter(\.type.isActor))
    }

    /// Finds `@Label` not already inside a canonical token and not followed by more name characters.
    static func visibleRange(of mention: Mention, in body: String) -> Range<String.Index>? {
        var search = body.startIndex..<body.endIndex
        while let range = body.range(of: mention.visible, range: search) {
            let insideToken = range.lowerBound > body.startIndex && body[body.index(before: range.lowerBound)] == "["
            let next = range.upperBound < body.endIndex ? body[range.upperBound] : " "
            if !insideToken && !(next.isLetter || next.isNumber) && !body[range.upperBound...].hasPrefix("](mention:") { return range }
            search = range.upperBound..<body.endIndex
        }
        return nil
    }

    /// Composer text for a stored body (used to edit a failed send): tokens become `@Label` and are re-selected.
    public static func decode(body: String) -> (text: String, mentions: [Mention]) {
        var mentions: [Mention] = []
        let text = segments(body).map { segment -> String in
            switch segment {
            case .text(let t): return t
            case .mention(let m): if !mentions.contains(m) { mentions.append(m) }; return m.visible
            case .reference(let label, let kind, let id):
                // A reference the picker can make is edited as its `@Label` (shown as a pill) like a person.
                if let type = MentionType(rawValue: kind) {
                    let m = Mention(type: type, npub: id, label: label)
                    if m.label == label {
                        if !mentions.contains(m) { mentions.append(m) }
                        return m.visible
                    }
                }
                return "@[\(label)](mention:\(kind):\(id))"
            }
        }.joined()
        return (text, mentions)
    }

    /// The picked mentions whose `@Label` is still in the text (what the composer shows as pills).
    public static func present(_ mentions: [Mention], in text: String) -> [Mention] {
        mentions.filter { visibleRange(of: $0, in: text) != nil }
    }

    /// `text` without one mention's `@Label` and the single space after it.
    public static func removing(_ mention: Mention, from text: String) -> String {
        guard var range = visibleRange(of: mention, in: text) else { return text }
        if range.upperBound < text.endIndex, text[range.upperBound] == " " { range = range.lowerBound..<text.index(after: range.upperBound) }
        var out = text
        out.removeSubrange(range)
        return out
    }

    /// One Backspace that deleted a character of a picked mention (`old` became `new`) removes the whole mention, as a pill
    /// would be removed. Nil when the edit was something else (typing, a paste, deleting a space after the name).
    public static func wholeMentionDeletion(old: String, new: String, mentions: [Mention]) -> String? {
        guard new.count == old.count - 1 else { return nil }
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        let deleted = prefix   // index in `old` of the removed character
        guard Array(a[(deleted + 1)...]) == Array(b[deleted...]) else { return nil }
        for mention in mentions {
            guard let range = visibleRange(of: mention, in: old) else { continue }
            let lower = old.distance(from: old.startIndex, to: range.lowerBound), upper = old.distance(from: old.startIndex, to: range.upperBound)
            if deleted >= lower, deleted < upper { return removing(mention, from: old) }
        }
        return nil
    }

    /// The `@query` being typed at the end of the composer, if any (drives the picker).
    public static func activeQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex, let before = text[text.index(before: at)...].first, !(before.isWhitespace || before == "(") { return nil }
        let query = text[text.index(after: at)...]
        guard query.count <= 40, !query.contains(where: { $0.isNewline }), query.filter({ $0 == " " }).count <= 2 else { return nil }
        return String(query)
    }

    /// `activeQuery(in:)`, except that an `@` which begins an already picked mention (`@Rick ` after choosing Rick) is not
    /// a query: choosing from the list closes it, and typing on after the name never reopens it.
    public static func activeQuery(in text: String, excluding picked: [Mention]) -> String? {
        guard let query = activeQuery(in: text), let at = text.lastIndex(of: "@") else { return nil }
        for mention in picked {
            // Encoding/pills bind the picked value to its first complete visible occurrence. A later
            // @Rick Smith or @Rick-Jones is a new query even though its prefix names the same person.
            if let range = visibleRange(of: mention, in: text), range.lowerBound == at { return nil }
        }
        return query
    }

    /// Replaces the trailing `@query` with the mention's visible text and a trailing space.
    public static func complete(_ text: String, with mention: Mention) -> String {
        guard activeQuery(in: text) != nil, let at = text.lastIndex(of: "@") else { return text + mention.visible + " " }
        return String(text[..<at]) + mention.visible + " "
    }
}
