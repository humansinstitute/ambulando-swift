import XCTest
@testable import AmbulandoCore

actor Counter {
    var current = 0, peak = 0, total = 0
    var order: [String] = []
    func enter(_ name: String = "") { current += 1; total += 1; peak = max(peak, current); order.append(name) }
    func leave() { current -= 1 }
}

final class SyncEngineTests: XCTestCase {
    func testBackoffSchedule() {
        XCTAssertEqual(SyncBackoff.delay(failures: 0, random: 0.5), .zero)
        XCTAssertEqual(SyncBackoff.delay(failures: 1, random: 0.5), .seconds(2))
        XCTAssertEqual(SyncBackoff.delay(failures: 3, random: 0.5), .seconds(8))
        XCTAssertEqual(SyncBackoff.delay(failures: 20, random: 0.5), .seconds(300))
        XCTAssertEqual(SyncBackoff.delay(failures: 1, random: 0), .milliseconds(1600))
        XCTAssertEqual(SyncBackoff.delay(failures: 1, random: 1), .milliseconds(2400))
    }

    func testConcurrencyIsBounded() async {
        let engine = SyncEngine(maxConcurrent: 3)
        let counter = Counter()
        for i in 0..<20 {
            await engine.enqueue("job\(i)") {
                await counter.enter()
                try await Task.sleep(for: .milliseconds(10))
                await counter.leave()
            }
        }
        await engine.waitUntilIdle()
        let peak = await counter.peak, total = await counter.total
        XCTAssertEqual(total, 20)
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1, "jobs do run concurrently")
    }

    func testDuplicateKeysCoalesceWithOneRerun() async {
        let engine = SyncEngine(maxConcurrent: 2)
        let counter = Counter()
        let gate = AsyncStream<Void>.makeStream()
        await engine.enqueue("scopes:w") {
            await counter.enter()
            for await _ in gate.stream { break }
        }
        try? await Task.sleep(for: .milliseconds(20))
        for _ in 0..<5 { await engine.enqueue("scopes:w") { await counter.enter() } }
        let snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.running, ["scopes:w"])
        gate.continuation.yield()
        await engine.waitUntilIdle()
        let total = await counter.total
        XCTAssertEqual(total, 2, "first run plus exactly one rerun for the five mid-flight requests")
    }

    func testVisibleWorkRunsBeforeBackgroundCatchUp() async {
        let engine = SyncEngine(maxConcurrent: 1)
        let counter = Counter()
        let gate = AsyncStream<Void>.makeStream()
        await engine.enqueue("blocker") { for await _ in gate.stream { break } }
        try? await Task.sleep(for: .milliseconds(10))
        for i in 0..<3 { await engine.enqueue("bg\(i)", priority: .background) { await counter.enter("bg\(i)"); await counter.leave() } }
        await engine.enqueue("visible", priority: .visible) { await counter.enter("visible"); await counter.leave() }
        gate.continuation.yield()
        await engine.waitUntilIdle()
        let order = await counter.order
        XCTAssertEqual(order, ["visible", "bg0", "bg1", "bg2"])
    }

    func testCancelAllStopsRunningAndQueuedWork() async {
        let engine = SyncEngine(maxConcurrent: 2, reservedForeground: 0)
        let counter = Counter()
        for i in 0..<10 {
            await engine.enqueue("long\(i)") {
                await counter.enter()
                try await Task.sleep(for: .seconds(30))
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        let clock = ContinuousClock(), start = clock.now
        await engine.cancelAll()
        await engine.waitUntilIdle()
        XCTAssertLessThan(clock.now - start, .seconds(1))
        let started = await counter.total
        XCTAssertEqual(started, 2, "queued jobs never started")
        let snapshot = await engine.snapshot
        XCTAssertTrue(snapshot.isIdle)
        XCTAssertTrue(snapshot.errors.isEmpty, "cancellation is not a failure")
    }

    func testFailureBacksOffAndForceBypasses() async {
        let engine = SyncEngine(maxConcurrent: 1, random: { 0.5 })
        let counter = Counter()
        struct Boom: Error {}
        await engine.enqueue("flaky") { await counter.enter(); throw Boom() }
        await engine.waitUntilIdle()
        let failures = await engine.failureCount("flaky")
        XCTAssertEqual(failures, 1)
        let errored = await engine.snapshot.errors["flaky"]
        XCTAssertNotNil(errored)

        // Within the 2 s backoff a normal enqueue waits…
        await engine.enqueue("flaky") { await counter.enter() }
        try? await Task.sleep(for: .milliseconds(100))
        var total = await counter.total
        XCTAssertEqual(total, 1)
        // …but an explicit user refresh runs now and clears the error on success.
        await engine.enqueue("flaky", force: true) { await counter.enter() }
        await engine.waitUntilIdle()
        total = await counter.total
        let cleared = await engine.snapshot.errors["flaky"]
        XCTAssertEqual(total, 2)
        XCTAssertNil(cleared)
    }
}

final class WorkspaceSyncTests: XCTestCase {
    /// Tower double answering the routes the WP2 read path uses, with the same JSON shapes Tower serializes.
    func towerRoutes(origin: String = "https://tower.example") -> StubTransport.Handler {
        return { request in
            let path = request.url!.path
            if path == "/.well-known/nstack.json" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "descriptor read is unauthenticated")
                return (200, Fixtures.descriptor(origin: origin))
            }
            guard request.value(forHTTPHeaderField: "Authorization") != nil else { return (401, ["code": "unauthorized"]) }
            switch path {
            case "/api/v4/flightdeck-pg/workspaces":
                return (200, ["workspaces": [Fixtures.workspace(Fixtures.workspaceId, label: "Studio")], "next_cursor": NSNull()])
            case "/api/v4/flightdeck-pg/workspaces/\(Fixtures.workspaceId)/scopes":
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-flightdeck-pg-app-npub"), Fixtures.appNpub)
                return (200, ["scopes": [Fixtures.scope(Fixtures.scopeA, name: "Ambulando"), Fixtures.scope(Fixtures.scopeB, name: "Ops")], "next_cursor": NSNull()])
            case "/api/v4/flightdeck-pg/workspaces/\(Fixtures.workspaceId)/scopes/\(Fixtures.scopeA)/channels":
                return (200, ["scope_id": Fixtures.scopeA, "channels": [Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "features", position: 1)], "next_cursor": NSNull()])
            case "/api/v4/flightdeck-pg/workspaces/\(Fixtures.workspaceId)/scopes/\(Fixtures.scopeB)/channels":
                return (200, ["scope_id": Fixtures.scopeB, "channels": [Fixtures.channel(Fixtures.channel2, scope: Fixtures.scopeB, name: "deploys")], "next_cursor": NSNull()])
            case "/api/v4/flightdeck-pg/workspaces/\(Fixtures.workspaceId)/members":
                return (200, ["members": [Fixtures.member(TestKeys.npub, name: "Me")], "next_cursor": NSNull()])
            case "/api/v4/flightdeck-pg/workspaces/\(Fixtures.workspaceId)/me/scope-order":
                return (200, ["scope_order": ["scope_ids": [Fixtures.scopeB], "row_version": 1]])
            default:
                return (404, ["code": "not_found"])
            }
        }
    }

    func testConnectDiscoverAndMaterialiseNavigation() async throws {
        let identity = try await makeIdentity()
        let store = try LocalStore(directory: temporaryDirectory())
        let transport = StubTransport(towerRoutes())
        let sync = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity, transport: transport)

        let connection = try await sync.connect(origin: try TowerOrigin("https://tower.example"))
        XCTAssertEqual(connection.signerNpub, TestKeys.npub)
        XCTAssertEqual(connection.towerNpub, TestKeys.npub)
        await sync.discover(connection)
        await sync.engine.waitUntilIdle()

        let workspaces = try await store.reader.workspaces(connectionId: connection.id)
        XCTAssertEqual(workspaces.map(\.label), ["Studio"])
        let scopes = try await store.reader.scopes(workspaceId: Fixtures.workspaceId).map(\.name)
        XCTAssertEqual(scopes, ["Ambulando", "Ops"])
        let channels = try await store.reader.channels(workspaceId: Fixtures.workspaceId).map(\.name)
        XCTAssertEqual(Set(channels), ["features", "deploys"])
        let snapshot = await sync.engine.snapshot
        XCTAssertTrue(snapshot.errors.isEmpty, "\(snapshot.errors)")

        for request in transport.recorded where request.url!.path.hasPrefix("/api/v4/") {
            let event = try decodeAuthorization(request)
            XCTAssertTrue(SignatureVerifier.verify(event))
            XCTAssertEqual(event.pubkey, TestKeys.pubkeyHex)
            XCTAssertEqual(event.tags.first, ["u", request.url!.absoluteString])
        }
        XCTAssertEqual(transport.recorded.count, 7, "descriptor + workspaces + scopes + 2 channel lists + members + scope order")
        let members = try await store.reader.members(workspaceId: Fixtures.workspaceId)
        XCTAssertEqual(members.map(\.label), ["Me"])
        let order = ScopeOrdering.decode(try await store.reader.state(WorkspaceSync.scopeOrderKey(Fixtures.workspaceId)))
        XCTAssertEqual(order, [Fixtures.scopeB])
    }

    func testLockedIdentityRecordsErrorAndSendsNothing() async throws {
        let identity = try await makeIdentity()
        let store = try LocalStore(directory: temporaryDirectory())
        let transport = StubTransport(towerRoutes())
        let sync = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity, transport: transport)
        let connection = try await sync.connect(origin: try TowerOrigin("https://tower.example"))
        await identity.lock()
        await sync.discover(connection)
        await sync.engine.waitUntilIdle()
        let error = await sync.engine.snapshot.errors["discover:\(connection.id)"]
        XCTAssertEqual(error, IdentityError.locked.errorDescription)
        XCTAssertEqual(transport.recorded.count, 1, "only the public descriptor read happened")
    }

    func testDescriptorForDifferentOriginIsRefused() async throws {
        let identity = try await makeIdentity()
        let store = try LocalStore(directory: temporaryDirectory())
        let sync = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity, transport: StubTransport(towerRoutes(origin: "https://elsewhere.example")))
        do { _ = try await sync.connect(origin: try TowerOrigin("https://tower.example")); XCTFail() }
        catch { XCTAssertNotNil(error as? TowerError) }
        let count = try await store.reader.connections().count
        XCTAssertEqual(count, 0)
    }
}
