import AmbulandoCore
import SwiftUI

// MARK: Bell

/// The toolbar entry to the notification inbox, with the unread count of the selected workspace. It is always reachable:
/// a Tower without an inbox says so on the screen instead of hiding the feature.
struct NotificationsButton: View {
    @Environment(AppModel.self) private var model
    let action: () -> Void

    var body: some View {
        let unread = model.notificationUnread
        Button(action: action) {
            Image(systemName: unread > 0 ? "bell.badge" : "bell")
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)").font(.system(size: 9, weight: .bold)).foregroundStyle(Amb.primaryForeground)
                            .padding(.horizontal, 3).frame(minWidth: 14, minHeight: 14)
                            .background(Amb.destructive, in: Capsule()).offset(x: 9, y: -7)
                    }
                }
        }
        .accessibilityLabel(unread == 0 ? "Notifications" : "Notifications, \(unread) unread")
        .accessibilityIdentifier("notifications.open")
    }
}

// MARK: Screen

/// The durable notification inbox: what Tower has told this person, newest first, with unread / all / archived views,
/// a category filter and read, unread, archive and dismiss. Everything shown comes from the local store; actions apply at
/// once and are sent in the background (they wait for the PIN while the app is locked).
struct NotificationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceRecord
    let store: LocalStore

    @State private var snapshot = LiveQuery<NotificationSnapshot>(initial: NotificationSnapshot())
    @State private var filter: NotificationFilter = .unread
    @State private var category: String?
    @State private var detail: NotificationItem?
    @State private var undo: NotificationItem?
    @State private var undoTask: Task<Void, Never>?

    private var connectionId: String? { model.connection?.id }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $filter) {
                    ForEach(NotificationFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .accessibilityIdentifier("notifications.filter")
                if snapshot.value.unread > 0 {
                    HStack {
                        Text("\(snapshot.value.unread) unread").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                        Spacer()
                        Button("Mark all read") { model.markAllNotificationsRead(upToSeq: snapshot.value.status.localSeq, category: category) }
                            .font(.amb(.footnote).weight(.semibold))
                            .accessibilityIdentifier("notifications.markAll")
                    }
                    .padding(.horizontal, 16).padding(.bottom, 6)
                }
                content
            }
            .background(Amb.canvas)
            .navigationTitle("Notifications")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("notifications.done") }
                ToolbarItem(placement: .primaryAction) { actionsMenu }
            }
            .safeAreaInset(edge: .bottom) { undoBar }
        }
        .task(id: "\(workspace.id)|\(filter.rawValue)|\(category ?? "")") { start() }
        .onAppear { model.openNotifications() }
        .onChange(of: filter) { _, now in if now == .archived { model.loadArchivedNotifications() } }
        .onDisappear { snapshot.pause(); undoTask?.cancel() }
        .sheet(item: $detail) { item in NotificationDetailView(item: item) }
        .accessibilityIdentifier("notifications.screen")
    }

    private func start() {
        guard let connectionId else { return }
        let workspaceId = workspace.id, filter = filter, category = category
        snapshot.start(store: store, matches: { $0.workspaceId == workspaceId && $0.table == .notifications }) {
            try await store.reader.notificationSnapshot(connectionId: connectionId, workspaceId: workspaceId, filter: filter, category: category)
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        let value = snapshot.value
        List {
            if let banner = banner(value.status) { banner.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            ForEach(value.rejected) { rejection in
                HStack(alignment: .top) {
                    Notice(tone: .warning, text: rejection.message)
                    Button("OK") { model.acknowledgeNotificationRejection(rejection.id) }.buttonStyle(.borderless)
                        .accessibilityIdentifier("notifications.rejection.ok")
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)).listRowBackground(Color.clear)
                .accessibilityIdentifier("notifications.rejection")
            }
            ForEach(value.items) { item in
                NotificationRow(item: item, pending: value.pendingIds.contains(item.id))
                    .contentShape(Rectangle())
                    .onTapGesture { open(item) }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if item.isRead {
                            Button { model.changeNotification(.markUnread, item) } label: { Label("Unread", systemImage: "envelope.badge") }.tint(Amb.info)
                        } else {
                            Button { model.changeNotification(.markRead, item) } label: { Label("Read", systemImage: "envelope.open") }.tint(Amb.info)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { dismissItem(item) } label: { Label("Dismiss", systemImage: "xmark.bin") }
                        if item.isArchived {
                            Button { model.changeNotification(.unarchive, item) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }.tint(Amb.warning)
                        } else {
                            Button { model.changeNotification(.archive, item) } label: { Label("Archive", systemImage: "archivebox") }.tint(Amb.warning)
                        }
                    }
                    .contextMenu { rowMenu(item) }
                    .accessibilityAction(named: item.isRead ? "Mark unread" : "Mark read") { model.changeNotification(item.isRead ? .markUnread : .markRead, item) }
                    .accessibilityAction(named: "Archive") { model.changeNotification(.archive, item) }
                    .accessibilityAction(named: "Dismiss") { dismissItem(item) }
                    .ambListRows()
            }
            if value.items.isEmpty, snapshot.loaded { emptyState(value.status).listRowBackground(Color.clear) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { model.openNotifications(force: true) }
        .accessibilityIdentifier("notifications.list")
    }

    @ViewBuilder private func rowMenu(_ item: NotificationItem) -> some View {
        Button(item.isRead ? "Mark unread" : "Mark read", systemImage: item.isRead ? "envelope.badge" : "envelope.open") {
            model.changeNotification(item.isRead ? .markUnread : .markRead, item)
        }
        Button(item.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") {
            model.changeNotification(item.isArchived ? .unarchive : .archive, item)
        }
        Button("Dismiss", systemImage: "xmark.bin", role: .destructive) { dismissItem(item) }
        Button("Details", systemImage: "info.circle") { detail = item }
    }

    private var actionsMenu: some View {
        Menu {
            Picker("Category", selection: $category) {
                Text("All categories").tag(String?.none)
                ForEach(snapshot.value.categories, id: \.self) { Text(NotificationCategories.label($0)).tag(String?.some($0)) }
            }
            Button("Refresh", systemImage: "arrow.clockwise") { model.openNotifications(force: true) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Notification actions")
        .accessibilityIdentifier("notifications.menu")
    }

    // MARK: Actions

    private func open(_ item: NotificationItem) {
        switch model.openNotification(item) {
        case .opened: dismiss()
        case .detail:
            detail = item
            if item.isUnread { model.changeNotification(.markRead, item) }
        }
    }

    private func dismissItem(_ item: NotificationItem) {
        model.changeNotification(.dismiss, item)
        undo = item
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { undo = nil }
        }
    }

    @ViewBuilder private var undoBar: some View {
        if let item = undo {
            HStack {
                Text("Dismissed").font(.amb(.footnote))
                Spacer()
                Button("Undo") { model.changeNotification(.undismiss, item); undo = nil }
                    .font(.amb(.footnote).weight(.semibold))
                    .accessibilityIdentifier("notifications.undo")
            }
            .padding(12)
            .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusControl).stroke(Amb.border))
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    // MARK: States

    private func banner(_ status: NotificationSyncStatus) -> AnyView? {
        switch status.state {
        case .unsupported:
            return AnyView(Notice(tone: .info, text: "This Tower doesn't have a notification inbox yet, so there is nothing to show. Deck's Inbox and Needs You work as before; this screen fills in once Tower turns notifications on.")
                .padding(.horizontal, 16).padding(.vertical, 6).accessibilityIdentifier("notifications.unsupported"))
        case .noAccess:
            return AnyView(Notice(tone: .warning, text: "Tower no longer lets you read this workspace's notifications. They were removed from this \(Device.name).")
                .padding(.horizontal, 16).padding(.vertical, 6).accessibilityIdentifier("notifications.noAccess"))
        case .cold, .ready:
            if status.hydrating, status.state != .ready, !snapshot.value.items.isEmpty {
                return AnyView(Notice(tone: .info, text: "Loading older notifications…")
                    .padding(.horizontal, 16).padding(.vertical, 6).accessibilityIdentifier("notifications.hydrating"))
            }
            if status.lastError != nil, status.state == .cold || status.syncedAt == nil {
                return AnyView(Notice(tone: .warning, text: "Couldn't reach Tower for notifications yet. They will load when the connection returns.")
                    .padding(.horizontal, 16).padding(.vertical, 6).accessibilityIdentifier("notifications.error"))
            }
            return nil
        }
    }

    @ViewBuilder private func emptyState(_ status: NotificationSyncStatus) -> some View {
        switch status.state {
        case .unsupported, .noAccess:
            EmptyView()
        case .cold:
            HStack { ProgressView().controlSize(.small); Text("Loading notifications…").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground) }
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
                .accessibilityIdentifier("notifications.loading")
        case .ready:
            VStack(spacing: 6) {
                Image(systemName: "bell").font(.amb(.title2)).foregroundStyle(Amb.mutedForeground)
                Text(emptyTitle).font(.amb(.headline)).foregroundStyle(Amb.foreground)
                Text("Notifications start from when your Tower turned them on. Earlier activity isn't imported; Deck's Inbox still shows it.")
                    .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 24)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notifications.empty")
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .unread: "You're all caught up"
        case .all: "No notifications yet"
        case .archived: "Nothing archived"
        }
    }
}

// MARK: Row

private struct NotificationRow: View {
    let item: NotificationItem
    let pending: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: NotificationCategories.systemImage(item.category))
                .font(.amb(.subheadline)).foregroundStyle(item.isUnread ? Amb.primary : Amb.mutedForeground)
                .frame(width: 30, height: 30)
                .background((item.isUnread ? Amb.accent : Amb.muted), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.sourceLabel).font(.amb(.caption).weight(.semibold)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                    Text(NotificationCategories.label(item.category)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                    Spacer(minLength: 4)
                    if pending { Image(systemName: "clock").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).accessibilityLabel("Waiting to send") }
                    Text(ChatTime.label(item.occurredAt)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
                Text(item.title).font(.amb(.subheadline).weight(item.isUnread ? .semibold : .regular)).foregroundStyle(Amb.foreground).lineLimit(2)
                if !item.body.isEmpty {
                    Text(item.body).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground).lineLimit(2)
                }
                if item.eventCount > 1 {
                    Text("\(item.eventCount) updates").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
            }
            if item.isUnread {
                Circle().fill(Amb.primary).frame(width: 8, height: 8).padding(.top, 6).accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notifications.row")
    }
}

// MARK: Detail

/// What a notification says when this build has no screen for its target (`app_object`, a future kind), or when the item is
/// no longer available. Plain text only.
struct NotificationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: NotificationItem

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.title).font(.amb(.headline))
                    if !item.body.isEmpty { Text(item.body) }
                }
                Section {
                    LabeledContent("From", value: item.sourceLabel)
                    LabeledContent("Type", value: NotificationCategories.label(item.category))
                    if let when = ChatTime.date(item.occurredAt) { LabeledContent("When", value: when.formatted(date: .abbreviated, time: .shortened)) }
                    if item.eventCount > 1 { LabeledContent("Updates", value: "\(item.eventCount)") }
                }
                Section {
                    Text(item.accessOK
                         ? "Ambulando can't open this kind of item yet. It was sent by \(item.sourceLabel); open that app to act on it."
                         : "You can no longer see what this notification was about.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                }
            }
            .navigationTitle("Notification")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .accessibilityIdentifier("notifications.detail")
    }
}

// MARK: Settings

/// Notifications in Settings: what Tower provides, the person's own inbox choices, and — plainly — that alerts outside the
/// app are not available in this build. Inbox choices are Tower's (loaded when the section appears, written on change).
struct NotificationSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var preferences: NotificationPreferences?
    @State private var loadFailed = false
    @State private var savingId: String?
    @State private var problem: String?

    private var status: NotificationSyncStatus { model.notificationBadge.value.status }

    private var inboxLabel: String {
        switch status.state {
        case .ready: "On"
        case .unsupported: "Not available on this Tower"
        case .noAccess: "No access to this workspace"
        case .cold: status.hydrating ? "Loading…" : "Not loaded yet"
        }
    }

    var body: some View {
        Section {
            LabeledContent("Inbox", value: inboxLabel).accessibilityIdentifier("settings.notifications.inbox")
            if status.state == .ready {
                LabeledContent("Unread", value: "\(model.notificationBadge.value.unread)").accessibilityIdentifier("settings.notifications.unread")
                if let started = status.startedAt.flatMap(ChatTime.date) {
                    LabeledContent("Started", value: started.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("settings.notifications.started")
                }
            }
            if status.state == .unsupported {
                Text("This Tower has no notification inbox yet. Deck's Inbox and Needs You are unaffected.")
                    .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            }
            if status.state == .ready, let preferences {
                ForEach(preferences.categories) { category in
                    Toggle(isOn: Binding(get: { preferences.inboxOn(category) }, set: { set(category, on: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.label)
                            if category.sourceAppId != "flightdeck.core" { Text(category.sourceLabel).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
                            if category.mandatory { Text("Always on").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
                        }
                    }
                    .disabled(category.mandatory || savingId != nil || !model.isUnlocked)
                    .accessibilityIdentifier("settings.notifications.category.\(category.category)")
                }
            } else if status.state == .ready, loadFailed {
                Button("Load notification choices again") { Task { await load() } }
            }
            if let problem { Text(problem).font(.amb(.footnote)).foregroundStyle(Amb.destructive) }
            #if os(iOS)
            PushAlertsRows()
            #else
            LabeledContent("Alerts on this \(Device.name)", value: "Not available").accessibilityIdentifier("settings.notifications.alerts")
            #endif
        } header: { Text("Notifications") } footer: {
            #if os(iOS)
            Text("New notifications appear in the bell while Ambulando is open and when it refreshes in the background. Your choice for each kind applies to what Ambulando shows; other apps keep their own. Reading a notification here is shared with them. Alerts use the system's notification settings; lock screen text is generic (\"New activity\") and opening one fetches it again and checks your access first.")
            #else
            Text("New notifications appear in the bell while Ambulando is open and when it refreshes in the background. Your choice for each kind applies to what Ambulando shows; other apps keep their own. Reading a notification here is shared with them. Alerts outside the app are not available on the Mac in this version.")
            #endif
        }
        .task(id: model.selectedWorkspace?.id) { await load() }
    }

    private func load() async {
        guard model.canRead, status.state != .unsupported else { return }
        switch await model.loadNotificationPreferences() {
        case .success(let loaded): preferences = loaded; loadFailed = false
        case .failure: loadFailed = true
        }
    }

    private func set(_ category: NotificationCategoryInfo, on: Bool) {
        guard var current = preferences else { return }
        let previous = current
        savingId = category.id; problem = nil
        // Shown at once; put back if Tower refuses. The change is this app's view only.
        let client = TowerAPI.notificationClientAppId
        current.rules.removeAll { $0.sourceAppId == category.sourceAppId && $0.category == category.category && $0.channel == "inbox" && $0.clientAppId == client }
        current.rules.append(NotificationRule(sourceAppId: category.sourceAppId, category: category.category, clientAppId: client, channel: "inbox", mode: on ? "on" : "off",
                                              rowVersion: previous.rowVersion(source: category.sourceAppId, category: category.category, clientAppId: client, channel: "inbox")))
        preferences = current
        Task {
            switch await model.setNotificationInbox(category, on: on, known: previous) {
            case .success(let updated): preferences = updated
            case .failure(let error):
                if case NotificationPreferenceError.changedElsewhere(let latest) = error { preferences = latest } else { preferences = previous }
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            savingId = nil
        }
    }
}


#if os(iOS)
import UIKit

/// Alerts outside the app. The system prompt appears only when the person presses Enable; every state below is what the
/// coordinator actually knows (permission, token, Tower's acknowledgement), never an assumption.
struct PushAlertsRows: View {
    @Environment(AppModel.self) private var model

    private var status: PushStatus? { model.pushStatus }

    private var label: String {
        guard model.pushAvailable else { return "Not available in sample data" }
        guard let status else { return "Checking…" }
        switch status.phase {
        case .off: return status.permission == .denied ? "Blocked in system Settings" : "Off"
        case .needsPermission: return "Waiting for your answer"
        case .denied: return "Blocked in system Settings"
        case .waitingForToken: return "Registering this \(Device.name) with Apple…"
        case .waitingForUnlock: return "Waiting for unlock"
        case .notRegistered: return "Not registered with Tower yet"
        case .active: return "On"
        case .registeredNotDelivering: return "Waiting for Tower"
        case .providerUnavailable: return "Not available on this Tower"
        case .failed: return "Needs attention"
        }
    }

    private var detail: String? {
        guard let status else { return nil }
        switch status.phase {
        case .denied: return "Notifications are turned off for Ambulando in system Settings. Open Settings to allow them."
        case .off where status.permission == .denied: return "Notifications are turned off for Ambulando in system Settings. Open Settings to allow them, then come back and press Enable."
        case .waitingForUnlock: return "Registering needs your identity unlocked. Alerts are not delivered until then."
        case .providerUnavailable: return "This Tower is not set up to send alerts yet. Notifications still appear in the bell."
        case .failed(let message): return message
        case .registeredNotDelivering(let reason):
            let why = switch reason {
            case "provider_not_configured": "Tower has no Apple push key set up yet, so it cannot send alerts."
            case "environment_not_enabled": "Tower is not set up to send alerts to this kind of build yet."
            case "permission_denied": "Tower was told alerts are denied on this device."
            default: "Tower says it cannot send alerts yet."
            }
            return "This device is registered, but alerts are not being delivered. " + why + " Notifications still appear in the bell."
        case .active(let until): return "Registered until \(until.formatted(date: .abbreviated, time: .shortened)); it renews itself while Ambulando is unlocked."
        default: return nil
        }
    }

    var body: some View {
        Group {
            LabeledContent("Alerts on this \(Device.name)", value: label).accessibilityIdentifier("settings.notifications.alerts")
            if let detail { Text(detail).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground).accessibilityIdentifier("settings.notifications.alerts.detail") }
            if let status, model.pushAvailable {
                switch status.phase {
                case .off where status.permission != .denied:
                    Button("Enable Notifications") { model.enablePush() }.disabled(!model.isUnlocked).accessibilityIdentifier("settings.notifications.enable")
                case .denied, .off:
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                        .accessibilityIdentifier("settings.notifications.openSettings")
                default:
                    Button("Turn off alerts", role: .destructive) { model.disablePush() }.accessibilityIdentifier("settings.notifications.disable")
                }
            }
        }
        .task { model.refreshPushStatus() }
    }
}
#endif
