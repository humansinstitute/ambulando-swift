import Foundation

/// One Tower outbox event (`serializeFlightDeckPgEvent`), as delivered by `GET /workspaces/:w/events` and the
/// `flightdeck_pg.event` frames of `GET /workspaces/:w/events/stream`. Only the fields the client acts on are kept.
public struct TowerEvent: Sendable, Equatable {
    public let rowVersion: Int
    public let cursor: String
    public let workspaceId: String
    public let entityType: String
    public let entityId: String?
    public let operation: String
    public let scopeId: String?
    public let channelId: String?
    /// Parent ids some events carry in `payload` (thread of a message, task of a comment, target of a reaction).
    public let threadId: String?
    public let parentId: String?
    /// The changed record's `row_version` after the change, when Tower reports it.
    public let entityRowVersion: Int?

    public init(rowVersion: Int, cursor: String, workspaceId: String, entityType: String, entityId: String?, operation: String,
                scopeId: String? = nil, channelId: String? = nil, threadId: String? = nil, parentId: String? = nil, entityRowVersion: Int? = nil) {
        self.rowVersion = rowVersion; self.cursor = cursor; self.workspaceId = workspaceId; self.entityType = entityType
        self.entityId = entityId; self.operation = operation; self.scopeId = scopeId; self.channelId = channelId
        self.threadId = threadId; self.parentId = parentId; self.entityRowVersion = entityRowVersion
    }

    /// Parses one serialized event. Ids are lower-cased UUIDs; anything else is dropped so it can never reach a path.
    public init?(json o: [String: Any]) {
        guard let row = flexibleInt(o["row_version"]), let cursor = o["cursor"] as? String, !cursor.isEmpty,
              let workspace = lowerUUID(o["workspace_id"] as? String), let type = o["entity_type"] as? String,
              let operation = o["operation"] as? String else { return nil }
        let payload = o["payload"] as? [String: Any] ?? [:]
        let parent = ["task_id", "doc_id", "target_id", "message_id", "file_id"].lazy.compactMap { lowerUUID(payload[$0] as? String) }.first
        self.init(rowVersion: row, cursor: cursor, workspaceId: workspace, entityType: type, entityId: lowerUUID(o["entity_id"] as? String),
                  operation: operation, scopeId: lowerUUID(o["scope_id"] as? String),
                  channelId: lowerUUID(o["channel_id"] as? String) ?? lowerUUID(payload["channel_id"] as? String),
                  threadId: lowerUUID(payload["thread_id"] as? String), parentId: parent, entityRowVersion: flexibleInt(o["entity_row_version"]))
    }
}

/// One Server-Sent Events frame.
public struct SSEFrame: Sendable, Equatable {
    public var event: String
    public var data: String
    public var id: String?
}

/// Incremental `text/event-stream` parser (WHATWG rules: LF, CR or CRLF line ends, `:` comments, multi-line `data`).
/// Bytes are fed in arbitrary chunks; a frame is emitted only at its terminating blank line.
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var event = ""
    private var data: [String] = []
    private var id: String?
    private var sawCR = false
    /// Comment lines (`: heartbeat`) seen since the last call; they prove the connection is alive.
    public private(set) var comments = 0
    /// Upper bound on one unterminated line, so a hostile stream cannot grow memory without limit.
    public static let maxLine = 4 * 1024 * 1024

    public init() {}

    public enum ParseError: Error { case lineTooLong }

    public mutating func feed(_ chunk: Data) throws -> [SSEFrame] {
        var frames: [SSEFrame] = []
        for byte in chunk {
            if sawCR {
                sawCR = false
                if byte == 0x0A { continue }
            }
            if byte == 0x0A || byte == 0x0D {
                if byte == 0x0D { sawCR = true }
                if let frame = line(String(decoding: buffer, as: UTF8.self)) { frames.append(frame) }
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
                if buffer.count > Self.maxLine { throw ParseError.lineTooLong }
            }
        }
        return frames
    }

    public mutating func takeComments() -> Int { defer { comments = 0 }; return comments }

    private mutating func line(_ text: String) -> SSEFrame? {
        if text.isEmpty {
            defer { event = ""; data = []; id = nil }
            guard !data.isEmpty else { return nil }
            return SSEFrame(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"), id: id)
        }
        if text.hasPrefix(":") { comments += 1; return nil }
        let field: Substring, value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            let rest = text[text.index(after: colon)...]
            value = rest.hasPrefix(" ") ? rest.dropFirst() : rest
        } else { field = Substring(text); value = "" }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        case "id": if !value.contains("\0") { id = String(value) }
        default: break
        }
        return nil
    }
}

/// Local work derived from a batch of events. Deletions are applied directly (tombstones); everything else becomes a
/// keyed, coalescing refresh job, so a burst of edits to one record costs one request.
public struct EventPlan: Sendable, Equatable {
    public enum Refresh: Sendable, Hashable {
        case message(channelId: String, messageId: String)
        case thread(channelId: String, threadId: String)
        case channelMessages(channelId: String)
        case task(String)
        case channelTasks(String)
        case doc(String)
        case channelDocs(String)
        case channelFiles(String)
        case reactions(channelId: String, messageId: String)
        case inbox
        /// Scopes and channels (`complete` lists remove what the actor can no longer see).
        case structure
        /// Member directory and personal scope order.
        case directory
        /// Membership or grants changed: re-run discovery (a workspace no longer listed is removed locally).
        case access
    }

    public enum Tombstone: Sendable, Hashable {
        case message(String), thread(String), task(String), doc(String), file(String), comment(String), reaction(String)
    }

    public var refreshes: Set<Refresh> = []
    public var tombstones: Set<Tombstone> = []
    /// Highest reported `row_version` per direct record refresh; a local row already at that version is not fetched.
    public var versions: [Refresh: Int] = [:]
    /// Events of types this client does not render (canvas, agents, workrooms …); counted, not fetched.
    public var ignored = 0
    /// More events than `targetedLimit`: per-record fetches were folded into per-channel list catch-ups.
    public var folded = false

    public init() {}

    /// Above this many events in one batch, targeted fetches are replaced by channel list catch-ups (as the web
    /// client does for a replay burst).
    public static let targetedLimit = 100

    static let accessTypes: Set<String> = ["workspace_member", "group", "channel_grant", "scope_access", "org_data", "permission_grant"]
    static let directoryTypes: Set<String> = ["actor", "workspace_member_profile", "scope_order"]

    /// Adds a direct refresh. `nil` (a change to a child, such as a comment) disables the version skip for it.
    mutating func insert(_ refresh: Refresh, version: Int?) {
        let known = refreshes.contains(refresh)
        refreshes.insert(refresh)
        if let version, !known || versions[refresh] != nil { versions[refresh] = max(versions[refresh] ?? version, version) }
        else { versions[refresh] = nil }
    }

    public static func make(_ events: [TowerEvent], workspaceId: String) -> EventPlan {
        var plan = EventPlan()
        let fold = events.count > targetedLimit
        plan.folded = fold
        for e in events {
            guard e.workspaceId == workspaceId else { plan.ignored += 1; continue }
            let deleted = e.operation == "deleted"
            let channel = e.channelId
            switch e.entityType {
            case "message":
                guard let id = e.entityId, let channel else { plan.ignored += 1; continue }
                if deleted { plan.tombstones.insert(.message(id)) }
                else if fold { plan.refreshes.insert(.channelMessages(channelId: channel)) }
                else { plan.insert(.message(channelId: channel, messageId: id), version: e.entityRowVersion) }
            case "thread":
                guard let id = e.entityId, let channel else { plan.ignored += 1; continue }
                if deleted { plan.tombstones.insert(.thread(id)) }
                else { plan.refreshes.insert(fold ? .channelMessages(channelId: channel) : .thread(channelId: channel, threadId: id)) }
            case "task":
                guard let id = e.entityId else { plan.ignored += 1; continue }
                if deleted { plan.tombstones.insert(.task(id)) }
                else if fold, let channel { plan.refreshes.insert(.channelTasks(channel)) }
                else { plan.insert(.task(id), version: e.entityRowVersion) }
            case "task_comment", "task_assignment", "task_watcher":
                if deleted, e.entityType == "task_comment", let id = e.entityId { plan.tombstones.insert(.comment(id)) }
                if let task = e.parentId, !fold { plan.insert(.task(task), version: nil) }
                else if let channel { plan.refreshes.insert(.channelTasks(channel)) }
            case "doc":
                guard let id = e.entityId else { plan.ignored += 1; continue }
                if deleted { plan.tombstones.insert(.doc(id)) }
                else if let channel, fold { plan.refreshes.insert(.channelDocs(channel)) }
                else { plan.insert(.doc(id), version: e.entityRowVersion) }
            case "doc_comment":
                if deleted, let id = e.entityId { plan.tombstones.insert(.comment(id)) }
                if let doc = e.parentId, !fold { plan.insert(.doc(doc), version: nil) }
                else if let channel { plan.refreshes.insert(.channelDocs(channel)) }
            case "file", "file_folder":
                if deleted, e.entityType == "file", let id = e.entityId { plan.tombstones.insert(.file(id)) }
                if let channel { plan.refreshes.insert(.channelFiles(channel)) }
            case "reaction":
                if deleted, let id = e.entityId { plan.tombstones.insert(.reaction(id)) }
                if let target = e.parentId, let channel, !fold { plan.refreshes.insert(.reactions(channelId: channel, messageId: target)) }
            case "resource_view_state":
                plan.refreshes.insert(.inbox)
            case "scope", "channel":
                plan.refreshes.insert(.structure)
            default:
                if accessTypes.contains(e.entityType) { plan.refreshes.formUnion([.access, .structure, .directory]) }
                else if directoryTypes.contains(e.entityType) { plan.refreshes.insert(.directory) }
                else { plan.ignored += 1 }
            }
        }
        // A deleted record is not fetched again in the same batch.
        for t in plan.tombstones {
            switch t {
            case .task(let id): plan.refreshes.remove(.task(id))
            case .doc(let id): plan.refreshes.remove(.doc(id))
            case .message(let id): plan.refreshes = plan.refreshes.filter { if case .message(_, id) = $0 { false } else { true } }
            case .thread(let id): plan.refreshes = plan.refreshes.filter { if case .thread(_, id) = $0 { false } else { true } }
            default: break
            }
        }
        plan.versions = plan.versions.filter { plan.refreshes.contains($0.key) }
        return plan
    }
}
