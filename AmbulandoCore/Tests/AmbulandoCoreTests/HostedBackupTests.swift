import XCTest
@testable import AmbulandoCore

private actor AfterBackupReadback: HTTPTransport {
    let underlying: FakeOnboardingTower
    let after: @Sendable () async throws -> Void
    private var reads = 0

    init(underlying: FakeOnboardingTower, after: @escaping @Sendable () async throws -> Void) {
        self.underlying = underlying; self.after = after
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try await underlying.send(request)
        if request.url?.path == "/api/v4/identity-backup/me" {
            reads += 1
            if reads == 2 { try await after() }
        }
        return response
    }
}

/// The hosted-backup save sequence against `FakeOnboardingTower`, which implements tower docs/contract/hosted-identity-backup-v1.md
/// (strict NIP-98 on writes and `/me`, public ciphertext read, CAS revisions, one username per key, `identity_origin` payment gate).
/// Synthetic generated keys only. No live NStack was contacted.
final class HostedBackupTests: XCTestCase {
    private let password = "correct horse battery staple"
    private let cheap: UInt8 = 10

    private struct Rig {
        let identity: IdentityService
        let directory: URL
        let tower: FakeOnboardingTower
        let npub: String
        let saver: HostedBackupSaver
    }

    private func rig(logN: UInt8 = 10, accepted: ClosedRange<UInt8> = 10...18) async throws -> Rig {
        let directory = temporaryDirectory()
        let identity = IdentityService(vaultURL: directory.appendingPathComponent("vault.json"), secrets: MemorySecretStore())
        let preview = try await identity.beginNewIdentity()
        _ = try await identity.createPendingBackup(password: password, logN: cheap)
        try await identity.notePendingBackupExported()
        try await identity.acknowledgePendingBackup(password: password)
        _ = try await identity.commitNewIdentity(pin: TestKeys.pin)
        let tower = FakeOnboardingTower()
        tower.hostedLogN = accepted
        tower.inviteCodes[OnboardingFixture.invite] = 21
        let saver = HostedBackupSaver(origin: try TowerOrigin(tower.origin), transport: tower, identity: identity, logN: logN, acceptedLogN: accepted)
        return Rig(identity: identity, directory: directory, tower: tower, npub: preview.npub, saver: saver)
    }

    private func hostedRequests(_ tower: FakeOnboardingTower) -> [FakeOnboardingTower.Seen] { tower.requests.filter { $0.path.hasPrefix("/api/v4/identity-backup") } }

    func testSaveReadsBackVerifiesAndOnlyThenConfirms() async throws {
        let rig = try await rig()
        let gateBefore = await rig.identity.paymentBackupGate()
        XCTAssertEqual(gateBefore, .hostedBackupRequired)

        let confirmation = try await rig.saver.save(username: "Alice_01", password: password)
        XCTAssertEqual(confirmation, .init(username: "alice_01", revision: "1"))
        let row = try XCTUnwrap(rig.tower.hosted["alice_01"])
        XCTAssertEqual(row.owner, rig.npub)
        XCTAssertEqual(row.revision, 1)
        // Contract order: who am I, write, public read-back, signed read-back.
        XCTAssertEqual(hostedRequests(rig.tower).map { "\($0.method) \($0.path)" },
                       ["GET /api/v4/identity-backup/me", "PUT /api/v4/identity-backup/alice_01", "GET /api/v4/identity-backup/alice_01", "GET /api/v4/identity-backup/me"])
        let gate = await rig.identity.paymentBackupGate()
        XCTAssertEqual(gate, .allowed)
        let record = await rig.identity.backupRecord()
        XCTAssertEqual(record?.hostedUsername, "alice_01"); XCTAssertEqual(record?.hostedRevision, "1")
        XCTAssertNil(record?.hostedAttempt, "the staged upload is cleared once confirmed")

        // The stored ciphertext opens, with the password, to this identity's key.
        let opened = try NIP49.open(row.ncryptsec, password: password)
        XCTAssertEqual(try NewIdentity.npub(secret: opened.secretKey), rig.npub)
        XCTAssertEqual(opened.keySecurity, .safe)

        // The server saw only the ciphertext: no password, no plaintext key in any URL, body or header.
        let secretHex = opened.secretKey.hex, nsec = Bech32.encode(hrp: "nsec", data: opened.secretKey)
        for request in rig.tower.requests {
            let text = request.url.absoluteString + String(decoding: (try? JSONSerialization.data(withJSONObject: request.body)) ?? Data(), as: UTF8.self)
            for secret in [password, secretHex, nsec] { XCTAssertFalse(text.contains(secret), request.path) }
        }
    }

    func testAlreadyConfirmedNeverUploadsAgain() async throws {
        let rig = try await rig()
        _ = try await rig.saver.save(username: "alice_01", password: password)
        let before = rig.tower.requests.count
        let again = try await rig.saver.save(username: "someone_else", password: "different password entirely")
        XCTAssertEqual(again, .init(username: "alice_01", revision: "1"))
        XCTAssertEqual(rig.tower.requests.count, before)
    }

    func testConfirmationAndStagedRetryBelongToTheSelectedOrigin() async throws {
        let rig = try await rig()
        _ = try await rig.saver.save(username: "alice_01", password: password)
        let second = FakeOnboardingTower(origin: "https://other.example")
        second.hostedLogN = 10...18
        let secondOrigin = try TowerOrigin(second.origin)
        let before = await rig.identity.paymentBackupGate(origin: secondOrigin)
        XCTAssertEqual(before, .hostedBackupRequired)
        let saver = HostedBackupSaver(origin: secondOrigin, transport: second, identity: rig.identity, logN: cheap, acceptedLogN: 10...18)
        _ = try await saver.save(username: "alice_02", password: password)
        XCTAssertEqual(second.count("PUT", suffix: "/alice_02"), 1)
        let after = await rig.identity.paymentBackupGate(origin: secondOrigin)
        XCTAssertEqual(after, .allowed)
        let first = await rig.identity.paymentBackupGate(origin: try TowerOrigin(rig.tower.origin))
        XCTAssertEqual(first, .hostedBackupRequired, "a different server needs its own verified confirmation")
    }

    func testIdentityReplacementAfterSignedReadbackCannotConfirmAnotherIdentity() async throws {
        let rig = try await rig()
        let identity = rig.identity
        let transport = AfterBackupReadback(underlying: rig.tower) {
            _ = try await identity.remove()
            _ = try await identity.beginNewIdentity()
            _ = try await identity.createPendingBackup(password: "replacement fixture password", logN: 10)
            try await identity.notePendingBackupExported()
            try await identity.acknowledgePendingBackup(password: "replacement fixture password")
            _ = try await identity.commitNewIdentity(pin: TestKeys.pin)
        }
        let saver = HostedBackupSaver(origin: try TowerOrigin(rig.tower.origin), transport: transport, identity: identity, logN: cheap, acceptedLogN: 10...18)
        do { _ = try await saver.save(username: "alice_01", password: password); XCTFail("confirmed a different identity") }
        catch { XCTAssertEqual(error as? IdentityError, .accountMismatch) }
        let replacement = await identity.backupRecord()
        XCTAssertNotEqual(replacement?.npub, rig.npub)
        XCTAssertNil(replacement?.hostedBackupConfirmedAt)
        XCTAssertNil(replacement?.hostedAttempt)
    }

    func testContractCostFloorIsEnforcedForRealUploads() async throws {
        // Production bounds: a cost-10 ciphertext is refused locally before any request, and a cost-16 one is accepted.
        let low = try await rig(logN: 10, accepted: 16...18)
        do { _ = try await low.saver.save(username: "alice_01", password: password); XCTFail("uploaded a cost-10 ciphertext") }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .invalidBackup) }
        XCTAssertTrue(low.tower.hosted.isEmpty)
        let record = await low.identity.backupRecord()
        XCTAssertEqual(record?.hostedBackupConfirmedAt, nil)
        let ok = try await rig(logN: 16, accepted: 16...18)
        let confirmation = try await ok.saver.save(username: "alice_01", password: password)
        XCTAssertEqual(confirmation.revision, "1")
        XCTAssertEqual(Array(Bech32.decode(try XCTUnwrap(ok.tower.hosted["alice_01"]).ncryptsec, maxLength: 162)!.data)[1], 16)
    }

    func testFreshHostedCopyRejectsShortPasswordBeforeUpload() async throws {
        let rig = try await rig()
        do { _ = try await rig.saver.save(username: "alice_01", password: "too short"); XCTFail("accepted a short password") }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .passwordTooShort) }
        XCTAssertEqual(rig.tower.count("PUT", suffix: "/alice_01"), 0)
        let record = await rig.identity.backupRecord()
        XCTAssertNil(record?.hostedBackupConfirmedAt)
        XCTAssertNil(record?.hostedAttempt)
    }

    func testLostResponseIsRecoveredWithoutASecondUpload() async throws {
        let rig = try await rig()
        rig.tower.dropResponses["PUT /api/v4/identity-backup/alice_01"] = 1   // the server stored it; the answer never arrived
        do { _ = try await rig.saver.save(username: "alice_01", password: password); XCTFail("answer was lost") }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .network); XCTAssertTrue((error as? HostedBackupFailure)?.retryable == true) }
        let staged = await rig.identity.backupRecord()?.hostedAttempt
        XCTAssertEqual(staged?.username, "alice_01")
        XCTAssertNotNil(rig.tower.hosted["alice_01"])
        let gateMid = await rig.identity.paymentBackupGate()
        XCTAssertEqual(gateMid, .hostedBackupRequired, "an unacknowledged upload is not a confirmed backup")

        let confirmation = try await rig.saver.save(username: "alice_01", password: password)
        XCTAssertEqual(confirmation.revision, "1")
        XCTAssertEqual(hostedRequests(rig.tower).filter { $0.method == "PUT" }.count, 1)
        XCTAssertEqual(rig.tower.hosted["alice_01"]?.ncryptsec, staged?.ncryptsec, "the copy on the server is the staged one")
        let gate = await rig.identity.paymentBackupGate()
        XCTAssertEqual(gate, .allowed)
    }

    func testFailedSendReplaysTheIdenticalStagedBody() async throws {
        let rig = try await rig()
        rig.tower.failures["PUT /api/v4/identity-backup/alice_01"] = [URLError(.notConnectedToInternet)]
        do { _ = try await rig.saver.save(username: "alice_01", password: password); XCTFail() }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .network) }
        XCTAssertTrue(rig.tower.hosted.isEmpty)
        _ = try await rig.saver.save(username: "alice_01", password: password)
        let puts = hostedRequests(rig.tower).filter { $0.method == "PUT" }
        XCTAssertEqual(puts.count, 2)
        XCTAssertEqual(puts[0].body["ncryptsec"] as? String, puts[1].body["ncryptsec"] as? String, "same ciphertext, not a fresh random one")
        XCTAssertEqual(puts[1].body["expected_revision"] as? String, "0")
    }

    func testTamperedReadbackIsNotConfirmed() async throws {
        let rig = try await rig()
        rig.tower.hostedTamperReadback = true
        do { _ = try await rig.saver.save(username: "alice_01", password: password); XCTFail("confirmed a mismatching copy") }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .readbackMismatch) }
        let record = await rig.identity.backupRecord()
        XCTAssertNil(record?.hostedBackupConfirmedAt)
        let gate = await rig.identity.paymentBackupGate()
        XCTAssertEqual(gate, .hostedBackupRequired)
    }

    func testPresenceOfARowAloneIsNotProof() async throws {
        // `/me` succeeds, but the stored bytes are not what this device uploaded (and open to a different key).
        let rig = try await rig()
        let foreign = try NIP49.seal(secretKey: Data(repeating: 5, count: 32), password: password, logN: cheap)
        rig.tower.hosted["alice_01"] = .init(owner: rig.npub, ncryptsec: foreign, revision: 4)
        do { _ = try await rig.saver.save(username: "alice_01", password: password); XCTFail() }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .existingBackupDoesNotOpen) }
        XCTAssertEqual(hostedRequests(rig.tower).filter { $0.method == "PUT" }.count, 0, "an existing copy is never overwritten")
        XCTAssertEqual(rig.tower.hosted["alice_01"]?.ncryptsec, foreign)
        let gate = await rig.identity.paymentBackupGate()
        XCTAssertEqual(gate, .hostedBackupRequired)
    }

    func testExistingCopyThatOpensIsAdoptedWithoutAWrite() async throws {
        // Another device of the same identity saved it earlier with the same password.
        let rig = try await rig()
        let secret = try await rig.identity.exportBackup(password: password, logN: cheap)
        rig.tower.hosted["alice_01"] = .init(owner: rig.npub, ncryptsec: secret, revision: 3)
        let confirmation = try await rig.saver.save(username: "alice_01", password: password)
        XCTAssertEqual(confirmation, .init(username: "alice_01", revision: "3"))
        XCTAssertEqual(hostedRequests(rig.tower).filter { $0.method == "PUT" }.count, 0)
    }

    func testUsernameRulesAreCheckedBeforeAnyRequest() async throws {
        let rig = try await rig()
        for bad in ["ab", "Admin", "-bad-", "has space", "a/b", "../x", "x" + String(repeating: "y", count: 40), "ünï", ""] {
            do { _ = try await rig.saver.save(username: bad, password: password); XCTFail(bad) }
            catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .usernameInvalid, bad) }
        }
        XCTAssertTrue(rig.tower.requests.isEmpty)
        XCTAssertEqual(HostedBackupUsername.normalized("ＡＬＩＣＥ"), "alice", "NFKC then lowercase, as the server does")
        XCTAssertNil(HostedBackupUsername.normalized("root"))
    }

    func testTakenUsernameLeavesNothingConfirmedAndAnotherNameWorks() async throws {
        let rig = try await rig()
        rig.tower.hosted["taken_name"] = .init(owner: "npub1someoneelse", ncryptsec: try NIP49.seal(secretKey: Data(repeating: 6, count: 32), password: "x", logN: cheap), revision: 1)
        do { _ = try await rig.saver.save(username: "taken_name", password: password); XCTFail() }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .usernameUnavailable) }
        let gate = await rig.identity.paymentBackupGate()
        XCTAssertEqual(gate, .hostedBackupRequired)
        let confirmation = try await rig.saver.save(username: "free_name", password: password)
        XCTAssertEqual(confirmation.username, "free_name")
        let attempts = await rig.identity.backupRecord()?.hostedAttempt
        XCTAssertNil(attempts)
    }

    func testMissingServiceFailsClosedAndIdentityOrNothingIsConfirmed() async throws {
        let rig = try await rig()
        rig.tower.hostedMounted = false
        do { _ = try await rig.saver.save(username: "alice_01", password: password); XCTFail() }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .backendMissing) }
        let gate = await rig.identity.paymentBackupGate()
        XCTAssertEqual(gate, .hostedBackupRequired)
    }

    func testOnlyAnIdentityCreatedHereHasARequiredHostedBackup() async throws {
        let imported = try await makeIdentity()
        let tower = FakeOnboardingTower()
        let saver = HostedBackupSaver(origin: try TowerOrigin(tower.origin), transport: tower, identity: imported, logN: cheap, acceptedLogN: 10...18)
        do { _ = try await saver.save(username: "alice_01", password: password); XCTFail() }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .notEligible) }
        XCTAssertTrue(tower.requests.isEmpty)
        await imported.lock()
        do { _ = try await saver.save(username: "alice_01", password: password); XCTFail() }
        catch { XCTAssertEqual(error as? IdentityError, .locked) }
    }

    func testStagingFailureStopsBeforeAnyUpload() async throws {
        let rig = try await rig()
        chmod(rig.directory.path, 0o500)
        defer { chmod(rig.directory.path, 0o700) }
        do { _ = try await rig.saver.save(username: "alice_01", password: password); XCTFail("uploaded without a durable record") }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .persistence) }
        XCTAssertEqual(hostedRequests(rig.tower).filter { $0.method == "PUT" }.count, 0)
        XCTAssertTrue(rig.tower.hosted.isEmpty)
    }

    func testRestoreByUsernameNeedsNoSignatureAndYieldsTheSameKey() async throws {
        let rig = try await rig()
        _ = try await rig.saver.save(username: "alice_01", password: password)
        let api = HostedBackupAPI(origin: try TowerOrigin(rig.tower.origin), transport: rig.tower, signer: nil)
        let stored = try await api.fetch(username: "alice_01")
        let other = IdentityService(vaultURL: temporaryDirectory().appendingPathComponent("vault.json"), secrets: MemorySecretStore())
        let state = try await other.importBackup(ncryptsec: stored.ncryptsec, password: password, pin: "1357")
        XCTAssertEqual(state.npub, rig.npub)
        let last = try XCTUnwrap(hostedRequests(rig.tower).last)
        XCTAssertNil(last.signer, "the public read carries no authorization")
        do { _ = try await api.fetch(username: "nobody_here"); XCTFail() }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .notFound) }
        do { _ = try await api.fetch(username: "../me"); XCTFail() }
        catch { XCTAssertEqual((error as? HostedBackupFailure)?.kind, .usernameInvalid) }
    }

    // MARK: Onboarding gate end to end

    private func controller(_ rig: Rig) async throws -> OnboardingController {
        let identity = rig.identity
        let origin = try TowerOrigin(rig.tower.origin)
        return OnboardingController(origin: origin, signerNpub: rig.npub, signer: identity, transport: rig.tower,
                                    store: MemoryOnboardingDraftStore(), returnURL: OnboardingFixture.returnURL,
                                    backupGate: { await identity.paymentBackupGate(origin: origin) },
                                    declaresNewIdentity: { await identity.backupRecord()?.origin == .created },
                                    makeKey: OnboardingFixture.keys())
    }

    func testNewIdentityCannotStartPaymentUntilTheHostedCopyIsConfirmed() async throws {
        let rig = try await rig()
        let c = try await controller(rig)
        _ = await c.load()
        _ = await c.edit(name: "Studio", fundingCents: 2100, agentOfferId: .some(nil), invite: OnboardingInviteCode(OnboardingFixture.invite))
        _ = await c.confirmReview()
        let blocked = await c.continueToPayment()
        XCTAssertEqual(blocked.failure?.kind, .hostedBackupRequired)
        XCTAssertEqual(rig.tower.count("POST", suffix: "/intents"), 0, "no invite seat is claimed")
        XCTAssertEqual(rig.tower.count("POST", suffix: "/account"), 0)

        _ = try await rig.saver.save(username: "alice_01", password: password)
        let refreshed = await c.refreshBackupGate()
        XCTAssertEqual(refreshed.backupGate, .allowed)
        XCTAssertNil(refreshed.failure)
        let paid = await c.continueToPayment()
        XCTAssertNotNil(paid.checkoutURL)
        let create = try XCTUnwrap(rig.tower.requests.first { $0.method == "POST" && $0.path.hasSuffix("/intents") })
        XCTAssertEqual(create.body["identity_origin"] as? String, "new", "the intent declares a new identity so the server guards payment too")
    }

    func testServerSideGuardIsClassifiedEvenIfTheLocalGateWereBypassed() async throws {
        let rig = try await rig()
        let identity = rig.identity
        let c = OnboardingController(origin: try TowerOrigin(rig.tower.origin), signerNpub: rig.npub, signer: identity, transport: rig.tower,
                                     store: MemoryOnboardingDraftStore(), returnURL: OnboardingFixture.returnURL,
                                     backupGate: { .allowed }, declaresNewIdentity: { true }, makeKey: OnboardingFixture.keys())
        _ = await c.load()
        _ = await c.edit(name: "Studio", fundingCents: 2100, agentOfferId: .some(nil), invite: OnboardingInviteCode(OnboardingFixture.invite))
        _ = await c.confirmReview()
        let result = await c.continueToPayment()
        XCTAssertEqual(result.failure?.kind, .hostedBackupRequired)
        XCTAssertNil(result.checkoutURL)
        XCTAssertEqual(rig.tower.count("POST", suffix: "/checkout"), 1, "the server refused it (409 identity_backup_required)")
    }

    func testExistingIdentitiesDeclareNothingAndAreNeverGated() async throws {
        let tower = FakeOnboardingTower()
        tower.inviteCodes[OnboardingFixture.invite] = 21
        let identity = try await makeIdentity()
        let npub = NostrKeys.npub(publicKeyHex: try await identity.publicKeyHex())!
        let c = OnboardingController(origin: try TowerOrigin(tower.origin), signerNpub: npub, signer: identity, transport: tower,
                                     store: MemoryOnboardingDraftStore(), returnURL: OnboardingFixture.returnURL,
                                     backupGate: { await identity.paymentBackupGate() },
                                     declaresNewIdentity: { await identity.backupRecord()?.origin == .created }, makeKey: OnboardingFixture.keys())
        _ = await c.load()
        _ = await c.edit(name: "Studio", fundingCents: 2100, agentOfferId: .some(nil), invite: OnboardingInviteCode(OnboardingFixture.invite))
        _ = await c.confirmReview()
        let paid = await c.continueToPayment()
        XCTAssertNotNil(paid.checkoutURL)
        let create = try XCTUnwrap(tower.requests.first { $0.method == "POST" && $0.path.hasSuffix("/intents") })
        XCTAssertNil(create.body["identity_origin"])
    }
}
