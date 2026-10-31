import Foundation
import XCTest
@testable import AmbulandoCore

final class NStackAgentSetupTests: XCTestCase {
    func testHTTPSDiscoveryVerifiesRegistrationAndUsesOwnerSignaturesWithFIPSAbsent() async throws {
        let identity = try await makeIdentity()
        let store = try LocalStore(directory: temporaryDirectory())
        let installation = "autopilot_" + SHA256Hex.of(TestKeys.pubkeyHex).prefix(32)
        let transport = StubTransport { request in
            let path = request.url!.path
            if path == "/.well-known/nstack.json" {
                var descriptor = Fixtures.descriptor(origin: "https://tower.example")
                var services = descriptor["services"] as! [[String: Any]]
                services.append(["id": "autopilot", "kind": "autopilot", "endpoint": "https://agents.example"])
                descriptor["services"] = services
                return (200, descriptor)
            }
            let auth = try decodeAuthorization(request)
            XCTAssertTrue(SignatureVerifier.verify(auth))
            XCTAssertEqual(auth.tags.first, ["u", request.url!.absoluteString])
            if path.hasSuffix("/app-registration") { return (200, ["identity": ["workspace_id": Fixtures.workspaceId, "workspace_owner_npub": TestKeys.npub, "app_npub": Fixtures.appNpub], "registration": ["installed": true, "enabled": true, "app_npub": Fixtures.appNpub]]) }
            XCTAssertEqual(request.url?.host, "agents.example")
            if path.hasSuffix("/health") { return (200, ["ok": true, "api_version": 1, "installation_id": installation, "installation_npub": TestKeys.npub]) }
            return (200, ["installation_id": installation, "agents": [["agent_id": "fixture", "bot_npub": TestKeys.npub, "name": "Fixture Agent", "description": "Local fixture", "can_instruct": true, "paths": [:]]]])
        }
        let sync = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity, transport: transport)
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let workspace = WorkspaceRecord(id: Fixtures.workspaceId, appNpub: Fixtures.appNpub, label: "Studio", slug: nil, towerBaseURL: "https://tower.example", role: "owner", ownerNpub: TestKeys.npub, raw: Data())
        let setup = try await sync.discoverNStackAgents(connection, workspace)
        XCTAssertEqual(setup.agents.map(\.id), ["fixture"])
        XCTAssertEqual(setup.endpoint.description, "https://agents.example")
        let wrongConnection = ConnectionRecord(origin: try TowerOrigin("https://other.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        do { try await sync.installNStackAgents(setup, selected: ["fixture"], connection: wrongConnection, workspace: workspace); XCTFail("cross-Tower install") } catch { }
        XCTAssertEqual(transport.recorded.count, 4)
        XCTAssertTrue(transport.recorded.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertThrowsError(try TowerOrigin("http://anything.fips:1234"))
    }

    func testForgedOrUnregisteredLocatorAppStopsBeforeAutopilot() async throws {
        let identity = try await makeIdentity()
        let store = try LocalStore(directory: temporaryDirectory())
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let workspace = WorkspaceRecord(id: Fixtures.workspaceId, appNpub: Fixtures.appNpub, label: "Studio", slug: nil,
            towerBaseURL: "https://tower.example", role: "member", ownerNpub: TestKeys.npub, raw: Data())
        for mode in ["missing", "wrong-app", "wrong-workspace", "wrong-owner", "ambiguous-service"] {
            let transport = StubTransport { request in
                if request.url!.path == "/.well-known/nstack.json" {
                    var descriptor = Fixtures.descriptor(origin: "https://tower.example")
                    if mode == "ambiguous-service" {
                        var services = descriptor["services"] as! [[String: Any]]
                        services += [["id": "one", "kind": "autopilot", "endpoint": "https://one.example"], ["id": "two", "kind": "autopilot", "endpoint": "https://two.example"]]
                        descriptor["services"] = services
                    }
                    return (200, descriptor)
                }
                XCTAssertTrue(request.url!.path.hasSuffix("/app-registration"))
                return (200, ["identity": ["workspace_id": mode == "wrong-workspace" ? UUID().uuidString : Fixtures.workspaceId,
                    "workspace_owner_npub": mode == "wrong-owner" ? Fixtures.appNpub : TestKeys.npub,
                    "app_npub": mode == "wrong-app" ? TestKeys.npub : Fixtures.appNpub],
                    "registration": ["installed": mode != "missing", "enabled": true, "app_npub": Fixtures.appNpub]])
            }
            let sync = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity, transport: transport)
            do { _ = try await sync.discoverNStackAgents(connection, workspace); XCTFail(mode) } catch { }
            XCTAssertEqual(transport.recorded.count, 2, mode)
        }
    }

    func testAddOverHTTPSKeepsFIPSMetadataAndMaterializesOneAgentAcrossRetries() async throws {
        let identity = try await makeIdentity()
        let store = try LocalStore(directory: temporaryDirectory())
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let workspace = WorkspaceRecord(id: Fixtures.workspaceId, appNpub: Fixtures.appNpub, label: "Studio", slug: nil,
            towerBaseURL: "https://tower.example", role: "owner", ownerNpub: TestKeys.npub, raw: Data())
        let choice = try JSONDecoder().decode(NStackAgentChoice.self, from: Fixtures.json(["agent_id": "fixture",
            "bot_npub": TestKeys.npub, "name": "Fixture Agent", "description": "Local fixture", "can_instruct": true, "paths": [:]]))
        let setup = NStackAgentSetup(towerOrigin: try TowerOrigin(connection.origin), signerNpub: TestKeys.npub,
            endpoint: try TowerOrigin("https://agents.example"), installationId: "autopilot_" + SHA256Hex.of(TestKeys.pubkeyHex).prefix(32),
            installationNpub: TestKeys.npub, owner: TestKeys.npub, workspaceId: workspace.id, appNpub: workspace.appNpub, agents: [choice])
        let connectionID = "50000000-0000-4000-8000-000000000001"
        let agentID = "50000000-0000-4000-8000-000000000002"
        let transport = StubTransport { request in
            let event = try decodeAuthorization(request)
            XCTAssertTrue(SignatureVerifier.verify(event))
            if let body = request.httpBody {
                XCTAssertTrue(event.tags.contains(["payload", SHA256Hex.of(body)]))
                let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                if request.httpMethod == "PATCH" {
                    XCTAssertNil(payload["fips_endpoint"]); XCTAssertNil(payload["fips_transport_npub"])
                    XCTAssertEqual((payload["metadata"] as? [String: Any])?["transport_mode"] as? String, "https")
                    return (200, ["autopilot_connection": ["id": connectionID]])
                }
                if request.url!.path.hasSuffix("/autopilot-connections") {
                    return (200, ["autopilot_connection": ["id": connectionID, "row_version": 1,
                        "fips_endpoint": "http://\(TestKeys.npub).fips:3601", "fips_transport_npub": TestKeys.npub,
                        "metadata": ["installation_npub": TestKeys.npub]]])
                }
                return (200, ["workspace_agent": ["id": agentID]])
            }
            return (200, ["workspace_agents": [["id": agentID, "workspace_id": workspace.id, "agent_npub": TestKeys.npub,
                "display_name": "Fixture Agent", "row_version": 1]], "next_cursor": NSNull()])
        }
        let sync = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity, transport: transport)
        for _ in 0..<2 {
            try await sync.installNStackAgents(setup, selected: [choice.id], connection: connection, workspace: workspace)
            await sync.engine.waitUntilIdle()
        }
        let agents = try await store.reader.workspaceAgents(workspaceId: workspace.id)
        XCTAssertEqual(agents.map(\.id), [agentID])
        XCTAssertEqual(transport.recorded.filter { $0.httpMethod == "PATCH" }.count, 2)
        XCTAssertFalse(transport.recorded.contains { $0.url!.path.contains("messages") })
    }

    func testOnlyExactOwnerHealthAndAgentReadPathsAreAllowed() throws {
        let origin = try TowerOrigin("https://agents.example")
        XCTAssertNoThrow(try origin.url(path: "/api/owners/\(TestKeys.npub)/control-plane/v1/agents"))
        for path in ["/api/system/restart", "/api/owners/invalid/control-plane/v1/agents", "/api/owners/\(TestKeys.npub)/control-plane/v1/agents/other", "/api/owners/\(TestKeys.npub)/control-plane/v1/manifest"] {
            XCTAssertThrowsError(try origin.url(path: path))
        }
    }
}
