import XCTest
@testable import AmbulandoCore

final class StoreTests: XCTestCase {
    func scope(_ id: String, _ name: String, workspace: String = Fixtures.workspaceId, rowVersion: Int = 1, updated: String = "2026-10-01T00:00:00.000Z") throws -> ScopeRecord {
        var object = Fixtures.scope(id, workspace: workspace, name: name, updated: updated)
        object["row_version"] = rowVersion
        return try ScopeRecord(raw: Fixtures.json(object))
    }

    func channel(_ id: String, scope: String, _ name: String, workspace: String = Fixtures.workspaceId, position: Double? = nil) throws -> ChannelRecord {
        try ChannelRecord(raw: Fixtures.json(Fixtures.channel(id, scope: scope, workspace: workspace, name: name, position: position)))
    }

    func testMigrationIsIdempotentAndDataSurvivesReopen() async throws {
        let dir = temporaryDirectory()
        do {
            let store = try LocalStore(directory: dir)
            try await store.writer.upsertScopes(workspaceId: Fixtures.workspaceId, [try scope(Fixtures.scopeA, "Alpha")], complete: true)
            try await store.writer.setState("selected-workspace", Fixtures.workspaceId)
        }
        let reopened = try LocalStore(directory: dir)
        let version = try await reopened.writer.schemaVersion()
        XCTAssertEqual(version, Schema.version)
        let names = try await reopened.reader.scopes(workspaceId: Fixtures.workspaceId).map(\.name)
        XCTAssertEqual(names, ["Alpha"])
        let selected = try await reopened.reader.state("selected-workspace")
        XCTAssertEqual(selected, Fixtures.workspaceId)
    }

    func testRowVersionAndTimestampGuardPreventsStaleOverwrite() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let w = Fixtures.workspaceId
        do { let value = try await store.writer.upsertScopes(workspaceId: w, [try scope(Fixtures.scopeA, "New", rowVersion: 3)], complete: false); XCTAssertEqual(value, 1) }
        do { let value = try await store.writer.upsertScopes(workspaceId: w, [try scope(Fixtures.scopeA, "Stale", rowVersion: 2)], complete: false); XCTAssertEqual(value, 0) }
        do { let value = try await store.writer.upsertScopes(workspaceId: w, [try scope(Fixtures.scopeA, "New", rowVersion: 3)], complete: false); XCTAssertEqual(value, 0, "identical payload is a no-op") }
        // Tower serializes scopes/channels with row_version 1 always, so updated_at must order them.
        do { let value = try await store.writer.upsertScopes(workspaceId: w, [try scope(Fixtures.scopeA, "Old", rowVersion: 3, updated: "2026-09-01T00:00:00.000Z")], complete: false); XCTAssertEqual(value, 0) }
        do { let value = try await store.writer.upsertScopes(workspaceId: w, [try scope(Fixtures.scopeA, "Renamed", rowVersion: 3, updated: "2026-11-01T00:00:00.000Z")], complete: false); XCTAssertEqual(value, 1) }
        let names = try await store.reader.scopes(workspaceId: w).map(\.name)
        XCTAssertEqual(names, ["Renamed"])
    }

    func testCompleteListsReconcileRevokedRows() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let w = Fixtures.workspaceId
        try await store.writer.upsertScopes(workspaceId: w, [try scope(Fixtures.scopeA, "A"), try scope(Fixtures.scopeB, "B")], complete: true)
        try await store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA, [try channel(Fixtures.channel1, scope: Fixtures.scopeA, "general")], complete: true)
        try await store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeB, [try channel(Fixtures.channel2, scope: Fixtures.scopeB, "ops")], complete: true)
        try await store.writer.upsertScopes(workspaceId: w, [try scope(Fixtures.scopeA, "A")], complete: true)
        let scopes = try await store.reader.scopes(workspaceId: w).map(\.id)
        let channels = try await store.reader.channels(workspaceId: w).map(\.id)
        XCTAssertEqual(scopes, [Fixtures.scopeA])
        XCTAssertEqual(channels, [Fixtures.channel1], "channels of a revoked scope are removed")
    }

    func testWorkspaceIsolation() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let connection = try await store.writer.saveConnection(ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil))
        let w1 = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId, label: "One")))
        let w2 = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId2, label: "Two")))
        try await store.writer.replaceWorkspaces(connectionId: connection.id, [w1, w2])
        // The same scope id under two workspaces stays two independent rows.
        try await store.writer.upsertScopes(workspaceId: w1.id, [try scope(Fixtures.scopeA, "In one", workspace: w1.id)], complete: true)
        try await store.writer.upsertScopes(workspaceId: w2.id, [try scope(Fixtures.scopeA, "In two", workspace: w2.id)], complete: true)
        // A record claiming another workspace is ignored rather than written across the boundary.
        try await store.writer.upsertScopes(workspaceId: w1.id, [try scope(Fixtures.scopeB, "Smuggled", workspace: w2.id)], complete: false)
        var one = try await store.reader.scopes(workspaceId: w1.id).map(\.name)
        XCTAssertEqual(one, ["In one"])

        // Losing access to workspace two removes only its rows.
        try await store.writer.replaceWorkspaces(connectionId: connection.id, [w1])
        one = try await store.reader.scopes(workspaceId: w1.id).map(\.name)
        let two = try await store.reader.scopes(workspaceId: w2.id)
        let listed = try await store.reader.workspaces(connectionId: connection.id).map(\.label)
        XCTAssertEqual(one, ["In one"])
        XCTAssertTrue(two.isEmpty)
        XCTAssertEqual(listed, ["One"])
    }

    func testConnectionIsBoundToOriginAndSigner() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let origin = try TowerOrigin("https://tower.example")
        let first = try await store.writer.saveConnection(ConnectionRecord(origin: origin, signerNpub: TestKeys.npub, towerNpub: nil))
        let again = try await store.writer.saveConnection(ConnectionRecord(origin: origin, signerNpub: TestKeys.npub, towerNpub: "npub1x"))
        XCTAssertEqual(first.id, again.id, "same origin+signer reuses the connection")
        let other = try await store.writer.saveConnection(ConnectionRecord(origin: origin, signerNpub: NostrKeys.npub(publicKeyHex: String(repeating: "cd", count: 32))!, towerNpub: nil))
        XCTAssertNotEqual(first.id, other.id)
        let count = try await store.reader.connections().count
        XCTAssertEqual(count, 2)
    }

    func testMessagesOrderedNewestWindowOldestFirst() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let records = (0..<10).map { i in
            MessageRecord(workspaceId: Fixtures.workspaceId, id: String(format: "m%02d", i), channelId: Fixtures.channel1, body: "b\(i)",
                          createdAt: String(format: "2026-10-01T00:00:%02d.000Z", i))
        }
        do { let value = try await store.writer.upsertMessages(records.shuffled()); XCTAssertEqual(value, 10) }
        let window = try await store.reader.latestMessages(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1, limit: 3).map(\.body)
        XCTAssertEqual(window, ["b7", "b8", "b9"])
    }

    func testWritesEmitCoalescedChangesAndNoOpsEmitNothing() async throws {
        let store = try LocalStore(directory: temporaryDirectory(), coalesceInterval: .milliseconds(20))
        let stream = await store.changes.stream()
        var iterator = stream.makeAsyncIterator()
        try await store.writer.upsertScopes(workspaceId: Fixtures.workspaceId, [try scope(Fixtures.scopeA, "A")], complete: false)
        let first = await iterator.next()
        XCTAssertEqual(first, [ChangeKey(.scopes, Fixtures.workspaceId), ChangeKey(.channels, Fixtures.workspaceId)])
        try await store.writer.upsertScopes(workspaceId: Fixtures.workspaceId, [try scope(Fixtures.scopeA, "A")], complete: false)
        try await store.writer.setState("k", "v")
        let second = await iterator.next()
        XCTAssertEqual(second, [ChangeKey(.appState)], "the identical scope upsert produced no change")
    }
}

final class ChangeCoalescerTests: XCTestCase {
    func testBurstIsRateLimitedAndLossless() async throws {
        let coalescer = ChangeCoalescer(interval: .milliseconds(100))
        let stream = await coalescer.stream()
        let collector = Task { () -> [Set<ChangeKey>] in
            var batches: [Set<ChangeKey>] = []
            for await batch in stream { batches.append(batch); if batches.reduce(Set(), { $0.union($1) }).count == 2_000 { break } }
            return batches
        }
        let clock = ContinuousClock(), start = clock.now
        for i in 0..<2_000 {
            await coalescer.record([ChangeKey(.messages, "w\(i)")])
            if i % 200 == 0 { try await Task.sleep(for: .milliseconds(50)) }
        }
        let batches = await collector.value
        let seconds = Double((clock.now - start).components.seconds) + Double((clock.now - start).components.attoseconds) / 1e18
        XCTAssertEqual(batches.reduce(Set(), { $0.union($1) }).count, 2_000, "no key lost")
        XCTAssertLessThanOrEqual(Double(batches.count), (seconds * 10).rounded(.up) + 1, "≤ 10 emissions per second")
        print("Coalescer: 2000 changes over \(String(format: "%.2f", seconds))s → \(batches.count) UI notifications")
    }
}
