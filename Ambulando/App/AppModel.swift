import AmbulandoCore
#if os(iOS)
import BackgroundTasks
#endif
import Foundation
import Network
import Observation
import os
#if os(iOS)
import UIKit
#endif

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
    /// A conversation known only by id (a pin or a canvas naplet); its channel is looked up or fetched first.
    case threadById(workspaceId: String, threadId: String)
    case canvas(workspaceId: String, canvasId: String)
    /// An Excalidraw board on a canvas, full screen.
    case board(workspaceId: String, canvasId: String, napletId: String)
    case contextComponent(workspaceId: String, scopeId: String, componentId: String)
    /// Publisher-owned web content in a labelled view.
    case webContent(workspaceId: String, source: WebContentSource)

    var workspaceId: String {
        switch self {
        case .task(let w, _), .doc(let w, _), .file(let w, _), .thread(let w, _, _), .channel(let w, _), .threadById(let w, _), .canvas(let w, _),
             .board(let w, _, _), .contextComponent(let w, _, _), .webContent(let w, _): w
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
    private(set) var identity: IdentityState = .none {
        didSet {
            guard identity != oldValue else { return }
            // window.nostr follows the identity: locking cancels and refuses every request; removing it forgets sites.
            browser.setLocked(!isUnlocked)
            if identity == .none, oldValue != .none { browser.reset() }
        }
    }
    /// The in-app browser (full-screen tabs with `window.nostr`); see `BrowserModel`.
    @ObservationIgnored let browser = BrowserModel()
    /// Why an existing identity cannot be opened (sealed while the iPhone is locked, or a damaged file).
    private(set) var vaultProblem: VaultReadProblem?
    private(set) var connection: ConnectionRecord?
    private(set) var selectedWorkspaceId: String?
    private(set) var syncStatus = SyncSnapshot()
    /// Navigation inside the Chat tab for the selected workspace; persisted per connection and workspace.
    var chatPath: [ChatRoute] = [] {
        didSet {
            guard chatPath != oldValue else { return }
            if !restoringPath { pathEdits &+= 1 }
            persistChatPath()
        }
    }
    /// Bumped by every context or Chat path change that is not a restore, so a restore that started earlier (a slow
    /// read, a workspace list stored late) never overwrites what the user opened in the meantime.
    @ObservationIgnored private var contextEdits: UInt64 = 0
    @ObservationIgnored private var pathEdits: UInt64 = 0
    /// Context restores applied since launch. Sample-data mode shows it so UI tests can check launch restores once.
    private(set) var contextRestores = 0
    /// The shared Workspace → Scope → Channel context chosen in the sidebar. Chat, tasks, documents and files read and
    /// write inside it; persisted per connection and workspace (see `WorkContext`).
    private(set) var context: WorkContext = .home
    /// The sidebar drawer (workspace, scopes and channels), reachable from every mode.
    var sidebarOpen = false
    /// Navigation inside each section other than Chat (Chat keeps `chatPath`). Kept while the app runs, so switching
    /// sections returns to the same screen; a workspace switch or a new sidebar choice starts the context-bound ones over.
    var deckPath: [WorkRoute] = []
    var tasksPath: [WorkRoute] = []
    var docsPath: [WorkRoute] = []
    var filesPath: [WorkRoute] = []
    var agentsPath: [WorkRoute] = []
    var contextPath: [WorkRoute] = []
    var toolboxPath: [WorkRoute] = []
    /// The member's role and permissions in the selected workspace (`GET /me`), for showing management controls.
    var membership: WorkspaceMembership?
    @ObservationIgnored var membershipWorkspaceId: String?
    @ObservationIgnored private(set) var manager: ScopeChannelManager?
    /// The viewer's personal pins in the selected workspace (sidebar "Pinned").
    let pins = LiveQuery<PinsSnapshot>(initial: PinsSnapshot())
    /// Viewer-local board positions by canvas, so returning to a board keeps where it was (never written to Tower).
    @ObservationIgnored var canvasViewports: [String: CanvasViewport] = [:]
    /// Excalidraw board sessions (drafts, saves) shared by the inline and full-screen editors.
    @ObservationIgnored let boards = BoardRegistry()
    /// The current section (bottom bar). Opening a record from Search or a mention may switch it.
    var mode: AppMode = .chat {
        didSet { if mode != oldValue, lockedView != mode { lockedView = nil } }
    }
    /// The section kept on sidebar choices (in memory, cleared when another section opens, as on the web).
    var lockedView: AppMode?
    /// Bumped when a sidebar choice opens Deck; Deck then shows its Inbox card.
    var deckInboxRequests = 0
    var notice: String?
    /// Set when the app runs on deterministic local sample data (UI automation); never a live Tower.
    private(set) var fixture: FixtureEnvironment?

    /// Public Nostr profiles (names and avatars) for the people of the selected workspace; see `AppModel+People`.
    @ObservationIgnored var profiles: ProfileSync?
    @ObservationIgnored var avatars: AvatarCenter?
    /// Settings › Nostr profiles: public relays and picture hosts may be contacted (on by default, as on the web).
    var publicProfilesEnabled = true
    /// The signed-in person as shown in the profile button and Settings (from the store; nil before it is read).
    let me = LiveQuery<AccountProfile?>(initial: nil)
    /// Members and agents of the selected workspace; a change schedules a profile refresh for them.
    @ObservationIgnored let profilePeople = LiveQuery<[String]>(initial: [])
    @ObservationIgnored var lastProfilePeople: [String]?

    @ObservationIgnored private(set) var store: LocalStore?
    @ObservationIgnored private(set) var sync: WorkspaceSync?
    @ObservationIgnored private(set) var outbox: OutboxSender?
    @ObservationIgnored private(set) var writes: WriteSender?
    @ObservationIgnored private(set) var saver: DocumentSaver?
    /// Images and files pasted into chat composers, uploading to workspace storage (see `ComposerUploads`).
    private(set) var uploads: ComposerUploads?
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
    /// The last revocation could not delete the Keychain item (it stays blocked by the revocation marker).
    private(set) var backgroundRevocationIncomplete = false
    private(set) var lastBackgroundReport: BackgroundRefreshReport?
    private(set) var backgroundScheduleError: String?
    /// First frame → stored channel list on screen, measured once per launch (budget: ≤ 400 ms; signposted).
    private(set) var launchToCachedListMs: Double?
    @ObservationIgnored private var firstFrame: ContinuousClock.Instant?
    @ObservationIgnored private var launchInterval: OSSignpostIntervalState?
    @ObservationIgnored private static let signposter = OSSignposter(subsystem: "studio.otherstuff.ambulando.native", category: "launch")

    func markFirstFrame() {
        guard firstFrame == nil else { return }
        firstFrame = .now
        launchInterval = Self.signposter.beginInterval("launch-to-cached-list")
    }

    func markCachedListShown() {
        guard launchToCachedListMs == nil, let firstFrame else { return }
        let ms = (ContinuousClock.now - firstFrame).milliseconds
        launchToCachedListMs = ms
        if let launchInterval { Self.signposter.endInterval("launch-to-cached-list", launchInterval) }
        // Sample-data mode keeps a short history so device runs can be read back without UI automation.
        if fixture != nil, let store {
            Task {
                let previous = (try? await store.reader.state("fixture.launch-ms")) ?? nil
                let history = ((previous ?? "").split(separator: ",").suffix(9).map(String.init) + [String(format: "%.0f", ms)]).joined(separator: ",")
                try? await store.writer.setState("fixture.launch-ms", history)
            }
        }
    }
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var restoringPath = false

    let workspaces = LiveQuery<[WorkspaceRecord]>(initial: [])

    static var dataDirectory: URL {
        ProductionStorage.dataDirectory(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
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

    /// A start that failed (for example the store could not be opened while the iPhone was locked) is tried again
    /// when the app becomes active or protected data becomes available. Nothing is deleted or recreated to get past it.
    private func retryStartIfFailed() async {
        // Only a failure to open local storage is retried; later steps may already have started system services.
        guard case .failed = phase, store == nil, transfers == nil else { return }
        phase = .starting
        startTask = nil
        await start()
    }

    /// Reads the identity again. A launch while the iPhone was locked could not read the sealed vault or the
    /// trusted-device session; once it is unlocked both are available again and no PIN or import is needed.
    func refreshIdentityAvailability() async {
        guard let sync else { return }
        let state = await sync.identity.refreshAvailability()
        vaultProblem = await sync.identity.vaultProblem
        guard state != identity else { return }
        identity = state
        canReadWhileLocked = await sync.identity.canReadWhileLocked
        if case .unlocked = state {
            refresh(force: false)
            kickOutbox(force: true)
            startLive()
        }
    }

    private func performStart() async {
        guard phase == .starting else { return }
        do {
            let fixture = FixtureEnvironment.fromLaunchArguments()
            let directory = fixture?.directory ?? Self.dataDirectory
            let secrets = fixture?.secrets ?? KeychainVaultSecretStore(service: KeychainServices.named(ProductionStorage.vaultSecretService))
            let background = fixture?.backgroundCredentials
                ?? KeychainBackgroundCredentialStore(service: KeychainServices.named(ProductionStorage.backgroundReadService))
            let session = fixture?.sessionKeys ?? KeychainSessionKeyStore(service: KeychainServices.named(ProductionStorage.sessionService))
            let (store, identity) = try await Task.detached(priority: .userInitiated) {
                let store = try LocalStore(directory: ProductionStorage.storeDirectory(directory))
                // Nothing is in flight at launch; an interrupted send is queued again (Tower replays by client_request_id),
                // and an interrupted write is reconciled before it is sent again.
                try await store.writer.resetInterruptedSends()
                try await store.writer.resetInterruptedWrites()
                let identity = IdentityService(vaultURL: ProductionStorage.vaultURL(directory), secrets: secrets,
                                               background: background, session: session)
                // Trusted-device session: stays unlocked across relaunch until Lock now / remove / disconnect. The
                // Keychain item opens only while the iPhone is unlocked, so a background launch on a locked device stays
                // locked and can read only with the user-enabled background credential.
                await identity.resumeSession()
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
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(ProductionStorage.fileCacheDirectoryName, isDirectory: true))
            self.outbox = OutboxSender(store: store, engine: engine, identity: identity, transport: transport, staging: staging, transfers: transfers)
            self.writes = WriteSender(store: store, engine: engine, identity: identity, transport: transport, staging: staging, transfers: transfers)
            self.saver = DocumentSaver(store: store, identity: identity, transport: transport)
            let pasted = ComposerUploadTransfer(engine: engine, identity: identity, transport: transport, transfers: transfers)
            self.uploads = ComposerUploads(store: store, staging: staging) { [weak self] job in
                // Signed by the connection the paste was made in; a different (or no) connection does not upload it.
                guard let connection = await MainActor.run(body: { self?.connection }) else { throw ComposerUploadError.otherConnection }
                return try await pasted.upload(job, connection: connection)
            }
            self.manager = ScopeChannelManager(store: store, identity: identity, transport: transport)
            // Debug test runs on a production store (the upgrade check) pass -AmbulandoNoPublicNetwork: no relay or
            // picture host is contacted.
            #if DEBUG
            let offlineProfiles = ProcessInfo.processInfo.arguments.contains("-AmbulandoNoPublicNetwork")
            #else
            let offlineProfiles = false
            #endif
            let publicProfiles: ProfileSource = offlineProfiles ? UnreachableProfiles() : RelayProfileSource()
            let publicPictures: AvatarTransport = offlineProfiles ? UnreachableProfiles() : URLSessionAvatarTransport()
            let profileSource = fixture?.profileSource ?? publicProfiles
            let avatarTransport = fixture?.avatarTransport ?? publicPictures
            self.profiles = ProfileSync(store: store, engine: engine, source: profileSource)
            let avatarRoot = fixture.map { $0.directory.appendingPathComponent("Avatars", isDirectory: true) }
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(ProductionStorage.avatarCacheDirectoryName, isDirectory: true)
            let avatarStore = AvatarStore(directory: avatarRoot, transport: avatarTransport)
            self.avatars = AvatarCenter(store: avatarStore)
            self.publicProfilesEnabled = await ProfileSync.isEnabled(store)
            if !publicProfilesEnabled { await avatarStore.setEnabled(false) }
            self.fixture = fixture
            if let fixture { try await fixture.prepare(identity: identity, sync: sync, store: store) }
            self.identity = await identity.state
            await browser.configure(store: store, signer: { [weak self] in await MainActor.run { self?.sync?.identity } }, locked: !isUnlocked)
            browser.samplePage = fixture?.browserSample
            vaultProblem = await identity.vaultProblem
            canReadWhileLocked = await identity.canReadWhileLocked
            backgroundRefreshEnabled = try await store.reader.state(Self.backgroundPreferenceKey) == "on"
            lastBackgroundReport = WorkspaceSync.decodeReport(try await store.reader.state(BackgroundRefreshReport.stateKey))
            let connections = try await store.reader.connections()
            // Agents and Context are optional sections, off by default as on the web. An install upgraded from builds
            // 7–8 had both in its sidebar, so they stay visible there unless the user turns them off.
            // (Sample-data mode leaves the web default.)
            for key in [AppMode.agentsPreference, AppMode.contextPreference] where fixture == nil && UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(!connections.isEmpty, forKey: key)
            }
            let selected = try await store.reader.state("selected.connection")
            connection = connections.first { $0.id == selected } ?? connections.first
            if let connection {
                // The stored choice exists only if the switcher was used; otherwise (or if Tower no longer lists it) the
                // first saved workspace is shown, so the sidebar reads its scopes straight away.
                selectedWorkspaceId = WorkspaceSelection.effective(
                    persisted: try await store.reader.state("selected.workspace:\(connection.id)"),
                    listed: try await store.reader.workspaces(connectionId: connection.id),
                    listComplete: try await store.reader.state(WorkspaceSelection.listedKey(connection.id)) != nil)
                await restoreContext()
                await restoreChatPath()
                // Observed only after the restore has started the sidebar, so the first list (usually the same one)
                // is a no-op instead of a second, unawaited restore that could land after the user opened a channel.
                observeWorkspaces(connection)
            }
            statusTask = Task { [weak self] in
                // Sync status changes on every job start/finish; screens get at most 4 updates a second, and only
                // real changes (Observation would otherwise invalidate every reader on each assignment).
                for await snapshot in await engine.statusStream() {
                    guard let self else { return }
                    if snapshot != self.syncStatus { self.syncStatus = snapshot }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            watchNetwork()
            observeProtectedData()
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
        workspaceListGeneration &+= 1
        let generation = workspaceListGeneration
        workspaces.onLoad = { [weak self] listed in self?.workspacesDidLoad(listed, connectionId: id, generation: generation) }
        workspaces.start(store: store, matches: { $0.table == .workspaces }) { try await store.reader.workspaces(connectionId: id) }
    }

    /// Bumped when the observed workspace list is replaced or stopped, so a late list for an earlier connection is ignored.
    @ObservationIgnored private var workspaceListGeneration: UInt64 = 0

    /// The workspace list was stored (first discovery after connecting, every refresh, a workspace removed or access
    /// lost). Keeps a listed workspace shown and its sidebar reading; the same list stored again changes nothing.
    private func workspacesDidLoad(_ listed: [WorkspaceRecord], connectionId: String, generation: UInt64) {
        guard let store, connection?.id == connectionId, generation == workspaceListGeneration else { return }
        guard listed.isEmpty else {
            applyWorkspaceChange(listed: listed, listComplete: true)
            return
        }
        // Empty: "not loaded yet" (keep showing saved data) unless Tower's answer was stored and really was empty.
        Task {
            let complete = ((try? await store.reader.state(WorkspaceSelection.listedKey(connectionId))) ?? nil) != nil
            guard connection?.id == connectionId, generation == workspaceListGeneration, workspaces.value.isEmpty else { return }
            applyWorkspaceChange(listed: [], listComplete: complete)
        }
    }

    private func applyWorkspaceChange(listed: [WorkspaceRecord], listComplete: Bool) {
        guard let connection else { return }
        switch WorkspaceSelection.change(selected: selectedWorkspaceId, navigationFor: navigationWorkspaceId, listed: listed, listComplete: listComplete) {
        case .none:
            return
        case .show(let id):
            showWorkspace(id, persist: false)
        case .startNavigation(let id):
            navigationWorkspaceId = id
            Task {
                await restoreContext()
                await restoreChatPath()
            }
            if let sync, canRead, let workspace = listed.first(where: { $0.id == id }) {
                Task { await sync.refreshWorkspace(connection, workspace, priority: .visible) }
            }
            startLive()
        case .clear:
            // Tower lists no workspace for this identity any more; nothing read for the old one stays on screen.
            selectedWorkspaceId = nil
            navigationWorkspaceId = nil
            navigation.stop()
            pins.stop()
            context = .home
            restoringPath = true; chatPath = []; restoringPath = false
            resetSectionPaths()
            membership = nil; membershipWorkspaceId = nil
            canvasViewports = [:]
            Task { await liveStream?.stop() }
        }
    }

    var selectedWorkspace: WorkspaceRecord? {
        workspaces.value.first { $0.id == selectedWorkspaceId } ?? workspaces.value.first
    }

    // MARK: Identity

    func importIdentity(nsec: String, pin: String) async {
        guard let sync else { return }
        // With a Tower connection on this iPhone only that connection's identity can be imported (never a replacement).
        do { identity = try await sync.identity.importIdentity(nsec: nsec, pin: pin, requiredNpub: connection?.signerNpub); notice = nil }
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
        identity = await sync.identity.lock()   // also revokes the background credential (fail-closed marker + Keychain delete)
        canReadWhileLocked = await sync.identity.canReadWhileLocked
        backgroundRevocationIncomplete = await sync.identity.revocationIncomplete
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
        browser.reset()
        await liveStream?.stop()
        await sync.engine.cancelAll()
        // Disconnecting ends the trusted-device session; the next launch asks for the PIN.
        do { try await sync.identity.endSession() } catch { notice = error.localizedDescription }
        do {
            for workspace in workspaces.value { fileCache?.purge(workspaceId: workspace.id) }
            try await store.writer.removeConnection(id: connection.id)
            try await store.writer.setState("selected.connection", nil)
            workspaces.stop()
            workspaceListGeneration &+= 1
            self.connection = nil
            selectedWorkspaceId = nil
            context = .home
            navigation.stop()
            navigationWorkspaceId = nil
            pins.stop()
            stopPeople()
            // Profile rows went with the connection; their pictures go too.
            await avatars?.clear()
            resetSectionPaths()
            membership = nil; membershipWorkspaceId = nil
            restoringPath = true; chatPath = []; restoringPath = false
        } catch { notice = error.localizedDescription }
    }

    /// The user chose a workspace in the switcher; the choice is remembered for this connection.
    func selectWorkspace(_ id: String) {
        guard let store, let connection else { return }
        guard id != selectedWorkspaceId else {
            // Already shown (perhaps as the default): choosing it makes it the remembered choice.
            Task { try? await store.writer.setState("selected.workspace:\(connection.id)", id) }
            return
        }
        showWorkspace(id, persist: true)
    }

    /// Switches every mode to `id`, starting at Home. `persist` is false for a default the user did not choose.
    private func showWorkspace(_ id: String, persist: Bool) {
        guard let store, let connection else { return }
        selectedWorkspaceId = id
        restoringPath = true; chatPath = []; restoringPath = false
        context = .home
        navigation.stop()
        pins.stop()
        stopPeople()
        navigationWorkspaceId = id
        canvasViewports = [:]
        resetSectionPaths()
        membership = nil; membershipWorkspaceId = nil
        Task {
            if persist { try? await store.writer.setState("selected.workspace:\(connection.id)", id) }
            await restoreContext()
            await restoreChatPath()
        }
        if let workspace = workspaces.value.first(where: { $0.id == id }), let sync, canRead {
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
                await sync.refreshPins(connection, workspace, priority: .background, force: force)
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
        Task {
            await retryStartIfFailed()
            await refreshIdentityAvailability()
            refresh(force: false)
            kickOutbox()
            startLive()
        }
    }

    /// iOS made files with complete protection readable again (the iPhone was unlocked) while this process kept running.
    private func observeProtectedData() {
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.retryStartIfFailed()
                await self?.refreshIdentityAvailability()
            }
        }
        #endif
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
        #if os(iOS)
        guard fixture == nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: AppDelegate.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request); backgroundScheduleError = nil }
        catch { backgroundScheduleError = (error as NSError).localizedDescription + " (\((error as NSError).domain) \((error as NSError).code))" }
        #endif
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
        #if os(iOS)
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
        #endif
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
        backgroundRevocationIncomplete = await sync.identity.revocationIncomplete
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

    func withWorkspace(_ workspace: WorkspaceRecord, _ body: @escaping @Sendable (WorkspaceSync, ConnectionRecord) async -> Void) {
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
        if let data = try? JSONSerialization.data(withJSONObject: intent.payload),
           UploadToken.contains(in: String(decoding: data, as: UTF8.self)) {
            notice = ComposerUploadError.unresolved.localizedDescription
            return false
        }
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
        let edits = (contextEdits, pathEdits)
        let stored = (try? await store.reader.state(key)).flatMap { $0 }
        let routes = stored.flatMap { try? JSONDecoder().decode([ChatRoute].self, from: Data($0.utf8)) } ?? []
        guard key == chatPathKey else { return }   // the workspace changed while reading
        guard edits == (contextEdits, pathEdits) else { return }   // the user navigated while reading
        let workspace = selectedWorkspaceId ?? selectedWorkspace?.id
        let mine = routes.filter { $0.workspaceId == workspace }
        // Builds before the shared context pushed the channel itself; it is now the context (the Chat root), so an
        // upgraded path keeps the same open channel and thread.
        var expected = edits
        if context.channelId == nil, case .channel(_, let channelId)? = mine.first,
           let channel = try? await store.reader.channel(workspaceId: workspace ?? "", id: channelId),
           key == chatPathKey, edits == (contextEdits, pathEdits) {
            setContext(WorkContext(scopeId: channel.scopeId, channelId: channel.id), resetChat: false)
            expected.0 = contextEdits
        }
        guard key == chatPathKey, expected == (contextEdits, pathEdits) else { return }
        restoringPath = true
        chatPath = mine.filter { if case .thread(_, let channelId, _) = $0 { channelId == context.channelId } else { false } }
        restoringPath = false
    }

    // MARK: Shared context (sidebar)

    /// Scopes, channels, collapse state and unread channels of the selected workspace for the sidebar and context bar.
    let navigation = LiveQuery<NavigationSnapshot>(initial: NavigationSnapshot())
    /// The workspace `navigation` was started for (nil until it is). Without it the sidebar has nothing to read.
    @ObservationIgnored private(set) var navigationWorkspaceId: String?

    /// What the sidebar and the Chat channel list say about scopes and channels: never an unexplained empty list.
    var navigationState: NavigationLoadState {
        let workspace = selectedWorkspace?.id ?? selectedWorkspaceId
        let nav = navigation.value
        let connectionId = connection?.id ?? ""
        return .resolve(.init(
            hasWorkspace: workspace != nil,
            workspacesLoaded: workspaces.loaded,
            navigationLoaded: navigation.loaded && (nav.workspaceId == workspace || navigation.error != nil),
            hasScopes: !nav.groups.isEmpty && nav.workspaceId == workspace,
            canRead: canRead,
            refreshing: WorkspaceSync.navigationRefreshing(syncStatus, connectionId: connectionId, workspaceId: workspace),
            error: navigation.error ?? workspaces.error
                ?? WorkspaceSync.navigationError(syncStatus, connectionId: connectionId, workspaceId: workspace)))
    }

    /// Sample-data mode only: Tower's workspace list is fetched and stored again, as any later refresh does.
    func fixtureStoreWorkspacesAgain() async {
        guard fixture != nil, let sync, let connection else { return }
        await sync.discover(connection, priority: .visible, force: true)
    }

    /// Retry from the sidebar: refresh past any failure backoff, and read the saved navigation again if that failed.
    func retryNavigation() {
        if navigation.error != nil || navigationWorkspaceId == nil { Task { await restoreContext() } }
        refresh(force: true)
    }

    private var contextKey: String? {
        guard let connection, let workspace = selectedWorkspaceId ?? selectedWorkspace?.id else { return nil }
        return WorkContext.stateKey(connectionId: connection.id, workspaceId: workspace)
    }

    /// Chooses the context from the sidebar. Chat follows it (a channel's conversation becomes the Chat root); tasks,
    /// documents and files filter to it. Persisted for relaunch.
    func selectContext(_ next: WorkContext) {
        sidebarOpen = false
        guard next != context else { return }
        contextSelections &+= 1
        setContext(next, resetChat: true)
    }

    /// Counts sidebar choices; the shell returns the context-bound modes to their root on each (a record opened in the
    /// old context would otherwise stay on top). Following a record's context does not count.
    private(set) var contextSelections = 0

    /// Opening a record from the global Inbox or Search (or a mention) follows its context, like the web app, without
    /// closing it: the sidebar, Chat, Tasks, Docs and Files then show where it lives.
    func adoptContext(for route: WorkRoute) {
        guard let store, let workspace = selectedWorkspaceId, route.workspaceId == workspace else { return }
        Task {
            let channelId: String?
            switch route {
            case .channel(_, let id), .thread(_, let id, _): channelId = id
            case .task(_, let id): channelId = try? await store.reader.task(workspaceId: workspace, id: id)?.channelId
            case .doc(_, let id): channelId = try? await store.reader.doc(workspaceId: workspace, id: id)?.channelId
            case .file(_, let id): channelId = try? await store.reader.file(workspaceId: workspace, id: id)?.channelId
            case .threadById(_, let id): channelId = try? await store.reader.thread(workspaceId: workspace, id: id)?.channelId
            case .canvas, .board, .contextComponent, .webContent: channelId = nil
            }
            guard let channelId, channelId != context.channelId,
                  let channel = try? await store.reader.channel(workspaceId: workspace, id: channelId), workspace == selectedWorkspaceId else { return }
            setContext(WorkContext(scopeId: channel.scopeId, channelId: channel.id), resetChat: true)
        }
    }

    /// A mentioned conversation: its channel becomes the context and the thread opens on top of it in Chat.
    func openThreadMention(_ threadId: String) {
        guard let store, let workspace = selectedWorkspaceId else { return }
        Task {
            guard let thread = try? await store.reader.thread(workspaceId: workspace, id: threadId),
                  let channel = try? await store.reader.channel(workspaceId: workspace, id: thread.channelId), workspace == selectedWorkspaceId else { return }
            setContext(WorkContext(scopeId: channel.scopeId, channelId: channel.id), resetChat: true)
            mode = .chat
            chatPath = [.thread(workspaceId: workspace, channelId: channel.id, threadId: thread.id)]
        }
    }

    private func setContext(_ next: WorkContext, resetChat: Bool) {
        contextEdits &+= 1
        context = next
        if resetChat { chatPath = [] }
        guard let store, let key = contextKey else { return }
        let encoded = next.encoded()
        Task { try? await store.writer.setState(key, encoded) }
    }

    private func restoreContext() async {
        guard let store, let connection, let key = contextKey, let workspace = selectedWorkspaceId ?? selectedWorkspace?.id else { return }
        let edits = contextEdits
        if let fixture, fixture.slowContextRestore { try? await Task.sleep(for: .seconds(1)) }
        let stored = WorkContext.decode((try? await store.reader.state(key)) ?? nil) ?? .home
        guard key == contextKey else { return }   // the workspace changed while reading
        // A context chosen while reading (or by a newer restore's legacy-path upgrade) wins over the stored one.
        if edits == contextEdits { context = stored }
        contextRestores += 1
        navigationWorkspaceId = workspace
        observeNavigation(connection: connection, workspaceId: workspace)
        observePins(connection: connection, workspaceId: workspace)
        observePeople(connection: connection, workspaceId: workspace)
    }

    private func observeNavigation(connection: ConnectionRecord, workspaceId: String) {
        guard let store else { return }
        let orderKey = WorkspaceSync.scopeOrderKey(workspaceId)
        let collapsedKey = WorkspaceSync.collapsedKey(connectionId: connection.id, workspaceId: workspaceId)
        let viewer = connection.signerNpub
        navigation.start(store: store, matches: { key in
            ([.scopes, .channels, .viewStates, .members].contains(key.table) && key.workspaceId == workspaceId) || key.table == .appState
                || key.table == .profiles
        }) {
            async let scopes = store.reader.scopes(workspaceId: workspaceId)
            async let channels = store.reader.channels(workspaceId: workspaceId)
            async let order = store.reader.state(orderKey)
            async let collapsed = store.reader.state(collapsedKey)
            async let unread = store.reader.unreadChannelIds(workspaceId: workspaceId)
            async let members = store.reader.directoryMembers(workspaceId: workspaceId)
            let groups = SidebarNavigation.groups(scopes: try await scopes, channels: try await channels, personalOrder: ScopeOrdering.decode(try await order))
            let names = Dictionary(try await members.map { ($0.npub, $0.label) }, uniquingKeysWith: { a, _ in a })
            var labels: [String: String] = [:]
            for channel in groups.flatMap(\.channels) { labels[channel.id] = SidebarNavigation.label(channel, viewerNpub: viewer, names: names) }
            return NavigationSnapshot(workspaceId: workspaceId, groups: groups, collapsed: Set(ScopeOrdering.decode(try await collapsed)),
                                      unread: try await unread, labels: labels, loaded: true)
        }
    }

    /// Narrows the context when its scope or channel is no longer listed (deleted, or access lost). Only a complete,
    /// loaded list for this workspace is trusted, so a list still syncing never clears the selection.
    func validateContext() {
        let snapshot = navigation.value
        guard snapshot.loaded, snapshot.workspaceId == selectedWorkspaceId, !snapshot.groups.isEmpty else { return }
        let resolved = context.resolved(scopes: snapshot.groups.map(\.scope), channels: snapshot.groups.flatMap(\.channels))
        if resolved != context { setContext(resolved, resetChat: true) }
    }

    /// Collapse is a personal preference on this iPhone (as on the web, per browser); persisted for relaunch.
    func toggleScopeCollapsed(_ scopeId: String) {
        guard let store, let connection, let workspace = selectedWorkspaceId else { return }
        var collapsed = navigation.value.collapsed
        if collapsed.contains(scopeId) { collapsed.remove(scopeId) } else { collapsed.insert(scopeId) }
        let encoded = String(decoding: (try? JSONEncoder().encode(collapsed.sorted())) ?? Data("[]".utf8), as: UTF8.self)
        let key = WorkspaceSync.collapsedKey(connectionId: connection.id, workspaceId: workspace)
        Task { try? await store.writer.setState(key, encoded) }
    }
}

/// The sidebar's view of the selected workspace (read off the main actor).
struct NavigationSnapshot: Sendable, Equatable {
    var workspaceId: String?
    var groups: [SidebarGroup] = []
    var collapsed: Set<String> = []
    var unread: Set<String> = []
    /// Display labels by channel id (direct messages are named after their participants).
    var labels: [String: String] = [:]
    var loaded = false

    func scope(_ id: String?) -> ScopeRecord? { groups.first { $0.scope.id == id }?.scope }
    func channel(_ id: String?) -> ChannelRecord? { groups.lazy.flatMap(\.channels).first { $0.id == id } }
    func label(_ channel: ChannelRecord) -> String { labels[channel.id] ?? channel.name }
    func channels(in context: WorkContext) -> [ChannelRecord] {
        guard let scopeId = context.scopeId else { return groups.flatMap(\.channels) }
        if let channelId = context.channelId { return groups.flatMap(\.channels).filter { $0.id == channelId } }
        return groups.first { $0.scope.id == scopeId }?.channels ?? []
    }
}
