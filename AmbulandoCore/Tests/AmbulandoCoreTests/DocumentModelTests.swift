import XCTest
@testable import AmbulandoCore

/// Document bodies: lossless JSON, the Markdown serializer port (checked against sol's own output), the body
/// representations, and structural edits that must keep marks, ids and unknown content.
final class DocumentModelTests: XCTestCase {
    static let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/prosemirror-golden.json")

    func testJSONValueRoundTripKeepsOrderNumbersAndEscapes() throws {
        let text = #"{"z":1,"a":[1.50,-0,2e10,true,null],"s":"line\nquote\" é 🎉 \/","nested":{"b":{},"a":[]}}"#
        let value = try JSONValue.parse(text)
        XCTAssertEqual(value.objectValue?.map(\.0), ["z", "a", "s", "nested"])
        XCTAssertEqual(value["a"]?.arrayValue?.first, .number("1.50"))
        XCTAssertEqual(value["s"]?.stringValue, "line\nquote\" é 🎉 /")
        let reparsed = try JSONValue.parse(value.serialized())
        XCTAssertEqual(reparsed, value)
        XCTAssertTrue(value.serializedString().hasPrefix(#"{"z":1,"a":[1.50,-0,2e10,true,null]"#))
        XCTAssertThrowsError(try JSONValue.parse(#"{"a":1,}"#))
        XCTAssertThrowsError(try JSONValue.parse(#""\udc00""#))
        XCTAssertThrowsError(try JSONValue.parse("[1] x"))
    }

    /// Every case's Markdown and content blocks equal what sol's `prosemirrorToFlightDeckContentModel` produced.
    func testSerializerMatchesWebGolden() throws {
        let golden = try JSONValue.parse(Data(contentsOf: Self.goldenURL))
        guard let cases = golden.objectValue else { return XCTFail("golden file unreadable") }
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for (name, value) in cases {
            let state = try XCTUnwrap(value["state"])
            let fields = Dictionary(uniqueKeysWithValues: ProseMirrorMarkdown.contentModelFields(state))
            XCTAssertEqual(fields["content"]?.stringValue, value["content"]?.stringValue, "content for \(name)")
            let blocks = fields["content_blocks"]?.arrayValue ?? []
            let expected = value["blocks"]?.arrayValue ?? []
            XCTAssertEqual(blocks.count, expected.count, "block count for \(name)")
            for (got, want) in zip(blocks, expected) {
                XCTAssertEqual(got["text"], want["text"], "block text for \(name)")
                XCTAssertEqual(got["type"], want["type"], "block type for \(name)")
                if let id = want["id"]?.stringValue, !id.hasPrefix("pm_") { XCTAssertEqual(got["id"]?.stringValue, id, "block id for \(name)") }
                XCTAssertEqual(got["attrs"]?["pmNodeId"], got["id"])
            }
        }
    }

    // MARK: Body representations

    func envelope(_ content: [JSONValue], extra: [(String, JSONValue)] = []) -> Data {
        let state = JSONValue.object([("type", .string("doc")), ("content", .array(content))])
        var model = ProseMirrorMarkdown.contentModelFields(state)
        model.append(("references", .array([.string("keep-me")])))
        let root = JSONValue.object([("format", .string(DocumentBody.envelopeFormat)), ("content_model", .object(model))] + extra)
        return root.serialized()
    }

    func para(_ id: String?, _ content: [JSONValue]) -> JSONValue {
        var pairs: [(String, JSONValue)] = [("type", .string("paragraph"))]
        if let id { pairs.append(("attrs", .object([("fdBlockId", .string(id))]))) }
        pairs.append(("content", .array(content)))
        return .object(pairs)
    }

    func text(_ s: String, _ marks: [String] = []) -> JSONValue {
        var pairs: [(String, JSONValue)] = [("type", .string("text")), ("text", .string(s))]
        if !marks.isEmpty { pairs.append(("marks", .array(marks.map { .object([("type", .string($0))]) }))) }
        return .object(pairs)
    }

    func testEnvelopeEditPreservesUnknownFieldsMarksAndIds() throws {
        let custom = JSONValue.object([("type", .string("customWidget")), ("attrs", .object([("fdBlockId", .string("w1")), ("n", .number("1.50"))]))])
        let bytes = envelope([para("b1", [text("Hello "), text("bold", ["bold"]), text(" world")]), custom],
                             extra: [("future_field", .object([("x", .number("2.0"))]))])
        let body = DocumentBody(bytes: bytes, contentType: DocumentBody.envelopeContentType)
        XCTAssertEqual(body.representation, .envelope)
        XCTAssertEqual(body.editing, .proseMirror)
        let state = try XCTUnwrap(body.editorState)
        let blocks = DocumentEditor.blocks(state)
        XCTAssertEqual(blocks.map(\.text), ["Hello bold world"])
        XCTAssertTrue(blocks[0].rich)

        // Edit inside the plain tail: the bold run is untouched.
        let edited = try DocumentEditor.setText(state, path: blocks[0].path, text: "Hello bold wide world!")
        let saved = try body.encoded(editorState: edited)
        XCTAssertEqual(saved.contentType, DocumentBody.envelopeContentType)
        let reread = DocumentBody(bytes: saved.bytes, contentType: saved.contentType)
        let root = try XCTUnwrap(reread.root)
        XCTAssertEqual(root["future_field"]?["x"], .number("2.0"), "unknown envelope field kept")
        XCTAssertEqual(reread.contentModel?["references"], .array([.string("keep-me")]), "unknown model field kept")
        XCTAssertEqual(reread.markdown, "Hello **bold** wide world\\!")
        let nodes = try XCTUnwrap(reread.editorState?["content"]?.arrayValue)
        XCTAssertEqual(nodes[0]["attrs"]?["fdBlockId"], .string("b1"), "block id kept for comment anchors")
        XCTAssertEqual(nodes[1], custom, "unknown node kept byte-for-byte")
        XCTAssertEqual(nodes[0]["content"]?.arrayValue?[1], text("bold", ["bold"]))
        XCTAssertEqual(reread.contentModel?["content"]?.stringValue, ProseMirrorMarkdown.markdown(edited))
        XCTAssertEqual(reread.contentModel?["content_format"], .string(ProseMirrorMarkdown.contentFormat))
    }

    func testTypedTextInheritsMarksAndDoesNotExtendLinks() throws {
        let link = JSONValue.object([("type", .string("text")), ("text", .string("site")),
                                     ("marks", .array([.object([("type", .string("link")), ("attrs", .object([("href", .string("https://x"))]))])]))])
        let state = JSONValue.object([("type", .string("doc")), ("content", .array([para("b1", [text("go "), text("bold", ["bold"]), text(" to "), link])]))])
        let path = DocumentEditor.blocks(state)[0].path
        // Typing at the end of "bold" continues bold.
        var next = try DocumentEditor.setText(state, path: path, text: "go bolder to site")
        var inline = try XCTUnwrap(DocumentEditor.node(next, at: path)?["content"]?.arrayValue)
        XCTAssertEqual(inline[1], text("bolder", ["bold"]))
        // Typing after the link does not extend the link.
        next = try DocumentEditor.setText(state, path: path, text: "go bold to site now")
        inline = try XCTUnwrap(DocumentEditor.node(next, at: path)?["content"]?.arrayValue)
        XCTAssertEqual(inline.last, text(" now"))
        XCTAssertEqual(inline[3], link)
        // Replacing a selection inside the bold run keeps bold.
        next = try DocumentEditor.setText(state, path: path, text: "go BOLD to site")
        inline = try XCTUnwrap(DocumentEditor.node(next, at: path)?["content"]?.arrayValue)
        XCTAssertEqual(inline[1], text("BOLD", ["bold"]))
        // A typed newline becomes a hard break; deleting everything leaves an empty paragraph without content.
        next = try DocumentEditor.setText(state, path: path, text: "go bold to site\nmore")
        inline = try XCTUnwrap(DocumentEditor.node(next, at: path)?["content"]?.arrayValue)
        XCTAssertEqual(inline.suffix(2).first?["type"], .string("hardBreak"))
        next = try DocumentEditor.setText(state, path: path, text: "")
        XCTAssertNil(DocumentEditor.node(next, at: path)?["content"])
        XCTAssertEqual(DocumentEditor.node(next, at: path)?["attrs"]?["fdBlockId"], .string("b1"))
    }

    func testInlineObjectsSurviveUnlessDeleted() throws {
        let wiki = JSONValue.object([("type", .string("fdWikiLink")), ("attrs", .object([("documentId", .string("d1")), ("title", .string("Plan"))]))])
        let state = JSONValue.object([("type", .string("doc")), ("content", .array([para("b1", [text("See "), wiki, text(" now")])]))])
        let block = DocumentEditor.blocks(state)[0]
        XCTAssertEqual(block.text, "See \u{FFFC} now")
        var next = try DocumentEditor.setText(state, path: block.path, text: "See \u{FFFC} later")
        XCTAssertEqual(DocumentEditor.node(next, at: block.path)?["content"]?.arrayValue?[1], wiki)
        next = try DocumentEditor.setText(state, path: block.path, text: "See  later")
        XCTAssertFalse((DocumentEditor.node(next, at: block.path)?["content"]?.arrayValue ?? []).contains(wiki))
    }

    func testNestedBlocksTasksAndStructureEdits() throws {
        let item: (Bool, String) -> JSONValue = { checked, label in
            .object([("type", .string("taskItem")), ("attrs", .object([("checked", .bool(checked))])), ("content", .array([self.para(nil, [self.text(label)])]))])
        }
        let list = JSONValue.object([("type", .string("taskList")), ("attrs", .object([("fdBlockId", .string("l1"))])),
                                     ("content", .array([item(false, "todo"), item(true, "done")]))])
        let state = JSONValue.object([("type", .string("doc")), ("content", .array([list]))])
        let blocks = DocumentEditor.blocks(state)
        XCTAssertEqual(blocks.map(\.text), ["todo", "done"])
        XCTAssertEqual(blocks.map(\.taskChecked), [false, true])
        XCTAssertEqual(blocks[0].path, [0, 0, 0])
        let toggled = try DocumentEditor.toggleTask(state, containing: blocks[0].path)
        XCTAssertEqual(ProseMirrorMarkdown.markdown(toggled), "- [x] todo\n- [x] done")
        // Inserting after a nested paragraph stays inside the item and gets no top-level id.
        let inserted = try DocumentEditor.insertParagraph(state, after: blocks[0].path, text: "note")
        let itemContent = try XCTUnwrap(DocumentEditor.node(inserted, at: [0, 0])?["content"]?.arrayValue)
        XCTAssertEqual(itemContent.count, 2)
        XCTAssertNil(itemContent[1]["attrs"])
        // Removing the only paragraph of an item removes the empty item; removing everything leaves one paragraph.
        let removed = try DocumentEditor.removeBlock(state, path: blocks[0].path)
        XCTAssertEqual(DocumentEditor.blocks(removed).map(\.text), ["done"])
        let empty = try DocumentEditor.removeBlock(removed, path: DocumentEditor.blocks(removed)[0].path)
        XCTAssertEqual(empty["content"]?.arrayValue?.count, 1)
        XCTAssertEqual(empty["content"]?.arrayValue?.first?["type"], .string("paragraph"))
        XCTAssertNotNil(empty["content"]?.arrayValue?.first?["attrs"]?["fdBlockId"]?.stringValue)
        XCTAssertThrowsError(try DocumentEditor.setText(state, path: [5], text: "x"))
    }

    func testRawMarkdownStaysMarkdown() throws {
        let body = DocumentBody(bytes: Data("# Notes\n\nPlain *md*".utf8), contentType: "text/markdown; charset=utf-8")
        XCTAssertEqual(body.representation, .rawMarkdown)
        XCTAssertEqual(body.editing, .markdown)
        let saved = try body.encoded(markdown: "# Notes\n\nEdited")
        XCTAssertEqual(String(decoding: saved.bytes, as: UTF8.self), "# Notes\n\nEdited")
        XCTAssertEqual(saved.contentType, "text/markdown; charset=utf-8")
        XCTAssertThrowsError(try body.encoded(editorState: .object([])))
    }

    func testLegacyMarkdownModelKeepsShapeAndClearsStaleBlocks() throws {
        let legacy = #"{"content":"old","content_blocks":[{"id":"x","text":"old"}],"title_hint":"t"}"#
        let body = DocumentBody(bytes: Data(legacy.utf8), contentType: "application/json")
        XCTAssertEqual(body.representation, .legacyModel)
        XCTAssertEqual(body.editing, .markdownModel)
        let saved = try body.encoded(markdown: "new text")
        let root = try JSONValue.parse(saved.bytes)
        XCTAssertEqual(root["content"], .string("new text"))
        XCTAssertEqual(root["content_blocks"], .array([]))
        XCTAssertEqual(root["title_hint"], .string("t"))
        XCTAssertNil(root["format"], "a legacy body is not silently converted")
    }

    func testUnknownFormatIsReadOnly() {
        let pdf = DocumentBody(bytes: Data([0x25, 0x50, 0x44, 0x46]), contentType: "application/pdf")
        XCTAssertFalse(pdf.isEditable)
        XCTAssertThrowsError(try pdf.encoded(markdown: "x"))
        let otherJSON = DocumentBody(bytes: Data(#"{"format":"document_content_v9","content_model":{"foo":1}}"#.utf8), contentType: "application/json")
        XCTAssertFalse(otherJSON.isEditable)
    }

    func testNewDocumentIsWebEnvelope() throws {
        let created = DocumentBody.newDocument(text: "First para\n\nSecond")
        let body = DocumentBody(bytes: created.bytes, contentType: created.contentType)
        XCTAssertEqual(body.representation, .envelope)
        XCTAssertEqual(body.markdown, "First para\n\nSecond")
        XCTAssertEqual(body.contentModel?["editor_state_format"], .string("prosemirror_json_v1"))
    }
}
