import AmbulandoCore
import Foundation
import Observation

/// Grandparent Chat's state on top of `AppModel` (identity, connection, workspace runtimes, outbox and sync stay the
/// shared Ambulando foundation). It adds exactly one thing: the binding to a single conversation, and the rules that
/// keep every read, write and route inside it. Tower stays authoritative for who may read and write.
@MainActor
@Observable
final class FamilyChatModel {
    let app: AppModel

    private(set) var binding: FamilyBinding?
    /// The signer whose binding has been read from disk; nil until read for the current identity.
    private(set) var bindingLoadedFor: String?
    private(set) var access: FamilyAccess = .checking
    /// The last live look at Tower for the bound target. Cleared when the binding changes.
    private(set) var live: FamilyVerification?
    private(set) var isVerifying = false
    var notice: String?

    @ObservationIgnored private var verifyTask: Task<FamilyVerification?, Never>?

    init(app: AppModel) { self.app = app }

    var signer: String? { app.identity.npub }
    var bindingLoaded: Bool { signer != nil && bindingLoadedFor == signer }

    // MARK: Binding

    /// Reads this account's binding (and finishes an interrupted creation) once the identity is known.
    func loadBinding() async {
        guard let signer, let store = app.catalogStore, bindingLoadedFor != signer else { return }
        let stored = try? await store.reader.familyBinding(signerNpub: signer)
        guard signer == self.signer else { return }
        binding = stored
        bindingLoadedFor = signer
        live = nil
        await alignConnection()
        await resolvePendingCreation()
        await refreshAccess()
    }

    func save(_ next: FamilyBinding) async {
        guard let store = app.catalogStore else { return }
        do {
            try await store.writer.setFamilyBinding(next)
            binding = next; bindingLoadedFor = next.signerNpub; live = nil
            // The app keeps syncing only what it shows: the other workspaces of this account are switched off.
            restrictSync(to: next)
            await refreshAccess()
        } catch { notice = error.localizedDescription }
    }

    /// Forget which conversation is chosen. Cached messages, drafts and unsent messages are left where they are.
    func forgetChoice() async {
        guard let binding, let store = app.catalogStore else { return }
        do {
            try await store.writer.clearFamilyBinding(signerNpub: binding.signerNpub)
            self.binding = nil; live = nil; access = .checking
        } catch { notice = error.localizedDescription }
    }

    /// A reconnect to the same Tower as the same account may carry a new connection id; the binding follows it.
    private func alignConnection() async {
        guard var binding, let connection = app.connection, connection.origin == binding.origin,
              connection.signerNpub == binding.signerNpub, connection.id != binding.connectionId else { return }
        binding.connectionId = connection.id
        if let store = app.catalogStore, (try? await store.writer.setFamilyBinding(binding)) != nil { self.binding = binding }
    }

    private func restrictSync(to binding: FamilyBinding) {
        for entry in app.workspaceEntries where entry.connection.signerNpub == binding.signerNpub {
            let bound = entry.workspace.id == binding.workspaceId && entry.workspace.appNpub == binding.appNpub
            if entry.enabled != bound { app.setWorkspaceEnabled(entry, bound) }
        }
    }

    // MARK: Workspace runtime

    var boundEntry: EnabledWorkspaceEntry? {
        guard let binding else { return nil }
        return app.workspaceEntries.first { $0.workspace.id == binding.workspaceId && $0.workspace.appNpub == binding.appNpub
            && $0.connection.signerNpub == binding.signerNpub }
    }

    /// The store of the bound workspace, once it is the selected one.
    var boundStore: LocalStore? {
        guard let binding, app.selectedWorkspaceId == binding.workspaceId, app.connection?.id == binding.connectionId else { return nil }
        return app.store
    }

    /// Makes the bound workspace the active one (a restored session may have another selected) and starts its sync.
    func activateBoundWorkspace() {
        guard let binding, let entry = boundEntry else { return }
        if !entry.enabled { app.setWorkspaceEnabled(entry, true) }
        if app.selectedWorkspaceId != binding.workspaceId || app.connection?.id != entry.connection.id { app.openWorkspace(entry) }
    }

    // MARK: Access

    func refreshAccess() async {
        guard let binding else { return }
        let entry = boundEntry
        let signerNow = signer
        var facts = FamilyFacts(signerNpub: signerNow, connection: app.connection, accessibleWorkspaces: workspaceFacts(for: binding))
        if let entry {
            let navigation = entry.navigation
            facts.channelsLoaded = navigation.loaded
            facts.channel = navigation.channel(binding.channelId)
            if let threadId = binding.threadId, let store = boundStore {
                facts.thread = try? await store.reader.thread(workspaceId: binding.workspaceId, id: threadId)
                facts.threadLoaded = true
            }
        }
        switch live {
        case .workspaceLost: facts.accessibleWorkspaces = []
        case .channelOrThreadLost: facts.thread = nil; facts.threadLoaded = true; facts.channel = nil; facts.channelsLoaded = true
        case .confirmed(let thread), .archived(let thread): facts.thread = thread; facts.threadLoaded = true; facts.threadConfirmedLive = true
        case .unreachable, nil: break
        }
        guard binding == self.binding, signerNow == signer else { return }
        let next = FamilyAccessEvaluator.evaluate(binding, facts)
        if next != access { access = next }
    }

    /// Cached listing of this account's workspaces. Empty means "not loaded yet" (a live check settles it), not "none".
    private func workspaceFacts(for binding: FamilyBinding) -> [WorkspaceRecord]? {
        let listed = app.workspaceEntries.filter { $0.connection.signerNpub == binding.signerNpub }.map(\.workspace)
        return listed.isEmpty ? nil : listed
    }

    // MARK: Live verification

    /// Asks Tower whether the bound workspace, channel and thread are still readable by this account. The answer replaces
    /// the cached view of the target until the next check; an unreachable Tower changes nothing.
    @discardableResult
    func verifyNow() async -> FamilyVerification? {
        if let verifyTask { return await verifyTask.value }
        guard let binding, binding.threadId != nil, app.canRead, let connection = app.connection,
              connection.id == binding.connectionId, let runtime = boundEntry?.runtime,
              let origin = try? TowerOrigin(connection.origin) else { return nil }
        isVerifying = true
        let task = Task { @MainActor [weak self] () -> FamilyVerification? in
            let api = TowerAPI(client: TowerClient(origin: origin, transport: runtime.sync.transport, signer: runtime.sync.identity))
            let result = await FamilyVerification.verify(binding, api: api)
            guard let self, binding == self.binding else { return result }
            if case .unreachable = result {} else { self.live = result }
            self.isVerifying = false
            self.verifyTask = nil
            await self.refreshAccess()
            return result
        }
        verifyTask = task
        return await task.value
    }

    /// Everything that must hold before a message is queued. Offline is allowed: the message waits in the durable outbox
    /// and Tower checks it again when it is sent. A target Tower says is gone, archived or forbidden is never written to.
    func prepareToSend() async -> Bool {
        guard binding?.threadId != nil else { return false }
        activateBoundWorkspace()
        let result = await verifyNow()
        switch result {
        case .confirmed: return true
        // Tower cannot be asked right now: the cached target must still look right, and Tower checks again when it sends.
        case .unreachable, nil: return access.canSend
        case .archived, .workspaceLost, .channelOrThreadLost: return false
        }
    }

    func api(for entry: EnabledWorkspaceEntry) -> TowerAPI? {
        guard let runtime = entry.runtime, let origin = try? TowerOrigin(entry.connection.origin) else { return nil }
        return TowerAPI(client: TowerClient(origin: origin, transport: runtime.sync.transport, signer: runtime.sync.identity))
    }

    // MARK: Conversation creation

    /// Finds the conversation an interrupted creation made (or notes that it never reached Tower).
    func resolvePendingCreation() async {
        guard let binding, let pending = binding.pendingCreation, let store = boundStore ?? app.store,
              app.selectedWorkspaceId == binding.workspaceId else { return }
        if let created = try? await store.reader.familyCreatedThread(workspaceId: binding.workspaceId, requestId: pending.requestId) {
            let title = String(MentionCodec.plain(created.body).prefix(60))
            await save(binding.withThread(created.threadId, title: title.isEmpty ? binding.channelName : title))
            return
        }
        // Not sent and not waiting any more (the person discarded it): there is no conversation to keep.
        if (try? await store.reader.outboxItem(id: pending.requestId)) == nil,
           let item = try? await store.reader.outbox(target: binding.creationTarget), item.isEmpty {
            await forgetChoice()
            notice = "The new family chat was not started. Choose it again to continue."
        }
    }

    // MARK: Routes

    /// A tapped notification. It can only show the bound conversation, which is always what the app shows.
    func handleTap(_ payload: PushPayload?) {
        guard let payload, let binding else { return }
        let destination: PushDestination? = payload.threadId.map { thread in
            payload.channelId.map { .thread(workspaceId: payload.workspaceId, channelId: $0, threadId: thread) }
                ?? .threadById(workspaceId: payload.workspaceId, threadId: thread)
        }
        guard let destination, FamilyRouting.resolve(destination, binding: binding) == .showConversation else { return }
        Task { await verifyNow() }
    }
}
