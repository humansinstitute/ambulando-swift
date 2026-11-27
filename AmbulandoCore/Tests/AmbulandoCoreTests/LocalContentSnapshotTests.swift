import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct LocalContentSnapshotTests {
    func fixture() async throws -> (LocalStore, IdentityService, WorkspaceBoundary) {
        let store = try LocalStore(directory: temporaryDirectory())
        let identity = try await makeIdentity()
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        let workspace = try WorkspaceRecord(raw: rawJSON(Fixtures.workspace(Fixtures.workspaceId, label: "Cache")))
        return (store, identity, try WorkspaceBoundary(connection: connection, workspace: workspace))
    }
    @Test func durableSealedContentRequiresUnlockedBoundIdentityAndRejectsCorruption() async throws {
        let (store, identity, boundary) = try await fixture()
        let cache = LocalContentSnapshot(store: store, identity: identity, boundary: boundary)
        let bytes = Data(repeating: 65, count: 180000) // cross the existing NIP44 envelope limit
        try await cache.save("code-and-data", bytes)
        let reopened = try LocalStore(directory: URL(fileURLWithPath: store.path).deletingLastPathComponent())
        let restored = LocalContentSnapshot(store: reopened, identity: identity, boundary: boundary)
        #expect(try await restored.read("code-and-data") == bytes)
        #expect(try await restored.read("different-version") == nil)
        let key = "local-content.v1:" + boundary.id + ":" + WorkspaceBoundary.digest(["code-and-data"])
        let sealed = try #require(await store.reader.state(key))
        #expect(!sealed.contains(String(repeating: "A", count: 100)))
        await identity.lock()
        await #expect(throws: IdentityError.locked) { try await restored.read("code-and-data") }
        _ = try await identity.unlock(pin: TestKeys.pin)
        let other = ConnectionRecord(origin: try TowerOrigin("https://other.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        let workspace = try WorkspaceRecord(raw: rawJSON(Fixtures.workspace(Fixtures.workspaceId, label: "Other")))
        let otherBoundary = try WorkspaceBoundary(connection: other, workspace: workspace)
        let otherKey = "local-content.v1:" + otherBoundary.id + ":" + WorkspaceBoundary.digest(["code-and-data"])
        try await store.writer.setState(otherKey, sealed)
        #expect(try await LocalContentSnapshot(store: store, identity: identity, boundary: otherBoundary).read("code-and-data") == nil)
        let secondWorkspace = try WorkspaceRecord(raw: rawJSON(Fixtures.workspace(Fixtures.workspaceId2, label: "Second")))
        let secondBoundary = try WorkspaceBoundary(connection: other, workspace: secondWorkspace)
        let secondKey = "local-content.v1:" + secondBoundary.id + ":" + WorkspaceBoundary.digest(["code-and-data"])
        try await store.writer.setState(secondKey, sealed)
        #expect(try await LocalContentSnapshot(store: store, identity: identity, boundary: secondBoundary).read("code-and-data") == nil)
        let secondIdentity = IdentityService(vaultURL: temporaryDirectory().appendingPathComponent("vault.json"), secrets: MemorySecretStore())
        try await secondIdentity.importIdentity(nsec: TestKeys.otherNsec(), pin: TestKeys.pin)
        await #expect(throws: IdentityError.signerMismatch) {
            try await LocalContentSnapshot(store: store, identity: secondIdentity, boundary: boundary).read("code-and-data")
        }
        try await store.writer.setState(key, "corrupt")
        await #expect(throws: (any Error).self) { try await restored.read("code-and-data") }
    }
    @Test func knownRemovalEvictsReadSnapshotsButPreservesDraftState() async throws {
        let (store, identity, boundary) = try await fixture()
        let cache = LocalContentSnapshot(store: store, identity: identity, boundary: boundary)
        try await cache.save("goals", Data("verified".utf8), dependencies: ["known-removed"])
        try await cache.save("unrelated", Data("retained".utf8), dependencies: ["other-file"])
        try await store.writer.setState("draft-recovery", "unsent")
        await store.writer.touch([ChangeKey(.access, boundary.workspaceId), ChangeKey(.files, boundary.workspaceId)])
        #expect(try await cache.read("goals") != nil) // generic access notifications do not erase content
        try await store.writer.invalidateLocalContent(workspace: boundary.workspaceId, record: "known-removed")
        #expect(try await cache.read("goals") == nil)
        #expect(try await cache.read("unrelated") == Data("retained".utf8))
        #expect(try await store.reader.state("draft-recovery") == "unsent")
    }
    @Test func lateReadCannotResurrectKnownRemovedContent() async throws {
        let (store, identity, boundary) = try await fixture()
        let cache = LocalContentSnapshot(store: store, identity: identity, boundary: boundary)
        let started = try await cache.epoch()
        try await store.writer.invalidateLocalContent(workspace: boundary.workspaceId, record: "removed-file")
        try await cache.save("late", Data("stale".utf8), dependencies: ["removed-file"], expectedEpoch: started)
        #expect(try await cache.read("late") == nil)
    }
    @Test func authenticationExpiryAndNetworkFailureDoNotRevokeSavedContent() {
        #expect(!CachedContentFailure.invalidates(URLError(.notConnectedToInternet)))
        #expect(!CachedContentFailure.invalidates(FileNappletError.invalid)) // Failed newer code/data validation cannot revoke an older verified snapshot.
        #expect(!CachedContentFailure.invalidates(TowerError.http(status: 401, code: nil, stage: nil)))
    }
}
