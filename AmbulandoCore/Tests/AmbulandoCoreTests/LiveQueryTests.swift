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
}
