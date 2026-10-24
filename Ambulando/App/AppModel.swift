import AmbulandoCore
import Foundation
import Observation

/// App-wide state on the main actor. It owns no network or database work itself: it forwards
/// intents to `WorkspaceSync`/`SyncEngine` (sole network owner) and reads the store via `LiveQuery`.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case starting, failed(String), ready }

    private(set) var phase: Phase = .starting
    private(set) var identity: IdentityState = .none
    private(set) var connection: ConnectionRecord?
    private(set) var selectedWorkspaceId: String?
    private(set) var syncStatus = SyncSnapshot()
    var notice: String?

    @ObservationIgnored private(set) var store: LocalStore?
    @ObservationIgnored private(set) var sync: WorkspaceSync?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    let workspaces = LiveQuery<[WorkspaceRecord]>(initial: [])

    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AmbulandoNative", isDirectory: true)
    }

    /// Opens the database and identity off the main actor, then shows cached data immediately.
    func start() async {
        guard phase == .starting else { return }
        do {
            let directory = Self.dataDirectory
            let (store, identity) = try await Task.detached(priority: .userInitiated) {
                (try LocalStore(directory: directory.appendingPathComponent("Store", isDirectory: true)),
                 IdentityService(vaultURL: directory.appendingPathComponent("Identity/vault.json")))
            }.value
            let sync = WorkspaceSync(store: store, engine: SyncEngine(maxConcurrent: 3), identity: identity, transport: URLSessionTransport())
            self.store = store
            self.sync = sync
            self.identity = await identity.state
            let connections = try await store.reader.connections()
            let selected = try await store.reader.state("selected.connection")
            connection = connections.first { $0.id == selected } ?? connections.first
            if let connection {
                selectedWorkspaceId = try await store.reader.state("selected.workspace:\(connection.id)")
                observeWorkspaces(connection)
            }
            statusTask = Task { [weak self] in
                for await snapshot in await sync.engine.statusStream() { self?.syncStatus = snapshot }
            }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
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

    func disconnect() async {
        guard let sync, let store, let connection else { return }
        await sync.engine.cancelAll()
        do {
            try await store.writer.removeConnection(id: connection.id)
            try await store.writer.setState("selected.connection", nil)
            workspaces.stop()
            self.connection = nil
            selectedWorkspaceId = nil
        } catch { notice = error.localizedDescription }
    }

    func selectWorkspace(_ id: String) {
        guard let store, let connection, id != selectedWorkspaceId else { return }
        selectedWorkspaceId = id
        Task { try? await store.writer.setState("selected.workspace:\(connection.id)", id) }
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
}
