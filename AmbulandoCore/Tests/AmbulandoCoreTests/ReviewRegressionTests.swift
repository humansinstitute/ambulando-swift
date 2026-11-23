import Foundation
import XCTest
@testable import AmbulandoCore

final class ReviewRegressionTests: XCTestCase {
    func testHeadInsertionRetainsDoctypeAndDocumentStructure() {
        for html in ["<!DOCTYPE html><html><head><title>Test</title></head><body>OK</body></html>",
                     "\u{FEFF} <!--before-->\n<!doctype HTML>\n<html lang='en'><body>OK</body></html>",
                     "<!doctype html><p>fragment</p>", "<p>fragment</p>"] {
            let result = ArtefactHTMLDocument.insertingHeadContent("<script>window.test=1</script>", into: html)
            let script = result.range(of: "<script>")!
            let doctype = result.range(of: "<!doctype", options: .caseInsensitive)!
            XCTAssertLessThan(doctype.lowerBound, script.lowerBound)
            XCTAssertTrue(result.contains("<head><script>"))
            XCTAssertEqual(result.components(separatedBy: "<script>").count, 2)
            XCTAssertTrue(result.contains(html.contains("fragment") ? "fragment" : "OK"))
        }
    }

    func testHTMLDraftIsolationAndExplicitLegacyReviewPreserveOriginal() throws {
        let directory = temporaryDirectory()
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let workspace = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId, label: "Workspace")))
        let boundary = try WorkspaceBoundary(connection: connection, workspace: workspace)
        let file = UUID().uuidString.lowercased()
        let store = HTMLSourceDraftStore(directory: directory, boundary: boundary, fileId: file, allowLegacy: true)
        let old = HTMLSourceDraftStore.Draft(base: "old-version", source: "unsaved original")
        try JSONEncoder().encode(old).write(to: XCTUnwrap(store.legacyURL))
        XCTAssertNil(store.load(), "Unscoped legacy content must never auto-load into an application boundary")
        XCTAssertEqual(store.legacyForReview(), old)
        try store.save(old)
        XCTAssertEqual(store.load(), old)
        XCTAssertEqual(store.legacyForReview(), old, "Import preserves the original recovery file")
        let foreign = ConnectionRecord(origin: try TowerOrigin("https://other.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let other = HTMLSourceDraftStore(directory: directory, boundary: try WorkspaceBoundary(connection: foreign, workspace: workspace), fileId: file, allowLegacy: false)
        XCTAssertNil(other.load())
        XCTAssertNil(other.legacyForReview(), "Fixtures and unrelated boundaries never inspect legacy production drafts")
        try store.remove()
        XCTAssertEqual(store.legacyForReview(), old)
    }

    func testChannelRevocationPurgesOnlyUnsharedCachedBytesAndKeepsDrafts() async throws {
        let h = try await WorkHarness.make()
        let cache = FileCache(root: temporaryDirectory())
        await h.store.writer.bindFileCache(cache)
        let bytes = Data("verified source".utf8)
        let goneId = h.work.seedFile(channel: Fixtures.channel1, scope: Fixtures.scopeA, name: "gone.html", bytes: bytes, contentType: "text/html")
        let keptId = h.work.seedFile(channel: Fixtures.channel2, scope: Fixtures.scopeA, name: "kept.html", bytes: bytes, contentType: "text/html")
        let gone = try FileRecord(raw: Fixtures.json(XCTUnwrap(h.work.file(goneId))))
        let kept = try FileRecord(raw: Fixtures.json(XCTUnwrap(h.work.file(keptId))))
        _ = try await h.store.writer.upsertFiles(workspaceId: h.workspace.id, [gone, kept])
        let goneURL = try cache.store(bytes, for: gone), keptURL = try cache.store(bytes, for: kept)
        let orphan = UUID().uuidString.lowercased(), shared = UUID().uuidString.lowercased(), recovery = UUID().uuidString.lowercased()
        let docImage = UUID().uuidString.lowercased(), commentImage = UUID().uuidString.lowercased()
        let attachmentRoot = cache.root.appendingPathComponent(h.workspace.id).appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: attachmentRoot, withIntermediateDirectories: true)
        for id in [orphan, shared, recovery, docImage, commentImage] { try bytes.write(to: attachmentRoot.appendingPathComponent(id)) }
        let removed = MessageRecord(workspaceId: h.workspace.id, id: UUID().uuidString.lowercased(), channelId: Fixtures.channel1,
            body: [orphan, shared, recovery, docImage, commentImage].map { StorageMarkdown.file(objectId: $0, name: "asset") }.joined(separator: " "), createdAt: "2026-11-01")
        let retained = MessageRecord(workspaceId: h.workspace.id, id: UUID().uuidString.lowercased(), channelId: Fixtures.channel2,
            body: StorageMarkdown.file(objectId: shared, name: "shared"), createdAt: "2026-11-01")
        _ = try await h.store.writer.upsertMessages([removed, retained])
        let docId = UUID().uuidString.lowercased(), objectId = UUID().uuidString.lowercased()
        let doc = DocRecord(workspaceId: h.workspace.id, id: docId, scopeId: Fixtures.scopeA, channelId: Fixtures.channel2,
                            storageObjectId: objectId, title: "Surviving document", summary: nil, rowVersion: 1, createdAt: "2026-11-01", updatedAt: "2026-11-01")
        let docBytes = Data("{\"image\":\"storage://\(docImage)\"}".utf8)
        try await h.store.writer.saveDocBody(DocBodyRecord(workspaceId: h.workspace.id, docId: docId, storageObjectId: objectId,
            sha256: SHA256Hex.of(docBytes), contentType: "application/json", docRowVersion: 1, bytes: docBytes, fetchedAt: "2026-11-01"), doc: doc, searchText: "")
        let comment = CommentRecord(workspaceId: h.workspace.id, id: UUID().uuidString.lowercased(), parent: .doc, parentId: docId,
            body: StorageMarkdown.image(objectId: commentImage, alt: "shared image"), senderNpub: nil, createdAt: "2026-11-01")
        _ = try await h.store.writer.upsertComments(workspaceId: h.workspace.id, [comment])
        let target = h.chat.target()
        try await h.store.writer.saveDraft(target, Draft(text: StorageMarkdown.file(objectId: recovery, name: "draft"), mentions: []))
        let loadedChannel = try await h.store.reader.channel(workspaceId: h.workspace.id, id: Fixtures.channel2)
        let channel = try XCTUnwrap(loadedChannel)
        _ = try await h.store.writer.upsertChannels(workspaceId: h.workspace.id, scopeId: Fixtures.scopeA, [channel], complete: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: goneURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptURL.path))
        XCTAssertNil(cache.attachment(workspaceId: h.workspace.id, objectId: orphan))
        XCTAssertNotNil(cache.attachment(workspaceId: h.workspace.id, objectId: shared))
        XCTAssertNotNil(cache.attachment(workspaceId: h.workspace.id, objectId: recovery))
        XCTAssertNotNil(cache.attachment(workspaceId: h.workspace.id, objectId: docImage))
        XCTAssertNotNil(cache.attachment(workspaceId: h.workspace.id, objectId: commentImage))
        let draft = try await h.store.reader.draft(target)
        XCTAssertEqual(draft?.text, StorageMarkdown.file(objectId: recovery, name: "draft"))
    }
    func testRevocationRetainsOriginalsForPendingCommandsAndBoardOrHTMLRecovery() async throws {
        let h = try await WorkHarness.make(), recoveryRoot = temporaryDirectory()
        let cache = FileCache(root: temporaryDirectory()), bytes = Data("original".utf8)
        await h.store.writer.bindFileCache(cache, recoveryDirectories: [recoveryRoot])
        var urls: [URL] = []
        for mode in 0..<3 {
            let id = h.work.seedFile(channel: Fixtures.channel1, scope: Fixtures.scopeA, name: "original-\(mode).html", bytes: bytes, contentType: "text/html")
            let file = try FileRecord(raw: Fixtures.json(XCTUnwrap(h.work.file(id))))
            _ = try await h.store.writer.upsertFiles(workspaceId: h.workspace.id, [file])
            urls.append(try cache.store(bytes, for: file))
            if mode == 0 {
                _ = try await h.store.writer.enqueueWrite(connection: h.connection, workspace: h.workspace,
                    intent: WriteIntent(kind: .pinSet, targetId: id, payload: ["resource_type": "file", "resource_id": id, "pinned": true]))
            } else {
                let name = mode == 1 ? id + ".json" : "html-" + h.workspace.id + "-" + id + ".json"
                try Data("{\"source\":\"unsaved\"}".utf8).write(to: recoveryRoot.appendingPathComponent(name))
            }
        }
        _ = try await h.store.writer.upsertChannels(workspaceId: h.workspace.id, scopeId: Fixtures.scopeA, [], complete: true)
        for url in urls { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path).count, 2)
        let pending = try await h.store.reader.writes(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(pending.count, 1)
    }

    func testCacheCleanupFailureStillPublishesAuthoritativeRevocation() async throws {
        let h = try await WorkHarness.make(), root = temporaryDirectory()
        let cache = FileCache(root: root)
        await h.store.writer.bindFileCache(cache)
        // A malformed local cache directory simulates a filesystem failure after the database commit.
        try Data("not a directory".utf8).write(to: root.appendingPathComponent(h.workspace.id))
        let stream = await h.store.changes.stream()
        let observed = Task { () -> Bool in
            for await keys in stream {
                if keys.contains(ChangeKey(.access, h.workspace.id)) { return true }
                if Task.isCancelled { return false }
            }
            return false
        }
        let deadline = Task { try? await Task.sleep(for: .seconds(3)); observed.cancel() }
        defer { observed.cancel(); deadline.cancel() }
        _ = try await h.store.writer.upsertChannels(workspaceId: h.workspace.id, scopeId: Fixtures.scopeA, [], complete: true)
        let channel = try await h.store.reader.channel(workspaceId: h.workspace.id, id: Fixtures.channel1)
        let failure = try await h.store.reader.state("cache-cleanup-failed:" + h.workspace.id)
        XCTAssertNil(channel)
        XCTAssertNotNil(failure)
        let published = await observed.value
        XCTAssertTrue(published)
    }

    func testInflightDownloadCannotRecreateBytesAfterRevocation() async throws {
        let h = try await WorkHarness.make(), bytes = Data("old download".utf8)
        let cache = FileCache(root: temporaryDirectory())
        let id = h.work.seedFile(channel: Fixtures.channel1, scope: Fixtures.scopeA, name: "original.html", bytes: bytes, contentType: "text/html")
        let file = try FileRecord(raw: Fixtures.json(XCTUnwrap(h.work.file(id))))
        _ = try await h.store.writer.upsertFiles(workspaceId: h.workspace.id, [file])
        await h.store.writer.bindFileCache(cache)
        let lease = await h.store.writer.fileCacheLease()
        _ = try await h.store.writer.upsertChannels(workspaceId: h.workspace.id, scopeId: Fixtures.scopeA, [], complete: true)
        do {
            _ = try await h.store.writer.cacheFile(bytes, for: file, cache: cache, lease: lease)
            XCTFail("A download begun before revocation must not recreate the removed File")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(cache.cached(file))
    }

    func testLocalSearchDistinguishesHTMLWhiteboardsAndOrdinaryFiles() async throws {
        let h = try await WorkHarness.make()
        for (name, mime) in [("Review HTML.html", "text/html"), ("Review Board.excalidraw", "application/vnd.excalidraw+json"), ("Review PDF.pdf", "application/pdf")] {
            let id = h.work.seedFile(channel: Fixtures.channel1, scope: Fixtures.scopeA, name: name, bytes: Data("content".utf8), contentType: mime)
            let file = try FileRecord(raw: Fixtures.json(XCTUnwrap(h.work.file(id))))
            _ = try await h.store.writer.upsertFiles(workspaceId: h.workspace.id, [file])
        }
        let hits = try await h.store.reader.search(workspaceId: h.workspace.id, text: "Review")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.first { $0.title == "Review HTML.html" }?.artefactType, .html)
        XCTAssertEqual(hits.first { $0.title == "Review HTML.html" }?.snippet, "HTML artefact")
        XCTAssertEqual(hits.first { $0.title == "Review Board.excalidraw" }?.artefactType, .whiteboard)
        XCTAssertEqual(hits.first { $0.title == "Review Board.excalidraw" }?.snippet, "Whiteboard")
        XCTAssertNil(hits.first { $0.title == "Review PDF.pdf" }?.artefactType)
    }

}
