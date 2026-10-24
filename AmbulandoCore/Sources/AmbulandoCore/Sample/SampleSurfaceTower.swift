import Foundation

/// In-process stand-in for Tower's Context Tree, Canvas, board version, agent, Toolbox and personal pin routes.
///
/// Like `SampleWorkTower` it exists for deterministic tests and the labelled sample-data mode; it is **not** Tower and is
/// never evidence of live behaviour. It follows the server rules the client depends on, read from
/// `tower/src/services/flightdeck-pg-context-tree.ts`, `flightdeck-pg-canvases.ts`, `thread-pins.ts`,
/// `flightdeck-record-priority.ts` and `routes/flightdeck-pg.ts`:
/// - every route needs a valid NIP-98 event over the exact URL, method and body bytes;
/// - an unreadable scope's tree is `404 context_not_found`; references resolve per viewer (`available`, `unavailable`,
///   `external` for artifacts);
/// - invisible canvases are `404 canvas_unavailable`; naplets whose source the viewer cannot read are projected as
///   `access: denied` with only their layout;
/// - board version bytes are served raw with their sha256;
/// - agent activity needs `channel.read` on the channel (403 otherwise);
/// - pins: `expected_row_version` must match (409 `thread_pin_conflict`), a reused `mutation_id` with a different request is
///   409 `mutation_id_reused` and with the same request replays the receipt, an unreadable target is 403
///   `thread_pin_target_forbidden`; reads come only through the record-sync priority feed (`family=personal_pin`).
/// Any write to a canvas route is recorded in `canvasWrites` (rendering must never produce one).
public final class SampleSurfaceTower: @unchecked Sendable {
    public enum Fault: Sendable { case offline, dropResponseAfterCommit, status(Int, String) }

    private let lock = NSLock()
    private let file: URL?
    public let workspaceId: String
    private var state: [String: Any] = [:]
    private var faults: [(match: String, fault: Fault)] = []
    private var clock = 0
    public private(set) var log: [String] = []
    /// Method and path of every non-GET request to a canvas route.
    public private(set) var canvasWrites: [String] = []
    /// Page size of the pin feed (Tower's is 200; tests use a small one to exercise continuation).
    public var pinPageSize = 200

    public init(workspaceId: String, file: URL? = nil) {
        self.workspaceId = workspaceId.lowercased()
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            state = saved
            clock = (saved["clock"] as? Int) ?? 0
        }
        for key in Self.collections where state[key] == nil { state[key] = [String: Any]() }
        for key in ["denied_scopes", "denied_channels", "denied_records", "hidden_canvases"] where state[key] == nil { state[key] = [String]() }
    }

    static let collections = ["components", "references", "canvases", "naplets", "elements", "board_versions", "agents", "activities", "wapps",
                              "pins", "pin_mutations", "records"]

    public func inject(_ fault: Fault, matching path: String) { lock.withLock { faults.append((path, fault)) } }
    public var requestLog: [String] { lock.withLock { log } }

    // MARK: State helpers (lock held)

    private func table(_ name: String) -> [String: [String: Any]] { (state[name] as? [String: [String: Any]]) ?? [:] }
    private func put(_ name: String, _ id: String, _ row: [String: Any]?) { var t = table(name); t[id] = row; state[name] = t }
    private func list(_ name: String) -> [String] { (state[name] as? [String]) ?? [] }
    private func now() -> String {
        clock += 1
        state["clock"] = clock
        return String(format: "2026-10-24T11:%02d:%02d.%03dZ", (clock / 60_000) % 60, (clock / 1000) % 60, clock % 1000)
    }
    private func persist() {
        guard let file, let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        try? data.write(to: file, options: .atomic)
    }
    private func mutate(_ body: () -> Void) { lock.withLock { body(); persist() } }

    // MARK: Seeding and access (sample data and tests)

    public func seeded() -> Bool { lock.withLock { state["seeded"] as? Bool == true } }
    public func markSeeded() { mutate { state["seeded"] = true } }

    /// Viewer access, as Tower's ACL would decide it: a denied scope's tree is unreadable, a denied channel blocks its
    /// activity and pin targets, a denied record resolves as unavailable (references) or denied (naplets).
    public func deny(scope: String) { mutate { state["denied_scopes"] = list("denied_scopes") + [scope] } }
    public func deny(channel: String) { mutate { state["denied_channels"] = list("denied_channels") + [channel] } }
    public func deny(record: String) { mutate { state["denied_records"] = list("denied_records") + [record] } }
    public func allow(record: String) { mutate { state["denied_records"] = list("denied_records").filter { $0 != record } } }
    public func hide(canvas: String) { mutate { state["hidden_canvases"] = list("hidden_canvases") + [canvas] } }

    /// A record a reference or pin may point at: its type, title and channel (stand-in for Tower's own tables).
    public func seedRecord(id: String, type: String, title: String, channel: String, scope: String) {
        mutate { put("records", id, ["id": id, "type": type, "title": title, "channel_id": channel, "scope_id": scope]) }
    }

    @discardableResult
    public func seedComponent(id: String = UUID().uuidString.lowercased(), scope: String, title: String, parent: String? = nil, sortOrder: Int) -> String {
        mutate {
            let stamp = now()
            put("components", id, ["id": id, "workspace_id": workspaceId, "scope_id": scope, "title": title, "parent_id": parent ?? NSNull(),
                                   "sort_order": sortOrder, "row_version": 1, "created_at": stamp, "updated_at": stamp, "deleted_at": NSNull()])
        }
        return id
    }

    public func renameComponent(_ id: String, title: String) {
        mutate {
            guard var row = table("components")[id] else { return }
            row["title"] = title; row["row_version"] = ((row["row_version"] as? Int) ?? 1) + 1; row["updated_at"] = now()
            put("components", id, row)
        }
    }

    /// Deletes a component with its subtree and their references (Tower's confirmed delete).
    public func deleteComponent(_ id: String) {
        mutate {
            var doomed: Set<String> = [id], frontier = [id]
            while let next = frontier.popLast() {
                for (cid, c) in table("components") where c["parent_id"] as? String == next && !doomed.contains(cid) { doomed.insert(cid); frontier.append(cid) }
            }
            for cid in doomed { put("components", cid, nil) }
            for (rid, r) in table("references") where doomed.contains(r["component_id"] as? String ?? "") { put("references", rid, nil) }
        }
    }

    @discardableResult
    public func seedReference(component: String, type: String, recordId: String? = nil, artifact: [String: String]? = nil, sortOrder: Int) -> String {
        let id = UUID().uuidString.lowercased()
        mutate {
            let c = table("components")[component] ?? [:]
            let target: Any = type == "artifact" ? (artifact ?? [:]) as Any : ["record_id": recordId ?? ""]
            let stamp = now()
            put("references", id, ["id": id, "workspace_id": workspaceId, "scope_id": c["scope_id"] ?? NSNull(), "component_id": component,
                                   "target_type": type, "target": target, "sort_order": sortOrder, "row_version": 1, "created_at": stamp, "updated_at": stamp])
        }
        return id
    }

    @discardableResult
    public func seedCanvas(id: String = UUID().uuidString.lowercased(), title: String, position: Int, viewport: [String: Double] = ["x": 0, "y": 0, "scale": 1],
                           canManage: Bool = true) -> String {
        mutate {
            let stamp = now()
            put("canvases", id, ["id": id, "title": title, "position": position, "visibility": ["mode": "workspace", "actor_ids": [], "group_ids": []],
                                 "viewport": viewport, "row_version": 1, "created_at": stamp, "updated_at": stamp, "can_manage": canManage])
        }
        return id
    }

    /// A naplet with its source; `content` is what Tower's resolver would return for a readable source.
    @discardableResult
    public func seedNaplet(canvas: String, sourceType: String, sourceId: String, title: String, layout: [String: Int], content: [String: Any],
                           source: [String: Any]? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        mutate {
            put("naplets", id, ["id": id, "canvas_id": canvas, "source_type": sourceType, "source_id": sourceId, "title": title, "layout": layout,
                                "content": content, "source": source ?? ["type": sourceType, "id": sourceId], "row_version": 1])
        }
        return id
    }

    public func moveNaplet(_ id: String, layout: [String: Int]) {
        mutate {
            guard var row = table("naplets")[id] else { return }
            row["layout"] = layout; row["row_version"] = ((row["row_version"] as? Int) ?? 1) + 1
            put("naplets", id, row)
        }
    }

    @discardableResult
    public func seedElement(canvas: String, kind: String, layout: [String: Int], data: [String: Any]) -> String {
        let id = UUID().uuidString.lowercased()
        mutate {
            let stamp = now()
            put("elements", id, ["id": id, "canvas_id": canvas, "kind": kind, "layout": layout, "data": data, "row_version": 1, "created_at": stamp, "updated_at": stamp])
        }
        return id
    }

    /// A board File's version bytes; returns the projection a ready excalidraw naplet carries.
    public func seedBoardVersion(fileId: String, versionId: String, versionNumber: Int, bytes: Data) -> [String: Any] {
        let sha = SHA256Hex.of(bytes)
        mutate { put("board_versions", "\(fileId)/\(versionId)", ["bytes": bytes.base64EncodedString(), "sha256": sha]) }
        return ["file_id": fileId, "current_version_id": versionId, "current_version_number": versionNumber, "content_type": "application/vnd.excalidraw+json",
                "size_bytes": bytes.count, "sha256": sha, "updated_at": "2026-10-24T09:00:00.000Z", "updated_by_actor_npub": NSNull(), "can_write": false]
    }

    @discardableResult
    public func seedAgent(npub: String, name: String, sortOrder: Int, visible: Bool = true) -> String {
        let id = UUID().uuidString.lowercased()
        mutate {
            let stamp = now()
            put("agents", id, ["id": id, "workspace_id": workspaceId, "connection_id": UUID().uuidString.lowercased(), "agent_id": name.lowercased(),
                               "agent_npub": npub, "display_name": name, "avatar_url": NSNull(), "capabilities": ["chat"], "sort_order": sortOrder,
                               "is_visible": visible, "metadata": [:], "row_version": 1, "created_at": stamp, "updated_at": stamp, "archived_at": NSNull()])
        }
        return id
    }

    @discardableResult
    public func seedActivity(channel: String, scope: String, thread: String, agent: String, state activityState: String, label: String,
                             summary: String? = nil, sequence: Int = 1, visibility: String = "user_visible") -> String {
        let id = UUID().uuidString.lowercased()
        mutate {
            let stamp = now()
            let terminal = AgentActivityRecord.terminalStates.contains(activityState)
            put("activities", id, ["id": id, "workspace_id": workspaceId, "scope_id": scope, "channel_id": channel, "thread_id": thread,
                                   "trigger_message_id": UUID().uuidString.lowercased(), "turn_id": NSNull(), "session_id": "sample-session",
                                   "activity_id": "act-\(id.prefix(8))", "agent_npub": agent, "publisher_actor_id": UUID().uuidString.lowercased(),
                                   "state": activityState, "label": label, "summary": summary ?? NSNull(), "body": NSNull(), "visibility": visibility,
                                   "sequence": sequence, "expires_at": "2026-10-24T23:00:00.000Z", "last_heartbeat_at": stamp,
                                   "lease_expires_at": "2026-10-24T23:00:00.000Z", "lease_health": "live", "blocked_by_turn_id": NSNull(),
                                   "queue_position": NSNull(), "terminal_at": terminal ? stamp : NSNull(), "created_at": stamp, "updated_at": stamp])
        }
        return id
    }

    @discardableResult
    public func seedWapp(title: String, launchURL: String, description: String? = nil, sortOrder: Int, owner: String, status: String = "active") -> String {
        let id = UUID().uuidString.lowercased()
        mutate {
            let stamp = now()
            put("wapps", id, ["id": id, "record_id": id, "workspace_id": workspaceId, "owner_actor_id": UUID().uuidString.lowercased(), "owner_npub": owner,
                              "owner_actor_npub": owner, "scope_id": NSNull(), "channel_id": NSNull(), "title": title, "description": description ?? NSNull(),
                              "launch_url": launchURL, "icon_url": NSNull(), "app_id": NSNull(), "wapp_id": NSNull(), "source_wingman_url": NSNull(),
                              "sort_order": sortOrder, "status": status, "record_state": status, "metadata": [:], "signer_profile": NSNull(),
                              "row_version": 1, "created_at": stamp, "updated_at": stamp])
        }
        return id
    }

    /// Someone (another device) pins or unpins; bumps the row version like Tower.
    public func externalPin(type: String, resource: String, pinned: Bool) { mutate { _ = writePin(type: type, resource: resource, pinned: pinned) } }

    public func pinRows() -> [[String: Any]] { lock.withLock { Array(table("pins").values) } }

    // MARK: Routing

    /// Handles a request for these routes, or returns nil for routes it does not own.
    public func handle(_ request: URLRequest) throws -> (Int, Any)? {
        guard let url = request.url else { return nil }
        let base = "/api/v4/flightdeck-pg/workspaces/\(workspaceId)/"
        guard url.path.hasPrefix(base) else { return nil }
        let parts = url.path.dropFirst(base.count).split(separator: "/").map(String.init)
        let method = request.httpMethod ?? "GET"
        guard Self.owns(parts) else { return nil }
        let body = request.httpBody ?? Data()
        guard SampleAuth.verify(request, body: body) else { return (401, ["code": "unauthorized", "error": "invalid NIP-98"]) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fault: Fault? = lock.withLock {
            log.append("\(method) \(url.path)")
            if parts.first == "canvases", method != "GET" { canvasWrites.append("\(method) \(url.path)") }
            guard let index = faults.firstIndex(where: { url.path.hasSuffix($0.match) || url.path.contains($0.match) }) else { return nil }
            return faults.remove(at: index).fault
        }
        if case .offline = fault { throw URLError(.notConnectedToInternet) }
        if case .status(let status, let code) = fault { return (status, ["code": code, "error": code]) }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let result = lock.withLock { () -> (Int, Any) in
            let r = route(parts, method: method, object: object, query: query)
            persist()
            return r
        }
        if case .dropResponseAfterCommit = fault { throw URLError(.networkConnectionLost) }
        return result
    }

    static func owns(_ p: [String]) -> Bool {
        guard let first = p.first else { return false }
        switch first {
        case "canvases", "workspace-agents", "agent-activities", "personal-wapps", "record-sync": return true
        case "scopes": return p.count >= 4 && p[2] == "context"
        case "me": return p.count >= 2 && p[1] == "pins"
        case "files": return p.count == 5 && p[2] == "versions" && p[4] == "object"
        default: return false
        }
    }

    private func error(_ status: Int, _ code: String) -> (Int, Any) { (status, ["code": code, "error": code]) }
    private func q(_ query: [URLQueryItem], _ name: String) -> String? { query.first { $0.name == name }?.value }

    private func paged(_ rows: [[String: Any]], key: String, query: [URLQueryItem], extra: [String: Any] = [:]) -> (Int, Any) {
        let limit = min(200, Int(q(query, "limit") ?? "50") ?? 50)
        let start = q(query, "cursor").flatMap { Int($0.dropFirst(4)) } ?? 0
        let slice = Array(rows.dropFirst(start).prefix(limit))
        let next: Any = start + slice.count < rows.count ? "idx:\(start + slice.count)" : NSNull()
        return (200, [key: slice, "next_cursor": next].merging(extra) { a, _ in a })
    }

    private func readable(_ record: String) -> [String: Any]? {
        guard !list("denied_records").contains(record), let r = table("records")[record],
              !list("denied_channels").contains(r["channel_id"] as? String ?? "") else { return nil }
        return r
    }

    private func route(_ p: [String], method: String, object: [String: Any], query: [URLQueryItem]) -> (Int, Any) {
        let capabilities: [String: Any] = ["read": true, "manage": false, "edit": false, "scope_manage": false]
        switch (method, p.count, p[0]) {
        // Context Tree
        case ("GET", 4, "scopes") where p[3] == "components":
            guard !list("denied_scopes").contains(p[1]) else { return error(404, "context_not_found") }
            let rows = table("components").values.filter { $0["scope_id"] as? String == p[1] }
                .sorted { (($0["sort_order"] as! Int), ($0["id"] as! String)) < (($1["sort_order"] as! Int), ($1["id"] as! String)) }
            return paged(rows, key: "components", query: query, extra: ["capabilities": capabilities])
        case ("GET", 6, "scopes") where p[3] == "components" && p[5] == "references":
            guard !list("denied_scopes").contains(p[1]) else { return error(404, "context_not_found") }
            guard table("components")[p[4]]?["scope_id"] as? String == p[1] else { return error(404, "context_not_found") }
            let rows = table("references").values.filter { $0["component_id"] as? String == p[4] }
                .sorted { (($0["sort_order"] as! Int), ($0["id"] as! String)) < (($1["sort_order"] as! Int), ($1["id"] as! String)) }
                .map { row -> [String: Any] in
                    var out = row
                    if row["target_type"] as? String == "artifact" { out["resolution"] = ["status": "external"] }
                    else if let id = (row["target"] as? [String: Any])?["record_id"] as? String, let r = readable(id) {
                        out["resolution"] = ["status": "available", "title": r["title"] ?? "", "record_id": id]
                    } else { out["resolution"] = ["status": "unavailable"] }
                    return out
                }
            return paged(rows, key: "references", query: query, extra: ["capabilities": capabilities])
        case (_, _, "scopes"):
            return error(403, "permission_denied")
        // Canvas
        case ("GET", 1, "canvases"):
            let rows = visibleCanvases()
            return (200, ["workspace_id": workspaceId, "complete": true, "canvases": rows])
        case ("GET", 3, "canvases") where p[2] == "snapshot":
            guard let canvas = visibleCanvases().first(where: { $0["id"] as? String == p[1] }) else { return error(404, "canvas_unavailable") }
            let naplets = table("naplets").values.filter { $0["canvas_id"] as? String == p[1] }
                .sorted { ((($0["layout"] as? [String: Int])?["z"] ?? 1), ($0["id"] as! String)) < ((($1["layout"] as? [String: Int])?["z"] ?? 1), ($1["id"] as! String)) }
                .map { n -> [String: Any] in
                    let layout = n["layout"] ?? [:]
                    // Tower collapses missing, unauthorized and failed sources to the same non-disclosing projection.
                    if list("denied_records").contains(n["source_id"] as? String ?? "") {
                        return ["id": n["id"]!, "access": "denied", "layout": layout, "row_version": n["row_version"]!]
                    }
                    return ["id": n["id"]!, "access": "ready", "layout": layout, "source": n["source"]!, "title": n["title"]!, "content": n["content"]!, "row_version": n["row_version"]!]
                }
            let elements = table("elements").values.filter { $0["canvas_id"] as? String == p[1] }.map { e -> [String: Any] in
                var out = e; out["canvas_id"] = nil; return out
            }
            return (200, ["workspace_id": workspaceId, "complete": true, "canvas": canvas, "naplets": naplets, "elements": elements,
                          "spatial_context": ["version": 1, "coordinate_space": "canvas_world", "items": []]])
        case ("GET", 5, "canvases") where p[2] == "naplets" && p[4] == "html":
            guard visibleCanvases().contains(where: { $0["id"] as? String == p[1] }) else { return error(404, "canvas_unavailable") }
            guard let n = table("naplets")[p[3]], n["source_type"] as? String == "html", !list("denied_records").contains(n["source_id"] as? String ?? ""),
                  let html = (n["content"] as? [String: Any])?["html"] as? String else { return error(404, "canvas_source_unavailable") }
            return (200, ["workspace_id": workspaceId, "naplet_id": p[3], "title": n["title"] ?? "HTML", "source": n["source"] ?? [:],
                          "content": ["html": html], "versions": []])
        case (_, _, "canvases"):
            // The native client never writes boards; any such request is recorded above and refused here.
            return error(403, "permission_denied")
        case ("GET", 5, "files"):
            guard !list("denied_records").contains(p[1]), let v = table("board_versions")["\(p[1])/\(p[3])"],
                  let bytes = Data(base64Encoded: v["bytes"] as? String ?? "") else { return error(404, "file_version_object_not_found") }
            return (200, bytes)
        // Agents
        case ("GET", 1, "workspace-agents"):
            let rows = table("agents").values.sorted { ($0["sort_order"] as! Int) < ($1["sort_order"] as! Int) }
            return (200, ["workspace_agents": rows, "next_cursor": NSNull()])
        case ("GET", 1, "agent-activities"):
            guard let channel = q(query, "channel_id"), !channel.isEmpty else { return error(400, "validation_error") }
            guard !list("denied_channels").contains(channel) else { return error(403, "permission_denied") }
            let rows = table("activities").values.filter { $0["channel_id"] as? String == channel }
                .sorted { ($0["created_at"] as! String) > ($1["created_at"] as! String) }
            return paged(rows, key: "agent_activities", query: query)
        // Toolbox
        case ("GET", 1, "personal-wapps"):
            let rows = table("wapps").values.sorted { ($0["sort_order"] as! Int) < ($1["sort_order"] as! Int) }
            return (200, ["personal_wapps": rows, "next_cursor": NSNull()])
        // Pins
        case ("GET", 2, "record-sync") where p[1] == "priority":
            return pinFeed(query)
        case ("PUT", 4, "me"):
            return putPin(type: p[2], resource: p[3], object)
        default:
            return error(404, "not_found")
        }
    }

    private func visibleCanvases() -> [[String: Any]] {
        table("canvases").values.filter { !list("hidden_canvases").contains($0["id"] as? String ?? "") }
            .sorted { (($0["position"] as! Int), ($0["id"] as! String)) < (($1["position"] as! Int), ($1["id"] as! String)) }
    }

    // MARK: Pins

    /// Newest first, each pin's current row once; continuation tokens expire with `invalidatePinCursors()`.
    private func pinFeed(_ query: [URLQueryItem]) -> (Int, Any) {
        let families = query.filter { $0.name == "family" }.compactMap(\.value)
        guard families == ["personal_pin"] else { return error(400, "invalid_family") }
        let rows = table("pins").values.sorted { (($0["row_version"] as! Int), ($0["id"] as! String)) > (($1["row_version"] as! Int), ($1["id"] as! String)) }
        var start = 0
        if let cursor = q(query, "cursor") {
            guard let saved = (state["pin_cursors"] as? [String: Int])?[cursor] else { return error(409, "auxiliary_cursor_invalid") }
            start = saved
        }
        let slice = Array(rows.dropFirst(start).prefix(min(pinPageSize, Int(q(query, "limit") ?? "200") ?? 200)))
        let token = UUID().uuidString.lowercased()
        var cursors = (state["pin_cursors"] as? [String: Int]) ?? [:]
        cursors[token] = start + slice.count
        state["pin_cursors"] = cursors
        let changes = slice.map { row -> [String: Any] in
            ["family": "personal_pin", "id": row["id"]!, "operation": "upsert", "version": String(row["row_version"] as! Int), "workspace_id": workspaceId,
             "scope_id": row["scope_id"] ?? NSNull(), "channel_id": row["channel_id"] ?? NSNull(), "row": row]
        }
        return (200, ["protocol_version": 1, "captured_head": "1", "changes": changes, "next_cursor": token, "has_more": start + slice.count < rows.count,
                      "coverage": "partial", "retention_policy": "retain_downloaded"])
    }

    /// Expires every pin feed continuation (a new record-clock epoch or the 7-day idle limit on Tower).
    public func invalidatePinCursors() { mutate { state["pin_cursors"] = [String: Int]() } }

    private func pinKey(_ type: String, _ resource: String) -> String { "\(type):\(resource)" }

    @discardableResult
    private func writePin(type: String, resource: String, pinned: Bool) -> [String: Any] {
        let key = pinKey(type, resource)
        var row = table("pins").values.first { $0["key"] as? String == key } ?? [:]
        let record = readable(resource)
        let stamp = now()
        if row.isEmpty {
            row = ["id": UUID().uuidString.lowercased(), "workspace_id": workspaceId, "actor_id": "sample-actor", "key": key, "resource_type": type,
                   "resource_id": resource, "thread_id": type == "thread" ? resource : NSNull(), "order_position": NSNull(), "row_version": 0]
        }
        let wasPinned = row["pinned"] as? Bool == true
        row["pinned"] = pinned
        row["channel_id"] = record?["channel_id"] ?? row["channel_id"] ?? NSNull()
        row["scope_id"] = record?["scope_id"] ?? row["scope_id"] ?? NSNull()
        row["root_record_id"] = resource
        // Re-pinning keeps the original time (Tower keeps `pinned_at` while a pin stays pinned).
        if pinned { if !wasPinned { row["pinned_at"] = stamp } } else { row["pinned_at"] = NSNull() }
        row["row_version"] = ((row["row_version"] as? Int) ?? 0) + 1
        row["updated_at"] = stamp
        put("pins", row["id"] as! String, row)
        return row
    }

    private func putPin(type: String, resource: String, _ o: [String: Any]) -> (Int, Any) {
        guard ["thread", "task", "document", "channel"].contains(type), UUID(uuidString: resource) != nil, let pinned = o["pinned"] as? Bool,
              let expected = o["expected_row_version"] as? Int, expected >= 0, let mutation = o["mutation_id"] as? String, UUID(uuidString: mutation) != nil,
              Set(o.keys).isSubset(of: ["pinned", "expected_row_version", "mutation_id", "import_only", "pinned_at"]) else { return error(400, "invalid_thread_pin") }
        let hash = SHA256Hex.of("\(type)|\(resource)|\(pinned)|\(expected)")
        if let prior = table("pin_mutations")[mutation] {
            guard prior["hash"] as? String == hash else { return error(409, "mutation_id_reused") }
            return (200, ["pin": prior["ack"] ?? [:]])
        }
        let current = table("pins").values.first { $0["key"] as? String == pinKey(type, resource) }
        guard ((current?["row_version"] as? Int) ?? 0) == expected else { return error(409, "thread_pin_conflict") }
        if pinned {
            guard table("records")[resource] != nil else { return error(404, "thread_not_found") }
            guard readable(resource) != nil else { return error(403, "thread_pin_target_forbidden") }
        }
        var row = writePin(type: type, resource: resource, pinned: pinned)
        put("pin_mutations", mutation, ["hash": hash, "ack": row])
        row["key"] = nil
        return (200, ["pin": row])
    }
}

/// NIP-98 check shared by the sample routes: a valid kind 27235 event over the exact URL, method and body bytes.
enum SampleAuth {
    static func verify(_ request: URLRequest, body: Data) -> Bool {
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Nostr "),
              let data = Data(base64Encoded: String(header.dropFirst(6))), let event = try? JSONDecoder().decode(NostrEvent.self, from: data),
              SignatureVerifier.verify(event), event.kind == 27235, event.tags.contains(["u", request.url!.absoluteString]),
              event.tags.contains(["method", (request.httpMethod ?? "GET").uppercased()]) else { return false }
        let payload = event.tags.first { $0.first == "payload" }?.last
        if body.isEmpty { return payload == nil } else { return payload == SHA256Hex.of(body) }
    }
}
