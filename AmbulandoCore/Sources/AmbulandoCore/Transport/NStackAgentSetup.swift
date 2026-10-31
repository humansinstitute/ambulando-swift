import Foundation

/// Ephemeral setup choices. Only selected public installation/agent fields are persisted by Tower.
public struct NStackAgentChoice: Sendable, Equatable, Identifiable, Decodable {
    public let agent_id: String
    public let bot_npub: String
    public let name: String
    public let description: String
    public let can_instruct: Bool
    public let paths: [String: String]
    public var id: String { agent_id }
}
public struct NStackAgentSetup: Sendable {
    public let towerOrigin: TowerOrigin
    public let signerNpub: String
    public let endpoint: TowerOrigin
    public let installationId: String
    public let installationNpub: String
    public let owner: String
    public let workspaceId: String
    public let appNpub: String
    public let agents: [NStackAgentChoice]
}

extension WorkspaceSync {
    public func discoverNStackAgents(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord) async throws -> NStackAgentSetup {
        try await identity.requireReader(npub: connection.signerNpub)
        let tower = api(origin: try TowerOrigin(connection.origin)).client
        let descriptor = try await TowerAPI(client: tower).descriptor()
        guard let owner = workspace.ownerNpub, NostrKeys.isValidNpub(owner), NostrKeys.isValidNpub(workspace.appNpub) else { throw TowerError.descriptor("Select a verified Ambulando workspace first") }
        let registration = try await tower.request(path: "/api/v4/flightdeck-pg/workspaces/\(try TowerAPI.uuid(workspace.id))/app-registration", appNpub: workspace.appNpub)
        let object = try JSONSerialization.jsonObject(with: registration) as? [String: Any]
        guard let registeredIdentity = object?["identity"] as? [String: Any], registeredIdentity["workspace_id"] as? String == workspace.id,
              registeredIdentity["workspace_owner_npub"] as? String == owner, registeredIdentity["app_npub"] as? String == workspace.appNpub,
              connection.towerNpub == nil || registeredIdentity["tower_service_npub"] as? String == connection.towerNpub,
              let app = object?["registration"] as? [String: Any], app["installed"] as? Bool == true,
              app["enabled"] as? Bool == true, app["app_npub"] as? String == workspace.appNpub else {
            throw TowerError.descriptor("Ambulando is not registered and enabled. Ask the workspace owner to install or enable it")
        }
        let services = descriptor.services.filter { $0.kind == "autopilot" }
        guard services.count == 1, let address = services.first?.endpoint else {
            throw TowerError.descriptor("Expected one advertised Autopilot HTTPS service. Ask the operator to configure NSTACK_AUTOPILOT_PUBLIC_ORIGIN on Tower")
        }
        let endpoint = try TowerOrigin(address)
        let client = TowerClient(origin: endpoint, transport: transport, signer: identity)
        let base = "/api/owners/\(owner)/control-plane/v1"
        let health = try JSONSerialization.jsonObject(with: await client.request(path: base + "/health")) as? [String: Any]
        guard health?["ok"] as? Bool == true, health?["api_version"] as? Int == 1,
              let npub = health?["installation_npub"] as? String, NostrKeys.isValidNpub(npub),
              let installation = health?["installation_id"] as? String,
              let publicKey = NostrKeys.publicKeyHex(npub: npub), installation == "autopilot_" + String(SHA256Hex.of(publicKey).prefix(32)) else { throw TowerError.malformed("Autopilot installation health") }
        struct Agents: Decodable { let installation_id: String; let agents: [NStackAgentChoice] }
        let choices = try JSONDecoder().decode(Agents.self, from: await client.request(path: base + "/agents"))
        guard choices.installation_id == installation,
              choices.agents.allSatisfy({ NostrKeys.isValidNpub($0.bot_npub) && !$0.agent_id.isEmpty }) else { throw TowerError.malformed("Autopilot agent identity") }
        return NStackAgentSetup(towerOrigin: try TowerOrigin(connection.origin), signerNpub: connection.signerNpub, endpoint: endpoint, installationId: installation, installationNpub: npub, owner: owner,
                                workspaceId: workspace.id, appNpub: workspace.appNpub, agents: choices.agents)
    }

    public func installNStackAgents(_ setup: NStackAgentSetup, selected: Set<String>, connection: ConnectionRecord, workspace: WorkspaceRecord) async throws {
        guard setup.towerOrigin == (try TowerOrigin(connection.origin)), setup.signerNpub == connection.signerNpub, setup.workspaceId == workspace.id, setup.owner == workspace.ownerNpub, setup.appNpub == workspace.appNpub else { throw TowerError.malformed("changed workspace selection") }
        guard !selected.isEmpty, selected.isSubset(of: Set(setup.agents.map(\.id))) else { throw TowerError.descriptor("Select at least one agent") }
        try await identity.requireReader(npub: connection.signerNpub)
        let client = api(origin: try TowerOrigin(connection.origin)).client
        let base = try TowerAPI.base(workspace.id)
        let ownerBase = "/api/owners/\(setup.owner)/control-plane/v1"
        let address = setup.endpoint.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let body: [String: Any] = ["installation_id": setup.installationId, "display_name": "Autopilot", "fips_endpoint": address,
            "https_endpoint": address, "api_version": "1", "capabilities": ["health", "agents.read"],
            "metadata": ["transport_mode": "https", "installation_npub": setup.installationNpub,
                         "health_path": ownerBase + "/health", "agents_path": ownerBase + "/agents", "connect_package_version": 0]]
        let response = try await client.request(method: "POST", path: base + "/autopilot-connections", appNpub: workspace.appNpub, jsonBody: rawJSON(body))
        let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
        guard let record = object?["autopilot_connection"] as? [String: Any], let id = record["id"] as? String, UUID(uuidString: id) != nil else { throw TowerError.malformed("saved Autopilot connection") }
        if (record["metadata"] as? [String: Any])?["transport_mode"] as? String != "https" {
            var metadata = record["metadata"] as? [String: Any] ?? [:]
            metadata["transport_mode"] = "https"; metadata["installation_npub"] = setup.installationNpub
            metadata["health_path"] = ownerBase + "/health"; metadata["agents_path"] = ownerBase + "/agents"
            let update: [String: Any] = ["row_version": record["row_version"] ?? 0, "https_endpoint": address, "metadata": metadata]
            _ = try await client.request(method: "PATCH", path: base + "/autopilot-connections/" + id,
                                         appNpub: workspace.appNpub, jsonBody: rawJSON(update))
        }
        for (index, agent) in setup.agents.filter({ selected.contains($0.id) }).enumerated() {
            let payload: [String: Any] = ["connection_id": id, "agent_id": agent.id, "agent_npub": agent.bot_npub,
                "display_name": agent.name, "capabilities": [String](), "sort_order": index, "is_visible": true,
                "metadata": ["description": agent.description, "can_instruct": agent.can_instruct, "paths": agent.paths]]
            _ = try await client.request(method: "POST", path: base + "/workspace-agents", appNpub: workspace.appNpub, jsonBody: rawJSON(payload))
        }
        await refreshAgents(connection, workspace, channelIds: [], force: true)
    }
}
