import Foundation
import XCTest
@testable import AmbulandoCore

final class MentionLookupTests: XCTestCase {
    let w = Fixtures.workspaceId
    let rick = Mention(type: .agent, npub: "npub1hd37reqgfcnz3pvzj4grknd2nkzc94p9ercmunrxx22razr2rfxsw6dns5", label: "Rick")

    func id(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }

    func doc(_ n: Int, _ title: String, updated: String = "2026-10-20T00:00:00.000Z", archived: Bool = false) throws -> DocRecord {
        try DocRecord(raw: Fixtures.json(["id": id(n), "workspace_id": w, "channel_id": Fixtures.channel1, "scope_id": Fixtures.scopeA,
                                          "title": title, "record_state": archived ? "archived" : "active", "row_version": 1,
                                          "activity_version": 1, "created_at": updated, "updated_at": updated]))
    }

    func task(_ n: Int, _ title: String, state: String = "new", updated: String = "2026-10-20T00:00:00.000Z") throws -> TaskRecord {
        var object = FakeEventTower.task(id(n), title: title, version: 1)
        object["state"] = state
        object["updated_at"] = updated
        return try TaskRecord(raw: Fixtures.json(object))
    }

    // MARK: Tokens

    func testRecordReferencesUseTheWebTokensAndOnlyPeopleAreRouted() {
        let doc = Mention(type: .doc, npub: id(1), label: "Release plan")
        let thread = Mention(type: .chat, npub: "\(Fixtures.channel1)#\(id(2))", label: "Ship it?")
        let (body, routed) = MentionCodec.encode(text: "see @Release plan and @Ship it? with @Rick", selected: [doc, thread, rick])
        XCTAssertEqual(body, "see @[Release plan](mention:doc:\(id(1))) and @[Ship it?](mention:chat:\(Fixtures.channel1)#\(id(2))) with \(rick.token)")
        XCTAssertEqual(routed, [rick], "records travel in the body only; mentions[] stays people and agents")
        // A stored body renders actors as mentions and records as references.
        let segments = MentionCodec.segments(body)
        XCTAssertTrue(segments.contains(.reference(label: "Release plan", kind: "doc", id: id(1))))
        XCTAssertTrue(segments.contains(.mention(rick)))
        // Editing it again restores the pills for both.
        let decoded = MentionCodec.decode(body: body)
        XCTAssertEqual(decoded.text, "see @Release plan and @Ship it? with @Rick")
        XCTAssertEqual(Set(decoded.mentions), Set([doc, thread, rick]))
        // An unknown record kind is kept as its exact token.
        XCTAssertEqual(MentionCodec.decode(body: "@[Q4](mention:flow:\(id(3)))").text, "@[Q4](mention:flow:\(id(3)))")
    }

    func testDraftsWithOldMentionsStillDecode() throws {
        let stored = Data(#"[{"type":"person","npub":"npub1x","label":"Ann"}]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([Mention].self, from: stored), [Mention(type: .person, npub: "npub1x", label: "Ann")])
        let doc = Mention(type: .doc, npub: id(1), label: "Plan")
        XCTAssertEqual(try JSONDecoder().decode(Mention.self, from: JSONEncoder().encode(doc)), doc)
    }

    func testCommentCompletionUsesCaretAndKeepsWholeParagraphAndAttachments() throws {
        let body = "🧭 Before @ric after ![photo](storage://sample)\nsecond line"
        let caret = ("🧭 Before @ric" as NSString).length
        let selection = NSRange(location: caret, length: 0)
        XCTAssertEqual(CommentMentions.query(in: body, selection: selection)?.text, "ric")
        let next = try XCTUnwrap(CommentMentions.complete(body, selection: selection, with: rick))
        XCTAssertEqual(next, "🧭 Before \(rick.token)  after ![photo](storage://sample)\nsecond line")
        let remapped = ComposerText.remap(selection, from: body, to: next)
        XCTAssertEqual(remapped.location, ("🧭 Before \(rick.token) " as NSString).length)
        XCTAssertNil(CommentMentions.query(in: next, selection: remapped), "a completed canonical token does not reopen the list")
        XCTAssertNil(CommentMentions.query(in: "mail@ric", selection: NSRange(location: 8, length: 0)))
        XCTAssertNil(CommentMentions.query(in: body, selection: NSRange(location: caret, length: 1)))
    }

    func testCommentRoutingUsesCanonicalActorIdentitiesOnlyAndKeepsTypes() {
        let person = Mention(type: .person, npub: TestKeys.npub, label: "Pete")
        let doc = Mention(type: .doc, npub: id(2), label: "Plan")
        let body = "@Rick \(rick.token) \(rick.token) \(person.token) \(doc.token) @[Spoof](mention:agent:not-an-npub)"
        XCTAssertEqual(CommentMentions.actors(in: body), [rick, person])
        XCTAssertEqual(CommentMentions.actors(in: "@Rick @Pete"), [], "display names are never routing authority")
        XCTAssertEqual(CommentMentions.actors(in: body.replacingOccurrences(of: rick.token, with: "")), [person])
        XCTAssertEqual(CommentMentions.actors(in: person.token).first?.requestObject["type"], "person")
    }

    // MARK: Query

    func testQueryPrefixesAndRankingFollowTheWeb() {
        XCTAssertEqual(MentionQuery("doc: plan").only, .doc)
        XCTAssertEqual(MentionQuery("doc: plan").text, "plan")
        XCTAssertEqual(MentionQuery("chat:general").only, .channel, "chat: is the web's alias for channel")
        XCTAssertEqual(MentionQuery("Thread:ship").only, .chat)
        XCTAssertNil(MentionQuery("plan").only)
        XCTAssertTrue(MentionQuery("person:").allows(.agent), "person: lists agents too, as on the web")
        XCTAssertFalse(MentionQuery("agent:").allows(.person))
        XCTAssertTrue(MentionQuery("flow:q4").unavailable, "flows are not stored on this device")
        XCTAssertFalse(MentionQuery("flow:q4").allows(.doc))
        XCTAssertEqual(MentionQuery("").limit, 15)
        XCTAssertEqual(MentionQuery("pl").limit, 10)
        XCTAssertEqual(MentionQuery("channel:").limit, 500)
        let q = MentionQuery("plan")
        XCTAssertEqual(q.rank("Plan"), 0)
        XCTAssertEqual(q.rank("Planning"), 1)
        XCTAssertEqual(q.rank("Release plan"), 2)
        XCTAssertEqual(q.rank("Explanation"), 2)
        XCTAssertNil(q.rank("Roadmap"))
        XCTAssertEqual(MentionQuery("über").rank("Das ÜBER-Board"), 2, "case is ignored beyond ASCII")
    }

    // MARK: Store lookup

    func testLookupFindsDocsTasksThreadsChannelsAndScopesInThisWorkspaceOnly() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        try await store.writer.upsertScopes(workspaceId: w, [try ScopeRecord(raw: Fixtures.json(Fixtures.scope(Fixtures.scopeA, name: "Planning")))], complete: false)
        try await store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA,
                                              [try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "plans")))], complete: false)
        try await store.writer.upsertDocs(workspaceId: w, [try doc(1, "Release plan", updated: "2026-10-21T00:00:00.000Z"), try doc(2, "Plan B"),
                                                           try doc(3, "Old plan", archived: true), try doc(4, "Budget")])
        try await store.writer.upsertTasks(workspaceId: w, [try task(5, "Plan the launch"), try task(6, "Archived plan", state: "archived")])
        let root = id(7), thread = id(8)
        try await store.writer.upsertThreads(workspaceId: w, [try ThreadRecord(raw: Fixtures.json([
            "id": thread, "workspace_id": w, "channel_id": Fixtures.channel1, "source_message_id": root, "title": NSNull(), "latest": NSNull(),
            "record_state": "active", "row_version": 1, "updated_at": "2026-10-24T01:00:00.000Z"]))])
        try await store.writer.upsertMessages([
            MessageRecord(workspaceId: w, id: root, channelId: Fixtures.channel1, threadId: thread, threadSourceId: root,
                          body: "Plan for @[Rick](mention:agent:\(rick.npub)) review\nsecond line", senderNpub: TestKeys.npub,
                          createdAt: "2026-10-24T01:00:00.000Z")])
        // Another workspace's record never appears.
        let otherDoc = try DocRecord(raw: Fixtures.json(["id": id(9), "workspace_id": Fixtures.workspaceId2, "channel_id": Fixtures.channel2,
                                                         "title": "Plan elsewhere", "row_version": 1, "created_at": "x", "updated_at": "x"]))
        try await store.writer.upsertDocs(workspaceId: Fixtures.workspaceId2, [otherDoc])

        let all = try await store.reader.mentionSuggestions(workspaceId: w, query: MentionQuery("plan"))
        XCTAssertEqual(Set(all.map(\.mention.type)), [.doc, .task, .chat, .channel, .scope])
        XCTAssertEqual(all.filter { $0.mention.type == .doc }.map(\.mention.label), ["Plan B", "Release plan"], "names starting with it first")
        XCTAssertFalse(all.contains { $0.mention.label == "Old plan" || $0.mention.label == "Archived plan" || $0.mention.label == "Plan elsewhere" })
        let conversation = try XCTUnwrap(all.first { $0.mention.type == .chat })
        XCTAssertEqual(conversation.mention.id, "\(Fixtures.channel1)#\(root)")
        XCTAssertEqual(conversation.mention.label, "Plan for @Rick review", "first line of the first message, mentions as names")
        XCTAssertEqual(all.first { $0.mention.type == .scope }?.detail, "Project")

        // A document in a channel this device no longer lists (access lost) is not offered.
        try await store.writer.upsertDocs(workspaceId: w, [try DocRecord(raw: Fixtures.json([
            "id": id(10), "workspace_id": w, "channel_id": Fixtures.channel2, "title": "Plan in a hidden channel", "row_version": 1,
            "created_at": "2026-10-22T00:00:00.000Z", "updated_at": "2026-10-22T00:00:00.000Z"]))])
        let visible = try await store.reader.mentionSuggestions(workspaceId: w, query: MentionQuery("plan"))
        XCTAssertFalse(visible.contains { $0.mention.label == "Plan in a hidden channel" })
        // Case is ignored beyond ASCII (SQLite's LIKE alone would not match these).
        try await store.writer.upsertDocs(workspaceId: w, [try doc(11, "ÜBERSICHT Straße"), try doc(12, "Ωmega notes")])
        let unicode = try await store.reader.mentionSuggestions(workspaceId: w, query: MentionQuery("übersicht"))
        XCTAssertEqual(unicode.map(\.mention.label), ["ÜBERSICHT Straße"])
        let greek = try await store.reader.mentionSuggestions(workspaceId: w, query: MentionQuery("ωMEGA"))
        XCTAssertEqual(greek.map(\.mention.label), ["Ωmega notes"])

        let docsOnly = try await store.reader.mentionSuggestions(workspaceId: w, query: MentionQuery("doc:"))
        XCTAssertEqual(Array(docsOnly.map(\.mention.label).prefix(3)), ["Release plan", "Budget", "Plan B"], "bare kind prefix lists the most recent")
        let literal = try await store.reader.mentionSuggestions(workspaceId: w, query: MentionQuery("100%"))
        XCTAssertTrue(literal.isEmpty, "% is matched literally")
    }

    func testMergeGroupsByKindWithAnExactPersonFirst() {
        let records = [MentionSuggestion(mention: Mention(type: .channel, npub: id(1), label: "rick"), detail: "Channel", updatedAt: "2"),
                       MentionSuggestion(mention: Mention(type: .doc, npub: id(2), label: "Notes for Rick"), detail: "Doc", updatedAt: "1"),
                       MentionSuggestion(mention: Mention(type: .doc, npub: id(3), label: "Rick's notes"), detail: "Doc", updatedAt: "0")]
        let ann = Mention(type: .person, npub: "npub1ann", label: "Ann")
        let merged = MentionRanking.merge(actors: [(ann, "npub1ann"), (rick, rick.npub)], records: records, query: MentionQuery("rick"))
        XCTAssertEqual(merged.map(\.mention.label), ["Rick", "Rick's notes", "Notes for Rick", "rick"], "exact actor, then docs (prefix first), then channels")
        // People also match their npub, as on the web.
        XCTAssertEqual(MentionRanking.merge(actors: [(ann, "npub1ann")], records: [], query: MentionQuery("npub1an")).map(\.mention), [ann])
        let bare = MentionRanking.merge(actors: [(rick, rick.npub), (ann, "npub1ann"), (ann, "dup")], records: records, query: MentionQuery(""))
        XCTAssertEqual(bare.map(\.mention.type), [.agent, .person, .doc, .doc, .channel])
        XCTAssertTrue(MentionRanking.merge(actors: [(rick, rick.npub)], records: records, query: MentionQuery("task:")).isEmpty)
    }

    // MARK: Recently tagged first

    func testBareAtListsWhatWasTaggedMostRecentlyFirstAndFollowsTheDirectoryName() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let brick = Mention(type: .agent, npub: "npub1brick", label: "Brick")
        let ann = Mention(type: .person, npub: "npub1ann", label: "Ann")
        let planned = Mention(type: .doc, npub: id(1), label: "Release plan")
        func message(_ n: Int, _ body: String, at day: Int, from sender: String = TestKeys.npub) -> MessageRecord {
            MessageRecord(workspaceId: w, id: id(100 + n), channelId: Fixtures.channel1, threadId: nil, threadSourceId: nil, body: body,
                          senderNpub: sender, createdAt: String(format: "2026-10-%02dT00:00:00.000Z", day))
        }
        try await store.writer.upsertMessages([
            message(1, "ping \(ann.token) please", at: 10),
            message(2, "\(rick.token) and \(brick.token)", at: 12),
            message(3, "see @[Release plan](mention:document:\(id(1)))", at: 11),
            message(4, "\(rick.token) again", at: 13),
            message(5, "\(ann.token) from someone else", at: 14, from: "npub1someoneelse"),
            message(6, "no tags here", at: 15)])
        try await store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA,
            [try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "general")))], complete: false)
        try await store.writer.upsertDocs(workspaceId: w, [try doc(1, "Release plan")])
        let recent = try await store.reader.recentMentions(workspaceId: w, senderNpub: TestKeys.npub)
        XCTAssertEqual(recent.map(\.npub), [rick.npub, brick.npub, planned.npub, ann.npub], "newest message first, once each; the web's document spelling counts; others' messages do not")
        XCTAssertEqual(recent.map(\.type), [.agent, .agent, .doc, .person])

        // A deleted person is not offered; a renamed agent shows the directory's current name.
        let renamed = Mention(type: .agent, npub: rick.npub, label: "Rick Renamed")
        let bare = MentionRanking.merge(actors: [(ann, ann.npub), (renamed, rick.npub)], records: [], query: MentionQuery(""), recent: recent)
        XCTAssertEqual(bare.map(\.mention.label), ["Rick Renamed", "Release plan", "Ann"], "Brick left the directory; Rick leads under the current name; the rest follow")
        XCTAssertEqual(bare.first?.detail, "Agent")
        // Typing narrows as before: recents only order the bare list.
        XCTAssertEqual(MentionRanking.merge(actors: [(ann, ann.npub), (renamed, rick.npub)], records: [], query: MentionQuery("an"), recent: recent).map(\.mention.label), ["Ann"])
    }

    func testRecentRecordsResolveCurrentNamesAndEligibilityBeyondDefaultLimit() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        try await store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA,
            [try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "general")))], complete: false)
        var docs = try (1...25).map { try doc($0, "Newer \($0)", updated: "2026-10-27T00:00:00.000Z") }
        docs += [try doc(40, "Renamed old document", updated: "2026-10-01T00:00:00.000Z"), try doc(41, "Archived", archived: true)]
        try await store.writer.upsertDocs(workspaceId: w, docs)
        try await store.writer.upsertTasks(workspaceId: w, [try task(43, "Archived task", state: "archived")])
        let root = id(45), thread = id(46)
        try await store.writer.upsertThreads(workspaceId: w, [try ThreadRecord(raw: Fixtures.json([
            "id": thread, "workspace_id": w, "channel_id": Fixtures.channel1, "source_message_id": root,
            "title": "Deleted thread", "record_state": "deleted", "row_version": 1, "updated_at": "x"]))])
        try await store.writer.upsertMessages([MessageRecord(workspaceId: w, id: root, channelId: Fixtures.channel1, threadId: thread, threadSourceId: root,
            body: "Deleted root", senderNpub: TestKeys.npub, createdAt: "2026-10-20T00:00:00.000Z")])
        let tags = [Mention(type: .doc, npub: id(40), label: "Old name"), Mention(type: .doc, npub: id(41), label: "Archived"),
                    Mention(type: .doc, npub: id(42), label: "Absent"), Mention(type: .task, npub: id(43), label: "Archived task"),
                    Mention(type: .chat, npub: "\(Fixtures.channel1)#\(root)", label: "Deleted thread")]
        try await store.writer.upsertMessages([MessageRecord(workspaceId: w, id: id(50), channelId: Fixtures.channel1, threadId: nil, threadSourceId: nil,
            body: tags.map(\.token).joined(separator: " "), senderNpub: TestKeys.npub, createdAt: "2026-10-28T00:00:00.000Z")])
        let withDeletedThread = try await store.reader.recentMentions(workspaceId: w, senderNpub: TestKeys.npub)
        XCTAssertEqual(withDeletedThread, [Mention(type: .doc, npub: id(40), label: "Renamed old document")])
        // Archiving a thread also removes its recent reference, without deleting its messages.
        try await store.writer.upsertThreads(workspaceId: w, [try ThreadRecord(raw: Fixtures.json([
            "id": thread, "workspace_id": w, "channel_id": Fixtures.channel1, "source_message_id": root,
            "title": "Archived thread", "record_state": "archived", "row_version": 2, "updated_at": "z"]))])
        let defaults = try await store.reader.mentionSuggestions(workspaceId: w, query: MentionQuery(""), limit: 15)
        XCTAssertFalse(defaults.contains { $0.mention.id == id(40) }, "the renamed record is outside the default search window")
        let recent = try await store.reader.recentMentions(workspaceId: w, senderNpub: TestKeys.npub)
        XCTAssertEqual(recent, [Mention(type: .doc, npub: id(40), label: "Renamed old document")])
        let ranked = MentionRanking.merge(actors: [], records: defaults, query: MentionQuery(""), recent: recent)
        XCTAssertEqual(ranked.first?.mention.label, "Renamed old document")
    }

    func testRecentMentionsAreCappedAndSkipDeletedMessages() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        var rows: [MessageRecord] = []
        for n in 0..<12 {
            rows.append(MessageRecord(workspaceId: w, id: id(200 + n), channelId: Fixtures.channel1, threadId: nil, threadSourceId: nil,
                                      body: "@[Person \(n)](mention:person:npub1p\(n))", senderNpub: TestKeys.npub,
                                      createdAt: String(format: "2026-10-%02dT00:00:00.000Z", 10 + n)))
        }
        try await store.writer.upsertMessages(rows)
        let recent = try await store.reader.recentMentions(workspaceId: w, senderNpub: TestKeys.npub, limit: 8)
        XCTAssertEqual(recent.map(\.label), (0..<8).map { "Person \(11 - $0)" })
    }

    func testPickedMentionClosesTheListAndTypingOnNeverReopensIt() {
        let ann = Mention(type: .person, npub: "npub1ann", label: "Ann Lee")
        XCTAssertEqual(MentionCodec.activeQuery(in: "@Ricky", excluding: [rick]), "Ricky")
        XCTAssertEqual(MentionCodec.activeQuery(in: "@Rick and @Ricky", excluding: [rick]), "Ricky")
        XCTAssertEqual(MentionCodec.activeQuery(in: "@Rick @", excluding: [rick]), "")
        XCTAssertEqual(MentionCodec.activeQuery(in: "@Rick @Rick Smith", excluding: [rick]), "Rick Smith")
        XCTAssertEqual(MentionCodec.activeQuery(in: "@Rick @Rick-Jones", excluding: [rick]), "Rick-Jones")
        XCTAssertNil(MentionCodec.activeQuery(in: "@Rick, please", excluding: [rick]))
        XCTAssertEqual(MentionCodec.activeQuery(in: "hi @An", excluding: [ann]), "An", "an unfinished @ is still a query")
        let picked = MentionCodec.complete("hi @An", with: ann)
        XCTAssertEqual(picked, "hi @Ann Lee ")
        XCTAssertNotNil(MentionCodec.activeQuery(in: picked), "the plain query would stay open on the picked name")
        XCTAssertNil(MentionCodec.activeQuery(in: picked, excluding: [ann]), "choosing the name closes the list")
        XCTAssertNil(MentionCodec.activeQuery(in: picked + "and", excluding: [ann]), "typing the next word does not reopen it")
        XCTAssertNil(MentionCodec.activeQuery(in: picked + "and then", excluding: [ann]))
        XCTAssertEqual(MentionCodec.activeQuery(in: picked + "and @Ri", excluding: [ann]), "Ri", "a new @ after it is a query again")
        // The visible name and the structured entry still come from the one picked value.
        let (body, routed) = MentionCodec.encode(text: picked + "and then", selected: [ann])
        XCTAssertEqual(body, "hi \(ann.token) and then")
        XCTAssertEqual(routed, [ann])
    }

    /// The lookahead runs on every keystroke: with a large workspace stored locally it stays well inside a frame budget.
    func testLookupStaysFastOnALargeWorkspace() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        try await store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA,
                                              [try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "general")))], complete: false)
        let words = ["alpha", "release", "plan", "budget", "native", "canvas", "design", "review", "launch", "notes"]
        var docs: [DocRecord] = [], tasks: [TaskRecord] = []
        for n in 0..<8_000 {
            docs.append(try doc(10_000 + n, "\(words[n % 10]) \(words[(n / 10) % 10]) document \(n)", updated: "2026-10-\(10 + n % 18)T00:00:00.000Z"))
            tasks.append(try task(20_000 + n, "\(words[(n / 3) % 10]) \(words[n % 7]) task \(n)", updated: "2026-10-\(10 + n % 18)T00:00:00.000Z"))
        }
        try await store.writer.upsertDocs(workspaceId: w, docs)
        try await store.writer.upsertTasks(workspaceId: w, tasks)
        _ = try await store.reader.mentionSuggestions(workspaceId: w, query: MentionQuery("warm"))
        var worst = 0.0
        for typed in ["p", "pl", "pla", "plan", "plan d", "zzz", "", "plän", "doc:re"] {
            let start = Date()
            let rows = try await store.reader.mentionSuggestions(workspaceId: w, query: MentionQuery(typed))
            worst = max(worst, Date().timeIntervalSince(start))
            print("mention lookup \"\(typed)\": \(String(format: "%.1f", Date().timeIntervalSince(start) * 1000)) ms, \(rows.count) rows")
            if typed == "plan" { XCTAssertEqual(rows.filter { $0.mention.type == .doc }.count, 10) }
        }
        print("mention lookup worst case over 16,000 records: \(String(format: "%.1f", worst * 1000)) ms")
        let plan = try await store.reader.explainMentionLookup(workspaceId: w)
        print("mention lookup query plan (documents):\n" + plan.joined(separator: "\n"))
        XCTAssertTrue(plan.contains { $0.contains("channels") }, "the channel check uses the channels primary key")
        XCTAssertLessThan(worst, 0.1)
    }
}
