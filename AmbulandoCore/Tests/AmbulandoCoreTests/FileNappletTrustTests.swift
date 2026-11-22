import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct FileNappletTrustTests {
    func receipt(_ fixture: FileNappletFixture = FileNappletFixture(), connection: ConnectionRecord? = nil, workspace: WorkspaceRecord? = nil, writable: Bool = true, version: String = "one") throws -> FileNappletTrustReceipt {
        let c = try connection ?? ConnectionRecord(origin: TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let w = try workspace ?? WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId, label: "Studio")))
        let code = FileNappletCode(html: fixture.html, binding: try FileNappletBinding.parse(html: fixture.html, metadata: rawJSON(fixture.metadata)), versionId: version)
        return try FileNappletTrustReceipt(connection: c, workspace: w, codeFile: fixture.codeId, code: code, canWrite: writable)
    }
    func store() -> FileNappletTrustStore { FileNappletTrustStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }

    @Test func firstApprovalReopenDataEditsAndForget() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let f = FileNappletFixture(), c = try ConnectionRecord(origin: TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let initial = try receipt(f, connection: c)
        #expect(initial.codeSHA256 == SHA256Hex.of(Data(f.html.utf8)))
        #expect(!store.contains(initial))
        try store.remember(initial)
        let normalized = try ConnectionRecord(id: c.id, origin: TowerOrigin("https://TOWER.EXAMPLE:443/"), signerNpub: c.signerNpub, towerNpub: nil)
        #expect(store.contains(try receipt(f, connection: normalized)))
        // Recreate store like a process restart. The data File and code revision are deliberately absent.
        f.bytes = Data("{\"format\":\"daily-tracker-v1\",\"metrics\":[],\"days\":{\"2026-01-01\":{}}}".utf8); f.revision += 1
        let reopened = FileNappletTrustStore(directory: store.directory)
        #expect(reopened.contains(try receipt(f, connection: c, version: "identical bytes new version")))
        let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
        let bytes = try Data(contentsOf: files[0]); let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("days")); #expect(!text.contains("<script")); #expect(!text.contains("2026-01-01"))
        #expect(try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try reopened.forget(initial); #expect(!store.contains(initial))
    }
    @Test func changedCodeAccessAndContextCannotReuseApproval() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let f = FileNappletFixture(), c = try ConnectionRecord(origin: TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let initial = try receipt(f, connection: c); try store.remember(initial)
        f.codeSuffix = "<!-- changed executable bytes -->"
        #expect(!store.contains(try receipt(f, connection: c)))
        f.codeSuffix = ""
        #expect(!store.contains(try receipt(f, connection: c, writable: false)))
        for other in [
            try ConnectionRecord(origin: TowerOrigin("https://other.example"), signerNpub: TestKeys.npub, towerNpub: nil),
            try ConnectionRecord(origin: TowerOrigin("https://tower.example"), signerNpub: "other-viewer", towerNpub: nil),
            try ConnectionRecord(origin: TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: "other-service")
        ] { #expect(!store.contains(try receipt(f, connection: other))) }
        var changedService = c; changedService.towerNpub = "changed-service"
        #expect(!store.contains(try receipt(f, connection: changedService)))
        let changedViewer = try ConnectionRecord(id: c.id, origin: TowerOrigin(c.origin), signerNpub: "changed-viewer", towerNpub: nil)
        #expect(!store.contains(try receipt(f, connection: changedViewer)))
        let w = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId2, label: "Other")))
        #expect(!store.contains(try receipt(f, connection: c, workspace: w)))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as! [String: Any]
        for (key, value): (String, Any) in [("dataFile", UUID().uuidString), ("codeFile", UUID().uuidString), ("app", "other"), ("policyVersion", 2), ("manifestVersion", 2), ("operations", ["read"]), ("format", "other"), ("privacy", "shared")] {
            var changed = object; changed[key] = value
            let receipt = try JSONDecoder().decode(FileNappletTrustReceipt.self, from: rawJSON(changed))
            #expect(!store.contains(receipt))
        }
        object["codeSHA256"] = "wrong"
        try rawJSON(object).write(to: store.directory.appendingPathComponent(initial.slot + ".json"))
        #expect(!store.contains(initial))
    }
    @Test func malformedMissingAndUnavailableStorageFailClosed() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let receipt = try receipt()
        #expect(!store.contains(receipt))
        try store.remember(receipt)
        let file = store.directory.appendingPathComponent(receipt.slot + ".json")
        for bytes in [Data("null".utf8), Data("{}".utf8), Data("truncated".utf8), Data(repeating: 32, count: 20000)] {
            try bytes.write(to: file); #expect(!store.contains(receipt))
        }
        let blocked = store.directory.appendingPathComponent("file-not-directory")
        try Data().write(to: blocked)
        let denied = FileNappletTrustStore(directory: blocked)
        #expect(!denied.contains(receipt))
        #expect(throws: (any Error).self) { try denied.remember(receipt) }
    }
}
