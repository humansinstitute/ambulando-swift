import AmbulandoCore
import Foundation
import ImageIO
import Observation
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

/// Deterministic local sample data for UI automation and demos, enabled only in Debug builds with the
/// `-AmbulandoUITestFixture` launch argument. Every app code path (identity vault, signing, store, sync engine,
/// outbox) runs for real; only the network transport is replaced by an in-process stand-in for Tower, so nothing
/// leaves the device. The identity is a throwaway key generated on first fixture launch, never a user's key.
/// The UI labels this mode on every screen; it is not evidence of live Tower behaviour.
@MainActor
@Observable
final class FixtureEnvironment {
    nonisolated static let origin = "https://fixture.ambulando.invalid"
    nonisolated static let pin = "135790"
    let studioWorkspaceId = FixtureTower.studio
    let directory: URL
    let tower: FixtureTower
    let secrets: VaultSecretStore
    /// Real Keychain item under a fixture-only service, so the opt-in background credential path runs as in production.
    let backgroundCredentials: BackgroundCredentialStore
    /// Trusted-device session item under a fixture-only service.
    let sessionKeys: SessionKeyStore
    /// In-process stand-in for the SSE route, fed from the fixture's event log.
    let events: EventStreamTransport
    /// Sample public profiles and avatars, served without any relay or picture host.
    let profileSource: ProfileSource
    let avatarTransport: AvatarTransport
    private let live: Bool
    /// Diagnostic only (`-AmbulandoDiagnosticPlainKeyboard`): turns off autocorrection/predictive text in the composer
    /// to attribute stalls to system text input. Never used for the budget runs.
    let plainKeyboard = ProcessInfo.processInfo.arguments.contains("-AmbulandoDiagnosticPlainKeyboard")
    private let simulateBackground: Bool
    /// Result of the simulated background refresh (`-AmbulandoFixtureSimulateBackgroundRefresh`), shown on screen.
    private(set) var backgroundSimulation: String?
    private let startLocked: Bool
    private let storm: Bool
    /// Control run for the storm check: same typing and probe window, no database writes.
    private let stormControl: Bool
    private(set) var stormStatus: String?
    /// `-AmbulandoFixtureSlowContextRestore`: reading the saved context takes a second, so a workspace list stored
    /// meanwhile is seen before the launch restore finishes (makes the launch-order check deterministic).
    let slowContextRestore = ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureSlowContextRestore")

    var offline: Bool {
        get { access(keyPath: \.offline); return tower.offline }
        set { withMutation(keyPath: \.offline) { tower.offline = newValue } }
    }
    var failScopes: Bool {
        get { access(keyPath: \.failScopes); return tower.failScopes }
        set { withMutation(keyPath: \.failScopes) { tower.failScopes = newValue } }
    }
    var rejectNextSend: Bool {
        get { access(keyPath: \.rejectNextSend); return tower.rejectNext }
        set { withMutation(keyPath: \.rejectNextSend) { tower.rejectNext = newValue } }
    }

    private init(directory: URL, startLocked: Bool, storm: Bool, stormControl: Bool, offline: Bool, live: Bool = false, simulateBackground: Bool = false) {
        self.directory = directory
        self.live = live
        self.simulateBackground = simulateBackground
        self.startLocked = startLocked
        self.storm = storm || stormControl
        self.stormControl = stormControl
        tower = FixtureTower(file: directory.appendingPathComponent("fixture-tower.json"))
        tower.offline = offline
        tower.failScopes = ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureScopesFail")
        secrets = KeychainVaultSecretStore(service: KeychainServices.named("studio.otherstuff.ambulando.native.fixture-vault.v1"))
        backgroundCredentials = KeychainBackgroundCredentialStore(service: Self.backgroundService)
        sessionKeys = KeychainSessionKeyStore(service: Self.sessionService)
        events = FixtureEventStream(tower: tower)
        profileSource = FixtureProfileSource(tower: tower)
        avatarTransport = FixtureAvatarTransport(tower: tower)
    }

    nonisolated static let backgroundService = KeychainServices.named("studio.otherstuff.ambulando.native.fixture-background.v1")
    nonisolated static let sessionService = KeychainServices.named("studio.otherstuff.ambulando.native.fixture-session.v1")

    /// `-AmbulandoFixtureLive`: another member posts in #general every few seconds (≤ 5 messages), delivered through
    /// the event log and the SSE stand-in, so live updates are visible while the user types.
    func startLiveIfRequested() {
        guard live else { return }
        let tower = tower
        Task.detached(priority: .utility) {
            for n in 1...5 {
                try? await Task.sleep(for: .seconds(3))
                tower.postAsMember(channel: FixtureTower.generalChannel, body: "Live update \(n) from Ana")
            }
        }
    }

    /// `-AmbulandoFixtureSimulateBackgroundRefresh`: runs the same pipeline a BGAppRefreshTask runs (the simulator
    /// cannot be granted real background windows on demand). Labelled as a simulation in the UI.
    func simulateBackgroundRefreshIfRequested(_ model: AppModel) async {
        guard simulateBackground, backgroundSimulation == nil, let sync = model.sync, let connection = model.connection,
              let workspace = await model.resolvedWorkspace() else { return }
        backgroundSimulation = "simulated background refresh: running"
        // As in the real transition: the foreground stream closes, then a change happens elsewhere, then iOS grants a window.
        await model.liveStream?.stop()
        _ = try? await sync.catchUpEventsAndWait(connection, workspace)
        await sync.engine.waitUntilIdle()
        tower.postAsMember(channel: FixtureTower.generalChannel, body: "Posted while the app was in the background")
        let report = await model.runBackgroundRefresh(budget: .seconds(20))
        backgroundSimulation = "simulated background refresh: \(report.result.rawValue) events=\(report.events)"
    }

    static func fromLaunchArguments() -> FixtureEnvironment? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-AmbulandoUITestFixture") else { return nil }
        #if os(iOS) && !targetEnvironment(simulator)
        // On a physical iPhone a sample-data process looks like a different account to whoever opens the app next, so it
        // needs a second, deliberate flag (a designated test device only, never someone's everyday phone).
        guard args.contains("-AmbulandoFixtureOnDevice") else { return nil }
        #endif
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AmbulandoFixture", isDirectory: true)
        if args.contains("-AmbulandoFixtureReset") {
            try? FileManager.default.removeItem(at: directory)
            try? KeychainBackgroundCredentialStore(service: backgroundService).delete()
            try? KeychainSessionKeyStore(service: sessionService).delete()
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FixtureEnvironment(directory: directory, startLocked: args.contains("-AmbulandoFixtureLocked"),
                                  storm: args.contains("-AmbulandoFixtureStorm"), stormControl: args.contains("-AmbulandoFixtureStormControl"),
                                  offline: args.contains("-AmbulandoFixtureOffline"), live: args.contains("-AmbulandoFixtureLive"),
                                  simulateBackground: args.contains("-AmbulandoFixtureSimulateBackgroundRefresh"))
        #else
        return nil
        #endif
    }

    /// First launch: create the throwaway identity and connect through the normal descriptor/discovery path.
    func prepare(identity: IdentityService, sync: WorkspaceSync, store: LocalStore) async throws {
        if case .none = await identity.state {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { throw IdentityError.keychainUnavailable }
            try await identity.importIdentity(nsec: Bech32.encode(hrp: "nsec", data: Data(bytes)), pin: Self.pin)
            await identity.lock()
        }
        // `-AmbulandoFixtureLocked` starts as after Lock now (no session resume); otherwise unlock with the PIN.
        // `-AmbulandoFixtureNoAutoUnlock` leaves the state to the session resume (stay-unlocked tests).
        let autoUnlock = !ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureNoAutoUnlock")
        if startLocked { await identity.lock() } else if autoUnlock, case .locked = await identity.state { try await identity.unlock(pin: Self.pin) }
        if let npub = await identity.state.npub { tower.actorNpub = npub; tower.work.actorNpub = npub; tower.labWork.actorNpub = npub }
        tower.seedWorkIfNeeded()
        tower.seedSurfacesIfNeeded()
        if try await store.reader.connections().isEmpty, case .unlocked = await identity.state {
            let connection = try await sync.connect(origin: try TowerOrigin(Self.origin))
            try await store.writer.setState("selected.connection", connection.id)
            // Production stores a workspace choice only when the switcher is used, so most phones have none
            // (`-AmbulandoFixtureNoWorkspaceChoice`), or one Tower no longer lists (`-AmbulandoFixtureStaleWorkspaceChoice`).
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-AmbulandoFixtureStaleWorkspaceChoice") {
                try await store.writer.setState("selected.workspace:\(connection.id)", FixtureTower.removedWorkspace)
            } else if !args.contains("-AmbulandoFixtureNoWorkspaceChoice") {
                try await store.writer.setState("selected.workspace:\(connection.id)", FixtureTower.studio)
            }
            await sync.discover(connection, priority: .visible, force: true)
            await sync.engine.waitUntilIdle()
        }
    }

    /// Sync storm for the responsiveness check: 20,000 messages materialised into another channel of the visible
    /// workspace in 500-row transactions (as catch-up would), while the main-actor probe samples latency.
    func startStormIfRequested(store: LocalStore, workspaceId: String) {
        keystrokes.append(ContinuousClock.now)
        guard storm, stormStatus == nil else { return }
        stormStatus = "storm: running"
        stormStarted = ContinuousClock.now
        frames.start()
        Task { [weak self] in
            let result = await Self.runStorm(store: store, workspaceId: workspaceId, writes: !(self?.stormControl ?? false))
            guard let self else { return }
            self.frames.stop()
            self.stormStatus = result.text + " " + self.attribution(result.timeline)
        }
    }

    private let frames = FrameMonitor()
    private var keystrokes: [ContinuousClock.Instant] = []
    private var stormStarted: ContinuousClock.Instant?

    /// Frame pacing and the three worst main-actor stalls, each with the distance to the nearest keystroke, so a stall
    /// can be attributed to input handling, rendering or sync (compare with the no-write control).
    private func attribution(_ samples: [MainActorProbe.Sample]) -> String {
        let f = frames.summary()
        let origin = stormStarted ?? .now
        let keys = keystrokes.map { ($0 - origin).milliseconds }
        let worst = samples.sorted { $0.latency > $1.latency }.prefix(3).map { sample -> String in
            let nearest = keys.min { abs($0 - sample.at) < abs($1 - sample.at) }.map { $0 - sample.at } ?? .nan
            return String(format: "t%.0f:%.1fms(key%+.0fms)", sample.at, sample.latency, nearest)
        }
        let firstKeyStall = samples.filter { $0.at < (keys.dropFirst().first ?? 0) }.map(\.latency).max() ?? 0
        let afterFirst = samples.filter { $0.at >= (keys.dropFirst().first ?? 0) }.map(\.latency)
        let typing = LatencyReport(samples: afterFirst)
        return String(format: "frames=%d maxFrame=%.1fms hitches=%d hitchRatio=%.1fms/s firstKeyMax=%.1fms afterFirstKey p99=%.2fms max=%.2fms keys=%d stalls=[%@]",
                      f.frames, f.maxGap, f.hitches, f.hitchRatio, firstKeyStall, typing.percentile(99), typing.max, keystrokes.count,
                      worst.joined(separator: " "))
    }

    nonisolated private static func runStorm(store: LocalStore, workspaceId: String, writes: Bool) async -> (text: String, timeline: [MainActorProbe.Sample]) {
        await Task.detached(priority: .utility) {
            // The probe covers exactly the storm window (which overlaps typing), not launch or navigation.
            let done = StormFlag()
            async let timeline = MainActorProbe.timeline { await done.value }
            let clock = ContinuousClock(), start = clock.now
            for batch in 0..<40 {
                let rows = (0..<500).map { i -> MessageRecord in
                    let n = batch * 500 + i
                    return MessageRecord(workspaceId: workspaceId, id: UUID().uuidString.lowercased(), channelId: FixtureTower.designChannel,
                                         threadId: nil, body: "Storm message \(n) " + String(repeating: "lorem ipsum ", count: 12),
                                         senderNpub: FixtureTower.ana,
                                         createdAt: String(format: "2026-10-01T%02d:%02d:%02d.%03dZ", (n / 3600) % 24, (n / 60) % 60, n % 60, n % 1000))
                }
                if writes { _ = try? await store.writer.upsertMessages(rows) }
                try? await Task.sleep(for: .milliseconds(50))   // paced like network pages, so the storm lasts while typing
            }
            let elapsed = clock.now - start
            await done.set()
            let samples = await timeline
            let probe = LatencyReport(samples: samples.map(\.latency))
            let text = String(format: "storm: done rows=%d window=%.0fms probe n=%d p99=%.2fms max=%.2fms", writes ? 20000 : 0,
                              elapsed.milliseconds, probe.count, probe.percentile(99), probe.max)
            return (text, samples)
        }.value
    }
}

actor StormFlag {
    var value = false
    func set() { value = true }
}

/// In-process stand-in for the Tower chat routes used by this app, persisted to the fixture directory.
/// It follows the route contracts (forward cursor paging, `create_thread`, `client_request_id` replay,
/// kind 33358 content/tag checks) closely enough for UI automation; it is not Tower.
final class FixtureTower: HTTPTransport, @unchecked Sendable {
    static let studio = "f1c70000-0000-4000-8000-000000000001"
    static let lab = "f1c70000-0000-4000-8000-000000000002"
    /// A workspace this identity no longer belongs to (never listed).
    static let removedWorkspace = "f1c70000-0000-4000-8000-0000000000ff"
    static let scopeAmbulando = "f1c70000-0000-4000-8000-0000000000a1"
    static let scopeOps = "f1c70000-0000-4000-8000-0000000000a2"
    static let scopeResearch = "f1c70000-0000-4000-8000-0000000000a3"
    static let generalChannel = "f1c70000-0000-4000-8000-0000000000c1"
    static let designChannel = "f1c70000-0000-4000-8000-0000000000c2"
    static let deploysChannel = "f1c70000-0000-4000-8000-0000000000c3"
    static let notesChannel = "f1c70000-0000-4000-8000-0000000000c4"
    static let ana = Bech32.encode(hrp: "npub", data: Data(repeating: 0xA1, count: 32))
    static let rick = Bech32.encode(hrp: "npub", data: Data(repeating: 0xB2, count: 32))
    static let brick = Bech32.encode(hrp: "npub", data: Data(repeating: 0xB5, count: 32))
    /// A member without a workspace name: the app names her from her (sample) public profile.
    static let bea = Bech32.encode(hrp: "npub", data: Data(repeating: 0xC4, count: 32))
    /// Someone who posted but is no longer listed and has no profile: shown by npub and initials.
    static let former = Bech32.encode(hrp: "npub", data: Data(repeating: 0xD5, count: 32))
    static let appNpub = Bech32.encode(hrp: "npub", data: Data(repeating: 0xC3, count: 32))

    private let lock = NSLock()
    private let file: URL
    /// Tasks, documents, files, storage, inbox and reactions (shared with the core tests).
    let work: SampleWorkTower
    /// The second sample workspace has no tasks, documents or files (empty lists, not errors).
    let labWork: SampleWorkTower
    /// Context Tree, canvases, boards, agents, Toolbox and pins (shared with the core tests); the lab workspace has none.
    let surfaces: SampleSurfaceTower
    let labSurfaces: SampleSurfaceTower
    /// Board File versions (list, read, save with a stale-base check) and their canvas projection.
    let boards: SampleBoardTower
    private var posted: [[String: Any]] = []
    /// Edits and deletions of messages, by id (persisted with the posted messages).
    private var revised: [String: [String: Any]] = [:]
    private var requests: [String: [String: Any]] = [:]
    /// Tower outbox event log (`GET /events`, the SSE stand-in), persisted with the posted messages.
    private var eventLog: [[String: Any]] = []
    /// Scope and channel management (created, renamed, reordered, archived; personal order), persisted like the messages.
    /// Writes to the Operations scope and its channels are refused with 403, as for a member without Manage access.
    private var managed: [String: Any] = [:]
    private let manageFile: URL
    /// The next scope-order save meets an edit from another session (`-AmbulandoFixtureScopeOrderConflict`).
    var scopeOrderConflict = ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureScopeOrderConflict")
    private var _offline = false, _rejectNext = false
    private var _actor = ""

    var offline: Bool { get { lock.withLock { _offline } } set { lock.withLock { _offline = newValue } } }
    /// Scope lists answer HTTP 500 as Tower does for an internal error (`-AmbulandoFixtureScopesFail`).
    var failScopes: Bool { get { lock.withLock { _failScopes } } set { lock.withLock { _failScopes = newValue } } }
    private var _failScopes = false
    var rejectNext: Bool { get { lock.withLock { _rejectNext } } set { lock.withLock { _rejectNext = newValue } } }
    var actorNpub: String { get { lock.withLock { _actor } } set { lock.withLock { _actor = newValue } } }

    init(file: URL) {
        self.file = file
        manageFile = file.deletingLastPathComponent().appendingPathComponent("fixture-manage.json")
        if let data = try? Data(contentsOf: manageFile), let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { managed = saved }
        work = SampleWorkTower(workspaceId: Self.studio, towerOrigin: FixtureEnvironment.origin,
                               file: file.deletingLastPathComponent().appendingPathComponent("fixture-work.json"))
        labWork = SampleWorkTower(workspaceId: Self.lab, towerOrigin: FixtureEnvironment.origin, objectHost: "objects-lab.sample.invalid",
                                  file: file.deletingLastPathComponent().appendingPathComponent("fixture-work-lab.json"))
        surfaces = SampleSurfaceTower(workspaceId: Self.studio, file: file.deletingLastPathComponent().appendingPathComponent("fixture-surfaces.json"))
        labSurfaces = SampleSurfaceTower(workspaceId: Self.lab, file: file.deletingLastPathComponent().appendingPathComponent("fixture-surfaces-lab.json"))
        boards = SampleBoardTower(workspaceId: Self.studio, file: file.deletingLastPathComponent().appendingPathComponent("fixture-boards.json"))
        // Pins and references resolve against the sample tasks, documents and channels the other routes serve.
        let work = work
        boards.objectBytes = { id in work.completedObjectBytes(id) }
        boards.externalSaveBeforeNextPublish = ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureBoardConflict")
        work.externalSaveBeforeNextDocBodySave = ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureDocConflict")
        surfaces.recordLookup = { id in
            if let t = work.task(id) { return ["title": t["title"] ?? "", "channel_id": t["channel_id"] ?? NSNull(), "scope_id": t["scope_id"] ?? NSNull()] }
            if let d = work.doc(id) { return ["title": d["title"] ?? "", "channel_id": d["channel_id"] ?? NSNull(), "scope_id": d["scope_id"] ?? NSNull()] }
            let channels = [Self.generalChannel: Self.scopeAmbulando, Self.designChannel: Self.scopeAmbulando, Self.deploysChannel: Self.scopeOps]
            if let scope = channels[id] { return ["title": "channel", "channel_id": id, "scope_id": scope] }
            if id.hasPrefix("f1c7bbbb") { return ["title": "Conversation", "channel_id": Self.generalChannel, "scope_id": Self.scopeAmbulando] }
            return nil
        }
        if let data = try? Data(contentsOf: file), let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            posted = (saved["posted"] as? [[String: Any]]) ?? []
            eventLog = (saved["events"] as? [[String: Any]]) ?? []
            revised = (saved["revised"] as? [String: [String: Any]]) ?? [:]
            for row in posted { if let id = row["client_request_id"] as? String { requests[id] = row } }
        }
    }

    private func persist() {
        if let data = try? JSONSerialization.data(withJSONObject: ["posted": posted, "revised": revised, "events": eventLog]) { try? data.write(to: file, options: .atomic) }
    }

    private static func uuid(_ n: Int, _ prefix: String) -> String { String(format: "\(prefix)-0000-4000-8000-%012d", n) }
    /// Seeded history spans three days (general #1–13, #14–26, the rest), so chat shows its date separators.
    private static func time(_ n: Int) -> String {
        let day = n <= 13 ? 21 : n <= 26 ? 22 : 23
        return String(format: "2026-10-%02dT%02d:%02d:00.000Z", day, 8 + n / 60, n % 60)
    }

    /// Seeded history: general has 40 conversations (one with replies), design/deploys/notes a few each.
    private var seeded: [[String: Any]] {
        var rows: [[String: Any]] = []
        func add(_ n: Int, _ workspace: String, _ channel: String, _ body: String, sender: String, label: String?, thread: String? = nil) {
            let id = Self.uuid(n, "f1c7aaaa")
            let threadId = thread ?? Self.uuid(n, "f1c7bbbb")
            let source = thread == nil ? id : Self.uuid(Int(thread!.suffix(12))!, "f1c7aaaa")
            rows.append(["id": id, "workspace_id": workspace, "channel_id": channel, "thread_id": threadId, "thread_source_message_id": source,
                         "body": body, "client_request_id": NSNull(), "record_state": "active", "row_version": 1, "sender_npub": sender,
                         "created_by_actor_label": label.map { $0 as Any } ?? NSNull(), "created_at": Self.time(n), "updated_at": Self.time(n)])
        }
        let topics = ["Walkthrough notes for the passage screens", "Theme tokens are synced with the web app", "Who owns the deploy checklist?",
                      "Draft agenda for Thursday", "Sync storm results look good", "Native chat review", "Docs index needs a refresh",
                      "Files upload uses storage prepare", "Inbox counts mentions and tasks", "Release notes for build 2"]
        for n in 1...40 {
            let ana = n % 3 != 0
            var body = "\(topics[(n - 1) % topics.count]) (#\(n))"
            if n == 38 { body = "@[Rick](mention:agent:\(Self.rick)) can you check the outbox retry states?" }
            add(n, Self.studio, Self.generalChannel, body, sender: ana ? Self.ana : Self.rick, label: ana ? "Ana" : "Rick")
        }
        let thread = Self.uuid(39, "f1c7bbbb")
        for (i, text) in ["Looks right on my phone", "Retry kept the same request id", "Ship it"].enumerated() {
            add(100 + i, Self.studio, Self.generalChannel, text, sender: i % 2 == 0 ? Self.rick : Self.ana, label: i % 2 == 0 ? "Rick" : "Ana", thread: thread)
        }
        add(198, Self.studio, Self.designChannel, "Shared the colour swatches for the new surfaces", sender: Self.bea, label: nil)
        add(199, Self.studio, Self.designChannel, "Dark mode keeps the same purple highlight", sender: Self.bea, label: nil)
        add(200, Self.studio, Self.designChannel, "Passage mark stays on its white backing", sender: Self.ana, label: "Ana")
        add(202, Self.studio, Self.designChannel, Self.richMessage, sender: Self.rick, label: "Rick")
        add(201, Self.studio, Self.deploysChannel, "Staging is green", sender: Self.rick, label: "Rick")
        add(205, Self.studio, Self.deploysChannel, "Handing the deploy rota over", sender: Self.former, label: nil)
        add(300, Self.lab, Self.notesChannel, "Lab workspace notes live here", sender: Self.ana, label: "Ana")
        return rows
    }

    private func allMessages() -> [[String: Any]] {
        (seeded + posted).map { revised[$0["id"] as? String ?? ""] ?? $0 }.sorted { (($0["created_at"] as! String), ($0["id"] as! String)) < (($1["created_at"] as! String), ($1["id"] as! String)) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .milliseconds(40))   // a little latency so states are observable
        let (status, body) = try route(request)
        let data = try (body as? Data) ?? JSONSerialization.data(withJSONObject: body)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    private func route(_ request: URLRequest) throws -> (Int, Any) {
        let path = request.url!.path
        if path == "/.well-known/nstack.json" {
            return (200, ["schema": "org.wingman.nstack.services", "schema_version": 1, "stack": ["tower_npub": Self.appNpub],
                          "services": [["id": "tower", "kind": "tower", "endpoint": FixtureEnvironment.origin, "protocols": ["https", "nip-98"],
                                        "availability": ["status": "available (local fixture)"]]]])
        }
        if request.url?.host == work.objectHost || request.url?.host == labWork.objectHost {
            // Presigned object-store upload: never signed (SampleWorkTower records any credential that arrives).
            if offline { throw URLError(.notConnectedToInternet) }
            return try work.handle(request) ?? labWork.handle(request) ?? (404, ["code": "not_found"])
        }
        guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Nostr ") == true else { return (401, ["code": "unauthorized"]) }
        if offline { throw URLError(.notConnectedToInternet) }
        // Surface routes first: their ownership is exact (board versions live under `/files/:f/versions/:v/object`).
        if let handled = try boards.handle(request) ?? surfaces.handle(request) ?? labSurfaces.handle(request) ?? work.handle(request) ?? labWork.handle(request) {
            return boards.project(handled, for: request)
        }
        let base = "/api/v4/flightdeck-pg/workspaces"
        if path == base {
            return (200, ["workspaces": [workspace(Self.studio, "Studio (sample)"), workspace(Self.lab, "Lab (sample)")], "next_cursor": NSNull()])
        }
        let parts = path.replacingOccurrences(of: base + "/", with: "").split(separator: "/").map(String.init)
        guard let w = parts.first, [Self.studio, Self.lab].contains(w) else { return (404, ["code": "not_found"]) }
        let rest = Array(parts.dropFirst())
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch (request.httpMethod ?? "GET", rest.count, rest.first) {
        case ("GET", 1, "scopes") where failScopes:
            return (500, ["error": "Internal error", "code": "internal_error", "status": 500])
        case ("GET", 1, "scopes"):
            return lock.withLock { (200, ["scopes": scopeRows(w), "next_cursor": NSNull()]) }
        case ("GET", 3, "scopes") where rest[2] == "channels":
            return lock.withLock { (200, ["channels": channelRows(w, scope: rest[1]), "next_cursor": NSNull()]) }
        case ("GET", 1, "me"):
            return (200, ["actor": ["actor_id": "f1c70000-0000-4000-8000-0000000000e1", "npub": actorNpub], "membership": ["role": "member"],
                          "permissions": ["channel.create", "channel.manage", "channel.read", "channel.write", "scope.create", "workspace.read"]])
        case ("POST", 3, "scopes") where rest[2] == "channels", ("POST", 1, "scopes"), ("PATCH", 2, "scopes"), ("DELETE", 2, "scopes"),
             ("PATCH", 2, "channels"), ("DELETE", 2, "channels"), ("POST", 3, "channels") where rest.last == "reorder" || rest.count == 2,
             ("PUT", 2, "me"):
            return try manage(request, workspace: w, rest: rest)
        case ("GET", 1, "members"):
            let me = actorNpub
            return (200, ["members": [member(me, "You (sample identity)", "human"), member(Self.ana, "Ana", "human"), member(Self.rick, "Rick", "agent"),
                                      member(Self.bea, nil, "human")],
                          "next_cursor": NSNull()])
        case ("GET", 2, "me"):
            return lock.withLock { (200, ["scope_order": scopeOrder(w)]) }
        case ("GET", 3, "channels") where rest[2] == "messages":
            return lock.withLock {
                let all = allMessages().filter { $0["workspace_id"] as? String == w && $0["channel_id"] as? String == rest[1]
                    && (q("thread_id") == nil || $0["thread_id"] as? String == q("thread_id")) }
                let start = q("cursor").flatMap { Int(String(decoding: Data(base64Encoded: $0) ?? Data(), as: UTF8.self)) } ?? 0
                let limit = min(200, Int(q("limit") ?? "50") ?? 50)
                let page = Array(all.dropFirst(start).prefix(limit))
                let next: Any = start + page.count < all.count ? Data(String(start + page.count).utf8).base64EncodedString() : NSNull()
                return (200, ["messages": page, "next_cursor": next])
            }
        case ("GET", 3, "channels") where rest[2] == "threads":
            return lock.withLock {
                let roots = allMessages().filter { $0["channel_id"] as? String == rest[1] && $0["id"] as? String == $0["thread_source_message_id"] as? String }
                return (200, ["threads": roots.map { thread(for: $0) }, "next_cursor": NSNull()])
            }
        case ("GET", 2, "threads"):
            return lock.withLock {
                guard let root = allMessages().first(where: { $0["thread_id"] as? String == rest[1] && $0["id"] as? String == $0["thread_source_message_id"] as? String })
                else { return (404, ["code": "thread_not_found"]) }
                return (200, ["thread": thread(for: root)])
            }
        case ("POST", 3, "channels") where rest[2] == "messages":
            return try post(request, workspace: w, channel: rest[1])
        case ("GET", 1, "events"):
            guard let after = Self.eventRow(q("cursor")) else { return (400, ["code": "validation_error"]) }
            let page = events(workspace: w, after: after, limit: min(200, Int(q("limit") ?? "50") ?? 50))
            let next: Any = (page.last?["cursor"] as? String) ?? q("cursor") ?? NSNull()
            return (200, ["events": page, "next_cursor": next])
        case ("GET", 1, "sync"):
            return (200, ["mode": "snapshot", "through_cursor": Self.eventCursor(eventHead), "channel_bundles": []])
        case ("GET", 2, "messages"):
            return lock.withLock { allMessages().first { $0["id"] as? String == rest[1] }.map { (200, ["message": $0]) } ?? (404, ["code": "message_not_found"]) }
        case ("PATCH", 2, "messages"), ("DELETE", 2, "messages"):
            return try revise(request, id: rest[1], query: query)
        default:
            return (404, ["code": "not_found"])
        }
    }

    // MARK: Scope and channel management (caller holds `lock` for the *Rows helpers)

    private func manageList(_ key: String) -> [[String: Any]] { managed[key] as? [[String: Any]] ?? [] }
    private func manageMap(_ key: String) -> [String: [String: Any]] { managed[key] as? [String: [String: Any]] ?? [:] }
    private var archived: Set<String> { Set(managed["archived"] as? [String] ?? []) }
    private func persistManaged() { if let data = try? JSONSerialization.data(withJSONObject: managed) { try? data.write(to: manageFile, options: .atomic) } }

    private func scopeRows(_ w: String) -> [[String: Any]] {
        let base = w == Self.studio ? [scope(Self.scopeAmbulando, w, "Ambulando"), scope(Self.scopeOps, w, "Operations")]
                                    : [scope(Self.scopeResearch, w, "Research")]
        let edits = manageMap("scopeEdits")
        return (base + manageList("scopes").filter { $0["workspace_id"] as? String == w })
            .filter { !archived.contains($0["id"] as? String ?? "") }
            .map { row in
                var row = row
                let id = row["id"] as? String ?? ""
                for (k, v) in edits[id] ?? [:] { row[k] = v }
                row["can_manage"] = id != Self.scopeOps
                return row
            }
    }

    private func channelRows(_ w: String, scope s: String) -> [[String: Any]] {
        let base: [[String: Any]] = switch s {
        case Self.scopeAmbulando: [channel(Self.generalChannel, w, s, "general", 1), channel(Self.designChannel, w, s, "design", 2)]
        case Self.scopeOps: [channel(Self.deploysChannel, w, s, "deploys", 1)]
        case Self.scopeResearch: [channel(Self.notesChannel, w, s, "notes", 1)]
        default: []
        }
        let edits = manageMap("channelEdits"), gone = archived
        let created: [[String: Any]] = manageList("channels").filter { $0["workspace_id"] as? String == w && $0["scope_id"] as? String == s }
        var rows: [[String: Any]] = []
        for original in base + created {
            let id = original["id"] as? String ?? ""
            guard !gone.contains(id) else { continue }
            var row = original
            for (k, v) in edits[id] ?? [:] { row[k] = v }
            rows.append(row)
        }
        func key(_ row: [String: Any]) -> (Double, String) { ((row["position"] as? Double) ?? 0, (row["id"] as? String) ?? "") }
        return rows.sorted { key($0) < key($1) }
    }

    private func scopeOrder(_ w: String) -> [String: Any] {
        if let saved = (managed["scopeOrder"] as? [String: Any])?[w] as? [String: Any] { return saved }
        return ["scope_ids": w == Self.studio ? [Self.scopeOps, Self.scopeAmbulando] : [], "row_version": 1]
    }

    private func channelScope(_ w: String, _ id: String) -> String? {
        for scope in scopeRows(w) { if let s = scope["id"] as? String, channelRows(w, scope: s).contains(where: { $0["id"] as? String == id }) { return s } }
        return nil
    }

    private func editChannel(_ id: String, _ values: [String: Any]) {
        var edits = manageMap("channelEdits")
        var row = edits[id] ?? [:]
        for (k, v) in values { row[k] = v }
        row["updated_at"] = ISO8601DateFormatter.fixture.string(from: Date())
        edits[id] = row
        managed["channelEdits"] = edits
    }

    private func manage(_ request: URLRequest, workspace w: String, rest: [String]) throws -> (Int, Any) {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let method = request.httpMethod ?? "GET"
        let forbidden: (Int, Any) = (403, ["code": "forbidden", "error": "Permission denied"])
        return lock.withLock {
            defer { persistManaged() }
            let now = ISO8601DateFormatter.fixture.string(from: Date())
            switch (method, rest.count, rest.first) {
            case ("POST", 3, "scopes"):
                let s = rest[1]
                guard scopeRows(w).contains(where: { $0["id"] as? String == s }) else { return (404, ["code": "scope_not_found"]) }
                if s == Self.scopeOps { return forbidden }
                let name = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return (400, ["code": "validation_error", "details": ["fields": [["message": "name must be a non-empty string"]]]]) }
                if channelRows(w, scope: s).contains(where: { $0["name"] as? String == name }) { return (409, ["code": "duplicate_channel"]) }
                var row = channel(UUID().uuidString.lowercased(), w, s, name, Double(channelRows(w, scope: s).count + 1))
                row["kind"] = body["kind"] ?? "channel"; row["metadata"] = body["metadata"] ?? [:]
                row["description"] = body["description"] ?? NSNull(); row["participant_npubs"] = body["participant_npubs"] ?? NSNull()
                row["updated_at"] = now
                managed["channels"] = manageList("channels") + [row]
                return (201, ["channel": row])
            case ("POST", 1, "scopes"):
                let name = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if scopeRows(w).contains(where: { $0["name"] as? String == name }) { return (409, ["code": "duplicate_scope"]) }
                var row = scope(UUID().uuidString.lowercased(), w, name)
                row["description"] = body["description"] ?? NSNull(); row["updated_at"] = now
                managed["scopes"] = manageList("scopes") + [row]
                return (201, ["scope": row])
            case ("PATCH", 2, "scopes"), ("DELETE", 2, "scopes"):
                let s = rest[1]
                guard var row = scopeRows(w).first(where: { $0["id"] as? String == s }) else { return (404, ["code": "scope_not_found"]) }
                if s == Self.scopeOps { return forbidden }
                if method == "DELETE" { managed["archived"] = Array(archived.union([s])); return (200, ["scope": row]) }
                var edits = manageMap("scopeEdits")
                edits[s] = ["name": body["name"] ?? row["name"]!, "description": body["description"] ?? NSNull(), "updated_at": now]
                managed["scopeEdits"] = edits
                for (k, v) in edits[s]! { row[k] = v }
                return (200, ["scope": row])
            case ("PATCH", 2, "channels"), ("DELETE", 2, "channels"), ("POST", 3, "channels"):
                let c = rest[1]
                guard let s = channelScope(w, c), let row = channelRows(w, scope: s).first(where: { $0["id"] as? String == c }) else {
                    return (404, ["code": "channel_not_found"])
                }
                if s == Self.scopeOps { return forbidden }
                if method == "DELETE" { managed["archived"] = Array(archived.union([c])); return (200, ["channel": row]) }
                if method == "POST" {
                    var siblings = channelRows(w, scope: s)
                    let moved = siblings.remove(at: siblings.firstIndex { $0["id"] as? String == c }!)
                    siblings.insert(moved, at: min(max(0, ((body["position"] as? Int) ?? 1) - 1), siblings.count))
                    for (i, sibling) in siblings.enumerated() { editChannel(sibling["id"] as! String, ["position": Double(i + 1)]) }
                    return (200, ["channel": channelRows(w, scope: s).first { $0["id"] as? String == c }!, "changed": true])
                }
                var values: [String: Any] = [:]
                if let name = body["name"] as? String {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if channelRows(w, scope: s).contains(where: { $0["name"] as? String == trimmed && $0["id"] as? String != c }) { return (409, ["code": "duplicate_channel"]) }
                    values["name"] = trimmed
                }
                if let metadata = body["metadata"] as? [String: Any] {
                    values["metadata"] = ((row["metadata"] as? [String: Any]) ?? [:]).merging(metadata) { $1 }
                }
                editChannel(c, values)
                return (200, ["channel": channelRows(w, scope: s).first { $0["id"] as? String == c }!])
            case ("PUT", 2, "me"):
                var order = scopeOrder(w)
                var version = order["row_version"] as? Int ?? 1
                if scopeOrderConflict {
                    scopeOrderConflict = false
                    version += 1
                    order = ["scope_ids": [Self.scopeAmbulando, Self.scopeOps], "row_version": version]
                    var all = managed["scopeOrder"] as? [String: Any] ?? [:]; all[w] = order; managed["scopeOrder"] = all
                }
                guard body["expected_row_version"] as? Int == version else { return (409, ["code": "scope_order_conflict"]) }
                order = ["scope_ids": body["scope_ids"] as? [String] ?? [], "row_version": version + 1]
                var all = managed["scopeOrder"] as? [String: Any] ?? [:]; all[w] = order; managed["scopeOrder"] = all
                return (200, ["scope_order": order])
            default:
                return (404, ["code": "not_found"])
            }
        }
    }

    private func post(_ request: URLRequest, workspace w: String, channel c: String) throws -> (Int, Any) {
        let object = (try JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let body = (object["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let event = ((object["message_signature"] as? [String: Any])?["nostr_event"] as? [String: Any]) ?? [:]
        let attachmentCount = (((object["metadata"] as? [String: Any])?["attachments"]) as? [Any])?.count ?? 0
        guard !body.isEmpty || attachmentCount > 0 else { return (400, ["code": "validation_error", "details": ["fields": [["message": "body must be non-empty"]]]]) }
        guard event["kind"] as? Int == 33358, event["content"] as? String == body else {
            return (400, ["code": "validation_error", "details": ["fields": [["message": "message_signature does not match body"]]]])
        }
        return lock.withLock {
            if _rejectNext {
                _rejectNext = false
                return (400, ["code": "validation_error", "details": ["fields": [["message": "sample rejection requested in Settings"]]]])
            }
            let requestId = object["client_request_id"] as? String
            if let requestId, let prior = requests[requestId] { return (200, ["message": prior, "replayed": true, "created": false]) }
            let id = UUID().uuidString.lowercased()
            let threadId = (object["thread_id"] as? String) ?? UUID().uuidString.lowercased()
            let source: Any = object["thread_id"] == nil ? id
                : (allMessages().first { $0["thread_id"] as? String == threadId && $0["id"] as? String == $0["thread_source_message_id"] as? String }?["id"] ?? NSNull())
            let now = ISO8601DateFormatter.fixture.string(from: Date())
            let attachments = ((object["metadata"] as? [String: Any])?["attachments"] as? [[String: Any]]) ?? []
            let row: [String: Any] = ["id": id, "workspace_id": w, "channel_id": c, "thread_id": threadId, "thread_source_message_id": source,
                                      "body": body, "client_request_id": requestId ?? NSNull(), "record_state": "active", "row_version": 1,
                                      "sender_npub": _actor, "created_by_actor_label": "You (sample identity)", "created_at": now, "updated_at": now,
                                      "attachments": attachments, "metadata": ["attachments": attachments]]
            posted.append(row)
            if let requestId { requests[requestId] = row }
            emitLocked(workspace: w, channel: c, type: "message", id: id, rowVersion: 1)
            persist()
            var reply = row
            reply["thread_source_message_id"] = nil   // like Tower's create reply
            return (201, ["message": reply, "created": true, "replayed": false])
        }
    }

    static func eventCursor(_ row: Int) -> String { Data("fixture-event:\(row)".utf8).base64EncodedString() }
    static func eventRow(_ cursor: String?) -> Int? {
        guard let cursor else { return 0 }
        guard let text = Data(base64Encoded: cursor).map({ String(decoding: $0, as: UTF8.self) }), text.hasPrefix("fixture-event:") else { return nil }
        return Int(text.dropFirst("fixture-event:".count))
    }

    /// Appends an event; the caller holds `lock`.
    private func emitLocked(workspace: String, channel: String?, type: String, id: String?, rowVersion: Int?, operation: String = "created") {
        let row = eventLog.count + 1
        eventLog.append(["id": UUID().uuidString.lowercased(), "cursor": Self.eventCursor(row), "row_version": row, "workspace_id": workspace,
                         "scope_id": NSNull(), "channel_id": channel ?? NSNull(), "entity_type": type, "entity_id": id ?? NSNull(),
                         "operation": operation, "entity_row_version": rowVersion ?? NSNull(), "payload": [:], "event_type": "flightdeck_pg.\(type).\(operation)"])
    }

    func events(workspace: String, after row: Int, limit: Int) -> [[String: Any]] {
        lock.withLock { Array(eventLog.filter { ($0["workspace_id"] as? String) == workspace && ($0["row_version"] as! Int) > row }.prefix(limit)) }
    }

    var eventHead: Int { lock.withLock { eventLog.count } }

    /// Another member (Ana) posts a new conversation, as if from another device.
    func postAsMember(channel: String, body: String) {
        lock.withLock {
            let id = UUID().uuidString.lowercased()
            let now = ISO8601DateFormatter.fixture.string(from: Date())
            posted.append(["id": id, "workspace_id": Self.studio, "channel_id": channel, "thread_id": UUID().uuidString.lowercased(),
                           "thread_source_message_id": id, "body": body, "client_request_id": NSNull(), "record_state": "active", "row_version": 1,
                           "sender_npub": Self.ana, "created_by_actor_label": "Ana", "created_at": now, "updated_at": now])
            emitLocked(workspace: Self.studio, channel: channel, type: "message", id: id, rowVersion: 1)
            persist()
        }
    }

    /// Author-only edit (row_version and a kind 33358 revision signature with `message_id` and `revision`), and delete.
    private func revise(_ request: URLRequest, id: String, query: [URLQueryItem]) throws -> (Int, Any) {
        let object = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        return lock.withLock {
            guard var row = allMessages().first(where: { $0["id"] as? String == id }), row["record_state"] as? String != "deleted" else {
                return (404, ["code": "message_not_found"])
            }
            let version = row["row_version"] as? Int ?? 1
            if request.httpMethod == "DELETE" {
                if let q = query.first(where: { $0.name == "row_version" })?.value, Int(q) != version { return (409, ["code": "stale_row_version"]) }
                row["record_state"] = "deleted"; row["body"] = ""; row["row_version"] = version + 1
            } else {
                guard row["sender_npub"] as? String == _actor else { return (403, ["code": "message_author_required"]) }
                guard object["row_version"] as? Int == version else { return (409, ["code": "stale_row_version"]) }
                let body = (object["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let event = ((object["message_signature"] as? [String: Any])?["nostr_event"] as? [String: Any]) ?? [:]
                let tags = (event["tags"] as? [[String]]) ?? []
                guard event["kind"] as? Int == 33358, event["content"] as? String == body, tags.contains(["message_id", id]),
                      tags.contains(["revision", String(version + 1)]) else {
                    return (400, ["code": "validation_error", "details": ["fields": [["message": "message_signature does not match the revision"]]]])
                }
                row["body"] = body; row["row_version"] = version + 1
                row["updated_at"] = ISO8601DateFormatter.fixture.string(from: Date())
            }
            revised[id] = row
            persist()
            return (200, ["message": row])
        }
    }

    /// An agent-style reply with the Markdown the web renders: heading, list, code, table, link and a mention.
    static let richMessage = """
    ## Build checklist
    @[Ana](mention:person:\(FixtureTower.ana)) the **native** pass is _ready_:

    1. Open the channel
    2. Check `swift test`
       - nested item

    ```sh
    xcodebuild -scheme Ambulando test
    ```

    | Surface | State |
    | --- | --- |
    | Chat | Markdown |
    | Docs | Images |

    > Notes from [the web app](https://example.invalid/notes)
    """

    /// Sample tasks, documents, files and inbox items, created once per fixture directory.
    func seedWorkIfNeeded() {
        guard !work.seeded() else { return }
        let me = actorNpub, w = work
        let general = Self.generalChannel, design = Self.designChannel, deploys = Self.deploysChannel
        let a = Self.scopeAmbulando, ops = Self.scopeOps
        let review = w.seedTask(scope: a, channel: general, title: "Review the native inbox", description: "Check read and done behave like the web inbox.",
                                state: "review", priority: "rock", assignee: me, creator: Self.ana)
        w.seedTask(scope: a, channel: general, title: "Write release notes for build 3", state: "in_progress", priority: "pebble", assignee: Self.rick, creator: Self.ana)
        w.seedTask(scope: a, channel: design, title: "Passage mark spacing", description: "Keep the white backing.", state: "ready", creator: Self.rick)
        w.seedTask(scope: a, channel: design, title: "Dark mode contrast pass", state: "new", creator: me)
        w.seedTask(scope: ops, channel: deploys, title: "Rotate staging certificates", state: "blocked", priority: "rock", creator: Self.rick)
        w.seedTask(scope: a, channel: general, title: "Archive old sync notes", state: "done", creator: Self.ana)
        w.seedTaskComment(task: review, body: "Assigned to you for the phone pass.", sender: Self.ana)

        let rich = Self.richDocument()
        let plan = w.seedDoc(scope: a, channel: general, title: "Native app plan", body: rich, contentType: DocumentBody.envelopeContentType)
        // Debug sample switch: another member holds the plan's edit lease.
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureDocLeaseHeld") { w.holdLease(doc: plan, by: Self.rick) }
        w.seedDoc(scope: a, channel: design, title: "Theme notes (Markdown)", body: Data("# Theme notes\n\nThe primary colour is **deep purple**.\n\n- Light\n- Dark".utf8),
                  contentType: "text/markdown")
        let folder = w.seedFolder(channel: general, scope: a, title: "Reports")
        w.seedFile(channel: general, scope: a, name: "sync-results.txt", bytes: Data("Sync storm: 20,000 rows, no dropped keystrokes.\n".utf8), contentType: "text/plain")
        w.seedFile(channel: general, scope: a, name: "q3-summary.csv", bytes: Data("week,tasks\n1,12\n2,9\n".utf8), contentType: "text/csv", folder: folder)
        if let png = Self.samplePNG() {
            w.seedFile(channel: design, scope: a, name: "palette.png", bytes: png, contentType: "image/png")
            // A Markdown document with a stored image (served by the sample storage route, loaded like any other object).
            let image = w.seedObject(png, contentType: "image/png", name: "board.png")
            let markdown = "# Release board\n\nThe palette as it ships:\n\n![Palette board](storage://\(image))\n\n| Step | Owner |\n| --- | --- |\n| Build | Rick |\n| Review | Ana |\n"
            w.seedDoc(scope: a, channel: design, title: "Release board (Markdown)", body: Data(markdown.utf8), contentType: "text/markdown")
        }

        w.seedViewState(type: "task", resource: review, scope: a, channel: general, activity: 3, viewed: 1, attention: 3)
        w.seedViewState(type: "document", resource: plan, scope: a, channel: general, activity: 2, viewed: 1)
        w.seedViewState(type: "thread", resource: Self.uuid(39, "f1c7bbbb"), scope: a, channel: general, activity: 4, viewed: 2)
        w.markSeeded()
    }

    static let canvasDoc = "f1c70000-0000-4000-8000-0000000000d7"
    static let canvasTask = "f1c70000-0000-4000-8000-0000000000e7"
    static let boardFile = "f1c70000-0000-4000-8000-0000000000f7"
    static let boardVersion = "f1c70000-0000-4000-8000-0000000000f8"
    static let lockedFile = "f1c70000-0000-4000-8000-0000000000f9"

    /// Sample Context Tree, canvases (with every naplet kind, a board and a locked item), agents, WApps and pins, created
    /// once per fixture directory. Shapes follow Tower's serializers; it is still sample data, never evidence of Tower.
    func seedSurfacesIfNeeded() {
        let s = surfaces
        guard !s.seeded() else { return }
        let a = Self.scopeAmbulando, general = Self.generalChannel, design = Self.designChannel
        let thread = Self.uuid(39, "f1c7bbbb")
        // Records the surfaces point at, in the sample task/document routes too.
        let notes = "# Build 7 launch notes\n\nContext Tree, Canvas, agents and the Toolbox are native on iPhone.\n\n- Pins sync with the web\n- Boards are read only"
        work.seedDoc(id: Self.canvasDoc, scope: a, channel: general, title: "Build 7 launch notes", body: Data(notes.utf8), contentType: "text/markdown")
        work.seedTask(id: Self.canvasTask, scope: a, channel: general, title: "Ship build 7 to TestFlight-free phone", state: "ready", priority: "rock", creator: Self.ana)
        s.seedRecord(id: Self.canvasDoc, type: "document", title: "Build 7 launch notes", channel: general, scope: a)
        s.seedRecord(id: Self.canvasTask, type: "task", title: "Ship build 7 to TestFlight-free phone", channel: general, scope: a)
        s.seedRecord(id: thread, type: "thread", title: "Native chat review", channel: general, scope: a)
        s.seedRecord(id: design, type: "channel", title: "design", channel: design, scope: a)
        s.seedRecord(id: Self.lockedFile, type: "file", title: "Board-only budget", channel: design, scope: a)
        s.deny(record: Self.lockedFile)

        // Context Tree for the Ambulando scope.
        let root = s.seedComponent(scope: a, title: "Native iPhone app", sortOrder: 0)
        let sync = s.seedComponent(scope: a, title: "Sync and storage", parent: root, sortOrder: 0)
        let surfacesNode = s.seedComponent(scope: a, title: "Workspace surfaces", parent: root, sortOrder: 1)
        s.seedComponent(scope: a, title: "Release", sortOrder: 1)
        s.seedReference(component: sync, type: "doc", recordId: Self.canvasDoc, sortOrder: 0)
        s.seedReference(component: surfacesNode, type: "task", recordId: Self.canvasTask, sortOrder: 0)
        s.seedReference(component: surfacesNode, type: "file", recordId: Self.lockedFile, sortOrder: 1)
        s.seedReference(component: surfacesNode, type: "artifact", artifact: ["origin": "https://artifacts.sample.invalid", "project": "Wingman_Suite",
                                                                            "artifact": "wingman-suite-arch", "page": "index.html", "version_policy": "latest"], sortOrder: 2)

        // Canvas with every naplet kind this app draws, a board and a locked item.
        let launch = s.seedCanvas(title: "Launch board", position: 1, viewport: ["x": 0, "y": 0, "scale": 1])
        s.seedCanvas(title: "Retro", position: 2)
        s.seedNaplet(canvas: launch, sourceType: "document", sourceId: Self.canvasDoc, title: "Build 7 launch notes",
                     layout: ["x": 40, "y": 80, "width": 360, "height": 260, "z": 1],
                     content: ["title": "Build 7 launch notes", "body": notes, "updated_at": "2026-10-24T09:00:00.000Z"])
        s.seedNaplet(canvas: launch, sourceType: "task_list", sourceId: general, title: "General tasks",
                     layout: ["x": 440, "y": 80, "width": 320, "height": 260, "z": 2],
                     content: ["tasks": [["id": Self.canvasTask, "title": "Ship build 7 to TestFlight-free phone", "state": "ready"]]])
        s.seedNaplet(canvas: launch, sourceType: "chat_thread", sourceId: thread, title: "Native chat review",
                     layout: ["x": 40, "y": 380, "width": 360, "height": 280, "z": 3],
                     content: ["messages": [["id": Self.uuid(100, "f1c7aaaa"), "author": "Rick", "body": "Looks right on my phone", "created_at": Self.time(100)],
                                            ["id": Self.uuid(101, "f1c7aaaa"), "author": "Ana", "body": "Retry kept the same request id", "created_at": Self.time(101)]]])
        let board = Self.sampleBoard()
        let projection = s.seedBoardVersion(fileId: Self.boardFile, versionId: Self.boardVersion, versionNumber: 2, bytes: board)
        boards.seed(fileId: Self.boardFile, bytes: board, canWrite: true, author: Self.ana)
        s.seedNaplet(canvas: launch, sourceType: "task_tree", sourceId: general, title: "Task Tree",
                     layout: ["x": 40, "y": 740, "width": 820, "height": 440, "z": 9],
                     content: ["channel_id": general, "scope_id": a, "channel_title": "general", "can_create": true])
        s.seedNaplet(canvas: launch, sourceType: "excalidraw", sourceId: Self.boardFile, title: "Architecture sketch",
                     layout: ["x": 440, "y": 380, "width": 420, "height": 300, "z": 4], content: projection)
        s.seedNaplet(canvas: launch, sourceType: "document", sourceId: Self.lockedFile, title: "Budget",
                     layout: ["x": 900, "y": 80, "width": 240, "height": 180, "z": 5], content: ["body": "not for this viewer"])
        s.seedNaplet(canvas: launch, sourceType: "html", sourceId: UUID().uuidString.lowercased(), title: "Status page",
                     layout: ["x": 900, "y": 300, "width": 260, "height": 200, "z": 6],
                     content: ["html": "<h1>Status</h1><p>All green.</p><p id='bridge'></p><script>document.getElementById('bridge').textContent = 'Sandbox nostr: ' + typeof window.nostr;</script><a href='https://browser.sample.invalid/naplet' target='_blank'>Open signed browser</a>", "version_number": 1])
        s.seedElement(canvas: launch, kind: "text", layout: ["x": 40, "y": 20, "width": 400, "height": 40, "z": 7], data: ["text": "Build 7 launch", "fontSize": 28])
        s.seedElement(canvas: launch, kind: "arrow", layout: ["x": 400, "y": 200, "width": 40, "height": 10, "z": 8], data: ["start": [0, 5], "end": [40, 5]])
        s.seedElement(canvas: launch, kind: "rectangle", layout: ["x": 20, "y": 60, "width": 860, "height": 640, "z": 0], data: [:])

        // Agents and their activity in #general.
        s.seedAgent(npub: Self.rick, name: "Rick", sortOrder: 1)
        // A second launcher agent, so the Mac Deck's My Agents stack has a card behind the top one.
        s.seedAgent(npub: Self.brick, name: "Brick", sortOrder: 2, avatarURL: FixtureProfileSource.host + "brick.png")
        s.seedActivity(channel: general, scope: a, thread: thread, agent: Self.rick, state: "working", label: "Checking the outbox retry states")
        s.seedActivity(channel: general, scope: a, thread: thread, agent: Self.rick, state: "completed", label: "Answered the theme question")

        // Toolbox and pins.
        // Launcher logos: a cached sample image, a missing one (favicon fallback that fails) and one that is not an image.
        s.seedWapp(title: "Timesheets", launchURL: "https://timesheets.sample.invalid/", description: "Log time against tasks",
                   iconURL: FixtureProfileSource.host + "timesheets.png", sortOrder: 1, owner: Self.ana)
        s.seedWapp(title: "Legacy tool", launchURL: "http://legacy.sample.invalid/", description: "Served without HTTPS", sortOrder: 2, owner: Self.ana)
        // Served from memory by the browser's sample page (`browserSample`), so launching it can use `window.nostr` offline.
        s.seedWapp(title: "Sample Artifacts", launchURL: "https://browser.sample.invalid/apps/artifacts", description: "A Nostr web app", sortOrder: 3, owner: Self.rick)
        s.seedWapp(title: "Field Notes", launchURL: "https://fieldnotes.sample.invalid/", description: "Notes from site visits",
                   iconURL: FixtureProfileSource.host + "broken.png", sortOrder: 4, owner: Self.ana)
        s.externalPin(type: "thread", resource: thread, pinned: true)
        s.externalPin(type: "channel", resource: design, pinned: true)
        s.markSeeded()
    }

    /// A small Excalidraw scene: three boxes, arrows, text and one embeddable (listed as not drawn).
    static func sampleBoard() -> Data {
        func element(_ id: String, _ type: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["id": id, "type": type, "x": x, "y": y, "width": w, "height": h, "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
             "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid", "roughness": 1, "opacity": 100, "version": 1, "isDeleted": false].merging(extra) { _, b in b }
        }
        let elements: [[String: Any]] = [
            element("tower", "rectangle", 0, 0, 180, 80, ["backgroundColor": "#d0bfff", "roundness": ["type": 3]]),
            element("tower-text", "text", 20, 28, 140, 25, ["text": "Tower", "fontSize": 20, "textAlign": "center", "containerId": "tower"]),
            element("sync", "rectangle", 260, 0, 180, 80, ["backgroundColor": "#a5d8ff", "fillStyle": "hachure"]),
            element("sync-text", "text", 280, 28, 140, 25, ["text": "Sync engine", "fontSize": 20, "textAlign": "center", "containerId": "sync"]),
            element("store", "ellipse", 260, 160, 180, 90, ["backgroundColor": "#b2f2bb"]),
            element("store-text", "text", 280, 192, 140, 25, ["text": "SQLite", "fontSize": 20, "textAlign": "center", "containerId": "store"]),
            element("a1", "arrow", 180, 40, 80, 0, ["points": [[0, 0], [80, 0]], "endArrowhead": "arrow"]),
            element("a2", "arrow", 350, 80, 0, 80, ["points": [[0, 0], [0, 80]], "endArrowhead": "triangle", "strokeStyle": "dashed"]),
            element("note", "text", 0, 120, 220, 50, ["text": "Screens read only\nfrom SQLite", "fontSize": 16]),
            element("embed", "embeddable", 0, 200, 200, 100, ["link": "https://example.invalid/video"]),
        ]
        let scene: [String: Any] = ["type": "excalidraw", "version": 2, "source": "wingman-ambulando", "elements": elements, "appState": [:], "files": [:]]
        return (try? JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys])) ?? Data()
    }

    /// A web-format document (ProseMirror authoritative) with marks, a task list, a link, a table and a node this app
    /// does not know, so the reader and editor are exercised on real structure.
    static func richDocument() -> Data {
        func t(_ s: String, _ marks: [String] = []) -> JSONValue {
            var pairs: [(String, JSONValue)] = [("type", .string("text")), ("text", .string(s))]
            if !marks.isEmpty { pairs.append(("marks", .array(marks.map { .object([("type", .string($0))]) }))) }
            return .object(pairs)
        }
        func block(_ type: String, _ id: String, _ content: [JSONValue], attrs: [(String, JSONValue)] = []) -> JSONValue {
            .object([("type", .string(type)), ("attrs", .object([("fdBlockId", .string(id))] + attrs)), ("content", .array(content))])
        }
        func para(_ content: [JSONValue]) -> JSONValue { .object([("type", .string("paragraph")), ("content", .array(content))]) }
        let link = JSONValue.object([("type", .string("text")), ("text", .string("web inbox")),
                                     ("marks", .array([.object([("type", .string("link")), ("attrs", .object([("href", .string("https://browser.sample.invalid/document"))]))])]))])
        let task: (Bool, String) -> JSONValue = { checked, label in
            .object([("type", .string("taskItem")), ("attrs", .object([("checked", .bool(checked))])), ("content", .array([para([t(label)])]))])
        }
        let cell: (String) -> JSONValue = { .object([("type", .string("tableCell")), ("content", .array([para([t($0)])]))]) }
        let state = JSONValue.object([("type", .string("doc")), ("content", .array([
            block("heading", "pm_plan_h1", [t("Native app plan")], attrs: [("level", .int(1))]),
            block("paragraph", "pm_plan_p1", [t("Every screen reads from "), t("local storage", ["bold"]), t(", and sync runs "), t("off the main thread", ["italic"]), t(".")]),
            block("paragraph", "pm_plan_p2", [t("Compare with the "), link, t(" before release.")]),
            block("taskList", "pm_plan_tl", [task(true, "Chat and outbox"), task(false, "Tasks, docs, files and inbox")]),
            block("table", "pm_plan_tb", [.object([("type", .string("tableRow")), ("content", .array([cell("Surface"), cell("State")]))]),
                                          .object([("type", .string("tableRow")), ("content", .array([cell("Docs"), cell("Native")]))])]),
            .object([("type", .string("fdCalloutWidget")), ("attrs", .object([("fdBlockId", .string("pm_plan_w1")), ("tone", .string("info"))]))]),
            block("paragraph", "pm_plan_p3", [t("Edit this paragraph on the phone.")]),
        ]))])
        let model = JSONValue.object(ProseMirrorMarkdown.contentModelFields(state))
        return JSONValue.object([("format", .string(DocumentBody.envelopeFormat)), ("content_model", model)]).serialized()
    }

    static func samplePNG() -> Data? {
        #if os(macOS)
        return png(width: 96, height: 64) { context in
            context.setFillColor(CGColor(red: 0.17, green: 0.11, blue: 0.24, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 48, height: 64))
            context.setFillColor(CGColor(red: 0.75, green: 0.30, blue: 0.05, alpha: 1)); context.fill(CGRect(x: 48, y: 0, width: 48, height: 64))
        }
        #else
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64))
        let image = renderer.image { context in
            UIColor(red: 0.17, green: 0.11, blue: 0.24, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 48, height: 64))
            UIColor(red: 0.75, green: 0.30, blue: 0.05, alpha: 1).setFill(); context.fill(CGRect(x: 48, y: 0, width: 48, height: 64))
        }
        return image.pngData()
        #endif
    }

    /// A PNG drawn with Core Graphics (the Mac build's stand-in for UIGraphicsImageRenderer; origin bottom-left).
    static func png(width: Int, height: Int, draw: (CGContext) -> Void) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(context)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func workspace(_ id: String, _ label: String) -> [String: Any] {
        ["identity": ["workspace_id": id, "app_npub": Self.appNpub, "workspace_owner_npub": Self.ana], "label": label, "slug": label.lowercased(),
         "tower_base_url": FixtureEnvironment.origin, "membership": ["role": "member"]]
    }
    private func scope(_ id: String, _ w: String, _ name: String) -> [String: Any] {
        ["id": id, "workspace_id": w, "name": name, "kind": "project", "row_version": 1, "updated_at": "2026-10-01T00:00:00.000Z"]
    }
    private func channel(_ id: String, _ w: String, _ s: String, _ name: String, _ position: Double) -> [String: Any] {
        ["id": id, "workspace_id": w, "scope_id": s, "name": name, "kind": "channel", "position": position, "row_version": 1, "updated_at": "2026-10-01T00:00:00.000Z"]
    }
    private func member(_ npub: String, _ name: String?, _ kind: String) -> [String: Any] {
        ["actor": ["actor_id": UUID().uuidString.lowercased(), "npub": npub, "kind": kind, "display_name": name.map { $0 as Any } ?? NSNull()]]
    }
    private func thread(for root: [String: Any]) -> [String: Any] {
        ["id": root["thread_id"]!, "workspace_id": root["workspace_id"]!, "channel_id": root["channel_id"]!, "source_message_id": root["id"]!,
         "title": MentionCodec.plain(root["body"] as? String ?? ""), "record_state": "active", "row_version": 1, "updated_at": root["updated_at"]!]
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fixture: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// SSE stand-in for sample-data mode: speaks the same frames as Tower's `/events/stream` (connected, events with ids,
/// heartbeat comments), reading the fixture event log. Requests must be NIP-98 signed like the real route.
final class FixtureEventStream: EventStreamTransport, @unchecked Sendable {
    let tower: FixtureTower
    init(tower: FixtureTower) { self.tower = tower }

    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, EventChunks) {
        if tower.offline { throw URLError(.notConnectedToInternet) }
        let url = request.url!
        let authorized = request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Nostr ") == true
        let parts = url.path.split(separator: "/").map(String.init)
        let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
        let status = !authorized ? 401 : (parts.count >= 6 && parts.last == "stream" ? (FixtureTower.eventRow(cursor) == nil ? 400 : 200) : 404)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        let workspace = parts.count >= 5 ? parts[4] : ""
        let tower = self.tower
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                guard status == 200, var after = FixtureTower.eventRow(cursor) else { continuation.finish(); return }
                continuation.yield(Data("event: connected\ndata: {\"cursor\":\"\(cursor ?? "")\",\"poll_ms\":1000}\n\n".utf8))
                var beats = 0
                while !Task.isCancelled {
                    if tower.offline { continuation.finish(throwing: URLError(.networkConnectionLost)); return }
                    for event in tower.events(workspace: workspace, after: after, limit: 50) {
                        let data = (try? JSONSerialization.data(withJSONObject: event)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        after = event["row_version"] as? Int ?? after
                        continuation.yield(Data("id: \(after)\nevent: flightdeck_pg.event\ndata: \(data)\n\n".utf8))
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    beats += 1
                    if beats % 20 == 0 { continuation.yield(Data(": heartbeat\n\n".utf8)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (response, EventChunks(stream))
    }
}

/// Sample public profiles (sample-data mode only). Real profiles are signed relay events checked by
/// `ProfileEventFilter`; these are synthetic records for synthetic people, so there is nothing to verify.
final class FixtureProfileSource: ProfileSource, @unchecked Sendable {
    static let host = "https://avatars.sample.invalid/"
    let tower: FixtureTower
    init(tower: FixtureTower) { self.tower = tower }

    func profiles(pubkeys: [String]) async throws -> [ProfileRecord] {
        if tower.offline { throw URLError(.notConnectedToInternet) }
        try await Task.sleep(for: .milliseconds(150))
        let me = tower.actorNpub
        let people: [String: (display: String?, name: String?, picture: String?)] = [
            me: ("Sample Explorer", "explorer", Self.host + "you.png"),
            FixtureTower.ana: ("Ana Lima", "ana", Self.host + "ana.png"),
            FixtureTower.bea: ("Bea Ortiz", "bea", Self.host + "bea.png"),
            // A profile whose picture is not an image: the app keeps Rick's initials.
            FixtureTower.rick: (nil, "rick", Self.host + "broken.png"),
        ]
        let now = Date()
        return pubkeys.compactMap { pubkey in
            guard let npub = NostrKeys.npub(publicKeyHex: pubkey), let p = people[npub] else { return nil }
            return ProfileRecord(pubkey: pubkey, npub: npub, displayName: p.display, name: p.name, picture: p.picture,
                                 eventId: SHA256Hex.of(npub), eventCreatedAt: 1_792_800_000, status: .found, checkedAt: now)
        }
    }
}

/// Sample avatar host: draws a generic two-tone badge per name; `broken.png` answers bytes that are not an image.
final class FixtureAvatarTransport: AvatarTransport, @unchecked Sendable {
    let tower: FixtureTower
    init(tower: FixtureTower) { self.tower = tower }

    func fetch(_ url: URL, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        if tower.offline { throw URLError(.notConnectedToInternet) }
        guard url.host == "avatars.sample.invalid" else { throw URLError(.cannotFindHost) }
        try await Task.sleep(for: .milliseconds(120))
        let name = url.deletingPathExtension().lastPathComponent
        let data = name == "broken" ? Data("not an image".utf8) : Self.badge(name)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        return (data, response)
    }

    static func badge(_ name: String) -> Data {
        #if os(macOS)
        let palette: [String: (CGColor, CGColor)] = [
            "you": (CGColor(red: 0.13, green: 0.36, blue: 0.52, alpha: 1), CGColor(red: 0.68, green: 0.82, blue: 0.94, alpha: 1)),
            "ana": (CGColor(red: 0.75, green: 0.30, blue: 0.05, alpha: 1), CGColor(red: 1.00, green: 0.80, blue: 0.62, alpha: 1)),
            "bea": (CGColor(red: 0.15, green: 0.38, blue: 0.24, alpha: 1), CGColor(red: 0.64, green: 0.82, blue: 0.71, alpha: 1)),
        ]
        let (dark, light) = palette[name] ?? (CGColor(gray: 0.33, alpha: 1), CGColor(gray: 0.67, alpha: 1))
        return FixtureTower.png(width: 256, height: 256) { context in
            context.setFillColor(dark); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(light)
            context.fillEllipse(in: CGRect(x: 64, y: 256 - 40 - 128, width: 128, height: 128))
            context.fillEllipse(in: CGRect(x: 24, y: 256 - 168 - 176, width: 208, height: 176))
        } ?? Data()
        #else
        let palette: [String: (UIColor, UIColor)] = [
            "you": (UIColor(red: 0.13, green: 0.36, blue: 0.52, alpha: 1), UIColor(red: 0.68, green: 0.82, blue: 0.94, alpha: 1)),
            "ana": (UIColor(red: 0.75, green: 0.30, blue: 0.05, alpha: 1), UIColor(red: 1.00, green: 0.80, blue: 0.62, alpha: 1)),
            "bea": (UIColor(red: 0.15, green: 0.38, blue: 0.24, alpha: 1), UIColor(red: 0.64, green: 0.82, blue: 0.71, alpha: 1)),
        ]
        let (dark, light) = palette[name] ?? (.darkGray, .lightGray)
        let size = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            dark.setFill(); context.fill(CGRect(origin: .zero, size: size))
            light.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 64, y: 40, width: 128, height: 128))
            context.cgContext.fillEllipse(in: CGRect(x: 24, y: 168, width: 208, height: 176))
        }
        return image.pngData() ?? Data()
        #endif
    }
}
