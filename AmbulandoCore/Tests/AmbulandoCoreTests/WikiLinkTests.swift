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


/// Moving a document (online only) and keeping every link, draft and cached row coherent.
final class WikiMoveTests: XCTestCase {
    private func seed(_ h: WorkHarness, title: String = "Plan") async throws -> String {
        let id = h.work.seedDoc(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: title, body: DocumentBody.newDocument(text: "Hello").bytes,
                                contentType: DocumentBody.envelopeContentType)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        return id
    }
    private func channel(_ h: WorkHarness, _ id: String) async throws -> ChannelRecord {
        let all = try await h.store.reader.channels(workspaceId: h.workspace.id)
        return try XCTUnwrap(all.first { $0.id == id })
    }

    func testMoveKeepsTheRecordIdAndUpdatesTheCachedLocation() async throws {
        let h = try await WorkHarness.make()
        let id = try await seed(h)
        let destination = try await channel(h, Fixtures.channel2)
        let result = await h.saver.move(docId: id, to: destination, rowVersion: 1, connection: h.connection, workspace: h.workspace)
        guard case .moved(let doc, _) = result else { return XCTFail("not moved: \(result)") }
        XCTAssertEqual(doc.id, id)
        XCTAssertEqual(doc.channelId, Fixtures.channel2)
        XCTAssertEqual(doc.rowVersion, 2)
        let cached = try await h.store.reader.doc(workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(cached?.channelId, Fixtures.channel2, "an old link resolves to the same record at its new location")
        let body = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: id)
        XCTAssertNotNil(body, "the cached body is unchanged")
        let sent = try XCTUnwrap(h.transport.recorded.last { $0.url?.path.hasSuffix("/move") == true })
        let json = try JSONSerialization.jsonObject(with: sent.httpBody!) as! [String: Any]
        XCTAssertEqual(json["row_version"] as? Int, 1)
        XCTAssertEqual(json["destination_channel_id"] as? String, Fixtures.channel2)
    }

    func testStaleMoveChangesNothing() async throws {
        let h = try await WorkHarness.make()
        let id = try await seed(h)
        h.work.externalDocSave(id, body: DocumentBody.newDocument(text: "Theirs").bytes, contentType: DocumentBody.envelopeContentType)
        let result = await h.saver.move(docId: id, to: try await channel(h, Fixtures.channel2), rowVersion: 1, connection: h.connection, workspace: h.workspace)
        guard case .stale = result else { return XCTFail("expected stale: \(result)") }
        let cached = try await h.store.reader.doc(workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(cached?.channelId, Fixtures.channel1)
    }

    func testMoveToTheSameChannelAndRefusedMovesAreReportedWithoutClaimingSuccess() async throws {
        let h = try await WorkHarness.make()
        let id = try await seed(h)
        let here = try await channel(h, Fixtures.channel1), there = try await channel(h, Fixtures.channel2)
        guard case .sameDestination = await h.saver.move(docId: id, to: here, rowVersion: 1, connection: h.connection, workspace: h.workspace) else { return XCTFail("same destination") }
        h.work.inject(.status(403, "forbidden"), matching: "/move")
        guard case .denied = await h.saver.move(docId: id, to: there, rowVersion: 1, connection: h.connection, workspace: h.workspace) else { return XCTFail("denied") }
        let cached = try await h.store.reader.doc(workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(cached?.channelId, Fixtures.channel1)
    }

    func testOfflineMoveIsNotQueuedAndTowerIsAskedWhereTheDocumentIs() async throws {
        let h = try await WorkHarness.make()
        let id = try await seed(h)
        h.work.inject(.offline, matching: "/move")
        let result = await h.saver.move(docId: id, to: try await channel(h, Fixtures.channel2), rowVersion: 1, connection: h.connection, workspace: h.workspace)
        // The request failed, the read-back works: Tower confirms the document never moved.
        guard case .notMoved(let message) = result else { return XCTFail("expected notMoved: \(result)") }
        XCTAssertTrue(message.contains("still has the document where it was"))
        let queued = try await h.pending()
        XCTAssertTrue(queued.isEmpty, "a move is never queued for a blind retry")
        let cached = try await h.store.reader.doc(workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(cached?.channelId, Fixtures.channel1)
        XCTAssertEqual(h.transport.recorded.filter { $0.url?.path.hasSuffix("/move") == true }.count, 1, "no automatic second attempt")
    }

    func testLostResponseAfterTowerAcceptedIsReconciledAsMovedByReadingTheDocument() async throws {
        let h = try await WorkHarness.make()
        let id = try await seed(h)
        h.work.inject(.dropResponseAfterCommit, matching: "/move")
        let result = await h.saver.move(docId: id, to: try await channel(h, Fixtures.channel2), rowVersion: 1, connection: h.connection, workspace: h.workspace)
        guard case .moved(let doc, _) = result else { return XCTFail("expected moved after read-back: \(result)") }
        XCTAssertEqual(doc.channelId, Fixtures.channel2)
        let cached = try await h.store.reader.doc(workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(cached?.channelId, Fixtures.channel2)
        XCTAssertEqual(h.transport.recorded.filter { $0.url?.path.hasSuffix("/move") == true }.count, 1, "the move was not sent twice")
    }

    func testServerErrorWhoseOutcomeCannotBeReadBackIsReportedUnknownNotUnchanged() async throws {
        let h = try await WorkHarness.make()
        let id = try await seed(h)
        h.work.inject(.status(503, "unavailable"), matching: "/move")
        h.work.inject(.offline, matching: "/docs/\(id)")   // the read-back fails too
        let result = await h.saver.move(docId: id, to: try await channel(h, Fixtures.channel2), rowVersion: 1, connection: h.connection, workspace: h.workspace)
        guard case .unknown(let message) = result else { return XCTFail("expected unknown: \(result)") }
        XCTAssertFalse(message.contains("nothing was changed"))
        XCTAssertTrue(message.contains("not known whether the document moved"))
    }

    func testDraftCompareAndSetNeverOverwritesALaterEdit() async throws {
        let h = try await WorkHarness.make()
        let id = try await seed(h)
        let stored = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: id)
        let cached = try XCTUnwrap(stored)
        let first = DocDraft(connectionId: h.connection.id, workspaceId: h.workspace.id, docId: id, title: "Plan", body: Data("one".utf8), contentType: "text/markdown",
                             baseRowVersion: 1, baseSha256: cached.sha256, baseStorageObjectId: cached.storageObjectId, state: .editing)
        try await h.store.writer.saveDocDraft(first)
        // The editor saves newer text while a move (or a link binding) was in flight.
        let later = DocDraft(connectionId: first.connectionId, workspaceId: first.workspaceId, docId: id, title: "Plan", body: Data("two, typed meanwhile".utf8),
                             contentType: "text/markdown", baseRowVersion: 1, baseSha256: cached.sha256, baseStorageObjectId: cached.storageObjectId, state: .editing)
        try await h.store.writer.saveDocDraft(later)
        let replaced = try await h.store.writer.replaceDocDraft(ifUnchanged: first, with: first.with(state: .failed, error: "stale snapshot"))
        XCTAssertFalse(replaced, "the older snapshot is refused")
        let current = try await h.store.reader.docDraft(key: first.key)
        XCTAssertEqual(current?.body, later.body)
        // A re-base touches only the base version, and only while the draft is based on the version that moved.
        let rebased = try await h.store.writer.rebaseDocDraft(key: first.key, workspaceId: first.workspaceId, from: 1, to: 2)
        let again = try await h.store.writer.rebaseDocDraft(key: first.key, workspaceId: first.workspaceId, from: 1, to: 3)
        XCTAssertTrue(rebased); XCTAssertFalse(again)
        let after = try await h.store.reader.docDraft(key: first.key)
        XCTAssertEqual(after?.baseRowVersion, 2)
        XCTAssertEqual(after?.body, later.body)
    }

    func testSavingDraftBlocksTheMove() async throws {
        let h = try await WorkHarness.make()
        let id = try await seed(h)
        let stored = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: id)
        let cached = try XCTUnwrap(stored)
        let saving = DocDraft(connectionId: h.connection.id, workspaceId: h.workspace.id, docId: id, title: "Plan", body: cached.bytes, contentType: cached.contentType,
                              baseRowVersion: 1, baseSha256: cached.sha256, baseStorageObjectId: cached.storageObjectId, state: .saving)
        try await h.store.writer.saveDocDraft(saving)
        let result = await h.saver.move(docId: id, to: try await channel(h, Fixtures.channel2), rowVersion: 1, connection: h.connection, workspace: h.workspace)
        guard case .notMoved = result else { return XCTFail("expected notMoved: \(result)") }
        XCTAssertFalse(h.transport.recorded.contains { $0.url?.path.hasSuffix("/move") == true })
    }

    func testDraftOnTheMovedVersionSurvivesAndSavesWithoutAConflict() async throws {
        let h = try await WorkHarness.make()
        let id = try await seed(h)
        let stored = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: id)
        let cached = try XCTUnwrap(stored)
        let body = DocumentBody(bytes: cached.bytes, contentType: cached.contentType)
        let edited = try body.encoded(editorState: try DocumentEditor.setText(try XCTUnwrap(body.editorState), path: [0], text: "Unsaved words"))
        let draft = DocDraft(connectionId: h.connection.id, workspaceId: h.workspace.id, docId: id, title: "Plan", body: edited.bytes, contentType: edited.contentType,
                             baseRowVersion: cached.docRowVersion, baseSha256: cached.sha256, baseStorageObjectId: cached.storageObjectId, state: .editing)
        try await h.store.writer.saveDocDraft(draft)
        guard case .moved = await h.saver.move(docId: id, to: try await channel(h, Fixtures.channel2), rowVersion: 1, connection: h.connection, workspace: h.workspace)
        else { return XCTFail("move") }
        let keptDraft = try await h.store.reader.docDraft(key: draft.key)
        let kept = try XCTUnwrap(keptDraft)
        XCTAssertEqual(kept.body, draft.body, "the unsaved text is untouched")
        XCTAssertEqual(kept.baseRowVersion, 2, "its base follows the document")
        guard case .saved = await h.saver.save(kept, connection: h.connection, workspace: h.workspace) else { return XCTFail("saves after the move without a recovery copy") }
        XCTAssertEqual(h.work.recoveryCount, 0)
    }

    func testDraftBasedOnAnOlderVersionBlocksTheMove() async throws {
        let h = try await WorkHarness.make()
        let id = try await seed(h)
        let stored = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: id)
        let cached = try XCTUnwrap(stored)
        let old = DocDraft(connectionId: h.connection.id, workspaceId: h.workspace.id, docId: id, title: "Plan", body: cached.bytes, contentType: cached.contentType,
                           baseRowVersion: 0, baseSha256: cached.sha256, baseStorageObjectId: cached.storageObjectId, state: .editing)
        try await h.store.writer.saveDocDraft(old)
        let result = await h.saver.move(docId: id, to: try await channel(h, Fixtures.channel2), rowVersion: 1, connection: h.connection, workspace: h.workspace)
        guard case .notMoved(let message) = result else { return XCTFail("expected notMoved: \(result)") }
        XCTAssertTrue(message.contains("unsaved edits"))
        XCTAssertFalse(h.transport.recorded.contains { $0.url?.path.hasSuffix("/move") == true }, "nothing was sent")
    }

    func testConsequencesNameTheAccessChangeAndPrivateConversations() {
        let shared = ChannelRecord(workspaceId: "w", id: "c1", scopeId: "s1", name: "general", updatedAt: "")
        let other = ChannelRecord(workspaceId: "w", id: "c2", scopeId: "s2", name: "team", updatedAt: "")
        let note = ChannelRecord(workspaceId: "w", id: "c3", scopeId: "s3", name: "DM: me", kind: "dm", updatedAt: "",
                                 raw: Data(#"{"participants":["npub1me"],"description":"dm:npub1me"}"#.utf8))
        let across = DocMovePlan.consequences(from: shared, to: other, viewerNpub: "npub1me")
        XCTAssertFalse(across.touchesPrivateConversation)
        XCTAssertTrue(across.lines.contains { $0.contains("Access follows team") })
        XCTAssertTrue(across.lines.contains { $0.contains("changes scope") })
        XCTAssertTrue(across.lines.contains { $0.contains("never grants access") })
        let fromNote = DocMovePlan.consequences(from: note, to: shared, viewerNpub: "npub1me")
        XCTAssertTrue(fromNote.touchesPrivateConversation)
        XCTAssertTrue(fromNote.lines.contains { $0.contains("private note-to-self") })
    }
}

/// Create-and-link: one durable write creates the page and the source learns its id, even across lost responses and a source
/// that cannot be saved right now.
final class WikiCreateTests: XCTestCase {
    private func sourceBody(_ text: String = "See [[Dashboard]] today") -> Data {
        let state = JSONValue.object([("type", .string("doc")), ("content", .array([.object([("type", .string("paragraph")),
            ("content", .array([.object([("type", .string("text")), ("text", .string(text))])]))])]))])
        let model = JSONValue.object(ProseMirrorMarkdown.contentModelFields(state))
        return JSONValue.object([("format", .string(DocumentBody.envelopeFormat)), ("content_model", model)]).serialized()
    }

    private func sender(_ h: WorkHarness, failBinding: Bool = false) -> WriteSender {
        let store = h.store, saver = h.saver, workspace = h.workspace
        return WriteSender(store: store, engine: h.engine, identity: h.chat.identity, transport: h.transport, staging: h.staging,
                           afterWikiCreate: { connection, item, created in
            if failBinding { throw URLError(.cannotConnectToHost) }
            _ = try await WikiBinder.bind(title: item.string(WikiCreate.titleKey) ?? "", to: created.id, occurrence: (item.payloadObject[WikiCreate.occurrenceKey] as? Int),
                                          sourceDocId: item.string(WikiCreate.sourceKey) ?? "", connection: connection, workspace: workspace, store: store, saver: saver)
        })
    }

    private func intent(_ h: WorkHarness, source: String, channel: String = Fixtures.channel2, title: String = "Dashboard") throws -> WriteIntent {
        let created = DocumentBody.newDocument(text: "")
        let name = UUID().uuidString.lowercased() + ".document.json"
        try FileManager.default.createDirectory(at: h.staging, withIntermediateDirectories: true)
        try created.bytes.write(to: h.staging.appendingPathComponent(name))
        var payload: [String: any Sendable] = ["channel_id": channel, "title": title, "staged": name, "content_type": created.contentType, "file_name": title + ".document.json"]
        payload.merge(WikiCreate.linkPayload(sourceDocId: source, title: title, occurrence: nil)) { $1 }
        return WriteIntent(kind: .docCreate, targetId: channel, payload: payload)
    }

    private func seededSource(_ h: WorkHarness) async throws -> String {
        let id = h.work.seedDoc(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Petes Notes", body: sourceBody(), contentType: DocumentBody.envelopeContentType)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        return id
    }

    private func savedMarkdown(_ h: WorkHarness, _ id: String) -> String { DocumentBody(bytes: h.work.docBody(id)!, contentType: nil).markdown }

    func testCreateAndLinkCreatesOnePageInTheChosenChannelAndLinksTheSource() async throws {
        let h = try await WorkHarness.make()
        let source = try await seededSource(h)
        let writer = sender(h)
        try await writer.submit(intent(h, source: source), connection: h.connection, workspace: h.workspace)
        await h.settled()
        let docs = try await h.store.reader.docs(workspaceId: h.workspace.id)
        let created = try XCTUnwrap(docs.first { $0.title == "Dashboard" })
        XCTAssertEqual(created.channelId, Fixtures.channel2, "created where the person chose, not in the source channel")
        XCTAssertEqual(docs.filter { $0.title == "Dashboard" }.count, 1)
        XCTAssertEqual(savedMarkdown(h, source), "See [Dashboard](wiki:\(created.id)) today")
        let rest = try await h.pending()
        XCTAssertTrue(rest.isEmpty, "the write is retired only after the link was recorded")
    }

    func testLostResponseRetryNeitherDuplicatesThePageNorLosesTheLink() async throws {
        let h = try await WorkHarness.make()
        let source = try await seededSource(h)
        h.work.inject(.dropResponseAfterCommit, matching: "/channels/\(Fixtures.channel2)/docs")
        let writer = sender(h)
        try await writer.submit(intent(h, source: source), connection: h.connection, workspace: h.workspace)
        await h.settled()
        await writer.kick(h.connection, force: true); await h.engine.waitUntilIdle()
        let docs = try await h.store.reader.docs(workspaceId: h.workspace.id)
        XCTAssertEqual(docs.filter { $0.title == "Dashboard" }.count, 1, "the retry found the page created by the lost attempt")
        let created = try XCTUnwrap(docs.first { $0.title == "Dashboard" })
        XCTAssertTrue(savedMarkdown(h, source).contains("wiki:\(created.id)"))
    }

    func testSourceThatCannotBeSavedKeepsTheLinkInADraftAndTheCreatedPage() async throws {
        let h = try await WorkHarness.make()
        let source = try await seededSource(h)
        h.work.inject(.offline, matching: "/storage/prepare")   // the page's own upload goes first and may use it, so arm after creation below
        h.work.inject(.offline, matching: "/edit-leases/acquire")
        let writer = sender(h)
        try await writer.submit(intent(h, source: source), connection: h.connection, workspace: h.workspace)
        await h.settled()
        await writer.kick(h.connection, force: true); await h.engine.waitUntilIdle()
        let docs = try await h.store.reader.docs(workspaceId: h.workspace.id)
        let created = try XCTUnwrap(docs.first { $0.title == "Dashboard" }, "the created page exists")
        XCTAssertEqual(docs.filter { $0.title == "Dashboard" }.count, 1)
        let key = DocDraft.key(connectionId: h.connection.id, workspaceId: h.workspace.id, docId: source)
        let draftRow = try await h.store.reader.docDraft(key: key)
        let draft = try XCTUnwrap(draftRow, "the source link survives as an unsaved draft")
        XCTAssertTrue(DocumentBody(bytes: draft.body, contentType: draft.contentType).markdown.contains("wiki:\(created.id)"))
        // The person (or a later retry) saves it once online again.
        guard case .saved = await h.saver.save(draft, connection: h.connection, workspace: h.workspace) else { return XCTFail("saves later") }
        XCTAssertTrue(savedMarkdown(h, source).contains("wiki:\(created.id)"))
    }

    func testFailedLinkingKeepsTheWriteQueuedAndTheRetryDoesNotCreateASecondPage() async throws {
        let h = try await WorkHarness.make()
        let source = try await seededSource(h)
        let failing = sender(h, failBinding: true)
        try await failing.submit(intent(h, source: source), connection: h.connection, workspace: h.workspace)
        await h.settled()
        var rows = try await h.pending()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.lastCode, "wiki_link_pending")
        let working = sender(h)
        await working.kick(h.connection, force: true); await h.engine.waitUntilIdle()
        rows = try await h.pending()
        XCTAssertTrue(rows.isEmpty)
        let docs = try await h.store.reader.docs(workspaceId: h.workspace.id)
        XCTAssertEqual(docs.filter { $0.title == "Dashboard" }.count, 1)
        let created = try XCTUnwrap(docs.first { $0.title == "Dashboard" })
        XCTAssertTrue(savedMarkdown(h, source).contains("wiki:\(created.id)"))
    }

    func testUnsavedEditsInTheSourceReceiveTheLinkWithoutBeingUploaded() async throws {
        let h = try await WorkHarness.make()
        let source = try await seededSource(h)
        let stored = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: source)
        let cached = try XCTUnwrap(stored)
        let mine = sourceBody("My new words and [[Dashboard]]")
        let draft = DocDraft(connectionId: h.connection.id, workspaceId: h.workspace.id, docId: source, title: "Petes Notes", body: mine,
                             contentType: DocumentBody.envelopeContentType, baseRowVersion: cached.docRowVersion, baseSha256: cached.sha256,
                             baseStorageObjectId: cached.storageObjectId, state: .editing)
        try await h.store.writer.saveDocDraft(draft)
        let writer = sender(h)
        try await writer.submit(intent(h, source: source), connection: h.connection, workspace: h.workspace)
        await h.settled()
        let docs = try await h.store.reader.docs(workspaceId: h.workspace.id)
        let created = try XCTUnwrap(docs.first { $0.title == "Dashboard" })
        let after = try await h.store.reader.docDraft(key: draft.key)
        let kept = try XCTUnwrap(after)
        XCTAssertEqual(DocumentBody(bytes: kept.body, contentType: kept.contentType).markdown, "My new words and [Dashboard](wiki:\(created.id))")
        XCTAssertFalse(savedMarkdown(h, source).contains("wiki:"), "the person's unsaved edits were not uploaded for them")
        XCTAssertFalse(savedMarkdown(h, source).contains("My new words"))
    }

    func testRepeatRequestsFindThePendingOrExistingPageInsteadOfCreatingAnother() async throws {
        let h = try await WorkHarness.make()
        let source = try await seededSource(h)
        let queued = try await h.writes.submit(intent(h, source: source), connection: h.connection, workspace: h.workspace)
        let pending = try await h.pending()
        let docs = try await h.store.reader.docs(workspaceId: h.workspace.id)
        if case .pending(let item)? = WikiCreate.existing(title: " dashboard ", channelId: Fixtures.channel2, docs: docs, pending: pending) { XCTAssertEqual(item.id, queued.id) }
        else if !pending.isEmpty { XCTFail("a queued creation must be found") }
        XCTAssertNil(WikiCreate.existing(title: "Dashboard", channelId: Fixtures.channel1, docs: docs, pending: []))
        await h.settled()
        let after = try await h.store.reader.docs(workspaceId: h.workspace.id)
        guard case .page(let page)? = WikiCreate.existing(title: "Dashboard", channelId: Fixtures.channel2, docs: after, pending: []) else { return XCTFail("existing page") }
        XCTAssertEqual(page.channelId, Fixtures.channel2)
    }
}
