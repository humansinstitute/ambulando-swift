import AmbulandoCore
import SwiftUI

/// The personal Goals list: a named goal with a short description, an optional target date and progress counted in
/// checkpoints reached. Goals are stored as Files in the owner's private Goals channel (see `GoalsSpace`); this screen
/// never shows implementation detail unless something needs the owner's decision.
struct GoalsView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var creating = false
    @State private var showArchived = false

    private var goals: GoalsModel? { model.goalsModel(for: workspace) }

    var body: some View {
        Group {
            if let goals { content(goals) } else {
                ContentUnavailableView("Goals unavailable", systemImage: "target", description: Text("Open a connected workspace to use goals."))
            }
        }
        .navigationTitle("Goals")
        .task(id: model.selectedWorkspaceBoundary) {
            guard let goals else { return }
            await goals.refresh()
            // Agents can edit goals too; pick their changes up while this screen is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await goals.refresh()
            }
        }
    }

    @ViewBuilder private func content(_ goals: GoalsModel) -> some View {
        switch goals.space {
        case nil:
            if let error = goals.error { GoalsMessage(title: "Goals could not be loaded", text: error) { Task { await goals.refresh() } } }
            else { ProgressView("Loading goals…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        case .unsafe(let reason):
            GoalsMessage(title: "Goals are not available", text: reason) { Task { await goals.refresh() } }
        case .needsSetup(let scopes, let suggested, let agents):
            GoalsSetupView(goals: goals, scopes: scopes, suggested: suggested, agents: agents)
        case .ready:
            list(goals)
        }
    }

    private func list(_ goals: GoalsModel) -> some View {
        let active = goals.goals.filter { $0.goal.status == .active }
        let completed = goals.goals.filter { $0.goal.status == .completed }
        let archived = goals.goals.filter { $0.goal.status == .archived }
        return List {
            if let error = goals.error { Notice(tone: .warning, text: error).listRowSeparator(.hidden) }
            if goals.goals.isEmpty && goals.unreadable.isEmpty {
                ContentUnavailableView {
                    Label("No goals yet", systemImage: "target")
                } description: {
                    Text("A goal has a name, a few checkpoints and the chats, tasks and documents that move it forward.")
                } actions: {
                    Button("New goal") { creating = true }.buttonStyle(.borderedProminent)
                }.listRowBackground(Color.clear)
            }
            if !active.isEmpty { Section("Active") { ForEach(active) { GoalRow(document: $0) } } }
            if !completed.isEmpty { Section("Completed") { ForEach(completed) { GoalRow(document: $0) } } }
            if !archived.isEmpty {
                Section {
                    DisclosureGroup("Archived (\(archived.count))", isExpanded: $showArchived) { ForEach(archived) { GoalRow(document: $0) } }
                }
            }
            if !goals.unreadable.isEmpty {
                Section("Could not be opened") {
                    ForEach(goals.unreadable) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.amb(.body))
                            Text(item.reason).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                        }
                    }
                }
            }
            if let channel = goals.channel, case .ready(_, let agents) = goals.space, !agents.isEmpty {
                Section("Agents") { GoalsAgentAccess(goals: goals, channel: channel, agents: agents) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Amb.background)
        .refreshable { await goals.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("New goal", systemImage: "plus") }.accessibilityIdentifier("goals.new")
            }
        }
        .sheet(isPresented: $creating) {
            GoalFormSheet(goals: goals, existing: nil) { document in
                model.push(.goal(workspaceId: workspace.id, fileId: document.id), in: model.mode)
            }
        }
        .accessibilityIdentifier("goals.list")
    }
}

private struct GoalRow: View {
    let document: GoalDocument
    @Environment(AppModel.self) private var model

    var body: some View {
        let goal = document.goal
        NavigationLink(value: WorkRoute.goal(workspaceId: document.file.workspaceId, fileId: document.id)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(goal.name).font(.amb(.headline)).foregroundStyle(Amb.foreground).lineLimit(2)
                HStack(spacing: 8) {
                    Text(GoalFormat.progress(goal))
                    if let target = GoalFormat.date(goal.targetDate) { Text("· Target \(target)") }
                }
                .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("goal.row.\(goal.name)")
    }
}

/// Lets the owner choose which agents may add to and edit their goals. Only agents appear here; people never do.
private struct GoalsAgentAccess: View {
    let goals: GoalsModel
    let channel: ChannelRecord
    let agents: [GoalsAgent]
    @State private var error: String?

    var body: some View {
        ForEach(agents) { agent in
            Toggle(isOn: Binding(get: { agent.access != nil }, set: { on in
                Task { error = await goals.setAgent(agent.member, enabled: on) }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.member.label).font(.amb(.body))
                    Text(agent.access == nil ? "Can’t see your goals" : "Can add to and edit your goals").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                }
            }
        }
        if let error { Notice(tone: .error, text: error) }
    }
}

private struct GoalsMessage: View {
    let title: String
    let text: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "target")
        } description: { Text(text) } actions: { Button("Try again", action: retry) }
    }
}

/// First use: creates the owner's private Goals channel. The owner confirms where it goes; Home is suggested.
private struct GoalsSetupView: View {
    let goals: GoalsModel
    let scopes: [ScopeRecord]
    let suggested: ScopeRecord?
    let agents: [MemberRecord]
    @State private var scopeId: String = ""
    @State private var allowed: Set<String> = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Goals are private to you. Choose where they are kept and which of your agents can add to them.").font(.amb(.body))
            }
            Section("Keep goals in") {
                Picker("Space", selection: $scopeId) {
                    ForEach(scopes) { Text($0.name).tag($0.id) }
                }
            }
            if !agents.isEmpty {
                Section("Agents that can add to your goals") {
                    ForEach(agents) { agent in
                        Toggle(agent.label, isOn: Binding(get: { allowed.contains(agent.actorId) }, set: { on in
                            if on { allowed.insert(agent.actorId) } else { allowed.remove(agent.actorId) }
                        }))
                    }
                }
            }
            if let error { Notice(tone: .error, text: error) }
            Section {
                Button(busy ? "Setting up…" : "Set up goals") {
                    busy = true; error = nil
                    Task { error = await goals.setUp(scopeId: scopeId, agentActorIds: Array(allowed)); busy = false }
                }
                .disabled(busy || scopeId.isEmpty)
                .accessibilityIdentifier("goals.setup")
            }
        }
        .formStyle(.grouped)
        .onAppear { if scopeId.isEmpty { scopeId = suggested?.id ?? scopes.first?.id ?? "" } }
    }
}

/// Name, description and optional dates. Creating saves a new goal; editing saves only the fields that changed, each
/// against the value this form opened with, so another device's or an agent's change to a different field survives.
struct GoalFormSheet: View {
    let goals: GoalsModel
    let existing: GoalDocument?
    var onSaved: (GoalDocument) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var hasStart = false
    @State private var hasTarget = false
    @State private var start = Date()
    @State private var target = Date()
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("goal.form.name")
                Section("Goal") {
                    TextField("What do you want to achieve?", text: $description, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("goal.form.description")
                }
                Section("Dates (optional)") {
                    Toggle("Start date", isOn: $hasStart)
                    if hasStart { DatePicker("Starts", selection: $start, displayedComponents: .date) }
                    Toggle("Target date", isOn: $hasTarget)
                    if hasTarget { DatePicker("Target", selection: $target, displayedComponents: .date) }
                }
                if let error { Notice(tone: .error, text: error) }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(existing == nil ? "Create goal" : "Save") { save() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(busy)
                    .accessibilityIdentifier("goal.form.save")
            }.padding()
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 440)
        #endif
        .onAppear(perform: load)
    }

    private func load() {
        guard let goal = existing?.goal else { return }
        name = goal.name; description = goal.description
        if let d = GoalFormat.controlDate(goal.startDate) { start = d; hasStart = true }
        if let d = GoalFormat.controlDate(goal.targetDate) { target = d; hasTarget = true }
    }

    private func save() {
        busy = true; error = nil
        let startValue = hasStart ? GoalFormat.string(from: start) : nil, targetValue = hasTarget ? GoalFormat.string(from: target) : nil
        Task {
            defer { busy = false }
            do {
                let saved: GoalDocument
                if let existing {
                    let was = existing.goal
                    var edits: [GoalEdit] = []
                    if name.trimmingCharacters(in: .whitespacesAndNewlines) != was.name { edits.append(.setName(expected: was.name, value: name)) }
                    if description.trimmingCharacters(in: .whitespacesAndNewlines) != was.description { edits.append(.setDescription(expected: was.description, value: description)) }
                    if startValue != was.startDate { edits.append(.setStartDate(expected: was.startDate, value: startValue)) }
                    if targetValue != was.targetDate { edits.append(.setTargetDate(expected: was.targetDate, value: targetValue)) }
                    if edits.isEmpty { dismiss(); return }
                    saved = try await goals.edit(existing.id, edits)
                } else {
                    let goal = try Goal.create(name: name, description: description, startDate: startValue, targetDate: targetValue)
                    saved = try await goals.create(goal).get()
                }
                onSaved(saved); dismiss()
            } catch {
                self.error = GoalsModel.message(error)
                if existing != nil, error is GoalError { await goals.reload(existing!.id) }
            }
        }
    }
}

/// Deck's entry to personal goals: the active goals with their progress, and the full list.
struct DeckGoalsCard: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord

    var body: some View {
        let goals = model.goalsModel(for: workspace)
        let active = (goals?.goals ?? []).filter { $0.goal.status == .active }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Goals").font(.amb(.headline)).foregroundStyle(Amb.itemHeading)
                Spacer()
                Button("All goals") { model.push(.goals(workspaceId: workspace.id), in: .deck) }.buttonStyle(.borderless).accessibilityIdentifier("deck.goals.all")
            }
            if goals?.space.map({ if case .ready = $0 { true } else { false } }) != true {
                Text(goals?.loaded == true ? "Set up goals to keep track of what matters." : "Loading…").font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground)
            } else if active.isEmpty {
                Text("No active goals.").font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground)
            } else {
                ForEach(active.prefix(4)) { doc in
                    Button { model.push(.goal(workspaceId: workspace.id, fileId: doc.id), in: .deck) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(doc.goal.name).font(.amb(.body)).foregroundStyle(Amb.foreground).lineLimit(1)
                            Text(GoalFormat.progress(doc.goal)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: model.selectedWorkspaceBoundary) { await goals?.refresh() }
        .accessibilityIdentifier("deck.goals")
    }
}
