import Foundation

/// A separate, read-only protocol. Tracker requests and bindings are deliberately not accepted here.
public struct WorkspaceReportBinding: Sendable, Equatable {
    public let workspaceId: String
    public static func parse(html: String, metadata: Data) throws -> Self {
        let meta = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
        guard let n = meta?["napplet"] as? [String: Any], TrackerDocument.exact(n, ["version", "app_id", "bindings"]),
              TrackerDocument.number(n["version"]) == 1, n["app_id"] as? String == "workspace-report",
              let b = n["bindings"] as? [String: Any], TrackerDocument.exact(b, ["report"]),
              let r = b["report"] as? [String: Any], TrackerDocument.exact(r, ["workspace_id"]),
              let workspace = TrackerDocument.uuid(r["workspace_id"]) else { throw FileNappletError.invalid }
        let regex = try NSRegularExpression(pattern: "<script\\b([^>]*)>([\\s\\S]*?)</script\\s*>", options: [.caseInsensitive])
        let text = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: text.length)).filter {
            text.substring(with: $0.range(at: 1)).range(of: "\\bid\\s*=\\s*([\"'])wingman-napplet-manifest\\1", options: [.regularExpression, .caseInsensitive]) != nil
        }
        guard matches.count == 1, let match = matches.first,
              text.substring(with: match.range(at: 1)).range(of: "\\btype\\s*=\\s*([\"'])application/json\\1", options: [.regularExpression, .caseInsensitive]) != nil,
              let m = try JSONSerialization.jsonObject(with: Data(text.substring(with: match.range(at: 2)).utf8)) as? [String: Any],
              TrackerDocument.exact(m, ["version", "app_id", "bindings"]), TrackerDocument.number(m["version"]) == 1,
              m["app_id"] as? String == "workspace-report", let bindings = m["bindings"] as? [String: Any], TrackerDocument.exact(bindings, ["report"]),
              let report = bindings["report"] as? [String: Any], TrackerDocument.exact(report, ["format", "operations", "privacy"]),
              report["format"] as? String == "workspace-report-v1", report["operations"] as? [String] == ["read"], report["privacy"] as? String == "viewer" else { throw FileNappletError.invalid }
        return Self(workspaceId: workspace)
    }
}
public struct WorkspaceReportCode: Sendable, Equatable {
    public let html: String
    public let binding: WorkspaceReportBinding
    public let versionId: String
    public let sha256: String
}
public struct WorkspaceReportRequest: Sendable {
    public let id: String
    public let range: String
    public static let ranges: Set<String> = ["7d", "30d", "90d", "all"]
    public static func parse(_ data: Data, session: String) throws -> Self {
        guard data.count <= 1024, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              TrackerDocument.exact(o, ["type", "version", "session", "requestId", "operation", "binding", "range"]),
              o["type"] as? String == "wingman-napplet-data", TrackerDocument.number(o["version"]) == 1,
              o["session"] as? String == session, o["operation"] as? String == "read", o["binding"] as? String == "report",
              let id = o["requestId"] as? String, id.range(of: "^[a-zA-Z0-9_-]{1,64}\\z", options: .regularExpression) != nil,
              let range = o["range"] as? String, ranges.contains(range) else { throw FileNappletError.invalid }
        return Self(id: id, range: range)
    }
}

public enum WorkspaceReportDocument {
    /// Returns only the validated aggregate; identity is checked by the host and never exposed to the frame.
    public static func validate(_ bytes: Data, workspace: String, range: String, identity: [String: String]) throws -> Data {
        guard bytes.count <= 70 * 1024, var o = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              TrackerDocument.exact(o, ["identity", "format", "workspace_id", "range", "from", "to", "as_of", "timezone", "complete", "channel_policy", "activity", "inventory", "channels", "ranking", "coverage"]),
              let i = o["identity"] as? [String: String], i == identity,
              o["format"] as? String == "workspace-report-v1", o["workspace_id"] as? String == workspace,
              o["range"] as? String == range, WorkspaceReportRequest.ranges.contains(range),
              o["timezone"] as? String == "UTC", TrackerDocument.boolean(o["complete"]) == true,
              o["channel_policy"] as? String == "active-project-channels",
              let to = o["to"] as? String, to == o["as_of"] as? String else { throw FileNappletError.invalid }
        let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard to.hasSuffix("Z"), let end = date.date(from: to) else { throw FileNappletError.invalid }
        if range == "all" { guard o["from"] is NSNull else { throw FileNappletError.invalid } }
        else {
            guard let from = o["from"] as? String, from.hasSuffix("Z"), let start = date.date(from: from),
                  abs(end.timeIntervalSince(start) - Double(["7d": 7, "30d": 30, "90d": 90][range]!) * 86400) < 0.001 else { throw FileNappletError.invalid }
        }
        func object(_ v: Any?, _ keys: Set<String>) throws -> [String: Any] {
            guard let v = v as? [String: Any], TrackerDocument.exact(v, keys) else { throw FileNappletError.invalid }; return v
        }
        func count(_ v: Any?) throws -> Int64 {
            guard let n = TrackerDocument.number(v), n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 9007199254740991,
                  n.doubleValue.rounded(.towardZero) == n.doubleValue else { throw FileNappletError.invalid }; return n.int64Value
        }
        let activity = try object(o["activity"], ["messages", "conversations"])
        let inventory = try object(o["inventory"], ["channels", "conversations", "tasks", "documents", "files"])
        let tasks = try object(inventory["tasks"], ["total", "open", "completed", "archived", "by_state"])
        let states = try object(tasks["by_state"], ["new", "ready", "in_progress", "review", "done", "archive", "backlog", "blocked", "archived"])
        let stateTotal = try states.values.reduce(Int64(0)) { try $0 + count($1) }
        guard try count(tasks["total"]) == stateTotal, try count(tasks["completed"]) == count(states["done"]),
              try count(tasks["archived"]) == count(states["archive"]) + count(states["archived"]),
              try count(tasks["total"]) == count(tasks["open"]) + count(tasks["completed"]) + count(tasks["archived"]) else { throw FileNappletError.invalid }
        let total = try count(inventory["channels"])
        guard total <= 2000 else { throw FileNappletError.invalid }
        for key in ["conversations", "documents", "files"] { _ = try count(inventory[key]) }
        let coverage = try object(o["coverage"], ["tasks_channels", "documents_channels", "files_channels"])
        for v in coverage.values { guard try count(v) <= total else { throw FileNappletError.invalid } }
        let ranking = try object(o["ranking"], ["total_channels", "returned_channels", "has_more", "other_messages", "other_conversations"])
        guard let rows = o["channels"] as? [[String: Any]], rows.count == min(Int(total), 10),
              try count(ranking["total_channels"]) == total, try count(ranking["returned_channels"]) == Int64(rows.count),
              TrackerDocument.boolean(ranking["has_more"]) == (total > rows.count) else { throw FileNappletError.invalid }
        var ids = Set<String>(), messages: Int64 = 0, conversations: Int64 = 0, previous: (Int64, String)?
        for row in rows {
            guard TrackerDocument.exact(row, ["channel_id", "scope_id", "name", "scope_name", "messages", "conversations"]),
                  let id = TrackerDocument.uuid(row["channel_id"]), ids.insert(id).inserted, TrackerDocument.uuid(row["scope_id"]) != nil else { throw FileNappletError.invalid }
            for key in ["name", "scope_name"] { guard let name = row[key] as? String, name.utf16.count <= 300 else { throw FileNappletError.invalid } }
            let m = try count(row["messages"]), c = try count(row["conversations"])
            guard c <= m else { throw FileNappletError.invalid }
            if let p = previous { guard p.0 > m || (p.0 == m && p.1 < id) else { throw FileNappletError.invalid } }
            previous = (m, id); messages += m; conversations += c
        }
        let otherM = try count(ranking["other_messages"]), otherC = try count(ranking["other_conversations"])
        guard otherC <= otherM, try count(activity["messages"]) == messages + otherM,
              try count(activity["conversations"]) == conversations + otherC,
              total > rows.count || (otherM == 0 && otherC == 0) else { throw FileNappletError.invalid }
        o.removeValue(forKey: "identity")
        let result = try rawJSON(o)
        guard result.count <= 65536 else { throw FileNappletError.invalid }; return result
    }
}

extension TowerAPI {
    public func workspaceReportCode(workspace: String, app: String, viewer: String, fileId: String) async throws -> WorkspaceReportCode {
        let row = try await nappletFile(workspace: workspace, app: app, id: fileId)
        guard let channel = lowerUUID(row["channel_id"] as? String), let metadata = row["metadata"] as? [String: Any],
              TrackerDocument.boolean(metadata["html_artifact"]) == true,
              let file = try? FileRecord(raw: rawJSON(row)), ArtefactType.file(file) == .html else { throw FileNappletError.invalid }
        let response = try object(try await client.request(path: try Self.base(workspace) + "/channels/" + Self.uuid(channel), appNpub: app), "report private channel")
        guard let c = response["channel"] as? [String: Any], lowerUUID(c["id"] as? String) == channel,
              lowerUUID(c["workspace_id"] as? String) == workspace, c["kind"] as? String == "dm",
              c["participant_npubs"] as? [String] == [viewer], c["archived_at"] == nil || c["archived_at"] is NSNull else { throw FileNappletError.unavailable }
        let (bytes, version) = try await nappletBytes(workspace: workspace, app: app, file: row, mime: "text/html", limit: 4 * 1024 * 1024)
        guard let html = String(data: bytes, encoding: .utf8) else { throw FileNappletError.invalid }
        let binding = try WorkspaceReportBinding.parse(html: html, metadata: rawJSON(metadata))
        guard binding.workspaceId == workspace else { throw FileNappletError.invalid }
        return WorkspaceReportCode(html: html, binding: binding, versionId: version, sha256: SHA256Hex.of(bytes))
    }
    public func authorizeWorkspaceReport(workspace: String, app: String, viewer: String, fileId: String, expected: WorkspaceReportCode) async throws {
        guard try await workspaceReportCode(workspace: workspace, app: app, viewer: viewer, fileId: fileId) == expected else { throw FileNappletError.unavailable }
        // Membership is live, independent of a readable private code File or remembered consent.
        let me = try object(try await client.request(path: try Self.base(workspace) + "/me", appNpub: app), "report membership")
        guard let identity = me["identity"] as? [String: String], identity["workspace_id"] == workspace, identity["app_npub"] == app else { throw FileNappletError.unavailable }
        try Task.checkCancellation()
    }
    public func readWorkspaceReport(workspace: String, app: String, viewer: String, fileId: String, expected: WorkspaceReportCode, range: String, identity: [String: String]) async throws -> Data {
        guard WorkspaceReportRequest.ranges.contains(range) else { throw FileNappletError.invalid }
        try await authorizeWorkspaceReport(workspace: workspace, app: app, viewer: viewer, fileId: fileId, expected: expected)
        let bytes = try await client.request(path: try Self.base(workspace) + "/workspace-report", query: [URLQueryItem(name: "range", value: range), URLQueryItem(name: "top_n", value: "10")], appNpub: app)
        let value = try WorkspaceReportDocument.validate(bytes, workspace: workspace, range: range, identity: identity)
        try await authorizeWorkspaceReport(workspace: workspace, app: app, viewer: viewer, fileId: fileId, expected: expected)
        return value
    }
}
extension WorkspaceSync {
    public func workspaceReportCode(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String) async throws -> WorkspaceReportCode {
        try await identity.requireReader(npub: c.signerNpub)
        return try await api(origin: TowerOrigin(c.origin)).workspaceReportCode(workspace: w.id, app: w.appNpub, viewer: c.signerNpub, fileId: fileId)
    }
    public func authorizeWorkspaceReport(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: WorkspaceReportCode) async throws {
        try await identity.requireReader(npub: c.signerNpub)
        try await api(origin: TowerOrigin(c.origin)).authorizeWorkspaceReport(workspace: w.id, app: w.appNpub, viewer: c.signerNpub, fileId: fileId, expected: code)
    }
    public func readWorkspaceReport(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: WorkspaceReportCode, range: String) async throws -> Data {
        try await identity.requireReader(npub: c.signerNpub)
        guard let root = try JSONSerialization.jsonObject(with: w.raw) as? [String: Any], let expected = root["identity"] as? [String: String],
              expected["workspace_id"] == w.id, expected["app_npub"] == w.appNpub,
              expected["tower_service_npub"] == c.towerNpub else { throw FileNappletError.unavailable }
        return try await api(origin: TowerOrigin(c.origin)).readWorkspaceReport(workspace: w.id, app: w.appNpub, viewer: c.signerNpub, fileId: fileId, expected: code, range: range, identity: expected)
    }
}

extension WorkspaceSync {
    public func createWorkspaceReport(_ c: ConnectionRecord, _ w: WorkspaceRecord, template: Data) async throws -> FileRecord {
        try await identity.requireSigner(npub: c.signerNpub)
        let api = try api(origin: TowerOrigin(c.origin))
        let scopeRows = try await api.client.list(path: try TowerAPI.base(w.id) + "/scopes", appNpub: w.appNpub, key: "scopes")
        let scopes = try scopeRows.map(ScopeRecord.init(raw:))
        guard let dm = scopes.first(where: { $0.workspaceId == w.id && $0.kind == "dm" }) else { throw FileNappletError.unavailable }
        let channels = try await api.channels(workspaceId: w.id, scopeId: dm.id, appNpub: w.appNpub)
        var channel = DirectMessagePlanner.existing(in: channels, participants: [c.signerNpub])
        if channel == nil {
            let response = try api.object(try await api.client.request(method: "POST", path: try TowerAPI.base(w.id) + "/scopes/" + TowerAPI.uuid(dm.id) + "/channels", appNpub: w.appNpub,
                jsonBody: rawJSON(["kind": "dm", "participant_npubs": [c.signerNpub], "name": "Personal", "description": "dm:" + c.signerNpub])), "self DM")
            guard let row = response["channel"] as? [String: Any] else { throw FileNappletError.unavailable }
            let created = try ChannelRecord(raw: rawJSON(row))
            channel = DirectMessagePlanner.existing(in: [created], participants: [c.signerNpub])
        }
        guard let channel, channel.workspaceId == w.id else { throw FileNappletError.unavailable }
        try Task.checkCancellation()
        guard let html = String(data: template, encoding: .utf8) else { throw FileNappletError.invalid }
        let reportMetadata = try rawJSON(["napplet": ["version": 1, "app_id": "workspace-report", "bindings": ["report": ["workspace_id": w.id]]]])
        _ = try WorkspaceReportBinding.parse(html: html, metadata: reportMetadata)
        let metadata: [String: Any] = ["html_artifact": true,
            "artefact": ["schema_version": 1, "type": "html", "format_version": 1, "editor_id": "builtin.html"],
            "napplet": ["version": 1, "app_id": "workspace-report", "bindings": ["report": ["workspace_id": w.id]]]]
        let code = try await api.createNappletFile(workspace: w.id, app: w.appNpub, channel: channel.id, name: "Workspace Report.html", mime: "text/html", bytes: template, metadata: metadata)
        _ = try await store.writer.upsertFiles(workspaceId: w.id, [code]) // Code metadata only; aggregates never enter the store.
        _ = try await store.writer.upsertChannels(workspaceId: w.id, scopeId: dm.id, [channel], complete: false)
        return code
    }
}
extension TowerAPI {
    public func workspaceReports(workspace: String, app: String, viewer: String) async throws -> [FileRecord] {
        let scopes = try await scopes(workspaceId: workspace, appNpub: app)
        guard scopes.allSatisfy({ $0.workspaceId == workspace }), scopes.contains(where: { $0.kind == "dm" }) else { throw FileNappletError.unavailable }
        var found: [FileRecord] = []
        for scope in scopes where scope.kind == "dm" {
            let channels = try await channels(workspaceId: workspace, scopeId: scope.id, appNpub: app)
            guard channels.allSatisfy({ $0.workspaceId == workspace && $0.scopeId == scope.id }) else { throw FileNappletError.unavailable }
            for channel in channels where DirectMessagePlanner.existing(in: [channel], participants: [viewer]) != nil {
                let rows = try await client.list(path: try Self.base(workspace) + "/channels/" + Self.uuid(channel.id) + "/files", appNpub: app, key: "files")
                for raw in rows {
                    let row = try object(raw, "tracker discovery")
                    let file = try FileRecord(raw: raw)
                    guard file.workspaceId == workspace, file.channelId == channel.id else { throw FileNappletError.unavailable }
                    if row["record_state"] as? String == "archived" || (row["deleted_at"] != nil && !(row["deleted_at"] is NSNull)) { continue }
                    let metadata = row["metadata"] as? [String: Any] ?? [:]
                    guard (metadata["napplet"] as? [String: Any])?["app_id"] as? String == "workspace-report" else { continue }
                    _ = try await workspaceReportCode(workspace: workspace, app: app, viewer: viewer, fileId: file.id)
                    found.append(file)
                }
            }
        }
        guard Set(found.map(\.id)).count == found.count else { throw FileNappletError.invalid }
        return found.sorted { $0.id < $1.id }
    }
}
extension WorkspaceSync {
    public func workspaceReports(_ c: ConnectionRecord, _ w: WorkspaceRecord) async throws -> [FileRecord] {
        try await identity.requireReader(npub: c.signerNpub)
        return try await api(origin: TowerOrigin(c.origin)).workspaceReports(workspace: w.id, app: w.appNpub, viewer: c.signerNpub)
    }
}

extension FileNappletTrustReceipt {
    public init(connection: ConnectionRecord, workspace: WorkspaceRecord, codeFile: String, report: WorkspaceReportCode) throws {
        guard UUID(uuidString: codeFile) != nil, report.binding.workspaceId == workspace.id else { throw FileNappletError.invalid }
        self.policyVersion = 1; self.origin = try TowerOrigin(connection.origin).url.absoluteString
        self.connection = connection.id; self.service = connection.towerNpub; self.viewer = connection.signerNpub
        self.workspace = workspace.id; self.app = workspace.appNpub; self.codeFile = codeFile.lowercased(); self.codeSHA256 = report.sha256
        self.manifestVersion = 1; self.appId = "workspace-report"; self.bindingName = "report"; self.dataFile = workspace.id
        self.format = "workspace-report-v1"; self.privacy = "viewer"; self.operations = ["read"]; self.canWrite = false
    }
}

/// Structural storage extension, independent of the cartridge's metric inventory.
public enum WorkspaceStorageDocument {
    public static func validateReport(_ bytes: Data, workspace: String, range: String, identity: [String: String]) throws -> Data {
        guard bytes.count <= 70 * 1024 else { throw FileNappletError.invalid }
        var report = try GenericJSON.decode(bytes)
        guard let storage = report.removeValue(forKey: "storage") as? [String: Any], let asOf = report["as_of"] as? String else { throw FileNappletError.invalid }
        let base = try WorkspaceReportDocument.validate(rawJSON(report), workspace: workspace, range: range, identity: identity)
        try validate(storage, workspace: workspace, asOf: asOf)
        var result = try GenericJSON.decode(base); result["storage"] = storage
        let data = try GenericJSON.canonical(result)
        guard data.count <= 65536 else { throw FileNappletError.invalid }; return data
    }
    public static func validate(_ storage: [String: Any], workspace: String, asOf: String) throws {
        guard GenericJSON.exact(storage, ["format", "workspace_id", "scope", "as_of", "activity_range_applies", "groups", "provider_measured_at", "last_object_completed_at", "caveats"]),
              storage["format"] as? String == "workspace-storage-v1", storage["workspace_id"] as? String == workspace,
              storage["scope"] as? String == "current-workspace", storage["as_of"] as? String == asOf,
              TrackerDocument.boolean(storage["activity_range_applies"]) == false,
              let groups = storage["groups"] as? [[String: Any]], groups.count <= 8,
              let caveats = storage["caveats"] as? [String], caveats.count <= 16 else { throw FileNappletError.invalid }
        func safeText(_ s: String, limit: Int) -> Bool {
            s.utf16.count <= limit && !s.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
        }
        func identifier(_ value: Any?) -> String? {
            guard let s = value as? String, GenericJSON.matches(s, "^[a-z][a-z0-9_-]{0,63}") else { return nil }; return s
        }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let snapshot = formatter.date(from: asOf), formatter.string(from: snapshot) == asOf else { throw FileNappletError.invalid }
        for key in ["provider_measured_at", "last_object_completed_at"] {
            if storage[key] is NSNull { continue }
            guard let time = storage[key] as? String, time.utf8.count <= 32, let date = formatter.date(from: time), formatter.string(from: date) == time, date <= snapshot else { throw FileNappletError.invalid }
        }
        guard caveats.allSatisfy({ safeText($0, limit: 1024) }) else { throw FileNappletError.invalid }
        var groupIDs = Set<String>()
        for group in groups {
            guard GenericJSON.exact(group, ["id", "metrics"]), let id = identifier(group["id"]), groupIDs.insert(id).inserted,
                  let metrics = group["metrics"] as? [[String: Any]], metrics.count <= 32 else { throw FileNappletError.invalid }
            var metricIDs = Set<String>()
            for metric in metrics {
                guard GenericJSON.exact(metric, ["id", "value", "unit", "method", "status"]),
                      let id = identifier(metric["id"]), metricIDs.insert(id).inserted, identifier(metric["method"]) != nil,
                      let unit = metric["unit"] as? String, ["bytes", "count"].contains(unit),
                      let status = metric["status"] as? String, ["actual", "estimated", "unavailable"].contains(status) else { throw FileNappletError.invalid }
                if status == "unavailable" { guard metric["value"] is NSNull else { throw FileNappletError.invalid } }
                else {
                    guard let n = TrackerDocument.number(metric["value"]), n.doubleValue.isFinite, n.doubleValue >= 0,
                          n.doubleValue <= 9007199254740991, n.doubleValue.rounded(.towardZero) == n.doubleValue else { throw FileNappletError.invalid }
                }
            }
        }
    }
}
