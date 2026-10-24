import Foundation
import XCTest
@testable import AmbulandoCore

/// Release gate: an update must keep the imported identity, the Tower connection, workspace and navigation selections,
/// drafts, unsent messages and changes, and cached records. These tests use only the public NIP-19 test key and
/// synthetic records.
final class AccountRetentionTests: XCTestCase {
    /// The production names every build since 0.1.0 (1) has used. Renaming any of them strands existing data.
    func testProductionStorageNamesArePinned() {
        XCTAssertEqual(ProductionStorage.dataDirectoryName, "AmbulandoNative")
        XCTAssertEqual(ProductionStorage.storeDirectoryName, "Store")
        XCTAssertEqual(ProductionStorage.databaseFileName, "ambulando.sqlite")
        XCTAssertEqual(ProductionStorage.vaultPath, "Identity/vault.json")
        XCTAssertEqual(ProductionStorage.vaultSecretService, "studio.otherstuff.ambulando.native.identity-vault.v1")
        XCTAssertEqual(ProductionStorage.backgroundReadService, "studio.otherstuff.ambulando.native.background-read.v1")
        XCTAssertEqual(ProductionStorage.sessionService, "studio.otherstuff.ambulando.native.session.v1")
        XCTAssertEqual(ProductionStorage.fileCacheDirectoryName, "AmbulandoFiles")
        XCTAssertEqual(KeychainVaultSecretStore().service, ProductionStorage.vaultSecretService)
        let support = URL(fileURLWithPath: "/data/Library/Application Support")
        XCTAssertEqual(ProductionStorage.vaultURL(ProductionStorage.dataDirectory(applicationSupport: support)).path,
                       "/data/Library/Application Support/AmbulandoNative/Identity/vault.json")
        XCTAssertEqual(ProductionStorage.storeDirectory(ProductionStorage.dataDirectory(applicationSupport: support)).path,
                       "/data/Library/Application Support/AmbulandoNative/Store")
    }

    /// Everything a running build leaves behind is found again by a new process (an update relaunch) at the same paths.
    func testUpdateRelaunchKeepsIdentityConnectionSelectionsDraftsAndUnsentWork() async throws {
        let data = temporaryDirectory()
        let secrets = MemorySecretStore()
        let session = MemorySessionStore()
        let target: ChatTarget
        let draftTarget: ChatTarget
        let connectionId: String
        do {
            let store = try LocalStore(directory: ProductionStorage.storeDirectory(data))
            let identity = IdentityService(vaultURL: ProductionStorage.vaultURL(data), secrets: secrets, session: session)
            try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
            let connection = try await store.writer.saveConnection(ConnectionRecord(origin: try TowerOrigin("https://tower.example"),
                                                                                    signerNpub: TestKeys.npub, towerNpub: nil))
            connectionId = connection.id
            let workspace = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId, label: "Studio")))
            try await store.writer.replaceWorkspaces(connectionId: connection.id, [workspace])
            try await store.writer.setState("selected.connection", connection.id)
            try await store.writer.setState("selected.workspace:\(connection.id)", workspace.id)
            try await store.writer.setState(WorkContext.stateKey(connectionId: connection.id, workspaceId: workspace.id),
                                            WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel1).encoded())
            target = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: Fixtures.channel1)
            // Sending clears that conversation's draft, so the draft is kept in another channel.
            draftTarget = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: Fixtures.channel2)
            try await store.writer.saveDraft(draftTarget, Draft(text: "half-written reply", mentions: []))
            _ = try await store.writer.enqueueSend(target: target, origin: connection.origin, signerNpub: TestKeys.npub,
                                                   appNpub: workspace.appNpub, body: "sent while offline", mentions: [])
        }
        // A new process: new store and identity objects over the same directory and Keychain.
        let store = try LocalStore(directory: ProductionStorage.storeDirectory(data))
        let identity = IdentityService(vaultURL: ProductionStorage.vaultURL(data), secrets: secrets, session: session)
        let v1 = await identity.state
        XCTAssertEqual(v1, .locked(npub: TestKeys.npub))
        let v2 = await identity.resumeSession()
        XCTAssertTrue(v2, "the trusted-device session survives the relaunch")
        let v3 = await identity.state
        XCTAssertEqual(v3, .unlocked(npub: TestKeys.npub))
        let v4 = try await store.reader.connections().map(\.id)
        XCTAssertEqual(v4, [connectionId])
        let v5 = try await store.reader.state("selected.connection")
        XCTAssertEqual(v5, connectionId)
        let v6 = try await store.reader.state("selected.workspace:\(connectionId)")
        XCTAssertEqual(v6, Fixtures.workspaceId)
        let context = WorkContext.decode(try await store.reader.state(WorkContext.stateKey(connectionId: connectionId, workspaceId: Fixtures.workspaceId)))
        XCTAssertEqual(context, WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel1))
        let v7 = try await store.reader.draft(draftTarget)?.text
        XCTAssertEqual(v7, "half-written reply")
        let v8 = try await store.reader.outbox(target: target).map(\.body)
        XCTAssertEqual(v8, ["sent while offline"])
        let v9 = try await store.writer.schemaVersion()
        XCTAssertEqual(v9, Schema.version)
    }

    /// A store written by the first build (schema 1) opens under the current schema with its connection and selections.
    func testSchemaOneStoreUpgradesWithoutLosingTheConnection() async throws {
        let directory = temporaryDirectory()
        let path = directory.appendingPathComponent(ProductionStorage.databaseFileName).path
        do {
            let db = try SQLiteConnection(path: path, readOnly: false)
            // Frozen copy of the schema-1 tables from 0.1.0 (1) (dfbea51).
            try db.execute("""
            CREATE TABLE connections(
              id TEXT PRIMARY KEY, origin TEXT NOT NULL, signer_npub TEXT NOT NULL, tower_npub TEXT, created_at TEXT NOT NULL,
              UNIQUE(origin, signer_npub));
            CREATE TABLE workspaces(
              connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
              workspace_id TEXT NOT NULL, app_npub TEXT NOT NULL, label TEXT NOT NULL, slug TEXT, tower_base_url TEXT,
              role TEXT, owner_npub TEXT, raw BLOB NOT NULL, synced_at TEXT NOT NULL,
              PRIMARY KEY(connection_id, workspace_id));
            CREATE TABLE scopes(
              workspace_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT, description TEXT,
              default_channel_id TEXT, row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
              PRIMARY KEY(workspace_id, id));
            CREATE TABLE channels(
              workspace_id TEXT NOT NULL, id TEXT NOT NULL, scope_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT,
              position REAL, row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
              PRIMARY KEY(workspace_id, id));
            CREATE INDEX channels_scope ON channels(workspace_id, scope_id, position, name);
            CREATE TABLE messages(
              workspace_id TEXT NOT NULL, id TEXT NOT NULL, channel_id TEXT NOT NULL, thread_id TEXT, body TEXT NOT NULL,
              sender_npub TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, row_version INTEGER NOT NULL,
              deleted INTEGER NOT NULL DEFAULT 0, raw BLOB NOT NULL,
              PRIMARY KEY(workspace_id, id));
            CREATE INDEX messages_channel_time ON messages(workspace_id, channel_id, created_at, id);
            CREATE TABLE app_state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            PRAGMA user_version = 1;
            """)
            try db.prepare("INSERT INTO connections VALUES ('c1', 'https://tower.example', ?, NULL, '2026-10-24T00:00:00Z')").run([.text(TestKeys.npub)])
            let raw = try Fixtures.json(Fixtures.workspace(Fixtures.workspaceId, label: "Studio"))
            try db.prepare("INSERT INTO workspaces VALUES ('c1', ?, ?, 'Studio', NULL, NULL, NULL, NULL, ?, '2026-10-24T00:00:00Z')")
                .run([.text(Fixtures.workspaceId), .text(Fixtures.appNpub), .blob(raw)])
            try db.prepare("INSERT INTO app_state VALUES ('selected.connection', 'c1'), ('selected.workspace:c1', ?)").run([.text(Fixtures.workspaceId)])
        }
        let store = try LocalStore(directory: directory)
        let v10 = try await store.writer.schemaVersion()
        XCTAssertEqual(v10, Schema.version)
        let v11 = try await store.reader.connections().map(\.origin)
        XCTAssertEqual(v11, ["https://tower.example"])
        let v12 = try await store.reader.workspaces(connectionId: "c1").map(\.label)
        XCTAssertEqual(v12, ["Studio"])
        let v13 = try await store.reader.state("selected.workspace:c1")
        XCTAssertEqual(v13, Fixtures.workspaceId)
    }

    /// The sealed vault is unreadable while the iPhone is locked (complete file protection). That is an identity that
    /// cannot be opened yet, not a missing one: no import is accepted over it and it is recovered once readable.
    func testUnreadableVaultIsUnavailableNotMissingAndRecovers() async throws {
        let data = temporaryDirectory()
        let secrets = MemorySecretStore()
        let session = MemorySessionStore()
        let vaultURL = ProductionStorage.vaultURL(data)
        do {
            let identity = IdentityService(vaultURL: vaultURL, secrets: secrets, session: session)
            try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        }
        let original = try Data(contentsOf: vaultURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vaultURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path) }
        guard (try? Data(contentsOf: vaultURL)) == nil else { throw XCTSkip("running with privileges that ignore file permissions") }

        let identity = IdentityService(vaultURL: vaultURL, secrets: secrets, session: session)
        let v14 = await identity.resumeSession()
        XCTAssertFalse(v14)
        let v15 = await identity.state
        XCTAssertEqual(v15, .unavailable)
        let v16 = await identity.state.npub
        XCTAssertNil(v16)
        // A fresh import would replace the account: refused while any vault exists.
        do { try await identity.importIdentity(nsec: TestKeys.otherNsec(), pin: TestKeys.pin); XCTFail("import over an existing vault") }
        catch { XCTAssertEqual(error as? IdentityError, .exists) }

        // The iPhone is unlocked: the same process reads the vault and resumes the trusted-device session.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
        let v17 = await identity.refreshAvailability()
        XCTAssertEqual(v17, .unlocked(npub: TestKeys.npub))
        XCTAssertEqual(try Data(contentsOf: vaultURL), original, "the vault bytes are untouched")
    }

    /// Without a session (after Lock now) a recovered vault comes back locked and asks for the PIN, never for an import.
    func testRecoveredVaultWithoutSessionIsLocked() async throws {
        let data = temporaryDirectory()
        let secrets = MemorySecretStore()
        let vaultURL = ProductionStorage.vaultURL(data)
        do {
            let identity = IdentityService(vaultURL: vaultURL, secrets: secrets, session: MemorySessionStore())
            try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
            await identity.lock()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vaultURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path) }
        guard (try? Data(contentsOf: vaultURL)) == nil else { throw XCTSkip("running with privileges that ignore file permissions") }
        let identity = IdentityService(vaultURL: vaultURL, secrets: secrets, session: MemorySessionStore())
        let v18 = await identity.state
        XCTAssertEqual(v18, .unavailable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
        let v19 = await identity.refreshAvailability()
        XCTAssertEqual(v19, .locked(npub: TestKeys.npub))
        let v20 = try await identity.unlock(pin: TestKeys.pin)
        XCTAssertEqual(v20, .unlocked(npub: TestKeys.npub))
    }

    /// An unreadable Keychain secret fails the unlock with a kept-identity error and leaves the vault as it was.
    func testKeychainUnavailableKeepsTheVault() async throws {
        let data = temporaryDirectory()
        let vaultURL = ProductionStorage.vaultURL(data)
        let secrets = MemorySecretStore()
        do {
            let identity = IdentityService(vaultURL: vaultURL, secrets: secrets)
            try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        }
        let original = try Data(contentsOf: vaultURL)
        let identity = IdentityService(vaultURL: vaultURL, secrets: UnavailableSecretStore())
        let v21 = await identity.state
        XCTAssertEqual(v21, .locked(npub: TestKeys.npub))
        do { try await identity.unlock(pin: TestKeys.pin); XCTFail("unlocked without the Keychain secret") }
        catch { XCTAssertEqual(error as? IdentityError, .keychainUnavailable) }
        let v22 = await identity.state
        XCTAssertEqual(v22, .locked(npub: TestKeys.npub))
        XCTAssertEqual(try Data(contentsOf: vaultURL), original)
        // With the secret readable again the same PIN works.
        let recovered = IdentityService(vaultURL: vaultURL, secrets: secrets)
        let v23 = try await recovered.unlock(pin: TestKeys.pin)
        XCTAssertEqual(v23, .unlocked(npub: TestKeys.npub))
    }
}


extension AccountRetentionTests {
    /// Lifecycle refreshes never disturb an identity that is already open in memory.
    func testRefreshDoesNotClobberAnUnlockedIdentity() async throws {
        let data = temporaryDirectory()
        let identity = IdentityService(vaultURL: ProductionStorage.vaultURL(data), secrets: MemorySecretStore(), session: MemorySessionStore())
        try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        for _ in 0..<3 {
            let state = await identity.refreshAvailability()
            XCTAssertEqual(state, .unlocked(npub: TestKeys.npub))
        }
        let event = try await identity.sign(NostrEventTemplate(kind: 1, tags: [], content: "still signing", createdAt: 1))
        XCTAssertEqual(event.pubkey, TestKeys.pubkeyHex)
        let problem = await identity.vaultProblem
        XCTAssertNil(problem)
    }

    /// A damaged vault is reported as damaged (not sealed, not missing), kept byte for byte, and never replaced.
    func testDamagedVaultIsSurfacedSeparatelyAndKept() async throws {
        let data = temporaryDirectory()
        let vaultURL = ProductionStorage.vaultURL(data)
        try FileManager.default.createDirectory(at: vaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{\"version\":1,\"truncated".utf8)
        try garbage.write(to: vaultURL)
        let identity = IdentityService(vaultURL: vaultURL, secrets: MemorySecretStore(), session: MemorySessionStore())
        let state = await identity.state
        XCTAssertEqual(state, .unavailable)
        let problem = await identity.vaultProblem
        XCTAssertEqual(problem, .damaged)
        do { try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin); XCTFail("import over a damaged vault") }
        catch { XCTAssertEqual(error as? IdentityError, .exists) }
        XCTAssertEqual(try Data(contentsOf: vaultURL), garbage)
    }

    /// With a Tower connection on the device, only that connection's identity can be imported.
    func testImportIsBoundToTheExistingConnectionIdentity() async throws {
        let identity = IdentityService(vaultURL: ProductionStorage.vaultURL(temporaryDirectory()), secrets: MemorySecretStore())
        do { try await identity.importIdentity(nsec: TestKeys.otherNsec(), pin: TestKeys.pin, requiredNpub: TestKeys.npub); XCTFail("imported another key") }
        catch { XCTAssertEqual(error as? IdentityError, .accountMismatch) }
        let none = await identity.state
        XCTAssertEqual(none, .none)
        let state = try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin, requiredNpub: TestKeys.npub)
        XCTAssertEqual(state, .unlocked(npub: TestKeys.npub))
    }

    /// After process death on a locked iPhone the vault is sealed, but the user-enabled background read credential still
    /// loads (matched by the public-key hint). It reads only; the identity is not shown as unlocked and nothing can be written.
    func testBackgroundCredentialStillLoadsWhileTheVaultIsSealed() async throws {
        let data = temporaryDirectory()
        let vaultURL = ProductionStorage.vaultURL(data)
        let secrets = MemorySecretStore(), background = MemoryBackgroundStore()
        do {
            let identity = IdentityService(vaultURL: vaultURL, secrets: secrets, background: background, session: MemorySessionStore())
            try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
            try await identity.enableBackgroundRead(origin: try TowerOrigin("https://tower.example"), workspaceIds: [Fixtures.workspaceId])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vaultURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path) }
        guard (try? Data(contentsOf: vaultURL)) == nil else { throw XCTSkip("running with privileges that ignore file permissions") }
        let identity = IdentityService(vaultURL: vaultURL, secrets: secrets, background: background, session: MemorySessionStore())
        let loaded = await identity.loadBackgroundRead()
        XCTAssertTrue(loaded, "the background credential is matched by the public-key hint")
        let canRead = await identity.canReadWhileLocked
        XCTAssertTrue(canRead)
        let state = await identity.state
        XCTAssertEqual(state, .unavailable, "the UI is not unlocked by the background credential")
        let problem = await identity.vaultProblem
        XCTAssertEqual(problem, .unreadable)
        do { try await identity.requireReader(npub: TestKeys.npub) } catch { XCTFail("reads allowed: \(error)") }
        do { try await identity.requireSigner(npub: TestKeys.npub); XCTFail("writes need the unlocked vault") }
        catch { XCTAssertEqual(error as? IdentityError, .locked) }
    }

    /// A vault from an earlier build (no hint yet) gets its hint the first time it is read, so later sealed launches work.
    func testHintIsAddedForAVaultFromAnEarlierBuild() async throws {
        let data = temporaryDirectory()
        let vaultURL = ProductionStorage.vaultURL(data)
        let secrets = MemorySecretStore()
        do {
            let identity = IdentityService(vaultURL: vaultURL, secrets: secrets)
            try await identity.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        }
        let hint = vaultURL.deletingLastPathComponent().appendingPathComponent("vault.pub")
        try FileManager.default.removeItem(at: hint)   // as left by builds 1-5
        let identity = IdentityService(vaultURL: vaultURL, secrets: secrets)
        let state = await identity.state
        XCTAssertEqual(state, .locked(npub: TestKeys.npub))
        XCTAssertEqual(try String(contentsOf: hint, encoding: .utf8), TestKeys.pubkeyHex)
        XCTAssertFalse(try String(contentsOf: hint, encoding: .utf8).contains("nsec"), "the hint holds only the public key")
    }
}

/// Keychain secret that cannot be read (as while the iPhone is locked: errSecInteractionNotAllowed).
struct UnavailableSecretStore: VaultSecretStore {
    func read() throws -> Data? { throw IdentityError.keychainUnavailable }
    func write(_ data: Data) throws { throw IdentityError.keychainUnavailable }
}
