import XCTest
@testable import AmbulandoCore

private final class Flaky: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Error]
    private(set) var attempts = 0
    init(_ failures: [Error]) { self.failures = failures }
    func next() -> Error? { lock.withLock { attempts += 1; return failures.isEmpty ? nil : failures.removeFirst() } }
}

final class ConnectionRecoveryTests: XCTestCase {
    // MARK: Classification

    func testOnlyTransientConnectionFailuresAreConnectionLoss() {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed] {
            XCTAssertTrue(ConnectionFailure.isTransient(URLError(code)), "\(code)")
        }
        for status in [502, 503, 504] { XCTAssertTrue(ConnectionFailure.isTransient(TowerError.http(status: status, code: nil, stage: nil))) }
        XCTAssertTrue(ConnectionFailure.isTransient(NSError(domain: NSURLErrorDomain, code: -1005)))
        // Refusals and local conditions are never connection loss.
        for status in [400, 401, 403, 404, 409, 500] { XCTAssertFalse(ConnectionFailure.isTransient(TowerError.http(status: status, code: nil, stage: nil)), "\(status)") }
        XCTAssertFalse(ConnectionFailure.isTransient(IdentityError.locked))
        XCTAssertFalse(ConnectionFailure.isTransient(URLError(.cancelled)))
        XCTAssertFalse(ConnectionFailure.isTransient(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(ConnectionFailure.isTransient(TowerError.malformed("x")))
    }

    // MARK: Engine retry

    func testTransientReadFailureRetriesWithoutUserActionThenClears() async throws {
        let engine = SyncEngine(maxConcurrent: 1, random: { 0.5 })
        let flaky = Flaky([URLError(.networkConnectionLost)])
        await engine.enqueue("inbox:w", priority: .visible, retries: 2) { if let e = flaky.next() { throw e } }
        let early = await engine.snapshot
        _ = early
        await engine.waitUntilIdle()
        let snapshot = await engine.snapshot
        XCTAssertEqual(flaky.attempts, 2, "one automatic rerun")
        XCTAssertTrue(snapshot.connectionFailures.isEmpty)
        XCTAssertTrue(snapshot.errors.isEmpty)
    }

    func testRetriesAreBoundedAndFailureIsConnectionNotRawError() async {
        let engine = SyncEngine(maxConcurrent: 1, random: { 0.5 })
        let flaky = Flaky(Array(repeating: URLError(.timedOut), count: 10))
        await engine.enqueue("inbox:w", retries: 1) { if let e = flaky.next() { throw e } }
        await engine.waitUntilIdle()
        let snapshot = await engine.snapshot
        XCTAssertEqual(flaky.attempts, 2, "first try plus the bounded retry, no busy loop")
        XCTAssertEqual(snapshot.connectionFailures, ["inbox:w"])
        XCTAssertTrue(snapshot.errors.isEmpty, "no raw transport text for normal screens")
        XCTAssertTrue(snapshot.isIdle)
    }

    func testAuthFailureAndWritesAreNeverRetriedOrCalledConnectionLoss() async {
        let engine = SyncEngine(maxConcurrent: 1, random: { 0.5 })
        let auth = Flaky(Array(repeating: TowerError.http(status: 401, code: "unauthorized", stage: nil), count: 5))
        await engine.enqueue("inbox:w", retries: 3) { if let e = auth.next() { throw e } }
        let write = Flaky(Array(repeating: URLError(.timedOut), count: 5))
        await engine.enqueue("write:w") { if let e = write.next() { throw e } }   // no `retries`
        await engine.waitUntilIdle()
        let snapshot = await engine.snapshot
        XCTAssertEqual(auth.attempts, 1)
        XCTAssertNotNil(snapshot.errors["inbox:w"])
        XCTAssertFalse(snapshot.connectionFailures.contains("inbox:w"))
        XCTAssertEqual(write.attempts, 1, "a job without retries is never replayed by the engine")
        XCTAssertTrue(snapshot.connectionFailures.contains("write:w"))
    }

    func testCancelDuringScheduledRetryStopsIt() async throws {
        let engine = SyncEngine(maxConcurrent: 1, random: { 0.5 })
        let flaky = Flaky(Array(repeating: URLError(.timedOut), count: 10))
        await engine.enqueue("inbox:w", retries: 3) { if let e = flaky.next() { throw e } }
        try await Task.sleep(for: .milliseconds(200))
        var snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.scheduled, ["inbox:w"], "waiting for its backoff, not shown as syncing")
        await engine.cancel("inbox:w")
        await engine.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(2300))
        snapshot = await engine.snapshot
        XCTAssertEqual(flaky.attempts, 1)
        XCTAssertTrue(snapshot.connectionFailures.isEmpty, "a cancelled job leaves no stale connection failure")
    }

    func testRetriggerBypassesBackoffCoalescesAndClears() async throws {
        let engine = SyncEngine(maxConcurrent: 1, random: { 0.5 })
        let flaky = Flaky([URLError(.notConnectedToInternet)])
        await engine.enqueue("inbox:w") { if let e = flaky.next() { throw e } }
        await engine.waitUntilIdle()
        var failing = await engine.snapshot.connectionFailures
        XCTAssertEqual(failing, ["inbox:w"])
        // Network returns / app foregrounds: two triggers in a row run the job once.
        await engine.enqueue("inbox:w", force: true) { if let e = flaky.next() { throw e } }
        await engine.enqueue("inbox:w", force: true) { if let e = flaky.next() { throw e } }
        await engine.waitUntilIdle()
        failing = await engine.snapshot.connectionFailures
        XCTAssertTrue(failing.isEmpty)
        XCTAssertLessThanOrEqual(flaky.attempts, 3)
    }

    func testAnotherPathClearsObsoleteConnectionFailure() async {
        let engine = SyncEngine(maxConcurrent: 1, random: { 0.5 })
        await engine.enqueue("inbox:w") { throw URLError(.timedOut) }
        await engine.waitUntilIdle()
        await engine.clearConnectionFailure("inbox:w")
        let snapshot = await engine.snapshot
        XCTAssertTrue(snapshot.connectionFailures.isEmpty)
        let count = await engine.failureCount("inbox:w")
        XCTAssertEqual(count, 0)
    }

    func testEventsDescribeRetryAndRecoveryByFamilyOnly() async {
        let engine = SyncEngine(maxConcurrent: 1, random: { 0.5 })
        let events = EventBox()
        await engine.setEventHandler { events.add($0) }
        let flaky = Flaky([URLError(.timedOut)])
        await engine.enqueue("inbox:2e5caefd-secret-workspace", retries: 2) { if let e = flaky.next() { throw e } }
        await engine.waitUntilIdle()
        let seen = events.all
        XCTAssertEqual(seen.map(\.family), ["inbox", "inbox"])
        XCTAssertEqual(seen.last?.kind, .recovered(afterFailures: 1))
    }

    // MARK: Inbox end to end

    private func flakyViewStates(_ h: WorkHarness, failures: [Error], pageTwoFails: Bool = false) -> (StubTransport, Flaky) {
        let flaky = Flaky(failures)
        let transport = StubTransport { request in
            if request.url!.path.hasSuffix("/resource-view-states"), let error = flaky.next() { throw error }
            return try h.transport.handlerResult(request)
        }
        return (transport, flaky)
    }

    func testInboxRecoversAfterTimeoutAndDroppedConnectionWithFreshSignaturesAndKeepsCache() async throws {
        let h = try await WorkHarness.make()
        let task = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Cached")
        h.work.seedViewState(type: "task", resource: task, scope: Fixtures.scopeA, channel: Fixtures.channel1, activity: 3, viewed: 1)
        await h.sync.refreshInbox(h.connection, h.workspace); await h.engine.waitUntilIdle()
        let cached = try await h.store.reader.viewStates(workspaceId: h.workspace.id)
        XCTAssertEqual(cached.count, 1)

        let (transport, flaky) = flakyViewStates(h, failures: [URLError(.networkConnectionLost), URLError(.timedOut)])
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
        await sync.refreshInbox(h.connection, h.workspace, force: true)
        // While waiting for its retry the cached rows are untouched and nothing raw is exposed.
        try await Task.sleep(for: .milliseconds(300))
        let during = await h.engine.snapshot
        XCTAssertTrue(during.errors.isEmpty)
        let stillCached = try await h.store.reader.viewStates(workspaceId: h.workspace.id)
        XCTAssertEqual(stillCached.count, 1)
        await h.engine.waitUntilIdle()   // no user action in between
        XCTAssertEqual(flaky.attempts, 3)
        let after = await h.engine.snapshot
        XCTAssertTrue(after.connectionFailures.isEmpty)
        XCTAssertTrue(after.errors.isEmpty)
        let authorizations = transport.recorded.filter { $0.url!.path.hasSuffix("/resource-view-states") }
            .compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(authorizations.count, 3)
        XCTAssertEqual(Set(authorizations).count, 3, "every attempt carries its own fresh signature")
    }

    func testLaterPageFailureKeepsPreviousCompleteSnapshot() async throws {
        let h = try await WorkHarness.make()
        let task = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Cached")
        h.work.seedViewState(type: "task", resource: task, scope: Fixtures.scopeA, channel: Fixtures.channel1, activity: 3, viewed: 1)
        await h.sync.refreshInbox(h.connection, h.workspace); await h.engine.waitUntilIdle()

        let calls = Flaky([])
        let transport = StubTransport { request in
            guard request.url!.path.hasSuffix("/resource-view-states") else { return try h.transport.handlerResult(request) }
            _ = calls.next()
            if request.url!.query?.contains("cursor=") == true { throw URLError(.networkConnectionLost) }
            return (200, ["states": [], "next_cursor": "page-2", "has_more": true])
        }
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
        await sync.refreshInbox(h.connection, h.workspace, force: true)
        await h.engine.waitUntilIdle()
        let states = try await h.store.reader.viewStates(workspaceId: h.workspace.id)
        XCTAssertEqual(states.count, 1, "an incomplete snapshot is never stored over the last complete one")
        XCTAssertGreaterThanOrEqual(calls.attempts, 2)
        XCTAssertLessThanOrEqual(calls.attempts, 2 * (1 + SyncBackoff.readRetries), "bounded")
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SyncEvent] = []
    func add(_ e: SyncEvent) { lock.withLock { events.append(e) } }
    var all: [SyncEvent] { lock.withLock { events } }
}

final class DiagnosticsTests: XCTestCase {
    func testEndpointTemplatesDropIdentifiersAndQueryValues() {
        let url = URL(string: "https://tower.example/api/v4/flightdeck-pg/workspaces/2e5caefd-008d-4af2-b819-972ea88fc67c/resource-view-states?limit=200&cursor=eyJzZWNyZXQiOiJ4In0&since=2026-10-26T08:00:00Z")!
        let text = DiagnosticsRedactor.endpoint(method: "get", url: url)
        XCTAssertEqual(text, "GET tower.example/api/v4/flightdeck-pg/workspaces/:id/resource-view-states??,cursor,limit=200")
        let npubPath = URL(string: "https://tower.example/api/v4/people/\(TestKeys.npub)/files/Secret%20Plan.pdf")!
        let second = DiagnosticsRedactor.endpoint(method: "GET", url: npubPath)
        XCTAssertFalse(second.contains("npub1"))
        XCTAssertFalse(second.contains("Secret"))
    }

    func testErrorCodesNeverEmbedMessages() {
        XCTAssertEqual(DiagnosticsRedactor.errorCode(URLError(.timedOut)), "NSURLErrorDomain -1001")
        XCTAssertEqual(DiagnosticsRedactor.errorCode(TowerError.http(status: 503, code: "contains secret text", stage: nil)), "http 503")
        let leaky = NSError(domain: "X", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed https://tower.example/x?token=abc"])
        XCTAssertEqual(DiagnosticsRedactor.errorCode(leaky), "error")
    }

    func testLowercaseSlugsEncodedSegmentsAndArbitraryQueryNamesAreNotKept() {
        let slugs = ["https://tower.example/api/v4/flightdeck-pg/workspaces/acmecorp/scopes/alice/channels/secretproject/messages",
                     "https://tower.example/api/v4/flightdeck-pg/workspaces/abcdefabcdef/files/quarterlyreport/content",
                     "https://tower.example/api/v4/flightdeck-pg/workspaces/%61lice/docs/files%2Fsecret/comments",
                     "https://tower.example/api/v4/flightdeck-pg/workspaces/ALICE/tasks/résumé/comments",
                     "https://tower.example/api/v4/flightdeck-pg/workspaces/a.b/threads/x_y/messages?limit=200&password=hunter2&user_alice=1&cursor=zzz&limit2=5"]
        let out = slugs.map { DiagnosticsRedactor.endpoint(method: "GET", url: URL(string: $0)) }
        XCTAssertEqual(out[0], "GET tower.example/api/v4/flightdeck-pg/workspaces/:id/scopes/:id/channels/:id/messages")
        XCTAssertEqual(out[1], "GET tower.example/api/v4/flightdeck-pg/workspaces/:id/files/:id/content")
        XCTAssertEqual(out[2], "GET tower.example/api/v4/flightdeck-pg/workspaces/:id/docs/:id/comments")
        XCTAssertEqual(out[3], "GET tower.example/api/v4/flightdeck-pg/workspaces/:id/tasks/:id/comments")
        XCTAssertEqual(out[4], "GET tower.example/api/v4/flightdeck-pg/workspaces/:id/threads/:id/messages??,?,?,cursor,limit=200")
        for line in out { for leak in ["alice", "acmecorp", "secretproject", "quarterlyreport", "hunter2", "password", "user_alice", "zzz", "secret", "ALICE"] { XCTAssertFalse(line.contains(leak), "\(line) leaked \(leak)") } }
        XCTAssertEqual(DiagnosticsRedactor.endpoint(method: "get\r\nX: y", url: URL(string: "https://t.example/api/v4/me")), "OTHER t.example/api/v4/me")
        XCTAssertEqual(DiagnosticsRedactor.endpoint(method: "GET", url: URL(string: "https://t.example/api/v4/x?limit=99999999999")), "GET t.example/api/v4/:id?limit")
        XCTAssertEqual(DiagnosticsRedactor.family("inbox"), "inbox")
        XCTAssertEqual(DiagnosticsRedactor.family("alice@example.com"), "job")
    }

    func testCorrelationOnlyInRecognisedFormats() {
        func response(_ headers: [String: String]) -> HTTPURLResponse { HTTPURLResponse(url: URL(string: "https://t.example")!, statusCode: 200, httpVersion: nil, headerFields: headers)! }
        XCTAssertEqual(DiagnosticsRedactor.correlation(response(["cf-ray": "8a1b2c3d4e5f6071-AMS"])), "cf-ray=8a1b2c3d4e5f6071-AMS")
        XCTAssertEqual(DiagnosticsRedactor.correlation(response(["x-request-id": "2E5CAEFD-008D-4AF2-B819-972EA88FC67C"])), "x-request-id=2e5caefd-008d-4af2-b819-972ea88fc67c")
        for bad in ["hello-world", "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg", "secret-token-123", "alice", "sk_live_abcdef", "8a1b2c3d4e5f-AMS", "8a1b2c3d4e5f6071-AMSX"] {
            XCTAssertNil(DiagnosticsRedactor.correlation(response(["x-request-id": bad])), bad)
            XCTAssertNil(DiagnosticsRedactor.correlation(response(["cf-ray": bad])), bad)
            XCTAssertNil(DiagnosticsRedactor.correlation(response(["x-correlation-id": bad])), bad)
        }
    }

    func testObservedTransportLogsRedactedEntriesAndExportHasNoSecrets() async throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("diagnostics.json")
        let log = DiagnosticsLog(fileURL: file, capacity: 5)
        let health = ConnectionHealth()
        let stub = StubTransport { request in
            if request.url!.path.hasSuffix("/boom") { throw URLError(.timedOut) }
            return (200, ["message": "private body text"])
        }
        let transport = ObservedTransport(stub, health: health, log: log)
        var request = URLRequest(url: URL(string: "https://tower.example/api/v4/flightdeck-pg/workspaces/2e5caefd-008d-4af2-b819-972ea88fc67c/resource-view-states?limit=200&cursor=SECRETCURSOR")!)
        request.setValue("Nostr c2VjcmV0LXRva2Vu", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{\"text\":\"my private message\",\"nsec\":\"\(TestKeys.nsec)\"}".utf8)
        _ = try await transport.send(request)
        var failing = await health.failing
        XCTAssertFalse(failing)
        do { _ = try await transport.send(URLRequest(url: URL(string: "https://tower.example/api/v4/boom")!)); XCTFail() } catch {}
        failing = await health.failing
        XCTAssertTrue(failing)
        _ = try await transport.send(request)
        failing = await health.failing
        XCTAssertFalse(failing, "any later response clears it")

        let text = await log.exportText(app: "0.1.0", build: "22", platform: "iOS", system: "26.0", now: Date(timeIntervalSince1970: 1_792_000_000))
        for secret in ["SECRETCURSOR", "c2VjcmV0LXRva2Vu", "private body", "my private message", TestKeys.nsec, "Authorization", "2e5caefd-008d"] {
            XCTAssertFalse(text.contains(secret), "export leaked \(secret)")
        }
        XCTAssertTrue(text.contains("App: 0.1.0 (22)"))
        XCTAssertTrue(text.contains("UTC"))
        XCTAssertTrue(text.contains("NSURLErrorDomain -1001"))
        XCTAssertTrue(text.contains("/resource-view-states?cursor,limit=200"))
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("SECRETCURSOR") || onDisk.contains("c2VjcmV0"))
    }

    func testLogIsBoundedAndPersistsAcrossInstances() async throws {
        let file = temporaryDirectory().appendingPathComponent("d.json")
        let log = DiagnosticsLog(fileURL: file, capacity: 3)
        for i in 0..<10 { await log.record(DiagnosticEntry(kind: "request", endpoint: "GET h/\(i)", outcome: "failed", errorCode: "x")) }
        let kept = await log.entries()
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept.last?.endpoint, "GET h/9")
        let reloaded = await DiagnosticsLog(fileURL: file, capacity: 3).entries()
        XCTAssertEqual(reloaded.map(\.endpoint), ["GET h/7", "GET h/8", "GET h/9"])
        await log.clear()
        let cleared = await log.entries()
        XCTAssertTrue(cleared.isEmpty)
    }
}
