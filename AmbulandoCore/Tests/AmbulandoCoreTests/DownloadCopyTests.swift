import XCTest
@testable import AmbulandoCore

final class DownloadCopyTests: XCTestCase {
    func testAuthenticatedExportFailureThenRetryAndCacheIntegrity() async throws {
        let h = try await WorkHarness.make()
        let bytes = Data([0, 1, 255, 4, 0])
        let id = h.work.seedFile(channel: Fixtures.channel1, scope: Fixtures.scopeA, name: "Package.dmg", bytes: bytes, contentType: "application/octet-stream")
        let raw = try XCTUnwrap(h.work.file(id))
        let file = try FileRecord(raw: JSONSerialization.data(withJSONObject: raw))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FileCache(root: root)
        h.work.inject(.status(503, "unavailable"), matching: "/files/\(id)/object")
        do {
            _ = try await h.sync.fileForExport(h.connection, h.workspace, file: file, cache: cache)
            XCTFail("Failed HTTP response must not export")
        } catch {}
        XCTAssertNil(cache.cached(file))
        let url = try await h.sync.fileForExport(h.connection, h.workspace, file: file, cache: cache)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let reads = h.transport.recorded.filter { $0.url!.path.hasSuffix("/object") }
        XCTAssertEqual(reads.count, 2)
        XCTAssertTrue(reads.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") != nil })
        XCTAssertTrue(h.work.credentialLeaks.isEmpty)
        // Corrupt local bytes must be refetched before export.
        try Data("corrupt".utf8).write(to: url)
        let restored = try await h.sync.fileForExport(h.connection, h.workspace, file: file, cache: cache)
        XCTAssertEqual(try Data(contentsOf: restored), bytes)
    }

    func testSavedBytesCollisionAndFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cached")
        let bytes = Data([0, 1, 255, 5, 0])
        try bytes.write(to: source)
        let first = try DownloadCopy.save(source, name: "Pi-Mac-0.1.0-5-arm64.dmg", directory: root)
        let second = try DownloadCopy.save(source, name: "Pi-Mac-0.1.0-5-arm64.dmg", directory: root)
        XCTAssertEqual(first.lastPathComponent, "Pi-Mac-0.1.0-5-arm64.dmg")
        XCTAssertEqual(second.lastPathComponent, "Pi-Mac-0.1.0-5-arm64 (1).dmg")
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(try Data(contentsOf: second), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let safe = try DownloadCopy.save(source, name: "../escape.dmg", directory: root)
        XCTAssertEqual(safe.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
    }

    func testFailureDoesNotCreateSuccessFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try DownloadCopy.save(root, name: "missing.dmg", directory: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
