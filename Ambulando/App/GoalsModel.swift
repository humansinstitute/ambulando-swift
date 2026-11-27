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
    @ObservationIgnored private var localRevision: String?
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

    func reconcileLocalRemovals() async {
        let revision = await service.cacheRevision()
        guard revision != localRevision, isCurrent(boundary) else { return }
        localRevision = revision
        guard loaded else { return }
        if let saved = await service.cached() {
            let keep = Set(saved.goals.map(\.id))
            goals.removeAll { !keep.contains($0.id) }
        } else {
            goals = []; space = nil; loaded = false
            error = "Saved Goals are no longer available with their previous access."
        }
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
        await reconcileLocalRemovals()
        if !loaded, let snapshot = await service.cached(), isCurrent(boundary) {
            space = snapshot.space; goals = snapshot.goals; unreadable = snapshot.unreadable; loaded = true
            localRevision = await service.cacheRevision()
            note("cached")
        }
        loading = true
        defer { loading = false }
        do {
            let snapshot = try await service.load()
            guard isCurrent(boundary) else { note("dropped-not-current"); return }
            space = snapshot.space; goals = snapshot.goals; unreadable = snapshot.unreadable; error = nil; loaded = true
            localRevision = await service.cacheRevision()
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
        guard isCurrent(boundary) else { throw CancellationError() }
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

    func createDiscussion(goalFileId: String, channelId: String, scopeId: String, expectedDefault: String?, requestId: String,
                          beforeCreate: @escaping @Sendable () async throws -> Void) async throws -> ThreadRecord {
        guard isCurrent(boundary) else { throw CancellationError() }
        let thread = try await service.api.createGoalDiscussion(workspaceId: service.workspaceId, appNpub: service.appNpub,
            goalFileId: goalFileId, channelId: channelId, scopeId: scopeId, expectedDefault: expectedDefault,
            requestId: requestId, beforeCreate: beforeCreate)
        guard isCurrent(boundary) else { throw CancellationError() }
        return thread
    }

    func findDiscussion(_ receipt: GoalDiscussionReceipt) async throws -> ThreadRecord? {
        guard isCurrent(boundary), receipt.workspaceId == service.workspaceId else { throw CancellationError() }
        let thread = try await service.api.findGoalDiscussion(workspaceId: service.workspaceId, appNpub: service.appNpub,
            channelId: receipt.channelId, goalFileId: receipt.goalFileId, requestId: receipt.requestId)
        guard isCurrent(boundary) else { throw CancellationError() }
        return thread
    }

    /// Picker rows are discovery only. Read the original through its own ACL before saving a pin reference.
    func pinReference(goalFileId: String, link: GoalLink) async throws {
        guard isCurrent(boundary) else { throw CancellationError() }
        guard link.type == .doc || link.type == .file, UUID(uuidString: service.workspaceId) != nil,
              UUID(uuidString: link.recordId) != nil else { throw GoalError.invalid("Only existing Docs and Files can be pinned.") }
        let workspaceId: String, recordId: String, channelId: String, raw: Data
        do {
            if link.type == .doc {
                let doc = try await service.api.doc(workspaceId: service.workspaceId, appNpub: service.appNpub, docId: link.recordId)
                workspaceId = doc.workspaceId; recordId = doc.id; channelId = doc.channelId; raw = doc.raw
            } else {
                let data = try await service.api.client.request(path: "/api/v4/flightdeck-pg/workspaces/\(service.workspaceId)/files/\(link.recordId)", appNpub: service.appNpub)
                guard let value = try JSONValue.parse(data)["file"], value.isObject else { throw GoalError.invalid("This file could not be verified. Nothing was pinned.") }
                let file = try FileRecord(raw: value.serialized())
                workspaceId = file.workspaceId; recordId = file.id; channelId = file.channelId; raw = file.raw
            }
        } catch TowerError.http(let status, _, _) where status == 403 || status == 404 {
            throw GoalError.invalid("This reference is no longer available to you. Nothing was pinned.")
        }
        guard isCurrent(boundary) else { throw CancellationError() }
        guard workspaceId == service.workspaceId, recordId == link.recordId,
              link.channelId == nil || link.channelId == channelId else { throw GoalError.invalid("This reference moved or belongs to another workspace. Refresh the picker; nothing was pinned.") }
        let source = try JSONValue.parse(raw)
        guard source["access_removed"]?.boolValue != true,
              !["archived", "deleted", "revoked", "access_removed"].contains(source["record_state"]?.stringValue ?? ""),
              source["deleted_at"] == nil || source["deleted_at"] == .null,
              source["archived_at"] == nil || source["archived_at"] == .null else {
            throw GoalError.invalid("This reference is no longer available. Nothing was pinned.")
        }
        try await edit(goalFileId, .pin(GoalLink(type: link.type, recordId: recordId, channelId: channelId, extra: link.extra)))
    }

    func setDefaultDiscussionChannel(goalFileId: String, expected: String?, channel: ChannelRecord?) async throws {
        guard isCurrent(boundary) else { throw CancellationError() }
        if let channel {
            func available(_ raw: Data) -> Bool {
                guard let value = try? JSONValue.parse(raw) else { return false }
                return !["archived", "deleted", "revoked", "access_removed"].contains(value["record_state"]?.stringValue ?? "")
                    && value["access_removed"]?.boolValue != true
                    && (value["deleted_at"] == nil || value["deleted_at"] == .null)
                    && (value["archived_at"] == nil || value["archived_at"] == .null)
            }
            let scopes = try await service.api.scopes(workspaceId: service.workspaceId, appNpub: service.appNpub)
            guard scopes.contains(where: { $0.id == channel.scopeId && $0.workspaceId == service.workspaceId && available($0.raw) }) else {
                throw GoalError.invalid("The selected channel’s scope is unavailable. Choose again.")
            }
            let channels = try await service.api.channels(workspaceId: service.workspaceId, scopeId: channel.scopeId, appNpub: service.appNpub)
            guard channels.contains(where: { $0.id == channel.id && $0.workspaceId == service.workspaceId && available($0.raw) }) else {
                throw GoalError.invalid("The selected channel is no longer accessible. Choose again.")
            }
        }
        guard isCurrent(boundary) else { throw CancellationError() }
        try await edit(goalFileId, .setDefaultChannel(expected: expected, value: channel?.id))
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
        guard isUnlocked, let sync, let connection, let boundary = selectedWorkspaceBoundary, workspace.id == selectedWorkspace?.id,
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
