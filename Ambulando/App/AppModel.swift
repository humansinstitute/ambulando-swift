import AmbulandoCore
import Foundation
import Network
import Observation

/// A place in chat navigation. Routes carry their workspace so a restored or stale path can never open a
/// conversation under a different workspace.
enum ChatRoute: Hashable, Codable {
    case channel(workspaceId: String, channelId: String)
    case thread(workspaceId: String, channelId: String, threadId: String)

    var workspaceId: String {
        switch self {
        case .channel(let w, _), .thread(let w, _, _): w
        }
    }
}

/// App-wide state on the main actor. It owns no network or database work itself: it forwards
/// intents to `WorkspaceSync`/`OutboxSender` via `SyncEngine` (sole network owner) and reads the store via `LiveQuery`.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case starting, failed(String), ready }

    private(set) var phase: Phase = .starting
    private(set) var identity: IdentityState = .none
    private(set) var connection: ConnectionRecord?
    private(set) var selectedWorkspaceId: String?
    private(set) var syncStatus = SyncSnapshot()
    /// Navigation inside the Chat tab for the selected workspace; persisted per connection and workspace.
    var chatPath: [ChatRoute] = [] { didSet { if chatPath != oldValue { persistChatPath() } } }
    var notice: String?
    /// Set when the app runs on deterministic local sample data (UI automation); never a live Tower.
    private(set) var fixture: FixtureEnvironment?

    @ObservationIgnored private(set) var store: LocalStore?
    @ObservationIgnored private(set) var sync: WorkspaceSync?
    @ObservationIgnored private(set) var outbox: OutboxSender?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var restoringPath = false

    let workspaces = LiveQuery<[WorkspaceRecord]>(initial: [])

    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AmbulandoNative", isDirectory: true)
    }

    /// Opens the database and identity off the main actor, then shows cached data immediately.
    func start() async {
        guard phase == .starting else { return }
        do {
            let fixture = FixtureEnvironment.fromLaunchArguments()
            let directory = fixture?.directory ?? Self.dataDirectory
            let secrets = fixture?.secrets ?? KeychainVaultSecretStore()
            let (store, identity) = try await Task.detached(priority: .userInitiated) {
                let store = try LocalStore(directory: directory.appendingPathComponent("Store", isDirectory: true))
                // Nothing is in flight at launch; an interrupted send is queued again (Tower replays by client_request_id).
                try await store.writer.resetInterruptedSends()
                return (store, IdentityService(vaultURL: directory.appendingPathComponent("Identity/vault.json"), secrets: secrets))
            }.value
            let transport: HTTPTransport = fixture?.tower ?? URLSessionTransport()
            let engine = SyncEngine(maxConcurrent: 3, reservedForeground: 1)
            let sync = WorkspaceSync(store: store, engine: engine, identity: identity, transport: transport)
            self.store = store
            self.sync = sync
            self.outbox = OutboxSender(store: store, engine: engine, identity: identity, transport: transport)
            self.fixture = fixture
            if let fixture { try await fixture.prepare(identity: identity, sync: sync, store: store) }
            self.identity = await identity.state
            let connections = try await store.reader.connections()
            let selected = try await store.reader.state("selected.connection")
            connection = connections.first { $0.id == selected } ?? connections.first
            if let connection {
                selectedWorkspaceId = try await store.reader.state("selected.workspace:\(connection.id)")
                observeWorkspaces(connection)
                await restoreChatPath()
            }
            statusTask = Task { [weak self] in
                for await snapshot in await engine.statusStream() { self?.syncStatus = snapshot }
            }
            watchNetwork()
            phase = .ready
            if case .unlocked = self.identity { refresh(force: false); kickOutbox() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Network return is a retry trigger for unsent messages (the outbox also retries on its own backoff).
    private func watchNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.kickOutbox(force: true) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "studio.otherstuff.ambulando.native.path", qos: .utility))
    }

    private func observeWorkspaces(_ connection: ConnectionRecord) {
        guard let store else { return }
        let id = connection.id
        workspaces.start(store: store, matches: { $0.table == .workspaces }) { try await store.reader.workspaces(connectionId: id) }
    }

    var selectedWorkspace: WorkspaceRecord? {
        workspaces.value.first { $0.id == selectedWorkspaceId } ?? workspaces.value.first
    }

    // MARK: Identity

    func importIdentity(nsec: String, pin: String) async {
        guard let sync else { return }
        do { identity = try await sync.identity.importIdentity(nsec: nsec, pin: pin); notice = nil }
        catch { notice = error.localizedDescription }
    }

    func unlock(pin: String) async {
        guard let sync else { return }
        do {
            identity = try await sync.identity.unlock(pin: pin)
            notice = nil
            refresh(force: false)
            kickOutbox(force: true)   // messages written while locked are signed only now
        } catch { notice = error.localizedDescription }
    }

    func lock() async {
        guard let sync else { return }
        await sync.engine.cancelAll()
        identity = await sync.identity.lock()
    }

    /// Removes only this app's sealed identity and cancels sync. Cached workspace data stays until disconnect.
    func removeIdentity() async {
        guard let sync else { return }
        await sync.engine.cancelAll()
        do { identity = try await sync.identity.remove() } catch { notice = error.localizedDescription }
    }

    // MARK: Connection

    func checkDescriptor(_ origin: String) async throws -> NStackDescriptor {
        guard let sync else { throw TowerError.unsafeOrigin }
        return try await sync.checkDescriptor(origin: try TowerOrigin(origin))
    }

    func connect(_ origin: String) async {
        guard let sync, let store else { return }
        do {
            let record = try await sync.connect(origin: try TowerOrigin(origin))
            try await store.writer.setState("selected.connection", record.id)
            connection = record
            observeWorkspaces(record)
            await sync.discover(record, priority: .visible, force: true)
            notice = nil
        } catch { notice = error.localizedDescription }
    }

    func unsentCount() async -> Int {
        guard let store, let connection else { return 0 }
        return (try? await store.reader.outboxCount(connectionId: connection.id)) ?? 0
    }

    func disconnect() async {
        guard let sync, let store, let connection else { return }
        await sync.engine.cancelAll()
        do {
            try await store.writer.removeConnection(id: connection.id)
            try await store.writer.setState("selected.connection", nil)
            workspaces.stop()
            self.connection = nil
            selectedWorkspaceId = nil
            restoringPath = true; chatPath = []; restoringPath = false
        } catch { notice = error.localizedDescription }
    }

    func selectWorkspace(_ id: String) {
        guard let store, let connection, id != selectedWorkspaceId else { return }
        selectedWorkspaceId = id
        restoringPath = true; chatPath = []; restoringPath = false
        Task {
            try? await store.writer.setState("selected.workspace:\(connection.id)", id)
            await restoreChatPath()
        }
        if let workspace = workspaces.value.first(where: { $0.id == id }), let sync {
            Task { await sync.refreshWorkspace(connection, workspace, priority: .visible) }
        }
    }

    /// Foreground refresh. `force` bypasses failure backoff (explicit pull-to-refresh).
    func refresh(force: Bool) {
        guard let sync, let connection, case .unlocked = identity else { return }
        Task {
            await sync.discover(connection, priority: force ? .visible : .background, force: force)
            if let workspace = selectedWorkspace { await sync.refreshWorkspace(connection, workspace, priority: .visible, force: force) }
        }
    }

    var lastSyncError: String? { syncStatus.errors.sorted { $0.key < $1.key }.first?.value }

    // MARK: Chat

    func kickOutbox(force: Bool = false) {
        guard let outbox, let connection, case .unlocked = identity else { return }
        Task { await outbox.kick(connection, force: force) }
    }

    /// Screen-driven catch-up for the open channel (visible priority, ahead of background work).
    func openChannel(_ channelId: String, in workspace: WorkspaceRecord, force: Bool = false) {
        guard let sync, let connection, case .unlocked = identity, workspace.id == selectedWorkspace?.id else { return }
        Task { await sync.catchUpChannel(connection, workspace, channelId: channelId, priority: .visible, force: force) }
    }

    func openThread(_ threadId: String, channelId: String, in workspace: WorkspaceRecord) {
        guard let sync, let connection, case .unlocked = identity, workspace.id == selectedWorkspace?.id else { return }
        Task { await sync.refreshThread(connection, workspace, channelId: channelId, threadId: threadId, priority: .user) }
    }

    func refreshDirectory(_ workspace: WorkspaceRecord) {
        guard let sync, let connection, case .unlocked = identity else { return }
        Task { await sync.refreshDirectory(connection, workspace, priority: .visible) }
    }

    func syncError(forKey key: String) -> String? { syncStatus.errors[key] }
    func isSyncing(_ key: String) -> Bool { syncStatus.running.contains(key) || syncStatus.queued.contains(key) }

    private var chatPathKey: String? {
        guard let connection, let workspace = selectedWorkspaceId ?? selectedWorkspace?.id else { return nil }
        return "chat-path:\(connection.id):\(workspace)"
    }

    private func persistChatPath() {
        guard !restoringPath, let store, let key = chatPathKey else { return }
        let encoded = (try? JSONEncoder().encode(chatPath)).map { String(decoding: $0, as: UTF8.self) }
        Task { try? await store.writer.setState(key, encoded) }
    }

    private func restoreChatPath() async {
        guard let store, let key = chatPathKey else { return }
        let stored = (try? await store.reader.state(key)).flatMap { $0 }
        let routes = stored.flatMap { try? JSONDecoder().decode([ChatRoute].self, from: Data($0.utf8)) } ?? []
        guard key == chatPathKey else { return }   // the workspace changed while reading
        let workspace = selectedWorkspaceId ?? selectedWorkspace?.id
        restoringPath = true
        chatPath = routes.filter { $0.workspaceId == workspace }
        restoringPath = false
    }
}
