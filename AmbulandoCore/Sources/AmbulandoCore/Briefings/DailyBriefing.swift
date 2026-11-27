import Foundation

/// Ambulando-owned v1 journal carried by a generic private versioned File. Read-only on native clients.
public struct DailyBriefing: Sendable, Equatable, Decodable {
    public static let mime = "application/vnd.ambulando.briefing+json"
    public static let systemKey = "ambulando.briefings"
    public static let timezone = "Australia/Perth"
    public struct Link: Sendable, Equatable, Decodable {
        public let type: String
        public let recordId: String
        public let channelId: String?
        public let label: String
        enum CodingKeys: String, CodingKey { case type, recordId = "record_id", channelId = "channel_id", label }
    }
    public struct Entry: Sendable, Equatable, Decodable {
        public let generatedAt: String
        public let paragraphs: [String]
        public let links: [Link]
        public let coverageNote: String?
        enum CodingKeys: String, CodingKey { case generatedAt = "generated_at", paragraphs, links, coverageNote = "coverage_note" }
    }
    public let schema: String
    public let schemaVersion: Int
    public let workspaceId: String
    public let ownerNpub: String
    public let authorNpub: String
    public let timeZone: String
    public let entries: [String: Entry]
    enum CodingKeys: String, CodingKey {
        case schema, schemaVersion = "schema_version", workspaceId = "workspace_id", ownerNpub = "owner_npub"
        case authorNpub = "author_npub", timeZone = "timezone", entries
    }

    public static func parse(_ bytes: Data, workspace: String, owner: String, author: String, now: Date = Date()) throws -> Self {
        guard bytes.count <= 4 * 1024 * 1024 else { throw BriefingError.invalid }
        let journal: Self
        do { journal = try JSONDecoder().decode(Self.self, from: bytes) } catch { throw BriefingError.invalid }
        guard journal.schema == "ambulando.briefing", journal.schemaVersion == 1, journal.timeZone == timezone,
              journal.workspaceId == workspace, journal.ownerNpub == owner, journal.authorNpub == author,
              UUID(uuidString: workspace) != nil, NostrKeys.isValidNpub(owner), NostrKeys.isValidNpub(author), owner != author else { throw BriefingError.invalid }
        guard journal.entries.count <= 3660 else { throw BriefingError.invalid }
        for (key, entry) in journal.entries {
            guard validDay(key), key <= day(now), let generated = timestamp(entry.generatedAt), day(generated) == key,
                  (1...2).contains(entry.paragraphs.count), entry.paragraphs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 4000 }),
                  entry.links.count <= 20, (entry.coverageNote == nil || (!(entry.coverageNote!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && entry.coverageNote!.utf16.count <= 1000)),
                  entry.links.allSatisfy({ ["task", "thread", "doc", "file"].contains($0.type) && UUID(uuidString: $0.recordId) != nil && ($0.channelId == nil || UUID(uuidString: $0.channelId!) != nil) && ($0.type != "thread" || $0.channelId != nil) && $0.label.utf16.count <= 160 && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw BriefingError.invalid }
        }
        return journal
    }

    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timezone)!; return c
    }
    public static func day(_ date: Date = Date()) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func validDay(_ text: String) -> Bool {
        guard text.utf8.count == 10, let date = dayDate(text) else { return false }; return day(date) == text
    }
    public static func dayDate(_ text: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar
        f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false; return f.date(from: text)
    }
    public static func timestamp(_ text: String) -> Date? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

public enum BriefingError: Error, LocalizedError, Sendable, Equatable {
    case invalid, unsafe, ambiguous, unavailable, incomplete
    public var errorDescription: String? {
        switch self {
        case .invalid: "The saved briefing could not be verified."
        case .unsafe: "The briefing’s private access could not be verified."
        case .ambiguous: "More than one briefing source was found. Rick needs to review the setup."
        case .unavailable: "Rick’s briefing is not available yet."
        case .incomplete: "The briefing source list is incomplete. Try again."
        }
    }
}

/// A metadata label confers no authority. Both metadata identities and the complete explicit grants must match.
public enum BriefingAccess {
    public static func active(_ bytes: Data) -> Bool {
        guard let o = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
        return !["deleted", "archived"].contains(o["record_state"] as? String ?? "") && o["archived_at"] as? String == nil && o["deleted_at"] as? String == nil && o["access_removed"] as? Bool != true
    }
    public static func matchesMIME(_ text: String?) -> Bool {
        text?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == DailyBriefing.mime
    }
    public static func metadata(_ bytes: Data, owner: String) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let m = o["metadata"] as? [String: Any], let b = m["briefing"] as? [String: Any],
              b["schema_version"] as? Int == 1, b["owner_npub"] as? String == owner,
              let author = b["author_npub"] as? String, NostrKeys.isValidNpub(author), author != owner else { return nil }
        return author
    }
    public static func isChannel(_ c: ChannelRecord, owner: String) -> Bool {
        guard c.kind == "channel", active(c.raw), metadata(c.raw, owner: owner) != nil,
              let o = try? JSONSerialization.jsonObject(with: c.raw) as? [String: Any],
              o["record_state"] as? String != "deleted", o["archived_at"] as? String == nil, o["is_archived"] as? Bool != true,
              let m = o["metadata"] as? [String: Any] else { return false }
        return m["system_key"] as? String == DailyBriefing.systemKey
    }
    public static func verify(grants: [GoalsChannelGrant], members: [MemberRecord], owner: String, author: String) throws {
        guard let human = members.first(where: { $0.npub == owner }),
              let agent = members.first(where: { $0.npub == author }), grants.count == 2 else { throw BriefingError.unsafe }
        var seen = Set<String>()
        for g in grants {
            guard !g.isGroup else { throw BriefingError.unsafe }
            let person: MemberRecord
            if g.actorId == human.actorId || g.npub == owner { person = human }
            else if g.actorId == agent.actorId || g.npub == author { person = agent }
            else { throw BriefingError.unsafe }
            guard g.actorId == person.actorId, g.npub == nil || g.npub == person.npub,
                  seen.insert(person.npub).inserted,
                  person.npub == owner ? g.access == "manage" : ["contribute", "manage"].contains(g.access ?? "") else { throw BriefingError.unsafe }
        }
        guard seen == Set([owner, author]) else { throw BriefingError.unsafe }
    }
}
