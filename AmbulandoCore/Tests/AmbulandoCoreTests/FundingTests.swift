import XCTest
@testable import AmbulandoCore

/// Lightning setup during invited onboarding and manual account top-ups, against `FakeOnboardingTower`, which follows NStack's real routes,
/// bodies and strict NIP-98 rules (tower src/routes/onboarding.ts, services/hosting-lightning.ts, services/hosting-topup.ts).
final class FundingTests: XCTestCase {
    private let returnAddress = OnboardingFixture.returnURL.absoluteString

    private func config(lightning: Bool? = true, card: Bool = true, mode: String = "test", enabled: Bool = true, topup: (Int, Int)? = nil) -> [String: Any] {
        var out: [String: Any] = ["version": 1, "onboarding_enabled": enabled,
                                  "card": ["available": card, "mode": mode, "return_urls": [returnAddress]] as [String: Any]]
        var funding: [String: Any] = ["min_cents": 2100, "max_cents": 1_000_000]
        if let topup { funding["topup_min_cents"] = topup.0; funding["topup_max_cents"] = topup.1 } else { funding["topup_min_cents"] = 2100; funding["topup_max_cents"] = 1_000_000 }
        out["funding"] = funding
        if let lightning { out["lightning"] = ["available": lightning] }
        return out
    }
    private func tower(lightning: Bool? = true) -> FakeOnboardingTower {
        let t = FakeOnboardingTower()
        t.inviteCodes[OnboardingFixture.invite] = 21
        t.deploymentConfig = config(lightning: lightning)
        return t
    }
    private func ready(_ tower: FakeOnboardingTower, store: OnboardingDraftStore = MemoryOnboardingDraftStore(), funding: Int = 2100,
                       signer: IdentityService? = nil, keys: (@Sendable () -> String)? = nil) async throws -> (OnboardingController, OnboardingSnapshot) {
        let identity = try await { () async throws -> IdentityService in if let signer { return signer }; return try await makeIdentity() }()
        let c = try await OnboardingFixture.controller(tower, signer: identity, store: store, returnURL: nil, keys: keys)
        _ = await c.load()
        _ = await c.edit(name: "Studio", fundingCents: funding, agentOfferId: .some(nil), invite: OnboardingInviteCode(OnboardingFixture.invite))
        return (c, await c.confirmReview())
    }
    private func posts(_ t: FakeOnboardingTower) -> Int { t.requests.filter { $0.method == "POST" && $0.path.hasPrefix("/api/v4/onboarding") }.count }

    // MARK: Invoice parsing

    func testInvoiceAmountIsReadFromTheHumanReadablePartAndMustMatchSats() {
        let tail = "pp5qqqsyqcyq5rqwzqfqypqdpl2pcs"   // data part is not interpreted; only the prefix is
        XCTAssertEqual(PayableInvoice.satsNamed(by: "lnbc20u1" + tail), .some(2000))
        XCTAssertEqual(PayableInvoice.satsNamed(by: "lnbc2500u1" + tail), .some(250_000))
        XCTAssertEqual(PayableInvoice.satsNamed(by: "lnbc1m1" + tail), .some(100_000))
        XCTAssertEqual(PayableInvoice.satsNamed(by: "lnbc10n1" + tail), .some(1))
        XCTAssertEqual(PayableInvoice.satsNamed(by: "lntb100u1" + tail), .some(10_000))
        XCTAssertEqual(PayableInvoice.satsNamed(by: "lnbc1" + tail), .some(nil), "an amountless invoice is well formed")
        XCTAssertNil(PayableInvoice.satsNamed(by: "lnbc1n1" + tail), "a fraction of a satoshi is refused")
        XCTAssertNil(PayableInvoice.satsNamed(by: "lnbc0u1" + tail))
        XCTAssertNil(PayableInvoice.satsNamed(by: "lnbc20x1" + tail))
        XCTAssertNil(PayableInvoice.satsNamed(by: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"))
        XCTAssertNil(PayableInvoice.satsNamed(by: "lnbc20u1 " + tail), "whitespace is refused")
        XCTAssertNil(PayableInvoice.satsNamed(by: "lnbc99999999999999999999u1" + tail), "overflow is refused")
    }

    func testQuoteJSONIsDecodedFromTheRealShape() throws {
        let json = """
        {"id":"7c1f0a52-0000-4000-8000-000000000009","intent_id":null,"state":"late_payment","amount_cents":2100,"amount_sats":52500,
         "invoice":"lnbc525000n1abc","payment_hash":"\(String(repeating: "a", count: 64))","expires_at":"2026-11-24T00:10:00.000Z",
         "rate":{"source":"fixture","quoted_at":"2026-11-24T00:00:00.000Z"},"future_field":1}
        """
        let quote = try JSONDecoder().decode(LightningQuote.self, from: Data(json.utf8))
        XCTAssertEqual(quote.state, .latePayment)
        XCTAssertTrue(quote.state.needsSupport)
        XCTAssertNil(quote.intent_id)
        XCTAssertFalse(quote.payable, "a late payment is never presented as payable")
        XCTAssertEqual(LightningQuoteState("brand_new"), .unknown("brand_new"))
        XCTAssertTrue(LightningQuoteState("brand_new").needsSupport, "an unknown state is never treated as paid or free")
    }

    // MARK: Lightning during onboarding

    func testQuoteRequestIsStrictlySignedBoundToTheIntentAndShowsExactInvoice() async throws {
        let t = tower()
        let (c, review) = try await ready(t)
        XCTAssertEqual(review.paymentOptions.first { $0.method == .lightning }?.available, true)
        let snap = await c.continueToLightning()
        XCTAssertNil(snap.failure)
        XCTAssertEqual(snap.phase, .awaitingPayment)
        let intentId = try XCTUnwrap(t.intents.first?.id)
        let request = try XCTUnwrap(t.requests.first { $0.path.hasSuffix("/lightning/quote") })
        XCTAssertEqual(request.path, "/api/v4/onboarding/intents/\(intentId)/lightning/quote")
        XCTAssertEqual(Set(request.body.keys), ["idempotency_key"], "the USD amount is the server's, never sent")
        XCTAssertNotNil(request.signer)
        let invoice = try XCTUnwrap(snap.lightningInvoice)
        XCTAssertEqual(invoice.sats, 2100 * 25)
        XCTAssertEqual(snap.lightning?.amount_cents, 2100)
        XCTAssertEqual(invoice.invoice, t.quotes[0].invoice)
        XCTAssertEqual(invoice.walletURL.scheme, "lightning")
        XCTAssertEqual(t.count("POST", suffix: "/checkout"), 0, "no card order was made")
        XCTAssertEqual(snap.draft.paymentMethod, "lightning")
        XCTAssertEqual(snap.draft.lightningQuoteId, t.quotes[0].id)
    }

    func testLightningStaysDisabledUnlessTrustedConfigSaysAvailable() async throws {
        for lightning in [Bool?.some(false), nil] {
            let t = tower(lightning: lightning)
            let (c, review) = try await ready(t)
            XCTAssertEqual(review.paymentOptions.first { $0.method == .lightning }?.available, false)
            let snap = await c.continueToLightning()
            XCTAssertEqual(snap.failure?.kind, .paymentUnavailable)
            XCTAssertEqual(posts(t), 0, "not even an account or intent is created for a disabled method")
        }
        let t = tower(); t.deploymentConfig = config(lightning: true, enabled: false)
        let (c, _) = try await ready(t)
        let snap = await c.continueToLightning()
        XCTAssertEqual(snap.failure?.kind, .paymentUnavailable)
        XCTAssertEqual(t.count("POST", suffix: "/lightning/quote"), 0)
        let legacy = FakeOnboardingTower(); legacy.inviteCodes[OnboardingFixture.invite] = 21     // older NStack: no config route at all
        let (old, _) = try await ready(legacy)
        let none = await old.continueToLightning()
        XCTAssertEqual(none.failure?.kind, .paymentUnavailable)
        XCTAssertEqual(legacy.count("POST", suffix: "/lightning/quote"), 0)
    }

    func testDoubleTapAndLostAnswerReplaySameKeyAndMakeOneInvoice() async throws {
        let t = tower()
        let store = MemoryOnboardingDraftStore()
        let (c, _) = try await ready(t, store: store)
        async let a = c.continueToLightning(); async let b = c.continueToLightning()
        _ = await (a, b)
        XCTAssertEqual(t.count("POST", suffix: "/lightning/quote"), 1, "a double tap coalesces to one request")
        // Lost answer: the server made the quote but the client never saw it.
        let t2 = tower()
        let store2 = MemoryOnboardingDraftStore()
        let (c2, _) = try await ready(t2, store: store2)
        t2.dropResponses["/lightning/quote"] = 1
        let lost = await c2.continueToLightning()
        XCTAssertEqual(lost.failure?.kind, .network)
        XCTAssertNil(lost.lightningInvoice)
        let key = try XCTUnwrap(lost.draft.lightningKey)
        XCTAssertEqual(store2.load(origin: t2.origin, signerNpub: lost.draft.signerNpub)?.lightningKey, key, "the key was durable before the request")
        let retried = await c2.continueToLightning()
        XCTAssertNil(retried.failure)
        XCTAssertEqual(t2.quotes.count, 1, "replaying the same key never makes a second invoice")
        let keys = t2.requests.filter { $0.path.hasSuffix("/lightning/quote") }.compactMap { $0.body["idempotency_key"] as? String }
        XCTAssertEqual(keys, [key, key])
        XCTAssertNotNil(retried.lightningInvoice)
    }

    func testRelaunchResumesTheSameQuoteFromServerState() async throws {
        let t = tower()
        let store = MemoryOnboardingDraftStore()
        let identity = try await makeIdentity()
        let (c, _) = try await ready(t, store: store, signer: identity)
        _ = await c.continueToLightning()
        let first = t.quotes[0]
        let relaunched = try await OnboardingFixture.controller(t, signer: identity, store: store, returnURL: nil)
        let snap = await relaunched.load()
        XCTAssertEqual(snap.phase, .awaitingPayment)
        XCTAssertEqual(snap.lightning?.id, first.id)
        XCTAssertEqual(snap.lightningInvoice?.invoice, first.invoice)
        XCTAssertEqual(t.quotes.count, 1)
        XCTAssertEqual(t.count("POST", suffix: "/refresh"), 1, "the server's own provider poll is the source")
        XCTAssertEqual(t.count("POST", suffix: "/lightning/quote"), 1)
    }

    func testSwitchingPaymentMethodNeverStartsASecondPayableCheckout() async throws {
        // Lightning first: card is refused with nothing sent.
        let t = tower()
        let (c, _) = try await ready(t)
        _ = await c.continueToLightning()
        let card = await c.continueToPayment()
        XCTAssertEqual(card.failure?.kind, .paymentMethodLocked)
        XCTAssertEqual(t.count("POST", suffix: "/checkout"), 0)
        XCTAssertEqual(card.paymentOptions.first { $0.method == .card }?.available, false)
        // Card first (including an unanswered request): lightning is refused with nothing sent.
        let t2 = tower()
        let (c2, _) = try await ready(t2)
        t2.dropResponses["/checkout"] = 1
        let ambiguous = await c2.continueToPayment()
        XCTAssertEqual(ambiguous.failure?.kind, .network)
        let ln = await c2.continueToLightning()
        XCTAssertEqual(ln.failure?.kind, .paymentMethodLocked)
        XCTAssertEqual(t2.count("POST", suffix: "/lightning/quote"), 0)
        XCTAssertEqual(ln.paymentOptions.first { $0.method == .lightning }?.available, false)
        // The same card key is replayed and still makes one order.
        let again = await c2.continueToPayment()
        XCTAssertNotNil(again.checkoutURL)
        XCTAssertEqual(t2.checkoutOrders.count, 1)
    }

    func testDefiniteRefusalFreesTheMethodButAnUnknownOutcomeDoesNot() async throws {
        let t = tower()
        let (c, _) = try await ready(t)
        t.lightningServing = false                                  // NStack answers 503 lightning_unavailable before making any quote
        let refused = await c.continueToLightning()
        XCTAssertEqual(refused.failure?.kind, .paymentUnavailable)
        XCTAssertNil(refused.draft.paymentMethod)
        t.lightningServing = true
        let card = await c.continueToPayment()
        XCTAssertNotNil(card.checkoutURL, "the card path remains usable")
    }

    func testFundingComesOnlyFromTheServersIntentNotFromWalletReturnOrQuoteHints() async throws {
        let t = tower()
        let (c, _) = try await ready(t)
        _ = await c.continueToLightning()
        let returned = await c.paymentReturned(OnboardingFixture.returnURL)
        XCTAssertEqual(returned.phase, .awaitingPayment, "a return, even to the approved address, funds nothing")
        let ignored = await c.paymentReturned(URL(string: "lightning:lnbc1")!)
        XCTAssertEqual(ignored.phase, .awaitingPayment)
        // The quote says settled but the intent is not funded: still not funded.
        t.lock.withLock { t.quotes[0].state = "settled" }
        let inconsistent = await c.refresh()
        XCTAssertEqual(inconsistent.phase, .awaitingPayment)
        XCTAssertFalse(inconsistent.intent?.fundingConfirmed ?? true)
        let blocked = await c.provision()
        XCTAssertEqual(blocked.failure?.kind, .fundingRequired)
        XCTAssertEqual(t.count("POST", suffix: "/provision"), 0)
        // Verified settlement: the server funds the intent and says so.
        t.lock.withLock { t.quotes[0].state = "open" }
        t.resolveQuote(t.quotes[0].id, to: "settled")
        let funded = await c.refresh()
        XCTAssertEqual(funded.phase, .readyToProvision)
        XCTAssertTrue(funded.intent?.fundingConfirmed ?? false)
        XCTAssertEqual(t.count("POST", suffix: "/lightning/quote"), 1, "no second invoice is ever asked for")
    }

    func testExpiryReleasesTheKeyOnlyOnVerifiedExpiryAndOpenPastExpiryNeverMakesASecondInvoice() async throws {
        let t = tower(); t.quoteTTL = -30                           // already past its stated expiry on the device clock
        let (c, _) = try await ready(t)
        let shown = await c.continueToLightning()
        XCTAssertNotNil(shown.lightningInvoice, "still shown: NStack, not the clock, decides it is closed")
        let again = await c.continueToLightning()
        XCTAssertNil(again.failure)
        XCTAssertEqual(t.quotes.count, 1, "an unverified past-expiry quote is replayed, never duplicated")
        let before = try XCTUnwrap(again.draft.lightningKey)
        t.resolveQuote(t.quotes[0].id, to: "expired")
        let closed = await c.refresh()
        XCTAssertNil(closed.draft.lightningKey)
        XCTAssertNil(closed.draft.paymentMethod)
        XCTAssertNil(closed.lightningInvoice)
        XCTAssertNotNil(closed.notice)
        t.quoteTTL = 600
        let fresh = await c.continueToLightning()
        XCTAssertEqual(t.quotes.count, 2)
        XCTAssertNotEqual(fresh.draft.lightningKey, before, "a new invoice uses a new key")
        XCTAssertNotNil(fresh.lightningInvoice)
    }

    func testLateAndMismatchedPaymentsAreShownAsSupportAndKeepTheLock() async throws {
        for state in ["late_payment", "mismatch"] {
            let t = tower()
            let (c, _) = try await ready(t)
            _ = await c.continueToLightning()
            t.resolveQuote(t.quotes[0].id, to: state)
            let snap = await c.refresh()
            XCTAssertEqual(snap.lightning?.state.needsSupport, true, state)
            XCTAssertNil(snap.lightningInvoice, "never presented as payable again")
            XCTAssertNotNil(snap.draft.lightningQuoteId)
            XCTAssertEqual(snap.paymentOptions.first { $0.method == .card }?.available, false)
            XCTAssertNotEqual(snap.phase, .readyToProvision)
            let retry = await c.continueToLightning()
            XCTAssertEqual(t.quotes.count, 1)
            XCTAssertNil(retry.lightningInvoice)
        }
    }

    func testInconsistentQuotesAreNeverDisplayed() async throws {
        for tweak in [{ (t: FakeOnboardingTower) in t.invoiceAmountOffset = 1 }, { (t: FakeOnboardingTower) in t.quoteAmountOffset = 100 }] {
            let t = tower(); tweak(t)
            let (c, _) = try await ready(t)
            let snap = await c.continueToLightning()
            XCTAssertNil(snap.lightningInvoice)
            XCTAssertEqual(snap.failure?.code, "unexpected_quote")
            XCTAssertEqual(snap.draft.paymentMethod, "lightning", "the invoice may exist at NStack: the method stays bound")
        }
    }

    func testLightningNeverRequestsWhileTheKeyCannotBeSaved() async throws {
        let t = tower()
        let store = FlakyDraftStore { $0.lightningKey != nil }
        let (c, _) = try await ready(t, store: store)
        let snap = await c.continueToLightning()
        XCTAssertEqual(snap.failure?.kind, .persistence)
        XCTAssertEqual(t.count("POST", suffix: "/lightning/quote"), 0)
        XCTAssertNil(snap.lightningInvoice)
        // The quote binding itself must be durable before an invoice is shown.
        let t2 = tower()
        let store2 = FlakyDraftStore { $0.lightningQuoteId != nil }
        let (c2, _) = try await ready(t2, store: store2)
        let unbound = await c2.continueToLightning()
        XCTAssertEqual(unbound.failure?.kind, .persistence)
        XCTAssertNil(unbound.lightningInvoice)
        store2.heal()
        let healed = await c2.continueToLightning()
        XCTAssertNotNil(healed.lightningInvoice)
        XCTAssertEqual(t2.quotes.count, 1, "the same key found the same quote")
    }

    func testBackupGateAndExpectedSignerPrecedeAnyLightningRequest() async throws {
        let t = tower()
        let identity = try await makeIdentity()
        let npub = NostrKeys.npub(publicKeyHex: try await identity.publicKeyHex())!
        let gated = OnboardingController(origin: try TowerOrigin(t.origin), signerNpub: npub, signer: identity, transport: t, store: MemoryOnboardingDraftStore(),
                                         returnURL: nil, backupGate: { .hostedBackupRequired }, declaresNewIdentity: { true }, makeKey: OnboardingFixture.keys())
        _ = await gated.load()
        _ = await gated.edit(name: "Studio", fundingCents: 2100, invite: OnboardingInviteCode(OnboardingFixture.invite))
        _ = await gated.confirmReview()
        let blocked = await gated.continueToLightning()
        XCTAssertEqual(blocked.failure?.kind, .hostedBackupRequired)
        XCTAssertEqual(posts(t), 0)
        // A different unlocked identity cannot act on this draft.
        let other = try await OnboardingFixture.otherIdentity()
        let wrong = OnboardingController(origin: try TowerOrigin(t.origin), signerNpub: npub, signer: other, transport: t, store: MemoryOnboardingDraftStore(),
                                         returnURL: nil, makeKey: OnboardingFixture.keys())
        _ = await wrong.load()
        let mismatch = await wrong.continueToLightning()
        XCTAssertEqual(mismatch.phase, .unavailable(.signerMismatch))
        XCTAssertEqual(posts(t), 0)
        // New identities declare their origin on the intent that carries the quote.
        let ok = OnboardingController(origin: try TowerOrigin(t.origin), signerNpub: npub, signer: identity, transport: t, store: MemoryOnboardingDraftStore(),
                                      returnURL: nil, backupGate: { .allowed }, declaresNewIdentity: { true }, makeKey: OnboardingFixture.keys())
        _ = await ok.load()
        _ = await ok.edit(name: "Studio", fundingCents: 2100, invite: OnboardingInviteCode(OnboardingFixture.invite))
        _ = await ok.confirmReview()
        _ = await ok.continueToLightning()
        XCTAssertEqual(t.requests.first { $0.path.hasSuffix("/intents") && $0.method == "POST" }?.body["identity_origin"] as? String, "new")
    }

    func testIdentityChangeAfterCreateNeverSignsTheQuote() async throws {
        let t = tower()
        let alice = try await makeIdentity(), bob = try await OnboardingFixture.otherIdentity()
        let bobNpub = NostrKeys.npub(publicKeyHex: try await bob.publicKeyHex())!
        let swappable = SwappableSigner(alice)
        let aliceNpub = NostrKeys.npub(publicKeyHex: try await alice.publicKeyHex())!
        let c = OnboardingController(origin: try TowerOrigin(t.origin), signerNpub: aliceNpub, signer: swappable, transport: t, store: MemoryOnboardingDraftStore(),
                                    returnURL: nil, makeKey: OnboardingFixture.keys())
        _ = await c.load()
        _ = await c.edit(name: "Studio", fundingCents: 2100, invite: OnboardingInviteCode(OnboardingFixture.invite))
        _ = await c.confirmReview()
        t.hook = { seen in if seen.method == "POST", seen.path.hasSuffix("/intents") { swappable.swap(to: bob) } }
        let snap = await c.continueToLightning()
        XCTAssertEqual(snap.phase, .unavailable(.signerMismatch))
        XCTAssertEqual(t.count("POST", suffix: "/lightning/quote"), 0)
        XCTAssertFalse(t.requests.contains { $0.signer == bobNpub })
    }

    func testCreditSurvivesProvisioningInterruptionWithoutAnotherInvoice() async throws {
        let t = tower(); t.provisionFailures = 1
        let (c, _) = try await ready(t)
        _ = await c.continueToLightning()
        t.resolveQuote(t.quotes[0].id, to: "settled")
        _ = await c.refresh()
        let failed = await c.provision()
        XCTAssertEqual(failed.failure?.kind, .provisioningFailed)
        XCTAssertTrue(failed.intent?.fundingConfirmed ?? false, "the credit is kept")
        let resumed = await c.provision()
        XCTAssertEqual(resumed.phase, .provisioned)
        XCTAssertEqual(t.quotes.count, 1)
        XCTAssertEqual(t.count("POST", suffix: "/checkout"), 0)
        XCTAssertFalse(resumed.landing?.agentRunning ?? true)
    }

    func testFundingCannotBeEditedOnceAnInvoiceExists() async throws {
        let t = tower()
        let (c, _) = try await ready(t)
        _ = await c.continueToLightning()
        _ = await c.edit(fundingCents: 5000)
        let review = await c.confirmReview()
        XCTAssertNil(review.failure)
        let snap = await c.continueToLightning()
        XCTAssertEqual(snap.failure?.kind, .notEditable, "the invoice is for the original amount")
        XCTAssertEqual(t.quotes.count, 1)
        XCTAssertEqual(t.count("POST", suffix: "/options"), 0)
    }

    func testCancelWithLightningRotatesEveryKey() async throws {
        let t = tower()
        let (c, _) = try await ready(t)
        let paying = await c.continueToLightning()
        let oldKey = try XCTUnwrap(paying.draft.lightningKey)
        t.lock.withLock { t.intents[0].status = "open" }
        let cancelled = await c.cancelSetup()
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertNil(cancelled.draft.lightningKey)
        XCTAssertNil(cancelled.draft.paymentMethod)
        XCTAssertNil(cancelled.lightning)
        XCTAssertNotEqual(cancelled.draft.createKey, oldKey)
    }

    // MARK: Top-ups

    private struct Topup { let tower: FakeOnboardingTower; let controller: TopupController; let store: TopupDraftStore; let owner: String; let identity: IdentityService }
    private func topup(provisioned: Bool = true, lightning: Bool? = true, card: Bool = true, mode: String = "test", limits: (Int, Int)? = nil,
                        store: TopupDraftStore = MemoryTopupDraftStore(), identity: IdentityService? = nil, tower existing: FakeOnboardingTower? = nil,
                        gate: PaymentBackupGate = .allowed) async throws -> Topup {
        let t = existing ?? FakeOnboardingTower()
        if existing == nil { t.deploymentConfig = config(lightning: lightning, card: card, mode: mode, topup: limits) }
        let id = try await { () async throws -> IdentityService in if let identity { return identity }; return try await makeIdentity() }()
        let owner = NostrKeys.npub(publicKeyHex: try await id.publicKeyHex())!
        if provisioned { t.accounts.insert(owner); t.provision(owner) }
        let c = TopupController(origin: try TowerOrigin(t.origin), signerNpub: owner, signer: id, transport: t, store: store, backupGate: { gate }, makeKey: OnboardingFixture.keys())
        return Topup(tower: t, controller: c, store: store, owner: owner, identity: id)
    }
    private func onlyTopupRequests(_ t: FakeOnboardingTower) -> [FakeOnboardingTower.Seen] {
        t.requests.filter { $0.path.hasPrefix("/api/v4/onboarding") }
    }

    func testTopupReadsAreSignedAndShowServerAccountDebtAndLifecycle() async throws {
        let t = FakeOnboardingTower()
        t.accountFunding = ["reversal_debt_units": "7000", "open_cents": 500, "adjustments": [["kind": "refund", "state": "pending", "provider_ref": "x", "amount_cents": 500, "effective_cents": 500, "uncovered_units": "7000", "updated_at": "2026-11-24T00:00:00.000Z"]]]
        t.accountLifecycle = ["version": 1, "state": "read_only", "read_only": ["entered_at": "2026-11-20T00:00:00.000Z", "ends_at": "2026-12-20T00:00:00.000Z", "days_remaining": 26]]
        let s = try await topup(tower: t)
        let snap = await s.controller.load()
        XCTAssertEqual(snap.phase, .ready)
        XCTAssertEqual(snap.overview?.funding?.hasDebt, true)
        XCTAssertEqual(snap.overview?.funding?.open_cents, 500)
        XCTAssertEqual(snap.overview?.lifecycle?.state, "read_only")
        XCTAssertEqual(snap.overview?.lifecycle?.read_only?.days_remaining, 26)
        XCTAssertEqual(snap.overview?.account?.currency, "USD")
        XCTAssertEqual(snap.limits, .documented)
        XCTAssertEqual(snap.limits.presetsCents, [2100, 5000, 10000])
        let reads = onlyTopupRequests(t)
        XCTAssertEqual(reads.map(\.path), ["/api/v4/onboarding/config", "/api/v4/onboarding/account", "/api/v4/onboarding/topups"])
        XCTAssertTrue(reads.allSatisfy { $0.method == "GET" && $0.signer == s.owner })
    }

    func testCardTopupUsesExactContractBodyApprovedReturnAndCreatesNoIntent() async throws {
        let s = try await topup()
        _ = await s.controller.load()
        let snap = await s.controller.startCard(amountCents: 5000)
        XCTAssertNil(snap.failure)
        XCTAssertNotNil(snap.checkoutURL)
        let request = try XCTUnwrap(s.tower.requests.first { $0.path == "/api/v4/onboarding/topups/checkout" })
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(Set(request.body.keys), ["idempotency_key", "return_url", "amount_cents"])
        XCTAssertEqual(request.body["amount_cents"] as? Int, 5000)
        XCTAssertEqual(request.body["return_url"] as? String, returnAddress, "the server's own approved address; nothing is invented")
        XCTAssertEqual(request.signer, s.owner)
        XCTAssertEqual(snap.attempt?.orderId, s.tower.topupOrders.values.first?.id)
        XCTAssertTrue(s.tower.requests.allSatisfy { !$0.path.contains("/intents") && !$0.path.hasSuffix("/provision") && !$0.path.hasSuffix("/account") || $0.method == "GET" },
                      "a top-up makes no intent, workspace, seat or account mutation")
        XCTAssertNil(snap.list?.credited.first, "nothing is credited by opening a page")
        XCTAssertEqual((try s.store.load(origin: s.tower.origin, signerNpub: s.owner))?.attempt?.amountCents, 5000)
    }

    func testUnreadableSavedAttemptBlocksEverythingInsteadOfBecomingNoAttempt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("topup-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTopupDraftStore(directory: dir)
        let first = try await topup(store: store)
        _ = await first.controller.load()
        _ = await first.controller.startLightning(amountCents: 2100)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        try Data("{not json".utf8).write(to: file)
        let tower = first.tower
        let before = tower.requests.count
        let second = try await topup(store: store, identity: first.identity, tower: tower)
        let loaded = await second.controller.load()
        XCTAssertEqual(loaded.phase, .unavailable(.draftUnreadable))
        let started = await second.controller.startLightning(amountCents: 2100)
        XCTAssertEqual(started.phase, .unavailable(.draftUnreadable))
        let card = await second.controller.startCard(amountCents: 2100)
        XCTAssertEqual(card.phase, .unavailable(.draftUnreadable))
        XCTAssertEqual(tower.requests.count, before, "no request is signed or sent while the saved attempt is unreadable")
        XCTAssertEqual(tower.quotes.count, 1, "no second payable invoice")
    }

    /// A held server answer must not let another operation class run, or apply its own answer, in the middle of it.
    func testDelayedResponseSerializesOperationsAcrossClasses() async throws {
        let s = try await topup()
        _ = await s.controller.load()
        let started = await s.controller.startLightning(amountCents: 2100)
        let key = try XCTUnwrap(started.attempt?.key)
        let quoteId = try XCTUnwrap(started.attempt?.quoteId)
        s.tower.lock.withLock { for i in s.tower.quotes.indices where s.tower.quotes[i].id == quoteId { s.tower.quotes[i].state = "expired" } }
        let held = HeldResponse()
        defer { held.release() }
        s.tower.responseGate = { seen in if seen.path.hasSuffix("/refresh") { await held.hold() } }
        let refresh = Task { await s.controller.refresh() }
        try await held.waitUntilHeld()
        let mark = s.tower.requests.count
        // The terminal answer is held in transit; other operation classes must wait before reading or changing the attempt.
        let load = Task { await s.controller.load() }
        let again = Task { await s.controller.startLightning(amountCents: 5000) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(s.tower.requests.count, mark, "later operations wait: nothing new reaches the server while the older answer is pending")
        held.release()
        _ = await refresh.value; _ = await load.value; let last = await again.value
        let after = await s.controller.snapshot()
        XCTAssertNil(after.attempt?.key == key ? after.attempt : nil, "the expired invoice's attempt was closed once, by the refresh that saw it")
        XCTAssertNil(last.failure?.kind == .paymentMethodLocked ? last.failure : nil, "the new start ran after the close, not against a stale open attempt")
        XCTAssertEqual(after.attempt?.amountCents, 5000)
        XCTAssertEqual(s.tower.quotes.filter { $0.state == "open" }.count, 1, "exactly one payable invoice")
        XCTAssertEqual((try s.store.load(origin: s.tower.origin, signerNpub: s.owner))?.attempt?.amountCents, 5000)
    }

    func testAbsentDraftIsNotAnError() async throws {
        let store = FileTopupDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("topup-none-\(UUID().uuidString)"))
        XCTAssertNil(try store.load(origin: "https://a.example", signerNpub: "npub1x"))
    }

    func testCardTopupIsOfferedOnlyForTestModeConfigWithApprovedReturn() async throws {
        for (card, mode) in [(false, "test"), (true, "live")] {
            let s = try await topup(card: card, mode: mode)
            let loaded = await s.controller.load()
            XCTAssertFalse(loaded.cardAvailable)
            let snap = await s.controller.startCard(amountCents: 2100)
            XCTAssertEqual(snap.failure?.kind, .paymentUnavailable)
            XCTAssertEqual(s.tower.count("POST", suffix: "/topups/checkout"), 0)
        }
        let t = FakeOnboardingTower()                                              // older NStack: no config route, no top-ups route
        t.deploymentConfig = nil
        let s = try await topup(tower: t)
        let snap = await s.controller.load()
        XCTAssertFalse(snap.cardAvailable)
        XCTAssertFalse(snap.lightningAvailable)
    }

    func testLightningTopupQuoteSettlementAndCredit() async throws {
        let s = try await topup()
        _ = await s.controller.load()
        let started = await s.controller.startLightning(amountCents: 2100)
        XCTAssertNil(started.failure)
        let request = try XCTUnwrap(s.tower.requests.first { $0.path == "/api/v4/onboarding/topups/lightning/quote" })
        XCTAssertEqual(Set(request.body.keys), ["idempotency_key", "amount_cents"])
        XCTAssertEqual(request.body["amount_cents"] as? Int, 2100)
        XCTAssertEqual(started.invoice?.sats, 2100 * 25)
        XCTAssertEqual(started.quote?.intent_id, nil)
        XCTAssertEqual(started.list?.pending_lightning.count, 0, "the list is read before the quote existed")
        let pending = await s.controller.refresh()
        XCTAssertEqual(pending.list?.pending_lightning.count, 1)
        XCTAssertEqual(pending.list?.credited.count, 0, "paying a wallet or returning to the app credits nothing")
        XCTAssertNotNil(pending.attempt)
        let id = try XCTUnwrap(s.tower.quotes.first?.id)
        s.tower.resolveQuote(id, to: "settled")
        let done = await s.controller.refresh()
        XCTAssertNil(done.attempt, "closed on NStack's verified word")
        XCTAssertEqual(done.list?.credited.map(\.amount_cents), [2100])
        XCTAssertEqual(done.list?.credited.first?.method, "lightning")
        XCTAssertTrue(s.tower.requests.contains { $0.path == "/api/v4/onboarding/topups/lightning/quotes/\(id)/refresh" && $0.method == "POST" && $0.signer == s.owner })
        XCTAssertFalse(s.tower.requests.contains { $0.path.contains("/intents") })
    }

    func testLightningTopupDisabledByConfigSendsNothing() async throws {
        for lightning in [Bool?.some(false), nil] {
            let s = try await topup(lightning: lightning)
            _ = await s.controller.load()
            let snap = await s.controller.startLightning(amountCents: 2100)
            XCTAssertEqual(snap.failure?.kind, .paymentUnavailable)
            XCTAssertEqual(s.tower.count("POST", suffix: "/lightning/quote"), 0)
            XCTAssertNil(snap.attempt)
        }
    }

    func testTopupAmountsFollowTheServersLimitsExactly() async throws {
        let s = try await topup(limits: (3000, 5000))
        let loaded = await s.controller.load()
        XCTAssertEqual(loaded.limits, TopupLimits(minCents: 3000, maxCents: 5000))
        XCTAssertEqual(loaded.limits.presetsCents, [5000])
        XCTAssertEqual(loaded.limits.cents(fromDollars: "30"), 3000)
        XCTAssertNil(loaded.limits.cents(fromDollars: "29.99"))
        XCTAssertNil(loaded.limits.cents(fromDollars: "50.01"))
        for bad in [2999, 5001, 0, -1] {
            let snap = await s.controller.startCard(amountCents: bad)
            XCTAssertEqual(snap.failure?.kind, .validation)
        }
        XCTAssertEqual(s.tower.count("POST", suffix: "/topups/checkout"), 0)
        let documented = try await topup()
        let plain = await documented.controller.load()
        XCTAssertNil(plain.limits.cents(fromDollars: "20.99"), "the server minimum is US$21")
        XCTAssertEqual(plain.limits.cents(fromDollars: "21"), 2100)
        XCTAssertEqual(plain.limits.cents(fromDollars: "21.5"), 2150)
        XCTAssertNil(plain.limits.cents(fromDollars: "1,000"))
        let below = await documented.controller.startLightning(amountCents: 2099)
        XCTAssertEqual(below.failure?.kind, .validation)
        XCTAssertEqual(documented.tower.count("POST", suffix: "/lightning/quote"), 0)
    }

    func testUnprovisionedOrMissingAccountOffersNoTopup() async throws {
        let s = try await topup(provisioned: false)
        let snap = await s.controller.load()
        XCTAssertEqual(snap.phase, .unavailable(.notProvisioned))
        XCTAssertEqual(snap.failure?.kind, .accountNotProvisioned)
        let start = await s.controller.startCard(amountCents: 2100)
        XCTAssertNotNil(start.failure)
        XCTAssertEqual(s.tower.count("POST", suffix: "/topups/checkout"), 0)
        let t = FakeOnboardingTower(); t.deploymentConfig = config(); t.accounts.insert("x")
        let off = try await topup(tower: t)
        t.rolloutEnabled = false
        let disabled = await off.controller.load()
        XCTAssertEqual(disabled.phase, .ready)
        let refused = await off.controller.startCard(amountCents: 2100)
        XCTAssertEqual(refused.phase, .unavailable(.rolloutDisabled))
    }

    func testDoubleTapAmbiguousCheckoutAndRelaunchReplaySameOrder() async throws {
        let s = try await topup()
        _ = await s.controller.load()
        async let a = s.controller.startCard(amountCents: 2100); async let b = s.controller.startCard(amountCents: 2100)
        _ = await (a, b)
        XCTAssertEqual(s.tower.count("POST", suffix: "/topups/checkout"), 1)
        // Second start while one is open is refused with nothing sent, for either method or amount.
        let other = await s.controller.startLightning(amountCents: 5000)
        XCTAssertEqual(other.failure?.kind, .paymentMethodLocked)
        let again = await s.controller.startCard(amountCents: 5000)
        XCTAssertEqual(again.failure?.kind, .paymentMethodLocked)
        XCTAssertEqual(s.tower.count("POST", suffix: "/topups/checkout"), 1)
        XCTAssertEqual(s.tower.count("POST", suffix: "/lightning/quote"), 0)

        // Lost answer, then relaunch: the same key and amount are replayed and the order is the same.
        let lost = try await topup()
        _ = await lost.controller.load()
        lost.tower.dropResponses["/topups/checkout"] = 1
        let ambiguous = await lost.controller.startCard(amountCents: 2100)
        XCTAssertEqual(ambiguous.failure?.kind, .network)
        XCTAssertNotNil(ambiguous.attempt, "kept for replay")
        XCTAssertNil(ambiguous.attempt?.orderId)
        let relaunched = TopupController(origin: try TowerOrigin(lost.tower.origin), signerNpub: lost.owner, signer: lost.identity, transport: lost.tower, store: lost.store, makeKey: OnboardingFixture.keys())
        let resumed = await relaunched.load()
        XCTAssertNotNil(resumed.checkoutURL)
        XCTAssertEqual(lost.tower.topupOrders.count, 1)
        let keys = lost.tower.requests.filter { $0.path.hasSuffix("/topups/checkout") }.compactMap { $0.body["idempotency_key"] as? String }
        XCTAssertEqual(keys.count, 2); XCTAssertEqual(Set(keys).count, 1)
        XCTAssertEqual(resumed.attempt?.orderId, lost.tower.topupOrders.values.first?.id)
    }

    func testLostInvoiceAnswerThenRelaunchReplaysTheSameKey() async throws {
        let s = try await topup()
        _ = await s.controller.load()
        s.tower.dropResponses["/topups/lightning/quote"] = 1
        let lost = await s.controller.startLightning(amountCents: 2100)
        XCTAssertEqual(lost.failure?.kind, .network)
        XCTAssertNotNil(lost.attempt)
        let relaunched = TopupController(origin: try TowerOrigin(s.tower.origin), signerNpub: s.owner, signer: s.identity, transport: s.tower, store: s.store, makeKey: OnboardingFixture.keys())
        let resumed = await relaunched.load()
        XCTAssertNotNil(resumed.invoice)
        XCTAssertEqual(s.tower.quotes.count, 1)
        let keys = s.tower.requests.filter { $0.path.hasSuffix("/topups/lightning/quote") }.compactMap { $0.body["idempotency_key"] as? String }
        XCTAssertEqual(Set(keys).count, 1)
    }

    func testTopupNeverRequestsWhileTheAttemptCannotBeSaved() async throws {
        let s = try await topup(store: FailingTopupStore())
        _ = await s.controller.load()
        let card = await s.controller.startCard(amountCents: 2100)
        XCTAssertEqual(card.failure?.kind, .persistence)
        let ln = await s.controller.startLightning(amountCents: 2100)
        XCTAssertEqual(ln.failure?.kind, .persistence)
        XCTAssertEqual(s.tower.count("POST", suffix: "/topups/checkout"), 0)
        XCTAssertEqual(s.tower.count("POST", suffix: "/lightning/quote"), 0)
        XCTAssertNil(ln.checkoutURL)
    }

    func testTopupCheckoutResponseIsValidatedAndNeverOpensAnythingElse() async throws {
        for tweak in [{ (t: FakeOnboardingTower) in t.checkoutMode = "live" }, { (t: FakeOnboardingTower) in t.checkoutAmountOffset = 100 },
                      { (t: FakeOnboardingTower) in t.checkoutURL = "https://evilstripe.com/pay" }, { (t: FakeOnboardingTower) in t.checkoutURL = "http://checkout.stripe.com/x" }] {
            let s = try await topup()
            tweak(s.tower)
            _ = await s.controller.load()
            let snap = await s.controller.startCard(amountCents: 2100)
            XCTAssertNil(snap.checkoutURL)
            XCTAssertEqual(snap.failure?.code, "unexpected_checkout")
            XCTAssertNotNil(snap.attempt, "the order may exist: the key stays for replay")
        }
    }

    func testCardOrderClosureIsNotClaimedAsCredit() async throws {
        let s = try await topup()
        _ = await s.controller.load()
        _ = await s.controller.startCard(amountCents: 2100)
        let foreign = await s.controller.paymentReturned(URL(string: "https://evil.example/return")!)
        XCTAssertNotNil(foreign.notice)
        XCTAssertNotNil(foreign.attempt)
        let key = try XCTUnwrap(s.tower.topupOrders.keys.first)
        let still = await s.controller.paymentReturned(OnboardingFixture.returnURL)
        XCTAssertNotNil(still.attempt, "a return funds and closes nothing while NStack still lists the order")
        XCTAssertEqual(still.list?.credited.count, 0)
        s.tower.expireTopupOrder(key)
        let closed = await s.controller.refresh()
        XCTAssertNil(closed.attempt)
        XCTAssertEqual(closed.list?.credited.count, 0, "expiry credits nothing")
        XCTAssertFalse(closed.notice?.lowercased().contains("credited by") ?? false)
        // A paid order shows up as a settlement and the next top-up may begin.
        let next = await s.controller.startCard(amountCents: 2100)
        XCTAssertNotNil(next.checkoutURL)
        s.tower.settleTopupOrder(try XCTUnwrap(s.tower.topupOrders.first { $0.value.open }?.key))
        let paid = await s.controller.refresh()
        XCTAssertEqual(paid.list?.credited.map(\.method), ["stripe"])
        XCTAssertNil(paid.attempt)
    }

    func testLateAndMismatchedTopupPaymentsAreSupportCases() async throws {
        let s = try await topup()
        _ = await s.controller.load()
        _ = await s.controller.startLightning(amountCents: 2100)
        let id = try XCTUnwrap(s.tower.quotes.first?.id)
        s.tower.resolveQuote(id, to: "late_payment")
        let snap = await s.controller.refresh()
        XCTAssertEqual(snap.needsSupport.map(\.state), ["late_payment"])
        XCTAssertNil(snap.invoice, "never shown as payable")
        XCTAssertEqual(snap.list?.credited.count, 0)
        XCTAssertNotNil(snap.notice)
        XCTAssertNil(snap.attempt, "a new top-up is possible, the old record stays visible for support")
    }

    func testTopupStateIsPerIdentityAndOriginAndBoundToTheSigner() async throws {
        let s = try await topup()
        _ = await s.controller.load()
        _ = await s.controller.startCard(amountCents: 2100)
        // Same device store, different identity: neither sees nor replays the other's attempt.
        let bob = try await OnboardingFixture.otherIdentity()
        let bobNpub = NostrKeys.npub(publicKeyHex: try await bob.publicKeyHex())!
        s.tower.accounts.insert(bobNpub); s.tower.provision(bobNpub)
        let other = TopupController(origin: try TowerOrigin(s.tower.origin), signerNpub: bobNpub, signer: bob, transport: s.tower, store: s.store, makeKey: OnboardingFixture.keys())
        let snap = await other.load()
        XCTAssertNil(snap.attempt)
        XCTAssertEqual(s.tower.topupOrders.count, 1)
        // Swapping the unlocked identity under a running controller signs nothing further.
        let alice = try await makeIdentity()
        let swappable = SwappableSigner(alice)
        let aliceNpub = NostrKeys.npub(publicKeyHex: try await alice.publicKeyHex())!
        s.tower.accounts.insert(aliceNpub); s.tower.provision(aliceNpub)
        let c = TopupController(origin: try TowerOrigin(s.tower.origin), signerNpub: aliceNpub, signer: swappable, transport: s.tower, store: MemoryTopupDraftStore(), makeKey: OnboardingFixture.keys())
        _ = await c.load()
        swappable.swap(to: bob)
        let before = s.tower.requests.count
        let mismatched = await c.startCard(amountCents: 2100)
        XCTAssertEqual(mismatched.phase, .unavailable(.signerMismatch))
        XCTAssertEqual(s.tower.requests.count, before, "nothing was signed or sent")
        XCTAssertFalse(s.tower.requests.contains { $0.signer == bobNpub && $0.path.hasSuffix("/checkout") })
    }

    func testOriginMustMatchItsDescriptorBeforeAnyTopupRequest() async throws {
        let t = FakeOnboardingTower(); t.deploymentConfig = config(); t.descriptorOrigin = "https://impostor.example"
        let s = try await topup(tower: t)
        let snap = await s.controller.load()
        if case .unavailable(.originRejected) = snap.phase {} else { XCTFail("expected origin rejection, got \(snap.phase)") }
        XCTAssertTrue(t.requests.allSatisfy { !$0.path.hasPrefix("/api/v4/onboarding") }, "nothing signed was sent")
    }

    func testTopupBackupGateStopsRequests() async throws {
        let s = try await topup(gate: .hostedBackupRequired)
        _ = await s.controller.load()
        let snap = await s.controller.startLightning(amountCents: 2100)
        XCTAssertEqual(snap.failure?.kind, .hostedBackupRequired)
        XCTAssertEqual(s.tower.count("POST", suffix: "/lightning/quote"), 0)
    }

    func testTooManyOpenQuotesIsReportedAndLeavesNoAttempt() async throws {
        let s = try await topup()
        _ = await s.controller.load()
        for i in 0..<5 { s.tower.lock.withLock { s.tower.quotes.append(.init(owner: s.owner, intentId: nil, key: "seed_key_\(i)", cents: 2100, sats: 52500, invoice: "x", hash: String(repeating: "0", count: 63) + "\(i)", expires: "2026-12-01T00:00:00.000Z")) } }
        let snap = await s.controller.startLightning(amountCents: 2100)
        XCTAssertEqual(snap.failure?.kind, .tooManyOpenQuotes)
        XCTAssertNil(snap.attempt, "a 429 is a definite refusal: no invoice was made, so nothing stays bound")
    }
}

private final class FailingTopupStore: TopupDraftStore, @unchecked Sendable {
    struct Disk: Error {}
    func load(origin: String, signerNpub: String) throws -> TopupDraft? { nil }
    func save(_ draft: TopupDraft) throws { throw Disk() }
}

private final class HeldResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var heldFlag = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        await withCheckedContinuation { c in lock.withLock { heldFlag = true; if released { c.resume() } else { continuations.append(c) } } }
    }
    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !lock.withLock({ heldFlag }) {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "HeldResponseTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func release() { lock.withLock { released = true; continuations.forEach { $0.resume() }; continuations = [] } }
}
