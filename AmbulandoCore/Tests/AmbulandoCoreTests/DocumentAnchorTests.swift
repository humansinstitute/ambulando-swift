import Foundation
import XCTest
@testable import AmbulandoCore

final class DocumentAnchorTests: XCTestCase {
    func testCrossParagraphQuoteUsesWebSeparatorsAndUTF16Coordinates() throws {
        let state = try JSONValue.parse(#"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"A😀B"}]},{"type":"paragraph","content":[{"type":"text","text":"Next"}]}]}"#)
        let anchor = DocumentAnchor(quote: "😀B\nNex", from: 2, to: 10)
        XCTAssertEqual(DocumentAnchors.selectedText(anchor, in: state), anchor.quote)
        XCTAssertNotEqual(DocumentAnchors.selectedText(DocumentAnchor(quote: "wrong", from: 1, to: 4), in: state), "wrong")
    }

    func testUTF16PositionsNestedBlocksAndVersionRelocation() throws {
        let state = try JSONValue.parse(#"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"A😀B"}]},{"type":"blockquote","content":[{"type":"paragraph","content":[{"type":"text","text":"quoted words"}]}]}]}"#)
        let spans = DocumentAnchors.spans(state)
        XCTAssertEqual(spans.map(\.start), [1, 8])
        XCTAssertEqual(spans[1].path, [1, 0])
        let anchor = try XCTUnwrap(spans[0].anchor(NSRange(location: 1, length: 2), version: 4))
        XCTAssertEqual(anchor.quote, "😀"); XCTAssertEqual(anchor.from, 2); XCTAssertEqual(anchor.to, 4)
        let bytes = try JSONSerialization.data(withJSONObject: anchor.metadata)
        let decoded = try XCTUnwrap(DocumentAnchor(metadata: JSONSerialization.jsonObject(with: bytes) as! [String: Any]))
        XCTAssertEqual(decoded, anchor)
        let changed = try DocumentEditor.setText(state, path: [0], text: "Before A😀B")
        let resolved = try XCTUnwrap(DocumentAnchors.resolve(decoded, in: DocumentAnchors.spans(changed)))
        XCTAssertEqual(resolved.range, NSRange(location: 8, length: 2), "version changes require exact quote verification/unique relocation")
        let removed = try DocumentEditor.setText(state, path: [0], text: "deleted")
        XCTAssertNil(DocumentAnchors.resolve(decoded, in: DocumentAnchors.spans(removed)))
    }
    func testAmbiguousQuoteIsOrphanedAndUnknownNodesRemainUnchanged() throws {
        let state = try JSONValue.parse(#"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"same same"}]},{"type":"futureWidget","attrs":{"keep":"yes"}}]}"#)
        XCTAssertNil(DocumentAnchors.resolve(DocumentAnchor(quote: "same", from: 100, to: 104), in: DocumentAnchors.spans(state)))
        _ = DocumentAnchors.spans(state)
        XCTAssertEqual(state["content"]?.arrayValue?.last?["attrs"]?["keep"]?.stringValue, "yes")
    }
    func testInsertedStorageImageBecomesRealNodeWithoutLosingMarksOrUnknownContent() throws {
        let state = try JSONValue.parse(#"{"type":"doc","content":[{"type":"paragraph","attrs":{"custom":true},"content":[{"type":"text","text":"Before After","marks":[{"type":"bold"}]}]},{"type":"futureWidget","attrs":{"keep":"yes"}}]}"#)
        let id = "3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11"
        let edited = try DocumentEditor.setText(state, path: [0], text: "Before ![pasted](storage://\(id))After")
        let paragraph = try XCTUnwrap(edited["content"]?.arrayValue?.first)
        let content = try XCTUnwrap(paragraph["content"]?.arrayValue)
        XCTAssertTrue(content.contains { $0["type"]?.stringValue == "fdStorageImage" && $0["attrs"]?["objectId"]?.stringValue == id })
        XCTAssertEqual(content.first?["marks"], state["content"]?.arrayValue?.first?["content"]?.arrayValue?.first?["marks"])
        XCTAssertEqual(paragraph["attrs"], state["content"]?.arrayValue?.first?["attrs"])
        XCTAssertEqual(edited["content"]?.arrayValue?.last, state["content"]?.arrayValue?.last)
    }
    func testAnchorAndReplySurviveQueuedWriteTransportAndReload() async throws {
        let h = try await WorkHarness.make()
        let body = DocumentBody.newDocument(text: "Select this sentence")
        let doc = h.work.seedDoc(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Anchors", body: body.bytes, contentType: body.contentType)
        let anchor = DocumentAnchor(quote: "this", from: 8, to: 12, version: 1)
        try await h.writes.submit(WriteIntent(kind: .docComment, targetId: doc, payload: ["body": "Anchored comment", "metadata": anchor.metadata]), connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        let stored = try await h.store.reader.comments(workspaceId: h.workspace.id, parent: .doc, parentId: doc)
        let root = try XCTUnwrap(stored.first)
        XCTAssertEqual(root.documentAnchor, anchor)
        let request = try XCTUnwrap(h.transport.recorded.first { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/comments") == true })
        let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        XCTAssertEqual((payload["metadata"] as? [String: Any])?["anchor_start_offset"] as? Int, 8)
        try await h.writes.submit(WriteIntent(kind: .docComment, targetId: doc, payload: ["body": "Reply", "parent_comment_id": root.id, "metadata": anchor.metadata]), connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        let replies = try await h.store.reader.comments(workspaceId: h.workspace.id, parent: .doc, parentId: doc)
        XCTAssertTrue(replies.contains { $0.parentCommentId == root.id && $0.documentAnchor == anchor })
    }

    func testMarkdownSelectionUsesLineQuoteRatherThanFakePMOffsets() throws {
        let text = "# Heading\n\nA **formatted** paragraph."
        let spans = DocumentAnchors.markdownSpans(text, blocks: DocumentRender.markdownBlocks(text))
        let paragraph = try XCTUnwrap(spans.last)
        XCTAssertEqual(paragraph.line, 3)
        let anchor = try XCTUnwrap(paragraph.anchor(NSRange(location: 2, length: 9), version: 2))
        XCTAssertEqual(anchor.quote, "formatted")
        XCTAssertNil(anchor.metadata["anchor_start_offset"])
        XCTAssertEqual(anchor.metadata["anchor_line_number"] as? Int, 3)
        let data = try JSONSerialization.data(withJSONObject: anchor.metadata)
        let decoded = try XCTUnwrap(DocumentAnchor(metadata: JSONSerialization.jsonObject(with: data) as! [String: Any]))
        XCTAssertEqual(DocumentAnchors.resolve(decoded, in: spans)?.range, NSRange(location: 2, length: 9))
    }

    func testMarkdownTableHeaderAndBodyKeepFormattedCellSourceLines() throws {
        let source = "| **Header** | Other |\n| --- | --- |\n| A [linked](https://example.com) cell | B |\n\nAfter table."
        let spans = DocumentAnchors.markdownSpans(source, blocks: DocumentRender.markdownBlocks(source))
        let header = try XCTUnwrap(spans.first { $0.path == [0, 0, 0, 0] })
        let cell = try XCTUnwrap(spans.first { $0.path == [0, 1, 0, 0] })
        XCTAssertEqual(header.text, "Header"); XCTAssertEqual(header.line, 1)
        XCTAssertEqual(cell.text, "A linked cell"); XCTAssertEqual(cell.line, 3)
        let anchor = try XCTUnwrap(cell.anchor(NSRange(location: 2, length: 6), version: 1))
        XCTAssertEqual(anchor.quote, "linked")
        XCTAssertEqual(anchor.metadata["anchor_line_number"] as? Int, 3)
        XCTAssertEqual(DocumentAnchors.resolve(anchor, in: spans)?.span.path, cell.path)
        XCTAssertEqual(spans.last?.line, 5)
    }

    func testResolvedThreadRoundTripsWithoutLosingAnchorOrRepliesAndReopens() async throws {
        let h = try await WorkHarness.make()
        let body = DocumentBody.newDocument(text: "Selected sentence")
        let doc = h.work.seedDoc(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Resolution", body: body.bytes, contentType: body.contentType)
        let anchor = DocumentAnchor(quote: "Selected", from: 1, to: 9, version: 1)
        try await h.writes.submit(WriteIntent(kind: .docComment, targetId: doc, payload: ["body": "Root", "metadata": anchor.metadata]), connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        let initial = try await h.store.reader.comments(workspaceId: h.workspace.id, parent: .doc, parentId: doc)
        let root = try XCTUnwrap(initial.first)
        try await h.writes.submit(WriteIntent(kind: .docComment, targetId: doc, payload: ["body": "Retained reply", "parent_comment_id": root.id]), connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        var version = root.rowVersion
        for status in ["resolved", "open"] {
            try await h.writes.submit(WriteIntent(kind: .docCommentStatus, targetId: root.id, payload: ["doc_id": doc, "status": status, "row_version": version]), connection: h.connection, workspace: h.workspace)
            await h.drainWrites()
            let records = try await h.store.reader.comments(workspaceId: h.workspace.id, parent: .doc, parentId: doc)
            let updated = try XCTUnwrap(records.first { $0.id == root.id })
            XCTAssertEqual(updated.status, status)
            XCTAssertEqual(updated.documentAnchor, anchor)
            XCTAssertTrue(records.contains { $0.parentCommentId == root.id && $0.body == "Retained reply" })
            version = updated.rowVersion
        }
    }

}
