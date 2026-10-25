import Foundation
import XCTest
@testable import AmbulandoCore

final class PushTests: XCTestCase {
    private let workspace = "2E5CAEFD-DD65-45D2-B747-EE874E8E5FC9"
    private let channel = "0617d526-88dc-4dc2-9876-08349ab60eca"
    private let thread = "dd555036-8b9a-43cc-9d10-1ef748744bba"
    private let task = "b96afd04-503c-4eeb-bcc2-a65fc651c9b2"
    private let doc = "11111111-2222-4333-8444-555555555555"
    private let installation = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"

    private func payload(_ fd: [String: Any]) throws -> PushPayload {
        var base: [String: Any] = ["v": 1, "origin": "https://tower.sample.invalid", "workspace_id": workspace]
        base.merge(fd) { $1 }
        return try PushPayload.parse(userInfo: ["aps": ["alert": "New activity"], "fd": base])
    }

    func testPayloadParsesV1AndRefusesUnknownOrUnsafeInput() throws {
        let parsed = try payload(["channel_id": channel, "thread_id": thread, "task_id": NSNull()])
        XCTAssertEqual(parsed.workspaceId, workspace.lowercased())
        XCTAssertEqual(parsed.threadId, thread)
        XCTAssertNil(parsed.taskId)
        XCTAssertThrowsError(try PushPayload.parse(userInfo: [:])) { XCTAssertEqual($0 as? PushPayload.ParseError, .missing) }
        XCTAssertThrowsError(try payload(["v": 2])) { XCTAssertEqual($0 as? PushPayload.ParseError, .unsupportedVersion) }
        XCTAssertThrowsError(try payload(["origin": "http://tower.sample.invalid"])) { XCTAssertEqual($0 as? PushPayload.ParseError, .invalidOrigin) }
        XCTAssertThrowsError(try payload(["origin": "https://tower.fips"])) { XCTAssertEqual($0 as? PushPayload.ParseError, .invalidOrigin) }
        XCTAssertThrowsError(try payload(["thread_id": "../x"])) { XCTAssertEqual($0 as? PushPayload.ParseError, .invalidId("thread_id")) }
        XCTAssertThrowsError(try payload(["workspace_id": NSNull()])) { XCTAssertEqual($0 as? PushPayload.ParseError, .invalidId("workspace_id")) }
    }

    func testRouteSpecificityPrefersTaskAndDocOverConversation() throws {
        let w = workspace.lowercased()
        XCTAssertEqual(PushRouter.destination(for: try payload(["channel_id": channel, "thread_id": thread, "task_id": task])),
                       .task(workspaceId: w, taskId: task))
        XCTAssertEqual(PushRouter.destination(for: try payload(["channel_id": channel, "doc_id": doc])), .doc(workspaceId: w, docId: doc))
        XCTAssertEqual(PushRouter.destination(for: try payload(["channel_id": channel, "thread_id": thread])),
                       .thread(workspaceId: w, channelId: channel, threadId: thread))
        XCTAssertEqual(PushRouter.destination(for: try payload(["thread_id": thread])), .threadById(workspaceId: w, threadId: thread))
        XCTAssertEqual(PushRouter.destination(for: try payload(["channel_id": channel])), .channel(workspaceId: w, channelId: channel))
        XCTAssertNil(PushRouter.destination(for: try payload([:])))
    }

    func testTapRefusesForeignOriginOrWorkspaceAndHoldsWhileLocked() throws {
        let p = try payload(["channel_id": channel])
        let origin = try TowerOrigin("https://TOWER.sample.invalid/")
        let held: Set<String> = [workspace.lowercased()]
        XCTAssertEqual(PushRouter.decide(p, connectedOrigin: origin, workspaceIds: held, isLocked: false),
                       .open(.channel(workspaceId: workspace.lowercased(), channelId: channel)))
        XCTAssertEqual(PushRouter.decide(p, connectedOrigin: origin, workspaceIds: held, isLocked: true),
                       .holdUntilUnlock(.channel(workspaceId: workspace.lowercased(), channelId: channel)))
        XCTAssertEqual(PushRouter.decide(p, connectedOrigin: try TowerOrigin("https://other.sample.invalid"), workspaceIds: held, isLocked: false),
                       .refuse(.foreignOrigin))
        XCTAssertEqual(PushRouter.decide(p, connectedOrigin: nil, workspaceIds: held, isLocked: false), .refuse(.foreignOrigin))
        XCTAssertEqual(PushRouter.decide(p, connectedOrigin: origin, workspaceIds: [doc], isLocked: false), .refuse(.unknownWorkspace))
        XCTAssertEqual(PushRouter.decide(try payload([:]), connectedOrigin: origin, workspaceIds: held, isLocked: false), .refuse(.noTarget))
    }

    func testDefaultsAndTokenValidation() throws {
        XCTAssertEqual(PushEnvironment.default(debugBuild: true), .sandbox)
        XCTAssertEqual(PushEnvironment.default(debugBuild: false), .production)
        XCTAssertEqual(PushSettings(), PushSettings(enabled: false, keepWhileLocked: true, preview: .generic))
        let token = try PushDeviceToken(data: Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(token.hex.count, 64)
        XCTAssertEqual(token.suffix, "ababab")
        XCTAssertThrowsError(try PushDeviceToken(hex: String(repeating: "a", count: 62)))
        XCTAssertThrowsError(try PushDeviceToken(hex: String(repeating: "g", count: 64)))
        XCTAssertThrowsError(try PushRegistration(workspaceId: workspace, appNpub: TestKeys.npub, installationId: installation,
                                                  environment: .sandbox, bundleId: "b", leaseSeconds: PushRegistration.maximumLeaseSeconds + 1))
        XCTAssertThrowsError(try PushRegistration(workspaceId: "not-a-uuid", appNpub: TestKeys.npub, installationId: installation,
                                                  environment: .sandbox, bundleId: "b"))
    }

    func testRegisterAndRevokeRequestsAreSignedForExactBodyAndRefusedWhileLocked() async throws {
        let identity = try await makeIdentity()
        let client = TowerClient(origin: try TowerOrigin("https://tower.sample.invalid"), transport: StubTransport { _ in (200, [:]) }, signer: identity)
        let registration = try PushRegistration(workspaceId: workspace, appNpub: TestKeys.npub, installationId: installation,
                                                environment: .sandbox, bundleId: "studio.otherstuff.ambulando.native")
        let token = try PushDeviceToken(data: Data(repeating: 0x0F, count: 32))
        let put = try await registration.registerRequest(token: token, client: client)
        let path = "/api/v4/flightdeck-pg/workspaces/\(workspace.lowercased())/notifications/apns-devices/\(installation.lowercased())"
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.path, path)
        XCTAssertEqual(put.value(forHTTPHeaderField: "x-flightdeck-pg-app-npub"), TestKeys.npub)
        let body = try XCTUnwrap(put.httpBody)
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"bundle_id":"studio.otherstuff.ambulando.native","device_token":"\#(token.hex)","environment":"sandbox","lease_seconds":604800,"preview":"generic"}"#)
        let putAuth = try decodeAuthorization(put)
        XCTAssertEqual(putAuth.kind, NIP98.kind)
        XCTAssertTrue(putAuth.tags.contains(["payload", SHA256Hex.of(body)]))
        XCTAssertTrue(putAuth.tags.contains(["method", "PUT"]))
        XCTAssertEqual(putAuth.pubkey, TestKeys.pubkeyHex)

        let delete = try await registration.revokeRequest(client: client)
        XCTAssertEqual(delete.httpMethod, "DELETE")
        XCTAssertEqual(delete.url?.path, path)
        XCTAssertNil(delete.httpBody)
        XCTAssertFalse(try decodeAuthorization(delete).tags.contains { $0.first == "payload" })

        let locked = try await makeIdentity(unlocked: false)
        let lockedClient = TowerClient(origin: try TowerOrigin("https://tower.sample.invalid"), transport: StubTransport { _ in (200, [:]) }, signer: locked)
        do {
            _ = try await registration.revokeRequest(client: lockedClient)
            XCTFail("signed while locked")
        } catch {}
    }

    func testLeaseResponseRejectsEchoedToken() throws {
        let token = try PushDeviceToken(data: Data(repeating: 0x0F, count: 32))
        let ok = Fixtures.json(["device": ["status": "active", "token_suffix": token.suffix, "lease_expires_at": "2026-11-01T00:00:00.000Z"]])
        XCTAssertEqual(try PushRegistration.leaseExpiry(fromResponse: ok, token: token), ISO8601DateFormatter.tower.date(from: "2026-11-01T00:00:00.000Z"))
        let echoed = Fixtures.json(["device": ["device_token": token.hex, "lease_expires_at": "2026-11-01T00:00:00.000Z"]])
        XCTAssertThrowsError(try PushRegistration.leaseExpiry(fromResponse: echoed, token: token))
    }

    func testPendingRevocationRetriesWithBackoffUntilLeaseEnds() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var pending = PendingPushRevocation(origin: try TowerOrigin("https://tower.sample.invalid"), workspaceId: workspace, appNpub: TestKeys.npub,
                                            installationId: installation, signerNpub: TestKeys.npub,
                                            leaseExpiresAt: now.addingTimeInterval(7200), now: now)
        XCTAssertEqual(pending.record(status: nil, now: now), .retry(at: now.addingTimeInterval(30)))
        XCTAssertEqual(pending.record(status: 503, now: now), .retry(at: now.addingTimeInterval(60)))
        for _ in 0..<10 { _ = pending.record(status: 401, now: now) }
        XCTAssertEqual(pending.nextAttemptAt, now.addingTimeInterval(3600))
        XCTAssertEqual(pending.record(status: 500, now: now.addingTimeInterval(7000)), .retry(at: now.addingTimeInterval(7200)))
        XCTAssertEqual(pending.record(status: 500, now: now.addingTimeInterval(7200)), .leaseExpired)
        XCTAssertEqual(pending.record(status: 404, now: now), .done)
        XCTAssertEqual(pending.record(status: 200, now: now), .done)
        let decoded = try JSONDecoder().decode(PendingPushRevocation.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(decoded, pending)
    }
}
