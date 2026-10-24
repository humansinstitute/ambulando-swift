import Foundation
import XCTest
@testable import AmbulandoCore

final class BackgroundReaderTests: XCTestCase {
    let origin = "https://tower.example"
    func template(_ url: String, method: String = "GET", payload: Bool = false, kind: Int = NIP98.kind) -> NostrEventTemplate {
        var tags = [["u", url], ["method", method]]
        if payload { tags.append(["payload", SHA256Hex.of("x")]) }
        return NostrEventTemplate(kind: kind, tags: tags, content: "")
    }

    func testPolicyAllowsOnlyPinnedReadRequests() {
        let policy = ReadPolicy(origin: origin, workspaceIds: [Fixtures.workspaceId])
        let base = "https://tower.example/api/v4/flightdeck-pg/workspaces"
        XCTAssertTrue(policy.allows(template(base)))
        XCTAssertTrue(policy.allows(template(base + "/\(Fixtures.workspaceId)/events/stream?cursor=abc")))
        XCTAssertTrue(policy.allows(template(base + "/\(Fixtures.workspaceId)/channels/\(Fixtures.channel1)/messages?limit=200")))
        XCTAssertFalse(policy.allows(template(base + "/\(Fixtures.workspaceId2)/events")), "unpinned workspace")
        XCTAssertFalse(policy.allows(template(base + "/\(Fixtures.workspaceId)/channels/x/messages", method: "POST", payload: true)), "write")
        XCTAssertFalse(policy.allows(template(base + "/\(Fixtures.workspaceId)/messages/x", method: "DELETE")), "delete")
        XCTAssertFalse(policy.allows(template("https://evil.example/api/v4/flightdeck-pg/workspaces")), "other host")
        XCTAssertFalse(policy.allows(template("http://tower.example/api/v4/flightdeck-pg/workspaces")), "plain HTTP")
        XCTAssertFalse(policy.allows(template("https://tower.example/api/v4/storage/\(Fixtures.workspaceId)/content")), "outside flightdeck-pg")
        XCTAssertFalse(policy.allows(template(base + "/\(Fixtures.workspaceId)/../other")), "path traversal")
        XCTAssertFalse(policy.allows(NostrEventTemplate(kind: MessageInstructionSignature.kind, tags: [["u", base], ["method", "GET"]], content: "")),
                       "never a chat signature")
    }

    func testLockedIdentitySignsReadsOnlyWithEnabledCredentialAndManualLockRevokes() async throws {
        let directory = temporaryDirectory()
        let background = MemoryBackgroundStore()
        let secrets = MemorySecretStore()
        let identity = IdentityService(vaultURL: directory.appendingPathComponent("vault.json"), secrets: secrets, background: background)
        try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        try await identity.enableBackgroundRead(origin: TowerOrigin(origin), workspaceIds: [Fixtures.workspaceId])

        // Process death: a new service over the same files is locked; the credential loads without the PIN.
        let relaunched = IdentityService(vaultURL: directory.appendingPathComponent("vault.json"), secrets: secrets, background: background)
        let state = await relaunched.state
        XCTAssertEqual(state, .locked(npub: TestKeys.npub), "UI still sees a locked identity")
        let loaded = await relaunched.loadBackgroundRead()
        XCTAssertTrue(loaded)
        try await relaunched.requireReader(npub: TestKeys.npub)
        do { try await relaunched.requireSigner(npub: TestKeys.npub); XCTFail("writes need the PIN") } catch {}
        let read = try await relaunched.sign(template("https://tower.example/api/v4/flightdeck-pg/workspaces/\(Fixtures.workspaceId)/events"))
        XCTAssertTrue(SignatureVerifier.verify(read))
        XCTAssertEqual(read.pubkey, TestKeys.pubkeyHex)
        do {
            _ = try await relaunched.sign(NostrEventTemplate(kind: MessageInstructionSignature.kind,
                                                             tags: MessageInstructionSignature.tags(body: "hi", workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1),
                                                             content: "hi"))
            XCTFail("a message signature must need the PIN")
        } catch { XCTAssertEqual(error as? IdentityError, .locked) }

        // Manual lock removes the credential: nothing is signed until the next unlock.
        await relaunched.lock()
        XCTAssertNil(try background.read())
        let canRead = await relaunched.canReadWhileLocked
        XCTAssertFalse(canRead)
        do { _ = try await relaunched.sign(template("https://tower.example/api/v4/flightdeck-pg/workspaces")); XCTFail() } catch {}
        do { try await relaunched.requireReader(npub: TestKeys.npub); XCTFail() } catch {}
    }

    func testCredentialOfAnotherIdentityIsIgnored() async throws {
        let background = MemoryBackgroundStore()
        let first = IdentityService(vaultURL: temporaryDirectory().appendingPathComponent("vault.json"), secrets: MemorySecretStore(), background: background)
        try await first.importIdentity(nsec: TestKeys.otherNsec(), pin: TestKeys.pin)
        try await first.enableBackgroundRead(origin: TowerOrigin(origin), workspaceIds: [Fixtures.workspaceId])
        let second = try await makeIdentity(unlocked: false)
        _ = second
        let other = IdentityService(vaultURL: temporaryDirectory().appendingPathComponent("vault.json"), secrets: MemorySecretStore(), background: background)
        try await other.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        await other.lock()   // also deletes the shared item; re-store the first identity's credential
        try await first.enableBackgroundRead(origin: TowerOrigin(origin), workspaceIds: [Fixtures.workspaceId])
        let loaded = await other.loadBackgroundRead()
        XCTAssertFalse(loaded, "a credential for a different key is never used")
    }
}

final class BackgroundRefreshTests: XCTestCase {
    func testLockedWithoutCredentialMakesNoRequests() async throws {
        let h = try await LiveHarness.make(unlocked: false)
        let report = await h.sync.backgroundRefresh(h.connection, workspaces: [h.workspace], outbox: nil, writes: nil, budget: .seconds(5))
        XCTAssertEqual(report.result, .skippedLocked)
        XCTAssertTrue(h.transport.recorded.isEmpty)
        let saved = try await h.store.reader.state(BackgroundRefreshReport.stateKey)
        XCTAssertEqual(WorkspaceSync.decodeReport(saved)?.result, .skippedLocked)
    }

    func testLockedWithCredentialCatchesUpReadsButLeavesOutboxForPIN() async throws {
        let background = MemoryBackgroundStore()
        let h = try await LiveHarness.make(unlocked: true, background: background)
        try await h.sync.identity.enableBackgroundRead(origin: TowerOrigin(h.connection.origin), workspaceIds: [h.workspace.id])
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        // Process death and a background launch: locked vault, stored credential.
        let identity = IdentityService(vaultURL: h.chat.directory.appendingPathComponent("vault.json"), secrets: h.chat.secretsCarrier, background: background)
        await identity.loadBackgroundRead()
        let sync = WorkspaceSync(store: h.store, engine: SyncEngine(), identity: identity, transport: h.transport)
        let outbox = OutboxSender(store: h.store, engine: sync.engine, identity: identity, transport: h.transport)
        let target = h.chat.target()
        _ = try await h.store.writer.enqueueSend(target: target, origin: h.connection.origin, signerNpub: TestKeys.npub, appNpub: Fixtures.appNpub,
                                                 body: "queued while locked", mentions: [])
        await outbox.kick(h.connection, force: true)
        let message = h.chat.tower.seed(channel: Fixtures.channel1, body: "arrived in background")
        h.tower.emit("message", id: message["id"] as? String, entityRowVersion: 1)
        let report = await sync.backgroundRefresh(h.connection, workspaces: [h.workspace], outbox: outbox, writes: nil, budget: .seconds(10))
        XCTAssertEqual(report.result, .completed)
        XCTAssertEqual(report.events, 1)
        XCTAssertFalse(report.sentPending)
        let stored = try await h.store.reader.message(workspaceId: h.workspace.id, id: message["id"] as! String)
        XCTAssertEqual(stored?.body, "arrived in background")
        XCTAssertTrue(h.chat.tower.recordedPosts.isEmpty, "nothing written without the PIN")
        for request in h.transport.recorded where request.url!.path.contains("/flightdeck-pg/") {
            XCTAssertEqual(request.httpMethod ?? "GET", "GET")
        }
    }

    func testExpirationCancelsJobsAndKeepsProgress() async throws {
        let h = try await LiveHarness.make()
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        for _ in 0..<5 { h.tower.emit("task", id: UUID().uuidString.lowercased(), entityRowVersion: 1) }
        // Slow, cancellable task reads (like URLSession): they outlast the budget.
        let slow = SlowTransport(inner: h.transport, slowPath: "/tasks/", delay: .seconds(3))
        let sync = WorkspaceSync(store: h.store, engine: h.sync.engine, identity: h.sync.identity, transport: slow, live: h.sync.live)
        let started = ContinuousClock.now
        let report = await sync.backgroundRefresh(h.connection, workspaces: [h.workspace], outbox: nil, writes: nil, budget: .milliseconds(300))
        XCTAssertEqual(report.result, .expired)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "returns at the budget, not when the slow request ends")
        let snapshot = await h.sync.engine.snapshot
        XCTAssertTrue(snapshot.queued.isEmpty)

        // An OS expiration handler cancels the task running the refresh.
        for _ in 0..<5 { h.tower.emit("task", id: UUID().uuidString.lowercased(), entityRowVersion: 1) }
        let task = Task { await sync.backgroundRefresh(h.connection, workspaces: [h.workspace], outbox: nil, writes: nil, budget: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.result, .expired)
    }
}

/// Transfer coordinator with a hand-driven backend standing in for the background URLSession.
final class BackgroundTransferTests: XCTestCase {
    final class ManualBackend: TransferBackend, @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (String, Int?, String?, URL?) -> Void)?
        var started: [(URLRequest, String)] = []
        var active: Set<String> = []
        func setCompletionHandler(_ handler: @escaping @Sendable (String, Int?, String?, URL?) -> Void) { lock.withLock { self.handler = handler } }
        func startUpload(_ request: URLRequest, file: URL, description: String) { lock.withLock { started.append((request, description)); active.insert(description) } }
        func startDownload(_ request: URLRequest, description: String) { lock.withLock { started.append((request, description)); active.insert(description) } }
        func activeDescriptions() async -> Set<String> { lock.withLock { active } }
        func complete(_ key: String, status: Int, file: URL? = nil, reason: String? = nil) {
            let h = lock.withLock { active.remove(key); return handler }
            h?(key, status, reason, file)
        }
        var startedCount: Int { lock.withLock { started.count } }
    }

    func waitStarted(_ backend: ManualBackend, _ count: Int) async {
        for _ in 0..<200 where backend.startedCount < count { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testUploadIsUnsignedSurvivesRelaunchAndIsNotRepeated() async throws {
        let directory = temporaryDirectory()
        let backend = ManualBackend()
        var transfers = BackgroundTransfers(directory: directory, backend: backend)
        await transfers.activate()
        let url = URL(string: "https://objects.example/bucket/obj?X-Amz-Signature=abc")!
        let waiting = Task { [transfers] in try await transfers.upload(key: "upload:1", url: url, bytes: Data("hello".utf8), contentType: "text/plain", towerHost: "tower.example") }
        await waitStarted(backend, 1)
        let request = backend.lock.withLock { backend.started[0].0 }
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.httpMethod, "PUT")
        // The waiting job is cancelled (BG expiry); the system transfer keeps going and finishes after a "relaunch".
        waiting.cancel()
        _ = await waiting.result
        transfers = BackgroundTransfers(directory: directory, backend: backend)
        await transfers.activate()
        backend.complete("upload:1", status: 200)
        try await Task.sleep(for: .milliseconds(50))
        try await transfers.upload(key: "upload:1", url: url, bytes: Data("hello".utf8), contentType: "text/plain", towerHost: "tower.example")
        XCTAssertEqual(backend.startedCount, 1, "a finished transfer is not repeated")
    }

    func testRefusesTowerHostAndPlainHTTP() async throws {
        let transfers = BackgroundTransfers(directory: temporaryDirectory(), backend: ManualBackend())
        for raw in ["https://tower.example/api/v4/storage/x", "https://tower.example/upload", "http://objects.example/x", "https://u:p@objects.example/x"] {
            do { try await transfers.upload(key: raw, url: URL(string: raw)!, bytes: Data(), contentType: "x", towerHost: "tower.example"); XCTFail(raw) }
            catch { XCTAssertEqual(error as? TransferError, .unsafeURL, raw) }
        }
    }

    func testFailedAndLostTransfersAreReportedThenRestarted() async throws {
        let directory = temporaryDirectory()
        let backend = ManualBackend()
        let transfers = BackgroundTransfers(directory: directory, backend: backend)
        await transfers.activate()
        let url = URL(string: "https://objects.example/a")!
        let first = Task { try await transfers.upload(key: "k", url: url, bytes: Data([1]), contentType: "x", towerHost: "tower.example") }
        await waitStarted(backend, 1)
        backend.complete("k", status: 403)
        do { try await first.value; XCTFail() } catch { XCTAssertEqual(error as? TransferError, .failed(status: 403, reason: "status 403")) }
        // Lost: running record but the system has no task (e.g. the user force-quit the app).
        let second = Task { try await transfers.upload(key: "k", url: url, bytes: Data([1]), contentType: "x", towerHost: "tower.example") }
        await waitStarted(backend, 2)
        backend.lock.withLock { backend.active.removeAll() }
        await transfers.recover()
        do { try await second.value; XCTFail() } catch {}
        let third = Task { try await transfers.upload(key: "k", url: url, bytes: Data([1]), contentType: "x", towerHost: "tower.example") }
        await waitStarted(backend, 3)
        backend.complete("k", status: 200)
        try await third.value
    }

    func testDownloadReturnsFileUntilForgotten() async throws {
        let directory = temporaryDirectory()
        let backend = ManualBackend()
        let transfers = BackgroundTransfers(directory: directory, backend: backend)
        await transfers.activate()
        let url = URL(string: "https://objects.example/file")!
        let pending = Task { try await transfers.download(key: "d", url: url, towerHost: "tower.example") }
        await waitStarted(backend, 1)
        let body = directory.appendingPathComponent("d.download")
        try Data("content".utf8).write(to: body)
        backend.complete("d", status: 200, file: body)
        let file = try await pending.value
        XCTAssertEqual(try Data(contentsOf: file), Data("content".utf8))
        XCTAssertEqual(try SHA256Hex.ofFile(file), SHA256Hex.of(Data("content".utf8)))
        await transfers.forget("d")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

/// Delays matching requests with a cancellable sleep, like a slow network.
struct SlowTransport: HTTPTransport {
    let inner: HTTPTransport
    let slowPath: String
    let delay: Duration
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url!.path.contains(slowPath) { try await Task.sleep(for: delay) }
        return try await inner.send(request)
    }
}

/// Keychain stand-in whose delete fails a set number of times.
final class FlakyBackgroundStore: BackgroundCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: BackgroundReadCredential?
    var failDeletes = 0
    func read() throws -> BackgroundReadCredential? { lock.withLock { value } }
    func write(_ credential: BackgroundReadCredential) throws { lock.withLock { value = credential } }
    func delete() throws {
        try lock.withLock {
            if failDeletes > 0 { failDeletes -= 1; throw IdentityError.keychainUnavailable }
            value = nil
        }
    }
    var stored: Bool { lock.withLock { value != nil } }
}

final class BackgroundRevocationTests: XCTestCase {
    let read = NostrEventTemplate(kind: NIP98.kind, tags: [["u", "https://tower.example/api/v4/flightdeck-pg/workspaces"], ["method", "GET"]], content: "")

    func testManualLockRevokesEvenWhenKeychainDeleteFails() async throws {
        let directory = temporaryDirectory()
        let secrets = MemorySecretStore(), background = FlakyBackgroundStore()
        let identity = IdentityService(vaultURL: directory.appendingPathComponent("vault.json"), secrets: secrets, background: background)
        try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        try await identity.enableBackgroundRead(origin: TowerOrigin("https://tower.example"), workspaceIds: [Fixtures.workspaceId])
        background.failDeletes = 1
        await identity.lock()
        XCTAssertTrue(background.stored, "the Keychain item survived the failed delete")
        let incomplete = await identity.revocationIncomplete
        XCTAssertTrue(incomplete, "the failure is reported, not hidden")
        // Same process: reload and sign both refuse.
        let reloaded = await identity.loadBackgroundRead()
        XCTAssertFalse(reloaded)
        do { _ = try await identity.sign(read); XCTFail("revoked credential signed") } catch {}
        XCTAssertFalse(background.stored, "the reload attempt finished the deletion")
        // Relaunch with the item still present (delete failing again): still refused.
        try background.write(BackgroundReadCredential(publicKeyHex: TestKeys.pubkeyHex, secretKey: Data(hex: TestKeys.secretHex)!,
                                                      origin: "https://tower.example", workspaceIds: [Fixtures.workspaceId], createdAt: ""))
        background.failDeletes = 5
        let relaunched = IdentityService(vaultURL: directory.appendingPathComponent("vault.json"), secrets: secrets, background: background)
        let loaded = await relaunched.loadBackgroundRead()
        XCTAssertFalse(loaded)
        let canRead = await relaunched.canReadWhileLocked
        XCTAssertFalse(canRead)
        do { try await relaunched.requireReader(npub: TestKeys.npub); XCTFail() } catch {}
        // Unlock and enable again: the user's explicit choice un-revokes with a fresh credential.
        background.failDeletes = 0
        try await relaunched.unlock(pin: TestKeys.pin)
        try await relaunched.enableBackgroundRead(origin: TowerOrigin("https://tower.example"), workspaceIds: [Fixtures.workspaceId])
        await relaunched.lock()
        let fresh = IdentityService(vaultURL: directory.appendingPathComponent("vault.json"), secrets: secrets, background: background)
        let afterLock = await fresh.loadBackgroundRead()
        XCTAssertFalse(afterLock, "a manual lock after re-enabling revokes again")
    }

    func testDisableAndRemoveFailClosed() async throws {
        for operation in ["disable", "remove"] {
            let directory = temporaryDirectory()
            let secrets = MemorySecretStore(), background = FlakyBackgroundStore()
            let identity = IdentityService(vaultURL: directory.appendingPathComponent("vault.json"), secrets: secrets, background: background)
            try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
            try await identity.enableBackgroundRead(origin: TowerOrigin("https://tower.example"), workspaceIds: [Fixtures.workspaceId])
            background.failDeletes = 1
            if operation == "disable" { try await identity.disableBackgroundRead() } else { _ = try? await identity.remove() }
            let relaunched = IdentityService(vaultURL: directory.appendingPathComponent("vault.json"), secrets: secrets, background: background)
            let loaded = await relaunched.loadBackgroundRead()
            XCTAssertFalse(loaded, operation)
        }
    }
}

final class BoundedChunkBufferTests: XCTestCase {
    func testDeliversInOrderWithinLimit() async throws {
        let buffer = BoundedChunkBuffer(limit: 10)
        XCTAssertTrue(buffer.append(Data("abcd".utf8)))
        XCTAssertTrue(buffer.append(Data("efgh".utf8)))
        XCTAssertEqual(buffer.bufferedBytes, 8)
        let first = try await buffer.next(), second = try await buffer.next()
        XCTAssertEqual(first, Data("abcd".utf8)); XCTAssertEqual(second, Data("efgh".utf8))
        XCTAssertEqual(buffer.bufferedBytes, 0)
        buffer.finish()
        let end = try await buffer.next()
        XCTAssertNil(end)
    }

    func testSlowConsumerOverflowFailsInsteadOfDropping() async throws {
        let buffer = BoundedChunkBuffer(limit: 10)
        XCTAssertTrue(buffer.append(Data(repeating: 1, count: 6)))
        XCTAssertFalse(buffer.append(Data(repeating: 2, count: 6)), "producer told to stop")
        XCTAssertFalse(buffer.append(Data(repeating: 3, count: 1)))
        do { _ = try await buffer.next(); XCTFail("overflow must surface") } catch { XCTAssertEqual(error as? BoundedChunkBuffer.Failure, .overflow) }
    }

    func testWaitingConsumerGetsChunkDirectly() async throws {
        let buffer = BoundedChunkBuffer(limit: 4)
        async let chunk = buffer.next()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(buffer.append(Data(repeating: 7, count: 4)))
        let value = try await chunk
        XCTAssertEqual(value?.count, 4)
    }
}
