import Foundation

// Task Tree naplets (sol `canvas/task-tree-page.js`, `task-tree-runtime.js`, `task-tree-graph.js`). A tree shows real
// channel tasks from a root task: children (`metadata.parent_task_id`) below, successors (`metadata.predecessor_task_ids`)
// to the right. Tasks are read through Tower's relationships route and stored like any other task, so a node opens the
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

/// A bounded projection of the tree from its root (sol `projectTree`).
public struct TaskTreeGraph: Sendable, Equatable {
    public struct Edge: Sendable, Equatable, Hashable { public let from: String; public let to: String; public let child: Bool }
    public struct Reference: Sendable, Equatable, Hashable { public let taskId: String; public let targetId: String; public let parent: Bool; public let available: Bool }
    public var nodes: [TaskTreeNode] = []
    public var edges: [Edge] = []
    public var references: [Reference] = []
    /// Grid cell of each node: columns follow dependencies (successors to the right), rows hierarchy (children below).
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
        var occupied = Set<String>()
        func reserve(_ id: String, _ x: Int, _ y: Int) {
            var y = y
            while occupied.contains("\(x):\(y)") { y += 1 }
            occupied.insert("\(x):\(y)")
            graph.positions[id] = (x, y)
        }
        if visible.contains(root) { reserve(root, 0, 0) }
        var pending = nodes.filter { graph.positions[$0.id] == nil }
        while !pending.isEmpty {
            var deferred: [TaskTreeNode] = []
            var progressed = false
            for task in pending {
                let predecessors = task.predecessors.filter { visible.contains($0) && $0 != task.id }
                let placed = predecessors.first { graph.positions[$0] != nil }
                if !predecessors.isEmpty && placed == nil { deferred.append(task); continue }
                if predecessors.isEmpty, let parent = task.parentId, visible.contains(parent), graph.positions[parent] == nil { deferred.append(task); continue }
                if let placed, let origin = graph.positions[placed] { reserve(task.id, origin.x + 1, origin.y) }
                else if let parent = task.parentId, let origin = graph.positions[parent] { reserve(task.id, origin.x, origin.y + 1) }
                else { reserve(task.id, 0, nodes.firstIndex(of: task) ?? 0) }
                progressed = true
            }
            if !progressed, let first = deferred.first { deferred.removeFirst(); reserve(first.id, 0, nodes.firstIndex(of: first) ?? 0) }
            pending = deferred
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
        guard task.id == taskId.lowercased() else { throw TowerError.malformed("task relationships") }
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
        var records: [TaskRecord] = []
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
            records += rows
            for r in rows { found[r.id] = TaskTreeNode(r, channelTitle: page.channelTitles[r.channelId]) }
            unavailable = unavailable || page.unavailable
            if let next = page.next, !item.contextOnly { queue[0].cursor = next } else { queue.removeFirst(); visited.insert(item.id) }
            for r in item.contextOnly ? [] : page.tasks where !visited.contains(r.id) && !queue.contains(where: { $0.id == r.id }) {
                queue.append((r.id, nil, false))
            }
        }
        if !records.isEmpty { try await sync.store.writer.upsertTasks(workspaceId: workspace.id, records) }
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
