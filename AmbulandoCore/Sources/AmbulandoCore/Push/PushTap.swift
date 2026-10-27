import Foundation

/// What a person is told after tapping a delivered alert that did not open anything. Wording names only the kind of
/// notification (from the alert's `category`), never its title or text.
public enum PushTapOutcome: Sendable, Equatable {
    /// The alert cannot be read, or belongs to another Tower or workspace than this connection holds.
    case notForThisConnection
    /// Tower no longer grants the item (revoked, withdrawn, removed or access lost).
    case unavailable(category: String?)
    /// Tower could not be asked just now (offline, locked signer, server trouble). Nothing was opened.
    case couldNotCheck(category: String?)

    public var message: String {
        switch self {
        case .notForThisConnection:
            return "That notification isn't for this Ambulando connection."
        case .unavailable(let category):
            return "That \(PushCategoryWording.noun(category)) is no longer available to you. It may have been withdrawn or you may have lost access."
        case .couldNotCheck(let category):
            return "Couldn't check that \(PushCategoryWording.noun(category)) just now. Open Notifications to try again."
        }
    }
}

/// Plain words for an alert's category, matching the Notifications list ("Mentions", "Assignments", …) in the singular.
public enum PushCategoryWording {
    public static func noun(_ category: String?) -> String {
        switch category {
        case "mention": "mention"
        case "dm": "direct message"
        case "task_assignment": "task assignment"
        case "comment_tag": "comment tag"
        case "chat_thread", "reply", "thread_reply": "reply"
        case "approval_requested", "approval": "approval request"
        case "security": "security notice"
        default: "notification"
        }
    }
}

/// The app's state at the moment of a tap, as plain values.
public struct PushTapSnapshot: Sendable, Equatable {
    public var connectedOrigin: TowerOrigin?
    public var connectedTowerNpub: String?
    /// Workspaces read from the saved connection (the store, not a view that may not have loaded yet on a cold start).
    public var workspaceIds: Set<String>
    public var isLocked: Bool

    public init(connectedOrigin: TowerOrigin?, connectedTowerNpub: String?, workspaceIds: Set<String>, isLocked: Bool) {
        self.connectedOrigin = connectedOrigin
        self.connectedTowerNpub = connectedTowerNpub
        self.workspaceIds = Set(workspaceIds.map { $0.lowercased() })
        self.isLocked = isLocked
    }
}

public enum PushTapResolution: Sendable, Equatable {
    /// The identity is locked: keep the payload (ids only) in memory and resolve again after unlock.
    case hold(PushPayload)
    /// Tower granted the inbox item just now; open it through the ordinary notification route.
    case openItem(NotificationItem)
    /// The alert named only records (no inbox item): open the most specific one, whose own load checks access.
    case openRecord(PushPayload)
    /// Nothing opens; tell the person why.
    case show(PushTapOutcome)
}

public enum PushTapResolver {
    /// One resolution for cold start, warm tap and a tap held until unlock. The payload decides nothing by itself: the
    /// connection and workspace must already be this app's, and an inbox item is read fresh from Tower (`lookup`, a direct
    /// id GET with no query) before anything renders. A failed check opens nothing and never falls back to a cached copy.
    public static func resolve(_ payload: PushPayload?, snapshot: PushTapSnapshot,
                               lookup: @Sendable (_ workspaceId: String, _ notificationId: String) async throws -> TowerAPI.NotificationLookup) async -> PushTapResolution {
        guard let payload else { return .show(.notForThisConnection) }
        switch PushRouter.decide(payload, connectedOrigin: snapshot.connectedOrigin, connectedTowerNpub: snapshot.connectedTowerNpub,
                                 workspaceIds: snapshot.workspaceIds, isLocked: snapshot.isLocked) {
        case .refuse: return .show(.notForThisConnection)
        case .holdUntilUnlock: return .hold(payload)
        case .open:
            guard let id = payload.notificationId else { return .openRecord(payload) }
            do {
                switch try await lookup(payload.workspaceId, id) {
                case .item(let item): return .openItem(item)
                case .unavailable: return .show(.unavailable(category: payload.category))
                }
            } catch {
                return .show(.couldNotCheck(category: payload.category))
            }
        }
    }
}
