import Foundation

// Task Tree naplets (sol `canvas/task-tree-page.js`, `task-tree-runtime.js`, `task-tree-graph.js`). A tree shows real
// channel tasks from a root task: children (`metadata.parent_task_id`) indented below/right, dependencies (`metadata.predecessor_task_ids`)
// drawn separately. Tasks are read through Tower's relationships route and stored like any other task, so a node opens the
// normal task screen. The naplet's saved layout keeps the view (`layout.task_tree`: root, collapsed branches, upstream
// context, viewport). Routes (existing):
//
// - `GET  /tasks/:t/relationships?cursor&limit` (the task and the tasks that name it as parent or predecessor)
// - `GET  /channels/:c/tasks` (choose an existing root)
// - `POST /channels/:c/tasks` with `client_request_id` and `metadata.parent_task_id` / `metadata.predecessor_task_ids`

/// One task as the tree draws it.
public struct TaskTreeNode: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let state: String
    public let channelId: String
    public let channelTitle: String?
    public let parentId: String?
    public let predecessors: [String]
    public let createdAt: String

    public init(_ task: TaskRecord, channelTitle: String? = nil) {
        let o = ((try? JSONSerialization.jsonObject(with: task.raw)) as? [String: Any]) ?? [:]
        let metadata = (o["metadata"] as? [String: Any]) ?? o
        id = task.id; title = task.title; state = task.state; channelId = task.channelId
        self.channelTitle = channelTitle ?? (o["channel_title"] as? String)
        parentId = lowerUUID(metadata["parent_task_id"] as? String)
        var seen = Set<String>()
        predecessors = ((metadata["predecessor_task_ids"] as? [Any]) ?? []).compactMap { lowerUUID($0 as? String) }.filter { seen.insert($0).inserted }
        createdAt = task.createdAt
    }
}

/// The view a tree naplet saves in its layout (`normalizeTaskTreeView`).
public struct TaskTreeView: Sendable, Equatable {
    public var instanceId: String
    public var rootTaskId: String?
    public var collapsed: [String] = []
    public var upstream: [String] = []
    public var scale: Double = 1

    public init(instanceId: String, rootTaskId: String? = nil) { self.instanceId = instanceId; self.rootTaskId = rootTaskId }

    /// From a naplet's saved layout; a naplet without one uses its own id as the instance.
    public init(savedLayout: Data, napletId: String) {
        let layout = ((try? JSONSerialization.jsonObject(with: savedLayout)) as? [String: Any]) ?? [:]
        let tree = (layout["task_tree"] as? [String: Any]) ?? [:]
        instanceId = (tree["instance_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? napletId
        rootTaskId = lowerUUID(tree["root_task_id"] as? String)
        collapsed = ((tree["collapsed"] as? [Any]) ?? []).compactMap { lowerUUID($0 as? String) }
        upstream = ((tree["upstream"] as? [Any]) ?? []).compactMap { lowerUUID($0 as? String) }
        if let viewport = tree["viewport"] as? [String: Any], let s = (viewport["scale"] as? NSNumber)?.doubleValue, s.isFinite { scale = min(2, max(0.25, s)) }
    }

    public var object: [String: Any] {
        ["instance_id": instanceId, "root_task_id": rootTaskId ?? NSNull(), "collapsed": collapsed, "upstream": upstream,
         "viewport": ["x": 0, "y": 0, "scale": scale]]
    }
}

/// A bounded native hierarchy projection from its root, with separate dependency edges.
public struct TaskTreeGraph: Sendable, Equatable {
    public struct Edge: Sendable, Equatable, Hashable { public let from: String; public let to: String; public let child: Bool }
    public struct Reference: Sendable, Equatable, Hashable { public let taskId: String; public let targetId: String; public let parent: Bool; public let available: Bool }
    public var nodes: [TaskTreeNode] = []
    public var edges: [Edge] = []
    public var references: [Reference] = []
    /// Grid cells: children indented right, siblings in one column, complete subtrees in disjoint rows.
    public var positions: [String: (x: Int, y: Int)] = [:]
    public var bounded = false
    public init() {}

    public static func == (a: TaskTreeGraph, b: TaskTreeGraph) -> Bool {
        a.nodes == b.nodes && a.edges == b.edges && a.references == b.references && a.bounded == b.bounded
            && a.positions.mapValues { [$0.x, $0.y] } == b.positions.mapValues { [$0.x, $0.y] }
    }

    public static func project(_ tasks: [TaskTreeNode], root: String, collapsed: [String] = [], upstream: [String] = [], limit: Int = 100) -> TaskTreeGraph {
        var byId: [String: TaskTreeNode] = [:]
        for task in tasks { byId[task.id] = task }
        var outgoing: [String: [Edge]] = [:]
        for task in byId.values.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            if let parent = task.parentId { outgoing[parent, default: []].append(Edge(from: parent, to: task.id, child: true)) }
            for p in task.predecessors { outgoing[p, default: []].append(Edge(from: p, to: task.id, child: false)) }
        }
        let closed = Set(collapsed)
        var visited = Set<String>(), queued = Set([root] + upstream), queue = [root] + upstream
        var nodes: [TaskTreeNode] = []
        let budget = max(1, min(2000, limit))
        var cursor = 0
        while cursor < queue.count && nodes.count < budget {
            let key = queue[cursor]; cursor += 1
            guard visited.insert(key).inserted, let task = byId[key] else { continue }
            nodes.append(task)
            if closed.contains(key) { continue }
            for link in outgoing[key] ?? [] where queued.insert(link.to).inserted { queue.append(link.to) }
        }
        let visible = Set(nodes.map(\.id))
        var graph = TaskTreeGraph()
        graph.nodes = nodes
        // Hierarchy owns placement. Reserve every descendant row before the next sibling;
        // dependency edges never turn siblings into an apparent chain.
        var placing = Set<String>()
        var nextRow = 0
        func place(_ id: String, depth: Int) {
            guard graph.positions[id] == nil, placing.insert(id).inserted else { return }
            graph.positions[id] = (depth, nextRow)
            nextRow += 1
            for edge in outgoing[id] ?? [] where edge.child && visible.contains(edge.to) {
                place(edge.to, depth: depth + 1)
            }
        }
        if visible.contains(root) {
            var top = root, ancestors = Set([root])
            while let parent = byId[top]?.parentId, visible.contains(parent), ancestors.insert(parent).inserted { top = parent }
            place(top, depth: 0)
        }
        // A dependency can discover a child before its parent. Place the highest unplaced
        // visible ancestor first; hierarchy still wins even in dependency-only components.
        for task in nodes where graph.positions[task.id] == nil {
            var top = task.id, ancestors = Set([task.id])
            while let parent = byId[top]?.parentId, visible.contains(parent), graph.positions[parent] == nil,
                  ancestors.insert(parent).inserted { top = parent }
            let parentDepth = byId[top]?.parentId.flatMap { graph.positions[$0]?.x }.map { $0 + 1 }
            let dependencyDepth = byId[top]?.predecessors.compactMap { graph.positions[$0]?.x }.max().map { $0 + 1 }
            place(top, depth: parentDepth ?? dependencyDepth ?? 0)
        }
        for task in nodes {
            for link in outgoing[task.id] ?? [] where visible.contains(link.to) { graph.edges.append(link) }
            if let parent = task.parentId, !visible.contains(parent) {
                graph.references.append(Reference(taskId: task.id, targetId: parent, parent: true, available: byId[parent] != nil))
            }
            for p in task.predecessors where !visible.contains(p) {
                graph.references.append(Reference(taskId: task.id, targetId: p, parent: false, available: byId[p] != nil))
            }
        }
        graph.bounded = cursor < queue.count
        return graph
    }
}

extension TowerAPI {
    /// One page of a task's relationships: the task, then tasks naming it as parent or predecessor that this viewer may
    /// read (`unavailable` when some were withheld).
    public func taskRelationships(workspaceId: String, appNpub: String, taskId: String, cursor: String?, limit: Int = 100)
        async throws -> (task: TaskRecord, tasks: [TaskRecord], channelTitles: [String: String], unavailable: Bool, next: String?) {
        var query = [URLQueryItem(name: "limit", value: String(min(100, max(1, limit))))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/tasks/" + Self.uuid(taskId) + "/relationships", query: query,
                                                    appNpub: appNpub), "task relationships")
        guard lowerUUID(o["workspace_id"] as? String) == workspaceId, let row = o["task"] as? [String: Any], let rows = o["tasks"] as? [[String: Any]] else {
            throw TowerError.malformed("task relationships")
        }
        let task = try TaskRecord(raw: rawJSON(row))
        guard task.id == taskId.lowercased(), task.workspaceId == workspaceId else { throw TowerError.malformed("task relationships") }
        let tasks = try rows.map { try TaskRecord(raw: rawJSON($0)) }
        guard tasks.allSatisfy({ $0.workspaceId == workspaceId }) else { throw TowerError.malformed("task relationships") }
        var titles: [String: String] = [:]
        for r in [row] + rows { if let c = lowerUUID(r["channel_id"] as? String), let t = r["channel_title"] as? String { titles[c] = t } }
        let next = (o["has_more"] as? Bool == true) ? (o["next_cursor"] as? String) : nil
        if o["has_more"] as? Bool == true, next == nil || next == cursor { throw TowerError.malformed("task relationships cursor") }
        return (task, tasks, titles, o["unavailable"] as? Bool == true, next)
    }
}

public enum TaskTreeError: LocalizedError, Equatable, Sendable {
    case unavailable, locked, failed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Task relationship unavailable. Access may have changed."
        case .locked: "Unlock to add tasks."
        case .failed(let detail): detail
        }
    }
}

/// Tower reads and writes for task tree naplets. Reads are stored like other task reads; creation is one confirmed
/// request with a stable `client_request_id`, so a retry after an uncertain answer finds the same task.
public struct TaskTreeService: Sendable {
    let sync: WorkspaceSync
    public init(sync: WorkspaceSync) { self.sync = sync }

    /// The authorized tasks reachable from `root` (and `upstream` context tasks), bounded like the web's tree.
    public func load(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, root: String, upstream: [String] = [], limit: Int = 100) async throws
        -> (tasks: [TaskTreeNode], unavailable: Bool, partial: Bool) {
        let api = sync.api(origin: try TowerOrigin(connection.origin))
        var found: [String: TaskTreeNode] = [:]
        var queue: [(id: String, cursor: String?, contextOnly: Bool)] = [(root, nil, false)] + upstream.map { ($0, nil, true) }
        var visited = Set<String>()
        var unavailable = false
        var requests = 0
        while let item = queue.first, found.count < limit, requests < max(100, limit) {
            requests += 1
            let page: (task: TaskRecord, tasks: [TaskRecord], channelTitles: [String: String], unavailable: Bool, next: String?)
            do {
                page = try await api.taskRelationships(workspaceId: workspace.id, appNpub: workspace.appNpub, taskId: item.id, cursor: item.cursor)
            } catch TowerError.http(let status, _, _) where [401, 403, 404].contains(status) {
                if item.id == root { throw TaskTreeError.unavailable }
                queue.removeFirst(); visited.insert(item.id); unavailable = true; continue
            }
            let rows = item.contextOnly ? [page.task] : [page.task] + page.tasks
            try await sync.store.writer.upsertTasks(workspaceId: workspace.id, rows)
            for r in rows { found[r.id] = TaskTreeNode(r, channelTitle: page.channelTitles[r.channelId]) }
            unavailable = unavailable || page.unavailable
            if let next = page.next, !item.contextOnly { queue[0].cursor = next } else { queue.removeFirst(); visited.insert(item.id) }
            for r in item.contextOnly ? [] : page.tasks where !visited.contains(r.id) && !queue.contains(where: { $0.id == r.id }) {
                queue.append((r.id, nil, false))
            }
        }
        return (Array(found.values), unavailable, !queue.isEmpty)
    }

    /// Tasks of a channel to choose a root from (newest first, one page).
    public func channelTasks(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channelId: String) async throws -> [TaskRecord] {
        let tasks = try await sync.api(origin: try TowerOrigin(connection.origin)).channelTasks(workspaceId: workspace.id, appNpub: workspace.appNpub, channelId: channelId)
        try await sync.store.writer.upsertTasks(workspaceId: workspace.id, tasks)
        return tasks
    }

    /// Creates a task in `channelId`: a child of `parent`, or the successor of `predecessor` (in its parent), or a base task.
    public func create(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channelId: String, scopeId: String?, title: String,
                       parent: String? = nil, predecessor: TaskTreeNode? = nil, requestId: String) async throws -> TaskRecord {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TaskTreeError.failed("Enter a title.") }
        do { try await sync.identity.requireSigner(npub: connection.signerNpub) } catch { throw TaskTreeError.locked }
        let metadata: [String: Any] = ["parent_task_id": parent ?? predecessor?.parentId ?? NSNull(), "predecessor_task_ids": predecessor.map { [$0.id] } ?? []]
        let body: [String: Any] = ["client_request_id": requestId, "title": name, "state": "new", "metadata": metadata]
        let client = TowerClient(origin: try TowerOrigin(connection.origin), transport: sync.transport, signer: sync.identity)
        let result = try await client.exchange(method: "POST", path: try TowerAPI.base(workspace.id) + "/channels/" + TowerAPI.uuid(channelId) + "/tasks",
                                               appNpub: workspace.appNpub, jsonBody: try JSONSerialization.data(withJSONObject: body))
        let o = ((try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any]) ?? [:]
        guard (200..<300).contains(result.status), let row = o["task"] as? [String: Any], let task = try? TaskRecord(raw: rawJSON(row)) else {
            if [401, 403].contains(result.status) { throw TaskTreeError.failed("You can't add tasks in this channel.") }
            throw TaskTreeError.failed("The task was not confirmed (HTTP \(result.status)). Retry the same title.")
        }
        guard task.channelId == channelId.lowercased(), scopeId == nil || task.scopeId == nil || task.scopeId == scopeId else {
            throw TaskTreeError.failed("Task destination was not confirmed. Retry the same entry.")
        }
        try await sync.store.writer.upsertTasks(workspaceId: workspace.id, [task])
        return task
    }
}

extension CanvasEditor {
    /// Saves a tree naplet's view (root, collapsed branches, upstream context) into its layout, keeping every other key.
    public func saveTaskTreeView(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, naplet: CanvasNaplet,
                                 view: TaskTreeView) async throws {
        var base = ((try? JSONSerialization.jsonObject(with: naplet.savedLayout)) as? [String: Any]) ?? [:]
        base["task_tree"] = view.object
        try await patchLayout(connection, workspace, canvasId: canvasId, naplet: naplet, layout: base)
    }

    /// Places a task tree for `channelId` (Tower authorizes `task.read` on it).
    public func addTaskTree(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, channelId: String, layout: CanvasLayout) async throws {
        var object = Self.layoutObject(Self.clamped(layout), base: [:])
        object["task_tree"] = TaskTreeView(instanceId: UUID().uuidString.lowercased()).object
        try await addNaplet(connection, workspace, canvasId: canvasId, sourceType: "task_tree", sourceId: channelId, title: "Task Tree", layoutObject: object)
    }
}

/// Persisted per-parent relationship progress. A failed refresh never masquerades as an empty list.
public struct TaskRelationshipCache: Codable, Sendable, Equatable {
    public var ids: [String] = []
    public var complete = false
    public var unavailable = false
    public var updatedAt: String? = nil
    public init() {}
    public static func key(_ workspace: String, _ task: String) -> String { "task-relationships:\(workspace):\(task)" }


}

extension StoreReader {
    public func taskRelationshipCache(workspaceId: String, taskId: String) throws -> TaskRelationshipCache? {
        guard let value = try state(TaskRelationshipCache.key(workspaceId, taskId)) else { return nil }
        return try JSONDecoder().decode(TaskRelationshipCache.self, from: Data(value.utf8))
    }

    /// Includes archived children and newly acknowledged creations/events. Never scans a bounded task-list page.
    public func directSubtasks(workspaceId: String, taskId: String) throws -> [TaskRecord] {
        let s = try db.prepare("""
        SELECT \(Self.taskColumns) FROM tasks WHERE workspace_id = ?
        AND lower(json_extract(CAST(raw AS TEXT), '$.metadata.parent_task_id')) = ?
        ORDER BY created_at, id
        """)
        try s.bind([.text(workspaceId), .text(taskId.lowercased())])
        var rows: [TaskRecord] = []
        while try s.step() { rows.append(Self.task(s, workspaceId: workspaceId)) }
        if let cache = try taskRelationshipCache(workspaceId: workspaceId, taskId: taskId), cache.complete {
            let ids = Set(cache.ids)
            rows = rows.filter { ids.contains($0.id) }
        }
        return rows
    }
}

extension TaskTreeService {
    /// Fetch only one parent's relationships, draining every page and caching progress after each.
    /// Descendants are loaded independently when expanded; successors are not counted as children.
    public func loadRelationships(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, taskId: String) async throws {
        try await sync.identity.requireReader(npub: connection.signerNpub)
        let api = sync.api(origin: try TowerOrigin(connection.origin))
        var cache = TaskRelationshipCache()
        var cursor: String? = nil
        var seen = Set<String>()
        let key = TaskRelationshipCache.key(workspace.id, taskId)
        repeat {
            do {
                let page = try await api.taskRelationships(workspaceId: workspace.id, appNpub: workspace.appNpub, taskId: taskId, cursor: cursor)
                try Task.checkCancellation()
                try await sync.store.writer.upsertTasks(workspaceId: workspace.id, [page.task] + page.tasks)
                cache.ids += page.tasks.map(\.id).filter { !cache.ids.contains($0) }
                cache.unavailable = cache.unavailable || page.unavailable
                cache.complete = page.next == nil
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                cache.updatedAt = formatter.string(from: Date())
                try await sync.store.writer.setState(key, String(decoding: JSONEncoder().encode(cache), as: UTF8.self))
                cursor = page.next
                if let cursor, !seen.insert(cursor).inserted { throw TowerError.malformed("task relationships repeated cursor") }
                // Load the named parent through its normal authorized read path.
                if let parent = TaskTreeNode(page.task).parentId, cursor == nil {
                    do {
                        let record = try await api.task(workspaceId: workspace.id, appNpub: workspace.appNpub, taskId: parent)
                        try await sync.store.writer.upsertTasks(workspaceId: workspace.id, [record])
                    } catch TowerError.http(let status, _, _) where [401, 403, 404].contains(status) {
                        try await sync.store.writer.applyTombstones(workspaceId: workspace.id, [.task(parent)])
                        cache.unavailable = true
                        try await sync.store.writer.setState(key, String(decoding: JSONEncoder().encode(cache), as: UTF8.self))
                    }
                }
            } catch TowerError.http(let status, _, _) where [401, 403, 404].contains(status) {
                cache.complete = false; cache.unavailable = true
                try await sync.store.writer.setState(key, String(decoding: JSONEncoder().encode(cache), as: UTF8.self))
                throw TaskTreeError.unavailable
            }
        } while cursor != nil
    }
}

extension WorkspaceSync {
    public func refreshTaskRelationships(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, taskId: String,
                                         force: Bool = false) async {
        let service = TaskTreeService(sync: self)
        await engine.enqueue(TaskRelationshipCache.key(workspace.id, taskId), priority: .user, force: force) {
            try await service.loadRelationships(connection, workspace, taskId: taskId)
        }
    }
}


extension StoreWriter {
    /// A newly stored authorized task or write acknowledgement is relationship evidence in its own right.
    /// Update known membership in the same transaction; client/server clock skew must never hide a new child.
    func noteTaskRelationship(_ task: TaskRecord) throws {
        guard let parent = TaskTreeNode(task).parentId else { return }
        let key = TaskRelationshipCache.key(task.workspaceId, parent)
        let query = try db.prepare("SELECT value FROM app_state WHERE key = ?")
        try query.bind([.text(key)])
        guard try query.step(), let value = query.text(0),
              var cache = try? JSONDecoder().decode(TaskRelationshipCache.self, from: Data(value.utf8)),
              !cache.ids.contains(task.id) else { return }
        cache.ids.append(task.id)
        try db.prepare("UPDATE app_state SET value = ? WHERE key = ?")
            .run([.text(String(decoding: try JSONEncoder().encode(cache), as: UTF8.self)), .text(key)])
    }
}
