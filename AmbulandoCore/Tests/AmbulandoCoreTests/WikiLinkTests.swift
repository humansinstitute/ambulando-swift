import XCTest
@testable import AmbulandoCore

/// Wiki links in documents: rendering, resolution by stable id across channels and scopes, title matching, the picker's
/// search, backlinks, and binding a created page into its source without touching code or other content.
final class WikiLinkTests: XCTestCase {
    private func doc(_ id: String, _ title: String, channel: String = "c1", scope: String? = "s1", archived: Bool = false) -> DocRecord {
        DocRecord(workspaceId: "w", id: id, scopeId: scope, channelId: channel, storageObjectId: nil, title: title, summary: nil,
                  archived: archived, rowVersion: 1, createdAt: "2026-10-28T00:00:00Z", updatedAt: "2026-10-28T00:00:00Z")
    }

    private func text(_ value: String, marks: [String] = []) -> JSONValue {
        var pairs: [(String, JSONValue)] = [("type", .string("text")), ("text", .string(value))]
        if !marks.isEmpty { pairs.append(("marks", .array(marks.map { .object([("type", .string($0))]) }))) }
        return .object(pairs)
    }
    private func paragraph(_ content: [JSONValue]) -> JSONValue { .object([("type", .string("paragraph")), ("content", .array(content))]) }
    private func wikiNode(_ id: String?, _ title: String) -> JSONValue {
        var attrs: [(String, JSONValue)] = []
        if let id { attrs.append(("documentId", .string(id))) }
        attrs.append(("title", .string(title)))
        return .object([("type", .string("fdWikiLink")), ("attrs", .object(attrs))])
    }
    private func richBody(_ blocks: [JSONValue]) -> DocumentBody {
        let state = JSONValue.object([("type", .string("doc")), ("content", .array(blocks))])
        let model = JSONValue.object(ProseMirrorMarkdown.contentModelFields(state))
        let root = JSONValue.object([("format", .string(DocumentBody.envelopeFormat)), ("content_model", model)])
        return DocumentBody(bytes: root.serialized(), contentType: DocumentBody.envelopeContentType)
    }
    private func wikiRuns(_ blocks: [RenderBlock]) -> [InlineRun] {
        blocks.flatMap { block -> [InlineRun] in
            if case .paragraph(let runs) = block { return runs.filter { $0.wiki != nil } }
            return []
        }
    }

    // MARK: Rendering

    func testRichNodeKeepsStableIdAndTitleInsteadOfALabelOnlyObject() {
        let body = richBody([paragraph([text("See "), wikiNode("D1", "Plan"), text(" now")])])
        let runs = wikiRuns(DocumentRender.blocks(body))
        XCTAssertEqual(runs.map(\.wiki), [WikiTarget(documentId: "D1", title: "Plan")])
        XCTAssertFalse(runs[0].object)
        XCTAssertNil(runs[0].link)
    }

    func testCanonicalMarkdownLinkAndLiteralTitleBecomeWikiReferences() {
        let body = DocumentBody(bytes: Data("Open [Plan](wiki:abc%2D1) and [[Dashboard]] today".utf8), contentType: "text/markdown")
        let runs = wikiRuns(DocumentRender.blocks(body))
        XCTAssertEqual(runs.map(\.wiki), [WikiTarget(documentId: "abc-1", title: "Plan"), WikiTarget(title: "Dashboard")])
    }

    func testLiteralTitleInRichTextBecomesAReferenceButCodeStaysLiteral() {
        let body = richBody([
            paragraph([text("Go to [[Dashboard]] then "), text("[[InCode]]", marks: ["code"])]),
            .object([("type", .string("codeBlock")), ("content", .array([text("[[Fenced]]")]))]),
        ])
        let blocks = DocumentRender.blocks(body)
        XCTAssertEqual(wikiRuns(blocks).map(\.wiki), [WikiTarget(title: "Dashboard")])
        guard case .paragraph(let runs) = blocks[0] else { return XCTFail("paragraph") }
        XCTAssertTrue(runs.contains { $0.code && $0.text == "[[InCode]]" && $0.wiki == nil })
        guard case .code(_, let code) = blocks[1] else { return XCTFail("code block") }
        XCTAssertEqual(code, "[[Fenced]]")
    }

    func testMarkdownCodeSpanAndFenceKeepLiteralBrackets() {
        let body = DocumentBody(bytes: Data("Use `[[Literal]]` here\n\n```\n[[Fence]]\n```\n".utf8), contentType: "text/markdown")
        XCTAssertTrue(wikiRuns(DocumentRender.blocks(body)).isEmpty)
    }

    func testChatMarkdownIsNotWikified() {
        let runs = DocumentRender.markdownBlocks("see [[Dashboard]]").flatMap { block -> [InlineRun] in
            if case .paragraph(let r) = block { return r }
            return []
        }
        XCTAssertTrue(runs.allSatisfy { $0.wiki == nil })
    }

    // MARK: Resolution

    func testBoundIdOpensFromAnyChannelAndScope() {
        let docs = [doc("d1", "Plan", channel: "c9", scope: "s9")]
        XCTAssertEqual(WikiLinks.resolve(WikiTarget(documentId: "d1", title: "Old title"), in: docs, sourceChannelId: "c1"), .available(docs[0]))
    }

    func testRenameAndMoveKeepTheSameRecord() {
        let before = doc("d1", "Plan", channel: "c1", scope: "s1")
        let after = doc("d1", "Roadmap", channel: "c7", scope: "s2")
        let link = WikiTarget(documentId: "d1", title: "Plan")
        guard case .available(let found) = WikiLinks.resolve(link, in: [before], sourceChannelId: "c1"),
              case .available(let moved) = WikiLinks.resolve(link, in: [after], sourceChannelId: "c1") else { return XCTFail("resolution") }
        XCTAssertEqual(found.id, moved.id)
        XCTAssertEqual(moved.title, "Roadmap")
        XCTAssertEqual(moved.channelId, "c7")
    }

    func testMissingOrArchivedBoundIdIsUnavailableAndNeverRebindsByTitle() {
        let docs = [doc("other", "Plan"), doc("gone", "Plan", archived: true)]
        XCTAssertEqual(WikiLinks.resolve(WikiTarget(documentId: "gone", title: "Plan"), in: docs, sourceChannelId: "c1"), .unavailable(documentId: "gone"))
        XCTAssertEqual(WikiLinks.resolve(WikiTarget(documentId: "never-synced", title: "Plan"), in: docs, sourceChannelId: "c1"), .unavailable(documentId: "never-synced"))
    }

    func testTitleOnlyMatchesTheSourceChannelAndIgnoresCase() {
        let docs = [doc("d1", "Dashboard", channel: "c1"), doc("d2", "Elsewhere", channel: "c2"), doc("d3", "dashboard", channel: "c2")]
        XCTAssertEqual(WikiLinks.resolve(WikiTarget(title: " DASHBOARD "), in: docs, sourceChannelId: "c1"), .available(docs[0]))
        XCTAssertEqual(WikiLinks.resolve(WikiTarget(title: "Elsewhere"), in: docs, sourceChannelId: "c1"), .unresolved(title: "Elsewhere"))
    }

    func testDuplicateTitlesAreAmbiguousAndNeverChosenSilently() {
        let docs = [doc("d1", "Notes"), doc("d2", "notes")]
        guard case .ambiguous(_, let matches) = WikiLinks.resolve(WikiTarget(title: "Notes"), in: docs, sourceChannelId: "c1") else { return XCTFail("ambiguous") }
        XCTAssertEqual(Set(matches.map(\.id)), ["d1", "d2"])
    }

    // MARK: Picker search

    func testSearchIsLocalByDefaultAndOffersOtherScopesOnlyWhenAsked() {
        let docs = [doc("a", "Plan", channel: "c1"), doc("b", "Plan", channel: "c2", scope: "s2"), doc("c", "Plan B", channel: "c1")]
        XCTAssertEqual(WikiLinks.search("plan", in: docs, sourceChannelId: "c1", everywhere: false).map(\.id), ["a", "c"])
        XCTAssertEqual(WikiLinks.search("plan", in: docs, sourceChannelId: "c1", everywhere: true).map(\.id), ["a", "c", "b"])
    }

    func testSearchReturnsEveryDuplicateTitleAndOmitsTheSourceAndArchivedPages() {
        let docs = [doc("a", "Plan"), doc("b", "Plan"), doc("src", "Plan"), doc("old", "Plan", archived: true)]
        XCTAssertEqual(Set(WikiLinks.search("Plan", in: docs, sourceChannelId: "c1", excluding: "src", everywhere: false).map(\.id)), ["a", "b"])
    }

    // MARK: Backlinks

    func testBacklinksFindSourcesInOtherChannelsByIdAndDiscloseUncachedBodies() {
        let target = doc("t", "Target", channel: "c1")
        let sameChannel = doc("s1", "Same", channel: "c1")
        let otherScope = doc("s2", "Other scope", channel: "c9", scope: "s9")
        let uncached = doc("s3", "Not saved here", channel: "c9", scope: "s9")
        let bodies = [
            "s1": richBody([paragraph([wikiNode("t", "Old title")])]),
            "s2": DocumentBody(bytes: Data("see [Target](wiki:t)".utf8), contentType: "text/markdown"),
        ]
        let result = WikiLinks.backlinks(to: target, docs: [target, sameChannel, otherScope, uncached], bodies: bodies)
        XCTAssertEqual(Set(result.sources.map(\.id)), ["s1", "s2"])
        XCTAssertEqual(result.examined, 2)
        XCTAssertEqual(result.total, 3)
        XCTAssertFalse(result.isComplete)
    }

    func testTitleOnlyBacklinkCountsOnlyWhenTheTitleIsUnique() {
        let target = doc("t", "Target")
        let source = doc("s", "Source")
        let bodies = ["s": DocumentBody(bytes: Data("go [[Target]]".utf8), contentType: "text/markdown")]
        XCTAssertEqual(WikiLinks.backlinks(to: target, docs: [target, source], bodies: bodies).sources.map(\.id), ["s"])
        let twin = doc("t2", "Target")
        XCTAssertTrue(WikiLinks.backlinks(to: target, docs: [target, source, twin], bodies: bodies).sources.isEmpty)
    }

    func testTitleOnlyBacklinksStayInTheTargetChannelAndIgnoreTwinsInOtherChannels() {
        let target = doc("t", "Target", channel: "c1")
        let sameChannelSource = doc("s1", "Source", channel: "c1")
        let otherChannelSource = doc("s2", "Other", channel: "c2")
        let twinElsewhere = doc("t2", "Target", channel: "c2")
        let bodies = ["s1": DocumentBody(bytes: Data("go [[Target]]".utf8), contentType: "text/markdown"),
                      "s2": DocumentBody(bytes: Data("go [[Target]]".utf8), contentType: "text/markdown")]
        // A twin title in another channel does not make the target ambiguous, and a title-only reference in another channel never points at it.
        let result = WikiLinks.backlinks(to: target, docs: [target, sameChannelSource, otherChannelSource, twinElsewhere], bodies: bodies)
        XCTAssertEqual(result.sources.map(\.id), ["s1"])
        // A twin in the SAME channel makes the title ambiguous: no title-only backlink is claimed.
        let twinHere = doc("t3", "target", channel: "c1")
        XCTAssertTrue(WikiLinks.backlinks(to: target, docs: [target, sameChannelSource, twinHere], bodies: bodies).sources.isEmpty)
        // A bound id still counts from any channel.
        let bound = ["s2": DocumentBody(bytes: Data("go [Target](wiki:t)".utf8), contentType: "text/markdown")]
        XCTAssertEqual(WikiLinks.backlinks(to: target, docs: [target, otherChannelSource, twinElsewhere], bodies: bound).sources.map(\.id), ["s2"])
    }

    func testBacklinksIgnoreCodeLiterals() {
        let target = doc("t", "Target"), source = doc("s", "Source")
        let bodies = ["s": DocumentBody(bytes: Data("`[[Target]]`".utf8), contentType: "text/markdown")]
        XCTAssertTrue(WikiLinks.backlinks(to: target, docs: [target, source], bodies: bodies).sources.isEmpty)
    }

    // MARK: Binding a created page

    func testBindingSetsTheIdOnUnresolvedNodesAndLiteralTextOnly() throws {
        let state = JSONValue.object([("type", .string("doc")), ("content", .array([
            paragraph([text("a "), wikiNode(nil, "Dashboard"), text(" b [[dashboard]] c "), text("[[Dashboard]]", marks: ["code"]), wikiNode("keep", "Dashboard"), wikiNode(nil, "Other")]),
            .object([("type", .string("codeBlock")), ("content", .array([text("[[Dashboard]]")]))]),
        ]))])
        let bound = try XCTUnwrap(WikiLinks.binding("Dashboard", to: "new", inEditorState: state))
        let content = try XCTUnwrap(bound["content"]?.arrayValue)
        let nodes = try XCTUnwrap(content[0]["content"]?.arrayValue)
        let wikis = nodes.filter { $0["type"]?.stringValue == "fdWikiLink" }.map { ($0["attrs"]?["documentId"]?.stringValue, $0["attrs"]?["title"]?.stringValue) }
        XCTAssertEqual(wikis.map { $0.0 ?? "-" }, ["new", "new", "keep", "-"])
        XCTAssertEqual(wikis.map { $0.1 ?? "" }, ["Dashboard", "dashboard", "Dashboard", "Other"])
        XCTAssertTrue(nodes.contains { $0["text"]?.stringValue == "[[Dashboard]]" && $0["marks"] != nil })
        XCTAssertEqual(content[1], state["content"]?.arrayValue?[1])
    }

    func testBindingReturnsNilWhenNothingMatchesSoTheBodyIsNotRewritten() {
        let state = JSONValue.object([("type", .string("doc")), ("content", .array([paragraph([wikiNode("x", "Dashboard"), text("plain")])]))])
        XCTAssertNil(WikiLinks.binding("Dashboard", to: "new", inEditorState: state))
        XCTAssertNil(WikiLinks.binding("Dashboard", to: "new", inMarkdown: "nothing [Dashboard](wiki:x) `[[Dashboard]]`\n```\n[[Dashboard]]\n```"))
    }

    func testMarkdownBindingWritesTheCanonicalLinkAndLeavesCodeAlone() throws {
        let source = "Go [[Dashboard Two]] and [[Dashboard]] or `[[Dashboard]]`\n```\n[[Dashboard]]\n```"
        let bound = try XCTUnwrap(WikiLinks.binding("Dashboard", to: "id/1", inMarkdown: source))
        XCTAssertEqual(bound, "Go [[Dashboard Two]] and [Dashboard](wiki:id%2F1) or `[[Dashboard]]`\n```\n[[Dashboard]]\n```")
    }

    func testMarkdownBindingKeepsEveryKindOfCodeLiteral() throws {
        let cases: [(String, String)] = [
            ("``[[Dashboard]]`` and [[Dashboard]]", "``[[Dashboard]]`` and [Dashboard](wiki:N)"),
            ("`a` [[Dashboard]] `b`", "`a` [Dashboard](wiki:N) `b`"),
            ("``` js\n[[Dashboard]]\n```\n[[Dashboard]]", "``` js\n[[Dashboard]]\n```\n[Dashboard](wiki:N)"),
            ("````\n```\n[[Dashboard]]\n```\n````\n[[Dashboard]]", "````\n```\n[[Dashboard]]\n```\n````\n[Dashboard](wiki:N)"),
            ("~~~\n[[Dashboard]]\n```\n[[Dashboard]]\n~~~\n[[Dashboard]]", "~~~\n[[Dashboard]]\n```\n[[Dashboard]]\n~~~\n[Dashboard](wiki:N)"),
            ("   ```\n[[Dashboard]]\n   ```\n[[Dashboard]]", "   ```\n[[Dashboard]]\n   ```\n[Dashboard](wiki:N)"),
            ("    [[Dashboard]]\n\n[[Dashboard]]", "    [[Dashboard]]\n\n[Dashboard](wiki:N)"),
            ("\\[[Dashboard]] but [[Dashboard]]", "\\[[Dashboard]] but [Dashboard](wiki:N)"),
            ("```\n[[Dashboard]] never closed", "```\n[[Dashboard]] never closed"),
            ("`[[Dashboard]]", "`[Dashboard](wiki:N)"),
        ]
        for (source, expected) in cases {
            let bound = WikiLinks.binding("Dashboard", to: "N", inMarkdown: source)
            if source == expected { XCTAssertNil(bound, source) } else { XCTAssertEqual(bound, expected, source) }
        }
    }

    func testBindingOnlyTheOpenedOccurrenceLeavesTheOthersAlone() throws {
        XCTAssertEqual(WikiLinks.binding("A", to: "N", inMarkdown: "[[A]] [[B]] [[A]] [[A]]", occurrence: 1), "[[A]] [[B]] [A](wiki:N) [[A]]")
        let state = JSONValue.object([("type", .string("doc")), ("content", .array([paragraph([wikiNode(nil, "A"), text(" and [[A]]")])]))])
        let bound = try XCTUnwrap(WikiLinks.binding("A", to: "N", inEditorState: state, occurrence: 1))
        let nodes = try XCTUnwrap(bound["content"]?.arrayValue?[0]["content"]?.arrayValue)
        XCTAssertNil(nodes[0]["attrs"]?["documentId"])
        XCTAssertEqual(nodes[2]["attrs"]?["documentId"]?.stringValue, "N")
    }

    func testBoundLinksRoundTripThroughTheOldFormats() throws {
        let markdown = "[Plan](wiki:d1) and [[Loose]]"
        let raw = DocumentBody(bytes: Data(markdown.utf8), contentType: "text/markdown")
        XCTAssertEqual(try raw.encoded(markdown: markdown).bytes, Data(markdown.utf8))
        let rich = richBody([paragraph([wikiNode("d1", "Plan"), text(" and "), wikiNode(nil, "Loose")])])
        XCTAssertEqual(rich.markdown, markdown)
        let state = try XCTUnwrap(rich.editorState)
        let again = try JSONValue.parse(rich.encoded(editorState: state).bytes)
        XCTAssertEqual(again["content_model"]?["editor_state"], state)
    }
}
