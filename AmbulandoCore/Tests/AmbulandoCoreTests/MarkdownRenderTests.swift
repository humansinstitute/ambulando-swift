import XCTest
@testable import AmbulandoCore

/// Markdown → display blocks for chat messages and Markdown document bodies (web parity: GFM with line breaks).
final class MarkdownRenderTests: XCTestCase {
    private func text(_ runs: [InlineRun]) -> String { runs.map(\.text).joined() }

    func testHeadingsParagraphBreaksAndInlineStyles() {
        let blocks = MarkdownBlocks.parse("# Title #\n\nFirst line with **bold**, _italic_, ~~gone~~ and `code`\nsecond line\n\nSub\n---")
        XCTAssertEqual(blocks.count, 3)
        guard case .heading(1, let title) = blocks[0], case .paragraph(let runs) = blocks[1], case .heading(2, let sub) = blocks[2] else {
            return XCTFail("\(blocks)")
        }
        XCTAssertEqual(text(title), "Title")
        XCTAssertEqual(text(sub), "Sub")
        XCTAssertTrue(text(runs).contains("\nsecond line"), "single newline kept as a line break")
        XCTAssertTrue(runs.contains { $0.bold && $0.text == "bold" })
        XCTAssertTrue(runs.contains { $0.italic && $0.text == "italic" })
        XCTAssertTrue(runs.contains { $0.strike && $0.text == "gone" })
        XCTAssertTrue(runs.contains { $0.code && $0.text == "code" })
    }

    func testFencesKeepMarkdownLookingTextVerbatim() {
        let source = "```swift\nlet a = \"# not a heading\"\n- not a list\n| a | b |\n```\n~~~\n**raw**\n~~~~\nafter"
        let blocks = MarkdownBlocks.parse(source)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .code(language: "swift", text: "let a = \"# not a heading\"\n- not a list\n| a | b |"))
        XCTAssertEqual(blocks[1], .code(language: "", text: "**raw**"))
        guard case .paragraph(let runs) = blocks[2] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(text(runs), "after")
        // An unclosed fence runs to the end; indented code also works.
        XCTAssertEqual(MarkdownBlocks.parse("```\nopen"), [.code(language: "", text: "open")])
        XCTAssertEqual(MarkdownBlocks.parse("    indented\n      more"), [.code(language: "", text: "indented\n  more")])
    }

    func testNestedListsStartNumbersAndTasks() {
        let source = """
        3. three
        4. four
           - nested *one*
           - nested two
             1. deep
        5. five

        - [ ] todo
        - [x] done
        """
        let blocks = MarkdownBlocks.parse(source)
        XCTAssertEqual(blocks.count, 2)
        guard case .list(true, 3, let items) = blocks[0] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[1].blocks.count, 2)
        guard case .list(false, _, let nested) = items[1].blocks[1] else { return XCTFail("nested: \(items[1].blocks)") }
        XCTAssertEqual(nested.count, 2)
        guard case .list(true, 1, let deep) = nested[1].blocks.last else { return XCTFail("deep: \(nested[1].blocks)") }
        XCTAssertEqual(deep.count, 1)
        guard case .paragraph(let first) = nested[0].blocks[0] else { return XCTFail() }
        XCTAssertTrue(first.contains { $0.italic && $0.text == "one" })
        guard case .list(false, _, let tasks) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(tasks.map(\.checked), [false, true])
        guard case .paragraph(let todo) = tasks[0].blocks[0] else { return XCTFail() }
        XCTAssertEqual(text(todo), "todo")
    }

    func testListInterruptsParagraphAndLazyContinuation() {
        let blocks = MarkdownBlocks.parse("Steps:\n1. open\ncontinued\n2. close\n\nIn 2024. we shipped")
        XCTAssertEqual(blocks.count, 3, "\(blocks)")
        guard case .list(true, 1, let items) = blocks[1], case .paragraph(let p) = items[0].blocks[0] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(text(p), "open\ncontinued")
    }

    func testMultiLineAndNestedQuotes() {
        let blocks = MarkdownBlocks.parse("> quoted **one**\nlazy\n>\n> > inner\n> - item")
        guard case .quote(let inner) = blocks.first, blocks.count == 1 else { return XCTFail("\(blocks)") }
        XCTAssertEqual(inner.count, 3, "\(inner)")
        guard case .paragraph(let p) = inner[0], case .quote(let nested) = inner[1], case .list = inner[2] else { return XCTFail("\(inner)") }
        XCTAssertEqual(text(p), "quoted one\nlazy")
        XCTAssertEqual(nested.count, 1)
    }

    func testPipeTablesWithAlignmentEscapesAndCode() {
        let source = "| Name | Value |\n|:-----|------:|\n| a \\| b | `x|y` |\n| only |\n\nafter"
        let blocks = MarkdownBlocks.parse(source)
        XCTAssertEqual(blocks.count, 2)
        guard case .table(let rows) = blocks[0] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0.map(text) }, [["Name", "Value"], ["a | b", "x|y"], ["only", ""]])
        XCTAssertTrue(rows[1][1].first?.code ?? false)
        // A paragraph followed by a rule is a heading, not a table.
        guard case .heading(2, _) = MarkdownBlocks.parse("plain\n---").first else { return XCTFail() }
    }

    func testRulesAndImages() {
        let blocks = MarkdownBlocks.parse("---\n\n![Diagram](storage://3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11)\n\n![remote](https://example.invalid/a.png) and text")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .rule)
        XCTAssertEqual(blocks[1], .image(alt: "Diagram", source: "storage://3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11"))
        guard case .paragraph(let runs) = blocks[2] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(runs.first?.image, "https://example.invalid/a.png")
    }

    func testMentionsKeepIdentityInsideEmphasisListsAndTables() {
        let npub = "npub1hd37reqgfcnz3pvzj4grknd2nkzc94p9ercmunrxx22razr2rfxsw6dns5"
        let doc = "c8d1a3e0-1111-4222-8333-944455566677"
        let source = "Hi **@[Pete](mention:person:\(npub))**, see @[Plan](mention:document:\(doc))\n\n- ask @[Rick](mention:agent:\(npub))\n\n| who |\n| --- |\n| @[Pete](mention:person:\(npub)) |\n\n`@[Raw](mention:person:x)`"
        let blocks = MarkdownBlocks.parse(source)
        XCTAssertEqual(blocks.count, 4, "\(blocks)")
        guard case .paragraph(let runs) = blocks[0] else { return XCTFail() }
        let pete = runs.first { $0.mentionId == npub }
        XCTAssertEqual(pete?.text, "@Pete")
        XCTAssertEqual(pete?.mentionKind, "person")
        XCTAssertTrue(pete?.bold ?? false)
        XCTAssertTrue(pete?.mention ?? false)
        XCTAssertNil(pete?.link)
        let plan = runs.first { $0.mentionId == doc }
        XCTAssertEqual(plan?.text, "Plan", "record references show their label without @")
        XCTAssertEqual(plan?.mentionKind, "document")
        XCTAssertFalse(text(runs).contains("@@"))
        XCTAssertFalse(text(runs).contains("@Plan"))
        guard case .list(_, _, let items) = blocks[1], case .paragraph(let item) = items[0].blocks[0] else { return XCTFail() }
        XCTAssertEqual(item.last?.mentionKind, "agent")
        XCTAssertEqual(text(item), "ask @Rick")
        guard case .table(let rows) = blocks[2] else { return XCTFail() }
        XCTAssertEqual(rows[1][0].first?.mentionId, npub)
        guard case .paragraph(let code) = blocks[3] else { return XCTFail() }
        XCTAssertEqual(code.first?.code, true)
        XCTAssertNil(code.first?.mentionId, "tokens inside code spans stay literal")
    }

    func testAutolinksAndBreakTags() {
        let runs = MarkdownBlocks.inline("see https://example.invalid/path. then<br>next [docs](https://example.invalid/d) and [file](storage://abc)")
        XCTAssertTrue(runs.contains { $0.link == "https://example.invalid/path" && $0.text == "https://example.invalid/path" })
        XCTAssertTrue(text(runs).contains("then\nnext"))
        XCTAssertTrue(runs.contains { $0.link == "https://example.invalid/d" && $0.text == "docs" })
        XCTAssertTrue(runs.contains { $0.link == "storage://abc" && $0.object })
    }

    func testPlainTextDetection() {
        XCTAssertTrue(MarkdownBlocks.isPlainText("Sounds good, see you at 3pm.\nThanks"))
        for rich in ["**bold**", "# h", "- item", "1. one", "a `b`", "@[A](mention:person:x)", "https://x.invalid", "> q", "a | b", "    code"] {
            XCTAssertFalse(MarkdownBlocks.isPlainText(rich), rich)
        }
    }

    func testPathologicalInputStaysBounded() {
        let deep = String(repeating: ">", count: 400) + " deep"
        XCTAssertFalse(MarkdownBlocks.parse(deep).isEmpty)
        let nested = (0..<200).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n")
        XCTAssertFalse(MarkdownBlocks.parse(nested).isEmpty)
        XCTAssertEqual(MarkdownBlocks.parse(""), [])
        XCTAssertEqual(MarkdownBlocks.parse("\n\n  \n"), [])
    }

    /// A message body as Tower stores it (mention tokens written by the web composer, agent reply with list and code).
    func testTowerShapedMessageBody() throws {
        let raw = #"{"id":"6c0d2b1e-0000-4000-8000-000000000001","workspace_id":"2e5caefd-dd65-45d2-b747-ee874e8e5fc9","channel_id":"0617d526-88dc-4dc2-9876-08349ab60eca","body":"@[Rick](mention:agent:npub1llwrq3rtah3rg3r2dyfyht55ek7aa0ey7z47ujju407pzfp38shqa7zcvr) status?\n\n**Build 5** is ready:\n\n- Full-screen unlock\n- Channel catch-up\n\n```sh\nswift test\n```","sender_npub":"npub1jss47s4fvv6usl7tn6yp5zamv2u60923ncgfea0e6thkza5p7c3q0afmzy","created_at":"2026-10-24T08:00:00Z","updated_at":"2026-10-24T08:00:00Z","row_version":1,"record_state":"active"}"#
        let message = try MessageRecord(raw: Data(raw.utf8))
        XCTAssertFalse(MarkdownBlocks.isPlainText(message.body))
        let blocks = MarkdownBlocks.parse(message.body)
        XCTAssertEqual(blocks.count, 4, "\(blocks)")
        guard case .paragraph(let first) = blocks[0], case .list(false, _, let items) = blocks[2] else { return XCTFail() }
        XCTAssertEqual(first.first?.mentionKind, "agent")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(blocks[3], .code(language: "sh", text: "swift test"))
    }

    /// `document_content_v1` with a Markdown content model (no editor state) renders through the same parser.
    func testMarkdownModelDocumentBody() {
        let body = ##"{"format":"document_content_v1","content_model":{"content":"# Plan\n\n| Step | Owner |\n| --- | --- |\n| Build | @[Rick](mention:agent:npub1x) |\n\n![Board](storage://3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11)","content_blocks":[]}}"##
        let decoded = DocumentBody(bytes: Data(body.utf8), contentType: DocumentBody.envelopeContentType)
        XCTAssertEqual(decoded.editing, .markdownModel)
        let blocks = DocumentRender.blocks(decoded)
        XCTAssertEqual(blocks.count, 3, "\(blocks)")
        guard case .table(let rows) = blocks[1] else { return XCTFail() }
        XCTAssertEqual(rows[1][1].first?.mentionKind, "agent")
        XCTAssertEqual(blocks[2], .image(alt: "Board", source: "storage://3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11"))
    }

    /// ProseMirror bodies: stored images keep their object id; fdMention marks keep kind and id; nothing is rewritten.
    func testProseMirrorImagesAndMentions() throws {
        let body = #"{"format":"document_content_v1","content_model":{"content":"x","editor_state":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"fdStorageImage","attrs":{"objectId":"3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11","alt":"Plan","src":"storage://3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11"}}]},{"type":"paragraph","content":[{"type":"text","text":"Ask "},{"type":"text","text":"Pete","marks":[{"type":"fdMention","attrs":{"label":"Pete","mentionType":"person","mentionId":"npub1abc"}}]},{"type":"fdStorageImage","attrs":{"objectId":"0b1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d22","alt":"inline"}}]}]}}}"#
        let bytes = Data(body.utf8)
        let decoded = DocumentBody(bytes: bytes, contentType: DocumentBody.envelopeContentType)
        let blocks = DocumentRender.blocks(decoded)
        XCTAssertEqual(blocks.first, .image(alt: "Plan", source: "storage://3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11"))
        guard case .paragraph(let runs) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(runs[1].mentionId, "npub1abc")
        XCTAssertEqual(runs[1].mentionKind, "person")
        XCTAssertEqual(runs[2].image, "storage://0b1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d22")
        XCTAssertEqual(decoded.root?.serialized(), try JSONValue.parse(bytes).serialized(), "reading never rewrites the body")
    }

    /// Every Markdown string the web serializer produced for the golden ProseMirror cases parses into blocks.
    func testWebGoldenMarkdownParses() throws {
        let golden = try JSONValue.parse(Data(contentsOf: DocumentModelTests.goldenURL))
        for (name, value) in golden.objectValue ?? [] {
            let markdown = value["content"]?.stringValue ?? ""
            let blocks = MarkdownBlocks.parse(markdown)
            if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { XCTAssertFalse(blocks.isEmpty, name) }
        }
    }
}
