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

/// Goals for one workspace as one identity. Generic server authority selects SQL or retained legacy storage.
/// Writes require the unlocked connection signer. Verified snapshots restore only through that identity.
public struct GoalsService: Sendable {
    public let api: TowerAPI
    public let workspaceId: String
    public let appNpub: String
    public let viewer: String
    let identity: IdentityService
    var cache: LocalContentSnapshot?
    var workspaceOwner: String?
    private let mutations = GoalsMutationGate()

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
        if let (repository, current) = try await relational(channelId: channel.id) {
            let snapshot = GoalsSnapshot(space: space, goals: try current.documents(workspaceId: workspaceId, channelId: repository.channelId, owner: viewer).sorted(by: Self.order), unreadable: [])
            if let epoch, try await cache?.epoch() != epoch { throw CancellationError() }
            await remember(snapshot, epoch: epoch); return snapshot
        }
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
        if let (repository, current) = try await personalRelational() {
            guard let document = try current.documents(workspaceId: workspaceId, channelId: repository.channelId, owner: viewer).first(where: { $0.id == fileId }) else {
                if let cache { try? await cache.store.writer.invalidateLocalContent(workspace: workspaceId, record: fileId) }
                throw TowerError.http(status: 404, code: "goal_not_found", stage: "Goals")
            }
            await remember(document); return document
        }
        do {
            let document = try await api.readGoal(workspaceId: workspaceId, appNpub: appNpub, fileId: fileId)
            await remember(document); return document
        } catch {
            if CachedContentFailure.invalidates(error), let cache { try? await cache.store.writer.invalidateLocalContent(workspace: workspaceId, record: fileId) }
            throw error
        }
    }

    /// Primary discussion references are independently ACL checked. They need not belong to this viewer's personal home.
    /// A denied read stays 403 so callers may propagate only the already-readable thread's identity reference.
    public func resolveReference(_ id: String) async throws -> GoalDocument {
        if let workspaceOwner, let repository = try await GoalsRelationalRepository.resolve(api: api, workspaceId: workspaceId, workspaceOwner: workspaceOwner, appNpub: appNpub, id: id) {
            guard let snapshot = try await repository.snapshot(),
                  let document = try snapshot.documents(workspaceId: workspaceId, channelId: repository.channelId, owner: repository.owner).first(where: { $0.id == id }) else {
                throw TowerError.http(status: 404, code: "goal_not_found", stage: "Goal reference")
            }
            return document
        }
        // A missing relational row is not permission to treat retained source bytes as canonical after activation.
        let response = try await api.client.request(path: TowerAPI.base(workspaceId) + "/files/" + TowerAPI.uuid(id), appNpub: appNpub)
        guard let raw = try JSONValue.parse(response)["file"] else { throw GoalsRelationalRows.invalid }
        let file = try FileRecord(raw: raw.serialized())
        guard file.id == id, file.workspaceId == workspaceId, GoalFiles.isGoal(file) else { throw GoalError.invalid("This is not a goal.") }
        guard try await relational(channelId: file.channelId) == nil else {
            throw TowerError.http(status: 404, code: "goal_not_found", stage: "Goal reference")
        }
        return try await api.readGoal(workspaceId: workspaceId, appNpub: appNpub, file: file)
    }

    public func create(_ goal: Goal, channelId: String) async throws -> GoalDocument {
        try await mutations.run { try await performCreate(goal, channelId: channelId) }
    }

    private func performCreate(_ goal: Goal, channelId: String) async throws -> GoalDocument {
        try await requireSigner()
        if let (repository, current) = try await relational(channelId: channelId) {
            try await verifyAddedReferences(before: Goal(name: "", description: ""), after: goal)
            let document = try await repository.save(goal: goal, id: UUID().uuidString.lowercased(), before: current, actor: viewer)
            await remember(document); return document
        }
        let document = try await api.createGoal(workspaceId: workspaceId, appNpub: appNpub, channelId: channelId, goal: goal)
        await remember(document); return document
    }

    public func edit(_ fileId: String, _ edits: [GoalEdit]) async throws -> GoalDocument {
        try await mutations.run { try await performEdit(fileId, edits) }
    }

    private func performEdit(_ fileId: String, _ edits: [GoalEdit]) async throws -> GoalDocument {
        try await requireSigner()
        if let (repository, current) = try await personalRelational() {
            guard let head = try current.documents(workspaceId: workspaceId, channelId: repository.channelId, owner: viewer).first(where: { $0.id == fileId }) else {
                throw TowerError.http(status: 404, code: "goal_not_found", stage: "Goals")
            }
            let next = try GoalEdit.applyAll(edits, to: head.goal)
            if next == head.goal { return head }
            try await verifyAddedReferences(before: head.goal, after: next)
            let document = try await repository.save(goal: next, id: fileId, before: current, actor: viewer)
            await remember(document); return document
        }
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
        if try await personalRelational() != nil {
            var saved: [GoalDocument] = []
            for write in writes {
                do { saved.append(try await edit(write.id, [write.edit])) }
                catch { throw GoalFocusMoveFailed(saved: saved, total: writes.count, underlying: error) }
            }
            return saved
        }
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
        service.workspaceOwner = workspace.ownerNpub
        return service
    }
}

extension GoalsService {
    /// A cached authority stamp prevents an outage or a missing namespace from re-enabling the legacy writer.
    private func relational(channelId: String) async throws -> (GoalsRelationalRepository, GoalsRelationalRepository.Snapshot)? {
        let authoritySlot = "goals-authority:" + channelId
        let prior = try await cache?.read(authoritySlot)
        guard let workspaceOwner else {
            guard prior == nil, await cached()?.goals.contains(where: { $0.storage == .relational }) != true else { throw GoalsRelationalRows.invalid }
            return nil
        }
        var repository = GoalsRelationalRepository(api: api, workspaceId: workspaceId, workspaceOwner: workspaceOwner, appNpub: appNpub, channelId: channelId, owner: viewer)
        repository.cache = cache
        repository.requireWriteSigner = { try await self.requireSigner() }
        let snapshot: GoalsRelationalRepository.Snapshot?
        do { snapshot = try await repository.snapshot() }
        catch {
            if CachedContentFailure.invalidates(error), let cache {
                try? await cache.store.writer.invalidateLocalContent(workspace: workspaceId, record: channelId)
            }
            throw error
        }
        guard let current = snapshot else {
            guard prior == nil, await cached()?.goals.contains(where: { $0.storage == .relational }) != true else {
                throw GoalSaveFailed(message: "Goals storage is unavailable. Saved content is retained; reconnect before changing it.", retryable: true)
            }
            return nil
        }
        if let prior {
            let previous = try JSONValue.parse(prior)
            guard let oldEpoch = previous["epoch"]?.intValue, let newEpoch = current.authority["epoch"]?.intValue,
                  newEpoch >= oldEpoch, newEpoch != oldEpoch || previous["mode"] == current.authority["mode"] else { throw GoalsRelationalRows.invalid }
        }
        // Store the authority separately from display content; cache restoration is never a write grant.
        try await cache?.save(authoritySlot, current.authority.serialized())
        return (repository, current)
    }

    private func personalRelational() async throws -> (GoalsRelationalRepository, GoalsRelationalRepository.Snapshot)? {
        if workspaceOwner == nil {
            guard await cached()?.goals.contains(where: { $0.storage == .relational }) != true else { throw GoalsRelationalRows.invalid }
            return nil
        }
        let space = try await api.goalsSpace(workspaceId: workspaceId, appNpub: appNpub, viewer: viewer)
        guard case .ready(let channel, _) = space else {
            await remember(GoalsSnapshot(space: space, goals: [], unreadable: []))
            throw GoalError.invalid("Your private Goals channel could not be verified. Reconnect before changing goals.")
        }
        return try await relational(channelId: channel.id)
    }

    private func verifyAddedReferences(before: Goal, after: Goal) async throws {
        for ref in after.links + after.pinnedRefs where !(before.links + before.pinnedRefs).contains(where: { $0.key == ref.key }) {
            let path: String, key: String
            switch ref.type {
            case .chat: path = "threads"; key = "thread"
            case .task: path = "tasks"; key = "task"
            case .doc: path = "docs"; key = "doc"
            case .file: path = "files"; key = "file"
            }
            let bytes = try await api.client.request(path: TowerAPI.base(workspaceId) + "/" + path + "/" + TowerAPI.uuid(ref.recordId), appNpub: appNpub)
            guard let row = try JSONValue.parse(bytes)[key], row["id"] == .string(ref.recordId), row["workspace_id"] == .string(workspaceId),
                  row["channel_id"]?.stringValue != nil, ref.channelId == nil || row["channel_id"] == .string(ref.channelId!), goalRecordAvailable(row) else {
                throw GoalError.invalid("This reference is unavailable in this workspace. Nothing was saved.")
            }
        }
    }
}

/// Serializes user saves across suspension points so one durable pending slot cannot be overwritten by another save.
private actor GoalsMutationGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func run<T: Sendable>(_ action: @Sendable () async throws -> T) async throws -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
        defer {
            if waiters.isEmpty { busy = false }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await action()
    }
}
