import XCTest
import Foundation
import Testing
@testable import AmbulandoCore

/// Native task hierarchy: siblings, nested indentation, dependency separation, collapse and bounds.
@Suite struct TaskTreeTests {
    static let w = "a1b2c3d4-0000-4000-8000-0000000000aa", c = "a1b2c3d4-0000-4000-8000-0000000000cc"

    static func task(_ n: Int, parent: Int? = nil, after: Int? = nil) -> TaskTreeNode {
        func id(_ i: Int) -> String { String(format: "a1b2c3d4-0000-4000-8000-%012d", i) }
        var metadata: [String: Any] = [:]
        if let parent { metadata["parent_task_id"] = id(parent) }
        if let after { metadata["predecessor_task_ids"] = [id(after)] }
        let raw = try! JSONSerialization.data(withJSONObject: ["id": id(n), "workspace_id": w, "channel_id": c, "title": "T\(n)", "state": "new",
                                                               "created_at": String(format: "2026-10-25T10:00:%02d.000Z", n), "metadata": metadata])
        return TaskTreeNode(try! TaskRecord(raw: raw))
    }

    @Test func childrenGoBelowAndSuccessorsToTheRight() {
        let tasks = [Self.task(1), Self.task(2, parent: 1), Self.task(3, parent: 1, after: 2), Self.task(4, after: 1)]
        let graph = TaskTreeGraph.project(tasks, root: tasks[0].id)
        #expect(graph.nodes.count == 4)
        let p = graph.positions
        #expect(p[tasks[0].id]! == (0, 0))
        #expect(p[tasks[1].id]!.x == 1 && p[tasks[1].id]!.y == 1, "child below its parent")
        #expect(p[tasks[2].id]!.x == p[tasks[1].id]!.x, "dependencies do not override sibling indentation")
        #expect(p[tasks[3].id]!.x == 1 && p[tasks[3].id]!.y > p[tasks[2].id]!.y, "successor to the right of the root")
        #expect(graph.edges.contains(.init(from: tasks[0].id, to: tasks[1].id, child: true)))
        #expect(graph.edges.contains(.init(from: tasks[1].id, to: tasks[2].id, child: false)))
    }

    @Test func collapsedBranchesAndBoundsLimitTheTree() {
        let tasks = [Self.task(1), Self.task(2, parent: 1), Self.task(3, parent: 2)]
        #expect(TaskTreeGraph.project(tasks, root: tasks[0].id, collapsed: [tasks[1].id]).nodes.map(\.title) == ["T1", "T2"])
        let bounded = TaskTreeGraph.project(tasks, root: tasks[0].id, limit: 2)
        #expect(bounded.nodes.count == 2 && bounded.bounded)
    }
}


extension TaskTreeTests {
    @Test func nestedSubtreeReservesRowsBeforeTheNextSibling() {
        let tasks = [Self.task(1), Self.task(2, parent: 1), Self.task(3, parent: 2), Self.task(4, parent: 3), Self.task(5, parent: 1, after: 4)]
        let p = TaskTreeGraph.project(tasks, root: tasks[0].id).positions
        #expect(p[tasks[1].id]!.x == p[tasks[4].id]!.x)
        #expect(p[tasks[2].id]!.x == p[tasks[1].id]!.x + 1)
        #expect(p[tasks[4].id]!.y > p[tasks[3].id]!.y)
        let collapsed = TaskTreeGraph.project(tasks, root: tasks[0].id, collapsed: [tasks[1].id])
        #expect(collapsed.positions[tasks[4].id]!.y == 2)
        #expect(collapsed.nodes.count == 3)
    }

    @Test func largeHierarchyIsDeterministicBoundedAndHasNoOverlaps() {
        let tasks = [Self.task(1)] + (2...350).map { Self.task($0, parent: $0 < 20 ? 1 : 2) }
        let g = TaskTreeGraph.project(tasks, root: tasks[0].id, limit: 300)
        #expect(g.nodes.count == 300 && g.bounded)
        #expect(Set(g.positions.values.map { "\($0.x):\($0.y)" }).count == 300)
        #expect(g == TaskTreeGraph.project(tasks.reversed(), root: tasks[0].id, limit: 300))
    }
}

extension TaskTreeTests {
    @Test func sixSiblingsShareIndentationAndHaveNoFalseChildEdges() {
        let tasks = [Self.task(1)] + (2...7).map { Self.task($0, parent: 1) }
        let g = TaskTreeGraph.project(tasks, root: tasks[0].id)
        #expect(g.edges.count == 6)
        #expect(g.edges.allSatisfy { $0.child && $0.from == tasks[0].id })
        #expect(tasks.dropFirst().allSatisfy { g.positions[$0.id]!.x == 1 })
        #expect(tasks.dropFirst().map { g.positions[$0.id]!.y } == Array(1...6))
    }
}

/// Real relationship decoding and local-store observation, with controlled paginated Tower responses.
final class TaskRelationshipLoadingTests: XCTestCase {
    private func row(_ n: Int, parent: Int? = nil, predecessor: Int? = nil) -> [String: any Sendable] {
        func id(_ n: Int) -> String { String(format: "a1b2c3d4-0000-4000-8000-%012d", n) }
        var metadata: [String: any Sendable] = [:]
        if let parent { metadata["parent_task_id"] = id(parent) }
        if let predecessor { metadata["predecessor_task_ids"] = [id(predecessor)] }
        return ["id": id(n), "workspace_id": Fixtures.workspaceId, "channel_id": Fixtures.channel1,
                "title": "Task \(n)", "state": n == 3 ? "archive" : "new", "metadata": metadata,
                "created_at": "2026-01-01T00:00:00.000Z", "updated_at": "2026-01-01T00:00:00.000Z"]
    }

    func testPagedRelationshipsCacheDirectChildrenAndParentWithoutCountingSuccessors() async throws {
        let h = try await WorkHarness.make()
        let root = row(1), child = row(2, parent: 1), archived = row(3, parent: 1), successor = row(4, predecessor: 1)
        let transport = StubTransport { request in
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
            return (200, ["workspace_id": Fixtures.workspaceId, "task": root,
                          "tasks": cursor == nil ? [child, successor] : [archived],
                          "has_more": cursor == nil, "next_cursor": cursor == nil ? "second" : NSNull(), "unavailable": false])
        }
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
        let id = root["id"] as! String
        try await TaskTreeService(sync: sync).loadRelationships(h.connection, h.workspace, taskId: id)
        let children = try await h.store.reader.directSubtasks(workspaceId: Fixtures.workspaceId, taskId: id)
        XCTAssertEqual(children.map(\.title), ["Task 2", "Task 3"])
        let cache = try await h.store.reader.taskRelationshipCache(workspaceId: Fixtures.workspaceId, taskId: id)
        XCTAssertEqual(cache?.complete, true)
        XCTAssertEqual(cache?.ids.count, 3)
        XCTAssertEqual(transport.recorded.count, 2)
        // A later complete response removes a relationship from this view, without deleting or reparenting the task.
        let empty = StubTransport { _ in (200, ["workspace_id": Fixtures.workspaceId, "task": root, "tasks": [], "has_more": false, "unavailable": false]) }
        let fresh = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: empty)
        try await TaskTreeService(sync: fresh).loadRelationships(h.connection, h.workspace, taskId: id)
        let after = try await h.store.reader.directSubtasks(workspaceId: Fixtures.workspaceId, taskId: id)
        XCTAssertTrue(after.isEmpty)
        let retained = try await h.store.reader.task(workspaceId: Fixtures.workspaceId, id: child["id"] as! String)
        XCTAssertNotNil(retained, "never mutate stored relationships to fix the display")
    }

    func testFailedSecondPageRetainsPartialCacheAndRestrictedResponseIsHonest() async throws {
        let h = try await WorkHarness.make()
        let root = row(1), child = row(2, parent: 1), id = row(1)["id"] as! String
        let transport = StubTransport { request in
            if request.url!.query?.contains("cursor=") == true { return (503, ["code": "offline"]) }
            return (200, ["workspace_id": Fixtures.workspaceId, "task": root, "tasks": [child],
                          "has_more": true, "next_cursor": "second", "unavailable": false])
        }
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
        do { try await TaskTreeService(sync: sync).loadRelationships(h.connection, h.workspace, taskId: id); XCTFail() } catch {}
        let cache = try await h.store.reader.taskRelationshipCache(workspaceId: Fixtures.workspaceId, taskId: id)
        let children = try await h.store.reader.directSubtasks(workspaceId: Fixtures.workspaceId, taskId: id)
        XCTAssertEqual(cache?.complete, false)
        XCTAssertEqual(children.count, 1)
        let restricted = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity,
                                       transport: StubTransport { _ in (403, ["code": "forbidden"]) })
        do { try await TaskTreeService(sync: restricted).loadRelationships(h.connection, h.workspace, taskId: id); XCTFail() }
        catch { XCTAssertEqual(error as? TaskTreeError, .unavailable) }
        let denied = try await h.store.reader.taskRelationshipCache(workspaceId: Fixtures.workspaceId, taskId: id)
        XCTAssertEqual(denied?.unavailable, true)
        XCTAssertEqual(denied?.complete, false)
    }
}

extension TaskTreeTests {
    @Test func dependencyDiscoveryCannotPlaceChildBeforeItsVisibleParent() {
        let tasks = [Self.task(1), Self.task(2, parent: 3, after: 1), Self.task(3, after: 1)]
        let g = TaskTreeGraph.project(tasks, root: tasks[0].id)
        #expect(g.positions[tasks[1].id]!.x == g.positions[tasks[2].id]!.x + 1)
        #expect(g.positions[tasks[1].id]!.y > g.positions[tasks[2].id]!.y)
    }


}

extension TaskRelationshipLoadingTests {
    func testQueuedSubtaskWriteKeepsParentMetadataAndCanRefreshDetails() async throws {
        let h = try await WorkHarness.make()
        let root = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Parent")
        try await h.store.writer.upsertTasks(workspaceId: h.workspace.id, [TaskRecord(raw: Fixtures.json(h.work.task(root)!))])
        let service = TaskTreeService(sync: h.sync)
        try await service.loadRelationships(h.connection, h.workspace, taskId: root)
        let intent = WriteIntent(kind: .taskCreate, targetId: nil, payload: ["channel_id": Fixtures.channel1,
                                 "title": "Child", "metadata": ["parent_task_id": root]])
        _ = try await h.writes.submit(intent, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        // The fixture server clock predates the device clock. Acknowledgement must update the open detail
        // before any relationship re-fetch, without relying on timestamp ordering.
        let children = try await h.store.reader.directSubtasks(workspaceId: h.workspace.id, taskId: root)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.title, "Child")
        XCTAssertEqual(children.first?.channelId, Fixtures.channel1)
        XCTAssertEqual(children.first.map { TaskTreeNode($0).parentId }, root)
        let child = try XCTUnwrap(children.first)
        try await service.loadRelationships(h.connection, h.workspace, taskId: child.id)
        let parent = try await h.store.reader.task(workspaceId: h.workspace.id, id: root)
        XCTAssertEqual(parent?.title, "Parent")
    }
}


extension TaskTreeTests {
    @Test func upstreamParentAppearsAboveItsSelectedRoot() {
        let tasks = [Self.task(1), Self.task(2, parent: 1)]
        let g = TaskTreeGraph.project(tasks, root: tasks[1].id, upstream: [tasks[0].id])
        #expect(g.positions[tasks[1].id]!.x == g.positions[tasks[0].id]!.x + 1)
        #expect(g.positions[tasks[1].id]!.y > g.positions[tasks[0].id]!.y)
    }
}


extension TaskRelationshipLoadingTests {
    func testLiveTaskUpsertUpdatesCachedMembershipRegardlessOfServerClock() async throws {
        let h = try await WorkHarness.make()
        let root = row(1), child = row(2, parent: 1), id = row(1)["id"] as! String
        let transport = StubTransport { _ in (200, ["workspace_id": Fixtures.workspaceId, "task": root, "tasks": [], "has_more": false, "unavailable": false]) }
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
        try await TaskTreeService(sync: sync).loadRelationships(h.connection, h.workspace, taskId: id)
        try await h.store.writer.upsertTasks(workspaceId: h.workspace.id, [TaskRecord(raw: Fixtures.json(child))])
        let children = try await h.store.reader.directSubtasks(workspaceId: h.workspace.id, taskId: id)
        XCTAssertEqual(children.map(\.title), ["Task 2"])
        let cache = try await h.store.reader.taskRelationshipCache(workspaceId: h.workspace.id, taskId: id)
        XCTAssertTrue(cache?.ids.contains(child["id"] as! String) == true)
    }
}
