import Foundation

/// Opt-in synthetic read-only briefing transport for native integration checks. Never used for real publication.
public final class SampleBriefingTower: @unchecked Sendable {
    public let workspace: String, scope: String, channel: String, file: String, version: String, author: String, app: String
    private let lock = NSLock()
    private let seededAt = Date()
    private var _unsafe = false, _missingToday = false, _corrupt = false, _duplicate = false, _partial = false, _publicObject = false
    private var reads: [String] = []
    public var unsafe: Bool { get { lock.withLock { _unsafe } } set { lock.withLock { _unsafe = newValue } } }
    public var missingToday: Bool { get { lock.withLock { _missingToday } } set { lock.withLock { _missingToday = newValue } } }
    public var corrupt: Bool { get { lock.withLock { _corrupt } } set { lock.withLock { _corrupt = newValue } } }
    public var duplicate: Bool { get { lock.withLock { _duplicate } } set { lock.withLock { _duplicate = newValue } } }
    public var partial: Bool { get { lock.withLock { _partial } } set { lock.withLock { _partial = newValue } } }
    public var publicObject: Bool { get { lock.withLock { _publicObject } } set { lock.withLock { _publicObject = newValue } } }
    public var paths: [String] { lock.withLock { reads } }
    public init(workspace: String, scope: String, author: String, app: String) {
        self.workspace = workspace; self.scope = scope; self.author = author; self.app = app
        channel = "b11ef000-0000-4000-8000-000000000001"; file = "b11ef000-0000-4000-8000-000000000002"
        version = "b11ef000-0000-4000-8000-000000000003"
    }
    public func response(_ request: URLRequest, owner: String, fallback: (Int, Any)) throws -> (Int, Any) {
        guard let url = request.url, url.path.hasPrefix("/api/v4/flightdeck-pg/workspaces/" + workspace + "/") else { return fallback }
        guard SampleAuth.verify(request, body: request.httpBody ?? Data()) else { return (401, ["code": "unauthorized"]) }
        return try lock.withLock {
            let path = url.path, base = "/api/v4/flightdeck-pg/workspaces/" + workspace
            reads.append(path)
            guard request.httpMethod == "GET" else { return (405, ["code": "read_only_fixture"]) }
            let meta: [String: Any] = ["schema_version": 1, "owner_npub": owner, "author_npub": author]
            let human = "a0000000-0000-4000-8000-0000000000a1", agent = "a0000000-0000-4000-8000-0000000000a2"
            func append(_ key: String, _ rows: [[String: Any]]) -> (Int, Any) {
                var o = fallback.1 as? [String: Any] ?? [:]
                o[key] = (o[key] as? [[String: Any]] ?? []) + rows
                return (200, o)
            }
            if path == base + "/me" {
                var o = fallback.1 as? [String: Any] ?? [:]
                o["identity"] = ["workspace_id": workspace, "app_npub": app, "workspace_owner_npub": owner]; return (200, o)
            }
            if path == base + "/scopes" { return append("scopes", [["id": scope, "workspace_id": workspace, "name": "Briefing sample", "kind": "scope"]]) }
            if path == base + "/scopes/" + scope + "/channels" {
                let c: [String: Any] = ["id": channel, "workspace_id": workspace, "scope_id": scope, "name": "Briefings", "kind": "channel", "metadata": ["system_key": DailyBriefing.systemKey, "briefing": meta]]
                var rows = [c]; if _duplicate { var d = c; d["id"] = human; rows.append(d) }
                return (200, ["channels": rows, "partial": _partial])
            }
            if path == base + "/members" {
                var original = fallback.1 as? [String: Any] ?? [:]
                original["members"] = (original["members"] as? [[String: Any]] ?? []).filter { row in
                    let npub = (row["actor"] as? [String: Any])?["npub"] as? String
                    return npub != owner && npub != author
                }
                let added: [[String: Any]] = [["actor": ["actor_id": human, "npub": owner, "kind": "human", "display_name": "Sample owner"]],
                                          ["actor": ["actor_id": agent, "npub": author, "kind": "agent", "display_name": "Rick"]]]
                original["members"] = (original["members"] as? [[String: Any]] ?? []) + added
                return (200, original)
            }
            if path == base + "/channels/" + channel + "/grants" {
                var rows = [(human, owner, "manage"), (agent, author, "contribute")].map { id, npub, access in
                    ["principal_type": "person", "stored_principal_type": "actor", "principal": ["type": "person", "actor_id": id, "npub": npub], "access_level": access] as [String: Any]
                }
                if _unsafe { rows.append(["principal_type": "group", "principal_id": human, "access_level": "read"]) }
                return (200, ["grants": rows])
            }
            let now = seededAt, yesterday = DailyBriefing.calendar.date(byAdding: .day, value: -1, to: now)!
            func entry(_ date: Date) -> [String: Any] {
                ["generated_at": ISO8601DateFormatter().string(from: date), "paragraphs": ["Synthetic progress overview.", "Synthetic suggested focus."],
                 "links": [["type": "thread", "record_id": human, "channel_id": channel, "label": "Synthetic source conversation"]],
                 "coverage_note": "Synthetic coverage limitation."]
            }
            var entries = [DailyBriefing.day(yesterday): entry(yesterday)]
            if !_missingToday { entries[DailyBriefing.day(now)] = entry(now) }
            let bytes = try rawJSON(["schema": "ambulando.briefing", "schema_version": 1, "workspace_id": workspace, "owner_npub": owner,
                                     "author_npub": author, "timezone": DailyBriefing.timezone, "entries": entries])
            let f: [String: Any] = ["id": file, "workspace_id": workspace, "channel_id": channel, "scope_id": scope, "display_name": "Synthetic briefing",
                                   "content_type": DailyBriefing.mime, "metadata": ["briefing": meta], "current_version_id": version,
                                   "object": ["storage_object": ["is_public": _publicObject, "content_type": DailyBriefing.mime, "size_bytes": bytes.count, "sha256_hex": SHA256Hex.of(bytes)]]]
            if path == base + "/channels/" + channel + "/files" { return (200, ["files": [f], "partial": _partial]) }
            if path == base + "/files/" + file { return (200, ["file": f]) }
            if path == base + "/files/" + file + "/versions/" + version + "/object" { return (200, _corrupt ? Data("bad".utf8) : bytes) }
            return fallback
        }
    }
}
