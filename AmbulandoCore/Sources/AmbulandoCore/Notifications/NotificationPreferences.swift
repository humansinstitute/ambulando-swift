import Foundation

/// What Tower's notification registry and this person's rules say. Server truth, read when Settings opens and written
/// through the same adapter as everything else; nothing here is cached as authority on the device.
public struct NotificationCategoryInfo: Sendable, Equatable, Identifiable {
    public let sourceAppId: String
    public let sourceLabel: String
    public let category: String
    public let label: String
    public let mandatory: Bool
    public let defaultInbox: Bool
    public var id: String { sourceAppId + "|" + category }
}

public struct NotificationRule: Sendable, Equatable {
    public let sourceAppId: String
    public let category: String
    public let clientAppId: String
    public let channel: String       // inbox | alert
    public let mode: String          // on | off
    public let rowVersion: Int?

    public init(sourceAppId: String, category: String, clientAppId: String = "*", channel: String, mode: String, rowVersion: Int? = nil) {
        self.sourceAppId = sourceAppId; self.category = category; self.clientAppId = clientAppId
        self.channel = channel; self.mode = mode; self.rowVersion = rowVersion
    }

    init?(json o: [String: Any]) {
        guard let source = o["source_app_id"] as? String, let category = o["category"] as? String, let channel = o["channel"] as? String,
              let mode = o["mode"] as? String else { return nil }
        self.init(sourceAppId: source, category: category, clientAppId: (o["client_app_id"] as? String) ?? "*", channel: channel, mode: mode,
                  rowVersion: flexibleInt(o["row_version"]))
    }
}

public struct NotificationPreferences: Sendable, Equatable {
    public var categories: [NotificationCategoryInfo] = []
    public var rules: [NotificationRule] = []
    /// Bumped by Tower on every rules write; the inbox snapshot is kept under one value of it.
    public var rulesRevision: Int?
    public init() {}

    /// Whether this category shows in this app's inbox view: Ambulando's own rule for the exact category beats the shared
    /// (`*`) one, `default` (an inherited row kept for its revision) is skipped, `off` wins; else the registry default.
    public func inboxOn(_ category: NotificationCategoryInfo, clientAppId: String = TowerAPI.notificationClientAppId) -> Bool {
        let matching = rules.filter { $0.channel == "inbox" && $0.sourceAppId == category.sourceAppId && $0.category == category.category && $0.mode != "default" }
        if let own = matching.first(where: { $0.clientAppId == clientAppId }) { return own.mode == "on" }
        if let shared = matching.first(where: { $0.clientAppId == "*" }) { return shared.mode == "on" }
        return category.defaultInbox
    }

    /// The revision of the exact key, or 0 when this device has never seen it (the compare-and-set base).
    public func rowVersion(source: String, category: String, clientAppId: String, channel: String) -> Int {
        rules.first { $0.sourceAppId == source && $0.category == category && $0.clientAppId == clientAppId && $0.channel == channel }?.rowVersion ?? 0
    }
}

/// Why a rules write did not apply.
public enum NotificationRulesWrite: Sendable, Equatable {
    case applied(rules: [NotificationRule], rulesRevision: Int?)
    /// `409 rules_conflict`: nothing was written; these are the current rules to rebase on.
    case conflict(rules: [NotificationRule], rulesRevision: Int?)
    /// `409 mutation_id_reused`: a rejection of this request (not a replay).
    case mutationReused
}

extension TowerAPI {
    public func notificationPreferences(workspaceId: String, appNpub: String) async throws -> NotificationPreferences {
        let base = try Self.notificationsPath(workspaceId)
        var preferences = NotificationPreferences()
        let registry = try object(try await client.request(path: base + "/categories", appNpub: appNpub), "notification categories")
        for source in (registry["sources"] as? [[String: Any]]) ?? [] {
            guard let appId = source["app_id"] as? String else { continue }
            let label = (source["label"] as? String) ?? appId
            for c in (source["categories"] as? [[String: Any]]) ?? [] {
                guard let category = c["category"] as? String else { continue }
                preferences.categories.append(NotificationCategoryInfo(
                    sourceAppId: appId, sourceLabel: label, category: category, label: (c["label"] as? String) ?? NotificationCategories.label(category),
                    mandatory: (c["mandatory"] as? Bool) ?? false, defaultInbox: ((c["default_inbox"] as? String) ?? "on") != "off"))
            }
        }
        let rules = try object(try await client.request(path: base + "/rules", appNpub: appNpub), "notification rules")
        preferences.rules = ((rules["rules"] as? [[String: Any]]) ?? []).compactMap(NotificationRule.init(json:))
        preferences.rulesRevision = flexibleInt(rules["rules_revision"])
        return preferences
    }

    /// `PUT …/notifications/rules`: all-or-nothing, each entry compare-and-set on its exact key's `expected_row_version`
    /// (0 only when absent). `mode: "default"` keeps the row and bumps its revision; a key is never deleted.
    public func putNotificationRules(workspaceId: String, appNpub: String, mutationId: String, _ entries: [(rule: NotificationRule, expectedRowVersion: Int)]) async throws -> NotificationRulesWrite {
        let body = try rawJSON(["mutation_id": mutationId, "rules": entries.map { e -> [String: Any] in
            ["source_app_id": e.rule.sourceAppId, "category": e.rule.category, "client_app_id": e.rule.clientAppId, "channel": e.rule.channel,
             "mode": e.rule.mode, "expected_row_version": e.expectedRowVersion]
        }])
        let (status, data) = try await client.exchange(method: "PUT", path: try Self.notificationsPath(workspaceId) + "/rules", appNpub: appNpub, jsonBody: body)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = o["code"] as? String ?? o["error"] as? String
        func parsed() -> [NotificationRule] { ((o["rules"] as? [[String: Any]]) ?? []).compactMap(NotificationRule.init(json:)) }
        switch status {
        case 200..<300: return .applied(rules: parsed(), rulesRevision: flexibleInt(o["rules_revision"]))
        case 409 where code == "rules_conflict": return .conflict(rules: parsed(), rulesRevision: flexibleInt(o["rules_revision"]))
        case 409 where code == "mutation_id_reused": return .mutationReused
        default: throw TowerError.http(status: status, code: code, stage: "notification preferences")
        }
    }
}
