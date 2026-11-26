import AmbulandoCore
import Foundation
import Observation

/// Screen state for the personal Goals list and the goal being viewed. One model serves one workspace boundary; every
/// result is dropped if the boundary changed while it was in flight, so a switched or locked workspace can neither
/// show nor save another workspace's goals.
@MainActor
@Observable
final class GoalsModel {
    let boundary: WorkspaceBoundary
    @ObservationIgnored private let service: GoalsService
    @ObservationIgnored private let isCurrent: @MainActor (WorkspaceBoundary) -> Bool

    private(set) var loading = false
    private(set) var loaded = false
    private(set) var space: GoalsSpaceState?
    private(set) var goals: [GoalDocument] = []
    private(set) var unreadable: [UnreadableGoal] = []
    /// Plain-language reason the last load failed; the previous goals stay visible.
    private(set) var error: String?
    /// The load in progress. It is not tied to the view that started it, so a view that disappears (or is rebuilt)
    /// mid-load does not cancel it, and callers that arrive meanwhile wait for its result instead of being skipped.
    @ObservationIgnored private var inflight: Task<Void, Never>?

    init(boundary: WorkspaceBoundary, service: GoalsService, isCurrent: @escaping @MainActor (WorkspaceBoundary) -> Bool) {
        self.boundary = boundary; self.service = service; self.isCurrent = isCurrent
    }

    var channel: ChannelRecord? { if case .ready(let channel, _) = space { channel } else { nil } }
    var viewer: String { service.viewer }
    func goal(_ fileId: String) -> GoalDocument? { goals.first { $0.id == fileId } }

    /// Goals that link a record, for the "In goals" indicator on a source.
    func goals(linking type: GoalLinkType, recordId: String) -> [GoalDocument] {
        goals.filter { $0.goal.links.contains { $0.type == type && $0.recordId == recordId.lowercased() } }
    }

    /// The latest refresh outcomes (newest last, at most 12), for diagnosing a load that never finishes. Not shown.
    @ObservationIgnored private(set) var refreshLog: [String] = []
    private func note(_ outcome: String) {
        refreshLog.append(outcome)
        if refreshLog.count > 12 { refreshLog.removeFirst() }
    }

    func refresh() async {
        if let inflight { note("joined"); await inflight.value; return }
        note("start")
        let load = Task { await self.load() }
        inflight = load
        await load.value
        inflight = nil
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let snapshot = try await service.load()
            guard isCurrent(boundary) else { note("dropped-not-current"); return }
            space = snapshot.space; goals = snapshot.goals; unreadable = snapshot.unreadable; error = nil; loaded = true
            note("loaded")
        } catch is CancellationError {
            note("cancelled")
        } catch {
            guard isCurrent(boundary) else { note("dropped-not-current"); return }
            self.error = Self.message(error)
            note("failed")
        }
    }

    func setUp(scopeId: String, agentActorIds: [String]) async -> String? {
        do { _ = try await service.setUp(scopeId: scopeId, agentActorIds: agentActorIds) } catch { return Self.message(error) }
        await refresh()
        return nil
    }

    func setAgent(_ agent: MemberRecord, enabled: Bool) async -> String? {
        guard let channel else { return "Set up goals first." }
        do { try await service.setAgentAccess(channelId: channel.id, agent: agent, enabled: enabled) } catch { return Self.message(error) }
        await refresh()
        return nil
    }

    func create(_ goal: Goal) async -> Result<GoalDocument, Error> {
        guard let channel else { return .failure(GoalError.invalid("Set up goals before adding one.")) }
        do {
            let created = try await service.create(goal, channelId: channel.id)
            if isCurrent(boundary) { publish(created) }
            return .success(created)
        } catch { return .failure(error) }
    }

    /// Throws `GoalError.conflict` / `GoalSaveFailed` with a readable message; the saved goal is unchanged in both cases.
    @discardableResult
    func edit(_ fileId: String, _ edits: GoalEdit...) async throws -> GoalDocument { try await edit(fileId, edits) }

    @discardableResult
    func edit(_ fileId: String, _ edits: [GoalEdit]) async throws -> GoalDocument {
        let saved = try await service.edit(fileId, edits)
        if isCurrent(boundary) { publish(saved) }
        return saved
    }

    /// A focus reorder is saving; further moves wait for it so each plan starts from saved ranks.
    private(set) var moving = false

    /// Moves an active goal to `toIndex` among the active goals in focus order with the fewest rank edits
    /// (`GoalFocus.planMove`, saved by `GoalsService.move`). On a refusal the move stops, the earlier writes stay (each
    /// leaves a valid order), the goals are reloaded and a readable message says how much was saved.
    func move(_ fileId: String, toIndex: Int) async -> String? {
        guard !moving else { return nil }
        moving = true
        defer { moving = false }
        do {
            let active = GoalFocus.order(goals.filter { $0.goal.status == .active })
            let saved = try await service.move(try GoalFocus.planMove(active, id: fileId, toIndex: toIndex))
            if isCurrent(boundary) { saved.forEach(publish) }
            return nil
        } catch {
            if let failed = error as? GoalFocusMoveFailed, isCurrent(boundary) { failed.saved.forEach(publish) }
            await refresh()
            return Self.message(error)
        }
    }

    /// Re-reads one goal (e.g. after a conflict or an agent edit).
    func reload(_ fileId: String) async {
        guard let fresh = try? await service.read(fileId), isCurrent(boundary) else { return }
        publish(fresh)
    }

    /// Adds a link from a source record to a goal, saving only the reference. Tower decides write access.
    func add(_ link: GoalLink, to fileId: String) async -> String? {
        do { try await edit(fileId, .link(link)); return nil } catch { return Self.message(error) }
    }

    private func publish(_ doc: GoalDocument) {
        goals = (goals.filter { $0.id != doc.id } + [doc]).sorted(by: GoalsService.order)
        error = nil
    }

    static func message(_ error: Error) -> String {
        switch error {
        case let e as GoalError: e.localizedDescription
        case let e as GoalSaveFailed: e.message
        case let e as GoalFocusMoveFailed: e.errorDescription ?? e.reason
        case let e as BoardEditError: e.localizedDescription
        case TowerError.http(let status, _, _) where status == 403: "You don’t have access to change goals here."
        case TowerError.http(let status, _, _) where status == 404: "This is no longer available to you."
        default: error.localizedDescription
        }
    }
}

extension AppModel {
    /// The Goals model of the selected workspace, created on first use. Nil without an open, connected workspace.
    func goalsModel(for workspace: WorkspaceRecord) -> GoalsModel? {
        guard let sync, let connection, let boundary = selectedWorkspaceBoundary, workspace.id == selectedWorkspace?.id,
              workspace.appNpub == selectedWorkspace?.appNpub else { return nil }
        if let existing = goalModels[boundary.id] { return existing }
        guard let service = try? sync.goals(connection, workspace) else { return nil }
        let model = GoalsModel(boundary: boundary, service: service, isCurrent: { [weak self] in self?.selectedWorkspaceBoundary == $0 })
        goalModels[boundary.id] = model
        return model
    }
}

extension AppModel {
    /// Opens the personal Goals list from Home (the sidebar) on Deck, closing the sidebar.
    func openGoals() {
        guard let workspace = selectedWorkspace?.id else { return }
        if fileNappletNavigation?({ self.openGoals() }) == true { return }
        deckPath = [.goals(workspaceId: workspace)]
        show(.deck)
    }
}
