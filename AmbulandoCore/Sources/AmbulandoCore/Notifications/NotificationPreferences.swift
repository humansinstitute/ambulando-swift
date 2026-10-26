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
    public init() {}

    /// Whether this category shows in the inbox: the most specific stored `inbox` rule, else the registry default.
    public func inboxOn(_ category: NotificationCategoryInfo) -> Bool {
        let matching = rules.filter { $0.channel == "inbox" && $0.sourceAppId == category.sourceAppId && $0.category == category.category }
        if let exact = matching.first(where: { $0.clientAppId == "*" }) { return exact.mode == "on" }
        return category.defaultInbox
    }
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
        return preferences
    }

    /// `PUT …/notifications/rules` with a fresh `mutation_id`; Tower answers with every rule of the caller.
    public func putNotificationRules(workspaceId: String, appNpub: String, mutationId: String, _ rules: [NotificationRule]) async throws -> [NotificationRule] {
        let body = try rawJSON(["mutation_id": mutationId, "rules": rules.map { r -> [String: Any] in
            ["source_app_id": r.sourceAppId, "category": r.category, "client_app_id": r.clientAppId, "channel": r.channel, "mode": r.mode]
        }])
        let (status, data) = try await client.exchange(method: "PUT", path: try Self.notificationsPath(workspaceId) + "/rules", appNpub: appNpub, jsonBody: body)
        guard (200..<300).contains(status) else {
            let failure = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw TowerError.http(status: status, code: failure?["code"] as? String ?? failure?["error"] as? String, stage: "notification preferences")
        }
        return ((try object(data, "notification rules")["rules"] as? [[String: Any]]) ?? []).compactMap(NotificationRule.init(json:))
    }
}
