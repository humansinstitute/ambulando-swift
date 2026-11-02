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
            case .taskBoardChange:
                state = (p["state"] as? String) ?? state
                if let value = p["assignee"] as? String { assignee = value.isEmpty ? nil : value }
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
    var agents: [MemberRecord] = []
    var boardWrites: [WriteItem] = []
}

struct TasksView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @SceneStorage("tasks.board") private var board = false
    /// The shared sidebar context (scope, channel or Home); the list reads and new records are written inside it.
    private var context: WorkContext { model.context }
    private var scopeId: String? { model.context.scopeId }
    @State private var snapshot = LiveQuery<TasksSnapshot>(initial: TasksSnapshot())
    @State private var creating = false
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var feedback: String?
    @State private var archiveConfirmation = false
    @State private var targeted: TaskState?
    @AppStorage("tasks.collapsed.v1") private var collapseJSON = "{}"
    @AppStorage("tasks.defaultAgent.v1") private var agentJSON = "{}"

    private var preferenceKey: String { "\(model.connection?.id ?? "")/\(workspace.appNpub)/\(workspace.id)/\(model.identity.npub ?? "")" }
    private var collapsed: Set<String> { Set((decodePreferences(collapseJSON)[preferenceKey] as? [String]) ?? []) }
    private var defaultAgent: String? {
        guard let npub = decodePreferences(agentJSON)[preferenceKey] as? String,
              snapshot.value.agents.contains(where: { $0.npub == npub }) else { return nil }
        return npub
    }
    private var parents: Set<String> { Set(snapshot.value.rows.compactMap { TaskTreeNode($0.task).parentId }) }
    private var selectable: [TaskRow] { snapshot.value.rows.filter { !parents.contains($0.id) && $0.pending.isEmpty } }
    private var canWrite: Bool { model.isUnlocked && model.connection != nil && model.selectedWorkspace?.id == workspace.id }

    var body: some View {
        VStack(spacing: 0) {
            ListHeaderBar {
                if board {
                    Button(selecting ? "Cancel" : "Select") {
                        selecting.toggle(); selected.removeAll(); feedback = nil
                    }.disabled(busy)
                        .keyboardShortcut(selecting ? .escape : "s", modifiers: selecting ? [] : [.command, .shift])
                        .accessibilityIdentifier("tasks.select")
                    if selecting { selectionMenu }
                }
                Spacer()
                Picker("Layout", selection: $board) {
                    Image(systemName: "list.bullet").tag(false).accessibilityLabel("List")
                    Image(systemName: "rectangle.split.3x1").tag(true).accessibilityLabel("Board")
                }
                .pickerStyle(.segmented).frame(width: 110)
                .labelsHidden()
                .accessibilityIdentifier("tasks.layout")
                Button { creating = true } label: { Image(systemName: "plus.circle.fill").font(.amb(.title2)) }
                    .accessibilityLabel("New task").accessibilityIdentifier("tasks.new")
            }
            Group { if board { boardView } else { listView } }
            boardFeedback
        }
        .navigationTitle("Tasks")
        .confirmationDialog("Archive \(selected.count) selected tasks?", isPresented: $archiveConfirmation, titleVisibility: .visible) {
            Button("Archive selected", role: .destructive) { apply(.archive) }
        }

        .onChange(of: preferenceKey) { _, _ in selected.removeAll(); selecting = false; feedback = nil }
        .onChange(of: model.context) { _, _ in selected.removeAll(); selecting = false; feedback = nil }
        .onChange(of: board) { _, _ in selected.removeAll(); selecting = false }
        .onChange(of: snapshot.value.rows) { _, _ in selected.formIntersection(Set(selectable.map(\.id))) }
        .onKeyPress(.escape) { if !busy { selected.removeAll(); selecting = false }; return .handled }
        .sheet(isPresented: $creating) {
            TaskCreateSheet(workspace: workspace, store: store, choice: snapshot.value.choice, context: context)
        }
        .refreshable { model.openTasks(workspace, scopeId: scopeId, force: true) }
        .task(id: model.context) { start(); model.openTasks(workspace, scopeId: scopeId) }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { model.openTasks(workspace, scopeId: scopeId) } }
    }

    private var boardFeedback: some View {
        ScrollView {
            VStack(spacing: 4) {
                if let feedback { Text(feedback).font(.amb(.caption)).accessibilityIdentifier("tasks.feedback") }
                ForEach(snapshot.value.boardWrites) { item in
                    WriteStatusLine(item: item, label: item.string("task_title") ?? "Board action")
                }
            }.padding(10).frame(maxWidth: .infinity)
        }
        .frame(maxHeight: snapshot.value.boardWrites.isEmpty && feedback == nil ? 0 : 110)
        .background(Amb.card)
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
                            Text(item.string("title") ?? "Task").font(.amb(.subheadline).weight(.semibold))
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
                                        Button { setState(row, .done) } label: { Label("Done", systemImage: "checkmark") }.tint(Amb.taskStatus("done"))
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    if row.taskState != .inProgress {
                                        Button { setState(row, .inProgress) } label: { Label("Start", systemImage: "play") }.tint(Amb.taskStatus("in_progress"))
                                    }
                                }
                        }
                    } header: {
                        HStack { TaskStatusBadge(state: state.rawValue); Text("\(rows.count)") }.textCase(nil)
                    }
                }
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
        .overlay {
            if snapshot.loaded && snapshot.value.rows.isEmpty && snapshot.value.creating.isEmpty {
                EmptyNote(title: "No tasks", systemImage: "checklist", detail: model.isUnlocked ? "Tasks in this scope appear here. Tap + to add one." : "Unlock to load tasks.")
            }
        }
    }

    private var selectionMenu: some View {
        Menu {
            Button("Select visible") { selected.formUnion(selectable.map(\.id)) }
                .keyboardShortcut("a", modifiers: .command)
                .accessibilityIdentifier("tasks.selectVisible")
            Button("Clear selection") { selected.removeAll() }
            ForEach(TaskBoardAction.allCases, id: \.self) { action in
                Button(action.label) {
                    if action == .archive { archiveConfirmation = true } else { apply(action) }
                }
                .disabled(selected.isEmpty || !canWrite || (action == .ready && defaultAgent == nil))
                .accessibilityIdentifier("tasks.bulk.\(action.rawValue)")
            }
            Menu("Default agent on this device") {
                ForEach(snapshot.value.agents) { agent in
                    Button(displayName(agent.npub, snapshot.value.names, me: model.identity.npub)) {
                        savePreference(agent.npub, in: &agentJSON)
                    }
                }
            }
            if defaultAgent == nil { Text("Choose a default agent to mark tasks ready.") }
        } label: { Text(busy ? "Queuing…" : "\(selected.count) selected") }
        .disabled(busy).accessibilityIdentifier("tasks.actions")
    }

    private var boardView: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(columns, id: \.0) { state, rows in boardColumn(state, rows: rows) }
            }
            .scrollTargetLayout().padding(12)
        }
        .scrollTargetBehavior(.viewAligned)
    }

    private func boardColumn(_ state: TaskState, rows: [TaskRow]) -> some View {
        let closed = collapsed.contains(state.rawValue)
        return VStack(alignment: .leading, spacing: 8) {
            if closed {
                VStack(spacing: 8) {
                    collapseButton(state, closed: true)
                    columnSelection(state, rows: rows)
                    Text(state.label).font(.amb(.subheadline).weight(.semibold))
                        .fixedSize().rotationEffect(.degrees(90)).frame(width: 24, height: 110)
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                }.frame(maxWidth: .infinity)
            } else {
                HStack {
                    collapseButton(state, closed: false)
                    TaskStatusBadge(state: state.rawValue)
                    Spacer(minLength: 0)
                    columnSelection(state, rows: rows)
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { row in boardCard(row) }
                        if rows.isEmpty { Text("Nothing here").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).padding(.vertical, 20) }
                    }.frame(maxWidth: .infinity, minHeight: 120, alignment: .top)
                }
            }
        }
        .padding(closed ? 4 : 10)
        .frame(width: closed ? 44 : 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Amb.muted.opacity(0.6), in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(targeted == state ? Amb.accentForeground : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
            guard values.count == 1, let text = values.first,
                  let id = TaskBoardDrag.taskId(from: text, signer: model.identity.npub ?? "", connection: model.connection?.id ?? "", workspace: workspace.id, app: workspace.appNpub),
                  let row = snapshot.value.rows.first(where: { $0.id == id }), canChange(row) else { return false }
            if row.state != state.rawValue { setState(row, state) }
            return true
        } isTargeted: { value in targeted = value ? state : nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.\(state.rawValue)")
    }

    private func collapseButton(_ state: TaskState, closed: Bool) -> some View {
        Button {
            var values = collapsed
            if closed { values.remove(state.rawValue) } else { values.insert(state.rawValue) }
            savePreference(Array(values).sorted(), in: &collapseJSON)
        } label: { Image(systemName: closed ? "chevron.right" : "chevron.left").frame(minWidth: 32, minHeight: 32).contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .accessibilityLabel("\(closed ? "Expand" : "Collapse") \(state.label)")
        .accessibilityIdentifier("board.collapse.\(state.rawValue)")
    }

    private func columnSelection(_ state: TaskState, rows: [TaskRow]) -> some View {
        Button {
            selecting = true
            selected = TaskBoardSelection.togglingColumn(selected, ids: Set(rows.filter { canChange($0) }.map(\.id)))
        } label: { Text("\(rows.count)").monospacedDigit().frame(minWidth: 32, minHeight: 32).contentShape(Rectangle()) }
        .buttonStyle(.plain).disabled(busy)
        .accessibilityLabel("Select tasks in \(state.label), \(rows.count) tasks")
        .accessibilityIdentifier("board.select.\(state.rawValue)")
    }

    private func boardCard(_ row: TaskRow) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if !parents.contains(row.id) {
                Button { toggle(row) } label: {
                    Image(systemName: selected.contains(row.id) ? "checkmark.square.fill" : "square")
                        .frame(minWidth: 32, minHeight: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canChange(row)).accessibilityLabel("\(selected.contains(row.id) ? "Deselect" : "Select") \(row.title)")
                .accessibilityIdentifier("board.check.\(row.title)")
            }
            if selecting {
                Button { toggle(row) } label: { cardContent(row) }.buttonStyle(.plain).disabled(!canChange(row))
            } else {
                NavigationLink(value: WorkRoute.task(workspaceId: workspace.id, taskId: row.id)) { cardContent(row) }.buttonStyle(.plain)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected.contains(row.id) ? Amb.accent : Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(selected.contains(row.id) ? Amb.accentForeground : .clear))
        .contextMenu {
            Button(selected.contains(row.id) ? "Deselect" : "Select") { toggle(row) }.disabled(!canChange(row))
            ForEach(TaskState.board.filter { $0.rawValue != row.state }, id: \.self) { target in
                Button("Move to \(target.label)") { setState(row, target) }.disabled(!canChange(row))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.card.\(row.title)")
        .modifier(TaskCardDrag(text: TaskBoardDrag(signer: model.identity.npub ?? "", connection: model.connection?.id ?? "", workspace: workspace.id, app: workspace.appNpub, task: row.id).text, enabled: canChange(row)))
    }

    private func cardContent(_ row: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TaskRowView(row: row, snapshot: snapshot.value, me: model.identity.npub, showsStatus: false)
            if let failure = row.pending.first(where: { !$0.isPending }) {
                WriteStatusLine(item: failure, label: "Board change")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func canChange(_ row: TaskRow) -> Bool { canWrite && !busy && !parents.contains(row.id) && row.pending.isEmpty }
    private func toggle(_ row: TaskRow) {
        guard canChange(row) else { return }
        selecting = true
        if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) }
    }

    private func setState(_ row: TaskRow, _ state: TaskState) {
        guard row.state != state.rawValue, canChange(row) else { return }
        model.submit(WriteIntent(kind: .taskState, targetId: row.id, payload: ["state": state.rawValue]), in: workspace)
    }

    private func apply(_ action: TaskBoardAction) {
        guard !busy, canWrite, let sender = model.writes, let connection = model.connection else { return }
        let rows = snapshot.value.rows.filter { selected.contains($0.id) && canChange($0) }
        let boundary = model.selectedWorkspaceBoundary
        let originContext = context
        let agent = defaultAgent
        busy = true
        Task { @MainActor in
            var queued = Set<String>(), failed = 0
            for row in rows {
                guard boundary == model.selectedWorkspaceBoundary, originContext == model.context else { break }
                guard let intent = action.intent(for: row.task, agent: agent) else { failed += 1; continue }
                do { _ = try await sender.submit(intent, connection: connection, workspace: workspace); queued.insert(row.id) }
                catch { failed += 1 }
            }
            busy = false
            guard boundary == model.selectedWorkspaceBoundary, originContext == model.context else { return }
            selected.subtract(queued)
            feedback = "\(queued.count) queued. \(failed > 0 ? "\(failed) could not be queued; selection kept. " : "")Changes save when connected. Failed or partial actions appear below and in task details."
        }
    }

    private func decodePreferences(_ value: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] ?? [:]
    }
    private func savePreference(_ value: Any, in storage: inout String) {
        var preferences = decodePreferences(storage); preferences[preferenceKey] = value
        if let data = try? JSONSerialization.data(withJSONObject: preferences, options: [.sortedKeys]) { storage = String(decoding: data, as: UTF8.self) }
    }

    private func start() {
        let w = workspace.id, context = context, store = store, connection = model.connection?.id ?? ""
        snapshot.start(store: store, matches: { ($0.workspaceId == w && [.tasks, .writes, .members, .channels, .scopes].contains($0.table)) || $0.table == .profiles }) {
            async let tasks = store.reader.tasks(workspaceId: w, context: context, limit: 500)
            async let writes = store.reader.writes(connectionId: connection, workspaceId: w)
            async let choice = scopeChoice(store, w)
            async let names = directoryNames(store, w)
            async let members = store.reader.members(workspaceId: w)
            let pending = try await writes
            let creating = pending.filter { $0.kind == .taskCreate }
            return TasksSnapshot(rows: try await tasks.map { TaskRow(task: $0, writes: pending) }, creating: creating,
                                 choice: try await choice, names: try await names, agents: try await members.filter { $0.kind == "agent" },
                                 boardWrites: pending.filter { $0.kind == .taskBoardChange })
        }
    }
}

private struct TaskCardDrag: ViewModifier {
    let text: String
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.draggable(text) } else { content }
    }
}

struct TaskRowView: View {
    let row: TaskRow
    let snapshot: TasksSnapshot
    let me: String?
    var showsStatus = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(3)
            HStack(spacing: 8) {
                if showsStatus { TaskStatusBadge(state: row.state) }
                PriorityBadge(priority: row.priority)
                if let channel = snapshot.choice.channelName(row.task.channelId) { Text("#\(channel)").lineLimit(1) }
                if let assignee = row.assignee { Label(displayName(assignee, snapshot.names, me: me), systemImage: "person").lineLimit(1) }
                if row.pending.contains(where: \.isPending) { Image(systemName: "arrow.up.circle").accessibilityLabel("Change not sent yet") }
                if row.pending.contains(where: { !$0.isPending }) { Image(systemName: "exclamationmark.circle").foregroundStyle(Amb.destructive).accessibilityLabel("Change not saved") }
            }
            .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
        }
    }
}

struct PriorityBadge: View {
    let priority: String
    var body: some View {
        Text((TaskPriority(rawValue: priority)?.label ?? priority).uppercased())
            .font(.amb(.caption2).weight(.bold))
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
    var people = PeopleDirectory()
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

    @State private var commentsExpanded = false
    @State private var compactTab = TaskDetailTab.task

    enum TaskDetailTab: String, CaseIterable { case task = "Task", comments = "Comments" }

    /// Wide windows show details beside an independent comments panel; narrow ones switch between the two.
    private static let splitWidth: CGFloat = 700

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Self.splitWidth
            Group {
                if wide { splitLayout(width: proxy.size.width) } else { tabbedLayout }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Amb.background)
        .fixtureLabel()
        .navigationTitle("Task")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button("Edit") { editing = true }.disabled(snapshot.value.row == nil).accessibilityIdentifier("task.edit")
            }
        }
        .sheet(isPresented: $editing) {
            if let row = snapshot.value.row { TaskEditSheet(row: row, workspace: workspace) }
        }
        .task { start() }
        .onAppear { model.openTask(taskId, in: workspace); model.markViewed(.task, taskId, in: workspace) }
    }

    private func splitLayout(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if !commentsExpanded {
                detailScroll
                Divider()
            }
            commentsPanel(expandable: true)
                .frame(width: commentsExpanded ? nil : min(max(320, width * 0.4), 480))
                .frame(maxWidth: commentsExpanded ? .infinity : nil)
        }
    }

    private var tabbedLayout: some View {
        VStack(spacing: 0) {
            switch compactTab {
            case .task: detailScroll
            case .comments: commentsPanel(expandable: false).tabletReadingWidth()
            }
            Divider()
            Picker("Section", selection: $compactTab) {
                ForEach(TaskDetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8)
            .accessibilityIdentifier("task.tabs")
            .background(Amb.card)
        }
    }

    private var detailScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let row = snapshot.value.row {
                    header(row)
                    TaskSubtasksView(taskId: taskId, workspace: workspace, store: store, ancestors: [taskId])
                    ForEach(row.pending) { WriteStatusLine(item: $0, label: label(for: $0)) }
                    if let description = row.task.description, !description.isEmpty {
                        MessageBody(text: description, workspace: workspace).ambCard()
                    }
                } else if snapshot.loaded {
                    SyncNote(text: model.isUnlocked ? "Loading task…" : "This task is not saved on this \(Device.name) yet. Unlock to load it.")
                }
                if let error = model.syncError(forKey: WorkspaceSync.taskKey(workspace.id, taskId)) { SyncNote(text: error, tone: .warning) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tabletReadingWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { model.openTask(taskId, in: workspace, force: true) }
    }

    private func header(_ row: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title).font(Amb.editorial).foregroundStyle(Amb.foreground).accessibilityIdentifier("task.title")
            if let channel = snapshot.value.choice.channelName(row.task.channelId) {
                Text([snapshot.value.choice.scopeName(row.task.scopeId), "#\(channel)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            }
            HStack(spacing: 10) {
                Menu {
                    ForEach(TaskState.board + [.backlog, .archive], id: \.self) { state in
                        Button(state.label) { submit(.taskState, ["state": state.rawValue]) }
                    }
                } label: { TaskStatusBadge(state: row.state).frame(minHeight: 44) }
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
        Label(text, systemImage: systemImage).font(.amb(.footnote).weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(Amb.accent, in: Capsule()).foregroundStyle(Amb.accentForeground)
    }

    private var commentCount: Int { snapshot.value.comments.count + snapshot.value.pendingComments.count }

    /// Newest first: unsent comments are the newest, then saved ones by time.
    private var newestFirst: [CommentRecord] { snapshot.value.comments.sorted { $0.createdAt > $1.createdAt } }

    private func commentsPanel(expandable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comments").font(.amb(.headline)).foregroundStyle(Amb.itemHeading)
                    Text(commentCount == 1 ? "1 comment" : "\(commentCount) comments").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
                Spacer()
                if expandable {
                    Button { commentsExpanded.toggle() } label: {
                        Image(systemName: commentsExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain).foregroundStyle(Amb.mutedForeground)
                    .accessibilityLabel(commentsExpanded ? "Restore comments" : "Expand comments")
                    .accessibilityIdentifier("task.comments.expand")
                }
            }
            commentComposer
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.value.pendingComments.reversed()) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.string("body") ?? "").font(.amb(.body)).foregroundStyle(Amb.mutedForeground)
                            WriteStatusLine(item: item, label: "Comment")
                        }
                        .accessibilityIdentifier("comment.pending")
                    }
                    ForEach(newestFirst) { c in CommentRow(comment: c, people: snapshot.value.people, workspace: workspace) }
                    if commentCount == 0 {
                        Text("No comments yet.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(16)
        .background(Amb.background)
    }

    private var commentComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ContentTextEntry(text: $comment, placeholder: "Add a comment", workspace: workspace, field: "task-comment-\(taskId)", actorMentions: true)
                .lineLimit(1...5).focused($commentFocused)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Amb.muted, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityIdentifier("comment.field")
            Button {
                let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                if model.submit(WriteIntent(kind: .taskComment, targetId: taskId, payload: ["body": text, "mentions": CommentMentions.actors(in: text).map(\.requestObject)]), in: workspace) { comment = "" }
            } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send comment").accessibilityIdentifier("comment.send")
        }
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
        snapshot.start(store: store, matches: { ($0.workspaceId == w && [.tasks, .comments, .writes, .members, .agents, .channels].contains($0.table)) || $0.table == .profiles }) {
            async let task = store.reader.task(workspaceId: w, id: id)
            async let comments = store.reader.comments(workspaceId: w, parent: .task, parentId: id)
            async let writes = store.reader.writes(connectionId: connection, workspaceId: w, targetId: id)
            async let people = store.reader.people(connectionId: connection, workspaceId: w)
            async let members = store.reader.directoryMembers(workspaceId: w)
            async let choice = scopeChoice(store, w)
            let pending = try await writes
            let directory = try await members
            return TaskDetailSnapshot(row: try await task.map { TaskRow(task: $0, writes: pending.filter { $0.kind != .taskComment }) },
                                      comments: try await comments, pendingComments: pending.filter { $0.kind == .taskComment }, people: try await people,
                                      members: directory, names: Dictionary(directory.map { ($0.npub, $0.label) }, uniquingKeysWith: { a, _ in a }),
                                      choice: try await choice)
        }
    }
}

struct CommentRow: View {
    let comment: CommentRecord
    let people: PeopleDirectory
    var workspace: WorkspaceRecord? = nil
    var body: some View {
        let person = comment.author(in: people)
        HStack(alignment: .top, spacing: 10) {
            PersonAvatar(person: person)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(person.name).font(.amb(.subheadline).weight(.semibold))
                    Text(ChatTime.label(comment.createdAt)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                    if comment.status == "resolved" { Label("Resolved", systemImage: "checkmark.circle").font(.amb(.caption)).foregroundStyle(Amb.success) }
                }
                MessageBody(text: comment.body, workspace: workspace)
            }
        }
        .accessibilityElement(children: .contain)
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
    let context: WorkContext
    var parentTaskId: String? = nil
    var parentChannelId: String? = nil
    @State private var title = ""
    @State private var detail = ""
    @State private var channelId: String?
    @State private var state = TaskState.new
    @State private var priority = TaskPriority.sand
    @State private var assignee: String?
    @State private var members: [MemberRecord] = []

    private var channels: [ChannelRecord] { choice.channels(in: context).filter { parentChannelId == nil || $0.id == parentChannelId } }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title).accessibilityIdentifier("newtask.title")
                ContentTextEntry(text: $detail, placeholder: "Description", workspace: workspace, field: "new-task-description").lineLimit(3...8)
                Picker("Channel", selection: $channelId) {
                    ForEach(channels) { Text("#\($0.name) · \(choice.scopeName($0.scopeId) ?? "")").tag(Optional($0.id)) }
                }
                .disabled(parentTaskId != nil)
                Picker("State", selection: $state) { ForEach(TaskState.board, id: \.self) { Text($0.label).tag($0) } }
                Picker("Priority", selection: $priority) { ForEach(TaskPriority.editable, id: \.self) { Text($0.label).tag($0) } }
                Picker("Assignee", selection: $assignee) {
                    Text("Unassigned").tag(String?.none)
                    ForEach(members) { Text($0.label).tag(Optional($0.npub)) }
                }
                if !model.isUnlocked { Text("Saved on this \(Device.name) and sent after you unlock.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground) }
            }
            .navigationTitle(parentTaskId == nil ? "New task" : "Add subtask")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { create() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || channelId == nil)
                        .accessibilityIdentifier("newtask.add")
                }
            }
            .task {
                channelId = parentChannelId ?? channelId ?? context.channelId ?? channels.first?.id
                members = (try? await store.reader.directoryMembers(workspaceId: workspace.id)) ?? []
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
        if let parentTaskId { payload["metadata"] = ["parent_task_id": parentTaskId] }
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
                Section("Description") { ContentTextEntry(text: $detail, placeholder: "Description", workspace: workspace, field: "task-description-\(row.task.id)", multilineEditor: true).frame(minHeight: 160).accessibilityIdentifier("edittask.description") }
            }
            .navigationTitle("Edit task")
            .inlineTitle()
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

private struct SubtaskSnapshot: Sendable, Equatable {
    var children: [TaskRecord] = []
    var parentId: String?
    var parent: TaskRecord?
    var cache: TaskRelationshipCache?
    var choice = ScopeChoice()
    var task: TaskRecord?
    var pending: [WriteItem] = []
}

/// Each expanded parent observes the same local store and loads its own paginated relationship list.
/// Cycles are displayed as links but never recursively expanded.
struct TaskSubtasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pushRoute) private var pushRoute
    let taskId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    let ancestors: Set<String>
    var showParent = true
    @State private var snapshot = LiveQuery<SubtaskSnapshot>(initial: SubtaskSnapshot())
    @State private var expanded: Set<String> = []
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showParent, let parentId = snapshot.value.parentId {
                if let parent = snapshot.value.parent {
                    Button { pushRoute(.task(workspaceId: workspace.id, taskId: parentId)) } label: {
                        Label("Parent: \(parent.title)", systemImage: "arrow.up.left")
                    }.accessibilityIdentifier("task.parent")
                } else {
                    Text("Parent task unavailable on this device or access is restricted.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                }
            }
            HStack {
                Text("Subtasks (\(snapshot.value.children.count)\(confirmed ? "" : "+"))").font(.amb(.headline))
                Spacer()
                if showParent {
                    Button("Add subtask") { adding = true }.disabled(snapshot.value.task == nil)
                        .accessibilityIdentifier("task.subtasks.add")
                    Button { refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh subtasks")
                }
            }
            if let error = model.syncError(forKey: TaskRelationshipCache.key(workspace.id, taskId)) {
                SyncNote(text: "Subtasks could not refresh. Showing saved tasks. \(error)", tone: .warning)
            } else if !model.canRead {
                SyncNote(text: "Offline or locked. Showing saved subtasks; connect and unlock to refresh.")
            } else if snapshot.value.cache == nil {
                SyncNote(text: "Loading subtasks… Saved tasks may be incomplete.")
            }
            if snapshot.value.cache?.unavailable == true {
                SyncNote(text: "Some relationships are unavailable or restricted. The count includes only saved readable subtasks.", tone: .warning)
            } else if let cache = snapshot.value.cache, !cache.complete {
                SyncNote(text: "Subtasks partially loaded. Refresh to retry the remaining relationships.", tone: .warning)
            }
            if snapshot.value.cache != nil {
                Text("Saved relationship list.").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            }
            ForEach(snapshot.value.pending) { item in
                VStack(alignment: .leading) {
                    Text(item.string("title") ?? "New subtask")
                    WriteStatusLine(item: item, label: "Add subtask")
                }
            }
            if snapshot.value.children.isEmpty && snapshot.value.pending.isEmpty && confirmed { Text("No subtasks.").foregroundStyle(Amb.mutedForeground) }
            ForEach(snapshot.value.children) { child in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        if !ancestors.contains(child.id) {
                            Button {
                                if !expanded.insert(child.id).inserted { expanded.remove(child.id) }
                            } label: { Image(systemName: expanded.contains(child.id) ? "chevron.down" : "chevron.right") }
                            .accessibilityLabel("Expand subtasks of \(child.title)")
                        }
                        Button { pushRoute(.task(workspaceId: workspace.id, taskId: child.id)) } label: {
                            VStack(alignment: .leading) {
                                Text(child.title).multilineTextAlignment(.leading)
                                TaskStatusBadge(state: child.state)
                                    .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                            }
                        }.accessibilityIdentifier("task.subtask.\(child.id)")
                    }
                    if expanded.contains(child.id), !ancestors.contains(child.id) {
                        TaskSubtasksView(taskId: child.id, workspace: workspace, store: store,
                                         ancestors: ancestors.union([child.id]), showParent: false)
                            .padding(.leading, 20)
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $adding) {
            if let task = snapshot.value.task {
                TaskCreateSheet(workspace: workspace, store: store, choice: snapshot.value.choice,
                                context: WorkContext(scopeId: task.scopeId, channelId: task.channelId), parentTaskId: task.id, parentChannelId: task.channelId)
            }
        }
        .task {
            start()
            refresh()
            // Foreground fallback covers relationship events missed while this detail remains open.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                refresh(force: true)
            }
        }
        .onChange(of: model.identity) { _, _ in refresh(force: true) }
    }

    private var confirmed: Bool { snapshot.value.cache?.complete == true && snapshot.value.cache?.unavailable == false && model.canRead && model.syncError(forKey: TaskRelationshipCache.key(workspace.id, taskId)) == nil }

    private func refresh(force: Bool = false) {
        model.withWorkspace(workspace) { sync, c in
            await sync.refreshTaskRelationships(c, workspace, taskId: taskId, force: force)
        }
    }

    private func start() {
        let w = workspace.id, id = taskId, store = store, connection = model.connection?.id ?? ""
        snapshot.start(store: store, matches: { ($0.workspaceId == w && [.tasks, .channels, .writes].contains($0.table)) || $0.table == .appState }) {
            let task = try await store.reader.task(workspaceId: w, id: id)
            let parentId = task.map { TaskTreeNode($0).parentId } ?? nil
            let parent: TaskRecord?
            if let parentId { parent = try await store.reader.task(workspaceId: w, id: parentId) } else { parent = nil }
            return SubtaskSnapshot(children: try await store.reader.directSubtasks(workspaceId: w, taskId: id),
                                   parentId: parentId, parent: parent,
                                   cache: try await store.reader.taskRelationshipCache(workspaceId: w, taskId: id),
                                   choice: try await scopeChoice(store, w), task: task,
                                   pending: try await store.reader.writes(connectionId: connection, workspaceId: w).filter {
                                       $0.kind == .taskCreate && ($0.payloadObject["metadata"] as? [String: Any])?["parent_task_id"] as? String == id
                                   })
        }
    }
}
