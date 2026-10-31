import Foundation
import XCTest
@testable import AmbulandoCore

final class DocumentMergeTests: XCTestCase {
    func raw(_ text: String, version: Int = 6, title: String = "Plan") -> PreservedDocumentSnapshot {
        let bytes = Data(text.utf8)
        return PreservedDocumentSnapshot(title: title, bytes: bytes, contentType: "text/markdown", rowVersion: version,
                                sha256: SHA256Hex.of(bytes), storageObjectId: "object-\(version)")
    }
    func rich(_ text: String, version: Int = 6) -> PreservedDocumentSnapshot {
        let body = DocumentBody.newDocument(text: text)
        let decoded = DocumentBody(bytes: body.bytes, contentType: body.contentType)
        let nodes = decoded.editorState!["content"]!.arrayValue!.map { $0.setting("attrs", nil) }
        let bytes = try! decoded.encoded(editorState: decoded.editorState!.setting("content", .array(nodes))).bytes
        return PreservedDocumentSnapshot(title: "Plan", bytes: bytes, contentType: body.contentType, rowVersion: version,
                                sha256: SHA256Hex.of(bytes), storageObjectId: "object-\(version)")
    }
    func testV6LocalAndV8RemoteIndependentEditsRetainBothAndTitle() throws {
        let result = try DocumentMerge.merge(base: raw("Alpha\nBeta\nGamma"),
            local: raw("Local Alpha\nBeta\nGamma", title: "Local title"), latest: raw("Alpha\nBeta\nRemote Gamma", version: 8))
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(String(decoding: result.bytes, as: UTF8.self), "Local Alpha\nBeta\nRemote Gamma")
        XCTAssertEqual(result.title, "Local title")
    }
    func testRichParagraphAndWithinParagraphIndependentChanges() throws {
        let result = try DocumentMerge.merge(base: rich("Alpha beta gamma\n\nLast"),
            local: rich("Local Alpha beta gamma\n\nLast"), latest: rich("Alpha beta remote gamma\n\nRemote Last", version: 8))
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(DocumentBody(bytes: result.bytes, contentType: result.contentType).markdown, "Local Alpha beta remote gamma\n\nRemote Last")
    }
    func testOverlappingEditsAndTitleNeedExplicitChoices() throws {
        let b = raw("old", title: "Original"), l = raw("mine", title: "Mine"), r = raw("theirs", version: 8, title: "Theirs")
        let first = try DocumentMerge.merge(base: b, local: l, latest: r)
        XCTAssertEqual(Set(first.conflicts.map(\.id)), ["/body", "/title"])
        let resolved = try DocumentMerge.merge(base: b, local: l, latest: r, choices: ["/body": .local, "/title": .latest])
        XCTAssertTrue(resolved.conflicts.isEmpty)
        XCTAssertEqual(resolved.title, "Theirs")
        XCTAssertEqual(resolved.bytes, l.bytes)
    }
    func testDeletionVersusEditIsConflictAndIndependentInsertionIsCombined() throws {
        let b = rich("One\n\nTwo\n\nThree")
        let result = try DocumentMerge.merge(base: b, local: rich("One\n\nThree"), latest: rich("One\n\nChanged Two\n\nThree", version: 8))
        XCTAssertFalse(result.conflicts.isEmpty)
        let independent = try DocumentMerge.merge(base: b, local: rich("Inserted\n\nOne\n\nTwo\n\nThree"), latest: rich("One\n\nTwo\n\nChanged Three", version: 8))
        XCTAssertTrue(independent.conflicts.isEmpty)
        XCTAssertEqual(DocumentBody(bytes: independent.bytes, contentType: independent.contentType).markdown, "Inserted\n\nOne\n\nTwo\n\nChanged Three")
    }
    func testRichMarksAndUnknownMetadataArePreserved() throws {
        var b = rich("One\n\nTwo")
        let original = try JSONValue.parse(b.bytes).setting("opaque", .object([("retain", .bool(true))]))
        b.bytes = original.serialized(); b.sha256 = SHA256Hex.of(b.bytes)
        var l = b, r = b
        let lb = DocumentBody(bytes: b.bytes, contentType: b.contentType)
        var blocks = lb.editorState!["content"]!.arrayValue!
        var inline = blocks[0]["content"]!.arrayValue!
        inline[0] = inline[0].setting("marks", .array([.object([("type", .string("bold"))])]))
        blocks[0] = blocks[0].setting("content", .array(inline))
        let marked = lb.editorState!.setting("content", .array(blocks))
        l.bytes = try lb.encoded(editorState: marked).bytes
        let remote = try DocumentEditor.setText(lb.editorState!, path: [1], text: "Remote Two")
        r.bytes = try lb.encoded(editorState: remote).bytes
        let result = try DocumentMerge.merge(base: b, local: l, latest: r)
        XCTAssertTrue(result.conflicts.isEmpty)
        let root = try JSONValue.parse(result.bytes)
        XCTAssertEqual(root["opaque"], original["opaque"])
        XCTAssertTrue(DocumentBody(bytes: result.bytes, contentType: result.contentType).markdown.contains("**One**"))
        XCTAssertTrue(DocumentBody(bytes: result.bytes, contentType: result.contentType).markdown.contains("Remote Two"))
    }
    func testIndependentBoundaryInsertionAndReplacementAreBothRetained() throws {
        let result = try DocumentMerge.merge(base: raw("Old\nLast"), local: raw("Prefix\nOld\nLast"), latest: raw("Changed\nLast", version: 8))
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(String(decoding: result.bytes, as: UTF8.self), "Prefix\nChanged\nLast")
    }
    func testInvalidBaseAndChangedRepresentationRefuseAutomaticMerge() throws {
        var invalid = raw("old"); invalid.sha256 = "bad"
        XCTAssertThrowsError(try DocumentMerge.merge(base: invalid, local: raw("local"), latest: raw("remote")))
        XCTAssertThrowsError(try DocumentMerge.merge(base: raw("old"), local: raw("local"), latest: rich("remote")))
    }
    func testReviewRefreshCanReconcilePreviewAgainWithoutChangingOriginal() throws {
        let original = raw("A\nB\nC")
        let local = raw("Local A\nB\nC")
        let v8 = raw("A\nRemote B\nC", version: 8)
        let merged = try DocumentMerge.merge(base: original, local: local, latest: v8)
        var preview = v8; preview.bytes = merged.bytes
        let v9 = raw("A\nRemote B\nNew C", version: 9)
        let again = try DocumentMerge.merge(base: v8, local: preview, latest: v9)
        XCTAssertTrue(again.conflicts.isEmpty)
        XCTAssertEqual(String(decoding: again.bytes, as: UTF8.self), "Local A\nRemote B\nNew C")
        XCTAssertEqual(String(decoding: local.bytes, as: UTF8.self), "Local A\nB\nC")
    }
    func testRestoredPreservedDraftFindsItsOriginalCommonBaseAfterAcceptance() {
        let v6 = raw("Base six"), v8 = raw("Latest eight", version: 8)
        var local = v6; local.bytes = Data("Local work on six".utf8)
        var journal = DocumentReviewJournal()
        journal.retainBase(v6); journal.preserve(local); journal.retainBase(v8)
        XCTAssertEqual(journal.commonBase(for: local)?.bytes, v6.bytes)
        XCTAssertEqual(journal.commonBase(for: v8)?.bytes, v8.bytes)
        XCTAssertEqual(journal.retained.first?.bytes, local.bytes)
    }
    func testDiffIncludesWhitespaceDeletionAndVersionText() {
        let lines = DocumentReviewDiff.lines(local: "Title\nold\nkeep ", latest: "Title\nnew\nkeep")
        XCTAssertTrue(lines.contains { $0.prefix == "−" && $0.text == "old" })
        XCTAssertTrue(lines.contains { $0.prefix == "+" && $0.text == "new" })
        XCTAssertTrue(lines.contains { $0.prefix == "−" && $0.text == "keep " })
    }
}

extension WorkTests {
    func testReviewJournalRetainsBaseOriginalAndInvalidEditedPreviewAcrossReopen() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        let edit = try await draft(h, doc: id) { try DocumentEditor.setText($0, path: [0], text: "Local") }
        let read = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: id)
        let cached = try XCTUnwrap(read)
        var journal = DocumentReviewJournal()
        journal.base = PreservedDocumentSnapshot(title: "Plan", bytes: cached.bytes, contentType: cached.contentType,
            rowVersion: cached.docRowVersion, sha256: cached.sha256, storageObjectId: cached.storageObjectId)
        var original = journal.base!; original.bytes = edit.body
        journal.preserve(original); journal.preserve(original)
        journal.mergeBase = journal.base; journal.mergeLocal = original; journal.mergeLatest = journal.base
        journal.previewText = "{ unfinished rich edit"; journal.previewTitle = "Unfinished title"
        journal.choices = ["/body/content": "local"]
        try await h.store.writer.saveDocumentReview(journal, key: edit.key)
        try await h.store.writer.saveDocDraft(edit)
        h.work.externalDocSave(id, body: DocumentBody.newDocument(text: "Remote advanced").bytes, contentType: edit.contentType)
        _ = try await h.saver.latest(h.connection, h.workspace, docId: id)
        let reopenedStore = try LocalStore(directory: h.chat.directory.appendingPathComponent("Store"))
        let reopened = try await reopenedStore.reader.documentReview(key: edit.key)
        XCTAssertEqual(reopened, journal)
        XCTAssertEqual(reopened.retained.count, 1)
        XCTAssertEqual(reopened.base?.bytes, cached.bytes)
        let current = try await h.store.reader.docDraft(key: edit.key)
        XCTAssertEqual(current, edit)
        let foreign = try await h.store.reader.documentReview(key: "different-connection:" + edit.key)
        XCTAssertNil(foreign.base)
    }
    func testPreflightDetectsNewRemoteBeforeUploadAndRetryDoesNotPublishItAgain() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        let edit = try await draft(h, doc: id) { try DocumentEditor.setText($0, path: [0], text: "Local") }
        try await h.store.writer.saveDocDraft(edit)
        h.work.externalDocSave(id, body: DocumentBody.newDocument(text: "Remote").bytes, contentType: edit.contentType)
        let before = h.transport.recorded.count
        guard case .recovery(id: nil, _) = await h.saver.save(edit, connection: h.connection, workspace: h.workspace) else { return XCTFail("must request review") }
        XCTAssertFalse(h.transport.recorded.dropFirst(before).contains { $0.httpMethod == "PATCH" || $0.url?.path.hasSuffix("/storage/prepare") == true })
        // Simulate a canonical save whose response was lost. Exact content/title may be acknowledged without another PATCH.
        h.work.externalDocSave(id, body: edit.body, contentType: edit.contentType)
        guard case .saved = await h.saver.save(edit, connection: h.connection, workspace: h.workspace) else { return XCTFail("must acknowledge already saved bytes") }
        XCTAssertFalse(h.transport.recorded.dropFirst(before).contains { $0.httpMethod == "PATCH" })
        let retained = try await h.store.reader.docDraft(key: edit.key)
        XCTAssertNil(retained)
    }
}
