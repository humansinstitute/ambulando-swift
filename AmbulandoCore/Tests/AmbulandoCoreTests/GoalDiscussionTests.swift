import Foundation
import XCTest
@testable import AmbulandoCore

@MainActor final class GoalDiscussionTests: XCTestCase {
    let goal = "11111111-1111-4111-8111-111111111111"
    let other = "22222222-2222-4222-8222-222222222222"
    let request = "33333333-3333-4333-8333-333333333333"
    let scope = "44444444-4444-4444-8444-444444444444"
    let thread = "55555555-5555-4555-8555-555555555555"

    func testAdditiveGoalRoundtripAndIndependentDefaultAndPinEdits() throws {
        var initial = try Goal.create(name: "Purpose", description: "Make progress")
        initial.extra = .object([("future", .string("preserved"))])
        let pin = GoalLink(type: .doc, recordId: goal, extra: .object([("future_ref", .bool(true))]))
        let changed = try GoalEdit.applyAll([.setDefaultChannel(expected: nil, value: Fixtures.channel1), .pin(pin), .link(GoalLink(type: .file, recordId: other))], to: initial)
        XCTAssertEqual(changed, try Goal.parse(changed.encode()))
        XCTAssertEqual(changed.extra, initial.extra)
        XCTAssertEqual([pin], changed.pinnedRefs)
        let unpinned = try GoalEdit.unpin(.doc, recordId: goal).apply(to: changed)
        XCTAssertEqual(changed.links, unpinned.links)
        XCTAssertEqual(Fixtures.channel1, unpinned.defaultChannelId)
        XCTAssertThrowsError(try GoalEdit.setDefaultChannel(expected: nil, value: Fixtures.channel2).apply(to: changed))
        XCTAssertEqual(changed, try GoalEdit.pin(pin).apply(to: changed))
        XCTAssertThrowsError(try GoalEdit.pin(GoalLink(type: .task, recordId: request)).apply(to: initial))
        let malformed = initial.toJSON().setting("default_channel_id", .int(7))
        XCTAssertThrowsError(try Goal.parse(malformed.serialized()))
        XCTAssertThrowsError(try Goal.parse(initial.toJSON().setting("pinned_refs", .array([pin.toJSON(), pin.toJSON()])).serialized()))
    }

    func testMetadataDoesNotReassignAndPreservesUnknownFieldsButNewOutputIsCanonical() throws {
        let reference = JSONValue.object([("version", .int(1)), ("goal_file_id", .string(goal)), ("future", .string("keep"))])
        let original = JSONValue.object([("another_app", .bool(false)), (GoalAssociation.key, reference)])
        XCTAssertEqual(original, try GoalAssociation.metadata(goalFileId: goal, base: original))
        XCTAssertThrowsError(try GoalAssociation.metadata(goalFileId: other, base: original))
        for malformed in [JSONValue.null, .string(goal), .object([("version", .int(2)), ("goal_file_id", .string(goal))]), .object([("version", .string("1")), ("goal_file_id", .string(goal))])] {
            XCTAssertThrowsError(try GoalAssociation.read(.object([(GoalAssociation.key, malformed)])))
        }
        XCTAssertNil(try GoalAssociation.read(.object([])))
    }

    func testReceiptReopensAndOnlyExplicitClearRetiresIt() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try GoalDiscussionReceipt.key(connectionId: request, workspaceId: Fixtures.workspaceId, goalFileId: goal)
        let receipt = try GoalDiscussionReceipt(workspaceId: Fixtures.workspaceId, goalFileId: goal, channelId: Fixtures.channel1, requestId: request)
        let first = try LocalStore(directory: dir)
        try await first.writer.setState(key, receipt.encode())
        let reopened = try LocalStore(directory: dir)
        let saved = try await reopened.reader.state(key)!
        XCTAssertEqual(receipt, try GoalDiscussionReceipt.parse(saved, workspaceId: Fixtures.workspaceId, goalFileId: goal))
        XCTAssertThrowsError(try GoalDiscussionReceipt.parse(saved, workspaceId: Fixtures.workspaceId2, goalFileId: goal))
        XCTAssertThrowsError(try GoalDiscussionReceipt.parse(saved, workspaceId: Fixtures.workspaceId, goalFileId: other))
        XCTAssertThrowsError(try GoalDiscussionReceipt.parse(saved.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"), workspaceId: Fixtures.workspaceId, goalFileId: goal))
        let stillPending = try await first.reader.state(key)
        XCTAssertEqual(saved, stillPending)
        try await reopened.writer.setState(key, nil)
        let cleared = try await LocalStore(directory: dir).reader.state(key)
        XCTAssertNil(cleared)
    }

    func testAssociatedOutputsReopenDeduplicateAndRespectWorkspaceAndSoftDeletion() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(directory: dir)
        for workspace in [Fixtures.workspaceId, Fixtures.workspaceId2] {
            _ = try await store.writer.upsertScopes(workspaceId: workspace, [try ScopeRecord(raw: Fixtures.json(Fixtures.scope(scope, workspace: workspace, name: "Scope")))], complete: false)
            _ = try await store.writer.upsertChannels(workspaceId: workspace, scopeId: scope, [try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: scope, workspace: workspace, name: "Channel")))], complete: false)
            let metadata = try GoalAssociation.metadata(goalFileId: goal)
            let row = JSONValue.object([("id", .string(other)), ("workspace_id", .string(workspace)), ("scope_id", .string(scope)), ("channel_id", .string(Fixtures.channel1)),
                ("title", .string(workspace == Fixtures.workspaceId ? "Original vision" : "Other workspace")), ("metadata", metadata), ("row_version", .int(1)), ("updated_at", .string("2026-11-27"))])
            _ = try await store.writer.upsertDocs(workspaceId: workspace, [try DocRecord(raw: row.serialized())])
        }
        let reopened = try LocalStore(directory: dir)
        let explicit = [GoalLink(type: .doc, recordId: other)]
        let rows = try await reopened.reader.associatedGoalLinks(workspaceId: Fixtures.workspaceId, goalId: goal, explicit: explicit)
        XCTAssertEqual(1, rows.count); XCTAssertEqual("Original vision", rows.first?.title)
        let original = try await reopened.reader.doc(workspaceId: Fixtures.workspaceId, id: other)!
        let deleted = try JSONValue.parse(original.raw).setting("deleted_at", .string("2026-11-27")).setting("row_version", .int(2))
        _ = try await reopened.writer.upsertDocs(workspaceId: Fixtures.workspaceId, [try DocRecord(raw: deleted.serialized())])
        let automatic = try await reopened.reader.associatedGoalLinks(workspaceId: Fixtures.workspaceId, goalId: goal, explicit: [])
        XCTAssertTrue(automatic.isEmpty)
        let unavailable = try await reopened.reader.associatedGoalLinks(workspaceId: Fixtures.workspaceId, goalId: goal, explicit: explicit)
        XCTAssertEqual(false, unavailable.first?.available); XCTAssertNil(unavailable.first?.title)
    }

    func testDiscussionCreationRoutingAndCanonicalInheritanceUseExistingRoutes() async throws {
        let w = GoalWireTests.workspace, c = GoalWireTests.channel, g = GoalWireTests.file
        let scope = scope, request = request, thread = thread
        var value = try Goal.create(name: "Purposeful work", description: "Do not copy this private description")
        value.defaultChannelId = c
        let tower = GoalWireTests.Tower(value)
        let metadata = try GoalAssociation.metadata(goalFileId: g).setting("ambulando_discussion_request_id", .string(request))
        let threadRow = JSONValue.object([("id", .string(thread)), ("workspace_id", .string(w)), ("channel_id", .string(c)), ("metadata", metadata), ("row_version", .int(1))])
        let transport = StubTransport { sent in
            let path = sent.url!.path
            if path.hasSuffix("/scopes") { return (200, ["scopes": [Fixtures.scope(scope, workspace: w, name: "Scope")]]) }
            if path.hasSuffix("/channels") { return (200, ["channels": [Fixtures.channel(c, scope: scope, workspace: w, name: "Discussion")]]) }
            if path.hasSuffix("/threads"), sent.httpMethod == "POST" { return (201, JSONValue.object([("thread", threadRow)]).serialized()) }
            if path.hasSuffix("/threads/" + thread) { return (200, JSONValue.object([("thread", threadRow)]).serialized()) }
            if path.hasSuffix("/threads") { return (200, JSONValue.object([("threads", .array([threadRow])), ("next_cursor", .null)]).serialized()) }
            return try tower.handle(sent)
        }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: try await makeIdentity()))
        let dir = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalStore(directory: dir)
        let key = try GoalDiscussionReceipt.key(connectionId: request, workspaceId: w, goalFileId: g)
        let receipt = try GoalDiscussionReceipt(workspaceId: w, goalFileId: g, channelId: c, requestId: request)
        let created = try await api.createGoalDiscussion(workspaceId: w, appNpub: GoalWireTests.app, goalFileId: g, channelId: c, scopeId: scope, expectedDefault: c, requestId: request) {
            try await local.writer.setState(key, receipt.encode())
        }
        XCTAssertEqual(thread, created.id)
        let posted = try JSONValue.parse(transport.recorded.first { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/threads") }!.httpBody!)
        XCTAssertEqual(g, try GoalAssociation.read(posted["metadata"]!)); XCTAssertNil(posted["body"])
        let inherited = try await api.threadGoalMetadata(workspaceId: w, appNpub: GoalWireTests.app, threadId: thread, expectedChannelId: c)
        XCTAssertEqual(try GoalAssociation.metadata(goalFileId: g), inherited)
        let found = try await api.findGoalDiscussion(workspaceId: w, appNpub: GoalWireTests.app, channelId: c, goalFileId: g, requestId: request)
        XCTAssertEqual(thread, found?.id)
        do { _ = try await api.createGoalDiscussion(workspaceId: w, appNpub: GoalWireTests.app, goalFileId: g, channelId: c, scopeId: scope, expectedDefault: nil, requestId: request); XCTFail("stale default should refuse") } catch is GoalError {}
        XCTAssertEqual(1, transport.recorded.filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/threads") }.count)
    }

    func testRecoveryRefusesIncompleteDuplicateAndCrossWorkspaceResults() async throws {
        let w = Fixtures.workspaceId, c = Fixtures.channel1, id = thread, request = request
        let metadata = try GoalAssociation.metadata(goalFileId: goal).setting("ambulando_discussion_request_id", .string(request))
        let row = JSONValue.object([("id", .string(id)), ("workspace_id", .string(w)), ("channel_id", .string(c)), ("metadata", metadata)])
        let bodies: [JSONValue] = [
            .object([("threads", .array([row])), ("next_cursor", .string("more"))]),
            .object([("threads", .array(Array(repeating: row, count: 200)))]),
            .object([("threads", .array([row, row]))]),
            .object([("threads", .array([row.setting("workspace_id", .string(Fixtures.workspaceId2))]))]),
        ]
        let identity = try await makeIdentity()
        for body in bodies {
            let transport = StubTransport { _ in (200, body.serialized()) }
            let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
            do { _ = try await api.findGoalDiscussion(workspaceId: w, appNpub: Fixtures.appNpub, channelId: c, goalFileId: goal, requestId: request); XCTFail("uncertain recovery must be disclosed") } catch {}
            XCTAssertTrue(transport.recorded.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    func testPrivateGoalRetainsOnlyCanonicalReferenceAndMissingOrWrongChannelRefuse() async throws {
        let w = Fixtures.workspaceId, c = Fixtures.channel1, id = thread, g = goal
        let reference = JSONValue.object([("version", .int(1)), ("goal_file_id", .string(g)), ("snapshot", .string("must not copy"))])
        let row = JSONValue.object([("id", .string(id)), ("workspace_id", .string(w)), ("channel_id", .string(c)), ("metadata", .object([(GoalAssociation.key, reference)]))])
        let identity = try await makeIdentity()
        for status in [403, 404] {
            let transport = StubTransport { request in
                if request.url!.path.hasSuffix("/threads/" + id) { return (200, JSONValue.object([("thread", row)]).serialized()) }
                return (status, ["code": "source_unavailable"])
            }
            let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
            if status == 403 {
                let metadata = try await api.threadGoalMetadata(workspaceId: w, appNpub: Fixtures.appNpub, threadId: id, expectedChannelId: c)
                XCTAssertEqual(try GoalAssociation.metadata(goalFileId: g), metadata)
                XCTAssertNil(metadata[GoalAssociation.key]?["snapshot"])
            } else {
                do { _ = try await api.threadGoalMetadata(workspaceId: w, appNpub: Fixtures.appNpub, threadId: id); XCTFail("missing goal must refuse") } catch {}
            }
            do { _ = try await api.threadGoalMetadata(workspaceId: w, appNpub: Fixtures.appNpub, threadId: id, expectedChannelId: Fixtures.channel2); XCTFail("channel mismatch must refuse") } catch {}
        }
    }
}
