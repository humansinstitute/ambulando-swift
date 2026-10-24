import AmbulandoCore
import SwiftUI

/// One inbox entry: a view state Tower reports as unread (or needing attention) with the local record it points at.
struct InboxEntry: Sendable, Equatable, Identifiable {
    let state: ViewStateRecord
    let title: String
    let subtitle: String
    let route: WorkRoute?
    let taskState: String?
    var id: String { state.id }
}

struct InboxSnapshot: Sendable, Equatable {
    var needsYou: [InboxEntry] = []
    var unread: [InboxEntry] = []
    var all: [ViewStateRecord] { (needsYou + unread).map(\.state) }
}

/// The Inbox: mentions, assignments and other activity waiting for this member, from Tower's view states
/// (`resource-view-states`) joined with locally stored tasks, documents and threads. Reading an item marks it read
/// on this iPhone immediately and on Tower through the durable write queue.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var snapshot = LiveQuery<InboxSnapshot>(initial: InboxSnapshot())

    var body: some View {
        List {
            if let error = model.syncError(forKey: WorkspaceSync.inboxKey(workspace.id)) {
                SyncNote(text: error, tone: .warning).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            if !snapshot.value.needsYou.isEmpty {
                Section("Needs you") { ForEach(snapshot.value.needsYou) { row($0) } }
            }
            if !snapshot.value.unread.isEmpty {
                Section("Unread") { ForEach(snapshot.value.unread) { row($0) } }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if snapshot.loaded && snapshot.value.needsYou.isEmpty && snapshot.value.unread.isEmpty {
                EmptyNote(title: "All caught up", systemImage: "tray",
                          detail: model.isUnlocked ? "Mentions, assigned tasks and unread conversations appear here." : "Showing saved items. Unlock to refresh.")
                    .accessibilityIdentifier("inbox.empty")
            }
        }
        .navigationTitle("Inbox")
        .safeAreaInset(edge: .top, spacing: 0) {
            if !snapshot.value.all.isEmpty {
                ListHeaderBar {
                    Text("\(snapshot.value.all.count) unread").font(.subheadline).foregroundStyle(Amb.mutedForeground)
                    Spacer()
                    Button("Mark all read") { model.markRead(snapshot.value.all, in: workspace) }
                        .font(.subheadline.weight(.semibold)).accessibilityIdentifier("inbox.markAll")
                }
            }
        }
        .refreshable { model.openInbox(workspace, force: true) }
        .task { start() }
        .onAppear { model.openInbox(workspace) }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { model.openInbox(workspace) } }
    }

    @ViewBuilder private func row(_ entry: InboxEntry) -> some View {
        let content = HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(entry.state.resourceType)).foregroundStyle(entry.state.needsAttention ? Amb.brandOrange : Amb.primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(2)
                Text(entry.subtitle).font(.caption).foregroundStyle(Amb.mutedForeground).lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle().fill(Amb.brandOrange).frame(width: 8, height: 8).accessibilityLabel("Unread")
        }
        .contentShape(Rectangle())
        Group {
            if let route = entry.route {
                // Opening the record marks it read (see `AppModel.markViewed`), as the web inbox does.
                NavigationLink(value: route) { content }
            } else {
                content
            }
        }
        .accessibilityIdentifier("inbox.item")
        .swipeActions(edge: .leading) {
            Button { model.markRead([entry.state], in: workspace) } label: { Label("Read", systemImage: "envelope.open") }.tint(Amb.info)
        }
        .swipeActions(edge: .trailing) {
            if entry.state.resourceType == .task, entry.taskState.flatMap(TaskState.init(rawValue:))?.isTerminal != true {
                Button { done(entry) } label: { Label("Done", systemImage: "checkmark") }.tint(Amb.success)
            }
        }
        .contextMenu {
            Button { model.markRead([entry.state], in: workspace) } label: { Label("Mark read", systemImage: "envelope.open") }
            if entry.state.resourceType == .task { Button { done(entry) } label: { Label("Mark done", systemImage: "checkmark.circle") } }
        }
    }

    /// Done on a task: change its state and clear it from the inbox, as the web inbox does.
    private func done(_ entry: InboxEntry) {
        model.submit(WriteIntent(kind: .taskState, targetId: entry.state.resourceId, payload: ["state": TaskState.done.rawValue]), in: workspace)
        model.markRead([entry.state], in: workspace)
    }

    private func icon(_ type: ViewStateRecord.ResourceType) -> String {
        switch type {
        case .task: "checklist"
        case .document: "doc.text"
        case .thread: "bubble.left.and.bubble.right"
        }
    }

    private func start() {
        let w = workspace.id, store = store
        snapshot.start(store: store, matches: { $0.workspaceId == w && [.viewStates, .tasks, .docs, .threads, .channels, .messages].contains($0.table) }) {
            let states = try await store.reader.viewStates(workspaceId: w).filter { $0.unread || $0.needsAttention }.prefix(200)
            let choice = try await scopeChoice(store, w)
            var needsYou: [InboxEntry] = [], unread: [InboxEntry] = []
            for state in states {
                let channel = choice.channelName(state.channelId).map { "#\($0)" } ?? ""
                var entry: InboxEntry
                switch state.resourceType {
                case .task:
                    let task = try await store.reader.task(workspaceId: w, id: state.resourceId)
                    entry = InboxEntry(state: state, title: task?.title ?? "Task",
                                       subtitle: [task?.taskState?.label ?? "Task", channel].filter { !$0.isEmpty }.joined(separator: " · "),
                                       route: .task(workspaceId: w, taskId: state.resourceId), taskState: task?.state)
                case .document:
                    let doc = try await store.reader.doc(workspaceId: w, id: state.resourceId)
                    entry = InboxEntry(state: state, title: doc?.title ?? "Document", subtitle: ["Document", channel].filter { !$0.isEmpty }.joined(separator: " · "),
                                       route: .doc(workspaceId: w, docId: state.resourceId), taskState: nil)
                case .thread:
                    let thread = try await store.reader.thread(workspaceId: w, id: state.resourceId)
                    let channelId = thread?.channelId ?? state.channelId
                    let title = thread?.title.map(MentionCodec.plain) ?? "Conversation"
                    entry = InboxEntry(state: state, title: String(title.prefix(90)), subtitle: ["Conversation", channel].filter { !$0.isEmpty }.joined(separator: " · "),
                                       route: channelId.map { .thread(workspaceId: w, channelId: $0, threadId: state.resourceId) }, taskState: nil)
                }
                if state.needsAttention { needsYou.append(entry) } else { unread.append(entry) }
            }
            return InboxSnapshot(needsYou: needsYou, unread: unread)
        }
    }
}
