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
/// Labels sit above bordered fields (a grouped Form puts the label left and the value right-aligned on the Mac). Keys:
/// focus starts in Name; Return there moves to the description, where Return is a newline; Tab and Shift-Tab move
/// between fields; ⌘Return saves; Escape cancels.
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
    @State private var descriptionFocused = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var startValue: String? { hasStart ? GoalFormat.string(from: start) : nil }
    private var targetValue: String? { hasTarget ? GoalFormat.string(from: target) : nil }
    private var datesProblem: String? {
        if let startValue, let targetValue, targetValue < startValue { return "The target date is before the start date." }
        return nil
    }
    /// Why Save is unavailable, or nil when the goal can be saved.
    private var blocker: String? {
        if trimmedName.isEmpty { return "Add a name." }
        if trimmedName.utf16.count > Goal.maxName { return "The name is too long." }
        if trimmedDescription.isEmpty { return "Describe what you want to achieve." }
        if trimmedDescription.utf16.count > Goal.maxDescription { return "The description is too long." }
        return datesProblem
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(existing == nil ? "New goal" : "Edit goal")
                .font(.amb(.title3).weight(.semibold)).foregroundStyle(Amb.itemHeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GoalFormField(label: "Name", count: trimmedName.utf16.count, limit: Goal.maxName) {
                        TextField("Name", text: $name, prompt: Text("e.g. Ship Ambulando"))
                            .labelsHidden().textFieldStyle(.roundedBorder).font(.amb(.body))
                            .focused($nameFocused)
                            .onSubmit { descriptionFocused = true }
                            .accessibilityIdentifier("goal.form.name")
                    }
                    GoalFormField(label: "Description", count: trimmedDescription.utf16.count, limit: Goal.maxDescription) {
                        descriptionEditor
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dates (optional)").font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.itemHeading)
                        HStack(alignment: .top, spacing: 24) {
                            GoalDateField(label: "Start date", on: $hasStart, date: $start, identifier: "goal.form.start")
                            GoalDateField(label: "Target date", on: $hasTarget, date: $target, identifier: "goal.form.target")
                            Spacer(minLength: 0)
                        }
                        if let datesProblem {
                            Text(datesProblem).font(.amb(.footnote)).foregroundStyle(Amb.destructive).accessibilityIdentifier("goal.form.datesProblem")
                        }
                    }
                    if let error { Notice(tone: .error, text: error) }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if let blocker, !busy {
                    Text(blocker).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground).lineLimit(1).accessibilityIdentifier("goal.form.blocker")
                }
                if busy { ProgressView().controlSize(.small) }
                Button(existing == nil ? "Create goal" : "Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent).disabled(busy || blocker != nil)
                    .help("⌘Return")
                    .accessibilityIdentifier("goal.form.save")
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .background(Amb.background)
        #if os(macOS)
        .frame(width: 540)
        .frame(minHeight: 460)
        #endif
        .onAppear {
            load()
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    @ViewBuilder private var descriptionEditor: some View {
        #if os(macOS)
        ComposerTextView(text: $description, focused: $descriptionFocused, placeholder: "What do you want to achieve?",
                         plainKeyboard: false, onPasteItems: { _ in [] }, onSubmit: { if blocker == nil && !busy { save() } },
                         fixedHeight: 112 * TextScale.shared.factor, formField: true, onCancel: { dismiss() },
                         identifier: "goal.form.description")
            .frame(height: 112 * TextScale.shared.factor)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusControl)
                .stroke(descriptionFocused ? Amb.primary : Amb.border, lineWidth: descriptionFocused ? 2 : 1))
        #else
        TextField("Description", text: $description, prompt: Text("What do you want to achieve?"), axis: .vertical)
            .lineLimit(4...10).labelsHidden().textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("goal.form.description")
        #endif
    }

    private func load() {
        guard let goal = existing?.goal else { return }
        name = goal.name; description = goal.description
        if let d = GoalFormat.controlDate(goal.startDate) { start = d; hasStart = true }
        if let d = GoalFormat.controlDate(goal.targetDate) { target = d; hasTarget = true }
    }

    private func save() {
        guard !busy, blocker == nil else { return }
        busy = true; error = nil
        let startValue = startValue, targetValue = targetValue
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

/// A form label above its field, with a character count once the value nears its limit.
private struct GoalFormField<Field: View>: View {
    let label: String
    var count = 0
    var limit = 0
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.itemHeading)
                Spacer()
                if limit > 0, count > limit * 3 / 4 {
                    Text("\(count)/\(limit)").font(.amb(.caption)).monospacedDigit()
                        .foregroundStyle(count > limit ? Amb.destructive : Amb.mutedForeground)
                }
            }
            field
        }
    }
}

/// An optional date: a checkbox to include it and a date control that is always enabled, so the keyboard reaches it
/// (macOS leaves checkboxes out of Tab unless Full Keyboard Access is on). Changing the date includes it; it reads as
/// unset (dimmed) until then.
private struct GoalDateField: View {
    let label: String
    @Binding var on: Bool
    @Binding var date: Date
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(label, isOn: $on)
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .font(.amb(.body)).accessibilityIdentifier("\(identifier).include")
            DatePicker(label, selection: $date, displayedComponents: .date)
                .labelsHidden()
                #if os(macOS)
                .datePickerStyle(.field)
                #endif
                .opacity(on ? 1 : 0.5)
                .onChange(of: date) { _, _ in on = true }
                .accessibilityHint(on ? "" : "Not set. Changing the date includes it.")
                .accessibilityIdentifier(identifier)
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
