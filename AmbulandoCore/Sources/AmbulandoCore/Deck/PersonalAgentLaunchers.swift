import Foundation

/// The web's My Agents launchers, read from the existing actor-owned Tower settings route.
public struct PersonalAgentLauncher: Sendable, Equatable, Codable, Identifiable {
    public let npub: String
    public let address: String
    public var id: String { npub }
    public var safeURL: URL? {
        guard let url = URL(string: address), BrowserURLPolicy.decide(url, mainFrame: true) == .load,
              url.scheme == "https" else { return nil }
        return url
    }
    public static func decode(_ data: Data) throws -> [Self] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = object["settings"] as? [String: Any], let rows = settings["autopilot_agents"] as? [[String: Any]] else { throw TowerError.malformed("personal agents") }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let npub = row["agent_npub"] as? String, NostrKeys.isValidNpub(npub), seen.insert(npub).inserted else { return nil }
            return Self(npub: npub, address: row["url"] as? String ?? "")
        }
    }
}

extension WorkspaceSync {
    public static func personalAgentsKey(_ connection: String, _ workspace: String) -> String { "personal-agents:\(connection):\(workspace)" }
    public func refreshPersonalAgentLaunchers(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, force: Bool = false) async {
        let sync = self, key = Self.personalAgentsKey(connection.id, workspace.id)
        await engine.enqueue(key, priority: .visible, force: force) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let client = TowerClient(origin: try TowerOrigin(connection.origin), transport: sync.transport, signer: sync.identity)
            let path = "/api/v4/flightdeck-pg/workspaces/\(try TowerAPI.uuid(workspace.id))/me/autopilot-agents"
            let data = try await client.request(path: path, appNpub: workspace.appNpub)
            let rows = try PersonalAgentLauncher.decode(data)
            try Task.checkCancellation()
            let encoded = try JSONEncoder().encode(rows)
            try await sync.store.writer.setState(key, String(decoding: encoded, as: UTF8.self))
        }
    }
}
