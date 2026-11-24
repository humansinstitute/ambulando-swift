import XCTest
@testable import AmbulandoCore

final class OnboardingTests: XCTestCase {
    private func tower(offers: Bool = false) -> FakeOnboardingTower {
        let t = FakeOnboardingTower()
        t.inviteCodes[OnboardingFixture.invite] = 21
        if offers { t.offers = [.init(id: "7c1f0a52-0000-4000-8000-000000000001", cap: 500, max: 2000)] }
        return t
    }
    private func ready(_ tower: FakeOnboardingTower, store: OnboardingDraftStore = MemoryOnboardingDraftStore(), name: String = "Studio",
                       funding: Int = 2100, agent: String? = nil, signer: IdentityService? = nil, returnURL: URL? = OnboardingFixture.returnURL,
                       keys: (@Sendable () -> String)? = nil) async throws -> (OnboardingController, OnboardingSnapshot) {
        let identity = try await { () async throws -> IdentityService in if let signer { return signer }; return try await makeIdentity() }()
        let c = try await OnboardingFixture.controller(tower, signer: identity, store: store, returnURL: returnURL, keys: keys)
        _ = await c.load()
        _ = await c.edit(name: name, fundingCents: funding, agentOfferId: .some(agent), invite: OnboardingInviteCode(OnboardingFixture.invite))
        return (c, await c.confirmReview())
    }

    // MARK: Contract: signing, URL, secrecy

    func testEveryMutationCarriesPayloadHashAndInviteStaysOutOfURLs() async throws {
        let t = tower()
        let (c, review) = try await ready(t)
        XCTAssertEqual(review.phase, .review)
        let paid = await c.continueToPayment()
        XCTAssertEqual(paid.phase, .awaitingPayment)
        XCTAssertNil(paid.failure)
        // The fake rejects (401) any mutation lacking a valid payload tag, so success proves strict NIP-98 including bodiless POST /account.
        XCTAssertGreaterThan(t.count("POST", suffix: "/account"), 0)
        for request in t.requests {
            XCTAssertFalse(request.url.absoluteString.contains("inv_"), "invite must never be in a URL")
            XCTAssertTrue(request.url.absoluteString.hasPrefix("https://tower.example/"))
        }
        XCTAssertEqual(t.requests.first { $0.path.hasSuffix("/intents") && $0.method == "POST" }?.body["invite_code"] as? String, OnboardingFixture.invite)
        XCTAssertEqual("\(OnboardingInviteCode(OnboardingFixture.invite)!)", "inv_••••")
        XCTAssertFalse("\(String(reflecting: OnboardingInviteCode(OnboardingFixture.invite)!))".contains("fixtureCode"))
    }

    func testInviteIsOnlyOnDeviceUntilServerAcceptsIt() async throws {
        let dir = temporaryDirectory()
        let store = FileOnboardingDraftStore(directory: dir)
        let t = tower()
        let (c, _) = try await ready(t, store: store)
        func draftFiles() throws -> String {
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        }
        XCTAssertTrue(try draftFiles().contains(OnboardingFixture.invite), "needed to replay an interrupted create")
        _ = await c.continueToPayment()
        XCTAssertFalse(try draftFiles().contains(OnboardingFixture.invite), "removed once the intent id is recorded")
    }

    func testInviteInputParsing() throws {
        XCTAssertEqual(OnboardingInviteInput.parse(" \(OnboardingFixture.invite) \n")?.code.rawValue, OnboardingFixture.invite)
        XCTAssertNil(OnboardingInviteInput.parse(OnboardingFixture.invite)?.suggestedOrigin)
        let link = OnboardingInviteInput.parse("https://tower.example/join?invite=\(OnboardingFixture.invite)")
        XCTAssertEqual(link?.suggestedOrigin?.description, "https://tower.example")
        XCTAssertEqual(OnboardingInviteInput.parse("https://tower.example:8443/#invite=\(OnboardingFixture.invite)")?.suggestedOrigin?.description, "https://tower.example:8443")
        for bad in ["http://tower.example/?invite=\(OnboardingFixture.invite)", "https://u:p@tower.example/?invite=\(OnboardingFixture.invite)",
                    "https://tower.example/?invite=a&invite=\(OnboardingFixture.invite)", "https://tower.example/?invite=notacode",
                    "https://tower.example/\(OnboardingFixture.invite)", "javascript:alert(1)", "inv_abc", "", "https://abc.fips/?invite=\(OnboardingFixture.invite)"] {
            XCTAssertNil(OnboardingInviteInput.parse(bad), bad)
        }
    }

    func testOriginMustMatchItsOwnDescriptorBeforeAnythingIsSigned() async throws {
        let t = tower(); t.descriptorOrigin = "https://elsewhere.example"
        let c = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: MemoryOnboardingDraftStore())
        let snap = await c.load()
        guard case .unavailable(.originRejected) = snap.phase else { return XCTFail("\(snap.phase)") }
        XCTAssertTrue(t.requests.allSatisfy { $0.path == "/.well-known/nstack.json" }, "no signed request may reach an unverified origin")
        XCTAssertThrowsError(try TowerOrigin("http://tower.example"))
    }

    func testMissingBackendAndDisabledRolloutAreClearStates() async throws {
        let missing = tower(); missing.onboardingRouteMounted = false
        let c1 = try await OnboardingFixture.controller(missing, signer: makeIdentity(), store: MemoryOnboardingDraftStore())
        let awaited1 = await c1.load().phase
        XCTAssertEqual(awaited1, .unavailable(.backendMissing))

        let off = tower(); off.rolloutEnabled = false
        let (c2, _) = try await ready(off)
        let snap = await c2.continueToPayment()
        XCTAssertEqual(snap.phase, .unavailable(.rolloutDisabled))
        XCTAssertEqual(off.count("POST", suffix: "/checkout"), 0)
    }

    // MARK: Identity and account isolation

    func testAnotherSignerNeverSeesOrReusesState() async throws {
        let t = tower()
        let store = MemoryOnboardingDraftStore()
        let (a, _) = try await ready(t, store: store, name: "Alpha", keys: OnboardingController.randomKey)
        _ = await a.continueToPayment()
        let aliceDraft = await a.snapshot().draft
        let bob = try await OnboardingFixture.otherIdentity()
        let bobNpub = NostrKeys.npub(publicKeyHex: try await bob.publicKeyHex())!
        XCTAssertNotEqual(bobNpub, aliceDraft.signerNpub)
        let b = try await OnboardingFixture.controller(t, signer: bob, store: store, keys: OnboardingController.randomKey)
        let snap = await b.load()
        XCTAssertNil(snap.intent, "Bob has no intent; Alice's is invisible to him")
        XCTAssertNil(snap.draft.intentId)
        XCTAssertNotEqual(snap.draft.createKey, aliceDraft.createKey)
        XCTAssertEqual(snap.draft.signerNpub, bobNpub)
        // Bob asking for Alice's intent by id gets the neutral 404 mapping and keys rotate rather than being reused.
        var forged = aliceDraft; forged = OnboardingDraft(origin: aliceDraft.origin, signerNpub: bobNpub, createKey: "ob_bob_create_key", checkoutKey: "ob_bob_checkout_key")
        forged.intentId = aliceDraft.intentId
        try store.save(forged)
        let b2 = try await OnboardingFixture.controller(t, signer: bob, store: store)
        let after = await b2.load()
        XCTAssertNil(after.draft.intentId)
        XCTAssertNil(after.intent)
        XCTAssertNotEqual(after.draft.createKey, "ob_bob_create_key")
    }

    func testSignerMismatchSendsNothingSigned() async throws {
        let t = tower()
        let alice = try await makeIdentity()
        let bob = try await OnboardingFixture.otherIdentity()
        let aliceNpub = NostrKeys.npub(publicKeyHex: try await alice.publicKeyHex())!
        let c = OnboardingController(origin: try TowerOrigin(t.origin), signerNpub: aliceNpub, signer: bob, transport: t, store: MemoryOnboardingDraftStore(), returnURL: OnboardingFixture.returnURL)
        let awaited3 = await c.load().phase
        XCTAssertEqual(awaited3, .unavailable(.signerMismatch))
        let awaited5 = await c.provision().phase
        XCTAssertEqual(awaited5, .unavailable(.signerMismatch))
        XCTAssertTrue(t.requests.allSatisfy { $0.signer == nil })
    }

    func testDraftStoreIsKeyedByOriginAndSigner() throws {
        let store = FileOnboardingDraftStore(directory: temporaryDirectory())
        var a = OnboardingDraft(origin: "https://a.example", signerNpub: TestKeys.npub, createKey: "k1xxxxxxxx", checkoutKey: "c1xxxxxxxx"); a.workspaceName = "A"
        try store.save(a)
        XCTAssertEqual(store.load(origin: "https://a.example", signerNpub: TestKeys.npub)?.workspaceName, "A")
        XCTAssertNil(store.load(origin: "https://b.example", signerNpub: TestKeys.npub))
        XCTAssertNil(store.load(origin: "https://a.example", signerNpub: "npub1other"))
    }

    // MARK: Invitation cap

    func testInviteCapResponseStopsBeforeAnyPayment() async throws {
        let t = tower(); t.inviteCodes[OnboardingFixture.invite] = 1
        let (a, _) = try await ready(t, name: "First")
        let awaited7 = await a.continueToPayment().failure
        XCTAssertNil(awaited7)
        let bob = try await OnboardingFixture.otherIdentity()
        let (b, _) = try await ready(t, name: "Second", signer: bob)
        let snap = await b.continueToPayment()
        XCTAssertEqual(snap.failure?.kind, .inviteFull)
        XCTAssertNil(snap.intent)
        XCTAssertNil(snap.checkoutURL)
        XCTAssertEqual(t.count("POST", suffix: "/checkout"), 1, "only the first identity ever reached checkout")
        XCTAssertNotNil(snap.draft.invite, "kept so the user can retry if a place is released")
    }

    func testSeatIsPerIdentityNotPerAttempt() async throws {
        let t = tower(); t.inviteCodes[OnboardingFixture.invite] = 1
        let (a, _) = try await ready(t)
        _ = await a.continueToPayment()
        _ = await a.refresh(); _ = await a.continueToPayment()
        XCTAssertEqual(t.seats[OnboardingFixture.invite]?.count, 1)
    }

    // MARK: Revisions

    func testStaleRevisionFetchesLatestAndRequiresReview() async throws {
        let t = tower()
        let (c, _) = try await ready(t)
        _ = await c.continueToPayment()
        let idSnap = await c.snapshot()
        let id = try XCTUnwrap(idSnap.intent?.id)
        t.bumpRevision(id)                         // changed elsewhere (another device)
        _ = await c.edit(name: "Renamed")
        _ = await c.confirmReview()
        let snap = await c.continueToPayment()
        XCTAssertEqual(snap.failure?.kind, .staleRevision)
        XCTAssertEqual(snap.intent?.revision, 2)
        XCTAssertEqual(snap.draft.workspaceName, "Studio", "the server's version is adopted, not the unsent edit")
        XCTAssertNotEqual(snap.phase, .review, "the user has to review the reconciled choices again")
        // After reviewing again the change goes through with the fresh revision.
        _ = await c.edit(name: "Renamed"); _ = await c.confirmReview()
        let again = await c.continueToPayment()
        XCTAssertNil(again.failure)
        XCTAssertEqual(again.intent?.workspace_name, "Renamed")
    }

    func testFundingCannotBeChangedAfterCheckoutStarted() async throws {
        let t = tower()
        let (c, _) = try await ready(t)
        _ = await c.continueToPayment()
        _ = await c.edit(fundingCents: 5000); _ = await c.confirmReview()
        let snap = await c.continueToPayment()
        XCTAssertEqual(snap.failure?.kind, .notEditable)
        XCTAssertEqual(snap.intent?.funding_cents, 2100)
    }

    // MARK: Durable state and identity binding

    func testUnsavableDraftStopsEverySideEffect() async throws {
        let t = tower()
        let store = FlakyDraftStore()                         // every write fails
        let (c, _) = try await ready(t, store: store)
        let snap = await c.continueToPayment()
        XCTAssertEqual(snap.failure?.kind, .persistence)
        XCTAssertNil(snap.checkoutURL)
        XCTAssertTrue(t.requests.filter { $0.path.hasPrefix("/api/v4/onboarding") && $0.method == "POST" }.isEmpty, "no account, create or checkout request")
        XCTAssertTrue(t.intents.isEmpty)
    }

    func testBindingSaveFailureAfterCreateStopsBeforeCheckoutAndRelaunchReusesKeys() async throws {
        let t = tower()
        let store = FlakyDraftStore { $0.intentId != nil }    // keys save; the intent binding does not
        let (c, _) = try await ready(t, store: store)
        let snap = await c.continueToPayment()
        XCTAssertEqual(snap.failure?.kind, .persistence)
        XCTAssertEqual(t.intents.count, 1, "the server did accept the create")
        XCTAssertEqual(t.count("POST", suffix: "/checkout"), 0)
        XCTAssertNil(snap.checkoutURL)
        let onDisk = try XCTUnwrap(store.load(origin: t.origin, signerNpub: snap.draft.signerNpub))
        XCTAssertEqual(onDisk.createKey, snap.draft.createKey)
        XCTAssertNil(onDisk.intentId)
        store.heal()
        let c2 = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: store)
        let loaded = await c2.load()
        XCTAssertEqual(loaded.draft.checkoutKey, snap.draft.checkoutKey)
        _ = await c2.confirmReview()
        let resumed = await c2.continueToPayment()
        XCTAssertNil(resumed.failure)
        XCTAssertEqual(t.intents.count, 1)
        XCTAssertEqual(t.checkoutOrders.count, 1)
    }

    func testOrderBindingSaveFailureNeverOpensCheckoutAndRelaunchReplaysSameOrder() async throws {
        let t = tower()
        let store = FlakyDraftStore { $0.checkoutOrderId != nil }
        let (c, _) = try await ready(t, store: store)
        let snap = await c.continueToPayment()
        XCTAssertEqual(snap.failure?.kind, .persistence)
        XCTAssertNil(snap.checkoutURL, "the browser is never opened with an unsaved order")
        XCTAssertEqual(t.checkoutOrders.count, 1)
        store.heal()
        let c2 = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: store)
        _ = await c2.load(); _ = await c2.confirmReview()
        let again = await c2.continueToPayment()
        XCTAssertNil(again.failure)
        XCTAssertEqual(t.checkoutOrders.count, 1, "same key, same order: no second payable checkout")
        XCTAssertNotNil(again.checkoutURL)
    }

    func testIdentityChangeDuringOperationNeverSignsDraftAsAnotherIdentity() async throws {
        let t = tower()
        let alice = try await makeIdentity()
        let bob = try await OnboardingFixture.otherIdentity()
        let bobNpub = NostrKeys.npub(publicKeyHex: try await bob.publicKeyHex())!
        let swappable = SwappableSigner(alice)
        let aliceNpub = NostrKeys.npub(publicKeyHex: try await alice.publicKeyHex())!
        let c = OnboardingController(origin: try TowerOrigin(t.origin), signerNpub: aliceNpub, signer: swappable, transport: t,
                                    store: MemoryOnboardingDraftStore(), returnURL: OnboardingFixture.returnURL, makeKey: OnboardingFixture.keys())
        _ = await c.load()
        _ = await c.edit(name: "Studio", fundingCents: 2100, invite: OnboardingInviteCode(OnboardingFixture.invite))
        _ = await c.confirmReview()
        // The identity changes after the create request has been signed and sent, before checkout is signed.
        t.hook = { seen in if seen.method == "POST", seen.path.hasSuffix("/intents") { swappable.swap(to: bob) } }
        let snap = await c.continueToPayment()
        XCTAssertEqual(snap.phase, .unavailable(.signerMismatch))
        XCTAssertEqual(t.count("POST", suffix: "/checkout"), 0, "checkout was never signed or sent")
        XCTAssertFalse(t.requests.contains { $0.signer == bobNpub }, "nothing from this draft was signed as the new identity")
        // Cancel and provision are bound the same way.
        let cancelled = await c.cancelSetup()
        XCTAssertEqual(cancelled.phase, .unavailable(.signerMismatch))
        XCTAssertEqual(t.count("POST", suffix: "/cancel"), 0)
        let provisioned = await c.provision()
        XCTAssertEqual(provisioned.phase, .unavailable(.signerMismatch))
        XCTAssertFalse(t.requests.contains { $0.signer == bobNpub })
    }

    func testBoundSignerRejectsAForeignEventEvenIfKeyLookupLooksRight() async throws {
        struct Liar: EventSigner {
            let claimed: String; let real: IdentityService
            func publicKeyHex() async throws -> String { claimed }
            func sign(_ t: NostrEventTemplate) async throws -> NostrEvent { try await real.sign(t) }
        }
        let alice = try await makeIdentity(), bob = try await OnboardingFixture.otherIdentity()
        let aliceHex = try await alice.publicKeyHex()
        let bound = BoundSigner(inner: Liar(claimed: aliceHex, real: bob), expectedHex: aliceHex)
        do { _ = try await bound.sign(NostrEventTemplate(kind: 27235, tags: [], content: "")); XCTFail("signed") }
        catch { XCTAssertEqual(error as? IdentityError, .signerMismatch) }
    }

    // MARK: Payment truth

    func testReturnOrRedirectNeverFundsOnlyServerEvidenceDoes() async throws {
        let t = tower()
        let (c, _) = try await ready(t)
        let paying = await c.continueToPayment()
        XCTAssertEqual(paying.checkoutURL?.host, "checkout.stripe.com")
        XCTAssertEqual(paying.draft.checkoutOrderId, t.checkoutOrders.values.first)
        let before = t.requests.count
        // Forged and cancelled returns: wrong host, wrong path, lookalike scheme.
        for forged in ["https://evil.example/billing/return?status=paid", "https://tower.example/other?paid=1", "ambulando://paid", "http://tower.example/billing/return"] {
            let snap = await c.paymentReturned(URL(string: forged))
            XCTAssertEqual(snap.phase, .awaitingPayment, forged)
            XCTAssertNotNil(snap.notice)
        }
        XCTAssertEqual(t.requests.count, before, "an untrusted return triggers no request at all")
        // Even the genuine return address with a "paid" claim only prompts a server read; the server says still open.
        let cancelled = await c.paymentReturned(URL(string: "https://tower.example/billing/return?status=paid"))
        XCTAssertEqual(cancelled.phase, .awaitingPayment)
        XCTAssertFalse(cancelled.intent!.fundingConfirmed)
        // The webhook (server side) is the only thing that funds.
        t.fund(cancelled.intent!.id)
        let funded = await c.paymentReturned(OnboardingFixture.returnURL)
        XCTAssertEqual(funded.phase, .readyToProvision)
        XCTAssertTrue(funded.intent!.fundingConfirmed)
    }

    func testPendingPaymentBlocksProvisionBeforeAnyRequest() async throws {
        let t = tower()
        let (c, _) = try await ready(t)
        _ = await c.continueToPayment()
        let snap = await c.provision()
        XCTAssertEqual(snap.failure?.kind, .fundingRequired)
        XCTAssertEqual(t.count("POST", suffix: "/provision"), 0)
    }

    func testReversedFundingStopsProvisioning() async throws {
        let t = tower()
        let (c, _) = try await ready(t)
        let idSnap = await c.continueToPayment()
        let id = try XCTUnwrap(idSnap.intent?.id)
        t.fund(id); t.lock.withLock { t.intents[0].reversed = true }
        let snap = await c.provision()
        XCTAssertEqual(snap.failure?.kind, .fundingRequired)
        XCTAssertEqual(t.count("POST", suffix: "/provision"), 0)
    }

    func testCheckoutResponseIsValidatedFailClosed() async throws {
        for (label, mutate): (String, (FakeOnboardingTower) -> Void) in [
            ("foreign host", { $0.checkoutURL = "https://evil.example/pay" }),
            ("stripe lookalike", { $0.checkoutURL = "https://checkout.stripe.com.evil.example/pay" }),
            ("http", { $0.checkoutURL = "http://checkout.stripe.com/pay" }),
            ("live mode", { $0.checkoutMode = "live" }),
            ("amount drift", { $0.checkoutAmountOffset = 100 })] {
            let t = tower(); mutate(t)
            let (c, _) = try await ready(t)
            let snap = await c.continueToPayment()
            XCTAssertEqual(snap.failure?.kind, .paymentUnavailable, label)
            XCTAssertNil(snap.checkoutURL, label)
        }
    }

    func testPaymentOptionsFailClosed() async throws {
        let t = tower()
        let (c, _) = try await ready(t, returnURL: nil)
        let snap = await c.snapshot()
        XCTAssertEqual(snap.paymentOptions.first { $0.method == .card }?.available, false)
        XCTAssertEqual(snap.paymentOptions.first { $0.method == .lightning }?.available, false)
        let paid = await c.continueToPayment()
        XCTAssertEqual(paid.failure?.kind, .paymentUnavailable)
        XCTAssertEqual(t.count("POST", suffix: "/checkout"), 0)
        XCTAssertNil(OnboardingController.approvedReturn(URL(string: "https://u:p@tower.example/return")!))
        XCTAssertNil(OnboardingController.approvedReturn(URL(string: "https://tower.example/return?x=1")!))
        XCTAssertNil(OnboardingController.approvedReturn(URL(string: "http://tower.example/return")!))
        XCTAssertNotNil(OnboardingController.approvedReturn(URL(string: "http://localhost:3000/return")!))
    }

    // MARK: Relaunch, retries, duplicate protection

    func testAmbiguousCheckoutThenGateUnavailableKeepsProgressAndKeysWithoutFinancialAssurance() async throws {
        let t = tower()
        t.dropResponses["/checkout"] = 1                        // checkout order was made; the answer was lost
        let dir = temporaryDirectory()
        let (c, _) = try await ready(t, store: FileOnboardingDraftStore(directory: dir))
        let first = await c.continueToPayment()
        XCTAssertEqual(first.failure?.kind, .network)
        let intentId = try XCTUnwrap(first.draft.intentId), key = first.draft.checkoutKey
        // Meanwhile the payment completes server-side and the rollout gate then turns off.
        t.fund(intentId); t.rolloutEnabled = false
        let retry = await c.continueToPayment()
        XCTAssertEqual(retry.phase, .unavailable(.rolloutDisabled))
        XCTAssertEqual(retry.draft.intentId, intentId, "progress retained")
        XCTAssertEqual(retry.draft.checkoutKey, key, "operation key unchanged")
        for text in [retry.failure?.localizedDescription ?? "", OnboardingFailure(kind: .paymentUnavailable).localizedDescription] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("nothing was"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("charged"), text)
            XCTAssertFalse(text.contains("Tower"), text)
        }
        let checkoutsBefore = t.count("POST", suffix: "/checkout")
        XCTAssertEqual(checkoutsBefore, 2, "the lost attempt and the retry the gate refused")
        let sentKeys = t.requests.filter { $0.path.hasSuffix("/checkout") }.compactMap { $0.body["idempotency_key"] as? String }
        XCTAssertEqual(sentKeys, [key, key])
        // Relaunch while the gate is still off: reads still show the server's verified funding, and no new checkout is made.
        let c2 = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: FileOnboardingDraftStore(directory: dir))
        let loaded = await c2.load()
        XCTAssertEqual(loaded.phase, .readyToProvision)
        XCTAssertTrue(loaded.intent!.fundingConfirmed)
        XCTAssertEqual(t.count("POST", suffix: "/checkout"), checkoutsBefore)
        t.rolloutEnabled = true
        let done = await c2.provision()
        XCTAssertEqual(done.phase, .provisioned)
        XCTAssertEqual(t.count("POST", suffix: "/checkout"), checkoutsBefore)
    }

    func testNetworkFailureThenRelaunchReusesEveryOperationKey() async throws {
        let dir = temporaryDirectory()
        let t = tower()
        t.failures["POST /api/v4/onboarding/intents"] = [URLError(.notConnectedToInternet)]
        let (c, _) = try await ready(t, store: FileOnboardingDraftStore(directory: dir))
        let first = await c.continueToPayment()
        XCTAssertEqual(first.failure?.kind, .network)
        XCTAssertEqual(first.draft.invite?.rawValue, OnboardingFixture.invite)
        let createKey = first.draft.createKey, checkoutKey = first.draft.checkoutKey
        // Relaunch: a new controller and store over the same files.
        let c2 = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: FileOnboardingDraftStore(directory: dir))
        let loaded = await c2.load()
        XCTAssertEqual(loaded.draft.createKey, createKey)
        XCTAssertEqual(loaded.draft.workspaceName, "Studio")
        _ = await c2.confirmReview()
        let second = await c2.continueToPayment()
        XCTAssertNil(second.failure)
        let creates = t.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/intents") }
        XCTAssertEqual(creates.count, 2)
        XCTAssertEqual(Set(creates.compactMap { $0.body["client_request_key"] as? String }), [createKey])
        XCTAssertEqual(t.requests.first { $0.path.hasSuffix("/checkout") }?.body["idempotency_key"] as? String, checkoutKey)
    }

    func testLostCreateResponseDoesNotDuplicateTheIntent() async throws {
        let t = tower()
        t.dropResponses["POST /api/v4/onboarding/intents"] = 1       // server created it; the answer never arrived
        let dir = temporaryDirectory()
        let (c, _) = try await ready(t, store: FileOnboardingDraftStore(directory: dir))
        let awaited9 = await c.continueToPayment().failure?.kind
        XCTAssertEqual(awaited9, .network)
        XCTAssertEqual(t.intents.count, 1)
        let c2 = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: FileOnboardingDraftStore(directory: dir))
        _ = await c2.load(); _ = await c2.confirmReview()
        let resumed = await c2.continueToPayment()
        XCTAssertNil(resumed.failure)
        XCTAssertEqual(t.intents.count, 1, "replay with the same key returns the same intent")
        XCTAssertEqual(resumed.phase, .awaitingPayment)
    }

    func testRelaunchWithoutDraftAdoptsServersIntentInsteadOfCreatingAnother() async throws {
        let t = tower()
        let (c, _) = try await ready(t)
        _ = await c.continueToPayment()
        let fresh = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: MemoryOnboardingDraftStore())
        let snap = await fresh.load()
        XCTAssertEqual(snap.intent?.id, t.intents[0].id)
        XCTAssertEqual(snap.phase, .form, "resumed, but the user must review again before any payment step")
        XCTAssertEqual(t.intents.count, 1)
    }

    func testDuplicateProvisionTapsAndRelaunchIssueOneServerRequest() async throws {
        let t = tower(); t.provisionDelay = 0.2
        let (c, _) = try await ready(t)
        let idSnap = await c.continueToPayment()
        let id = try XCTUnwrap(idSnap.intent?.id)
        t.fund(id)
        async let one = c.provision()
        async let two = c.provision()
        let (a, b) = await (one, two)
        XCTAssertEqual(a.phase, .provisioned); XCTAssertEqual(b.phase, .provisioned)
        XCTAssertEqual(t.count("POST", suffix: "/provision"), 1)
        // Relaunch and "resume": already provisioned, so nothing further is requested.
        let again = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: MemoryOnboardingDraftStore())
        let loaded = await again.load()
        _ = loaded
        let c3 = await c.provision()
        XCTAssertEqual(c3.phase, .provisioned)
        XCTAssertEqual(t.count("POST", suffix: "/provision"), 1)
        XCTAssertEqual(t.count("POST", suffix: "/checkout"), 1)
    }

    func testSetupFailureKeepsCreditAndResumesWithoutSecondCheckout() async throws {
        let t = tower(); t.provisionFailures = 1
        let (c, _) = try await ready(t)
        let idSnap = await c.continueToPayment()
        let id = try XCTUnwrap(idSnap.intent?.id)
        t.fund(id)
        let failed = await c.provision()
        XCTAssertEqual(failed.failure?.kind, .provisioningFailed)
        XCTAssertEqual(failed.phase, .provisioning)
        XCTAssertEqual(failed.intent?.last_error, "billing_link:billing_owner_conflict")
        XCTAssertTrue(failed.intent!.fundingConfirmed)
        let done = await c.provision()
        XCTAssertEqual(done.phase, .provisioned)
        XCTAssertEqual(t.count("POST", suffix: "/checkout"), 1)
        XCTAssertEqual(t.intents.count, 1)
    }

    // MARK: Agents, landing, catalogue

    func testEmptyCatalogueFailsClosedAndNeverInventsAnAgent() async throws {
        let t = tower()
        let c = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: MemoryOnboardingDraftStore())
        let loaded = await c.load()
        XCTAssertTrue(loaded.offers.isEmpty)
        _ = await c.edit(name: "Studio", agentOfferId: .some("7c1f0a52-0000-4000-8000-000000000001"), invite: OnboardingInviteCode(OnboardingFixture.invite))
        let snap = await c.confirmReview()
        XCTAssertEqual(snap.failure?.kind, .agentUnavailable)
        XCTAssertNotEqual(snap.phase, .review)
    }

    func testSelectedAgentIsNotRunningAndNothingIsSentForTheUser() async throws {
        let t = tower(offers: true)
        let agent = "7c1f0a52-0000-4000-8000-000000000001"
        let (c, review) = try await ready(t, agent: agent)
        XCTAssertEqual(review.phase, .review)
        XCTAssertEqual(review.draft.agentDailyCapCents, 500, "effective cap is pinned from the catalogue, not hardcoded")
        let idSnap = await c.continueToPayment()
        let id = try XCTUnwrap(idSnap.intent?.id)
        t.fund(id)
        let snap = await c.provision()
        XCTAssertEqual(snap.phase, .provisioned)
        XCTAssertEqual(snap.intent?.agent_state, .selected_not_provisioned)
        let landing = try XCTUnwrap(snap.landing)
        XCTAssertFalse(landing.agentRunning)
        XCTAssertFalse(landing.generalReady, "no General step is recorded by the server, so none is claimed")
        XCTAssertNotNil(landing.workspaceId)
        XCTAssertTrue(snap.agentNeedsFirstRequest)
        XCTAssertTrue(t.requests.allSatisfy { !$0.path.contains("message") }, "the app sends no paid work on its own")
    }

    func testAgentCapAboveOfferMaximumIsRejectedLocally() async throws {
        let t = tower(offers: true)
        let c = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: MemoryOnboardingDraftStore())
        _ = await c.load()
        _ = await c.edit(name: "Studio", agentOfferId: .some("7c1f0a52-0000-4000-8000-000000000001"), agentDailyCapCents: .some(99_999), invite: OnboardingInviteCode(OnboardingFixture.invite))
        let awaited11 = await c.confirmReview().failure?.kind
        XCTAssertEqual(awaited11, .validation)
    }

    func testCancelReleasesAndRotatesKeys() async throws {
        let t = tower()
        let (c, _) = try await ready(t)
        let paying = await c.continueToPayment()
        let oldKey = paying.draft.createKey
        let cancelled = await c.cancelSetup()
        XCTAssertEqual(cancelled.intent?.status, .cancelled)
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertNil(cancelled.draft.intentId)
        XCTAssertNotEqual(cancelled.draft.createKey, oldKey)
    }

    // MARK: Form helpers

    func testFundingChoices() {
        XCTAssertEqual(OnboardingFunding.presetsCents, [2100, 5000, 10000])
        XCTAssertEqual(OnboardingFunding.cents(fromDollars: "21"), 2100)
        XCTAssertEqual(OnboardingFunding.cents(fromDollars: "37.5"), 3750)
        XCTAssertEqual(OnboardingFunding.cents(fromDollars: "10000"), 1_000_000)
        for bad in ["20.99", "20", "-30", "30.001", "1e3", "", "30,00", "10000.01", "abc", "$30"] { XCTAssertNil(OnboardingFunding.cents(fromDollars: bad), bad) }
        XCTAssertEqual(OnboardingFunding.label(cents: 2100), "US$21")
        XCTAssertEqual(OnboardingFunding.label(cents: 3750), "US$37.50")
        XCTAssertNil(OnboardingName.normalized("   "))
        XCTAssertEqual(OnboardingName.normalized("  Studio "), "Studio")
        XCTAssertNil(OnboardingName.normalized(String(repeating: "x", count: 81)))
    }

    func testIntentJSONIsDecodedFromTheRealShape() throws {
        let t = tower()
        let intent = FakeOnboardingTower.Intent(owner: TestKeys.npub, key: "k", digest: "d", name: "Studio", funding: 2100)
        let data = try JSONSerialization.data(withJSONObject: t.view(intent))
        let decoded = try JSONDecoder().decode(OnboardingIntent.self, from: data)
        XCTAssertEqual(decoded.status, .open)
        XCTAssertFalse(decoded.fundingConfirmed)
        XCTAssertEqual(decoded.agent_state, .none)
    }
}
