import Foundation

/// Tower's notification inbox routes (`/api/v4/flightdeck-pg/workspaces/:w/notifications/…`). Every request is an
/// ordinary NIP-98 call made with the user's own identity; the inbox is the caller's alone. This file is the only place
/// that knows the wire shapes, so a contract change is a change here.
extension TowerAPI {
    public static let notificationPageLimit = 50
    public static let notificationChangeLimit = 200

    public enum NotificationReply: Sendable, Equatable {
        case item(NotificationItem)
        /// Someone (this user on another device) changed the item first; `item` is the current state.
        case stateConflict(NotificationItem?)
        /// Tower saw this `mutation_id` before with a different request: a rejection of *this* action, not a replay.
        /// (An identical retry is answered `200` with the original item.)
        case mutationIdReused
        case gone
        /// Other refusal (permission, malformed, server error): the HTTP status and Tower's error code.
        case refused(status: Int, code: String?)
    }

    public struct NotificationPage: Sendable {
        public let items: [NotificationItem]
        public let nextCursor: String?
        public let headSeq: Int
        public let counts: NotificationCounts?
        /// When Tower started this person's inbox (`inbox_started_at`); nothing older is ever imported.
        public let inboxStartedAt: String?
        /// Rows that were not valid items for this workspace and were skipped.
        public let skipped: Int
    }

    public struct NotificationChangePage: Sendable {
        public let changes: [NotificationChange]
        public let throughSeq: Int
        public let headSeq: Int
        public let hasMore: Bool
        public let skipped: Int
    }

    /// Why a notification read could not continue.
    public enum NotificationReadFailure: Error, Equatable, Sendable {
        /// 404/501: the Tower does not have the notification inbox.
        case unsupported
        /// 403: the workspace no longer lets this identity read.
        case forbidden
        /// 410 `reset_required`: the saved sequence is older than Tower keeps; list the inbox again.
        case resetRequired
    }

    static func notificationsPath(_ workspaceId: String) throws -> String { try base(workspaceId) + "/notifications" }

    private func notificationRead(_ path: String, query: [URLQueryItem], appNpub: String) async throws -> [String: Any] {
        let (status, body) = try await client.exchange(method: "GET", path: path, appNpub: appNpub, jsonBody: nil, query: query)
        switch status {
        case 200..<300: return try object(body, "notifications")
        case 404, 501: throw NotificationReadFailure.unsupported
        case 403: throw NotificationReadFailure.forbidden
        case 410: throw NotificationReadFailure.resetRequired
        default:
            let failure = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if status == 400, failure?["error"] as? String == "invalid_cursor" || failure?["code"] as? String == "invalid_cursor" {
                throw NotificationReadFailure.resetRequired
            }
            throw TowerError.http(status: status, code: failure?["code"] as? String ?? failure?["error"] as? String, stage: "notifications")
        }
    }

    /// `GET …/notifications/items?view=&limit=&cursor=` — newest first. `head_seq` is read in the same snapshot as the
    /// first page and is the sequence to replay from after listing.
    public func notificationItems(workspaceId: String, appNpub: String, view: String = "inbox", cursor: String? = nil,
                                  limit: Int = TowerAPI.notificationPageLimit) async throws -> NotificationPage {
        var query = [URLQueryItem(name: "view", value: view), URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200)))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let o = try await notificationRead(try Self.notificationsPath(workspaceId) + "/items", query: query, appNpub: appNpub)
        guard let rows = o["items"] as? [[String: Any]] else { throw TowerError.malformed("notifications") }
        let items = rows.compactMap { NotificationItem(json: $0, workspaceId: workspaceId) }
        let next = (o["next_cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return NotificationPage(items: items, nextCursor: next, headSeq: flexibleInt(o["head_seq"]) ?? 0,
                                counts: (o["counts"] as? [String: Any]).flatMap(NotificationCounts.init(json:)),
                                inboxStartedAt: o["inbox_started_at"] as? String, skipped: rows.count - items.count)
    }

    /// `GET …/notifications/changes?after_seq=&limit=` — ascending, including state transitions and tombstones.
    /// `through_seq` is the last sequence actually delivered in this page (never the head).
    public func notificationChanges(workspaceId: String, appNpub: String, afterSeq: Int,
                                    limit: Int = TowerAPI.notificationChangeLimit) async throws -> NotificationChangePage {
        let query = [URLQueryItem(name: "after_seq", value: String(afterSeq)), URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200)))]
        let o = try await notificationRead(try Self.notificationsPath(workspaceId) + "/changes", query: query, appNpub: appNpub)
        guard let rows = o["changes"] as? [[String: Any]], let through = flexibleInt(o["through_seq"]) else { throw TowerError.malformed("notification changes") }
        let changes = rows.compactMap { NotificationChange(json: $0, workspaceId: workspaceId) }
        return NotificationChangePage(changes: changes, throughSeq: through, headSeq: flexibleInt(o["head_seq"]) ?? through,
                                      hasMore: (o["has_more"] as? Bool) ?? false, skipped: rows.count - changes.count)
    }

    /// `GET …/notifications/counts`.
    public func notificationCounts(workspaceId: String, appNpub: String) async throws -> NotificationCounts {
        let o = try await notificationRead(try Self.notificationsPath(workspaceId) + "/counts", query: [], appNpub: appNpub)
        guard let counts = NotificationCounts(json: (o["counts"] as? [String: Any]) ?? o) else { throw TowerError.malformed("notification counts") }
        return counts
    }

    /// `PATCH …/notifications/items/:id` with `{mutation_id, expected_row_version, patch}`. Tower replays a known
    /// `mutation_id`, so resending after a lost reply is safe.
    public func patchNotification(workspaceId: String, appNpub: String, id: String, mutationId: String, expectedRowVersion: Int,
                                  observedChangeSeq: Int?, read: Bool?, dismissed: Bool?, archived: Bool?) async throws -> NotificationReply {
        var patch: [String: Any] = [:]
        if let read { patch["read"] = read }
        if let dismissed { patch["dismissed"] = dismissed }
        if let archived { patch["archived"] = archived }
        var request: [String: Any] = ["mutation_id": mutationId, "expected_row_version": expectedRowVersion, "patch": patch]
        // The sequence the person actually saw: Tower refuses (409) if the item changed since, so activity that arrived
        // after the screen was drawn is never marked read, dismissed or archived by a stale tap.
        if let observedChangeSeq { request["observed_change_seq"] = observedChangeSeq }
        let body = try rawJSON(request)
        let (status, data) = try await client.exchange(method: "PATCH", path: try Self.notificationsPath(workspaceId) + "/items/" + Self.uuid(id),
                                                       appNpub: appNpub, jsonBody: body)
        return Self.notificationReply(workspaceId: workspaceId, status: status, data: data)
    }

    public enum NotificationBulkOutcome: Sendable, Equatable {
        case done(affected: Int, throughSeq: Int?)
        case refused(NotificationReply)
    }

    /// `POST …/notifications/bulk`. A selector either names ids (≤ 200) or `up_to_seq`, so only what the user has
    /// actually been shown is changed; items that arrived after that sequence stay unread.
    public func bulkNotifications(workspaceId: String, appNpub: String, mutationId: String, op: String, ids: [String]?, upToSeq: Int?,
                                  view: String? = nil, category: String? = nil) async throws -> NotificationBulkOutcome {
        var selector: [String: Any] = [:]
        if let ids { selector["ids"] = ids }
        if let upToSeq { selector["up_to_seq"] = upToSeq }
        if let view { selector["view"] = view }
        if let category { selector["category"] = category }
        let body = try rawJSON(["mutation_id": mutationId, "op": op, "selector": selector])
        let (status, data) = try await client.exchange(method: "POST", path: try Self.notificationsPath(workspaceId) + "/bulk", appNpub: appNpub, jsonBody: body)
        if (200..<300).contains(status), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return .done(affected: flexibleInt(o["affected"]) ?? 0, throughSeq: flexibleInt(o["through_seq"]))
        }
        return .refused(Self.notificationReply(workspaceId: workspaceId, status: status, data: data))
    }

    static func notificationReply(workspaceId: String, status: Int, data: Data) -> NotificationReply {
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = o["error"] as? String ?? o["code"] as? String
        let item = (o["item"] as? [String: Any]).flatMap { NotificationItem(json: $0, workspaceId: workspaceId) }
        switch status {
        case 200..<300:
            if let item { return .item(item) }
            return .refused(status: status, code: "malformed_reply")
        case 409:
            if code == "mutation_id_reused" { return .mutationIdReused }
            return .stateConflict(item)
        case 404, 410: return .gone
        default: return .refused(status: status, code: code)
        }
    }
}
