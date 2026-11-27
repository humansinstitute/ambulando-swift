import Foundation

/// A personal goal: name, description, optional date-only start/target, an ordered checkpoint timeline and links to
/// existing records. Stored as the JSON content of one ordinary File (`application/vnd.ambulando.goal+json`).
/// Links are references only: titles, locations and access are always read from the source record, never copied here.
/// Progress is checkpoints reached; nothing is inferred from linked tasks. The format is the same one Android writes
/// (`ambulando.goal` v1), so either client can open and edit what the other saved.
public struct Goal: Sendable, Equatable {
    public var name: String
    public var description: String
    public var startDate: String?
    public var targetDate: String?
    public var status: GoalStatus
    public var checkpoints: [GoalCheckpoint]
    public var links: [GoalLink]
    /// Unknown top-level fields from a newer writer, written back untouched.
    public var extra: JSONValue
    public var defaultChannelId: String?
    public var pinnedRefs: [GoalLink]

    public init(name: String, description: String, startDate: String? = nil, targetDate: String? = nil, status: GoalStatus = .active,
                checkpoints: [GoalCheckpoint] = [], links: [GoalLink] = [], extra: JSONValue = .object([]), defaultChannelId: String? = nil, pinnedRefs: [GoalLink] = []) {
        self.name = name; self.description = description; self.startDate = startDate; self.targetDate = targetDate
        self.status = status; self.checkpoints = checkpoints; self.links = links; self.extra = extra
        self.defaultChannelId = defaultChannelId; self.pinnedRefs = pinnedRefs
    }

    public static let schema = "ambulando.goal"
    public static let version = 1
    public static let mime = "application/vnd.ambulando.goal+json"
    public static let maxBytes = 256 * 1024
    public static let maxName = 120
    public static let maxDescription = 2000
    public static let maxCheckpoints = 100
    public static let maxLinks = 500
    public static let maxPinnedRefs = 100
    static let known: Set<String> = ["schema", "schema_version", "name", "description", "start_date", "target_date", "status", "checkpoints", "links", "default_channel_id", "pinned_refs"]

    public var reachedCount: Int { checkpoints.filter(\.reached).count }

    /// The first checkpoint not yet reached while the goal is active; shown as "Next".
    public var nextCheckpointId: String? { status == .active ? checkpoints.first { !$0.reached }?.id : nil }

    public func toJSON() -> JSONValue {
        var pairs: [(String, JSONValue)] = (extra.objectValue ?? []).filter { !Self.known.contains($0.0) }
        pairs.append(("schema", .string(Self.schema))); pairs.append(("schema_version", .int(Self.version)))
        pairs.append(("name", .string(name))); pairs.append(("description", .string(description)))
        if let startDate { pairs.append(("start_date", .string(startDate))) }
        if let targetDate { pairs.append(("target_date", .string(targetDate))) }
        pairs.append(("status", .string(status.rawValue)))
        pairs.append(("checkpoints", .array(checkpoints.map { $0.toJSON() })))
        pairs.append(("links", .array(links.map { $0.toJSON() })))
        if let defaultChannelId { pairs.append(("default_channel_id", .string(defaultChannelId))) }
        if !pinnedRefs.isEmpty { pairs.append(("pinned_refs", .array(pinnedRefs.map { $0.toJSON() }))) }
        return .object(pairs)
    }

    public func encode() -> Data { toJSON().serialized() }

    /// Reads stored bytes. An unsupported or malformed goal is refused, never partially shown or rewritten.
    public static func parse(_ bytes: Data) throws -> Goal {
        guard bytes.count <= maxBytes else { throw GoalError.invalid("This goal is too large to read.") }
        guard let root = try? JSONValue.parse(bytes), root.isObject else { throw GoalError.invalid("This goal could not be read.") }
        guard root["schema"]?.stringValue == schema else { throw GoalError.invalid("This is not a goal.") }
        guard root["schema_version"]?.intValue == version else { throw GoalError.unsupported }
        guard let status = GoalStatus(rawValue: try root.string("status") ?? "") else { throw GoalError.invalid("Unknown goal status.") }
        let goal = Goal(
            name: try root.string("name") ?? "", description: try root.string("description") ?? "",
            startDate: try root.string("start_date"), targetDate: try root.string("target_date"), status: status,
            checkpoints: try root.array("checkpoints").map(GoalCheckpoint.parse),
            links: try root.array("links").map(GoalLink.parse),
            extra: .object((root.objectValue ?? []).filter { !known.contains($0.0) }),
            defaultChannelId: try root.string("default_channel_id"), pinnedRefs: try root.array("pinned_refs").map(GoalLink.parse))
        return try goal.validated()
    }

    public static func create(name: String, description: String, startDate: String? = nil, targetDate: String? = nil) throws -> Goal {
        try Goal(name: name.trimmingCharacters(in: .whitespacesAndNewlines), description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                 startDate: startDate.blankToNil, targetDate: targetDate.blankToNil).validated()
    }

    /// A strict `yyyy-MM-dd` calendar date, or `nil`. No time zone is involved, so a date never shifts between devices.
    public static func parseDate(_ value: String) -> DateComponents? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: y, month: m, day: d)
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return components
    }

    static func requireDate(_ value: String) throws {
        guard parseDate(value) != nil else { throw GoalError.invalid("Dates use the form 2026-12-18.") }
    }

    /// Throws `GoalError.invalid` with a user-readable message when a rule is broken.
    @discardableResult
    public func validated() throws -> Goal {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GoalError.invalid("A goal needs a name.") }
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GoalError.invalid("A goal needs a description.") }
        guard name.utf16.count <= Self.maxName else { throw GoalError.invalid("The name is too long.") }
        guard description.utf16.count <= Self.maxDescription else { throw GoalError.invalid("The description is too long.") }
        if let startDate { try Self.requireDate(startDate) }
        if let targetDate { try Self.requireDate(targetDate) }
        if let startDate, let targetDate, targetDate < startDate { throw GoalError.invalid("The target date is before the start date.") }
        guard checkpoints.count <= Self.maxCheckpoints else { throw GoalError.invalid("Too many checkpoints.") }
        guard Set(checkpoints.map(\.id)).count == checkpoints.count else { throw GoalError.invalid("Checkpoint identities repeat.") }
        try checkpoints.forEach { try $0.validate() }
        guard links.count <= Self.maxLinks else { throw GoalError.invalid("Too many linked records.") }
        guard Set(links.map(\.key)).count == links.count else { throw GoalError.invalid("A record is linked twice.") }
        try links.forEach { try $0.validate() }
        if let defaultChannelId, lowerUUID(defaultChannelId) != defaultChannelId { throw GoalError.invalid("The default channel identity is invalid.") }
        guard pinnedRefs.count <= Self.maxPinnedRefs else { throw GoalError.invalid("Too many pinned references.") }
        guard Set(pinnedRefs.map(\.key)).count == pinnedRefs.count else { throw GoalError.invalid("A reference is pinned twice.") }
        try pinnedRefs.forEach { ref in
            guard ref.type == .doc || ref.type == .file else { throw GoalError.invalid("Only Docs and Files can be pinned.") }
            try ref.validate()
        }
        return self
    }
}

public enum GoalStatus: String, Sendable, CaseIterable {
    case active, completed, archived
    /// Sort rank: active goals first.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public struct GoalCheckpoint: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var date: String?
    public var description: String?
    public var reached: Bool
    public var extra: JSONValue

    public init(id: String = GoalCheckpoint.newId(), title: String, date: String? = nil, description: String? = nil, reached: Bool = false, extra: JSONValue = .object([])) {
        self.id = id; self.title = title; self.date = date; self.description = description; self.reached = reached; self.extra = extra
    }

    static let known: Set<String> = ["id", "title", "date", "description", "reached"]
    static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,64}$")
    public static func newId() -> String { UUID().uuidString.lowercased() }

    func validate() throws {
        guard Self.idPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil else { throw GoalError.invalid("A checkpoint identity is invalid.") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GoalError.invalid("A checkpoint needs a title.") }
        guard title.utf16.count <= 120 else { throw GoalError.invalid("A checkpoint title is too long.") }
        guard (description?.utf16.count ?? 0) <= 500 else { throw GoalError.invalid("A checkpoint description is too long.") }
        if let date { try Goal.requireDate(date) }
    }

    func toJSON() -> JSONValue {
        var pairs: [(String, JSONValue)] = (extra.objectValue ?? []).filter { !Self.known.contains($0.0) }
        pairs.append(("id", .string(id))); pairs.append(("title", .string(title)))
        if let date { pairs.append(("date", .string(date))) }
        if let description { pairs.append(("description", .string(description))) }
        pairs.append(("reached", .bool(reached)))
        return .object(pairs)
    }

    static func parse(_ value: JSONValue) throws -> GoalCheckpoint {
        guard value.isObject else { throw GoalError.invalid("A checkpoint could not be read.") }
        return GoalCheckpoint(id: try value.string("id") ?? "", title: try value.string("title") ?? "", date: try value.string("date"),
                              description: try value.string("description"), reached: try value.bool("reached") ?? false,
                              extra: .object((value.objectValue ?? []).filter { !known.contains($0.0) }))
    }
}

public enum GoalLinkType: String, Sendable, CaseIterable { case chat, task, doc, file }

/// A reference to an existing record. Identity is (type, recordId); `channelId` only helps find a chat's channel.
public struct GoalLink: Sendable, Equatable, Hashable {
    public var type: GoalLinkType
    public var recordId: String
    public var channelId: String?
    public var extra: JSONValue

    public init(type: GoalLinkType, recordId: String, channelId: String? = nil, extra: JSONValue = .object([])) {
        self.type = type; self.recordId = recordId.lowercased(); self.channelId = channelId?.lowercased(); self.extra = extra
    }

    public struct Key: Hashable, Sendable {
        public let type: GoalLinkType; public let recordId: String
        public init(type: GoalLinkType, recordId: String) { self.type = type; self.recordId = recordId.lowercased() }
    }
    public var key: Key { Key(type: type, recordId: recordId) }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }

    static let known: Set<String> = ["type", "record_id", "channel_id"]

    func validate() throws {
        guard lowerUUID(recordId) == recordId else { throw GoalError.invalid("A linked record identity is invalid.") }
        if let channelId, lowerUUID(channelId) != channelId { throw GoalError.invalid("A linked channel identity is invalid.") }
    }

    func toJSON() -> JSONValue {
        var pairs: [(String, JSONValue)] = (extra.objectValue ?? []).filter { !Self.known.contains($0.0) }
        pairs.append(("type", .string(type.rawValue))); pairs.append(("record_id", .string(recordId)))
        if let channelId { pairs.append(("channel_id", .string(channelId))) }
        return .object(pairs)
    }

    static func parse(_ value: JSONValue) throws -> GoalLink {
        guard value.isObject else { throw GoalError.invalid("A link could not be read.") }
        guard let type = GoalLinkType(rawValue: try value.string("type") ?? "") else { throw GoalError.invalid("A link has an unknown type.") }
        return GoalLink(type: type, recordId: try value.string("record_id") ?? "", channelId: try value.string("channel_id"),
                        extra: .object((value.objectValue ?? []).filter { !known.contains($0.0) }))
    }
}

public enum GoalError: LocalizedError, Equatable, Sendable {
    case invalid(String)
    /// A newer app version wrote this goal; it is left exactly as stored.
    case unsupported
    /// An edit's expectation no longer holds because the goal changed elsewhere.
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .conflict(let message): message
        case .unsupported: "This goal was saved by a newer version of the app. Update to open it."
        }
    }
}

extension Optional where Wrapped == String {
    var blankToNil: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension JSONValue {
    // A known field of the wrong type is an error, never "absent": a goal is rewritten whole, so reading a damaged field
    // as empty would silently erase it (or every checkpoint and link) on the next save.
    private func typed<T>(_ key: String, _ read: (JSONValue) -> T?) throws -> T? {
        guard let value = self[key], value != .null else { return nil }
        guard let result = read(value) else { throw GoalError.invalid("The goal’s “\(key)” has an unexpected form, so it was not opened.") }
        return result
    }
    func string(_ key: String) throws -> String? { try typed(key) { $0.stringValue } }
    func bool(_ key: String) throws -> Bool? { try typed(key) { $0.boolValue } }
    func array(_ key: String) throws -> [JSONValue] { try typed(key) { $0.arrayValue } ?? [] }
}
