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
/// with the background credential too. Verified read snapshots restore only through the unlocked identity.
public struct GoalsService: Sendable {
    public let api: TowerAPI
    public let workspaceId: String
    public let appNpub: String
    public let viewer: String
    let identity: IdentityService
    var cache: LocalContentSnapshot?

    init(api: TowerAPI, workspaceId: String, appNpub: String, viewer: String, identity: IdentityService) {
        self.api = api; self.workspaceId = workspaceId; self.appNpub = appNpub; self.viewer = viewer; self.identity = identity
    }

    /// Focus order (`GoalFocus`), shared with Android and the agent tool.
    public static func order(_ a: GoalDocument, _ b: GoalDocument) -> Bool { GoalFocus.precedes(a, b) }

    private func requireSigner() async throws {
        do { try await identity.requireSigner(npub: viewer) } catch { throw BoardEditError.locked }
    }

    public func cacheRevision() async -> String? { try? await cache?.epoch() }

    public func load() async throws -> GoalsSnapshot {
        let epoch = try await cache?.epoch()
        let space = try await api.goalsSpace(workspaceId: workspaceId, appNpub: appNpub, viewer: viewer)
        guard case .ready(let channel, _) = space else { let snapshot = GoalsSnapshot(space: space, goals: [], unreadable: []); await remember(snapshot, epoch: epoch); return snapshot }
        var goals: [GoalDocument] = [], unreadable: [UnreadableGoal] = []
        for file in try await api.goalFiles(workspaceId: workspaceId, appNpub: appNpub, channelId: channel.id) {
            do { goals.append(try await api.readGoal(workspaceId: workspaceId, appNpub: appNpub, file: file)) }
            catch let e as GoalError { unreadable.append(UnreadableGoal(fileId: file.id, name: file.displayName, reason: e.localizedDescription)) }
            catch TowerError.http(let status, _, _) where status == 404 || status == 403 { continue }
        }
        let snapshot = GoalsSnapshot(space: space, goals: goals.sorted(by: Self.order), unreadable: unreadable)
        if let epoch, try await cache?.epoch() != epoch { throw CancellationError() }
        await remember(snapshot, epoch: epoch)
        return snapshot
    }

    public func read(_ fileId: String) async throws -> GoalDocument {
        let document = try await api.readGoal(workspaceId: workspaceId, appNpub: appNpub, fileId: fileId)
        await remember(document); return document
    }

    public func create(_ goal: Goal, channelId: String) async throws -> GoalDocument {
        try await requireSigner()
        let document = try await api.createGoal(workspaceId: workspaceId, appNpub: appNpub, channelId: channelId, goal: goal)
        await remember(document); return document
    }

    public func edit(_ fileId: String, _ edits: [GoalEdit]) async throws -> GoalDocument {
        try await requireSigner()
        let signer = viewer, identity = identity
        let transport = api.goalTransport(workspaceId: workspaceId, appNpub: appNpub, requireSigner: {
            do { try await identity.requireSigner(npub: signer) } catch { throw BoardEditError.locked }
        })
        let document = try await GoalEditor.edit(transport, fileId: fileId, edits: edits)
        await remember(document); return document
    }

    /// Saves a focus move write by write; see `GoalEditor.move`.
    public func move(_ writes: [GoalFocus.Write]) async throws -> [GoalDocument] {
        try await requireSigner()
        let signer = viewer, identity = identity
        let transport = api.goalTransport(workspaceId: workspaceId, appNpub: appNpub, requireSigner: {
            do { try await identity.requireSigner(npub: signer) } catch { throw BoardEditError.locked }
        })
        do {
            let documents = try await GoalEditor.move(transport, writes: writes)
            for document in documents { await remember(document) }; return documents
        } catch let failure as GoalFocusMoveFailed {
            for document in failure.saved { await remember(document) }
            throw failure
        }
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
        var service = GoalsService(api: api(origin: try TowerOrigin(connection.origin)), workspaceId: workspace.id, appNpub: workspace.appNpub,
                     viewer: connection.signerNpub, identity: identity)
        service.cache = LocalContentSnapshot(store: store, identity: identity, boundary: try WorkspaceBoundary(connection: connection, workspace: workspace))
        return service
    }
}
