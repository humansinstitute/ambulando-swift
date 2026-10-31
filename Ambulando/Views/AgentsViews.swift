import AmbulandoCore
import SwiftUI

// Agents (sol Agents section): the workspace's installed agents and what they are doing in the current context, read
// from Tower's materialised records (`/workspace-agents`, `/agent-activities`). Setup discovers agents over
// explicitly advertised HTTPS; session control and pipeline viewer screens remain unavailable here.

struct AgentsSnapshot: Sendable, Equatable {
    var agents: [WorkspaceAgentRecord] = []
    var activity: [AgentActivityRecord] = []
    var channelNames: [String: String] = [:]
    var names: [String: String] = [:]
}

struct AgentsView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var snapshot = LiveQuery<AgentsSnapshot>(initial: AgentsSnapshot())

    @State private var showingSetup = false
    private var channelIds: [String] { model.navigation.value.channels(in: model.context).map(\.id) }

    var body: some View {
        let value = snapshot.value
        let live = value.activity.filter { !$0.isTerminal && $0.leaseHealth == "live" }
        let stale = value.activity.filter { !$0.isTerminal && $0.leaseHealth != "live" }
        let recent = value.activity.filter(\.isTerminal)
        List {
            Section("Agents in this workspace") {
                if value.agents.isEmpty {
                    Text(snapshot.loaded ? "No agents are installed in this workspace." : "Loading…").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                }
                ForEach(value.agents) { agent in
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(Amb.primary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayName).font(.amb(.subheadline).weight(.semibold))
                            Text(([String(agent.agentNpub.prefix(12)) + "…"] + agent.capabilities.prefix(3)).joined(separator: " · "))
                                .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                        }
                        Spacer()
                        let busy = live.contains { $0.agentNpub == agent.agentNpub }
                        Text(busy ? "Working" : "Idle").font(.amb(.caption).weight(.semibold))
                            .foregroundStyle(busy ? Amb.brandOrange : Amb.mutedForeground)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("agent.\(agent.displayName)")
                }
            }
            activitySection("Working now", live, value)
            activitySection("Not responding", stale, value, note: "These agents stopped reporting before finishing.")
            activitySection("Recently finished", Array(recent.prefix(30)), value)
            Section("Not available on \(Device.name)") {
                Label("Pipeline runs and session control are not implemented in this native app. Agent setup uses advertised HTTPS.", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    .accessibilityIdentifier("agents.pipelines.unavailable")
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
        .navigationTitle("Agents")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Add agents") { showingSetup = true }.disabled(!model.isUnlocked) } }
        .sheet(isPresented: $showingSetup) { NStackAgentSetupView(workspace: workspace) }
        .refreshable { model.openAgents(workspace, channelIds: channelIds, force: true) }
        .task(id: model.context) { start(); model.openAgents(workspace, channelIds: channelIds) }
    }

    @ViewBuilder private func activitySection(_ title: String, _ rows: [AgentActivityRecord], _ value: AgentsSnapshot, note: String? = nil) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { activity in
                    Button { open(activity) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(value.names[activity.agentNpub] ?? "Agent").font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground)
                                Text(stateLabel(activity)).font(.amb(.caption).weight(.semibold)).foregroundStyle(stateColor(activity))
                                Spacer()
                                Text(ChatTime.label(activity.updatedAt)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                            }
                            if let text = activity.label ?? activity.summary {
                                Text(text).font(.amb(.footnote)).foregroundStyle(Amb.foreground).lineLimit(3)
                            }
                            Text("#" + (value.channelNames[activity.channelId] ?? "channel")).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(activity.threadId == nil)
                    .accessibilityIdentifier("activity.\(activity.label ?? activity.activityId)")
                }
            } header: { Text(title) } footer: { if let note { Text(note) } }
        }
    }

    private func stateLabel(_ a: AgentActivityRecord) -> String {
        if let position = a.queuePosition, a.state == "queued" { return "Queued #\(position)" }
        return a.state.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func stateColor(_ a: AgentActivityRecord) -> Color {
        switch a.state {
        case "failed", "cancelled": Amb.warning
        case "completed": Amb.mutedForeground
        default: Amb.brandOrange
        }
    }

    @Environment(\.pushRoute) private var pushRoute

    private func open(_ a: AgentActivityRecord) {
        guard let thread = a.threadId else { return }
        pushRoute(.thread(workspaceId: workspace.id, channelId: a.channelId, threadId: thread))
    }

    private func start() {
        let w = workspace.id, store = store
        let ids = channelIds
        // Every channel of the context is read (the first batch first, the rest in the background).
        let read: [String]? = model.context.isHome ? nil : ids
        snapshot.start(store: store, matches: { ($0.workspaceId == w && [.agents, .channels, .members].contains($0.table)) || $0.table == .profiles }) {
            async let agents = store.reader.workspaceAgents(workspaceId: w)
            async let activity = store.reader.agentActivities(workspaceId: w, channelIds: read)
            async let channels = store.reader.channels(workspaceId: w)
            async let members = store.reader.directoryMembers(workspaceId: w)
            let names = Dictionary(try await members.map { ($0.npub, $0.label) }, uniquingKeysWith: { a, _ in a })
            let agentList = try await agents
            var labels = names
            for agent in agentList { labels[agent.agentNpub] = agent.displayName }
            return AgentsSnapshot(agents: agentList, activity: try await activity,
                                  channelNames: Dictionary(try await channels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
                                  names: labels)
        }
    }
}


/// Shared iPhone/Mac setup; the selected workspace supplies the authoritative app identity.
struct NStackAgentSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceRecord
    @State private var setup: NStackAgentSetup?
    @State private var selected: Set<String> = []
    @State private var working = false
    @State private var error: String?
    private func setupError(_ error: Error) -> String {
        if case TowerError.http(let status, _, _) = error {
            if status == 401 || status == 403 { return "Your identity cannot access this workspace or Autopilot. Unlock the intended identity or ask its owner for access, then retry." }
            if status == 404 { return "A required setup route is missing. Ask the operator to activate the updated Tower and Autopilot services, then retry." }
            if status >= 500 { return "A setup service is offline or unavailable. Ask its operator to check the advertised HTTPS service, then retry." }
        }
        return error.localizedDescription
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Selected workspace") {
                    Text(workspace.label)
                    Text("Registered app identity: " + workspace.appNpub).font(.amb(.caption)).textSelection(.enabled)
                    Text("Discovery uses the Autopilot HTTPS service advertised by this nStack. No FIPS package is needed.").font(.amb(.footnote))
                }
                if let error { Section { Notice(tone: .error, text: error) } }
                if let setup {
                    Section("Available agents") {
                        if setup.agents.isEmpty { Text("No agents are available to this identity. Ask the Autopilot owner to enable an agent and grant you access.") }
                        ForEach(setup.agents) { agent in
                            Toggle(isOn: Binding(get: { selected.contains(agent.id) }, set: { if $0 { selected.insert(agent.id) } else { selected.remove(agent.id) } })) {
                                VStack(alignment: .leading) { Text(agent.name); Text(agent.description).font(.amb(.caption)) }
                            }
                        }
                    }
                    Text("Adding over HTTPS selects HTTPS for this installation and keeps existing verified FIPS details.").font(.amb(.footnote))
                    Button("Add selected agents over HTTPS") {
                        working = true; error = nil
                        Task {
                            do { try await model.installNStackAgents(setup, selected: selected, workspace: workspace); dismiss() }
                            catch { self.error = setupError(error) }
                            working = false
                        }
                    }.disabled(working || selected.isEmpty)
                }
                Button(setup == nil ? "Discover available agents" : "Retry discovery") {
                    working = true; error = nil
                    Task {
                        do { setup = try await model.discoverNStackAgents(workspace); selected = [] }
                        catch { self.error = setupError(error) }
                        working = false
                    }
                }.disabled(working)
                if working { ProgressView() }
            }
            .navigationTitle("Connect agents")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) } }
        }
    }
}
