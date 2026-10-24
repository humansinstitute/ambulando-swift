import Foundation
import XCTest
@testable import AmbulandoCore

final class MemorySessionStore: SessionKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: SessionKey?
    var failDeletes = 0
    func read() throws -> SessionKey? { lock.withLock { value } }
    func write(_ key: SessionKey) throws { lock.withLock { value = key } }
    func delete() throws {
        try lock.withLock {
            if failDeletes > 0 { failDeletes -= 1; throw IdentityError.keychainUnavailable }
            value = nil
        }
    }
    var stored: Bool { lock.withLock { value != nil } }
}

/// Stay unlocked on a trusted device: a PIN unlock survives relaunch; Lock now, remove and disconnect end it, and a
/// failed Keychain delete never lets it resume.
final class SessionContinuityTests: XCTestCase {
    func service(_ dir: URL, _ secrets: MemorySecretStore, _ session: MemorySessionStore) -> IdentityService {
        IdentityService(vaultURL: dir.appendingPathComponent("vault.json"), secrets: secrets, session: session)
    }

    func testUnlockedSessionResumesAfterRelaunchUntilManualLock() async throws {
        let dir = temporaryDirectory(), secrets = MemorySecretStore(), session = MemorySessionStore()
        let first = service(dir, secrets, session)
        try await first.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        // Relaunch: no PIN needed.
        let second = service(dir, secrets, session)
        let resumed = await second.resumeSession()
        XCTAssertTrue(resumed)
        let state = await second.state
        XCTAssertEqual(state, .unlocked(npub: TestKeys.npub))
        // Manual lock: the next launch needs the PIN, even if deleting the Keychain item fails.
        session.failDeletes = 1
        await second.lock()
        XCTAssertTrue(session.stored, "the item survived the failed delete")
        let third = service(dir, secrets, session)
        let afterLock = await third.resumeSession()
        XCTAssertFalse(afterLock, "never resumes after a manual lock")
        XCTAssertFalse(session.stored, "the resume attempt finished the deletion")
        do { _ = try await third.unlock(pin: "000000"); XCTFail("wrong PIN accepted") } catch {}
        let stillLocked = await third.state
        XCTAssertEqual(stillLocked, .locked(npub: TestKeys.npub))
        // A PIN unlock starts a new session.
        try await third.unlock(pin: TestKeys.pin)
        let fourth = service(dir, secrets, session)
        let again = await fourth.resumeSession()
        XCTAssertTrue(again)
    }

    func testEndSessionAndRemoveRevoke() async throws {
        let dir = temporaryDirectory(), secrets = MemorySecretStore(), session = MemorySessionStore()
        let identity = service(dir, secrets, session)
        try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        try await identity.endSession()   // disconnect
        let relaunched = service(dir, secrets, session)
        let resumed = await relaunched.resumeSession()
        XCTAssertFalse(resumed)
        try await relaunched.unlock(pin: TestKeys.pin)
        _ = try await relaunched.remove()
        XCTAssertFalse(session.stored)
    }

    func testSessionOfAnotherKeyIsRefused() async throws {
        let dir = temporaryDirectory(), secrets = MemorySecretStore(), session = MemorySessionStore()
        let identity = service(dir, secrets, session)
        try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        try session.write(SessionKey(publicKeyHex: TestKeys.pubkeyHex, secretKey: Data(repeating: 0x11, count: 32)))
        let relaunched = service(dir, secrets, session)
        let resumed = await relaunched.resumeSession()
        XCTAssertFalse(resumed, "a stored key that does not match the vault is never used")
    }
}

final class FeedRootTests: XCTestCase {
    /// Tower threads without a source message (and threads whose source was deleted) still appear in the channel,
    /// represented by their earliest stored message.
    func testThreadWithoutSourceAppearsByEarliestMessage() async throws {
        let h = try await ChatHarness.make()
        let w = h.workspace.id, c = Fixtures.channel1, thread = UUID().uuidString.lowercased()
        func message(_ id: String, _ body: String, _ at: String, thread: String?, source: String?) -> MessageRecord {
            MessageRecord(workspaceId: w, id: id, channelId: c, threadId: thread, threadSourceId: source, body: body, senderNpub: TestKeys.npub, createdAt: at)
        }
        let normalRoot = UUID().uuidString.lowercased(), normalThread = UUID().uuidString.lowercased()
        try await h.store.writer.upsertMessages([
            message(normalRoot, "normal root", "2026-10-24T01:00:00.000Z", thread: normalThread, source: normalRoot),
            message(UUID().uuidString.lowercased(), "normal reply", "2026-10-24T01:01:00.000Z", thread: normalThread, source: normalRoot),
            message(UUID().uuidString.lowercased(), "sourceless first", "2026-10-24T02:00:00.000Z", thread: thread, source: nil),
            message(UUID().uuidString.lowercased(), "sourceless second", "2026-10-24T02:01:00.000Z", thread: thread, source: nil),
            message(UUID().uuidString.lowercased(), "plain", "2026-10-24T03:00:00.000Z", thread: nil, source: nil),
        ])
        let feed = try await h.store.reader.channelFeed(workspaceId: w, channelId: c, limit: 50)
        XCTAssertEqual(feed.map(\.message.body), ["normal root", "sourceless first", "plain"])
        XCTAssertEqual(feed.first { $0.message.body == "sourceless first" }?.replyCount, 1)
        XCTAssertEqual(feed.first { $0.message.body == "normal root" }?.replyCount, 1, "replies stay inside their thread")
    }
}

final class WorkspaceChannelCatchUpTests: XCTestCase {
    /// Refreshing a workspace fetches the history of every channel, not only channels opened on this phone.
    func testWorkspaceRefreshCatchesUpUnopenedChannels() async throws {
        let h = try await LiveHarness.make()
        h.chat.tower.seed(channel: Fixtures.channel1, body: "one")
        h.chat.tower.seed(channel: Fixtures.channel2, body: "two")
        h.transport.setHandler { request in
            let path = request.url!.path
            if path.hasSuffix("/scopes") { return (200, ["scopes": [Fixtures.scope(Fixtures.scopeA, name: "A")], "next_cursor": NSNull()]) }
            if path.hasSuffix("/scopes/\(Fixtures.scopeA)/channels") {
                return (200, ["channels": [Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "one"),
                                           Fixtures.channel(Fixtures.channel2, scope: Fixtures.scopeA, name: "two")], "next_cursor": NSNull()])
            }
            return try h.tower.handler()(request)
        }
        await h.sync.refreshWorkspace(h.connection, h.workspace, priority: .visible)
        await h.sync.engine.waitUntilIdle()
        let one = try await h.store.reader.latestMessages(workspaceId: h.workspace.id, channelId: Fixtures.channel1, limit: 5)
        let two = try await h.store.reader.latestMessages(workspaceId: h.workspace.id, channelId: Fixtures.channel2, limit: 5)
        XCTAssertEqual(one.map(\.body), ["one"])
        XCTAssertEqual(two.map(\.body), ["two"])
    }
}
