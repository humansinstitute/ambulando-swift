import Foundation

/// What a person can do to their notifications. Every action changes the screen at once (a pending overlay over the
/// stored server state) and then goes through the durable write queue, so it survives offline, locking and relaunch.
/// Nothing here signs: the queue sends only while the identity is unlocked, exactly like every other write.
///
/// Notification state is its own fact. Reading, dismissing or archiving a notification never marks the record it points
/// at as viewed, and viewing the record is Tower's business (it derives read state from the view watermark). Nothing
/// here writes view states, feed state or Needs You.
public struct NotificationActions: Sendable {
    public let store: LocalStore
    public let writes: WriteSender

    public init(store: LocalStore, writes: WriteSender) { self.store = store; self.writes = writes }

    public enum Change: Sendable, Equatable {
        case markRead, markUnread, dismiss, undismiss, archive, unarchive

        var patch: NotificationPatch {
            switch self {
            case .markRead: NotificationPatch(read: true)
            case .markUnread: NotificationPatch(read: false)
            case .dismiss: NotificationPatch(dismissed: true)
            case .undismiss: NotificationPatch(dismissed: false)
            case .archive: NotificationPatch(archived: true)
            case .unarchive: NotificationPatch(archived: false)
            }
        }
    }

    /// Applies `change` to one item *as the person saw it*. The compare-and-set version and the observed sequence are those
    /// of the item they were looking at (`item`), never whatever the store holds now: if newer activity folded in between
    /// drawing the card and the tap, Tower answers 409 and the change is not applied to activity nobody has seen.
    public func apply(_ change: Change, to item: NotificationItem, connection: ConnectionRecord, workspace: WorkspaceRecord) async throws {
        let patch = change.patch
        try await store.writer.setNotificationPending(connectionId: connection.id, workspaceId: workspace.id, ids: [item.id], patch)
        var body: [String: any Sendable] = [:]
        if let read = patch.read { body["read"] = read }
        if let dismissed = patch.dismissed { body["dismissed"] = dismissed }
        if let archived = patch.archived { body["archived"] = archived }
        try await writes.submit(WriteIntent(kind: .notificationState, targetId: item.id, payload: [
            "mutation_id": UUID().uuidString.lowercased(),
            "expected_row_version": item.rowVersion, "observed_change_seq": item.changeSeq,
            "base_row_version": item.rowVersion, "seen_digest": item.activityDigest,
            "patch": body,
        ]), connection: connection, workspace: workspace)
    }

    /// "Mark all read", bounded by the sequence the person was *shown* (`upToSeq`: the sequence the screen had applied when
    /// it was drawn): items that reached Tower after that stay unread, including activity folded into a card after it was
    /// drawn. With a category it covers only that category.
    @discardableResult
    public func markAllRead(connection: ConnectionRecord, workspace: WorkspaceRecord, upToSeq: Int, category: String? = nil) async throws -> Int {
        let status = try await store.reader.notificationStatus(connectionId: connection.id, workspaceId: workspace.id)
        guard status.state == .ready, upToSeq > 0 else { return 0 }
        let ids = try await store.writer.markNotificationsReadUpTo(connectionId: connection.id, workspaceId: workspace.id, upToSeq: upToSeq, category: category)
        guard !ids.isEmpty else { return 0 }
        var payload: [String: any Sendable] = [
            "mutation_id": UUID().uuidString.lowercased(), "op": "mark_read", "up_to_seq": upToSeq, "view": "inbox", "pending_ids": ids,
        ]
        if let category { payload["category"] = category }
        try await writes.submit(WriteIntent(kind: .notificationBulk, targetId: nil, payload: payload), connection: connection, workspace: workspace)
        return ids.count
    }
}
