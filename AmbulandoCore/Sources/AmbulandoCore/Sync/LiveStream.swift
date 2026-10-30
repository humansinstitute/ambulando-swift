import Foundation

/// Foreground live updates for one workspace over Tower's SSE route.
///
/// Each connection attempt: (1) a bounded event catch-up from the stored cursor through the `events:<w>` job, (2) the
/// stream opened at the resulting cursor with a fresh NIP-98 header, (3) received events queued on the workspace's
/// `LiveFeed` and applied in ≤ 250 ms batches by the same job, which saves the cursor only after a batch is stored.
/// A dropped or silent connection (no heartbeat for `idleTimeout`) reconnects with backoff and resumes from the stored
/// cursor. The stream runs only while the app is active; iOS does not keep it open in the background.
public actor LiveStream {
    public typealias Opener = @Sendable (URLRequest) async throws -> (HTTPURLResponse, EventChunks)

    let sync: WorkspaceSync
    let open: Opener
    let idleTimeout: Duration
    let batchWindow: Duration
    let reconciliationInterval: Duration
    let random: @Sendable () -> Double
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var current: (connection: String, workspace: String)?

    public init(sync: WorkspaceSync, transport: EventStreamTransport, idleTimeout: Duration = .seconds(60), batchWindow: Duration = .milliseconds(250),
                reconciliationInterval: Duration = .seconds(60),
                random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.sync = sync
        self.open = { try await transport.open($0) }
        self.idleTimeout = idleTimeout
        self.batchWindow = batchWindow
        self.reconciliationInterval = max(.milliseconds(100), reconciliationInterval)
        self.random = random
    }

    public var isRunning: Bool { task != nil }
    public var workspaceId: String? { current?.workspace }

    /// Starts (or keeps) the stream for this workspace; any other workspace's stream is stopped first.
    public func start(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord) async {
        if let current, current == (connection.id, workspace.id), task != nil { return }
        await stop()
        generation &+= 1
        let gen = generation
        current = (connection.id, workspace.id)
        let activity = sync.engine.activity
        guard let lease = try? activity.lease() else { current = nil; return }
        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await activity.withLease(lease) { await self.run(connection, workspace, gen) }
        }
    }

    public func stop() async {
        guard let task else { return }
        task.cancel()
        self.task = nil
        if let workspace = current?.workspace {
            let feed = await sync.live.feed(workspace)
            await feed.reset()
            await feed.update { $0.stream = .stopped }
        }
        current = nil
    }

    private func run(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, _ gen: UInt64) async {
        let feed = await sync.live.feed(workspace.id)
        var failures = 0
        while !Task.isCancelled, gen == generation {
            do {
                try await sync.identity.requireReader(npub: connection.signerNpub)
            } catch {
                await feed.update { $0.stream = .locked }
                return   // restarted on unlock
            }
            await feed.update { $0.stream = failures == 0 ? .connecting : .reconnecting }
            do {
                let (outcome, didConnect) = try await connectOnce(connection, workspace, feed: feed)
                if didConnect { failures = 0 }
                if outcome == .accessLost {
                    await feed.update { $0.stream = .accessLost }
                    await sync.discover(connection, priority: .background, force: true)
                    return
                }
            } catch {
                // Only a cancelled stream stops; any other failure (including a cancelled job) reconnects.
                if Task.isCancelled || gen != generation { return }
                await feed.update { $0.lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error) }
            }
            if Task.isCancelled || gen != generation { return }
            failures += 1
            await feed.update { $0.stream = .reconnecting }
            let wait = min(SyncBackoff.delay(failures: failures, random: random()), .seconds(60))
            try? await Task.sleep(for: wait)
        }
    }

    enum Outcome { case ended, accessLost, reconnect }

    private func connectOnce(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, feed: LiveFeed) async throws -> (Outcome, Bool) {
        // 1. Bounded catch-up (seeds the cursor on first use, handles gaps), so the stream starts near the head.
        let catchUp = try await sync.catchUpEventsAndWait(connection, workspace, priority: .visible)
        if catchUp.accessLost { return (.accessLost, false) }
        guard let cursor = try await sync.store.reader.eventCursor(connectionId: connection.id, workspaceId: workspace.id) else { return (.reconnect, false) }
        _ = await feed.takeReconnect()
        // 2. Open the stream with a fresh signature.
        let api = sync.api(origin: try TowerOrigin(connection.origin))
        let request = try await api.streamRequest(workspaceId: workspace.id, appNpub: workspace.appNpub, cursor: cursor)
        let (response, chunks) = try await open(request)
        defer { chunks.cancel() }   // the connection never outlives this attempt
        switch response.statusCode {
        case 200: break
        case 403, 404: return (.accessLost, false)
        case 400:
            // Cursor refused: drop it so the next catch-up restarts at the head.
            try await sync.store.writer.saveEventCursor(connectionId: connection.id, workspaceId: workspace.id, nil)
            throw TowerError.http(status: 400, code: "cursor", stage: "event stream")
        default: throw TowerError.http(status: response.statusCode, code: nil, stage: "event stream")
        }
        // 3. Read frames, with an idle watchdog (Tower sends a heartbeat every 25 s).
        let activity = Activity()
        let sync = self.sync, batchWindow = self.batchWindow
        let outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { [idleTimeout] in
                while true {
                    try await Task.sleep(for: idleTimeout / 4)
                    if await activity.idle(for: idleTimeout) { return .reconnect }
                }
            }
            group.addTask { [reconciliationInterval] in
                // A heartbeat proves transport liveness, not that every authority/structure hint was delivered.
                // Reconcile readable lists while this foreground connection is alive, through the same keyed jobs.
                while true {
                    try await Task.sleep(for: reconciliationInterval)
                    try Task.checkCancellation()
                    await sync.catchUpEvents(connection, workspace, pages: 2, priority: .background)
                    await sync.refreshWorkspace(connection, workspace, priority: .background, includeDirectory: false)
                }
            }
            group.addTask {
                var parser = SSEParser()
                var previous = cursor
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    await activity.touch()
                    for frame in try parser.feed(chunk) {
                        switch frame.event {
                        case "connected":
                            await activity.markConnected()
                            await feed.update { $0.stream = .connected; $0.lastError = nil }
                        case "flightdeck_pg.event":
                            guard let data = frame.data.data(using: .utf8),
                                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let event = TowerEvent(json: object) else { continue }
                            guard event.workspaceId == workspace.id else { return .reconnect }
                            await feed.push(event, after: previous)
                            previous = event.cursor
                            await sync.scheduleEvents(connection, workspace, priority: .visible, delay: batchWindow)
                        case "flightdeck_pg.error":
                            if frame.data.contains("workspace_access_revoked") { return .accessLost }
                            return .reconnect
                        default: break
                        }
                    }
                    _ = parser.takeComments()
                    if await feed.takeReconnect() { return .reconnect }
                }
                return .reconnect   // server closed the stream
            }
            let outcome = try await group.next() ?? .reconnect
            group.cancelAll()
            return outcome
        }
        return (outcome, await activity.connected)
    }
}

actor Activity {
    private var last = ContinuousClock.now
    private(set) var connected = false
    func touch() { last = .now }
    func markConnected() { connected = true }
    func idle(for limit: Duration) -> Bool { ContinuousClock.now - last > limit }
}
