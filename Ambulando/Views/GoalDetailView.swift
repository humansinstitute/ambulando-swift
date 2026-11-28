import AmbulandoCore
import SwiftUI

/// One goal, as in the approved example: name, description, dates, an editable timeline of checkpoints and the work
/// associated with it across channels. Links are references: titles and places always come from the source record, and
/// removing a link never touches the source.
struct GoalDetailView: View {
    @Environment(AppModel.self) private var model
    let fileId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var associations = LiveQuery<GoalWorkSnapshot>(initial: GoalWorkSnapshot())
    private var links: [ResolvedGoalLink] { associations.value.links }
    @State private var editing = false
    @State private var checkpointForm: CheckpointForm?
    @State private var picking = false
    @State private var pinning = false
    @State private var actionError: String?

    private var goals: GoalsModel? { model.goalsModel(for: workspace, allAccessible: true) }
    private var document: GoalDocument? { goals?.goal(fileId) }

    var body: some View {
        Group {
            if let goals, let document { detail(goals, document) }
            else if goals?.loaded == true {
                ContentUnavailableView("Goal not found", systemImage: "target", description: Text("It may have been removed, or you may no longer have access."))
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle(document?.goal.name ?? "Goal")
        .task(id: (model.selectedWorkspaceBoundary?.id ?? "") + ":" + fileId) {
            guard let goals else { return }
            if goals.goal(fileId) == nil { await goals.refresh() }
            await goals.reload(fileId)
        }
        .task(id: GoalAssociationLoadKey(boundaryId: model.selectedWorkspaceBoundary?.id, fileId: fileId, goal: document?.goal)) { await resolve() }
        .onDisappear { associations.stop() }
        .alert("Couldn’t save", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    private func resolve() async {
        guard let goal = document?.goal else { associations.stop(); return }
        let w = workspace.id, id = fileId, store = store
        associations.start(store: store, matches: { $0.table == .access || ($0.workspaceId == w && [.threads, .tasks, .docs, .files, .channels, .scopes].contains($0.table)) }) {
            async let linked = store.reader.associatedGoalLinks(workspaceId: w, goalId: id, explicit: goal.links)
            async let pinned = store.reader.resolveGoalLinks(workspaceId: w, links: goal.pinnedRefs)
            return try await GoalWorkSnapshot(links: linked, pins: pinned)
        }
    }

    private func run(_ edits: GoalEdit...) {
        guard let goals else { return }
        Task {
            do { try await goals.edit(fileId, edits) }
            catch {
                actionError = GoalsModel.message(error)
                await goals.reload(fileId)
            }
        }
    }

    private func detail(_ goals: GoalsModel, _ document: GoalDocument) -> some View {
        let goal = document.goal
        let editable = goal.status != .archived
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(goal)
                Text(goal.description).font(.amb(.body)).foregroundStyle(Amb.foreground).textSelection(.enabled)
                dates(goal)
                GoalDiscussionControls(goals: goals, document: document, workspace: workspace, store: store)
                    .id(goals.boundary.id + ":" + document.id)
                pins(goal, editable: editable)
                timeline(goal, editable: editable)
                work(goal, editable: editable)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Amb.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    switch goal.status {
                    case .active:
                        Button("Mark complete", systemImage: "checkmark.circle") { run(.setStatus(expected: .active, value: .completed)) }
                        Button("Archive", systemImage: "archivebox") { run(.setStatus(expected: .active, value: .archived)) }
                    case .completed:
                        Button("Reopen", systemImage: "arrow.uturn.backward") { run(.setStatus(expected: .completed, value: .active)) }
                        Button("Archive", systemImage: "archivebox") { run(.setStatus(expected: .completed, value: .archived)) }
                    case .archived:
                        Button("Restore", systemImage: "arrow.uturn.backward") { run(.setStatus(expected: .archived, value: .active)) }
                    }
                } label: { Label("More", systemImage: "ellipsis.circle") }.accessibilityIdentifier("goal.more")
            }
        }
        .sheet(isPresented: $editing) { GoalFormSheet(goals: goals, existing: document) }
        .sheet(item: $checkpointForm) { form in
            CheckpointFormSheet(form: form) { run($0) }
        }
        .sheet(isPresented: $picking) {
            GoalLinkPicker(workspace: workspace, store: store, linked: Set(goal.links.map(\.key))) { link in run(.link(link)) }
        }
        .sheet(isPresented: $pinning) {
            GoalLinkPicker(workspace: workspace, store: store, linked: Set(goal.pinnedRefs.map(\.key)), pinsOnly: true) { link in
                try await goals.pinReference(goalFileId: document.id, link: link)
            }
        }
        .accessibilityIdentifier("goal.detail")
    }

    private func header(_ goal: Goal) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PERSONAL GOAL").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                Text(goal.name).font(Amb.editorial).foregroundStyle(Amb.foreground).textSelection(.enabled)
                if goal.status != .active {
                    Text(goal.status == .completed ? "Completed" : "Archived").font(.amb(.caption).weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(goal.status == .completed ? Amb.successBackground : Amb.muted, in: Capsule())
                        .foregroundStyle(goal.status == .completed ? Amb.success : Amb.mutedForeground)
                }
            }
            Spacer()
            if goal.status != .archived {
                Button("Edit goal") { editing = true }.accessibilityIdentifier("goal.edit")
            }
        }
    }

    @ViewBuilder private func dates(_ goal: Goal) -> some View {
        if goal.startDate != nil || goal.targetDate != nil {
            HStack(spacing: 20) {
                if let s = GoalFormat.date(goal.startDate) { Text("Started ").foregroundStyle(Amb.mutedForeground) + Text(s).bold() }
                if let t = GoalFormat.date(goal.targetDate) { Text("Target ").foregroundStyle(Amb.mutedForeground) + Text(t).bold() }
            }.font(.amb(.subheadline))
        }
    }

    // MARK: Timeline

    private func timeline(_ goal: Goal, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Timeline").font(.amb(.title3).weight(.semibold))
                Spacer()
                Text(GoalFormat.progress(goal)).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            }
            ForEach(Array(goal.checkpoints.enumerated()), id: \.element.id) { index, checkpoint in
                HStack(alignment: .top, spacing: 12) {
                    Button { run(.setReached(id: checkpoint.id, expected: checkpoint.reached, reached: !checkpoint.reached)) } label: {
                        Image(systemName: checkpoint.reached ? "checkmark.circle.fill" : (goal.nextCheckpointId == checkpoint.id ? "circle.inset.filled" : "circle"))
                            .font(.amb(.title3))
                            .foregroundStyle(checkpoint.reached ? Amb.success : (goal.nextCheckpointId == checkpoint.id ? Amb.primary : Amb.mutedForeground))
                    }
                    .buttonStyle(.plain).disabled(!editable)
                    .accessibilityLabel(checkpoint.reached ? "Mark \(checkpoint.title) not reached" : "Mark \(checkpoint.title) reached")
                    VStack(alignment: .leading, spacing: 2) {
                        if let date = GoalFormat.short(checkpoint.date) { Text(date).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
                        HStack(spacing: 6) {
                            Text(checkpoint.title).font(.amb(.body).weight(.semibold)).foregroundStyle(Amb.foreground)
                            if goal.nextCheckpointId == checkpoint.id {
                                Text("Next").font(.amb(.caption).weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Amb.accent, in: Capsule()).foregroundStyle(Amb.accentForeground)
                            }
                        }
                        if let d = checkpoint.description { Text(d).font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground) }
                    }
                    Spacer(minLength: 0)
                    if editable {
                        Menu {
                            Button("Edit", systemImage: "pencil") { checkpointForm = CheckpointForm(editing: checkpoint) }
                            Button("Move up", systemImage: "arrow.up") { run(.moveCheckpoint(id: checkpoint.id, toIndex: index - 1)) }.disabled(index == 0)
                            Button("Move down", systemImage: "arrow.down") { run(.moveCheckpoint(id: checkpoint.id, toIndex: index + 1)) }.disabled(index == goal.checkpoints.count - 1)
                            Button("Remove", systemImage: "trash", role: .destructive) { run(.removeCheckpoint(id: checkpoint.id)) }
                        } label: { Image(systemName: "ellipsis") }
                        .menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Checkpoint actions for \(checkpoint.title)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("checkpoint.\(checkpoint.title)")
            }
            if editable {
                Button { checkpointForm = CheckpointForm(editing: nil) } label: { Label("Add checkpoint", systemImage: "plus") }
                    .accessibilityIdentifier("goal.addCheckpoint")
            }
        }
    }

    // MARK: Associated work

    private func work(_ goal: Goal, editable: Bool) -> some View {
        let groups: [(String, String, [ResolvedGoalLink])] = [
            ("Chats", "bubble.left.and.bubble.right", links.filter { $0.link.type == .chat }),
            ("Tasks", "checklist", links.filter { $0.link.type == .task }),
            ("Artefacts", "doc.text", links.filter { $0.link.type == .doc || $0.link.type == .file }),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Associated work").font(.amb(.title3).weight(.semibold))
                Spacer()
                if editable { Button { picking = true } label: { Label("Add work", systemImage: "plus") }.accessibilityIdentifier("goal.addWork") }
            }
            ForEach(groups, id: \.0) { title, icon, items in
                if !items.isEmpty {
                    DisclosureGroup {
                        ForEach(items) { item in linkRow(item, editable: editable) }
                    } label: {
                        Label("\(title)  \(items.count)", systemImage: icon).font(.amb(.body).weight(.semibold))
                    }
                }
            }
            if links.isEmpty { Text("No associated work yet. Start a discussion or link existing work.").font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground) }
            if let error = associations.error { Text(error).font(.amb(.footnote)).foregroundStyle(Amb.destructive) }
        }
    }

    private func pins(_ goal: Goal, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pinned references").font(.amb(.title3).weight(.semibold)); Spacer()
                Button("Pin Doc or File", systemImage: "pin") { pinning = true }
                    .disabled(!editable || goal.pinnedRefs.count >= Goal.maxPinnedRefs).accessibilityIdentifier("goal.pin")
            }
            Text("Key originals for this goal. Pins are separate from associated outputs and grant no additional access.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            ForEach(associations.value.pins) { item in linkRow(item, editable: editable, pinned: true) }
            if goal.pinnedRefs.isEmpty { Text("No pinned references").foregroundStyle(Amb.mutedForeground) }
        }
    }

    private func linkRow(_ item: ResolvedGoalLink, editable: Bool, pinned: Bool = false) -> some View {
        let manual = document?.goal.links.contains(where: { $0.key == item.link.key }) == true
        return HStack {
            Button { open(item) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title ?? "Not available").font(.amb(.body)).foregroundStyle(item.available ? Amb.foreground : Amb.mutedForeground)
                    Text(item.available ? [item.location, item.detail].compactMap { $0 }.joined(separator: " · ") : "You may not have access, or it hasn’t synced to this device yet.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    if !pinned && !manual { Text("Associated through a goal discussion").font(.amb(.caption)).foregroundStyle(Amb.primary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).disabled(!item.available)
            if editable && (pinned || manual) {
                Button { if pinned { run(.unpin(item.link.type, recordId: item.link.recordId)) } else { run(.unlink(item.link.type, recordId: item.link.recordId)) } } label: { Image(systemName: pinned ? "pin.slash" : "xmark.circle") }
                    .buttonStyle(.plain).foregroundStyle(Amb.mutedForeground).accessibilityLabel(pinned ? "Unpin reference" : "Remove manual link")
            }
        }
        .padding(.vertical, 2)
    }

    private func open(_ item: ResolvedGoalLink) {
        guard item.available, model.isUnlocked, let goals, model.selectedWorkspaceBoundary == goals.boundary else { return }
        switch item.link.type {
        case .task: model.openRecord(kind: "task", id: item.link.recordId)
        case .doc: model.openRecord(kind: "doc", id: item.link.recordId)
        case .file: model.openRecord(kind: "file", id: item.link.recordId)
        case .chat: model.openRecord(kind: "thread", id: item.link.recordId)
        }
    }
}

struct CheckpointForm: Identifiable {
    let id = UUID()
    let editing: GoalCheckpoint?
}

private struct CheckpointFormSheet: View {
    let form: CheckpointForm
    let save: (GoalEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var hasDate = false
    @State private var date = Date()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Checkpoint", text: $title).accessibilityIdentifier("checkpoint.form.title")
                TextField("Description (optional)", text: $description, axis: .vertical).lineLimit(2...5)
                Toggle("Date", isOn: $hasDate)
                if hasDate { DatePicker("Date", selection: $date, displayedComponents: .date) }
            }.formStyle(.grouped)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(form.editing == nil ? "Add" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("checkpoint.form.save")
            }.padding()
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
        .onAppear {
            guard let c = form.editing else { return }
            title = c.title; description = c.description ?? ""
            if let d = GoalFormat.controlDate(c.date) { date = d; hasDate = true }
        }
    }

    private func commit() {
        let day = hasDate ? GoalFormat.string(from: date) : nil
        if let old = form.editing {
            var next = old; next.title = title; next.date = day; next.description = description
            save(.updateCheckpoint(id: old.id, expected: old, value: next))
        } else {
            save(.addCheckpoint(GoalCheckpoint(title: title.trimmingCharacters(in: .whitespacesAndNewlines), date: day,
                                               description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description.trimmingCharacters(in: .whitespacesAndNewlines))))
        }
        dismiss()
    }
}

/// Links an existing task, document or file from this device's synced records. The record is referenced, never copied.
private struct GoalLinkPicker: View {
    enum Kind: String, CaseIterable, Identifiable { case tasks = "Tasks", docs = "Documents", files = "Files"; var id: String { rawValue } }
    let workspace: WorkspaceRecord
    let store: LocalStore
    let linked: Set<GoalLink.Key>
    var pinsOnly = false
    let choose: (GoalLink) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.tasks
    @State private var query = ""
    @State private var tasks: [TaskRecord] = []
    @State private var docs: [DocRecord] = []
    @State private var files: [FileRecord] = []
    @State private var busy = false
    @State private var error: String?

    private func matches(_ title: String) -> Bool { query.isEmpty || title.localizedCaseInsensitiveContains(query) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $kind) { ForEach(Kind.allCases.filter { !pinsOnly || $0 != .tasks }) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding()
            TextField("Search", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal)
            List {
                switch kind {
                case .tasks: ForEach(tasks.filter { matches($0.title) && !linked.contains(.init(type: .task, recordId: $0.id)) }) { t in
                    row(t.title) { try await choose(GoalLink(type: .task, recordId: t.id, channelId: t.channelId)) } }
                case .docs: ForEach(docs.filter { matches($0.title) && !$0.archived && !linked.contains(.init(type: .doc, recordId: $0.id)) }) { d in
                    row(d.title) { try await choose(GoalLink(type: .doc, recordId: d.id, channelId: d.channelId)) } }
                case .files: ForEach(files.filter { matches($0.displayName) && !$0.archived && $0.contentType != Goal.mime && !linked.contains(.init(type: .file, recordId: $0.id)) }) { f in
                    row(f.displayName) { try await choose(GoalLink(type: .file, recordId: f.id, channelId: f.channelId)) } }
                }
            }.disabled(busy)
            if let error { Text(error).foregroundStyle(Amb.destructive).padding(.horizontal).accessibilityIdentifier("goal.picker.error") }
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button("Done") { dismiss() }.disabled(busy).keyboardShortcut(.defaultAction) }.padding()
        }
        .interactiveDismissDisabled(busy)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
        .task {
            if pinsOnly { kind = .docs }
            tasks = (try? await store.reader.tasks(workspaceId: workspace.id)) ?? []
            docs = (try? await store.reader.docs(workspaceId: workspace.id)) ?? []
            files = (try? await store.reader.files(workspaceId: workspace.id)) ?? []
        }
    }

    private func row(_ title: String, add: @escaping () async throws -> Void) -> some View {
        Button {
            guard !busy else { return }; busy = true; error = nil
            Task {
                defer { busy = false }
                do { try await add(); if pinsOnly { dismiss() } }
                catch { self.error = GoalsModel.message(error) }
            }
        } label: { Label(title, systemImage: "plus.circle").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
    }
}

private struct GoalWorkSnapshot: Sendable, Equatable {
    var links: [ResolvedGoalLink] = []
    var pins: [ResolvedGoalLink] = []
}

private struct GoalAssociationLoadKey: Equatable {
    let boundaryId: String?
    let fileId: String
    let goal: Goal?
}
