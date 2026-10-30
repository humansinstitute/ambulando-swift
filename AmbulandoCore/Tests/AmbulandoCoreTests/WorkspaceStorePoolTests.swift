import Foundation
import XCTest
@testable import AmbulandoCore

final class WorkspaceStorePoolTests: XCTestCase {
    private func workspace(app: String = TestKeys.npub) throws -> WorkspaceRecord {
        var raw = Fixtures.workspace(Fixtures.workspaceId, label: "Studio")
        var identity = raw["identity"] as! [String: Any]
        identity["app_npub"] = app; raw["identity"] = identity
        return try WorkspaceRecord(raw: Fixtures.json(raw))
    }

    private func connection(_ origin: String, signer: String = TestKeys.npub) throws -> ConnectionRecord {
        ConnectionRecord(origin: try TowerOrigin(origin), signerNpub: signer, towerNpub: nil)
    }

    private func seed(_ store: LocalStore, connection: ConnectionRecord, workspace: WorkspaceRecord, label: String) async throws {
        _ = try await store.writer.saveConnection(connection)
        try await store.writer.replaceWorkspaces(connectionId: connection.id, [workspace])
        try await store.writer.upsertScopes(workspaceId: workspace.id,
            [ScopeRecord(raw: Fixtures.json(Fixtures.scope(Fixtures.scopeA, name: label)))], complete: true)
        try await store.writer.upsertChannels(workspaceId: workspace.id, scopeId: Fixtures.scopeA,
            [ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: label)))], complete: true)
    }

    func testSameResourceIDsStayIsolatedAcrossTowersIdentitiesAndApplications() async throws {
        let root = temporaryDirectory(), workspace = try workspace()
        let catalog = try LocalStore(directory: root.appendingPathComponent("Catalog"))
        let pool = WorkspaceStorePool(catalog: catalog, directory: root.appendingPathComponent("Partitions"))
        let first = try connection("https://one.example"), second = try connection("https://two.example")
        let otherIdentity = try connection("https://one.example", signer: "different-identity")
        let otherApp = try self.workspace(app: Bech32.encode(hrp: "npub", data: Data(repeating: 0x11, count: 32)))
        let a = try await pool.store(connection: first, workspace: workspace)
        let b = try await pool.store(connection: second, workspace: workspace)
        let c = try await pool.store(connection: otherIdentity, workspace: workspace)
        let d = try await pool.store(connection: first, workspace: otherApp)
        for (index, store) in [a,b,c,d].enumerated() {
            let owner = [first,second,otherIdentity,first][index]
            try await seed(store, connection: owner, workspace: index == 3 ? otherApp : workspace, label: "private-\(index)")
            let target = ChatTarget(connectionId: owner.id, workspaceId: workspace.id, channelId: Fixtures.channel1)
            try await store.writer.saveDraft(target, Draft(text: "draft-\(index)", mentions: []))
            _ = try await store.writer.enqueueWrite(id: "same-write-id", connection: owner, workspace: index == 3 ? otherApp : workspace,
                intent: WriteIntent(kind: .taskState, targetId: "same-record-id", payload: ["state": "\(index)"]))
            _ = try await store.writer.enqueueSend(id: "same-outbox-id", target: target, origin: owner.origin, signerNpub: owner.signerNpub,
                appNpub: index == 3 ? otherApp.appNpub : workspace.appNpub, body: "body-\(index)", mentions: [])
        }
        XCTAssertEqual(Set([a,b,c,d].map(\.path)).count, 4)
        for (index, store) in [a,b,c,d].enumerated() {
            let scopes = try await store.reader.scopes(workspaceId: workspace.id)
            let channels = try await store.reader.channels(workspaceId: workspace.id)
            let outbox = try await store.reader.outboxItem(id: "same-outbox-id")
            let write = try await store.reader.writeItem(id: "same-write-id")
            XCTAssertEqual(scopes.map(\.name), ["private-\(index)"])
            XCTAssertEqual(channels.map(\.name), ["private-\(index)"])
            XCTAssertEqual(outbox?.body, "body-\(index)")
            XCTAssertEqual(write?.string("state"), "\(index)")
        }
        // A complete deletion in one partition cannot affect another partition with identical resource IDs.
        try await a.writer.upsertScopes(workspaceId: workspace.id, [], complete: true)
        let survivors = try await b.reader.scopes(workspaceId: workspace.id)
        XCTAssertEqual(survivors.map(\.name), ["private-1"])
    }

    func testUniqueMigrationPreservesFrozenRequestsDraftsCursorsAndIsNeverReplayed() async throws {
        let root = temporaryDirectory(), workspace = try workspace(), connection = try connection("https://one.example")
        let catalog = try LocalStore(directory: root.appendingPathComponent("Catalog"))
        try await seed(catalog, connection: connection, workspace: workspace, label: "cached")
        let target = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: Fixtures.channel1)
        let draftTarget = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: Fixtures.channel2)
        try await catalog.writer.saveDraft(draftTarget, Draft(text: "unsent private draft", mentions: []))
        let doc = DocDraft(connectionId: connection.id, workspaceId: workspace.id, docId: "doc", title: "private doc", body: Data("draft bytes".utf8),
            contentType: "text/plain", baseRowVersion: 2, baseSha256: "sha", baseStorageObjectId: "object", state: .editing)
        try await catalog.writer.saveDocDraft(doc)
        _ = try await catalog.writer.enqueueSend(id: "outbox", target: target, origin: connection.origin, signerNpub: connection.signerNpub,
            appNpub: workspace.appNpub, body: "pending", mentions: [])
        let frozen = Data("{\"client_request_id\":\"outbox\",\"signed\":true}".utf8)
        try await catalog.writer.freezeOutbox(id: "outbox", request: frozen)
        _ = try await catalog.writer.enqueueWrite(id: "write", connection: connection, workspace: workspace,
            intent: WriteIntent(kind: .taskState, targetId: "task", payload: ["state": "done", "ambiguous": true]))
        try await catalog.writer.saveEventCursor(connectionId: connection.id, workspaceId: workspace.id, "saved-cursor")
        try await catalog.writer.setState("unknown-private-state", "must not spread")
        let partitions = root.appendingPathComponent("Partitions")
        let pool = WorkspaceStorePool(catalog: catalog, directory: partitions)
        let store = try await pool.store(connection: connection, workspace: workspace)
        let migratedOutbox = try await store.reader.outboxItem(id: "outbox")
        let migratedDraft = try await store.reader.draft(draftTarget)
        let migratedDoc = try await store.reader.docDraft(key: doc.key)
        let cursor = try await store.reader.eventCursor(connectionId: connection.id, workspaceId: workspace.id)
        let unknown = try await store.reader.state("unknown-private-state")
        XCTAssertEqual(migratedOutbox?.request, frozen)
        XCTAssertEqual(migratedDraft?.text, "unsent private draft")
        XCTAssertEqual(migratedDoc, doc)
        XCTAssertEqual(cursor, "saved-cursor")
        XCTAssertNil(unknown)
        _ = try await store.writer.discardOutbox(id: "outbox", restoreDraft: false)
        try await store.writer.discardWrite(id: "write")
        let backupBefore = try Data(contentsOf: await pool.legacyBackupURL)
        // Reopening must not resurrect already acknowledged/discarded work from the preserved source.
        let reopened = try await WorkspaceStorePool(catalog: catalog, directory: partitions).store(connection: connection, workspace: workspace)
        let absentOutbox = try await reopened.reader.outboxItem(id: "outbox")
        let absentWrite = try await reopened.reader.writeItem(id: "write")
        XCTAssertNil(absentOutbox); XCTAssertNil(absentWrite)
        let backupAfter = try Data(contentsOf: await pool.legacyBackupURL)
        XCTAssertEqual(backupAfter, backupBefore)
        let sourceOutbox = try await catalog.reader.outboxItem(id: "outbox")
        XCTAssertNotNil(sourceOutbox, "migration never deletes recovery source")
    }

    func testAmbiguousCacheIsRetainedOnlyInBackupWhileQualifiedDraftsRemainPrivate() async throws {
        let root = temporaryDirectory(), workspace = try workspace()
        let first = try connection("https://one.example"), second = try connection("https://two.example")
        let catalog = try LocalStore(directory: root.appendingPathComponent("Catalog"))
        try await seed(catalog, connection: first, workspace: workspace, label: "ambiguous")
        _ = try await catalog.writer.saveConnection(second)
        try await catalog.writer.replaceWorkspaces(connectionId: second.id, [workspace])
        for (owner, text) in [(first,"first private"),(second,"second private")] {
            try await catalog.writer.saveDraft(ChatTarget(connectionId: owner.id, workspaceId: workspace.id, channelId: Fixtures.channel1), Draft(text: text, mentions: []))
        }
        let pool = WorkspaceStorePool(catalog: catalog, directory: root.appendingPathComponent("Partitions"))
        for (owner, text) in [(first,"first private"),(second,"second private")] {
            let store = try await pool.store(connection: owner, workspace: workspace)
            let scopes = try await store.reader.scopes(workspaceId: workspace.id)
            let draft = try await store.reader.draft(ChatTarget(connectionId: owner.id, workspaceId: workspace.id, channelId: Fixtures.channel1))
            let wrong = try await store.reader.draft(ChatTarget(connectionId: owner.id == first.id ? second.id : first.id, workspaceId: workspace.id, channelId: Fixtures.channel1))
            let status = try await store.reader.state("partition.legacy-cache")
            XCTAssertTrue(scopes.isEmpty); XCTAssertEqual(draft?.text, text); XCTAssertNil(wrong)
            XCTAssertEqual(status, "unattributed-source-preserved")
        }
        let recoverable = try await catalog.reader.scopes(workspaceId: workspace.id)
        XCTAssertEqual(recoverable.map(\.name), ["ambiguous"])
    }

    func testConcurrentPoolRequestsShareOneStoreAndOneNotificationBoundary() async throws {
        let root = temporaryDirectory(), workspace = try workspace(), connection = try connection("https://one.example")
        let catalog = try LocalStore(directory: root.appendingPathComponent("Catalog"))
        let pool = WorkspaceStorePool(catalog: catalog, directory: root.appendingPathComponent("Partitions"))
        let stores = try await withThrowingTaskGroup(of: LocalStore.self) { group in
            for _ in 0..<20 { group.addTask { try await pool.store(connection: connection, workspace: workspace) } }
            var values: [LocalStore] = []
            for try await store in group { values.append(store) }
            return values
        }
        XCTAssertTrue(stores.allSatisfy { $0 === stores.first })
        XCTAssertEqual(Set(stores.map(\.path)).count, 1)
    }

    func testApplicationChangeDoesNotAttributeOldDraftsOrCachedContentToNewApplication() async throws {
        let root = temporaryDirectory(), original = try workspace(), connection = try connection("https://one.example")
        let replacement = try workspace(app: Bech32.encode(hrp: "npub", data: Data(repeating: 0x22, count: 32)))
        let catalog = try LocalStore(directory: root.appendingPathComponent("Catalog"))
        try await seed(catalog, connection: connection, workspace: original, label: "old app secret")
        let target = ChatTarget(connectionId: connection.id, workspaceId: original.id, channelId: Fixtures.channel1)
        try await catalog.writer.saveDraft(target, Draft(text: "old app private draft", mentions: []))
        _ = try await catalog.writer.enqueueSend(id: "old-app-send", target: ChatTarget(connectionId: connection.id, workspaceId: original.id, channelId: Fixtures.channel2), origin: connection.origin, signerNpub: connection.signerNpub,
            appNpub: original.appNpub, body: "old app send", mentions: [])
        let pool = WorkspaceStorePool(catalog: catalog, directory: root.appendingPathComponent("Partitions"))
        let store = try await pool.store(connection: connection, workspace: replacement)
        let scopes = try await store.reader.scopes(workspaceId: original.id)
        let draft = try await store.reader.draft(target)
        let send = try await store.reader.outboxItem(id: "old-app-send")
        XCTAssertTrue(scopes.isEmpty); XCTAssertNil(draft); XCTAssertNil(send)
        let oldAppStore = try await pool.store(connection: connection, workspace: original)
        let preserved = try await oldAppStore.reader.outboxItem(id: "old-app-send")
        XCTAssertEqual(preserved?.body, "old app send")
    }

    func testFailedImportRollsBackEarlierTablesAndCompletionMarker() async throws {
        let root = temporaryDirectory(), workspace = try workspace(), connection = try connection("https://one.example")
        let catalog = try LocalStore(directory: root.appendingPathComponent("Catalog"))
        try await seed(catalog, connection: connection, workspace: workspace, label: "must roll back")
        // Simulate a newer source schema this application cannot safely attribute/import.
        try await catalog.writer.addUnsupportedLegacyColumnForTest()
        let partitions = root.appendingPathComponent("Partitions")
        let pool = WorkspaceStorePool(catalog: catalog, directory: partitions)
        do {
            _ = try await pool.store(connection: connection, workspace: workspace)
            XCTFail("incompatible legacy schema should fail closed")
        } catch is SQLiteError { }
        let boundary = try WorkspaceBoundary(connection: connection, workspace: workspace)
        let destination = try LocalStore(directory: partitions.appendingPathComponent(boundary.id))
        let marker = try await destination.reader.state("partition.migration.v1")
        let scopes = try await destination.reader.scopes(workspaceId: workspace.id)
        XCTAssertNil(marker); XCTAssertTrue(scopes.isEmpty)
        let sourceScopes = try await catalog.reader.scopes(workspaceId: workspace.id)
        XCTAssertEqual(sourceScopes.map(\.name), ["must roll back"])
    }

    func testConnectionAliasesFailClosedWithinPoolAndAfterRelaunch() async throws {
        let root = temporaryDirectory(), workspace = try workspace(), canonical = try connection("https://one.example")
        let alias = try connection("https://ONE.example:443/")
        let catalog = try LocalStore(directory: root.appendingPathComponent("Catalog"))
        try await seed(catalog, connection: canonical, workspace: workspace, label: "canonical")
        let partitions = root.appendingPathComponent("Partitions")
        let pool = WorkspaceStorePool(catalog: catalog, directory: partitions)
        let original = try await pool.store(connection: canonical, workspace: workspace)
        do {
            _ = try await pool.store(connection: alias, workspace: workspace)
            XCTFail("a different local connection ID must not silently alias private state")
        } catch is SQLiteError { }
        do {
            _ = try await WorkspaceStorePool(catalog: catalog, directory: partitions).store(connection: alias, workspace: workspace)
            XCTFail("relaunch must also reject noncanonical connection IDs")
        } catch is SQLiteError { }
        let unchanged = try await original.reader.connections()
        XCTAssertEqual(unchanged.map(\.id), [canonical.id])
    }

    func testLegacyDownloadedBytesRequireUniqueMetadataAndVerifiedHash() async throws {
        let root = temporaryDirectory(), workspace = try workspace(), owner = try connection("https://one.example")
        let catalog = try LocalStore(directory: root.appendingPathComponent("Catalog"))
        try await seed(catalog, connection: owner, workspace: workspace, label: "unique")
        let bytes = Data("verified cached attachment".utf8), sha = SHA256Hex.of(Data("verified cached attachment".utf8))
        func file(_ suffix: String, sha: String?) -> FileRecord {
            FileRecord(workspaceId: workspace.id, id: "cfb74990-0000-4000-8000-00000000000" + suffix,
                scopeId: Fixtures.scopeA, channelId: Fixtures.channel1, folderId: nil, storageObjectId: nil,
                displayName: "attachment.txt", contentType: "text/plain", sizeBytes: bytes.count, sha256: sha,
                createdAt: "2026-10-30T00:00:00Z", updatedAt: "2026-10-30T00:00:00Z")
        }
        let good = file("1", sha: sha), corrupt = file("2", sha: sha), unhashed = file("3", sha: nil)
        _ = try await catalog.writer.upsertFiles(workspaceId: workspace.id, [good,corrupt,unhashed])
        let legacy = FileCache(root: root.appendingPathComponent("LegacyCache"))
        _ = try legacy.store(bytes, for: good)
        _ = try legacy.store(Data("corrupted bytes".utf8), for: corrupt)
        _ = try legacy.store(bytes, for: unhashed)
        let partitions = root.appendingPathComponent("Partitions"), pool = WorkspaceStorePool(catalog: catalog, directory: partitions)
        let store = try await pool.store(connection: owner, workspace: workspace)
        let destination = FileCache(root: root.appendingPathComponent("NewCache"))
        let restored = try await pool.restoreFileCache(store: store, workspace: workspace, legacy: legacy, destination: destination)
        XCTAssertEqual(restored, 1)
        XCTAssertNotNil(destination.cached(good))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.url(for: corrupt).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.url(for: unhashed).path))
        XCTAssertNotNil(legacy.cached(good), "source bytes remain recoverable")
        let repeated = try await pool.restoreFileCache(store: store, workspace: workspace, legacy: legacy, destination: destination)
        XCTAssertEqual(repeated, 0)

        // Identical workspace/file IDs on another Tower cannot claim the first Tower's legacy bytes.
        let other = try connection("https://two.example")
        let isolated = try await pool.store(connection: other, workspace: workspace)
        let otherDestination = FileCache(root: root.appendingPathComponent("OtherTowerCache"))
        let wrongTower = try await pool.restoreFileCache(store: isolated, workspace: workspace, legacy: legacy, destination: otherDestination)
        XCTAssertEqual(wrongTower, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherDestination.url(for: good).path))

        let ambiguousCatalog = try LocalStore(directory: root.appendingPathComponent("AmbiguousCatalog"))
        try await seed(ambiguousCatalog, connection: owner, workspace: workspace, label: "ambiguous")
        _ = try await ambiguousCatalog.writer.saveConnection(other)
        try await ambiguousCatalog.writer.replaceWorkspaces(connectionId: other.id, [workspace])
        _ = try await ambiguousCatalog.writer.upsertFiles(workspaceId: workspace.id, [good])
        let ambiguousPool = WorkspaceStorePool(catalog: ambiguousCatalog, directory: root.appendingPathComponent("AmbiguousPartitions"))
        let ambiguousStore = try await ambiguousPool.store(connection: owner, workspace: workspace)
        let ambiguousDestination = FileCache(root: root.appendingPathComponent("AmbiguousCache"))
        let ambiguousRestore = try await ambiguousPool.restoreFileCache(store: ambiguousStore, workspace: workspace, legacy: legacy, destination: ambiguousDestination)
        XCTAssertEqual(ambiguousRestore, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ambiguousDestination.url(for: good).path))
    }

    func testExplicitRemovalRetiresOnlyMatchingStoresAndReconnectCannotResurrectQueue() async throws {
        let root = temporaryDirectory(), workspace = try workspace(), owner = try connection("https://one.example")
        let other = try connection("https://two.example"), catalog = try LocalStore(directory: root.appendingPathComponent("Catalog"))
        let directory = root.appendingPathComponent("Partitions"), pool = WorkspaceStorePool(catalog: catalog, directory: directory)
        let retiredStore = try await pool.store(connection: owner, workspace: workspace)
        let survivingStore = try await pool.store(connection: other, workspace: workspace)
        try await seed(retiredStore, connection: owner, workspace: workspace, label: "old account")
        try await seed(survivingStore, connection: other, workspace: workspace, label: "other Tower")
        let target = ChatTarget(connectionId: owner.id, workspaceId: workspace.id, channelId: Fixtures.channel1)
        _ = try await retiredStore.writer.enqueueSend(id: "old-account-pending", target: target, origin: owner.origin,
            signerNpub: owner.signerNpub, appNpub: workspace.appNpub, body: "do not replay on reconnect", mentions: [])
        // A partition from an earlier process need not have been opened by this pool to be retired.
        let secondWorkspace = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId2, label: "Not opened")))
        let secondBoundary = try WorkspaceBoundary(connection: owner, workspace: secondWorkspace)
        let unopenedDirectory = directory.appendingPathComponent(secondBoundary.id)
        do {
            let unopened = try LocalStore(directory: unopenedDirectory)
            _ = try await unopened.writer.saveConnection(owner)
            try await unopened.writer.replaceWorkspaces(connectionId: owner.id, [secondWorkspace])
        }
        let backupBefore = try Data(contentsOf: await pool.legacyBackupURL)
        try await pool.remove(connection: owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retiredStore.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unopenedDirectory.path))
        do { _ = try await retiredStore.reader.scopes(workspaceId: workspace.id); XCTFail("stale reader must fail closed") }
        catch is SQLiteError { }
        do { try await retiredStore.writer.setState("late-write", "must fail"); XCTFail("stale writer must fail closed") }
        catch is SQLiteError { }
        let surviving = try await survivingStore.reader.scopes(workspaceId: workspace.id)
        XCTAssertEqual(surviving.map(\.name), ["other Tower"])
        let reconnected = try connection("https://one.example")
        let fresh = try await pool.store(connection: reconnected, workspace: workspace)
        let absent = try await fresh.reader.outboxItem(id: "old-account-pending")
        XCTAssertNil(absent)
        let freshConnections = try await fresh.reader.connections().map(\.id)
        XCTAssertEqual(freshConnections, [reconnected.id])
        let backupAfter = try Data(contentsOf: await pool.legacyBackupURL)
        XCTAssertEqual(backupAfter, backupBefore)
        let recoverable = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Retired"), includingPropertiesForKeys: nil)
        XCTAssertEqual(recoverable.count, 1)
    }

    func testUnsavedBoardDraftMigrationRequiresUniqueOwnershipAndNeverOverwritesOrReplays() async throws {
        let root = temporaryDirectory(), workspace = try workspace(), owner = try connection("https://one.example")
        let catalog = try LocalStore(directory: root.appendingPathComponent("Catalog"))
        try await seed(catalog, connection: owner, workspace: workspace, label: "unique")
        let pool = WorkspaceStorePool(catalog: catalog, directory: root.appendingPathComponent("Partitions"))
        let store = try await pool.store(connection: owner, workspace: workspace)
        let legacyDirectory = root.appendingPathComponent("LegacyBoards"), destinationDirectory = root.appendingPathComponent("Boards")
        let legacy = BoardDraftStore(directory: legacyDirectory), destination = BoardDraftStore(directory: destinationDirectory)
        let file = "a1b2c3d4-0000-4000-8000-000000000001", existing = "a1b2c3d4-0000-4000-8000-000000000002"
        let invalidBase = "a1b2c3d4-0000-4000-8000-000000000003", invalidScene = "a1b2c3d4-0000-4000-8000-000000000004"
        let base = "a1b2c3d4-0000-4000-8000-000000000010", newer = "a1b2c3d4-0000-4000-8000-000000000011"
        try legacy.save(file, baseVersionId: base, baseVersionNumber: 1, scene: BoardScene.empty())
        try legacy.save(existing, baseVersionId: base, baseVersionNumber: 1, scene: BoardScene.empty())
        try destination.save(existing, baseVersionId: newer, baseVersionNumber: 2, scene: BoardScene.empty())
        try legacy.save(invalidBase, baseVersionId: "invalid", baseVersionNumber: 0, scene: BoardScene.empty())
        try legacy.save(invalidScene, baseVersionId: base, baseVersionNumber: 1, scene: ["not": "a board"])
        let copied = try await pool.restoreBoardDrafts(store: store, workspace: workspace, legacyDirectory: legacyDirectory,
            destinationDirectory: destinationDirectory)
        XCTAssertEqual(copied, 1)
        XCTAssertEqual(destination.load(file)?.baseVersionId, base)
        XCTAssertEqual(destination.load(existing)?.baseVersionId, newer)
        XCTAssertNil(destination.load(invalidBase)); XCTAssertNil(destination.load(invalidScene))
        XCTAssertNotNil(legacy.load(file), "legacy unsaved edits remain available for recovery")
        destination.delete(file)
        let repeated = try await pool.restoreBoardDrafts(store: store, workspace: workspace, legacyDirectory: legacyDirectory,
            destinationDirectory: destinationDirectory)
        XCTAssertEqual(repeated, 0); XCTAssertNil(destination.load(file), "a discarded migrated edit must not reappear")

        let other = try connection("https://two.example")
        let ambiguousCatalog = try LocalStore(directory: root.appendingPathComponent("AmbiguousCatalog"))
        try await seed(ambiguousCatalog, connection: owner, workspace: workspace, label: "ambiguous")
        _ = try await ambiguousCatalog.writer.saveConnection(other)
        try await ambiguousCatalog.writer.replaceWorkspaces(connectionId: other.id, [workspace])
        let ambiguousPool = WorkspaceStorePool(catalog: ambiguousCatalog, directory: root.appendingPathComponent("AmbiguousPartitions"))
        let ambiguousStore = try await ambiguousPool.store(connection: owner, workspace: workspace)
        let withheld = root.appendingPathComponent("WithheldBoards")
        let ambiguousCount = try await ambiguousPool.restoreBoardDrafts(store: ambiguousStore, workspace: workspace,
            legacyDirectory: legacyDirectory, destinationDirectory: withheld)
        XCTAssertEqual(ambiguousCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: withheld.path))
        XCTAssertNotNil(legacy.load(file))
    }
}

private extension StoreWriter {
    func addUnsupportedLegacyColumnForTest() throws { try db.execute("ALTER TABLE messages ADD COLUMN future_private_namespace TEXT") }
}
