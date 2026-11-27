import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct GoalMentionTests {
    static let workspace = GoalWireTests.workspace, channel = GoalWireTests.channel
    static let scope = "eeeeeeee-0000-4000-8000-000000000001"

    @Test func queryCompletionAndWireIdentity() throws {
        let title = "Training sign up onboarding to Ambulando"
        let typed = "Please see @tRaInInG sign up onboarding to Ambulando"
        #expect(MentionCodec.activeQuery(in: typed) == "tRaInInG sign up onboarding to Ambulando")
        #expect(MentionQuery("GoAl: ").only == .file)
        let picked = Mention(type: .file, npub: GoalWireTests.file, label: title)
        let completed = MentionCodec.complete(typed, with: picked)
        #expect(completed == "Please see @" + title + " ")
        #expect(MentionCodec.activeQuery(in: completed, excluding: [picked]) == nil)
        let wire = MentionCodec.encode(text: completed, selected: [picked])
        #expect(wire.body == "Please see " + picked.token + " ")
        #expect(wire.mentions.isEmpty)
        #expect(MentionCodec.segments(wire.body).contains(.reference(label: title, kind: "file", id: GoalWireTests.file)))
        #expect(MentionCodec.encode(text: "changed", selected: [picked]).body == "changed")
        #expect(MentionCodec.activeQuery(in: "@goal:\nsecret") == nil)
        let longTitle = String(repeating: "long goal ", count: 11).trimmingCharacters(in: .whitespaces)
        #expect(Mention(type: .file, npub: GoalWireTests.file, label: longTitle).label == longTitle)
        #expect(MentionCodec.activeQuery(in: "@" + String(repeating: "a", count: 161)) == nil)
    }

    @Test func allGoalRowsRemainBrowsableAndTitleMatchesIgnoreCase() throws {
        let goal = try Goal.create(name: "Training sign up onboarding to Ambulando", description: "d")
        let docs = try (0..<37).map { index in
            var row = GoalWireTests.Tower(goal).fileRow()
            row["id"] = String(format: "cccccccc-0000-4000-8000-%012d", index)
            return GoalDocument(file: try FileRecord(raw: rawJSON(row)), versionId: GoalWireTests.head, goal: goal)
        }
        let query = MentionQuery("goal:")
        let rows = GoalMentions.suggestions(docs, query: query)
        #expect(MentionRanking.merge(actors: [], records: rows, query: query).count == 37)
        let typed = MentionQuery("TRAINING SIGN UP")
        #expect(GoalMentions.suggestions(docs, query: typed).count == 37)
        #expect(MentionRanking.merge(actors: [], records: GoalMentions.suggestions(docs, query: typed), query: typed).first?.mention.label == goal.name)
        for change: [String: Any] in [["access_removed": true], ["record_state": "revoked"], ["record_state": "archived"], ["deleted_at": "2026-11-27"]] {
            var row = GoalWireTests.Tower(goal).fileRow()
            row.merge(change) { _, new in new }
            let removed = GoalDocument(file: try FileRecord(raw: rawJSON(row)), versionId: GoalWireTests.head, goal: goal)
            #expect(GoalMentions.suggestions([removed], query: MentionQuery("goal:")).isEmpty)
        }
        #expect(GoalMentions.suggestions(docs, query: MentionQuery("goal:no match")).isEmpty)
        #expect(GoalMentions.suggestions(docs, query: MentionQuery("task:")).isEmpty)
        #expect(GoalMentions.suggestions(docs, query: query).allSatisfy { $0.mention.type == .file })
    }

    /// Exercises the real home resolver, grant safety, File pagination and authenticated content reads.
    @Test func serviceReadsAllPagesAndRejectsOtherOwnersAndUnsafeGrants() async throws {
        let service = try await fixture()
        let rows = try await service.mentionSuggestions(query: MentionQuery("goal:"))
        #expect(rows.count == 23)
        #expect(rows.last?.mention.label == "Training sign up onboarding to Ambulando")
        #expect(rows.last?.mention.id == String(format: "cccccccc-0000-4000-8000-%012d", 22))
        #expect(try await fixture(otherOwner: true).mentionSuggestions(query: MentionQuery("goal:")).isEmpty)
        await #expect(throws: GoalError.self) {
            try await fixture(unsafe: true).mentionSuggestions(query: MentionQuery("goal:"))
        }
        await #expect(throws: TowerError.self) {
            try await fixture(failSecondPage: true).mentionSuggestions(query: MentionQuery("goal:"))
        }
        await #expect(throws: TowerError.listLimitReached("files")) {
            try await fixture(fullPageWithoutCursor: true).mentionSuggestions(query: MentionQuery("goal:"))
        }
        await #expect(throws: GoalError.self) {
            try await fixture(unreadable: true).mentionSuggestions(query: MentionQuery("goal:"))
        }
    }

    private func fixture(otherOwner: Bool = false, unsafe: Bool = false, failSecondPage: Bool = false, fullPageWithoutCursor: Bool = false, unreadable: Bool = false) async throws -> GoalsService {
        let identity = try await makeIdentity()
        let goal = try Goal.create(name: "Training sign up onboarding to Ambulando", description: "d")
        let bytes = unreadable ? Data("{}".utf8) : goal.encode()
        let base = "/api/v4/flightdeck-pg/workspaces/" + Self.workspace
        let transport = StubTransport { request in
            let path = request.url!.path
            if path == base + "/scopes" { return (200, ["scopes": [Fixtures.scope(Self.scope, workspace: Self.workspace, name: "Home")]]) }
            if path == base + "/scopes/" + Self.scope + "/channels" {
                var row = Fixtures.channel(Self.channel, scope: Self.scope, workspace: Self.workspace, name: "Goals")
                row["metadata"] = GoalsSpace.metadata(owner: otherOwner ? GoalsTests.owner : TestKeys.npub)
                return (200, ["channels": [row]])
            }
            if path == base + "/members" { return (200, ["members": [Fixtures.member(TestKeys.npub, name: "Owner")]]) }
            if path == base + "/channels/" + Self.channel + "/grants" {
                var grants: [[String: Any]] = [["principal": ["npub": TestKeys.npub], "access_level": "manage"]]
                if unsafe { grants.append(["principal_type": "group", "access_level": "read"]) }
                return (200, ["grants": grants])
            }
            if path == base + "/channels/" + Self.channel + "/files" {
                let second = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "cursor" && $0.value == "next" } == true
                if second && failSecondPage { return (503, ["code": "unavailable"]) }
                let rows = (fullPageWithoutCursor ? 0..<200 : second ? 12..<23 : 0..<12).map { index -> [String: Any] in
                    var row = GoalWireTests.Tower(goal).fileRow()
                    row["id"] = String(format: "cccccccc-0000-4000-8000-%012d", index)
                    row["current_version"] = ["id": GoalWireTests.head, "sha256_hex": SHA256Hex.of(bytes), "size_bytes": bytes.count]
                    return row
                }
                return (200, ["files": rows, "next_cursor": second || fullPageWithoutCursor ? NSNull() : "next" as Any])
            }
            if path.hasSuffix("/object") { return (200, bytes) }
            return (404, ["code": "unexpected_route"])
        }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
        return GoalsService(api: api, workspaceId: Self.workspace, appNpub: Fixtures.appNpub, viewer: TestKeys.npub, identity: identity)
    }
}
