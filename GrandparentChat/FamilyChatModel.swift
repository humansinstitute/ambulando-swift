import AmbulandoCore
import Foundation
import Observation

/// Grandparent Chat's state on top of `AppModel` (identity, connection, workspace runtimes, outbox and sync stay the
/// shared Ambulando foundation). It adds one thing: the binding to a single existing conversation, and the rules that
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
    /// Bumped whenever the binding or account changes, so an answer to an earlier question is never applied to a later one.
    @ObservationIgnored private var verifyGeneration = 0

    init(app: AppModel) {
        self.app = app
        // Every outbox of every workspace asks this before each send attempt. Until it is installed, nothing is sent.
        app.outboxGuard?.install(FamilySendGuard.make { [weak self] signer in await self?.storedBinding(signer) })
    }

    /// Forgets any live answer and abandons a check in flight: it was about a binding that is gone.
    private func resetVerification() {
        verifyGeneration &+= 1
        verifyTask?.cancel(); verifyTask = nil
        isVerifying = false; live = nil
    }

    var signer: String? { app.identity.npub }
    var bindingLoaded: Bool { signer != nil && bindingLoadedFor == signer }

    /// The binding exactly as saved on disk (never the in-memory copy), for the send guard.
    private func storedBinding(_ signer: String) async -> FamilyBinding? {
        guard let store = app.catalogStore else { return nil }
        return try? await store.reader.familyBinding(signerNpub: signer)
    }

    // MARK: Binding

    /// Reads this account's binding once the identity and the app's store are ready.
    func loadBinding() async {
        guard let signer, let store = app.catalogStore, bindingLoadedFor != signer else { return }
        let stored = try? await store.reader.familyBinding(signerNpub: signer)
        guard signer == self.signer else { return }
        resetVerification()
        binding = stored
        bindingLoadedFor = signer
        await alignConnection()
        await refreshAccess()
    }

    func save(_ next: FamilyBinding) async {
        guard let store = app.catalogStore else { return }
        do {
            try await store.writer.setFamilyBinding(next)
            resetVerification()
            binding = next; bindingLoadedFor = next.signerNpub
            // The app keeps syncing only what it shows: the other workspaces of this account are switched off.
            restrictSync(to: next)
            await refreshAccess()
        } catch { notice = error.localizedDescription }
    }

    /// Forget which conversation is chosen. Cached messages, drafts and unsent messages are left where they are; an
    /// unsent message for the old conversation is never sent (the send guard refuses it) until that choice is made again.
    func forgetChoice() async {
        guard let binding, let store = app.catalogStore else { return }
        do {
            try await store.writer.clearFamilyBinding(signerNpub: binding.signerNpub)
            resetVerification()
            self.binding = nil; access = .checking
        } catch { notice = error.localizedDescription }
    }

    /// A reconnect to the same NStack as the same account may carry a new connection id; the binding follows it.
    private func alignConnection() async {
        guard var binding, let connection = app.connection, connection.origin == binding.origin,
              connection.signerNpub == binding.signerNpub, connection.id != binding.connectionId else { return }
        binding.connectionId = connection.id
        if let store = app.catalogStore, (try? await store.writer.setFamilyBinding(binding)) != nil { self.binding = binding }
    }

    private func restrictSync(to binding: FamilyBinding) {
        for entry in app.workspaceEntries where entry.connection.signerNpub == binding.signerNpub {
            let bound = isBound(entry, binding)
            if entry.enabled != bound { app.setWorkspaceEnabled(entry, bound) }
        }
    }

    /// The whole boundary: this NStack, this account, this space and application. Another NStack's space with the same id is not it.
    private func isBound(_ entry: EnabledWorkspaceEntry, _ binding: FamilyBinding) -> Bool {
        entry.connection.origin == binding.origin && entry.connection.signerNpub == binding.signerNpub
            && entry.workspace.id == binding.workspaceId && entry.workspace.appNpub == binding.appNpub
    }

    // MARK: Workspace runtime

    var boundEntry: EnabledWorkspaceEntry? {
        guard let binding else { return nil }
        return app.workspaceEntries.first { isBound($0, binding) }
    }

    /// The store of the bound workspace, once it is the selected one on the bound connection.
    var boundStore: LocalStore? {
        guard let binding, let entry = boundEntry, app.selectedWorkspaceId == binding.workspaceId,
              app.connection?.id == entry.connection.id, entry.runtime?.store === app.store else { return nil }
        return app.store
    }

    /// Makes the bound workspace the active one (a restored session may have another selected) and starts its sync.
    func activateBoundWorkspace() {
        guard let binding, let entry = boundEntry else { return }
        if !entry.enabled { app.setWorkspaceEnabled(entry, true) }
        if app.selectedWorkspaceId != binding.workspaceId || app.connection?.id != entry.connection.id { app.openWorkspace(entry) }
    }

    func api(for entry: EnabledWorkspaceEntry) -> TowerAPI? {
        guard let runtime = entry.runtime, let origin = try? TowerOrigin(entry.connection.origin) else { return nil }
        return TowerAPI(client: TowerClient(origin: origin, transport: runtime.sync.transport, signer: runtime.sync.identity))
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
            if let store = boundStore {
                facts.thread = try? await store.reader.thread(workspaceId: binding.workspaceId, id: binding.threadId)
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

    /// Cached listing of this account's spaces on the bound NStack. Empty means "not loaded yet" (a live check settles it).
    private func workspaceFacts(for binding: FamilyBinding) -> [WorkspaceRecord]? {
        let listed = app.workspaceEntries.filter { $0.connection.origin == binding.origin && $0.connection.signerNpub == binding.signerNpub }.map(\.workspace)
        return listed.isEmpty ? nil : listed
    }

    // MARK: Live verification

    /// Asks Tower whether the bound workspace, channel and conversation are still readable by this account. The answer
    /// replaces the cached view of the target until the next check; an unreachable Tower changes nothing.
    @discardableResult
    func verifyNow() async -> FamilyVerification? {
        if let verifyTask { return await verifyTask.value }
        guard let binding, app.canRead, let entry = boundEntry, let api = api(for: entry) else { return nil }
        let generation = verifyGeneration
        isVerifying = true
        let task = Task { @MainActor [weak self] () -> FamilyVerification? in
            let result = await FamilyVerification.verify(binding, api: api)
            // Only the check for the current binding may change state; a superseded one just returns its answer to its caller.
            guard let self, generation == self.verifyGeneration, binding == self.binding else { return result }
            if !result.isUnreachable { self.live = result }
            self.isVerifying = false
            self.verifyTask = nil
            await self.refreshAccess()
            return result
        }
        verifyTask = task
        return await task.value
    }

    /// Everything that must hold before a message is queued. Offline is allowed: the message waits in the durable outbox
    /// and is checked again at every send attempt. A target Tower says is gone, archived or forbidden is never written to.
    func prepareToSend() async -> Bool {
        guard binding != nil else { return false }
        activateBoundWorkspace()
        let result = await verifyNow()
        switch result {
        case .confirmed: return true
        // Tower cannot be asked right now: the cached target must still look right, and the send guard asks again.
        case .unreachable, nil: return access.canSend
        case .archived, .workspaceLost, .channelOrThreadLost: return false
        }
    }

    // MARK: Routes

    /// A tapped notification. It can only show the bound conversation, which is always what the app shows.
    func handleTap(_ payload: PushPayload?) {
        guard let payload, let binding, let thread = payload.threadId else { return }
        let destination: PushDestination = payload.channelId.map { .thread(workspaceId: payload.workspaceId, channelId: $0, threadId: thread) }
            ?? .threadById(workspaceId: payload.workspaceId, threadId: thread)
        guard FamilyRouting.resolve(destination, binding: binding) == .showConversation else { return }
        Task { await verifyNow() }
    }
}
