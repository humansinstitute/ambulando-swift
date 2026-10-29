import Foundation

/// Synthetic administration API used only by opt-in sample UI and contract tests. Never touches a live workspace.
public final class SampleAdministrationTower: @unchecked Sendable {
    private let lock = NSLock()
    private let workspace: String
    private let file: URL?
    private var tables: [String: [[String: Any]]] = [:]
    private var scopeRevision = 1
    private var _denied = false
    public var denied: Bool { get { lock.withLock { _denied } } set { lock.withLock { _denied = newValue } } }
    public init(workspace: String, file: URL? = nil) {
        self.workspace = workspace; self.file = file
        if let file, let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] { tables = object }
    }
    public func seedMembers(_ members: [[String: Any]]) { lock.withLock { if tables["members"] == nil { tables["members"] = members.map { $0["actor"] as? [String: Any] ?? $0 }; persist() } } }
    public func seedGroups(_ groups: [[String: Any]]) {
        lock.withLock {
            guard tables["groups"] == nil else { return }
            tables["groups"] = groups.map { input in
                var group = input
                group["members"] = (input["members"] as? [[String: Any]] ?? []).map { source in
                    var actor = source["actor"] as? [String: Any] ?? source
                    if let known = tables["members"]?.first(where: { $0["npub"] as? String == actor["npub"] as? String }) { actor["actor_id"] = known["actor_id"] }
                    return actor
                }
                return group
            }
            persist()
        }
    }
    private func persist() {
        guard let file, let data = try? JSONSerialization.data(withJSONObject: tables, options: [.sortedKeys]) else { return }
        try? data.write(to: file, options: .atomic)
    }
    public func handle(_ request: URLRequest) throws -> (Int, Any)? {
        let base = "/api/v4/flightdeck-pg/workspaces/\(workspace)"
        guard let path = request.url?.path, path == base || path.hasPrefix(base + "/") else { return nil }
        let suffix = String(path.dropFirst(base.count)), p = suffix.split(separator: "/").map(String.init), method = request.httpMethod ?? "GET"
        let body = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]) ?? [:]
        let owned = ["members", "groups", "wapp-delegations", "wapp-installations", "wapp-install-intents", "wapp-publishing-grants"]
        guard owned.contains(p.first ?? "") || suffix == "/me" || (p.count == 3 && p[2] == "grants") || (p.isEmpty && method == "PATCH") else { return nil }
        return lock.withLock {
            if suffix == "/me" { return (200, ["membership": ["role": _denied ? "member" : "admin"], "actor": tables["members"]?.first ?? [:], "permissions": _denied ? ["workspace.read"] : ["workspace.read", "workspace.manage", "scope.create", "channel.manage"]]) }
            if _denied { return (403, ["code": "forbidden"]) }
            if p.isEmpty { tables["profile"] = [body]; persist(); return (200, body) }
            let family = p[0]
            if p.count == 3 && p[2] == "grants" {
                let key = "\(family):\(p[1]):grants"
                if method == "GET" { return (200, ["revision": scopeRevision, "can_manage": true, "grants": tables[key] ?? [], "principals": ["actors": tables["members"] ?? [], "groups": tables["groups"] ?? []]]) }
                if family == "scopes" {
                    guard body["expected_revision"] as? Int == scopeRevision else { return (409, ["code": "revision_conflict"]) }
                    var rows = tables[key] ?? []
                    rows.removeAll { $0["principal_id"] as? String == body["principal_id"] as? String && $0["principal_type"] as? String == body["principal_type"] as? String }
                    if body["revoke"] as? Bool != true { rows.append(body) }
                    tables[key] = rows; scopeRevision += 1; persist()
                    return (200, ["revision": scopeRevision, "can_manage": true, "grants": rows, "principals": ["actors": tables["members"] ?? [], "groups": tables["groups"] ?? []]])
                }
            }
            if family == "channels", p.count >= 3 {
                let key = "channels:\(p[1]):grants"
                var rows = tables[key] ?? []
                if p.count == 5 { rows.removeAll { $0["principal_id"] as? String == p[4] && $0["principal_type"] as? String == p[3] } }
                if method != "DELETE" { var row = body; if p.count == 5 { row["principal_type"] = p[3]; row["principal_id"] = p[4] }; rows.append(row) }
                tables[key] = rows; persist(); return (200, ["grants": rows])
            }
            if method == "GET" && p.count == 1 {
                let key: String
                switch family { case "wapp-delegations": key = "delegations"; case "wapp-installations": key = "installations"; case "wapp-install-intents": key = "intents"; case "wapp-publishing-grants": key = "grants"; default: key = family }
                return (200, [key: tables[family] ?? [], "next_cursor": NSNull()])
            }
            if family == "groups", p.count >= 3 {
                guard let index = tables[family]?.firstIndex(where: { $0["group_id"] as? String == p[1] }) else { return (404, ["code": "group_not_found"]) }
                var group = tables[family]![index]
                if p[2] == "members" {
                    if method == "POST", body["ensure_workspace_member"] as? Bool == true,
                       let npub = body["member_npub"] as? String,
                       !(tables["members"] ?? []).contains(where: { $0["npub"] as? String == npub }) {
                        guard NostrKeys.isValidNpub(npub), ["human", "agent"].contains(body["kind"] as? String ?? "") else { return (400, ["code": "validation_error"]) }
                        tables["members", default: []].append(["actor_id": UUID().uuidString.lowercased(), "npub": npub, "kind": body["kind"]!, "role": "member"])
                    }
                    var members = group["members"] as? [[String: Any]] ?? []
                    if method == "DELETE" && p.count == 4 { members.removeAll { $0["actor_id"] as? String == p[3] } }
                    else if let member = tables["members"]?.first(where: { $0["npub"] as? String == body["member_npub"] as? String }) { if !members.contains(where: { $0["actor_id"] as? String == member["actor_id"] as? String }) { members.append(member) } }
                    else { return (404, ["code": "member_not_found"]) }
                    group["members"] = members
                } else {
                    var children = group["child_group_ids"] as? [String] ?? []
                    if method == "DELETE" && p.count == 4 { children.removeAll { $0 == p[3] } }
                    else if let child = body["child_group_id"] as? String { guard child != p[1] else { return (409, ["code": "cycle"]) }; if !children.contains(child) { children.append(child) } }
                    group["child_group_ids"] = children
                }
                tables[family]![index] = group; persist(); return (200, ["group": group])
            }
            if method == "POST" || method == "PUT" {
                var row = body
                let id = p.count > 1 ? p[1] : UUID().uuidString.lowercased()
                row[family == "groups" ? "group_id" : family == "members" ? "actor_id" : "id"] = id
                if family == "members" { row["npub"] = body["member_npub"] }
                if p.last == "revoke" { row["revoked_at"] = ISO8601DateFormatter().string(from: Date()) }
                tables[family, default: []].removeAll { $0["id"] as? String == id }
                tables[family, default: []].append(row); persist(); return (200, ["saved": true])
            }
            return (404, ["code": "not_found"])
        }
    }
}
