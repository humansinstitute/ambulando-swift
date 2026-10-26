import Foundation

/// Typed views of Tower's durable per-recipient notification inbox (`org.wingman.notification.item` v1). The inbox is
/// actor-private and workspace-scoped; an item is only a pointer to a record, never a grant of access to it.
///
/// Parsing is deliberately tolerant of optional fields and strict about identity: an item that does not belong to the
/// workspace it was requested for is rejected, and unknown target kinds degrade to a generic detail view.
public struct NotificationItem: Sendable, Equatable, Identifiable {
    public static let schema = "org.wingman.notification.item"

    public enum Status: String, Sendable { case active, resolved, withdrawn, expired, revoked }

    /// What a tap opens. Unknown kinds (including every `app_object`) open the notification's own detail.
    public enum Target: Sendable, Equatable {
        case thread(channelId: String?, threadId: String, messageId: String?)
        case channel(channelId: String)
        case task(taskId: String)
        case doc(docId: String)
        case file(fileId: String)
        /// A kind this build has no screen for (`app_object`, `approval`, `workroom`, a future kind).
        case generic(kind: String)
    }

    public let workspaceId: String
    public let id: String
    public let recipientActorId: String?
    public let changeSeq: Int
    public let rowVersion: Int
    public let sourceAppId: String
    public let sourceLabel: String
    public let category: String
    public let reasons: [String]
    public let severity: String
    public let status: Status
    /// `live` or `baseline` (`from before notifications started`).
    public let origin: String
    public let groupKey: String?
    public let eventCount: Int
    public let actorName: String?
    public let title: String
    public let body: String
    public let icon: String?
    public let target: Target?
    public let occurredAt: String
    public let updatedAt: String
    public let expiresAt: String?
    public let isRead: Bool
    public let readReason: String?
    public let isDismissed: Bool
    public let isArchived: Bool
    /// False when the recipient can no longer read the subject: the text is replaced and there is nothing to open.
    public let accessOK: Bool
    /// Subject ids the item's server-side activity version belongs to, for display only.
    public let subjectKind: String?
    public let subjectActivityVersion: Int?
    public let raw: Data
    /// A schema version newer than this build understands: shown as a generic card, with nothing to open.
    public let isFutureVersion: Bool

    /// In the hydrated `inbox` partition: not removed, dismissed or archived.
    public var inInbox: Bool { !isDismissed && !isArchived && (status == .active || status == .resolved) }
    public var isUnread: Bool { !isRead && inInbox }

    public init?(raw: Data, workspaceId expected: String? = nil) {
        guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
        self.init(json: o, workspaceId: expected, raw: raw)
    }

    public init?(json o: [String: Any], workspaceId expected: String? = nil, raw: Data? = nil) {
        guard let id = lowerUUID(o["id"] as? String), let workspace = lowerUUID(o["workspace_id"] as? String),
              expected == nil || expected == workspace,
              let seq = flexibleInt(o["change_seq"]), let version = flexibleInt(o["row_version"]) else { return nil }
        if let schema = o["schema"] as? String, schema != Self.schema { return nil }
        // A newer schema version is shown as a generic card (never dropped, never a crash); nothing in it is opened.
        let schemaVersion = flexibleInt(o["version"]) ?? 1
        isFutureVersion = schemaVersion > 1
        let state = o["state"] as? [String: Any] ?? [:]
        let presentation = o["presentation"] as? [String: Any] ?? [:]
        let source = o["source"] as? [String: Any] ?? [:]
        let group = o["group"] as? [String: Any] ?? [:]
        let subject = o["subject"] as? [String: Any] ?? [:]
        let access = (o["access"] as? String) ?? "ok"
        workspaceId = workspace
        self.id = id
        recipientActorId = lowerUUID(o["recipient_actor_id"] as? String)
        changeSeq = seq
        rowVersion = version
        sourceAppId = (source["app_id"] as? String) ?? (o["source_app_id"] as? String) ?? "unknown"
        sourceLabel = (source["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sourceAppId
        category = (o["category"] as? String) ?? "unknown"
        reasons = (o["reasons"] as? [String]) ?? []
        severity = (o["severity"] as? String) ?? "normal"
        status = Status(rawValue: (o["status"] as? String) ?? "active") ?? .active
        origin = (o["origin"] as? String) ?? "live"
        groupKey = group["key"] as? String
        eventCount = max(1, flexibleInt(group["event_count"]) ?? 1)
        actorName = (o["actor"] as? [String: Any])?["display_name"] as? String
        accessOK = access == "ok"
        // A recipient without access never keeps producer text locally, whatever the server sent.
        title = accessOK ? Self.clean(presentation["title"] as? String, limit: 160) : "Item no longer available"
        body = accessOK ? Self.clean(presentation["body"] as? String, limit: 400) : ""
        icon = presentation["icon"] as? String
        target = (accessOK && !isFutureVersion) ? Self.parseTarget((o["action"] as? [String: Any])?["target"] as? [String: Any], subject: subject) : nil
        occurredAt = (o["occurred_at"] as? String) ?? ""
        updatedAt = (o["updated_at"] as? String) ?? (o["occurred_at"] as? String) ?? ""
        expiresAt = o["expires_at"] as? String
        isRead = state["read"] as? Bool ?? false
        readReason = state["read_reason"] as? String
        isDismissed = state["dismissed"] as? Bool ?? false
        isArchived = state["archived"] as? Bool ?? false
        subjectKind = subject["kind"] as? String
        subjectActivityVersion = flexibleInt(subject["activity_version"])
        self.raw = raw ?? ((try? rawJSON(o)) ?? Data())
    }

    /// Plain text only: control and bidirectional-override characters are removed and the length is bounded.
    static func clean(_ text: String?, limit: Int) -> String {
        guard let text else { return "" }
        let bad: Set<Unicode.Scalar> = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
        let scalars = text.unicodeScalars.filter { s in
            if bad.contains(s) { return false }
            if s == "\n" || s == "\t" { return true }
            return !CharacterSet.controlCharacters.contains(s)
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > limit ? String(cleaned.prefix(limit)) + "…" : cleaned
    }

    static func parseTarget(_ t: [String: Any]?, subject: [String: Any]) -> Target? {
        guard let t, let kind = t["kind"] as? String else { return nil }
        func id(_ key: String) -> String? { lowerUUID(t[key] as? String) ?? lowerUUID(subject[key] as? String) }
        switch kind {
        case "thread", "message":
            guard let thread = id("thread_id") ?? (kind == "message" ? lowerUUID(t["message_id"] as? String) : nil) else { return .generic(kind: kind) }
            return .thread(channelId: id("channel_id"), threadId: thread, messageId: lowerUUID(t["message_id"] as? String))
        case "channel":
            return id("channel_id").map { .channel(channelId: $0) } ?? .generic(kind: kind)
        case "task", "task_comment":
            return id("task_id").map { .task(taskId: $0) } ?? .generic(kind: kind)
        case "doc", "doc_comment":
            return id("doc_id").map { .doc(docId: $0) } ?? .generic(kind: kind)
        case "file":
            return id("file_id").map { .file(fileId: $0) } ?? .generic(kind: kind)
        default:
            return .generic(kind: kind)
        }
    }

    /// Fingerprint of everything a person reads on the card (updates, activity version, text). It is unchanged by read,
    /// dismiss and archive; a fold of newer activity changes it. A queued change made on a card whose fingerprint has since
    /// moved is not applied: that would mark activity read that nobody has seen.
    public var activityDigest: String {
        SHA256Hex.of(Data("\(eventCount)|\(subjectActivityVersion ?? -1)|\(title)|\(body)".utf8))
    }

    /// Rebuilds the item with its user-state flags replaced (an optimistic local change, or a server echo).
    func withState(read: Bool?, dismissed: Bool?, archived: Bool?) -> NotificationItem? {
        guard var o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
        var state = o["state"] as? [String: Any] ?? [:]
        if let dismissed { state["dismissed"] = dismissed }
        if let archived { state["archived"] = archived }
        if let read { state["read"] = read }
        // Dismissing or archiving also reads the item (Tower derives the same).
        if dismissed == true || archived == true { state["read"] = true }
        o["state"] = state
        return NotificationItem(json: o, workspaceId: workspaceId)
    }
}

/// One entry of `changes`: a full item (upsert, including state transitions) or a content-free removal.
public enum NotificationChange: Sendable, Equatable {
    case upsert(NotificationItem)
    case removed(id: String, changeSeq: Int, reason: String?)

    public var changeSeq: Int {
        switch self {
        case .upsert(let item): item.changeSeq
        case .removed(_, let seq, _): seq
        }
    }

    init?(json o: [String: Any], workspaceId: String) {
        let removedFlag = (o["schema"] as? String) == "org.wingman.notification.tombstone" || (o["change_type"] as? String) == "remove"
            || (o["removed"] as? Bool) == true || o["removed_at"] is String || (o["op"] as? String) == "removed"
            || (o["operation"] as? String) == "removed" || (o["type"] as? String) == "tombstone"
        if removedFlag {
            let inner = o["item"] as? [String: Any]
            guard let id = lowerUUID(o["id"] as? String) ?? lowerUUID(o["item_id"] as? String) ?? lowerUUID(inner?["id"] as? String),
                  let seq = flexibleInt(o["change_seq"]) ?? flexibleInt(inner?["change_seq"]) else { return nil }
            if let w = lowerUUID(o["workspace_id"] as? String), w != workspaceId { return nil }
            self = .removed(id: id, changeSeq: seq, reason: o["removal_reason"] as? String ?? inner?["removal_reason"] as? String)
            return
        }
        let itemJSON = (o["item"] as? [String: Any]) ?? o
        guard let item = NotificationItem(json: itemJSON, workspaceId: workspaceId) else { return nil }
        // A removal expressed on the item itself (status or access) is not displayable content.
        if [.withdrawn, .expired, .revoked].contains(item.status) {
            self = .removed(id: item.id, changeSeq: item.changeSeq, reason: item.status.rawValue)
        } else {
            self = .upsert(item)
        }
    }
}

public struct NotificationCounts: Sendable, Equatable, Codable {
    public var unreadTotal = 0
    public var byCategory: [String: Int] = [:]
    public var badge: Int?
    public var cappedAt = 999
    public var headSeq = 0
    public var inboxStartedAt: String?
    public var rulesRevision: Int?
    public init() {}

    init?(json o: [String: Any]) {
        guard let total = flexibleInt(o["unread_total"]) else { return nil }
        unreadTotal = total
        byCategory = (o["by_category"] as? [String: Any])?.compactMapValues(flexibleInt) ?? [:]
        badge = flexibleInt(o["badge"])
        cappedAt = flexibleInt(o["capped_at"]) ?? 999
        headSeq = flexibleInt(o["head_seq"]) ?? 0
        inboxStartedAt = o["inbox_started_at"] as? String
        rulesRevision = flexibleInt(o["rules_revision"])
    }
}

/// Where this workspace's inbox stands on this device.
public enum NotificationSyncState: String, Sendable, Codable {
    /// Never hydrated (or reset): the next job lists the inbox, then replays changes.
    case cold
    case ready
    /// Tower answered 404/501 for the inbox routes: the backend has no notifications. Retried rarely.
    case unsupported
    /// Tower refused this workspace (membership or access gone). Local items were purged.
    case noAccess
}

public struct NotificationSyncStatus: Sendable, Equatable {
    public var state: NotificationSyncState = .cold
    /// The inbox is being listed across jobs (a long inbox): not ready until the listing reaches its end.
    public var hydrating = false
    public var hydrateGen = 0
    /// The rules revision the stored snapshot was computed under (sent with `changes`).
    public var rulesRevision: Int?
    public var hydrateSeq: Int?
    public var hydrateCursor: String?
    public var archiveCursor: String?
    /// The archive listing was started and has more pages.
    public var archiveIncomplete = false
    public var localSeq = 0
    public var headSeq = 0
    /// Server-side activation time for the inbox, when Tower reports it ("Inbox started …").
    public var startedAt: String?
    public var syncedAt: String?
    public var counts: NotificationCounts?
    public var archivedHydrated = false
    public var lastError: String?
    public var checkedAt: String?
    public var resetAt: String?
    public init() {}
}

/// What the notification screen shows for one workspace.
public struct NotificationSnapshot: Sendable, Equatable {
    public var items: [NotificationItem] = []
    public var unread = 0
    public var status = NotificationSyncStatus()
    /// Optimistic changes not yet accepted by Tower.
    public var pendingIds: Set<String> = []
    /// Changes Tower or this device refused, waiting to be acknowledged by the person.
    public var rejected: [NotificationRejection] = []
    /// Categories present in the stored inbox, for the category filter.
    public var categories: [String] = []
    public init() {}
}

/// A change that did not apply, with the words to show.
public struct NotificationRejection: Sendable, Equatable, Identifiable {
    public let id: String
    public let message: String
    public init(id: String, message: String) { self.id = id; self.message = message }
}

/// The list filters of the notification screen.
public enum NotificationFilter: String, Sendable, CaseIterable, Identifiable {
    case unread, all, archived
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .unread: "Unread"
        case .all: "All"
        case .archived: "Archived"
        }
    }

    public func includes(_ item: NotificationItem) -> Bool {
        switch self {
        case .unread: item.isUnread
        case .all: item.inInbox
        case .archived: item.isArchived && !item.isDismissed
        }
    }
}

/// Human wording for categories the registry names (unknown ones are shown as written, capitalised).
public enum NotificationCategories {
    public static func label(_ category: String) -> String {
        switch category {
        case "mention": "Mentions"
        case "dm": "Direct messages"
        case "task_assignment": "Assignments"
        case "comment_tag": "Comment tags"
        case "chat_thread": "Conversations"
        case "approval_requested", "approval": "Approvals"
        case "security": "Security"
        default: category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public static func systemImage(_ category: String) -> String {
        switch category {
        case "mention": "at"
        case "dm": "bubble.left"
        case "task_assignment": "checklist"
        case "comment_tag": "text.bubble"
        case "chat_thread": "bubble.left.and.bubble.right"
        case "approval_requested", "approval": "checkmark.seal"
        case "security": "lock.shield"
        default: "bell"
        }
    }
}
