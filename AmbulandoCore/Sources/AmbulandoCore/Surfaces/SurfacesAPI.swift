import Foundation

/// Tower routes behind the Context Tree, Canvas, agents, Toolbox and personal pins, read from `tower/src/routes/context-tree.ts`
/// and `routes/flightdeck-pg.ts`. All are existing typed `/api/v4/flightdeck-pg` routes with NIP-98 auth; no new
/// contract is assumed. Paths are built only from validated UUIDs, and every row must belong to the requested
/// workspace (and scope, canvas or channel) before it is returned for materialisation.
extension TowerAPI {
    /// Pages a cursor route (`limit ≤ 200`, opaque `next_cursor`) to its end, refusing a repeated cursor.
    private func cursorPages(_ path: String, appNpub: String, key: String, extra: [URLQueryItem] = [], maxPages: Int = 20) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<maxPages {
            var query = [URLQueryItem(name: "limit", value: "200")] + extra
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let o = try object(try await client.request(path: path, query: query, appNpub: appNpub), key)
            guard let page = o[key] as? [[String: Any]] else { throw TowerError.malformed(key) }
            rows += page
            guard let next = o["next_cursor"] as? String, !next.isEmpty else { return rows }
            guard seen.insert(next).inserted else { throw TowerError.malformed("\(key) cursor") }
            cursor = next
        }
        throw TowerError.listLimitReached(key)
    }

    // MARK: Context Tree

    public func contextComponents(workspaceId: String, appNpub: String, scopeId: String) async throws -> [ContextComponentRecord] {
        let path = try Self.base(workspaceId) + "/scopes/" + Self.uuid(scopeId) + "/context/components"
        let rows = try await cursorPages(path, appNpub: appNpub, key: "components")
        let components = try rows.map { try ContextComponentRecord(raw: rawJSON($0)) }
        guard components.allSatisfy({ $0.workspaceId == workspaceId && $0.scopeId == scopeId.lowercased() }) else { throw TowerError.malformed("context components") }
        return components
    }

    public func contextReferences(workspaceId: String, appNpub: String, scopeId: String, componentId: String) async throws -> [ContextReferenceRecord] {
        let path = try Self.base(workspaceId) + "/scopes/" + Self.uuid(scopeId) + "/context/components/" + Self.uuid(componentId) + "/references"
        let rows = try await cursorPages(path, appNpub: appNpub, key: "references")
        let references = try rows.map { try ContextReferenceRecord(raw: rawJSON($0)) }
        guard references.allSatisfy({ $0.workspaceId == workspaceId && $0.scopeId == scopeId.lowercased() && $0.componentId == componentId.lowercased() }) else {
            throw TowerError.malformed("context references")
        }
        return references
    }

    // MARK: Canvas

    /// The canvases visible to this viewer, in the viewer's order. Tower returns the complete list in one response.
    public func canvases(workspaceId: String, appNpub: String) async throws -> [CanvasRecord] {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/canvases", appNpub: appNpub), "canvases")
        guard lowerUUID(o["workspace_id"] as? String) == workspaceId, o["complete"] as? Bool == true,
              let rows = o["canvases"] as? [[String: Any]] else { throw TowerError.malformed("canvases") }
        return try rows.map { try CanvasRecord(raw: rawJSON($0), workspaceId: workspaceId) }
    }

    /// One canvas snapshot: the definition, viewer-authorized naplets (denied ones carry only their frame) and elements.
    public func canvasSnapshot(workspaceId: String, appNpub: String, canvasId: String) async throws -> (canvas: CanvasRecord, snapshot: CanvasSnapshotRecord) {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/canvases/" + Self.uuid(canvasId) + "/snapshot", appNpub: appNpub), "canvas snapshot")
        guard lowerUUID(o["workspace_id"] as? String) == workspaceId, o["complete"] as? Bool == true, let row = o["canvas"] as? [String: Any],
              let naplets = o["naplets"] as? [[String: Any]], let elements = o["elements"] as? [[String: Any]] else { throw TowerError.malformed("canvas snapshot") }
        let canvas = try CanvasRecord(raw: rawJSON(row), workspaceId: workspaceId)
        guard canvas.id == canvasId.lowercased() else { throw TowerError.malformed("canvas snapshot") }
        let bytes = try rawJSON(["naplets": naplets, "elements": elements])
        _ = try CanvasScene.parse(bytes)   // refuse a snapshot beyond the bounds before it is stored
        return (canvas, CanvasSnapshotRecord(workspaceId: workspaceId, canvasId: canvas.id, canvasRowVersion: canvas.rowVersion, bytes: bytes,
                                             fetchedAt: ISO8601DateFormatter.tower.string(from: Date())))
    }

    /// The HTML of an HTML naplet (web content), as Tower resolves it for this viewer.
    public func napletHTML(workspaceId: String, appNpub: String, canvasId: String, napletId: String) async throws -> (title: String, html: String) {
        let path = try Self.base(workspaceId) + "/canvases/" + Self.uuid(canvasId) + "/naplets/" + Self.uuid(napletId) + "/html"
        let o = try object(try await client.request(path: path, appNpub: appNpub), "HTML naplet")
        guard lowerUUID(o["workspace_id"] as? String) == workspaceId, lowerUUID(o["naplet_id"] as? String) == napletId.lowercased(),
              let content = o["content"] as? [String: Any], let html = content["html"] as? String else { throw TowerError.malformed("HTML naplet") }
        return ((o["title"] as? String) ?? "HTML", html)
    }

    /// The exact bytes of one board version, verified against the sha256 Tower projected for the naplet.
    public func boardScene(workspaceId: String, appNpub: String, board: BoardReference) async throws -> BoardSceneRecord {
        guard board.sizeBytes <= ExcalidrawScene.maxBytes else { throw ExcalidrawScene.ParseError.tooLarge }
        let path = try Self.base(workspaceId) + "/files/" + Self.uuid(board.fileId) + "/versions/" + Self.uuid(board.versionId) + "/object"
        let bytes = try await client.request(path: path, appNpub: appNpub)
        guard bytes.count <= ExcalidrawScene.maxBytes else { throw ExcalidrawScene.ParseError.tooLarge }
        guard SHA256Hex.of(bytes) == board.sha256 else { throw DocumentBodyError.integrity }
        return BoardSceneRecord(workspaceId: workspaceId, fileId: board.fileId, versionId: board.versionId, sha256: board.sha256, bytes: bytes,
                                fetchedAt: ISO8601DateFormatter.tower.string(from: Date()))
    }

    // MARK: Agents

    public func workspaceAgents(workspaceId: String, appNpub: String) async throws -> [WorkspaceAgentRecord] {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/workspace-agents", appNpub: appNpub), "workspace agents")
        guard let rows = o["workspace_agents"] as? [[String: Any]] else { throw TowerError.malformed("workspace agents") }
        let agents = rows.compactMap { try? WorkspaceAgentRecord(raw: rawJSON($0)) }
        guard agents.allSatisfy({ $0.workspaceId == workspaceId }) else { throw TowerError.malformed("workspace agents") }
        return agents
    }

    /// Tower's materialised user-visible activity for one channel: the newest page (no commentary history).
    public static let agentActivityPage = 50

    public func agentActivities(workspaceId: String, appNpub: String, channelId: String) async throws -> [AgentActivityRecord] {
        let query = [URLQueryItem(name: "channel_id", value: try Self.uuid(channelId)), URLQueryItem(name: "history_limit", value: "0"),
                     URLQueryItem(name: "limit", value: String(Self.agentActivityPage))]
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/agent-activities", query: query, appNpub: appNpub), "agent activity")
        guard let rows = o["agent_activities"] as? [[String: Any]] else { throw TowerError.malformed("agent activity") }
        // Rows that are not user-visible or lack an activity id are skipped, as in sol `mapPgAgentActivity`.
        let activities = rows.compactMap { try? AgentActivityRecord(raw: rawJSON($0)) }
        guard activities.allSatisfy({ $0.workspaceId == workspaceId && $0.channelId == channelId.lowercased() }) else { throw TowerError.malformed("agent activity") }
        return activities
    }

    // MARK: Toolbox

    /// Tower caps this list at 200 and returns no continuation (`next_cursor: null`, `parseLimit`). A full page may
    /// therefore be incomplete: it is reported as such and never used to remove local rows.
    public static let personalWappLimit = 200

    public func personalWapps(workspaceId: String, appNpub: String) async throws -> (wapps: [PersonalWappRecord], complete: Bool) {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/personal-wapps",
                                                    query: [URLQueryItem(name: "limit", value: String(Self.personalWappLimit))], appNpub: appNpub), "personal WApps")
        guard let rows = o["personal_wapps"] as? [[String: Any]] else { throw TowerError.malformed("personal WApps") }
        let wapps = try rows.map { try PersonalWappRecord(raw: rawJSON($0)) }
        guard wapps.allSatisfy({ $0.workspaceId == workspaceId }) else { throw TowerError.malformed("personal WApps") }
        let more = (o["next_cursor"] as? String).map { !$0.isEmpty } ?? false
        return (wapps, rows.count < Self.personalWappLimit && !more)
    }

    // MARK: Personal pins

    /// The viewer's pins through the record-sync priority feed (`family=personal_pin`), read until `has_more` is false.
    /// The feed lists each pin's newest head once; Tower makes the family visible only to its own actor.
    public func personalPins(workspaceId: String, appNpub: String, maxPages: Int = 20) async throws -> (pins: [PinRecord], deleted: [String], ordering: Bool) {
        let base = try Self.base(workspaceId)
        // Capability belongs to the main sync envelope; the priority family feed does not advertise it.
        let capabilities = try object(await client.request(path: base + "/record-sync", query: [URLQueryItem(name: "protocol_version", value: "1"), URLQueryItem(name: "limit", value: "1")], appNpub: appNpub), "record sync capabilities")
        let ordering = capabilities["personal_pin_order_version"] as? Int == 1
        let path = base + "/record-sync/priority"
        var pins: [String: PinRecord] = [:]
        var deleted = Set<String>()
        var cursor: String?
        var restarted = false
        var pages = 0
        while pages < maxPages {
            pages += 1
            var query = [URLQueryItem(name: "family", value: "personal_pin"), URLQueryItem(name: "limit", value: "200")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let data: Data
            do { data = try await client.request(path: path, query: query, appNpub: appNpub) }
            catch TowerError.http(409, "auxiliary_cursor_invalid"?, _) where !restarted {
                // The continuation expired or the record clock moved to a new epoch: start one fresh pass.
                restarted = true; cursor = nil; pins = [:]; deleted = []; continue
            }
            let o = try object(data, "personal pins")
            guard o["protocol_version"] as? Int == 1, let changes = o["changes"] as? [[String: Any]] else { throw TowerError.malformed("personal pins") }
            for change in changes {
                guard change["family"] as? String == "personal_pin", let id = lowerUUID(change["id"] as? String) else { continue }
                if let w = change["workspace_id"] as? String, lowerUUID(w) != workspaceId { throw TowerError.malformed("personal pins") }
                if change["operation"] as? String == "delete" { deleted.insert(id); pins[id] = nil; continue }
                guard let row = change["row"] as? [String: Any] else { continue }
                let pin = try PinRecord(raw: rawJSON(row))
                guard pin.workspaceId == workspaceId, pin.id == id else { throw TowerError.malformed("personal pins") }
                if pins[id].map({ $0.rowVersion < pin.rowVersion }) ?? true { pins[id] = pin }
            }
            guard o["has_more"] as? Bool == true else { return (Array(pins.values), Array(deleted), ordering) }
            guard let next = o["next_cursor"] as? String, !next.isEmpty, next != cursor else { throw TowerError.malformed("personal pins cursor") }
            cursor = next
        }
        throw TowerError.listLimitReached("personal pins")
    }
}
