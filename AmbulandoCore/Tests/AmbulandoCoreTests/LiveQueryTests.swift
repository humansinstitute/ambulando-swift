import XCTest
@testable import AmbulandoCore

@MainActor
final class LiveQueryTests: XCTestCase {
    struct Slow: Error, LocalizedError { var errorDescription: String? { "old workspace failed" } }

    /// Regression: a slow load for a replaced query (previous workspace) must not overwrite the new one.
    func testSlowLoadFromReplacedQueryIsDiscarded() async throws {
        let coalescer = ChangeCoalescer(interval: .milliseconds(10))
        let query = LiveQuery<[String]>(initial: [])
        query.start(changes: coalescer, matches: { _ in true }) {
            try await Task.sleep(for: .milliseconds(300))
            return ["old workspace row"]
        }
        try await Task.sleep(for: .milliseconds(20))
        query.start(changes: coalescer, matches: { _ in true }) { ["new workspace row"] }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(query.value, ["new workspace row"])
        XCTAssertTrue(query.loaded)
        XCTAssertNil(query.error)
    }

    func testSlowErrorFromReplacedQueryIsDiscarded() async throws {
        let coalescer = ChangeCoalescer(interval: .milliseconds(10))
        let query = LiveQuery<[String]>(initial: [])
        query.start(changes: coalescer, matches: { _ in true }) {
            try? await Task.sleep(for: .milliseconds(300))
            throw Slow()
        }
        try await Task.sleep(for: .milliseconds(20))
        query.start(changes: coalescer, matches: { _ in true }) { ["fresh"] }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(query.value, ["fresh"])
        XCTAssertNil(query.error, "the old query's late error is not shown on the new one")
    }

    func testStoppedQueryIgnoresLateResult() async throws {
        let coalescer = ChangeCoalescer(interval: .milliseconds(10))
        let query = LiveQuery<[String]>(initial: [])
        query.start(changes: coalescer, matches: { _ in true }) {
            try? await Task.sleep(for: .milliseconds(200))
            return ["late"]
        }
        try await Task.sleep(for: .milliseconds(20))
        query.stop()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(query.value, [])
        XCTAssertFalse(query.loaded)
    }

    /// A paused query (a Deck card out of sight) keeps its rows, ignores changes, and resumes without flashing empty.
    func testPauseKeepsRowsAndResumeKeepsThemUntilTheFreshRead() async throws {
        let store = try LocalStore(directory: temporaryDirectory(), coalesceInterval: .milliseconds(10))
        let w = Fixtures.workspaceId
        let query = LiveQuery<[String]>(initial: [])
        let load: @Sendable () async throws -> [String] = { try await store.reader.scopes(workspaceId: w).map(\.name) }
        try await store.writer.upsertScopes(workspaceId: w, [try ScopeRecord(raw: Fixtures.json(Fixtures.scope(Fixtures.scopeA, name: "Alpha")))], complete: false)
        query.start(store: store, matches: { $0.table == .scopes }, load: load)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(query.value, ["Alpha"])
        query.pause()
        XCTAssertEqual(query.value, ["Alpha"], "rows stay while paused")
        XCTAssertTrue(query.loaded)
        try await store.writer.upsertScopes(workspaceId: w, [try ScopeRecord(raw: Fixtures.json(Fixtures.scope(Fixtures.scopeB, name: "Beta")))], complete: false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(query.value, ["Alpha"], "no reads while paused")
        query.start(store: store, keepingValue: true, matches: { $0.table == .scopes }) {
            try await Task.sleep(for: .milliseconds(100))
            return try await load()
        }
        XCTAssertEqual(query.value, ["Alpha"], "resuming keeps the rows until the fresh read")
        XCTAssertTrue(query.loaded)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(Set(query.value), ["Alpha", "Beta"])
    }

    func testReloadsOnlyForMatchingChanges() async throws {
        let store = try LocalStore(directory: temporaryDirectory(), coalesceInterval: .milliseconds(10))
        let query = LiveQuery<[String]>(initial: [])
        let w = Fixtures.workspaceId
        query.start(store: store, matches: { $0.table == .scopes && $0.workspaceId == w }) {
            try await store.reader.scopes(workspaceId: w).map(\.name)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(query.loaded)
        XCTAssertEqual(query.value, [])
        try await store.writer.upsertScopes(workspaceId: w, [try ScopeRecord(raw: Fixtures.json(Fixtures.scope(Fixtures.scopeA, name: "Alpha")))], complete: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(query.value, ["Alpha"])
    }

    /// Build 9 review: a Deck card paused while its channel was purged (access lost) showed the denied rows again for
    /// one read when it came back. Rows kept across a pause are now dropped if records were removed meanwhile.
    func testResumeAfterAccessLossShowsNoDeniedRows() async throws {
        let store = try LocalStore(directory: temporaryDirectory(), coalesceInterval: .milliseconds(10))
        let w = Fixtures.workspaceId
        try await store.writer.upsertScopes(workspaceId: w, [try ScopeRecord(raw: Fixtures.json(Fixtures.scope(Fixtures.scopeA, name: "Alpha")))], complete: true)
        let channel = try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "general")))
        try await store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA, [channel], complete: true)
        try await store.writer.upsertMessages([MessageRecord(workspaceId: w, id: "m1", channelId: Fixtures.channel1, body: "secret", createdAt: "2026-10-24T00:00:00Z")])
        let query = LiveQuery<[String]>(initial: [])
        let load: @Sendable () async throws -> [String] = { try await store.reader.latestMessages(workspaceId: w, channelId: Fixtures.channel1, limit: 10).map(\.body) }
        let matches: @Sendable (ChangeKey) -> Bool = { $0.workspaceId == w && $0.table == .messages }
        query.start(store: store, matches: matches, load: load)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(query.value, ["secret"])
        query.pause()
        // While hidden: Tower no longer lists the channel (access revoked), so its content is purged.
        try await store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA, [], complete: true)
        // Resume at once, before the purge's change batch is delivered, with a slow fresh read.
        query.start(store: store, keepingValue: true, matches: matches) {
            try await Task.sleep(for: .milliseconds(100))
            return try await load()
        }
        XCTAssertEqual(query.value, [], "denied rows are not shown again while the fresh read runs")
        XCTAssertFalse(query.loaded)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(query.loaded)
        XCTAssertEqual(query.value, [])
    }

    func testResumeAfterADeletedRecordAndAfterOrdinaryChanges() async throws {
        let store = try LocalStore(directory: temporaryDirectory(), coalesceInterval: .milliseconds(10))
        let w = Fixtures.workspaceId
        try await store.writer.upsertMessages([MessageRecord(workspaceId: w, id: "m1", channelId: Fixtures.channel1, body: "one", createdAt: "2026-10-24T00:00:00Z"),
                                               MessageRecord(workspaceId: w, id: "m2", channelId: Fixtures.channel1, body: "two", createdAt: "2026-10-24T00:00:01Z")])
        let query = LiveQuery<[String]>(initial: [])
        let load: @Sendable () async throws -> [String] = { try await store.reader.latestMessages(workspaceId: w, channelId: Fixtures.channel1, limit: 10).map(\.body) }
        query.start(store: store, matches: { $0.table == .messages }, load: load)
        try await Task.sleep(for: .milliseconds(80))
        query.pause()
        // An ordinary new message while hidden keeps the rows on resume (no flash; offline behaviour unchanged).
        try await store.writer.upsertMessages([MessageRecord(workspaceId: w, id: "m3", channelId: Fixtures.channel1, body: "three", createdAt: "2026-10-24T00:00:02Z")])
        query.start(store: store, keepingValue: true, matches: { $0.table == .messages }, load: load)
        XCTAssertEqual(query.value, ["one", "two"])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(query.value, ["one", "two", "three"])
        query.pause()
        // A message deleted on Tower while hidden is never shown again.
        try await store.writer.applyTombstones(workspaceId: w, [.message("m2")])
        query.start(store: store, keepingValue: true, matches: { $0.table == .messages }, load: load)
        XCTAssertEqual(query.value, [])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(query.value, ["one", "three"])
    }
}
