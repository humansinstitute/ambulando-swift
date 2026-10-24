import AmbulandoCore
import BackgroundTasks
import Foundation
import Network
import Observation
import UIKit

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

/// A record opened from the inbox, search or another tab. Like chat routes, it carries its workspace.
enum WorkRoute: Hashable {
    case task(workspaceId: String, taskId: String)
    case doc(workspaceId: String, docId: String)
    case file(workspaceId: String, fileId: String)
    case thread(workspaceId: String, channelId: String, threadId: String)
    case channel(workspaceId: String, channelId: String)

    var workspaceId: String {
        switch self {
        case .task(let w, _), .doc(let w, _), .file(let w, _), .thread(let w, _, _), .channel(let w, _): w
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
    @ObservationIgnored private(set) var writes: WriteSender?
    @ObservationIgnored private(set) var saver: DocumentSaver?
    /// Privacy-stripped images and files waiting to upload (Application Support, excluded from backup).
    @ObservationIgnored private(set) var staging: URL?
    /// Downloaded file and attachment content (Caches: the system may purge it; it is re-downloaded on demand).
    @ObservationIgnored private(set) var fileCache: FileCache?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// Foreground event stream for the selected workspace (stopped in the background and while locked).
    @ObservationIgnored private(set) var liveStream: LiveStream?
    /// System background session for presigned object-store transfers (nil in sample-data mode).
    @ObservationIgnored private(set) var transferBackend: URLSessionTransferBackend?
    @ObservationIgnored private(set) var transfers: BackgroundTransfers?
    @ObservationIgnored private var isActive = false
    /// The user's choice to keep a read-only credential for refresh while locked (persisted; revoked by manual lock).
    private(set) var backgroundRefreshEnabled = false
    /// The read-only credential is loaded right now (enabled and not revoked by a manual lock since the last unlock).
    private(set) var canReadWhileLocked = false
    private(set) var lastBackgroundReport: BackgroundRefreshReport?
    private(set) var backgroundScheduleError: String?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var restoringPath = false

    let workspaces = LiveQuery<[WorkspaceRecord]>(initial: [])

    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AmbulandoNative", isDirectory: true)
    }

    static let backgroundPreferenceKey = "background.refresh-enabled"

    /// Opens the database and identity off the main actor, then shows cached data immediately. Safe to call from the
    /// scene, a background refresh launch and background URLSession event delivery: the work runs once.
    func start() async {
        if let startTask { await startTask.value; return }
        let task = Task { await performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        guard phase == .starting else { return }
        do {
            let fixture = FixtureEnvironment.fromLaunchArguments()
            let directory = fixture?.directory ?? Self.dataDirectory
            let secrets = fixture?.secrets ?? KeychainVaultSecretStore()
            let background = fixture?.backgroundCredentials ?? KeychainBackgroundCredentialStore()
            let (store, identity) = try await Task.detached(priority: .userInitiated) {
                let store = try LocalStore(directory: directory.appendingPathComponent("Store", isDirectory: true))
                // Nothing is in flight at launch; an interrupted send is queued again (Tower replays by client_request_id),
                // and an interrupted write is reconciled before it is sent again.
                try await store.writer.resetInterruptedSends()
                try await store.writer.resetInterruptedWrites()
                let identity = IdentityService(vaultURL: directory.appendingPathComponent("Identity/vault.json"), secrets: secrets, background: background)
                // A background launch after process death can read only with the user-enabled credential.
                await identity.loadBackgroundRead()
                return (store, identity)
            }.value
            let transport: HTTPTransport = fixture?.tower ?? URLSessionTransport()
            let engine = SyncEngine(maxConcurrent: 3, reservedForeground: 1)
            if fixture == nil {
                // Recreated at every launch with the same identifier so iOS can deliver results of earlier transfers.
                let transferDirectory = directory.appendingPathComponent("Transfers", isDirectory: true)
                let backend = URLSessionTransferBackend(directory: transferDirectory)
                let transfers = BackgroundTransfers(directory: transferDirectory, backend: backend)
                await transfers.activate()
                await transfers.recover()
                transferBackend = backend
                self.transfers = transfers
            }
            let sync = WorkspaceSync(store: store, engine: engine, identity: identity, transport: transport, transfers: transfers)
            liveStream = LiveStream(sync: sync, transport: fixture?.events ?? URLSessionEventStreamTransport())
            self.store = store
            self.sync = sync
            let staging = directory.appendingPathComponent("Staging", isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var stagingURL = staging
            try? stagingURL.setResourceValues(excluded)
            self.staging = staging
            self.fileCache = FileCache(root: fixture.map { $0.directory.appendingPathComponent("FileCache", isDirectory: true) }
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AmbulandoFiles", isDirectory: true))
            self.outbox = OutboxSender(store: store, engine: engine, identity: identity, transport: transport, staging: staging, transfers: transfers)
            self.writes = WriteSender(store: store, engine: engine, identity: identity, transport: transport, staging: staging, transfers: transfers)
            self.saver = DocumentSaver(store: store, identity: identity, transport: transport)
            self.fixture = fixture
            if let fixture { try await fixture.prepare(identity: identity, sync: sync, store: store) }
            self.identity = await identity.state
            canReadWhileLocked = await identity.canReadWhileLocked
            backgroundRefreshEnabled = try await store.reader.state(Self.backgroundPreferenceKey) == "on"
            lastBackgroundReport = WorkspaceSync.decodeReport(try await store.reader.state(BackgroundRefreshReport.stateKey))
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
            if canRead { refresh(force: false); kickOutbox() }
            if isActive { startLive() }
            if let fixture { fixture.startLiveIfRequested(); await fixture.simulateBackgroundRefreshIfRequested(self) }
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
            // A manual lock revoked the read-only credential; it is provisioned again only if the user enabled it.
            if backgroundRefreshEnabled { await provisionBackgroundRead() }
            canReadWhileLocked = await sync.identity.canReadWhileLocked
            refresh(force: false)
            kickOutbox(force: true)   // messages written while locked are signed only now
            startLive()
        } catch { notice = error.localizedDescription }
    }

    func lock() async {
        guard let sync else { return }
        await liveStream?.stop()
        await sync.engine.cancelAll()
        await saver?.forgetAll()
        identity = await sync.identity.lock()   // also deletes the background credential
        canReadWhileLocked = false
    }

    /// Removes only this app's sealed identity and cancels sync. Cached workspace data stays until disconnect.
    func removeIdentity() async {
        guard let sync else { return }
        await liveStream?.stop()
        await sync.engine.cancelAll()
        do { identity = try await sync.identity.remove() } catch { notice = error.localizedDescription }
        canReadWhileLocked = false
        await setBackgroundPreference(false)
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
        await liveStream?.stop()
        await sync.engine.cancelAll()
        do {
            for workspace in workspaces.value { fileCache?.purge(workspaceId: workspace.id) }
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
        startLive()
    }

    /// Foreground refresh. `force` bypasses failure backoff (explicit pull-to-refresh).
    func refresh(force: Bool) {
        guard let sync, let connection, canRead else { return }
        Task {
            await sync.discover(connection, priority: force ? .visible : .background, force: force)
            if let workspace = selectedWorkspace {
                await sync.refreshWorkspace(connection, workspace, priority: .visible, force: force)
                // Pull to refresh also replays missed events (edits/deletions older than the last page).
                if force { await sync.catchUpEvents(connection, workspace, priority: .visible, force: true) }
            }
        }
    }

    /// Reads can be signed: unlocked, or the user-enabled read-only credential is loaded.
    var canRead: Bool { isUnlocked || canReadWhileLocked }

    // MARK: Lifecycle

    /// Scene became active: resume live updates and retry anything unsent.
    func sceneDidBecomeActive() {
        isActive = true
        refresh(force: false)
        kickOutbox()
        startLive()
    }

    /// Scene went to the background: close the stream (iOS would suspend it anyway), give unsent work the short
    /// finishing time iOS grants, and ask for the next opportunistic refresh.
    func sceneDidEnterBackground() {
        isActive = false
        Task { await liveStream?.stop() }
        scheduleBackgroundRefresh()
        finishPendingWorkInBackground()
    }

    private func startLive() {
        guard isActive, let liveStream, let connection, canRead else { return }
        Task {
            // At launch the observed workspace list may not have loaded yet; read the selection from the store.
            guard let workspace = await resolvedWorkspace(), isActive, connection.id == self.connection?.id else { return }
            await liveStream.start(connection, workspace)
        }
    }

    /// The selected workspace, from the observed list or (before it has loaded) from the store.
    func resolvedWorkspace() async -> WorkspaceRecord? {
        if let selectedWorkspace { return selectedWorkspace }
        guard let store, let connection, let stored = try? await store.reader.workspaces(connectionId: connection.id) else { return nil }
        return stored.first { $0.id == selectedWorkspaceId } ?? stored.first
    }

    /// Requests a `BGAppRefreshTask` no earlier than 15 minutes from now. iOS decides whether and when it runs.
    func scheduleBackgroundRefresh() {
        guard fixture == nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: AppDelegate.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request); backgroundScheduleError = nil }
        catch { backgroundScheduleError = (error as NSError).localizedDescription + " (\((error as NSError).domain) \((error as NSError).code))" }
    }

    /// Runs the shared sync pipeline once for a background window (also used by the sample-data simulation).
    func runBackgroundRefresh(budget: Duration) async -> BackgroundRefreshReport {
        guard let sync, let connection else {
            return BackgroundRefreshReport(result: .skippedNoConnection, startedAt: Date(), finishedAt: Date())
        }
        var targets = workspaces.value
        if targets.isEmpty, let stored = try? await store?.reader.workspaces(connectionId: connection.id) { targets = stored }
        if let selected = selectedWorkspaceId, let index = targets.firstIndex(where: { $0.id == selected }) { targets.insert(targets.remove(at: index), at: 0) }
        let report = await sync.backgroundRefresh(connection, workspaces: targets, outbox: outbox, writes: writes, budget: budget)
        lastBackgroundReport = report
        return report
    }

    /// Unsent messages and changes get the finishing time iOS allows after leaving the foreground (about 30 s).
    private func finishPendingWorkInBackground() {
        guard let sync, isUnlocked else { return }
        let application = UIApplication.shared
        var identifier = UIBackgroundTaskIdentifier.invalid
        let work = Task { @MainActor in
            kickOutbox()
            await sync.engine.waitUntilIdle()
            if identifier != .invalid { application.endBackgroundTask(identifier); identifier = .invalid }
        }
        identifier = application.beginBackgroundTask(withName: "ambulando.finish-sends") {
            work.cancel()
            Task { await sync.engine.cancelAll() }
            if identifier != .invalid { application.endBackgroundTask(identifier); identifier = .invalid }
        }
    }

    // MARK: Background refresh preference

    /// Turns "refresh while locked" on (requires the unlocked identity) or off.
    func setBackgroundRefresh(_ enabled: Bool) async {
        guard let sync else { return }
        if enabled {
            guard isUnlocked else { notice = IdentityError.locked.errorDescription; return }
            await setBackgroundPreference(true)
            await provisionBackgroundRead()
        } else {
            do { try await sync.identity.disableBackgroundRead() } catch { notice = error.localizedDescription }
            await setBackgroundPreference(false)
        }
        canReadWhileLocked = await sync.identity.canReadWhileLocked
    }

    private func setBackgroundPreference(_ on: Bool) async {
        backgroundRefreshEnabled = on
        try? await store?.writer.setState(Self.backgroundPreferenceKey, on ? "on" : nil)
    }

    private func provisionBackgroundRead() async {
        guard let sync, let connection, let origin = try? TowerOrigin(connection.origin) else { return }
        do { try await sync.identity.enableBackgroundRead(origin: origin, workspaceIds: workspaces.value.map(\.id)) }
        catch { notice = error.localizedDescription }
    }

    func liveStatus() async -> LiveStatus? {
        guard let sync, let workspace = await resolvedWorkspace() else { return nil }
        return await sync.live.feed(workspace.id).status
    }

    var lastSyncError: String? { syncStatus.errors.sorted { $0.key < $1.key }.first?.value }

    // MARK: Chat

    /// Resumes everything waiting to be sent: chat messages and other writes.
    func kickOutbox(force: Bool = false) {
        guard let outbox, let writes, let connection, case .unlocked = identity else { return }
        Task {
            await outbox.kick(connection, force: force)
            await writes.kick(connection, force: force)
        }
    }

    // MARK: Tasks, documents, files, inbox

    var isUnlocked: Bool { if case .unlocked = identity { true } else { false } }

    private func withWorkspace(_ workspace: WorkspaceRecord, _ body: @escaping @Sendable (WorkspaceSync, ConnectionRecord) async -> Void) {
        guard let sync, let connection, canRead, workspace.id == selectedWorkspace?.id else { return }
        Task { await body(sync, connection) }
    }

    func openTasks(_ workspace: WorkspaceRecord, scopeId: String?, force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshTasks(c, workspace, scopeId: scopeId, priority: .visible, force: force) }
    }

    func openTask(_ taskId: String, in workspace: WorkspaceRecord, force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshTask(c, workspace, taskId: taskId, force: force) }
    }

    func openDocs(_ workspace: WorkspaceRecord, scopeId: String?, force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshDocs(c, workspace, scopeId: scopeId, priority: .visible, force: force) }
    }

    func openDoc(_ docId: String, in workspace: WorkspaceRecord, force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshDoc(c, workspace, docId: docId, force: force) }
    }

    func openFiles(_ workspace: WorkspaceRecord, scopeId: String?, force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshFiles(c, workspace, scopeId: scopeId, priority: .visible, force: force) }
    }

    func openInbox(_ workspace: WorkspaceRecord, force: Bool = false) {
        withWorkspace(workspace) { sync, c in await sync.refreshInbox(c, workspace, priority: .visible, force: force) }
    }

    func download(_ file: FileRecord, in workspace: WorkspaceRecord) {
        guard let cache = fileCache else { return }
        withWorkspace(workspace) { sync, c in await sync.download(c, workspace, file: file, cache: cache) }
    }

    func downloadAttachment(_ objectId: String, in workspace: WorkspaceRecord) {
        guard let cache = fileCache else { return }
        withWorkspace(workspace) { sync, c in await sync.downloadAttachment(c, workspace, objectId: objectId, cache: cache) }
    }

    func refreshReactions(_ workspace: WorkspaceRecord, scope: String, messageIds: [String]) {
        withWorkspace(workspace) { sync, c in await sync.refreshReactions(c, workspace, scope: scope, messageIds: messageIds) }
    }

    /// Queues a write for the selected workspace. Returns false when there is no connection to bind it to.
    @discardableResult
    func submit(_ intent: WriteIntent, in workspace: WorkspaceRecord) -> Bool {
        guard let writes, let connection, workspace.id == selectedWorkspace?.id else { return false }
        Task {
            do { try await writes.submit(intent, connection: connection, workspace: workspace) }
            catch { notice = error.localizedDescription }
        }
        return true
    }

    /// Opening a task, document or thread marks it read when Tower reports it unread.
    func markViewed(_ type: ViewStateRecord.ResourceType, _ id: String, in workspace: WorkspaceRecord) {
        guard let store else { return }
        Task {
            guard let state = try? await store.reader.viewState(workspaceId: workspace.id, type: type, id: id), state.unread || state.needsAttention else { return }
            markRead([state], in: workspace)
        }
    }

    /// Marks records read: on this iPhone at once, and on Tower through the durable write queue.
    func markRead(_ resources: [ViewStateRecord], in workspace: WorkspaceRecord) {
        let unread = resources.filter { $0.unread || $0.needsAttention }
        guard !unread.isEmpty, let store, let writes, let connection, workspace.id == selectedWorkspace?.id else { return }
        Task {
            try? await store.writer.markViewedLocally(workspaceId: workspace.id, unread.map { ($0.resourceType, $0.resourceId, $0.activityVersion) })
            for chunk in stride(from: 0, to: unread.count, by: 500).map({ Array(unread[$0..<min($0 + 500, unread.count)]) }) {
                let list: [[String: any Sendable]] = chunk.map { ["resource_type": $0.resourceType.rawValue, "resource_id": $0.resourceId,
                                                                   "viewed_activity_version": $0.activityVersion] }
                _ = try? await writes.submit(WriteIntent(kind: .viewMark, targetId: chunk.count == 1 ? chunk[0].resourceId : nil, payload: ["resources": list]),
                                             connection: connection, workspace: workspace)
            }
        }
    }

    /// Screen-driven catch-up for the open channel (visible priority, ahead of background work).
    func openChannel(_ channelId: String, in workspace: WorkspaceRecord, force: Bool = false) {
        guard let sync, let connection, canRead, workspace.id == selectedWorkspace?.id else { return }
        Task {
            await sync.live.feed(workspace.id).setVisibleChannel(channelId)
            await sync.catchUpChannel(connection, workspace, channelId: channelId, priority: .visible, force: force)
        }
    }

    func openThread(_ threadId: String, channelId: String, in workspace: WorkspaceRecord) {
        guard let sync, let connection, canRead, workspace.id == selectedWorkspace?.id else { return }
        Task { await sync.refreshThread(connection, workspace, channelId: channelId, threadId: threadId, priority: .user) }
    }

    func refreshDirectory(_ workspace: WorkspaceRecord) {
        guard let sync, let connection, canRead else { return }
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
