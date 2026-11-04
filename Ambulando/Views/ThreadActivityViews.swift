import SwiftUI
import AmbulandoCore

/// The open conversation's agent lifecycles (design "Tower-backed live agent activity" §11): liveness is the header,
/// commentary is history. A live turn shows its state and its newest public commentary as work happens; a turn whose
/// lease passed shows "Stopped responding" (never finished); a finished turn collapses to "Earlier activity". Durable
/// final replies are ordinary messages above and are never touched here.
struct ThreadActivitySnapshot: Sendable, Equatable {
    struct Item: Sendable, Equatable, Identifiable {
        let record: AgentActivityRecord
        let agent: String
        let commentary: [AgentCommentaryEntry]
        var id: String { record.id }
    }
    var items: [Item] = []
}

struct ThreadActivityStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    /// Reports the newest shown activity line, so the list can follow it when the reader is at the newest message.
    var onTail: (String) -> Void = { _ in }
    @State private var snapshot = LiveQuery<ThreadActivitySnapshot>(initial: ThreadActivitySnapshot())

    /// Lifecycles shown: the newest few, and only those still current (live, or stopped within the display window) or the
    /// latest finished one.
    static let shown = 3

    var body: some View {
        // Re-evaluated against Tower's clock on every render: on foreground (scene phase), every few seconds while a turn
        // is live, and exactly at the next clear point (deadline + grace), so expired text never stays current.
        let _ = scenePhase
        let origin = model.connection.flatMap { try? TowerOrigin($0.origin).description }
        TimelineView(ActivitySchedule(items: snapshot.value.items.map(\.record), origin: origin)) { _ in
            let now = ServerClock.shared.now(origin: origin)
            let visible = Self.visible(snapshot.value.items, now: now)
            VStack(spacing: 6) {
                ForEach(visible) { item in ThreadActivityCard(item: item, now: now) }
            }
            .padding(.horizontal, 12)
            .padding(.top, visible.isEmpty ? 0 : 6)
            .onChange(of: Self.tail(visible, now: now)) { _, tail in onTail(tail) }
        }
        .task(id: target.threadId) { start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let thread = target.threadId { model.openThreadActivity(thread, channelId: target.channelId, in: workspace) }
        }
    }

    static func visible(_ items: [ThreadActivitySnapshot.Item], now: Date) -> [ThreadActivitySnapshot.Item] {
        var shownTerminal = false
        return items.prefix(shown).filter { item in
            let phase = AgentLiveness.phase(item.record, now: now)
            if phase.isLive { return true }
            if phase == .stopped {
                // A turn that stopped responding stays readable for the display window, then leaves the header.
                guard let clear = AgentLiveness.clearsAt(item.record) ?? item.record.leaseExpiresAt else { return false }
                return now.timeIntervalSince(clear) < AgentLiveness.stoppedDisplayWindow
            }
            // Only the newest finished turn, and only if it said something.
            guard !shownTerminal, !item.commentary.isEmpty else { return false }
            shownTerminal = true
            return true
        }
    }

    static func tail(_ items: [ThreadActivitySnapshot.Item], now: Date) -> String {
        items.map { "\($0.id):\($0.commentary.last?.sequence ?? -1):\(AgentLiveness.phase($0.record, now: now).isLive)" }.joined(separator: ",")
    }

    private func start() {
        guard let threadId = target.threadId else { return }
        let w = target.workspaceId, store = store, target = target
        snapshot.start(store: store, keepingValue: true, matches: { key in
            (key.workspaceId == w || key.workspaceId == nil) && [.agents, .members, .profiles].contains(key.table)
        }) {
            let records = try await store.reader.threadAgentActivities(workspaceId: w, threadId: threadId, limit: Self.shown + 2)
            let history = try await store.reader.agentCommentary(workspaceId: w, activityRowIds: records.map(\.id))
            let people = try await store.reader.people(connectionId: target.connectionId, workspaceId: w)
            return ThreadActivitySnapshot(items: records.map { record in
                var lines = history[record.id] ?? []
                // A lifecycle whose history is not stored yet still shows the snapshot's newest public line.
                if lines.isEmpty, record.state == "working", let text = record.latestText {
                    lines = [AgentCommentaryEntry(activityRowId: record.id, turnId: record.turnId, sequence: record.sequence, deliveryCursor: nil,
                                                  label: nil, summary: nil, body: text, createdAt: record.updatedAt)]
                }
                return .init(record: record, agent: people.name(record.agentNpub), commentary: lines)
            })
        }
        model.openThreadActivity(threadId, channelId: target.channelId, in: workspace)
    }
}

/// Refreshes while anything is live: every `AgentLiveness.refreshInterval` and exactly at each clear point.
private struct ActivitySchedule: TimelineSchedule {
    let items: [AgentActivityRecord]
    let origin: String?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let now = ServerClock.shared.now(origin: origin)
        let clears = items.compactMap(AgentLiveness.clearsAt).filter { $0 > now }.map { ServerClock.shared.local($0, origin: origin) }
        let live = !clears.isEmpty
        // Stopped turns also leave the header after their display window.
        let windows = items.compactMap { a -> Date? in
            guard AgentLiveness.phase(a, now: now) == .stopped, let clear = AgentLiveness.clearsAt(a) ?? a.leaseExpiresAt else { return nil }
            let end = clear.addingTimeInterval(AgentLiveness.stoppedDisplayWindow)
            return end > now ? ServerClock.shared.local(end, origin: origin) : nil
        }
        var pending = (clears + windows).sorted()
        var next = startDate
        var first = true
        return AnyIterator {
            if first { first = false; return startDate }
            guard live || !pending.isEmpty else { return nil }
            let periodic = live ? next.addingTimeInterval(AgentLiveness.refreshInterval) : .distantFuture
            if let exact = pending.first, exact <= periodic {
                pending.removeFirst()
                next = exact
                return exact
            }
            guard live else { return nil }
            next = periodic
            return periodic
        }
    }
}

private struct ThreadActivityCard: View {
    let item: ThreadActivitySnapshot.Item
    let now: Date
    @State private var expanded = false
    /// Lines shown before "Show all" while live; a stopped or finished turn starts collapsed.
    static let collapsedLines = 3

    var body: some View {
        let phase = AgentLiveness.phase(item.record, now: now)
        VStack(alignment: .leading, spacing: 6) {
            Button { if !phase.isLive || item.commentary.count > Self.collapsedLines { expanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if phase == .working {
                        ProgressView().controlSize(.mini).accessibilityHidden(true)
                    } else {
                        Image(systemName: icon(phase)).font(.amb(.caption)).foregroundStyle(tint(phase)).accessibilityHidden(true)
                    }
                    Text(item.agent).font(.amb(.caption).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1)
                    Text(status(phase)).font(.amb(.caption)).foregroundStyle(tint(phase)).lineLimit(1)
                        .accessibilityIdentifier("thread.activity.status")
                    Spacer(minLength: 0)
                    if !phase.isLive || item.commentary.count > Self.collapsedLines {
                        Image(systemName: open(phase) ? "chevron.up" : "chevron.down").font(.amb(.caption2)).foregroundStyle(Amb.mutedForeground)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("thread.activity.header")
            if open(phase) || (phase.isLive && !item.commentary.isEmpty) {
                let lines = open(phase) ? item.commentary : Array(item.commentary.suffix(Self.collapsedLines))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(entry.text).font(.amb(.caption)).foregroundStyle(phase.isLive ? Amb.foreground : Amb.mutedForeground)
                                .lineLimit(open(phase) ? nil : 2).multilineTextAlignment(.leading).textSelection(.enabled)
                            Spacer(minLength: 4)
                            Text(ChatTime.label(entry.createdAt)).font(.amb(.caption2)).foregroundStyle(Amb.mutedForeground)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("thread.activity.line")
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Amb.muted.opacity(phase.isLive ? 0.6 : 0.3), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread.activity")
    }

    private func open(_ phase: AgentActivityPhase) -> Bool { expanded }

    private func status(_ phase: AgentActivityPhase) -> String {
        switch phase {
        case .working:
            if let last = lastUpdate ?? Self.time(item.record.createdAt), now.timeIntervalSince(last) >= AgentLiveness.quietThreshold {
                return "Still working · no update for \(Int(now.timeIntervalSince(last) / 60)) min"
            }
            return "Working…"
        case .waiting: return "Waiting for you"
        case .queued(let position): return position.map { "Queued · position \($0)" } ?? "Queued"
        case .stopped:
            let at = (lastUpdate ?? Self.time(item.record.updatedAt)).map { " · last update \(Self.clock.string(from: $0))" } ?? ""
            return "Stopped responding\(at)"
        case .completed: return "Earlier activity · completed"
        case .failed: return "Earlier activity · failed"
        case .cancelled: return "Earlier activity · cancelled"
        }
    }

    /// The newest public line's time (Tower's clock).
    private var lastUpdate: Date? { (item.commentary.last?.createdAt).flatMap(Self.time) }

    private static func time(_ text: String) -> Date? { AgentLiveness.serverDate(text) }

    private func icon(_ phase: AgentActivityPhase) -> String {
        switch phase {
        case .queued: "clock"
        case .waiting: "hand.raised"
        case .stopped: "exclamationmark.circle"
        case .failed: "xmark.circle"
        case .cancelled: "slash.circle"
        default: "checkmark.circle"
        }
    }

    private func tint(_ phase: AgentActivityPhase) -> Color {
        switch phase {
        case .working, .waiting: Amb.primary
        case .stopped, .failed: Amb.destructive
        default: Amb.mutedForeground
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
