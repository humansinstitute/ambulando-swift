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
        XCTAssertEqual(MentionQuery("").limit, 8)
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
