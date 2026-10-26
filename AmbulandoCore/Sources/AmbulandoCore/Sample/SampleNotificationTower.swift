import Foundation

/// In-process stand-in for Tower's notification inbox of one workspace and one recipient, for sample-data mode and UI
/// automation. It follows the wire contract (`org.wingman.notification.item` v1; items, changes, counts, compare-and-set
/// PATCH, bulk) closely enough to exercise the real client; it is not Tower and says nothing about a live deployment.
public final class SampleNotificationTower: @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL?
    public let workspaceId: String
    private var items: [String: [String: Any]] = [:]
    private var changes: [[String: Any]] = []
    private var mutations: [String: (body: String, item: [String: Any])] = [:]
    private var seq = 0
    private var clock = 0
    private var offered = false

    public init(workspaceId: String, file: URL? = nil) {
        self.workspaceId = workspaceId.lowercased()
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            items = (saved["items"] as? [String: [String: Any]]) ?? [:]
            changes = (saved["changes"] as? [[String: Any]]) ?? []
            seq = (saved["seq"] as? Int) ?? 0
            clock = (saved["clock"] as? Int) ?? 0
            offered = (saved["seeded"] as? Bool) ?? false
        }
    }

    public var seeded: Bool { lock.withLock { offered } }
    public var head: Int { lock.withLock { seq } }

    private func persist() {
        guard let file else { return }
        let state: [String: Any] = ["items": items, "changes": changes, "seq": seq, "clock": clock, "seeded": offered]
        if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: file, options: .atomic) }
    }

    private func stamp() -> String {
        clock += 1
        return String(format: "2026-10-26T12:%02d:%02dZ", (clock / 60) % 60, clock % 60)
    }

    public enum Kind: Sendable {
        case thread(channel: String, thread: String)
        case task(String)
        case doc(String)
        case appObject(app: String, label: String)
    }

    /// Adds an unread notification (an event projected for the recipient).
    @discardableResult
    public func add(category: String, title: String, body: String, kind: Kind, read: Bool = false, updates: Int = 1) -> String {
        lock.withLock {
            let id = UUID().uuidString.lowercased()
            seq += 1
            var subject: [String: Any] = ["kind": "thread", "activity_version": 3]
            let target: [String: Any]
            var source: [String: Any] = ["app_id": "flightdeck.core", "label": "Flight Deck", "kind": "tower_rule"]
            switch kind {
            case .thread(let channel, let thread):
                subject["thread_id"] = thread; subject["channel_id"] = channel
                target = ["kind": "thread", "channel_id": channel, "thread_id": thread]
            case .task(let task):
                subject["kind"] = "task"; subject["task_id"] = task
                target = ["kind": "task", "task_id": task]
            case .doc(let doc):
                subject["kind"] = "doc"; subject["doc_id"] = doc
                target = ["kind": "doc", "doc_id": doc]
            case .appObject(let app, let label):
                subject = ["kind": "app_object", "activity_version": NSNull()]
                source = ["app_id": app, "label": label, "kind": "app"]
                target = ["kind": "app_object", "app_id": app, "object_type": "capture", "object_id": "c-1"]
            }
            let now = stamp()
            let item: [String: Any] = [
                "schema": "org.wingman.notification.item", "version": 1, "id": id, "workspace_id": workspaceId, "recipient_actor_id": "f1c70000-0000-4000-8000-0000000000aa",
                "change_seq": seq, "row_version": 1, "source": source, "category": category, "reasons": [category], "severity": "normal",
                "status": "active", "origin": "live", "group": ["key": "\(category):\(id)", "event_count": updates], "subject": subject,
                "presentation": ["title": title, "body": body, "icon": category, "push_preview": "generic"],
                "action": ["type": "open", "target": target], "audience": ["client_apps": ["*"]],
                "occurred_at": now, "updated_at": now,
                "state": ["read": read, "read_at": NSNull(), "read_reason": NSNull(), "dismissed": false, "archived": false], "access": "ok",
            ]
            items[id] = item
            changes.append(item)
            persist()
            return id
        }
    }

    public func markSeeded() { lock.withLock { offered = true; persist() } }

    /// Newer activity folded into an open item (unread again, one more update).
    public func fold(_ id: String, body: String) {
        lock.withLock {
            guard var item = items[id] else { return }
            seq += 1
            var group = item["group"] as? [String: Any] ?? [:]
            group["event_count"] = ((group["event_count"] as? Int) ?? 1) + 1
            var subject = item["subject"] as? [String: Any] ?? [:]
            subject["activity_version"] = ((subject["activity_version"] as? Int) ?? 0) + 1
            var presentation = item["presentation"] as? [String: Any] ?? [:]
            presentation["body"] = body
            var state = item["state"] as? [String: Any] ?? [:]
            state["read"] = false
            item["group"] = group; item["subject"] = subject; item["presentation"] = presentation; item["state"] = state
            item["row_version"] = ((item["row_version"] as? Int) ?? 1) + 1
            item["change_seq"] = seq
            item["updated_at"] = stamp()
            items[id] = item
            changes.append(item)
            persist()
        }
    }

    /// Access to the subject was lost: a content-free tombstone replaces the item.
    public func revoke(_ id: String) {
        lock.withLock {
            guard items[id] != nil else { return }
            seq += 1
            items[id] = nil
            changes.append(["schema": "org.wingman.notification.tombstone", "version": 1, "id": id, "workspace_id": workspaceId, "change_seq": seq,
                            "change_type": "remove", "removal_reason": "access_lost"])
            persist()
        }
    }

    public var titles: [String] { lock.withLock { items.values.compactMap { ($0["presentation"] as? [String: Any])?["title"] as? String } } }

    // MARK: Routes

    public func handle(_ request: URLRequest) throws -> (Int, Any)? {
        guard let url = request.url else { return nil }
        let base = "/api/v4/flightdeck-pg/workspaces/\(workspaceId)/notifications"
        guard url.path == base || url.path.hasPrefix(base + "/") else { return nil }
        let tail = String(url.path.dropFirst(base.count))
        let method = request.httpMethod ?? "GET"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        return lock.withLock {
            defer { persist() }
            func state(_ item: [String: Any]) -> [String: Any] { item["state"] as? [String: Any] ?? [:] }
            switch (method, tail) {
            case ("GET", "/items"):
                let wanted = q("view") ?? "inbox"
                let live = items.values.filter { item in
                    let s = state(item)
                    if wanted == "archived" { return s["archived"] as? Bool == true && s["dismissed"] as? Bool != true }
                    return s["dismissed"] as? Bool != true && s["archived"] as? Bool != true
                }.sorted { (($0["occurred_at"] as? String ?? ""), ($0["id"] as? String ?? "")) > (($1["occurred_at"] as? String ?? ""), ($1["id"] as? String ?? "")) }
                let limit = min(Int(q("limit") ?? "50") ?? 50, 100)
                let offset = q("cursor").flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
                let page = Array(live.dropFirst(offset).prefix(limit))
                let next: Any = offset + limit < live.count ? Data(String(offset + limit).utf8).base64EncodedString() : NSNull()
                return (200, ["items": page, "next_cursor": next, "head_seq": seq, "inbox_started_at": "2026-10-26T11:00:00Z"])
            case ("GET", "/changes"):
                let after = Int(q("after_seq") ?? "0") ?? 0
                let limit = min(Int(q("limit") ?? "200") ?? 200, 200)
                let pending = changes.filter { ($0["change_seq"] as? Int ?? 0) > after }
                let page = Array(pending.prefix(limit))
                return (200, ["changes": page, "through_seq": (page.last?["change_seq"] as? Int) ?? after, "head_seq": seq, "has_more": pending.count > page.count])
            case ("GET", "/counts"):
                let unread = items.values.filter { s in let st = state(s); return st["read"] as? Bool != true && st["dismissed"] as? Bool != true && st["archived"] as? Bool != true }
                var byCategory: [String: Int] = [:]
                for item in unread { byCategory[item["category"] as? String ?? "unknown", default: 0] += 1 }
                return (200, ["unread_total": unread.count, "by_category": byCategory, "badge": unread.count, "capped_at": 999, "head_seq": seq,
                              "inbox_started_at": "2026-10-26T11:00:00Z"])
            case ("GET", "/categories"):
                let core: [[String: Any]] = [("chat_thread", "Conversations", false), ("mention", "Mentions", false), ("dm", "Direct messages", false),
                                             ("comment_tag", "Comment tags", false), ("task_assignment", "Task assignments", false)].map {
                    ["category": $0.0, "label": $0.1, "default_severity": "normal", "default_inbox": "on", "default_alert": $0.0 == "chat_thread" ? "off" : "on",
                     "mandatory": $0.2, "grouping": "subject"]
                }
                return (200, ["sources": [["app_id": "flightdeck.core", "label": "Flight Deck", "kind": "tower_rule", "categories": core]]])
            case ("GET", "/rules"):
                return (200, ["rules": (state2["rules"] as? [[String: Any]]) ?? []])
            case ("PUT", "/rules"):
                var rules = (state2["rules"] as? [[String: Any]]) ?? []
                for rule in (body["rules"] as? [[String: Any]]) ?? [] {
                    rules.removeAll { $0["source_app_id"] as? String == rule["source_app_id"] as? String && $0["category"] as? String == rule["category"] as? String
                        && $0["channel"] as? String == rule["channel"] as? String }
                    var stored = rule; stored["row_version"] = 1
                    rules.append(stored)
                }
                state2["rules"] = rules
                return (200, ["rules": rules])
            case ("PATCH", _) where tail.hasPrefix("/items/"):
                let id = String(tail.dropFirst(7))
                guard var item = items[id] else { return (404, ["error": "notification_not_found", "code": "notification_not_found"]) }
                let mutation = body["mutation_id"] as? String ?? ""
                let signature = String(data: (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
                if let known = mutations[mutation] {
                    return known.body == signature ? (200, ["item": known.item]) : (409, ["error": "mutation_id_reused", "code": "mutation_id_reused"])
                }
                let stale = body["expected_row_version"] as? Int != item["row_version"] as? Int
                let overtaken = (body["observed_change_seq"] as? Int).map { $0 < (item["change_seq"] as? Int ?? 0) } ?? false
                guard !stale, !overtaken else { return (409, ["error": "state_conflict", "code": "state_conflict", "item": item]) }
                let patch = body["patch"] as? [String: Any] ?? [:]
                item = apply(patch, to: item)
                mutations[mutation] = (signature, item)
                return (200, ["item": item])
            case ("POST", "/bulk"):
                let selector = body["selector"] as? [String: Any] ?? [:]
                let upTo = selector["up_to_seq"] as? Int ?? Int.max
                let ids = selector["ids"] as? [String]
                var affected = 0
                for (id, item) in items where (ids?.contains(id) ?? true) && (item["change_seq"] as? Int ?? 0) <= upTo {
                    let s = state(item)
                    if s["read"] as? Bool != true, s["dismissed"] as? Bool != true, s["archived"] as? Bool != true { items[id] = apply(["read": true], to: item); affected += 1 }
                }
                return (200, ["affected": affected, "through_seq": seq, "mutation_id": body["mutation_id"] as? String ?? ""])
            default:
                return (404, ["error": "not_found", "code": "not_found"])
            }
        }
    }

    private var state2: [String: Any] = [:]

    private func apply(_ patch: [String: Any], to source: [String: Any]) -> [String: Any] {
        var item = source
        var state = item["state"] as? [String: Any] ?? [:]
        if let read = patch["read"] as? Bool { state["read"] = read }
        if let dismissed = patch["dismissed"] as? Bool { state["dismissed"] = dismissed; if dismissed { state["read"] = true } }
        if let archived = patch["archived"] as? Bool { state["archived"] = archived; if archived { state["read"] = true } }
        seq += 1
        item["state"] = state
        item["row_version"] = ((item["row_version"] as? Int) ?? 1) + 1
        item["change_seq"] = seq
        changes.append(item)
        items[item["id"] as! String] = item
        return item
    }
}
