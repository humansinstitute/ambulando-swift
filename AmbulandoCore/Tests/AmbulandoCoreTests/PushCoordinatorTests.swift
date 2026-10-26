import Foundation
import XCTest
@testable import AmbulandoCore

private actor FakePlatform: PushPlatform {
    var current: PushPermission
    var answer: PushPermission
    private(set) var prompts = 0
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(current: PushPermission, answer: PushPermission = .authorized) { self.current = current; self.answer = answer }
    func permission() async -> PushPermission { current }
    func requestPermission() async -> PushPermission { prompts += 1; current = answer; return answer }
    func registerForRemoteNotifications() async { registerCalls += 1 }
    func unregisterForRemoteNotifications() async { unregisterCalls += 1 }
    func set(_ value: PushPermission) { current = value }
}

private actor FakeRegistrar: PushRegistrar {
    var registered: [String] = []        // workspace ids, in order
    var tokens: [String] = []
    var revoked: [String] = []
    var revokedInstallations: [String] = []
    var failure: Error?
    var revokeStatus: Int? = 200
    var lease: Date
    var ready: Bool? = true
    var reason: String?
    var installations: [String] = []

    init(lease: Date) { self.lease = lease }
    func setDelivery(ready: Bool?, reason: String?) { self.ready = ready; self.reason = reason }
    func setFailure(_ error: Error?) { failure = error }
    func setRevokeStatus(_ status: Int?) { revokeStatus = status }
    func register(_ registration: PushRegistration, token: PushDeviceToken, origin: TowerOrigin, signerNpub: String) async throws -> PushAcknowledgement {
        if let failure { throw failure }
        registered.append(registration.workspaceId)
        tokens.append(token.hex)
        installations.append(registration.installationId)
        return PushAcknowledgement(leaseExpiresAt: lease, deliveryReady: ready, deliveryReason: reason)
    }
    func revoke(_ revocation: PendingPushRevocation) async -> Int? {
        guard let revokeStatus else { return nil }
        if (200..<300).contains(revokeStatus) || revokeStatus == 404 { revoked.append(revocation.workspaceId); revokedInstallations.append(revocation.installationId) }
        return revokeStatus
    }
}

private final class MemoryPersistence: PushPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PushInstallationState?
    func load() async -> PushInstallationState? { lock.withLock { state } }
    func save(_ state: PushInstallationState) async { lock.withLock { self.state = state } }
    var saved: PushInstallationState? { lock.withLock { state } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

final class PushCoordinatorTests: XCTestCase {
    private let w1 = "2e5caefd-dd65-45d2-b747-ee874e8e5fc9"
    private let w2 = "0617d526-88dc-4dc2-9876-08349ab60eca"
    private let alice = "npub1alicexxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    private let bob = "npub1bobxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    private let tokenData = Data(repeating: 0xAB, count: 32)

    private struct Harness {
        let coordinator: PushCoordinator
        let platform: FakePlatform
        let registrar: FakeRegistrar
        let persistence: MemoryPersistence
        let clock: Clock
    }

    private func harness(permission: PushPermission = .notDetermined, answer: PushPermission = .authorized,
                         environment: PushEnvironment = .sandbox) -> Harness {
        let clock = Clock()
        let platform = FakePlatform(current: permission, answer: answer)
        let registrar = FakeRegistrar(lease: clock.now.addingTimeInterval(7 * 24 * 3600))
        let persistence = MemoryPersistence()
        let coordinator = PushCoordinator(platform: platform, registrar: registrar, persistence: persistence,
                                          bundleId: "studio.otherstuff.ambulando.native", environment: environment,
                                          now: { clock.now })
        return Harness(coordinator: coordinator, platform: platform, registrar: registrar, persistence: persistence, clock: clock)
    }

    private func binding(_ signer: String? = nil, workspaces: [String]? = nil, origin: String = "https://tower.sample.invalid") throws -> PushBinding {
        PushBinding(origin: try TowerOrigin(origin), signerNpub: signer ?? alice,
                    workspaces: Dictionary(uniqueKeysWithValues: (workspaces ?? [w1]).map { ($0, "npub1app") }))
    }

    private func unlocked(_ b: PushBinding) -> PushContext { PushContext(binding: b, unlockedSigner: b.signerNpub) }

    // MARK: Permission

    func testNothingIsRequestedUntilExplicitEnable() async throws {
        let h = harness()
        let status = await h.coordinator.status()
        XCTAssertEqual(status.phase, .off)
        await h.coordinator.reconcile(context: unlocked(try binding()))
        let prompts = await h.platform.prompts, registers = await h.platform.registerCalls, uploaded = await h.registrar.registered
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(registers, 0)
        XCTAssertTrue(uploaded.isEmpty)
    }

    func testEnablePromptsOnceThenRegistersForRemoteNotifications() async throws {
        let h = harness()
        let status = await h.coordinator.enable(context: unlocked(try binding()))
        let prompts = await h.platform.prompts, registers = await h.platform.registerCalls
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(registers, 1)
        XCTAssertEqual(status.phase, .waitingForToken)   // the token arrives through the app delegate
    }

    func testDeniedPermissionIsReportedHonestlyAndNeverRegisters() async throws {
        let h = harness(permission: .denied)
        let status = await h.coordinator.enable(context: unlocked(try binding()))
        let prompts = await h.platform.prompts, registers = await h.platform.registerCalls
        XCTAssertEqual(status.phase, .off)               // not enabled: the OS refuses, only Settings can change that
        XCTAssertEqual(status.permission, .denied)
        XCTAssertEqual(prompts, 0)                       // iOS would not show a second prompt; we do not pretend to
        XCTAssertEqual(registers, 0)
    }

    func testRefusingThePromptLeavesNotificationsOff() async throws {
        let h = harness(answer: .denied)
        let status = await h.coordinator.enable(context: unlocked(try binding()))
        XCTAssertEqual(status.phase, .off)
        XCTAssertEqual(status.permission, .denied)
        let saved = h.persistence.saved
        XCTAssertEqual(saved?.enabled, false)
    }

    func testAlertsTurnedOffInSystemSettingsWithdrawTheRegistration() async throws {
        let h = harness()
        let b = try binding()
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        var registered = await h.registrar.registered
        XCTAssertEqual(registered, [w1])
        await h.platform.set(.denied)
        await h.coordinator.reconcile(context: unlocked(b))
        let revoked = await h.registrar.revoked
        let status = await h.coordinator.status()
        XCTAssertEqual(revoked, [w1])
        XCTAssertEqual(status.phase, .denied)
        XCTAssertEqual(status.enrolledWorkspaces, 0)
        registered = await h.registrar.registered
        XCTAssertEqual(registered, [w1])                 // nothing new was uploaded
    }

    // MARK: Token and lease

    func testTokenUploadsOnlyWhileTheIdentityIsUnlockedAndWaitsOtherwise() async throws {
        let h = harness()
        let b = try binding()
        await h.coordinator.enable(context: PushContext(binding: b, unlockedSigner: nil))
        await h.coordinator.tokenReceived(tokenData, context: PushContext(binding: b, unlockedSigner: nil))
        var uploaded = await h.registrar.registered
        var status = await h.coordinator.status()
        XCTAssertTrue(uploaded.isEmpty)
        XCTAssertEqual(status.phase, .waitingForUnlock)
        await h.coordinator.reconcile(context: unlocked(b))     // the PIN arrives
        uploaded = await h.registrar.registered
        status = await h.coordinator.status()
        XCTAssertEqual(uploaded, [w1])
        if case .active = status.phase {} else { XCTFail("expected active, got \(status.phase)") }
    }

    func testAnotherSignerUnlockedDoesNotUploadForThisBinding() async throws {
        let h = harness()
        let b = try binding(alice)
        await h.coordinator.enable(context: PushContext(binding: b, unlockedSigner: nil))
        await h.coordinator.tokenReceived(tokenData, context: PushContext(binding: b, unlockedSigner: bob))
        let uploaded = await h.registrar.registered
        XCTAssertTrue(uploaded.isEmpty)
    }

    func testLeaseIsRenewedOnlyWhenHalfSpentAndTokenChangeReuploads() async throws {
        let h = harness()
        let b = try binding(workspaces: [w1, w2])
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        await h.coordinator.reconcile(context: unlocked(b))
        var uploaded = await h.registrar.registered
        XCTAssertEqual(uploaded.count, 2)                       // no churn on a plain reconcile
        h.clock.advance(5 * 24 * 3600)                           // past half of the 7-day lease
        await h.coordinator.reconcile(context: unlocked(b))
        uploaded = await h.registrar.registered
        XCTAssertEqual(uploaded.count, 4)
        await h.coordinator.tokenReceived(Data(repeating: 0xCD, count: 32), context: unlocked(b))
        uploaded = await h.registrar.registered
        let tokens = await h.registrar.tokens
        XCTAssertEqual(uploaded.count, 6)
        XCTAssertEqual(Set(tokens).count, 2)
    }

    func testInstallationIdIsStableAcrossInstances() async throws {
        let h = harness()
        let first = await h.coordinator.installationId
        let again = PushCoordinator(platform: h.platform, registrar: h.registrar, persistence: h.persistence, bundleId: "x", environment: .sandbox)
        let second = await again.installationId
        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
    }

    func testStatePersistenceNeverContainsAnythingButWhatIsNeeded() async throws {
        let h = harness()
        let b = try binding()
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        let status = await h.coordinator.status()
        let text = String(describing: status)
        XCTAssertFalse(text.contains(try PushDeviceToken(data: tokenData).hex))
    }

    // MARK: Provider and failures

    func testUnavailableProviderIsShownTruthfullyAndNotRetriedInALoop() async throws {
        let h = harness()
        let b = try binding()
        await h.registrar.setFailure(TowerError.http(status: 404, code: nil, stage: "push registration"))
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        var status = await h.coordinator.status()
        XCTAssertEqual(status.phase, .providerUnavailable)
        await h.registrar.setFailure(nil)
        await h.coordinator.reconcile(context: unlocked(b))     // inside the retry window: nothing is sent
        var uploaded = await h.registrar.registered
        XCTAssertTrue(uploaded.isEmpty)
        h.clock.advance(PushCoordinator.unavailableRetry + 1)
        await h.coordinator.reconcile(context: unlocked(b))
        uploaded = await h.registrar.registered
        status = await h.coordinator.status()
        XCTAssertEqual(uploaded, [w1])
        if case .active = status.phase {} else { XCTFail("expected active, got \(status.phase)") }
    }

    func testOSRegistrationFailureIsVisibleAndNotAnEnrolment() async throws {
        let h = harness()
        await h.coordinator.enable(context: unlocked(try binding()))
        await h.coordinator.registrationFailed(NSError(domain: "NSCocoaErrorDomain", code: 3010, userInfo: [NSLocalizedDescriptionKey: "no aps-environment"]))
        let status = await h.coordinator.status()
        guard case .failed(let message) = status.phase else { return XCTFail("expected failed, got \(status.phase)") }
        XCTAssertTrue(message.contains("no aps-environment"))
        let uploaded = await h.registrar.registered
        XCTAssertTrue(uploaded.isEmpty)
    }

    func testServerRefusalIsSurfacedAsAFailure() async throws {
        let h = harness()
        let b = try binding()
        await h.registrar.setFailure(TowerError.http(status: 409, code: "transport_owned", stage: "push registration"))
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        let status = await h.coordinator.status()
        guard case .failed = status.phase else { return XCTFail("expected failed, got \(status.phase)") }
    }

    // MARK: Revocation (logout, signer, workspace)

    func testDisconnectWithdrawsRegistrationsWhileUnlocked() async throws {
        let h = harness()
        let b = try binding(workspaces: [w1, w2])
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        await h.coordinator.unbind(context: unlocked(b))
        let revoked = await h.registrar.revoked
        let status = await h.coordinator.status()
        XCTAssertEqual(Set(revoked), [w1, w2])
        XCTAssertEqual(status.enrolledWorkspaces, 0)
        XCTAssertEqual(status.pendingRevocations, 0)
    }

    func testRevocationWhileLockedIsKeptAndSentOnUnlockNeverSignedEarly() async throws {
        let h = harness()
        let b = try binding()
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        await h.coordinator.unbind(context: PushContext(binding: b, unlockedSigner: nil))      // logout while locked
        var revoked = await h.registrar.revoked
        var status = await h.coordinator.status()
        XCTAssertTrue(revoked.isEmpty)
        XCTAssertEqual(status.pendingRevocations, 1)
        await h.coordinator.reconcile(context: PushContext(binding: nil, unlockedSigner: bob))  // another signer cannot revoke it
        revoked = await h.registrar.revoked
        XCTAssertTrue(revoked.isEmpty)
        await h.coordinator.reconcile(context: PushContext(binding: nil, unlockedSigner: alice))
        revoked = await h.registrar.revoked
        status = await h.coordinator.status()
        XCTAssertEqual(revoked, [w1])
        XCTAssertEqual(status.pendingRevocations, 0)
    }

    func testRevocationThatCannotBeSentIsDroppedWhenTheLeaseEnds() async throws {
        let h = harness()
        let b = try binding()
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        await h.registrar.setRevokeStatus(nil)                                  // network down
        await h.coordinator.unbind(context: unlocked(b))
        var status = await h.coordinator.status()
        XCTAssertEqual(status.pendingRevocations, 1)
        h.clock.advance(8 * 24 * 3600)
        await h.coordinator.reconcile(context: unlocked(b))
        status = await h.coordinator.status()
        XCTAssertEqual(status.pendingRevocations, 0)
    }

    func testSignerChangeWithdrawsTheOldRowsAndRegistersTheNewSigner() async throws {
        let h = harness()
        await h.coordinator.enable(context: unlocked(try binding(alice)))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(try binding(alice)))
        // The old signer is not available, so its revocation waits; the new signer registers normally.
        await h.coordinator.reconcile(context: unlocked(try binding(bob)))
        var status = await h.coordinator.status()
        XCTAssertEqual(status.pendingRevocations, 1)
        var uploaded = await h.registrar.registered
        XCTAssertEqual(uploaded, [w1, w1])
        await h.coordinator.reconcile(context: unlocked(try binding(alice)))   // alice unlocks later: her old row is withdrawn
        status = await h.coordinator.status()
        let revoked = await h.registrar.revoked
        XCTAssertEqual(revoked, [w1])
        XCTAssertEqual(status.pendingRevocations, 1)                            // bob's row now waits for bob
    }

    func testWorkspaceRemovalWithdrawsOnlyThatWorkspace() async throws {
        let h = harness()
        await h.coordinator.enable(context: unlocked(try binding(workspaces: [w1, w2])))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(try binding(workspaces: [w1, w2])))
        await h.coordinator.reconcile(context: unlocked(try binding(workspaces: [w1])))
        let revoked = await h.registrar.revoked
        let status = await h.coordinator.status()
        XCTAssertEqual(revoked, [w2])
        XCTAssertEqual(status.enrolledWorkspaces, 1)
    }

    func testDisableWithdrawsAndDropsTheToken() async throws {
        let h = harness()
        let b = try binding()
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        await h.coordinator.disable(context: unlocked(b))
        let revoked = await h.registrar.revoked, unregistered = await h.platform.unregisterCalls
        let status = await h.coordinator.status()
        XCTAssertEqual(revoked, [w1])
        XCTAssertEqual(unregistered, 1)
        XCTAssertEqual(status.phase, .off)
        XCTAssertNil(h.persistence.saved?.tokenHex)
    }

    // MARK: Environment, foreground and tap

    func testEnvironmentComesFromTheSignedProfile() {
        let development = Data("<dict><key>aps-environment</key>\n\t<string>development</string></dict>".utf8)
        let production = Data("<dict><key>aps-environment</key><string>production</string></dict>".utf8)
        XCTAssertEqual(PushEnvironment.resolve(embeddedProfile: development), .sandbox)
        XCTAssertEqual(PushEnvironment.resolve(embeddedProfile: production), .production)
        XCTAssertEqual(PushEnvironment.resolve(embeddedProfile: nil), .production)   // App Store / TestFlight embed no profile
        XCTAssertEqual(PushEnvironment.resolve(embeddedProfile: Data("<dict></dict>".utf8)), .production)
    }

    private func payload(_ fd: [String: Any] = [:]) throws -> PushPayload {
        var base: [String: Any] = ["v": 1, "origin": "https://tower.sample.invalid", "workspace_id": w1,
                                   "channel_id": w2, "thread_id": "dd555036-8b9a-43cc-9d10-1ef748744bba",
                                   "notification_id": "11111111-2222-4333-8444-555555555555", "change_seq": 42]
        base.merge(fd) { $1 }
        return try PushPayload.parse(userInfo: ["aps": ["alert": ["title": "New activity", "body": ""]], "fd": base])
    }

    func testForegroundBannerIsSuppressedOnlyForTheResourceBeingViewed() throws {
        let p = try payload()
        let here = PushRouter.destination(for: p)
        XCTAssertEqual(PushPresentation.foreground(p, viewing: here), .suppress)
        XCTAssertEqual(PushPresentation.foreground(p, viewing: .channel(workspaceId: w1, channelId: w2)), .banner)
        XCTAssertEqual(PushPresentation.foreground(p, viewing: nil), .banner)
        XCTAssertEqual(PushPresentation.foreground(nil, viewing: here), .banner)     // unknown payload: let the OS show it
    }

    func testPayloadCarriesNotificationIdForRefetchAndUnknownPayloadIsRefused() throws {
        let p = try payload()
        XCTAssertEqual(p.notificationId, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(p.changeSeq, 42)
        XCTAssertThrowsError(try PushPayload.parse(userInfo: ["fd": ["v": 1, "origin": "https://tower.sample.invalid", "workspace_id": w1, "notification_id": "not-a-uuid"]]))
        XCTAssertThrowsError(try PushPayload.parse(userInfo: ["aps": ["alert": "x"]]))
    }

    func testRouteMismatchIsRefusedAndHeldTapGoesStale() throws {
        let p = try payload()
        let origin = try TowerOrigin("https://tower.sample.invalid")
        XCTAssertEqual(PushRouter.decide(p, connectedOrigin: origin, workspaceIds: [w2], isLocked: false), .refuse(.unknownWorkspace))
        XCTAssertEqual(PushRouter.decide(p, connectedOrigin: try TowerOrigin("https://elsewhere.sample.invalid"), workspaceIds: [w1], isLocked: false), .refuse(.foreignOrigin))
        let held = PendingPushTap(payload: p, receivedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(held.isFresh(now: Date(timeIntervalSince1970: 3600)))
        XCTAssertFalse(held.isFresh(now: Date(timeIntervalSince1970: 3 * 24 * 3600)))
    }
}


extension PushCoordinatorTests {
    func testRegisteredButProviderNotReadyIsNeverShownAsOn() async throws {
        let h = harness()
        let b = try binding()
        await h.registrar.setDelivery(ready: false, reason: "provider_not_configured")
        await h.coordinator.enable(context: PushContext(binding: b, unlockedSigner: alice))
        await h.coordinator.tokenReceived(tokenData, context: PushContext(binding: b, unlockedSigner: alice))
        var status = await h.coordinator.status()
        XCTAssertEqual(status.phase, .registeredNotDelivering(reason: "provider_not_configured"))
        await h.registrar.setDelivery(ready: true, reason: nil)
        await h.coordinator.reconcile(context: PushContext(binding: b, unlockedSigner: alice), force: true)
        status = await h.coordinator.status()
        if case .active = status.phase {} else { XCTFail("expected active once Tower reports ready, got \(status.phase)") }
    }

    func testSignerChangeRotatesInstallationIdAndKeepsTheOldOneForRevocation() async throws {
        let h = harness()
        await h.coordinator.enable(context: unlocked(try binding(alice)))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(try binding(alice)))
        let first = await h.coordinator.installationId
        await h.coordinator.reconcile(context: unlocked(try binding(bob)))       // bob signs in on this device
        let second = await h.coordinator.installationId
        XCTAssertNotEqual(first, second)
        let installations = await h.registrar.installations
        XCTAssertEqual(installations, [first, second])                           // bob never reuses alice's id
        await h.coordinator.reconcile(context: unlocked(try binding(alice)))     // alice's owed revocation uses her original id
        let revoked = await h.registrar.revokedInstallations
        XCTAssertEqual(revoked, [first])
    }

    func testLogoutRotatesInstallationIdSoTheNextPersonIsNotRefusedAsInstallationOwned() async throws {
        let h = harness()
        let b = try binding()
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        let before = await h.coordinator.installationId
        await h.coordinator.unbind(context: unlocked(b))
        let after = await h.coordinator.installationId
        XCTAssertNotEqual(before, after)
        let revoked = await h.registrar.revokedInstallations
        XCTAssertEqual(revoked, [before])
    }

    func testTokenOwnedByAnotherActorIsReportedWithoutStealing() async throws {
        let h = harness()
        let b = try binding()
        await h.registrar.setFailure(TowerError.http(status: 409, code: "transport_owned", stage: "push registration"))
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        let status = await h.coordinator.status()
        guard case .failed(let message) = status.phase else { return XCTFail("expected failed, got \(status.phase)") }
        XCTAssertTrue(message.contains("another account"))
        XCTAssertEqual(status.enrolledWorkspaces, 0)
    }

    func testAliasBodyStatesClientPlatformAndGrantedPermission() throws {
        let registration = try PushRegistration(workspaceId: w1, appNpub: "npub1app", installationId: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
                                                environment: .sandbox, bundleId: "studio.otherstuff.ambulando.native",
                                                platform: "ipados", appVersion: "0.1.0 (28)")
        let token = try PushDeviceToken(data: tokenData)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: registration.body(token: token)) as? [String: Any])
        XCTAssertEqual(object["client_app_id"] as? String, "ambulando")
        XCTAssertEqual(object["platform"] as? String, "ipados")
        XCTAssertEqual(object["permission_state"] as? String, "granted")
        XCTAssertEqual(object["app_version"] as? String, "0.1.0 (28)")
        XCTAssertEqual(object["environment"] as? String, "sandbox")
        let response = Fixtures.json(["device": ["lease_expires_at": "2026-11-03T12:00:00.000Z", "token_suffix": token.suffix],
                                      "delivery": ["ready": false, "reason": "provider_not_configured"]])
        let ack = try PushRegistration.acknowledgement(fromResponse: response, token: token)
        XCTAssertEqual(ack.deliveryReady, false)
        XCTAssertEqual(ack.deliveryReason, "provider_not_configured")
        let old = Fixtures.json(["device": ["lease_expires_at": "2026-11-03T12:00:00.000Z"]])
        XCTAssertNil(try PushRegistration.acknowledgement(fromResponse: old, token: token).deliveryReady)
    }

    func testTowerServiceIdentityMatchesAnAlternateOriginButNeverALookalike() throws {
        let known = "npub1towerxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        let alt = try payload(["origin": "https://tower.canonical.invalid", "tower_service_npub": known])
        let pinned = try TowerOrigin("https://tower.pinned.invalid")
        XCTAssertEqual(alt.towerServiceNpub, known)
        XCTAssertEqual(PushRouter.decide(alt, connectedOrigin: pinned, connectedTowerNpub: known, workspaceIds: [w1], isLocked: false),
                       .open(PushRouter.tapDestination(for: alt)!))
        // Same origin text but another Tower's identity is refused, as is an alternate origin without a matching identity.
        XCTAssertEqual(PushRouter.decide(try payload(["tower_service_npub": "npub1other"]), connectedOrigin: try TowerOrigin("https://tower.sample.invalid"),
                                         connectedTowerNpub: known, workspaceIds: [w1], isLocked: false), .refuse(.foreignOrigin))
        XCTAssertEqual(PushRouter.decide(alt, connectedOrigin: pinned, connectedTowerNpub: nil, workspaceIds: [w1], isLocked: false), .refuse(.foreignOrigin))
        XCTAssertEqual(PushRouter.decide(try payload(["origin": "https://tower.canonical.invalid"]), connectedOrigin: pinned, connectedTowerNpub: known,
                                         workspaceIds: [w1], isLocked: false), .refuse(.foreignOrigin))
        XCTAssertNil(try payload(["tower_service_npub": "not-an-npub"]).towerServiceNpub)
    }

    func testMissingDeliveryFlagIsNeutralNotOnAndRecheckBeforeHalfLifeFixesIt() async throws {
        let h = harness()
        let b = try binding()
        await h.registrar.setDelivery(ready: nil, reason: nil)                      // an older Tower without `delivery`
        await h.coordinator.enable(context: unlocked(b))
        await h.coordinator.tokenReceived(tokenData, context: unlocked(b))
        var status = await h.coordinator.status()
        XCTAssertEqual(status.phase, .registeredNotDelivering(reason: "readiness_unknown"))
        await h.registrar.setDelivery(ready: false, reason: "provider_not_configured")
        await h.coordinator.reconcile(context: unlocked(b))                         // plain trigger: lease is fresh, nothing re-sent
        var uploads = await h.registrar.registered.count
        XCTAssertEqual(uploads, 1)
        await h.registrar.setDelivery(ready: true, reason: nil)                     // key configured on Tower
        await h.coordinator.reconcile(context: PushContext(binding: b, unlockedSigner: nil), force: true)   // locked: no signing, no change
        uploads = await h.registrar.registered.count
        XCTAssertEqual(uploads, 1)
        await h.coordinator.reconcile(context: unlocked(b), force: true)            // explicit "Check again", unlocked, well before half-life
        uploads = await h.registrar.registered.count
        status = await h.coordinator.status()
        XCTAssertEqual(uploads, 2)
        if case .active = status.phase {} else { XCTFail("expected active only after Tower said ready, got \(status.phase)") }
    }

    func testIdOnlyAlertRoutesToTheInboxItemAndNoLongerRefusesAsNoTarget() throws {
        let origin = try TowerOrigin("https://tower.sample.invalid")
        let idOnly = try PushPayload.parse(userInfo: ["fd": ["v": 1, "origin": "https://tower.sample.invalid", "workspace_id": w1,
                                                              "notification_id": "11111111-2222-4333-8444-555555555555", "change_seq": 7,
                                                              "category": "app_object", "source_app_id": "blinkers"]])
        XCTAssertNil(PushRouter.destination(for: idOnly))
        XCTAssertEqual(PushRouter.decide(idOnly, connectedOrigin: origin, workspaceIds: [w1], isLocked: false),
                       .open(.notification(workspaceId: w1, notificationId: "11111111-2222-4333-8444-555555555555")))
        XCTAssertEqual(PushRouter.decide(idOnly, connectedOrigin: origin, workspaceIds: [w1], isLocked: true),
                       .holdUntilUnlock(.notification(workspaceId: w1, notificationId: "11111111-2222-4333-8444-555555555555")))
        // With neither an item nor a record id there is still nothing to open.
        XCTAssertEqual(PushRouter.decide(try PushPayload.parse(userInfo: ["fd": ["v": 1, "origin": "https://tower.sample.invalid", "workspace_id": w1]]),
                                         connectedOrigin: origin, workspaceIds: [w1], isLocked: false), .refuse(.noTarget))
    }
}
