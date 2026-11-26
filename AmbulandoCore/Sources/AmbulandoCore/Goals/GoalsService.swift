import Foundation

/// A goal file that exists but cannot be shown (newer app version, damaged content). It is never rewritten.
public struct UnreadableGoal: Sendable, Equatable, Identifiable {
    public let fileId: String
    public let name: String
    public let reason: String
    public var id: String { fileId }
}

public struct GoalsSnapshot: Sendable, Equatable {
    public var space: GoalsSpaceState
    public var goals: [GoalDocument]
    public var unreadable: [UnreadableGoal]
}

/// Goals for one workspace as one identity. Every write requires the unlocked signer of this connection; reads work
/// with the background credential too. Nothing here is cached beyond what the caller keeps.
public struct GoalsService: Sendable {
    public let api: TowerAPI
    public let workspaceId: String
    public let appNpub: String
    public let viewer: String
    let identity: IdentityService

    init(api: TowerAPI, workspaceId: String, appNpub: String, viewer: String, identity: IdentityService) {
        self.api = api; self.workspaceId = workspaceId; self.appNpub = appNpub; self.viewer = viewer; self.identity = identity
    }

    /// Focus order (`GoalFocus`), shared with Android and the agent tool.
    public static func order(_ a: GoalDocument, _ b: GoalDocument) -> Bool { GoalFocus.precedes(a, b) }

    private func requireSigner() async throws {
        do { try await identity.requireSigner(npub: viewer) } catch { throw BoardEditError.locked }
    }

    public func load() async throws -> GoalsSnapshot {
        let space = try await api.goalsSpace(workspaceId: workspaceId, appNpub: appNpub, viewer: viewer)
        guard case .ready(let channel, _) = space else { return GoalsSnapshot(space: space, goals: [], unreadable: []) }
        var goals: [GoalDocument] = [], unreadable: [UnreadableGoal] = []
        for file in try await api.goalFiles(workspaceId: workspaceId, appNpub: appNpub, channelId: channel.id) {
            do { goals.append(try await api.readGoal(workspaceId: workspaceId, appNpub: appNpub, file: file)) }
            catch let e as GoalError { unreadable.append(UnreadableGoal(fileId: file.id, name: file.displayName, reason: e.localizedDescription)) }
        }
        return GoalsSnapshot(space: space, goals: goals.sorted(by: Self.order), unreadable: unreadable)
    }

    public func read(_ fileId: String) async throws -> GoalDocument {
        try await api.readGoal(workspaceId: workspaceId, appNpub: appNpub, fileId: fileId)
    }

    public func create(_ goal: Goal, channelId: String) async throws -> GoalDocument {
        try await requireSigner()
        return try await api.createGoal(workspaceId: workspaceId, appNpub: appNpub, channelId: channelId, goal: goal)
    }

    public func edit(_ fileId: String, _ edits: [GoalEdit]) async throws -> GoalDocument {
        try await requireSigner()
        let signer = viewer, identity = identity
        let transport = api.goalTransport(workspaceId: workspaceId, appNpub: appNpub, requireSigner: {
            do { try await identity.requireSigner(npub: signer) } catch { throw BoardEditError.locked }
        })
        return try await GoalEditor.edit(transport, fileId: fileId, edits: edits)
    }

    /// Saves a focus move write by write; see `GoalEditor.move`.
    public func move(_ writes: [GoalFocus.Write]) async throws -> [GoalDocument] {
        try await requireSigner()
        let signer = viewer, identity = identity
        let transport = api.goalTransport(workspaceId: workspaceId, appNpub: appNpub, requireSigner: {
            do { try await identity.requireSigner(npub: signer) } catch { throw BoardEditError.locked }
        })
        return try await GoalEditor.move(transport, writes: writes)
    }

    public func setUp(scopeId: String, agentActorIds: [String]) async throws -> ChannelRecord {
        try await requireSigner()
        return try await api.createGoalsSpace(workspaceId: workspaceId, appNpub: appNpub, viewer: viewer, scopeId: scopeId, agentActorIds: agentActorIds)
    }

    public func setAgentAccess(channelId: String, agent: MemberRecord, enabled: Bool) async throws {
        try await requireSigner()
        try await api.setGoalsAgentAccess(workspaceId: workspaceId, appNpub: appNpub, channelId: channelId, agent: agent, enabled: enabled)
    }
}

extension WorkspaceSync {
    /// Goals for `workspace` as `connection`'s identity.
    public func goals(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord) throws -> GoalsService {
        GoalsService(api: api(origin: try TowerOrigin(connection.origin)), workspaceId: workspace.id, appNpub: workspace.appNpub,
                     viewer: connection.signerNpub, identity: identity)
    }
}
