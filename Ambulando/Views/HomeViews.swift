#if os(macOS)
import AmbulandoCore
import SwiftUI

/// Home on the Mac (Ambulando-Next board v3): the welcome row, then the owner's goals in focus order on the left (the
/// first three prominent, later ones quieter but readable; drag or use a goal's menu to choose which are in focus), and
/// the Daily Briefing with the five latest active chats on the right. Narrow windows stack the columns. The Deck
/// dashboard stays in the Deck section; a goal opens its detail on top of Home, so Back returns here.
struct HomeView: View {
    let workspace: WorkspaceRecord
    let store: LocalStore

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MacDeckWelcome(workspace: workspace, store: store, compact: !wide).frame(height: wide ? 170 : 260)
                    if wide {
                        HStack(alignment: .top, spacing: 32) {
                            HomeGoalsSection(workspace: workspace).frame(maxWidth: .infinity, alignment: .topLeading)
                            VStack(alignment: .leading, spacing: 32) {
                                HomeBriefing(workspace: workspace)
                                HomeLatestChats(workspace: workspace, store: store)
                            }
                            .frame(width: min(440, geometry.size.width * 0.38))
                        }
                    } else {
                        HomeGoalsSection(workspace: workspace)
                        HomeBriefing(workspace: workspace)
                        HomeLatestChats(workspace: workspace, store: store)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
            }
        }
        .background(Amb.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home")
    }
}

private struct HomeHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.amb(.title2).weight(.semibold)).foregroundStyle(Amb.itemHeading).accessibilityAddTraits(.isHeader)
    }
}

/// The three goals in focus are full cards; the next one peeks, quieter but readable. "Show all goals" reveals the rest
/// in place (no nested scroll), so the briefing and latest chats stay near the top of a narrow Home.
private enum HomeFocus { static let count = 3; static let shown = 4 }

private struct HomeGoalsSection: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    @State private var creating = false
    @State private var message: String?
    @State private var showAll = false

    var body: some View {
        let goals = model.goalsModel(for: workspace)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HomeHeading(title: "Goals")
                Spacer()
                if let goals, case .ready = goals.space {
                    Button { creating = true } label: { Label("New goal", systemImage: "plus") }.accessibilityIdentifier("home.goals.new")
                }
                Button("All goals") { model.push(.goals(workspaceId: workspace.id), in: .deck) }
                    .buttonStyle(.borderless).accessibilityIdentifier("home.goals.all")
            }
            if let message { Notice(tone: .warning, text: message).accessibilityIdentifier("home.goals.message") }
            if let goals { content(goals) } else { note("Open a connected workspace to use goals.") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.goals")
        .task(id: model.selectedWorkspaceBoundary) {
            guard let goals else { return }
            await goals.refresh()
            // Agents edit goals too; pick their changes up while Home is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await goals.refresh()
            }
        }
        .sheet(isPresented: $creating) {
            if let goals { GoalFormSheet(goals: goals, existing: nil) }
        }
    }

    @ViewBuilder private func content(_ goals: GoalsModel) -> some View {
        switch goals.space {
        case nil:
            note(goals.error ?? "Loading goals…")
        case .unsafe(let reason):
            note("Goals are not available: \(reason)")
        case .needsSetup:
            HStack {
                note("Set up goals to keep track of what matters.")
                Button("Set up goals") { model.push(.goals(workspaceId: workspace.id), in: .deck) }.accessibilityIdentifier("home.goals.setup")
            }
        case .ready:
            let active = GoalFocus.order(goals.goals.filter { $0.goal.status == .active })
            if active.isEmpty {
                HStack {
                    note("No active goals. A goal has a name, a few checkpoints and the work that moves it forward.")
                    Button("New goal") { creating = true }.buttonStyle(.borderedProminent)
                }
            }
            ForEach(Array(active.prefix(showAll ? active.count : HomeFocus.shown).enumerated()), id: \.element.id) { index, doc in
                HomeGoalCard(doc: doc, index: index, count: active.count, busy: goals.moving,
                             open: { model.push(.goal(workspaceId: workspace.id, fileId: doc.id), in: .deck) },
                             move: { move(goals, doc.id, to: $0) })
                    .draggable(doc.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first, id != doc.id, active.contains(where: { $0.id == id }) else { return false }
                        move(goals, id, to: index)
                        return true
                    }
            }
            if active.count > HomeFocus.shown {
                Button(showAll ? "Show fewer goals" : "Show all \(active.count) goals") { showAll.toggle() }
                    .buttonStyle(.borderless).accessibilityIdentifier("home.goals.showAll")
            }
            if active.count > HomeFocus.count {
                Text("The first \(HomeFocus.count) goals are in focus. Drag a goal or use its menu to change the order.")
                    .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            }
        }
    }

    private func move(_ goals: GoalsModel, _ id: String, to index: Int) {
        Task { message = await goals.move(id, toIndex: index) }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HomeGoalCard: View {
    let doc: GoalDocument
    let index: Int
    let count: Int
    let busy: Bool
    let open: () -> Void
    let move: (Int) -> Void

    private var inFocus: Bool { index < HomeFocus.count }

    private var actions: [NativeMessageAction] {
        var items: [NativeMessageAction] = []
        if index > 0 {
            items.append(NativeMessageAction("Move to top", "arrow.up.to.line") { move(0) })
            items.append(NativeMessageAction("Move up", "arrow.up") { move(index - 1) })
        }
        if index < count - 1 { items.append(NativeMessageAction("Move down", "arrow.down") { move(index + 1) }) }
        return items
    }

    var body: some View {
        let goal = doc.goal
        HStack(alignment: .top, spacing: 6) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(goal.name).font(.amb(inFocus ? .headline : .subheadline).weight(.semibold)).foregroundStyle(Amb.foreground)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        GoalProgressDots(goal: goal)
                    }
                    Text(goal.description).font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground)
                        .lineLimit(inFocus ? 2 : 1).multilineTextAlignment(.leading)
                    HStack(spacing: 12) {
                        if let start = GoalFormat.date(goal.startDate) { Text("Start \(start)") }
                        Spacer(minLength: 8)
                        Text(GoalFormat.progress(goal))
                        Spacer(minLength: 8)
                        if let target = GoalFormat.date(goal.targetDate) { Text("Target \(target)") }
                    }
                    .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(goal.name). \(GoalFormat.progress(goal))\(inFocus ? "" : ". Out of focus")")
            .accessibilityHint("Opens the goal")
            .accessibilityIdentifier("home.goal")
            .accessibilityActions {
                ForEach(actions.indices, id: \.self) { i in Button(actions[i].title) { actions[i].perform?() } }
            }
            if !actions.isEmpty, !busy {
                NativeMessageActions(items: actions, identifier: "home.goal.menu", label: "Goal order", help: "Move this goal")
                    .frame(width: 28, height: 28)
            }
        }
        .padding(inFocus ? 16 : 12)
        .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(inFocus ? Amb.primary.opacity(0.35) : Amb.border, lineWidth: 1))
        .shadow(color: .black.opacity(inFocus ? 0.06 : 0), radius: 8, y: 4)
        .opacity(inFocus ? 1 : 0.62)
        .contextMenu {
            ForEach(actions.indices, id: \.self) { i in Button(actions[i].title) { actions[i].perform?() } }
        }
    }
}

/// Checkpoints as dots on a line: filled when reached, ringed for the next one, hollow otherwise (as the goal timeline).
struct GoalProgressDots: View {
    let goal: Goal
    private static let shown = 8

    var body: some View {
        let checkpoints = goal.checkpoints
        if !checkpoints.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(checkpoints.prefix(Self.shown).enumerated()), id: \.element.id) { n, cp in
                    if n > 0 { Rectangle().fill(Amb.border).frame(width: 14, height: 1.5) }
                    Circle()
                        .fill(cp.reached ? Amb.primary : Amb.card)
                        .overlay(Circle().stroke(cp.reached || cp.id == goal.nextCheckpointId ? Amb.primary : Amb.mutedForeground, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                }
                if checkpoints.count > Self.shown {
                    Text("+\(checkpoints.count - Self.shown)").font(.amb(.caption2)).foregroundStyle(Amb.mutedForeground).padding(.leading, 4)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Facts from saved goals for a chosen day. There is no agent-written briefing yet, and Home says so.
private struct HomeBriefing: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    @State private var offset = 0

    private var day: Date { Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date() }

    var body: some View {
        let goals = model.goalsModel(for: workspace)
        let today = GoalFormat.string(from: Date()), dayValue = GoalFormat.string(from: day)
        let facts = GoalBriefing.facts(goals?.goals ?? [], day: dayValue, today: today, focus: HomeFocus.count)
        VStack(alignment: .leading, spacing: 10) {
            HomeHeading(title: "Daily Briefing")
            HStack(spacing: 6) {
                Button { offset -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                    .accessibilityLabel("Previous day").accessibilityIdentifier("home.briefing.previous")
                Text(offset == 0 ? "Today, \(GoalFormat.date(dayValue) ?? dayValue)" : GoalFormat.date(dayValue) ?? dayValue)
                    .font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground).monospacedDigit()
                    .accessibilityIdentifier("home.briefing.day")
                Button { offset += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                    .disabled(offset >= 0).accessibilityLabel("Next day").accessibilityIdentifier("home.briefing.next")
                if offset != 0 { Button("Today") { offset = 0 }.buttonStyle(.borderless).font(.amb(.subheadline)) }
            }
            if goals?.loaded != true {
                line("Loading goals…")
            } else if facts.isEmpty {
                line(offset == 0 ? "Nothing in your goals is dated today, and no goal in focus has a next checkpoint." : "Nothing in your goals is dated on this day.")
            } else {
                if offset != 0 {
                    line("What your goals have dated on this day. Reached shows the status now; past days aren’t recorded.")
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in factRow(fact) }
                }
            }
            Text("From your saved goals. Agent briefings aren’t available yet.")
                .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                .accessibilityIdentifier("home.briefing.source")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Amb.canvas, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.briefing")
    }

    @ViewBuilder private func factRow(_ fact: GoalBriefing.Fact) -> some View {
        switch fact {
        case .next(let goal, let checkpoint, let date):
            row("arrow.right.circle", "Next for \(goal): \(checkpoint)" + (GoalFormat.short(date).map { " (\($0))" } ?? ""))
        case .dated(let goal, let checkpoint, let reached):
            row(reached ? "checkmark.circle" : "calendar", "\(goal): \(checkpoint)" + (reached ? " (reached now)" : " (not reached yet)"))
        case .pastDate(let goal, let checkpoint, let date):
            row("exclamationmark.circle", "\(goal): \(checkpoint) was dated \(GoalFormat.short(date) ?? date) and isn’t reached")
        case .targetDate(let goal):
            row("flag", "Target date for \(goal)")
        case .startDate(let goal):
            row("play.circle", "\(goal) starts")
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).font(.amb(.subheadline)).foregroundStyle(Amb.foreground) } icon: {
            Image(systemName: symbol).foregroundStyle(Amb.primary)
        }
        .accessibilityIdentifier("home.briefing.fact")
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground)
    }
}

private struct HomeLatestSnapshot: Equatable, Sendable {
    var items: [DeckActivity.Item] = []
    var labels: [String: String] = [:]
}

/// The five most recently active chats across the workspace, from the same synced activity as the Deck Inbox.
private struct HomeLatestChats: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var snapshot = LiveQuery<HomeLatestSnapshot>(initial: HomeLatestSnapshot())
    static let limit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeHeading(title: "Latest")
            if snapshot.value.items.isEmpty {
                Text(snapshot.loaded ? "No recent chats." : "Loading chats…").font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground)
            }
            ForEach(snapshot.value.items) { item in card(item) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.latest")
        .task(id: workspace.id) { start() }
    }

    private func card(_ item: DeckActivity.Item) -> some View {
        let w = workspace.id
        let route: WorkRoute = item.isThread && item.channelId != nil
            ? .thread(workspaceId: w, channelId: item.channelId!, threadId: item.recordId)
            : .channel(workspaceId: w, channelId: item.channelId ?? item.recordId)
        let channel = item.channelId.flatMap { snapshot.value.labels[$0] }.map { "#\($0)" } ?? "Chat"
        return ThreadRouteLink(route: route) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel).font(.amb(.caption).weight(.semibold)).foregroundStyle(DeckInbox.tint(.chat)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ChatTime.label(item.activityAt)).font(.amb(.caption2)).foregroundStyle(Amb.mutedForeground)
                }
                Text(item.title).font(.amb(.subheadline).weight(item.isUnread ? .semibold : .regular)).foregroundStyle(Amb.foreground)
                    .lineLimit(2).multilineTextAlignment(.leading)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                }
                if item.workingUntil != nil { DeckWorkingLabel(until: item.workingUntil) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(item.isUnread ? Amb.brandOrange.opacity(0.7) : Amb.border, lineWidth: item.isUnread ? 1.2 : 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(channel): \(item.title)\(item.isUnread ? ", unread" : "")")
        .accessibilityIdentifier("home.latest.chat")
    }

    private func start() {
        let w = workspace.id, store = store, viewer = model.connection?.signerNpub, limit = Self.limit
        let origin = model.connection.flatMap { try? TowerOrigin($0.origin).description }
        snapshot.start(store: store, matches: { key in
            (key.workspaceId == w || key.workspaceId == nil)
                && [.access, .threads, .messages, .viewStates, .channels, .agents, .members, .profiles, .attentionPreferences].contains(key.table)
        }) {
            var sources = DeckActivity.Sources()
            let channelRows = try await store.reader.channels(workspaceId: w)
            let names = try await store.reader.people(workspaceId: w).names
            sources.channelScopes = Dictionary(channelRows.map { ($0.id, $0.scopeId) }, uniquingKeysWith: { a, _ in a })
            sources.threads = try await store.reader.deckThreads(workspaceId: w, channelIds: nil)
            sources.viewStates = try await store.reader.viewStates(workspaceId: w)
            sources.activities = try await store.reader.agentActivities(workspaceId: w, channelIds: nil)
            sources.now = ServerClock.shared.now(origin: origin)
            let types = try await store.reader.attentionTypes(workspaceId: w)
            // One card per conversation (a thread, or a channel's own posts), even if the feed repeats one.
            var seen = Set<String>()
            let chats = types.deck(DeckActivity.inbox(sources, context: .home)).filter { item in
                item.kind == .chat && seen.insert(item.isThread ? "thread:\(item.recordId)" : "channel:\(item.channelId ?? item.recordId)").inserted
            }
            return HomeLatestSnapshot(items: Array(chats.prefix(limit)),
                                      labels: Dictionary(channelRows.map { ($0.id, SidebarNavigation.label($0, viewerNpub: viewer, names: names)) }, uniquingKeysWith: { a, _ in a }))
        }
        model.openDeckActivity(workspace, channelIds: model.navigation.value.channels(in: .home).map(\.id))
    }
}
#endif
