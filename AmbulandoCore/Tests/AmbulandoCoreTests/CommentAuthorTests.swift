import XCTest
@testable import AmbulandoCore

final class CommentAuthorTests: XCTestCase {
    func testActorOnlyCreateReplyAndCachedRecordResolveWithoutGuessing() async throws {
        let h = try await WorkHarness.make()
        let actor = UUID().uuidString.lowercased()
        let member = MemberRecord(workspaceId: h.workspace.id, actorId: actor, npub: TestKeys.npub, kind: "human", displayName: "Actual author")
        let profile = ProfileRecord(pubkey: TestKeys.pubkeyHex, npub: TestKeys.npub, displayName: "Profile author",
                                    picture: "https://images.example/avatar.png", status: .found, checkedAt: Date())
        let people = PeopleDirectory(members: [member], agents: [:], profiles: [profile])
        let parent = UUID().uuidString.lowercased()
        for reply in [false, true] {
            let id = UUID().uuidString.lowercased()
            var raw: [String: Any] = ["id": id, "workspace_id": h.workspace.id, "doc_id": parent, "body": "Comment",
                                     "created_by_actor_id": actor.uppercased(), "updated_by_actor_id": UUID().uuidString,
                                     "row_version": 1, "created_at": "2026-10-29T00:00:00Z"]
            if reply { raw["parent_comment_id"] = parent }
            let row = try CommentRecord(raw: Fixtures.json(raw), parent: .doc)
            XCTAssertNil(row.senderNpub)
            XCTAssertEqual(row.author(in: people).npub, TestKeys.npub)
            XCTAssertEqual(row.author(in: people).name, "Profile author")
            XCTAssertEqual(row.author(in: people).avatarURL?.absoluteString, "https://images.example/avatar.png")
            XCTAssertEqual(row.author(in: PeopleDirectory()).name, "Unknown")
            try await h.store.writer.upsertComments(workspaceId: h.workspace.id, [row])
            var cached = try await h.store.reader.comments(workspaceId: h.workspace.id, parent: .doc, parentId: parent)
            XCTAssertEqual(cached.first { $0.id == id }?.author(in: people), row.author(in: people))
            raw["created_by_actor_npub"] = TestKeys.npub
            // Same-version list enrichment must correct an earlier actor-only acknowledgement.
            try await h.store.writer.upsertComments(workspaceId: h.workspace.id, [CommentRecord(raw: Fixtures.json(raw), parent: .doc)])
            cached = try await h.store.reader.comments(workspaceId: h.workspace.id, parent: .doc, parentId: parent)
            XCTAssertEqual(cached.first { $0.id == id }?.senderNpub, TestKeys.npub)
            raw.removeValue(forKey: "created_by_actor_npub")
            raw["row_version"] = 2
            try await h.store.writer.upsertComments(workspaceId: h.workspace.id, [CommentRecord(raw: Fixtures.json(raw), parent: .doc)])
            cached = try await h.store.reader.comments(workspaceId: h.workspace.id, parent: .doc, parentId: parent)
            XCTAssertEqual(cached.first { $0.id == id }?.senderNpub, TestKeys.npub, "later actor-only response keeps known creator")
            XCTAssertEqual(cached.first { $0.id == id }?.author(in: people).name, "Profile author")
        }
    }

    func testDirectIdentityLabelFallbackAndUpdaterNeverBecomeCreator() throws {
        let actor = UUID().uuidString.lowercased()
        let member = MemberRecord(workspaceId: Fixtures.workspaceId, actorId: actor, npub: TestKeys.npub, kind: "human", displayName: "Member")
        let people = PeopleDirectory(members: [member], agents: [:], profiles: [])
        var raw: [String: Any] = ["id": UUID().uuidString, "workspace_id": Fixtures.workspaceId, "doc_id": UUID().uuidString,
                                 "updated_by_actor_id": actor, "created_by_actor_label": "Historical author", "sender_npub": ""]
        var row = try CommentRecord(raw: Fixtures.json(raw), parent: .doc)
        XCTAssertEqual(row.author(in: people).name, "Historical author")
        XCTAssertEqual(row.author(in: people).npub, "")
        XCTAssertNil(row.author(in: people).avatarURL)
        raw["created_by_actor_npub"] = TestKeys.npub
        row = try CommentRecord(raw: Fixtures.json(raw), parent: .doc)
        XCTAssertEqual(row.author(in: people).name, "Member")
        XCTAssertEqual(row.author(in: people).npub, TestKeys.npub)
        XCTAssertNil(row.author(in: people).avatarURL)
    }
}
