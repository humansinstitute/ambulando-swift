import AmbulandoCore
import Foundation

/// The notification inbox as the app uses it: a bell with the unread count, the Notifications screen's actions, and
/// opening what a notification points at. All reads come from the local store; the keyed `notifications:<w>` sync job is
/// the only thing that talks to Tower, and the durable write queue is the only thing that changes state there.
extension AppModel {
    func observeNotificationBadge(connection: ConnectionRecord, workspaceId: String) {
        guard let store else { return }
        let connectionId = connection.id
        notificationBadge.start(store: store, matches: { key in
            key.workspaceId == workspaceId && key.table == .notifications
        }) {
            // The bell needs the count and the inbox state only, not the rows.
            var snapshot = NotificationSnapshot()
            snapshot.unread = try await store.reader.notificationUnreadCount(connectionId: connectionId, workspaceId: workspaceId)
            snapshot.status = try await store.reader.notificationStatus(connectionId: connectionId, workspaceId: workspaceId)
            return snapshot
        }
    }

    /// The bell is shown while Tower has (or may have) an inbox. A backend without one hides the count but keeps the
    /// screen reachable, where it says so.
    var notificationUnread: Int { notificationBadge.value.status.state == .ready ? notificationBadge.value.unread : 0 }

    /// Fetches the inbox now (opening the screen, pull to refresh): the same keyed job every other trigger uses.
    func openNotifications(force: Bool = false) {
        guard let workspace = selectedWorkspace else { return }
        withWorkspace(workspace) { sync, c in await sync.refreshNotifications(c, workspace, priority: .visible, force: force) }
    }

    /// Dismisses a refused or overtaken change from the list (it has already been reverted on screen).
    func acknowledgeNotificationRejection(_ id: String) {
        guard let store else { return }
        Task { try? await store.writer.discardWrite(id: id) }
    }

    func loadArchivedNotifications() {
        guard let workspace = selectedWorkspace else { return }
        withWorkspace(workspace) { sync, c in await sync.loadArchivedNotifications(c, workspace) }
    }

    /// Applies one change to one notification (optimistic, then queued). Locked: the change waits for the PIN.
    func changeNotification(_ change: NotificationActions.Change, _ item: NotificationItem) {
        guard let notificationActions, let connection, let workspace = selectedWorkspace, workspace.id == item.workspaceId else { return }
        Task {
            do { try await notificationActions.apply(change, to: item, connection: connection, workspace: workspace) }
            catch { notice = "Could not change this notification: \(error.localizedDescription)" }
        }
    }

    /// `upToSeq` is the sequence the screen had applied when it was drawn: later arrivals stay unread.
    func markAllNotificationsRead(upToSeq: Int, category: String?) {
        guard let notificationActions, let connection, let workspace = selectedWorkspace else { return }
        Task {
            do { try await notificationActions.markAllRead(connection: connection, workspace: workspace, upToSeq: upToSeq, category: category) }
            catch { notice = "Could not mark notifications read: \(error.localizedDescription)" }
        }
    }

    enum NotificationDestination: Equatable {
        /// Navigated to the record; the notification screen should close.
        case opened
        /// Nothing in this build opens it: show the notification's own detail.
        case detail
    }

    /// Opens what a notification points at, like a mention or a Deck row does: through the normal sections, which fetch
    /// the record with the user's own credentials (a record the person can no longer read says so there). Opening marks
    /// the *notification* read; it does not write a resource view (Tower derives that from actually viewing the record).
    @discardableResult
    func openNotification(_ item: NotificationItem) -> NotificationDestination {
        guard item.accessOK, let target = item.target else { return .detail }
        switch target {
        case .thread(let channelId, let threadId, _):
            if let channelId { openInChat(channelId: channelId, threadId: threadId) } else { openRecord(kind: "thread", id: threadId) }
        case .channel(let channelId):
            openRecord(kind: "channel", id: channelId)
        case .task(let taskId):
            openRecord(kind: "task", id: taskId)
        case .doc(let docId):
            openRecord(kind: "doc", id: docId)
        case .file(let fileId):
            openRecord(kind: "file", id: fileId)
        case .generic:
            return .detail
        }
        if item.isUnread { changeNotification(.markRead, item) }
        return .opened
    }
}

// MARK: Preferences

extension AppModel {
    func loadNotificationPreferences() async -> Result<NotificationPreferences, Error> {
        guard let sync, let connection, let workspace = selectedWorkspace else { return .failure(TowerError.unsafePath) }
        do { return .success(try await sync.loadNotificationPreferences(connection, workspace)) } catch { return .failure(error) }
    }

    func setNotificationInbox(_ category: NotificationCategoryInfo, on: Bool) async -> Result<[NotificationRule], Error> {
        guard let sync, let connection, let workspace = selectedWorkspace else { return .failure(TowerError.unsafePath) }
        do { return .success(try await sync.setNotificationInboxRule(connection, workspace, category: category, on: on)) } catch { return .failure(error) }
    }
}
