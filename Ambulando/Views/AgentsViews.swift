import AmbulandoCore
import SwiftUI

// Agents (sol Agents section): the workspace's installed agents and what they are doing in the current context, read
// from Tower's materialised records (`/workspace-agents`, `/agent-activities`). This app has no direct Autopilot
// connection (HTTPS-only, no FIPS), so Autopilot-only views — session control and the pipeline viewer — are listed as
// unavailable rather than imitated.

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

    private var channelIds: [String] { model.navigation.value.channels(in: model.context).map(\.id) }

    var body: some View {
        let value = snapshot.value
        let live = value.activity.filter { !$0.isTerminal && $0.leaseHealth == "live" }
        let stale = value.activity.filter { !$0.isTerminal && $0.leaseHealth != "live" }
        let recent = value.activity.filter(\.isTerminal)
        List {
            Section("Agents in this workspace") {
                if value.agents.isEmpty {
                    Text(snapshot.loaded ? "No agents are installed in this workspace." : "Loading…").font(.footnote).foregroundStyle(Amb.mutedForeground)
                }
                ForEach(value.agents) { agent in
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(Amb.primary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayName).font(.subheadline.weight(.semibold))
                            Text(([String(agent.agentNpub.prefix(12)) + "…"] + agent.capabilities.prefix(3)).joined(separator: " · "))
                                .font(.caption).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                        }
                        Spacer()
                        let busy = live.contains { $0.agentNpub == agent.agentNpub }
                        Text(busy ? "Working" : "Idle").font(.caption.weight(.semibold))
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
                Label("Pipeline runs and Autopilot sessions need a direct Autopilot connection, which this HTTPS-only app does not make.", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.footnote).foregroundStyle(Amb.mutedForeground)
                    .accessibilityIdentifier("agents.pipelines.unavailable")
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
        .navigationTitle("Agents")
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
                                Text(value.names[activity.agentNpub] ?? "Agent").font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground)
                                Text(stateLabel(activity)).font(.caption.weight(.semibold)).foregroundStyle(stateColor(activity))
                                Spacer()
                                Text(ChatTime.label(activity.updatedAt)).font(.caption).foregroundStyle(Amb.mutedForeground)
                            }
                            if let text = activity.label ?? activity.summary {
                                Text(text).font(.footnote).foregroundStyle(Amb.foreground).lineLimit(3)
                            }
                            Text("#" + (value.channelNames[activity.channelId] ?? "channel")).font(.caption).foregroundStyle(Amb.mutedForeground)
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
