import AmbulandoCore
import SwiftUI

/// A task as shown: Tower's record with the user's pending changes applied on top (they are queued durably and
/// marked as unsent until Tower accepts them).
struct TaskRow: Sendable, Equatable, Identifiable {
    let task: TaskRecord
    let title: String
    let state: String
    let priority: String
    let assignee: String?
    let pending: [WriteItem]
    var id: String { task.id }
    var taskState: TaskState? { TaskState(rawValue: state) }

    init(task: TaskRecord, writes: [WriteItem]) {
        self.task = task
        let mine = writes.filter { $0.targetId == task.id && $0.isPending }
        var title = task.title, state = task.state, priority = task.priority, assignee = task.assignedToNpub
        for w in mine {
            let p = w.payloadObject
            switch w.kind {
            case .taskState: state = (p["state"] as? String) ?? state
            case .taskPatch:
                let patch = p["patch"] as? [String: Any] ?? [:]
                title = (patch["title"] as? String) ?? title
                priority = (patch["priority"] as? String) ?? priority
            case .taskAssign: assignee = (p["assigned_to_npub"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            default: break
            }
        }
        self.title = title; self.state = state; self.priority = priority; self.assignee = assignee
        pending = writes.filter { $0.targetId == task.id }
    }
}

struct TasksSnapshot: Sendable, Equatable {
    var rows: [TaskRow] = []
    var creating: [WriteItem] = []
    var choice = ScopeChoice()
    var names: [String: String] = [:]
}

struct TasksView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @SceneStorage("tasks.board") private var board = false
    @State private var scopeId: String?
    @State private var snapshot = LiveQuery<TasksSnapshot>(initial: TasksSnapshot())
    @State private var creating = false

    var body: some View {
        Group {
            if board { boardView } else { listView }
        }
        .navigationTitle("Tasks")
        .safeAreaInset(edge: .top, spacing: 0) {
            ListHeaderBar {
                ScopeMenu(choice: snapshot.value.choice, selection: $scopeId)
                Spacer()
                Picker("Layout", selection: $board) {
                    Image(systemName: "list.bullet").tag(false).accessibilityLabel("List")
                    Image(systemName: "rectangle.split.3x1").tag(true).accessibilityLabel("Board")
                }
                .pickerStyle(.segmented).frame(width: 110)
                .accessibilityIdentifier("tasks.layout")
                Button { creating = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                    .accessibilityLabel("New task").accessibilityIdentifier("tasks.new")
            }
        }
        .sheet(isPresented: $creating) {
            TaskCreateSheet(workspace: workspace, store: store, choice: snapshot.value.choice, scopeId: scopeId)
        }
        .refreshable { model.openTasks(workspace, scopeId: scopeId, force: true) }
        .task(id: scopeId) { start(); model.openTasks(workspace, scopeId: scopeId) }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { model.openTasks(workspace, scopeId: scopeId) } }
    }

    private var columns: [(TaskState, [TaskRow])] {
        let byState = Dictionary(grouping: snapshot.value.rows) { TaskState(rawValue: $0.state) ?? .new }
        var out: [(TaskState, [TaskRow])] = TaskState.board.map { ($0, byState[$0] ?? []) }
        if let backlog = byState[.backlog], !backlog.isEmpty { out.insert((.backlog, backlog), at: 0) }
        return out
    }

    private var listView: some View {
        List {
            if !snapshot.value.creating.isEmpty {
                Section("Creating") {
                    ForEach(snapshot.value.creating) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.string("title") ?? "Task").font(.subheadline.weight(.semibold))
                            WriteStatusLine(item: item, label: "New task")
                        }
                    }
                }
            }
            ForEach(columns, id: \.0) { state, rows in
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { row in
                            NavigationLink(value: WorkRoute.task(workspaceId: workspace.id, taskId: row.id)) { TaskRowView(row: row, snapshot: snapshot.value, me: model.identity.npub) }
                                .accessibilityIdentifier("task.\(row.title)")
                                .swipeActions(edge: .trailing) {
                                    if row.taskState != .done {
                                        Button { setState(row, .done) } label: { Label("Done", systemImage: "checkmark") }.tint(Amb.success)
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    if row.taskState != .inProgress {
                                        Button { setState(row, .inProgress) } label: { Label("Start", systemImage: "play") }.tint(Amb.info)
                                    }
                                }
                        }
                    } header: {
                        Text("\(state.label) · \(rows.count)").textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if snapshot.loaded && snapshot.value.rows.isEmpty && snapshot.value.creating.isEmpty {
                EmptyNote(title: "No tasks", systemImage: "checklist", detail: model.isUnlocked ? "Tasks in this scope appear here. Tap + to add one." : "Unlock to load tasks.")
            }
        }
    }

    private var boardView: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(columns, id: \.0) { state, rows in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(state.label) · \(rows.count)").font(.subheadline.weight(.semibold)).foregroundStyle(Amb.itemHeading)
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(rows) { row in
                                    NavigationLink(value: WorkRoute.task(workspaceId: workspace.id, taskId: row.id)) {
                                        TaskRowView(row: row, snapshot: snapshot.value, me: model.identity.npub).padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        ForEach(TaskState.board.filter { $0.rawValue != row.state }, id: \.self) { target in
                                            Button("Move to \(target.label)") { setState(row, target) }
                                        }
                                    }
                                }
                                if rows.isEmpty { Text("Nothing here").font(.caption).foregroundStyle(Amb.mutedForeground).padding(.vertical, 20) }
                            }
                        }
                    }
                    .padding(10)
                    .frame(width: 280)
                    .background(Amb.muted.opacity(0.6), in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
                    .accessibilityIdentifier("board.\(state.rawValue)")
                }
            }
            .scrollTargetLayout()
            .padding(12)
        }
        .scrollTargetBehavior(.viewAligned)
    }

    private func setState(_ row: TaskRow, _ state: TaskState) {
        model.submit(WriteIntent(kind: .taskState, targetId: row.id, payload: ["state": state.rawValue]), in: workspace)
    }

    private func start() {
        let w = workspace.id, scope = scopeId, store = store, connection = model.connection?.id ?? ""
        snapshot.start(store: store, matches: { $0.workspaceId == w && [.tasks, .writes, .members, .channels, .scopes].contains($0.table) }) {
            async let tasks = store.reader.tasks(workspaceId: w, scopeId: scope, limit: 500)
            async let writes = store.reader.writes(connectionId: connection, workspaceId: w)
            async let choice = scopeChoice(store, w)
            async let names = directoryNames(store, w)
            let pending = try await writes
            let creating = pending.filter { $0.kind == .taskCreate }
            return TasksSnapshot(rows: try await tasks.map { TaskRow(task: $0, writes: pending) }, creating: creating,
                                 choice: try await choice, names: try await names)
        }
    }
}

struct TaskRowView: View {
    let row: TaskRow
    let snapshot: TasksSnapshot
    let me: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title).font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(3)
            HStack(spacing: 8) {
                PriorityBadge(priority: row.priority)
                if let channel = snapshot.choice.channelName(row.task.channelId) { Text("#\(channel)").lineLimit(1) }
                if let assignee = row.assignee { Label(displayName(assignee, snapshot.names, me: me), systemImage: "person").lineLimit(1) }
                if row.pending.contains(where: \.isPending) { Image(systemName: "arrow.up.circle").accessibilityLabel("Change not sent yet") }
                if row.pending.contains(where: { !$0.isPending }) { Image(systemName: "exclamationmark.circle").foregroundStyle(Amb.destructive).accessibilityLabel("Change not saved") }
            }
            .font(.caption).foregroundStyle(Amb.mutedForeground)
        }
    }
}

struct PriorityBadge: View {
    let priority: String
    var body: some View {
        Text((TaskPriority(rawValue: priority)?.label ?? priority).uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(priority == "rock" || priority == "urgent" || priority == "high" ? Amb.brandOrange : Amb.accentForeground)
            .background(Amb.accent, in: Capsule())
    }
}

// MARK: Detail

struct TaskDetailSnapshot: Sendable, Equatable {
    var row: TaskRow?
    var comments: [CommentRecord] = []
    var pendingComments: [WriteItem] = []
    var members: [MemberRecord] = []
    var names: [String: String] = [:]
    var choice = ScopeChoice()
}

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let taskId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var snapshot = LiveQuery<TaskDetailSnapshot>(initial: TaskDetailSnapshot())
    @State private var editing = false
    @State private var comment = ""
    @FocusState private var commentFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let row = snapshot.value.row {
                    header(row)
                    ForEach(row.pending) { WriteStatusLine(item: $0, label: label(for: $0)) }
                    if let description = row.task.description, !description.isEmpty {
                        MessageBody(text: description, workspace: workspace).ambCard()
                    }
                    comments
                } else if snapshot.loaded {
                    SyncNote(text: model.isUnlocked ? "Loading task…" : "This task is not saved on this iPhone yet. Unlock to load it.")
                }
                if let error = model.syncError(forKey: WorkspaceSync.taskKey(workspace.id, taskId)) { SyncNote(text: error, tone: .warning) }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { commentComposer }
        .background(Amb.background)
        .fixtureLabel()
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = true }.disabled(snapshot.value.row == nil).accessibilityIdentifier("task.edit")
            }
        }
        .sheet(isPresented: $editing) {
            if let row = snapshot.value.row { TaskEditSheet(row: row, workspace: workspace) }
        }
        .refreshable { model.openTask(taskId, in: workspace, force: true) }
        .task { start() }
        .onAppear { model.openTask(taskId, in: workspace); model.markViewed(.task, taskId, in: workspace) }
    }

    private func header(_ row: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title).font(Amb.editorial).foregroundStyle(Amb.foreground).accessibilityIdentifier("task.title")
            if let channel = snapshot.value.choice.channelName(row.task.channelId) {
                Text([snapshot.value.choice.scopeName(row.task.scopeId), "#\(channel)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Amb.mutedForeground)
            }
            HStack(spacing: 10) {
                Menu {
                    ForEach(TaskState.board + [.backlog, .archive], id: \.self) { state in
                        Button(state.label) { submit(.taskState, ["state": state.rawValue]) }
                    }
                } label: { chip(row.taskState?.label ?? row.state, systemImage: "circle.dashed") }
                    .accessibilityIdentifier("task.state")
                Menu {
                    ForEach(TaskPriority.editable, id: \.self) { p in
                        Button(p.label) { patch(row, ["priority": p.rawValue]) }
                    }
                } label: { chip(TaskPriority(rawValue: row.priority)?.label ?? row.priority, systemImage: "flag") }
                    .accessibilityIdentifier("task.priority")
                Menu {
                    Button("Unassigned") { assign(row, nil) }
                    ForEach(snapshot.value.members) { member in Button(member.label) { assign(row, member.npub) } }
                } label: {
                    chip(row.assignee.map { displayName($0, snapshot.value.names, me: model.identity.npub) } ?? "Unassigned", systemImage: "person")
                }
                .accessibilityIdentifier("task.assignee")
            }
        }
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.footnote.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(Amb.accent, in: Capsule()).foregroundStyle(Amb.accentForeground)
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comments").font(.headline).foregroundStyle(Amb.itemHeading)
            ForEach(snapshot.value.comments) { c in CommentRow(comment: c, names: snapshot.value.names, me: model.identity.npub) }
            ForEach(snapshot.value.pendingComments) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.string("body") ?? "").font(.body).foregroundStyle(Amb.mutedForeground)
                    WriteStatusLine(item: item, label: "Comment")
                }
                .accessibilityIdentifier("comment.pending")
            }
            if snapshot.value.comments.isEmpty && snapshot.value.pendingComments.isEmpty {
                Text("No comments yet.").font(.footnote).foregroundStyle(Amb.mutedForeground)
            }
        }
    }

    private var commentComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Add a comment", text: $comment, axis: .vertical)
                .lineLimit(1...5).focused($commentFocused)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Amb.muted, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityIdentifier("comment.field")
            Button {
                let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                if model.submit(WriteIntent(kind: .taskComment, targetId: taskId, payload: ["body": text]), in: workspace) { comment = "" }
            } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send comment").accessibilityIdentifier("comment.send")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
    }

    private func label(for item: WriteItem) -> String {
        switch item.kind {
        case .taskState: "State change"
        case .taskPatch: "Edit"
        case .taskAssign: "Assignment"
        default: "Change"
        }
    }

    private func submit(_ kind: WriteKind, _ payload: [String: any Sendable]) {
        model.submit(WriteIntent(kind: kind, targetId: taskId, payload: payload), in: workspace)
    }

    /// Edits record the version and values they were made on, so a concurrent change is detected, not overwritten.
    private func patch(_ row: TaskRow, _ fields: [String: String]) {
        submit(.taskPatch, ["base_row_version": row.task.rowVersion,
                            "base": ["title": row.task.title, "description": row.task.description ?? "", "priority": row.task.priority],
                            "patch": fields])
    }

    private func assign(_ row: TaskRow, _ npub: String?) {
        submit(.taskAssign, ["assigned_to_npub": npub ?? "", "base_row_version": row.task.rowVersion, "base_assigned_to_npub": row.task.assignedToNpub ?? ""])
    }

    private func start() {
        let w = workspace.id, id = taskId, store = store, connection = model.connection?.id ?? ""
        snapshot.start(store: store, matches: { $0.workspaceId == w && [.tasks, .comments, .writes, .members, .channels].contains($0.table) }) {
            async let task = store.reader.task(workspaceId: w, id: id)
            async let comments = store.reader.comments(workspaceId: w, parent: .task, parentId: id)
            async let writes = store.reader.writes(connectionId: connection, workspaceId: w, targetId: id)
            async let members = store.reader.members(workspaceId: w)
            async let choice = scopeChoice(store, w)
            let pending = try await writes
            let directory = try await members
            return TaskDetailSnapshot(row: try await task.map { TaskRow(task: $0, writes: pending.filter { $0.kind != .taskComment }) },
                                      comments: try await comments, pendingComments: pending.filter { $0.kind == .taskComment },
                                      members: directory, names: Dictionary(directory.map { ($0.npub, $0.label) }, uniquingKeysWith: { a, _ in a }),
                                      choice: try await choice)
        }
    }
}

struct CommentRow: View {
    let comment: CommentRecord
    let names: [String: String]
    let me: String?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: displayName(comment.senderNpub, names, me: me))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName(comment.senderNpub, names, me: me)).font(.subheadline.weight(.semibold))
                    Text(ChatTime.label(comment.createdAt)).font(.caption).foregroundStyle(Amb.mutedForeground)
                    if comment.status == "resolved" { Label("Resolved", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Amb.success) }
                }
                MessageBody(text: comment.body)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("comment")
    }
}

// MARK: Create and edit

struct TaskCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceRecord
    let store: LocalStore
    let choice: ScopeChoice
    let scopeId: String?
    @State private var title = ""
    @State private var detail = ""
    @State private var channelId: String?
    @State private var state = TaskState.new
    @State private var priority = TaskPriority.sand
    @State private var assignee: String?
    @State private var members: [MemberRecord] = []

    private var channels: [ChannelRecord] { choice.channels.filter { scopeId == nil || $0.scopeId == scopeId } }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title).accessibilityIdentifier("newtask.title")
                TextField("Description", text: $detail, axis: .vertical).lineLimit(3...8)
                Picker("Channel", selection: $channelId) {
                    ForEach(channels) { Text("#\($0.name) · \(choice.scopeName($0.scopeId) ?? "")").tag(Optional($0.id)) }
                }
                Picker("State", selection: $state) { ForEach(TaskState.board, id: \.self) { Text($0.label).tag($0) } }
                Picker("Priority", selection: $priority) { ForEach(TaskPriority.editable, id: \.self) { Text($0.label).tag($0) } }
                Picker("Assignee", selection: $assignee) {
                    Text("Unassigned").tag(String?.none)
                    ForEach(members) { Text($0.label).tag(Optional($0.npub)) }
                }
                if !model.isUnlocked { Text("Saved on this iPhone and sent after you unlock.").font(.footnote).foregroundStyle(Amb.mutedForeground) }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { create() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || channelId == nil)
                        .accessibilityIdentifier("newtask.add")
                }
            }
            .task {
                channelId = channelId ?? channels.first?.id
                members = (try? await store.reader.members(workspaceId: workspace.id)) ?? []
            }
        }
    }

    private func create() {
        guard let channelId else { return }
        var payload: [String: any Sendable] = ["channel_id": channelId, "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                                               "state": state.rawValue, "priority": priority.rawValue]
        let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { payload["description"] = d }
        if let assignee { payload["assigned_to_npub"] = assignee }
        if model.submit(WriteIntent(kind: .taskCreate, targetId: nil, payload: payload), in: workspace) { dismiss() }
    }
}

struct TaskEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let row: TaskRow
    let workspace: WorkspaceRecord
    @State private var title = ""
    @State private var detail = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") { TextField("Title", text: $title, axis: .vertical).lineLimit(1...4).accessibilityIdentifier("edittask.title") }
                Section("Description") { TextEditor(text: $detail).frame(minHeight: 160).accessibilityIdentifier("edittask.description") }
            }
            .navigationTitle("Edit task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("edittask.save")
                }
            }
            .onAppear { title = row.title; detail = row.task.description ?? "" }
        }
    }

    private func save() {
        var patch: [String: String] = [:]
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != row.task.title { patch["title"] = t }
        if detail != (row.task.description ?? "") { patch["description"] = detail }
        guard !patch.isEmpty else { dismiss(); return }
        let payload: [String: any Sendable] = ["base_row_version": row.task.rowVersion,
                                               "base": ["title": row.task.title, "description": row.task.description ?? "", "priority": row.task.priority],
                                               "patch": patch]
        if model.submit(WriteIntent(kind: .taskPatch, targetId: row.id, payload: payload), in: workspace) { dismiss() }
    }
}
