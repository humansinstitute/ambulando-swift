import Foundation
import Testing
@testable import AmbulandoCore

/// Task tree projection (sol `projectTree`): children below, successors to the right, collapse and bounds.
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
        #expect(p[tasks[1].id]!.x == 0 && p[tasks[1].id]!.y == 1, "child below its parent")
        #expect(p[tasks[2].id]!.x == p[tasks[1].id]!.x + 1, "a child successor goes right of its predecessor")
        #expect(p[tasks[3].id]!.x == 1 && p[tasks[3].id]!.y == 0, "successor to the right of the root")
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
