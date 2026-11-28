import AmbulandoCore
import SwiftUI

struct RemindersSnapshot: Sendable, Equatable {
    var personal: [TaskRow] = []
    var other: [TaskRow] = []
    var failures: [WriteItem] = []
    var viewer: MemberRecord?
    var humanIdentityKnown = false
    var choice = ScopeChoice()
    var people = PeopleDirectory()
    var refreshed = false
}

struct RemindersView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var snapshot = LiveQuery<RemindersSnapshot>(initial: RemindersSnapshot())
    private var readable: Bool { model.isUnlocked && model.selectedWorkspace?.id == workspace.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reminders").font(Amb.editorial)
                    Text("Your New, Ready and In Progress tasks · \(workspace.label)")
                        .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
                Spacer()
                Button("Refresh") { refresh() }.disabled(!readable)
                    .accessibilityIdentifier("reminders.refresh")
            }.padding(16)
            if !readable {
                EmptyNote(title: "Reminders locked", systemImage: "lock", detail: "Unlock to show your saved tasks.")
            } else if let error = snapshot.error {
                SyncNote(text: error, tone: .warning)
            } else if !snapshot.loaded {
                ProgressView("Loading saved reminders…").padding()
            } else if snapshot.value.viewer == nil {
                SyncNote(text: snapshot.value.humanIdentityKnown ? "Reminders requires your signed-in human workspace identity. Unlock with that identity." : "Your human workspace identity is not saved yet. Refresh when connected to load your reminders.", tone: .warning)
            } else {
                list
            }
        }
        .navigationTitle("Reminders")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminders.destination")
        .task(id: readable) { if readable { start(); refresh(); model.withWorkspace(workspace) { sync, c in await sync.refreshDirectory(c, workspace) } } else { snapshot.stop() } }
        .onChange(of: snapshot.value.choice.channels.map(\.id)) { _, _ in refresh() }
        .onDisappear { snapshot.stop() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !snapshot.value.refreshed {
                    SyncNote(text: "Showing saved tasks. Updates load in the background when connected.")
                }
                ForEach(snapshot.value.failures) { WriteStatusLine(item: $0, label: "Reminder change") }
                section("Note to Self", rows: snapshot.value.personal, id: "personal")
                Divider().accessibilityIdentifier("reminders.divider")
                section("Other assigned tasks", rows: snapshot.value.other, id: "other")
                if let error = refreshError { SyncNote(text: "Saved tasks shown. \(error)", tone: .warning) }
            }.padding(16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminders.list")
        .refreshable { refresh() }
    }

    private func section(_ title: String, rows: [TaskRow], id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.amb(.headline)).accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text("No saved open tasks assigned to you here.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            }
            ForEach(rows) { row in
                NavigationLink(value: WorkRoute.task(workspaceId: workspace.id, taskId: row.id)) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(row.title).font(.amb(.body).weight(.semibold))
                            Spacer()
                            TaskStatusBadge(state: row.state)
                        }
                        HStack {
                            Text([snapshot.value.choice.scopeName(row.task.scopeId), snapshot.value.choice.channelName(row.task.channelId)].compactMap { $0 }.joined(separator: " · "))
                                .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                            Spacer()
                            if let assignee = row.assignee { PersonAvatar(person: snapshot.value.people.person(assignee), size: 24) }
                        }
                        ForEach(row.pending) { WriteStatusLine(item: $0, label: "Task change") }
                    }.padding(12).background(Amb.card, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reminder.\(row.title)")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("reminders.\(id)")
    }

    private var refreshError: String? {
        snapshot.value.choice.channels.compactMap { model.syncError(forKey: WorkspaceSync.tasksKey(workspace.id, $0.id)) }.first
    }

    private func refresh() { model.openTasks(workspace, scopeId: nil, force: true) }

    private func start() {
        let w = workspace.id, store = store, connection = model.connection?.id ?? "", signer = model.connection?.signerNpub ?? ""
        snapshot.start(store: store, matches: { ($0.workspaceId == w && [.tasks, .writes, .members, .channels, .scopes, .access, .appState].contains($0.table)) || $0.table == .profiles }) {
            let members = try await store.reader.members(workspaceId: w)
            let viewer = Reminders.viewer(members, workspace: w, signer: signer)
            let choice = try await scopeChoice(store, w)
            let people = try await store.reader.people(connectionId: connection, workspaceId: w)
            guard let viewer else { return RemindersSnapshot(humanIdentityKnown: members.contains { $0.npub == signer }, choice: choice, people: people) }
            let writes = try await store.reader.writes(connectionId: connection, workspaceId: w)
            let tasks = try await store.reader.reminderCandidates(workspaceId: w)
            let byTask = Dictionary(grouping: writes, by: { $0.targetId ?? "" })
            let rows = tasks.map { TaskRow(task: $0, writes: byTask[$0.id] ?? []) }.filter { $0.isReminder(for: viewer) }
            let personal = Reminders.personalBoard(choice.channels, workspace: w, viewer: viewer.npub)?.id
            var refreshed = !choice.channels.isEmpty
            for channel in choice.channels {
                if try await store.reader.listSyncComplete(workspaceId: w, key: WorkspaceSync.tasksKey(w, channel.id)) != true { refreshed = false }
            }
            return RemindersSnapshot(personal: rows.filter { $0.task.channelId == personal }, other: rows.filter { $0.task.channelId != personal },
                failures: writes.filter { [.taskAssign, .taskState, .taskBoardChange].contains($0.kind) && !$0.isPending },
                viewer: viewer, humanIdentityKnown: true, choice: choice, people: people, refreshed: refreshed)
        }
    }
}

extension TaskRow {
    func isReminder(for viewer: MemberRecord) -> Bool {
        guard Reminders.isOpen(state) else { return false }
        let assignmentChanged = pending.contains { write in
            write.isPending && (write.kind == .taskAssign || (write.kind == .taskBoardChange && write.payloadObject["assignee"] != nil))
        }
        return assignmentChanged ? assignee == viewer.npub : Reminders.isAssigned(task, to: viewer)
    }
}
