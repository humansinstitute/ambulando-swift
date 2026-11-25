import XCTest
@testable import AmbulandoCore

/// One canonical outstanding payment attempt per onboarding intent (tower docs/contract/onboarding-v1.md): an identity restored on another device
/// resumes the existing card order or Lightning quote, never a second one; ambiguity and support states close both methods; only an explicit,
/// provider-verified release frees a payment. The fake tower applies the server's reuse, refusal and release rules.
final class PaymentAttemptTests: XCTestCase {
    private func tower() -> FakeOnboardingTower {
        let t = FakeOnboardingTower()
        t.inviteCodes[OnboardingFixture.invite] = 21
        t.deploymentConfig = ["version": 1, "onboarding_enabled": true,
                              "card": ["available": true, "mode": "test", "return_urls": [OnboardingFixture.returnURL.absoluteString]] as [String: Any],
                              "funding": ["min_cents": 2100, "max_cents": 1_000_000, "topup_min_cents": 2100, "topup_max_cents": 1_000_000],
                              "lightning": ["available": true]]
        return t
    }
    /// A device: its own draft store and operation keys, the same identity.
    private struct Device { let controller: OnboardingController; let store: OnboardingDraftStore }
    private func device(_ t: FakeOnboardingTower, name: String = "A", store: OnboardingDraftStore = MemoryOnboardingDraftStore()) async throws -> Device {
        let counter = OnboardingFixture.Counter()
        let c = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: store, returnURL: nil, keys: { "ob_\(name)_key_\(counter.next())" })
        return Device(controller: c, store: store)
    }
    private func ready(_ t: FakeOnboardingTower, name: String = "A", store: OnboardingDraftStore = MemoryOnboardingDraftStore()) async throws -> Device {
        let d = try await device(t, name: name, store: store)
        _ = await d.controller.load()
        _ = await d.controller.edit(name: "Studio", fundingCents: 2100, agentOfferId: .some(nil), invite: OnboardingInviteCode(OnboardingFixture.invite))
        _ = await d.controller.confirmReview()
        return d
    }
    private func restored(_ t: FakeOnboardingTower, name: String = "B") async throws -> (Device, OnboardingSnapshot) {
        let d = try await device(t, name: name)
        return (d, await d.controller.load())
    }
    /// Waits until `count` operations are parked behind the one in flight; no timing guess about arrival order.
    private func waitForQueue(_ c: OnboardingController, _ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await c.queuedOperations < count {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "QueueTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func posts(_ t: FakeOnboardingTower, _ suffix: String) -> Int { t.count("POST", suffix: suffix) }

    // MARK: Resume on a restored device

    func testRestoredDeviceResumesTheExistingCardOrderWithItsOwnKey() async throws {
        let t = tower()
        let a = try await ready(t)
        let paid = await a.controller.continueToPayment()
        let order = try XCTUnwrap(paid.draft.checkoutOrderId)
        let (b, loaded) = try await restored(t)
        XCTAssertEqual(loaded.phase, .awaitingPayment)
        XCTAssertEqual(loaded.draft.paymentMethod, "card")
        XCTAssertEqual(loaded.draft.checkoutOrderId, order)
        XCTAssertNil(loaded.paymentBlock)
        XCTAssertNotEqual(loaded.draft.checkoutKey, paid.draft.checkoutKey, "the second device never saw the first device's key")
        let resumed = await b.controller.continueToPayment()
        XCTAssertNil(resumed.failure)
        XCTAssertNotNil(resumed.checkoutURL)
        XCTAssertEqual(resumed.draft.checkoutOrderId, order)
        XCTAssertEqual(t.orderRows.count, 1, "no second payable order")
        let locked = await b.controller.continueToLightning()
        XCTAssertEqual(locked.failure?.kind, .paymentMethodLocked)
        XCTAssertEqual(posts(t, "/lightning/quote"), 0)
    }

    func testRestoredDeviceResumesTheExistingLightningQuoteWithoutAnotherInvoice() async throws {
        let t = tower()
        let a = try await ready(t)
        let first = await a.controller.continueToLightning()
        let invoice = try XCTUnwrap(first.lightningInvoice)
        let (b, loaded) = try await restored(t)
        XCTAssertEqual(loaded.phase, .awaitingPayment)
        XCTAssertEqual(loaded.draft.paymentMethod, "lightning")
        XCTAssertEqual(loaded.lightningInvoice?.invoice, invoice.invoice)
        XCTAssertEqual(loaded.lightning?.id, first.lightning?.id)
        XCTAssertNotNil(loaded.draft.lightningKey)
        XCTAssertNotEqual(loaded.draft.lightningKey, first.draft.lightningKey)
        let again = await b.controller.continueToLightning()
        XCTAssertNil(again.failure)
        XCTAssertEqual(again.lightning?.id, first.lightning?.id)
        XCTAssertEqual(t.quotes.count, 1, "no second invoice")
        let card = await b.controller.continueToPayment()
        XCTAssertEqual(card.failure?.kind, .paymentMethodLocked)
        XCTAssertEqual(posts(t, "/checkout"), 0)
    }

    func testRestoredDeviceRekeysWhenItsOwnQuoteWasReplacedByAnotherDevice() async throws {
        let t = tower()
        let a = try await ready(t)
        let first = await a.controller.continueToLightning()
        let oldQuote = try XCTUnwrap(first.lightning?.id)
        t.resolveQuote(oldQuote, to: "expired")
        let b = try await ready(t, name: "B")      // the same identity, a second device; it asks for a replacement invoice
        _ = await b.controller.load()
        let replacement = await b.controller.continueToLightning()
        let newQuote = try XCTUnwrap(replacement.lightning?.id)
        XCTAssertNotEqual(newQuote, oldQuote)
        let stale = await a.controller.load()          // the first device still holds the closed quote's key
        XCTAssertEqual(stale.lightning?.id, newQuote)
        XCTAssertEqual(stale.draft.lightningQuoteId, newQuote)
        XCTAssertNotEqual(stale.draft.lightningKey, first.draft.lightningKey, "a replayed key would return the closed quote")
        XCTAssertEqual(t.quotes.filter { ["open", "issuing"].contains($0.state) }.count, 1)
    }

    // MARK: Races and conflicts

    func testStaleViewConflictAdoptsTheEarlierPaymentAndNeverClearsIt() async throws {
        let t = tower()
        let a = try await ready(t)
        t.checkoutRefusal = "invalid_checkout"                    // device A creates the intent, its checkout is refused before any order
        _ = await a.controller.continueToPayment()
        t.checkoutRefusal = nil
        let (b, loaded) = try await restored(t)                  // device B reads the intent while no payment exists
        XCTAssertNil(loaded.draft.paymentMethod)
        _ = await b.controller.confirmReview()
        let card = await a.controller.continueToPayment()
        XCTAssertNotNil(card.checkoutURL)
        let lost = await b.controller.continueToLightning()      // B's view is stale: NStack refuses before any invoice
        XCTAssertEqual(lost.failure?.kind, .paymentMethodLocked)
        XCTAssertEqual(lost.draft.paymentMethod, "card")
        XCTAssertEqual(lost.draft.checkoutOrderId, card.draft.checkoutOrderId)
        XCTAssertEqual(lost.phase, .awaitingPayment)
        XCTAssertTrue(t.quotes.isEmpty)
        XCTAssertEqual(t.orderRows.filter { $0.state == "open" }.count, 1)
        XCTAssertEqual(posts(t, "/payment-attempt/release"), 0, "a conflict never cancels the other device's payment")
    }

    func testConcurrentMethodsOnOneDeviceIssueOnlyOnePayment() async throws {
        let t = tower()
        let a = try await ready(t)
        async let card = a.controller.continueToPayment()
        async let lightning = a.controller.continueToLightning()
        let (c, l) = await (card, lightning)
        XCTAssertEqual(t.orderRows.count + t.quotes.count, 1)
        XCTAssertNotEqual(c.failure == nil, l.failure == nil, "exactly one method succeeds")
        XCTAssertEqual((c.failure ?? l.failure)?.kind, .paymentMethodLocked)
        let final = await a.controller.snapshot()
        XCTAssertNotNil(final.draft.paymentMethod)
    }

    func testFundingCannotChangeWhileAPaymentIsOutstanding() async throws {
        let t = tower()
        let a = try await ready(t)
        _ = await a.controller.continueToPayment()
        let (b, _) = try await restored(t)
        _ = await b.controller.edit(fundingCents: 5000)
        _ = await b.controller.confirmReview()
        let blocked = await b.controller.continueToPayment()
        XCTAssertEqual(blocked.failure?.kind, .notEditable)
        XCTAssertEqual(posts(t, "/options"), 0)
        XCTAssertEqual(t.intents[0].funding, 2100)
        XCTAssertEqual(t.orderRows.count, 1)
    }

    // MARK: Ambiguity, support and unverifiable hints

    func testAmbiguousAttemptsCloseBothMethodsOnEveryDevice() async throws {
        let t = tower()
        let a = try await ready(t)
        let first = await a.controller.continueToPayment()
        t.orderRows.append(.init(id: UUID().uuidString.lowercased(), intentId: t.intents[0].id, cents: 2100))   // legacy duplicate row
        let (b, loaded) = try await restored(t)
        XCTAssertEqual(loaded.paymentBlock, .ambiguous)
        XCTAssertTrue(loaded.paymentOptions.allSatisfy { !$0.available })
        XCTAssertNil(loaded.draft.paymentMethod, "nothing is chosen from an ambiguous report")
        let before = t.requests.count
        let card = await b.controller.continueToPayment()
        let lightning = await b.controller.continueToLightning()
        XCTAssertEqual(card.failure?.kind, .paymentNeedsSupport)
        XCTAssertEqual(lightning.failure?.kind, .paymentNeedsSupport)
        XCTAssertEqual(t.requests.count, before, "no payment request is signed or sent")
        // The device that already holds a card order is closed too, rather than replaying.
        let refreshed = await a.controller.refresh()
        XCTAssertEqual(refreshed.paymentBlock, .ambiguous)
        let replay = await a.controller.continueToPayment()
        XCTAssertEqual(replay.failure?.kind, .paymentNeedsSupport)
        XCTAssertNil(replay.checkoutURL)
        XCTAssertEqual(first.draft.checkoutOrderId, replay.draft.checkoutOrderId, "the local binding is kept")
    }

    func testSupportStateAndNullMethodBlockWithoutFabricatingFunding() async throws {
        let t = tower()
        let a = try await ready(t)
        let first = await a.controller.continueToLightning()
        let quote = try XCTUnwrap(first.lightning?.id)
        t.resolveQuote(quote, to: "late_payment")
        let (_, loaded) = try await restored(t)
        XCTAssertEqual(loaded.paymentBlock, .needsSupport)
        XCTAssertTrue(loaded.paymentOptions.allSatisfy { !$0.available })
        XCTAssertEqual(loaded.intent?.fundingConfirmed, false)
        XCTAssertNotEqual(loaded.phase, .readyToProvision)
        XCTAssertNil(loaded.lightningInvoice, "a late payment is never offered as payable")

        let t2 = tower()
        let a2 = try await ready(t2)
        _ = await a2.controller.continueToPayment()
        t2.attemptTamper = { $0["method"] = NSNull() }
        let (_, nullMethod) = try await restored(t2)
        XCTAssertEqual(nullMethod.paymentBlock, .needsSupport)
        XCTAssertNil(nullMethod.draft.paymentMethod)
    }

    func testContradictoryOrUnreadableHintsAreRefused() async throws {
        let cases: [(String, @Sendable (inout [String: Any]) -> Void)] = [
            ("amount", { $0["amount_cents"] = 5000 }),
            ("order id", { $0["order_id"] = "not-a-uuid" }),
            ("unknown method", { $0["method"] = "cheque" }),
            ("unknown state", { $0["state"] = "settled" }),
            ("quote on a card order", { $0["quote_id"] = UUID().uuidString.lowercased() }),
            ("missing count", { $0.removeValue(forKey: "count") }),
        ]
        for (label, tamper) in cases {
            let t = tower()
            let a = try await ready(t)
            _ = await a.controller.continueToPayment()
            t.attemptTamper = tamper
            let (b, loaded) = try await restored(t)
            XCTAssertEqual(loaded.paymentBlock, .unverifiable, label)
            XCTAssertNil(loaded.draft.paymentMethod, label)
            XCTAssertNil(loaded.draft.checkoutOrderId, label)
            let attempt = await b.controller.continueToPayment()
            XCTAssertEqual(attempt.failure?.kind, .paymentNeedsSupport, label)
            XCTAssertEqual(posts(t, "/checkout"), 1, "\(label): only the first device ever issued a request")
        }
    }

    func testLightningQuoteForAnotherIntentOrAmountIsNeverAdopted() async throws {
        let tampers: [(String, @Sendable (inout [String: Any]) -> Void)] = [
            ("foreign intent", { dto in var q = dto["quote"] as! [String: Any]; q["intent_id"] = UUID().uuidString.lowercased(); dto["quote"] = q }),
            ("quote amount", { dto in var q = dto["quote"] as! [String: Any]; q["amount_cents"] = 4200; dto["quote"] = q }),
            ("quote id", { dto in var q = dto["quote"] as! [String: Any]; q["id"] = UUID().uuidString.lowercased(); dto["quote"] = q }),
            ("no quote", { $0["quote"] = NSNull() }),
        ]
        for (label, tamper) in tampers {
            let t = tower()
            let a = try await ready(t)
            _ = await a.controller.continueToLightning()
            t.attemptTamper = tamper
            let (_, loaded) = try await restored(t)
            XCTAssertEqual(loaded.paymentBlock, .unverifiable, label)
            XCTAssertNil(loaded.lightning, label)
            XCTAssertNil(loaded.lightningInvoice, label)
            XCTAssertNil(loaded.draft.paymentMethod, label)
        }
    }

    func testMissingFieldAndNullNeverFreeALocalPayment() async throws {
        let t = tower()
        let a = try await ready(t)
        let paid = await a.controller.continueToPayment()
        t.reportsPaymentAttempt = false                       // an older NStack: the field is absent, which says nothing
        let older = await a.controller.refresh()
        XCTAssertEqual(older.draft.paymentMethod, "card")
        XCTAssertEqual(older.draft.checkoutOrderId, paid.draft.checkoutOrderId)
        t.reportsPaymentAttempt = true
        t.expireOrder(try XCTUnwrap(paid.draft.checkoutOrderId))       // the provider closed it; an ordinary read is an explicit null
        let nullRead = await a.controller.refresh()
        XCTAssertEqual(nullRead.draft.paymentMethod, "card", "an ordinary null read never clears keys; only the explicit release does")
        XCTAssertEqual(nullRead.draft.checkoutKey, paid.draft.checkoutKey)
        let lightning = await a.controller.continueToLightning()
        XCTAssertEqual(lightning.failure?.kind, .paymentMethodLocked)
    }

    func testHintDecodingDistinguishesMissingNullAndUnreadable() throws {
        func intent(_ extra: String) throws -> OnboardingIntent {
            let json = """
            {"version":1,"id":"\(UUID().uuidString.lowercased())","account_id":"acct","status":"open","revision":1,"workspace_name":"S","agent":null,"agent_state":"none",
             "funding_cents":2100,"return_state":null,"funded":false,"funded_at":null,"funding_reversed":false,"steps":{},"last_error":null,"workspace_id":null,
             "provisioned_at":null,"intro_ends_at":null,"created_at":"x","updated_at":"x"\(extra)}
            """
            return try JSONDecoder().decode(OnboardingIntent.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try intent("").paymentAttempt, .notReported)
        XCTAssertEqual(try intent(#","payment_attempt":null"#).paymentAttempt, PaymentAttemptReport.none)
        XCTAssertEqual(try intent(#","payment_attempt":"soon""#).paymentAttempt, .unreadable)
        XCTAssertEqual(try intent(#","payment_attempt":{"method":"card"}"#).paymentAttempt, .unreadable)
        let full = try intent(#","payment_attempt":{"method":"card","state":"open","resume":"checkout","order_id":"o","quote_id":null,"amount_cents":2100,"created_at":null,"quote":null,"count":1,"future":true}"#)
        guard case .attempt(let attempt) = full.paymentAttempt else { return XCTFail("expected an attempt") }
        XCTAssertEqual(attempt.method, "card"); XCTAssertEqual(attempt.count, 1)
    }

    // MARK: Explicit release

    func testReleaseOfAnUnpaidPaymentFreesKeysAndAllowsAnotherMethod() async throws {
        let t = tower()
        let a = try await ready(t)
        let paid = await a.controller.continueToPayment()
        XCTAssertTrue(paid.canReleasePayment)
        let released = await a.controller.releasePayment()
        XCTAssertNil(released.failure)
        XCTAssertEqual(posts(t, "/payment-attempt/release"), 1)
        XCTAssertNil(released.draft.paymentMethod); XCTAssertNil(released.draft.checkoutOrderId)
        XCTAssertNotEqual(released.draft.checkoutKey, paid.draft.checkoutKey, "the closed order's key is never replayed")
        XCTAssertEqual(released.phase, .review)
        let lightning = await a.controller.continueToLightning()
        XCTAssertNil(lightning.failure)
        XCTAssertNotNil(lightning.lightningInvoice)
        XCTAssertEqual(t.quotes.count, 1)
    }

    func testReleaseOfAPaidPaymentFundsTheIntentInsteadOfClearing() async throws {
        let t = tower(); t.releaseVerdict = .paid
        let a = try await ready(t)
        _ = await a.controller.continueToPayment()
        let released = await a.controller.releasePayment()
        XCTAssertEqual(released.intent?.fundingConfirmed, true)
        XCTAssertEqual(released.phase, .readyToProvision)
        XCTAssertNotEqual(released.draft.paymentMethod, nil, "server funding wins; no payment key was thrown away")
    }

    func testReleaseThatCannotBeVerifiedKeepsTheMethodAndKeys() async throws {
        let t = tower(); t.releaseVerdict = .unverified
        let a = try await ready(t)
        let paid = await a.controller.continueToPayment()
        let released = await a.controller.releasePayment()
        XCTAssertEqual(released.draft.paymentMethod, "card")
        XCTAssertEqual(released.draft.checkoutKey, paid.draft.checkoutKey)
        XCTAssertEqual(released.draft.checkoutOrderId, paid.draft.checkoutOrderId)
        XCTAssertNotNil(released.notice)
        XCTAssertEqual(released.intent?.fundingConfirmed, false)
        let lightning = await a.controller.continueToLightning()
        XCTAssertEqual(lightning.failure?.kind, .paymentMethodLocked)
        // A transport failure is unknown too.
        t.failures["POST /api/v4/onboarding/intents/\(t.intents[0].id)/payment-attempt/release"] = [URLError(.timedOut)]
        let timedOut = await a.controller.releasePayment()
        XCTAssertEqual(timedOut.failure?.kind, .network)
        XCTAssertEqual(timedOut.draft.paymentMethod, "card")
    }

    func testReleaseOnAnOlderNStackLeavesTheLockIntact() async throws {
        let t = tower(); t.releaseRouteMounted = false
        let a = try await ready(t)
        let paid = await a.controller.continueToPayment()
        let released = await a.controller.releasePayment()
        XCTAssertEqual(released.failure?.kind, .releaseUnavailable)
        XCTAssertEqual(released.phase, .awaitingPayment, "an unavailable route never ends the wizard")
        XCTAssertEqual(released.draft.paymentMethod, "card")
        XCTAssertEqual(released.draft.checkoutKey, paid.draft.checkoutKey)
        XCTAssertFalse(released.canReleasePayment, "the action is withdrawn once the NStack has no such route")
    }

    func testReleaseResolvesAnAmbiguousIntentOnlyWhenTheProviderVerifiesEveryAttempt() async throws {
        let t = tower()
        let a = try await ready(t)
        _ = await a.controller.continueToPayment()
        t.orderRows.append(.init(id: UUID().uuidString.lowercased(), intentId: t.intents[0].id, cents: 2100))
        let (b, loaded) = try await restored(t)
        XCTAssertEqual(loaded.paymentBlock, .ambiguous)
        XCTAssertTrue(loaded.canReleasePayment)
        t.releaseVerdict = .unverified
        let stuck = await b.controller.releasePayment()
        XCTAssertEqual(stuck.paymentBlock, .ambiguous)
        t.releaseVerdict = .expire
        let freed = await b.controller.releasePayment()
        XCTAssertNil(freed.paymentBlock)
        XCTAssertTrue(freed.paymentOptions.contains { $0.method == .card && $0.available })
    }

    func testReleaseRefusesWithoutAnOpenUnfundedIntentOrTheRightIdentity() async throws {
        let t = tower()
        let none = try await ready(t)
        let before = t.requests.count
        let early = await none.controller.releasePayment()
        XCTAssertEqual(early.failure?.kind, .notEditable)
        XCTAssertEqual(t.requests.count, before, "nothing is sent without an intent")
        let other = try await OnboardingFixture.controller(t, signer: OnboardingFixture.otherIdentity(), store: MemoryOnboardingDraftStore(), returnURL: nil)
        _ = await other.load()
        let foreign = await other.releasePayment()
        XCTAssertEqual(foreign.failure?.kind, .notEditable)
        XCTAssertEqual(posts(t, "/payment-attempt/release"), 0)
    }

    func testCanonicalOrderChangeRekeysInsteadOfReplayingTheClosedOrder() async throws {
        let t = tower()
        let a = try await ready(t)
        let first = await a.controller.continueToPayment()
        let closed = try XCTUnwrap(first.draft.checkoutOrderId)
        t.expireOrder(closed)                                     // the provider closed it; another device then pays with a new order
        let (b, _) = try await restored(t)
        _ = await b.controller.confirmReview()
        let second = await b.controller.continueToPayment()
        let canonical = try XCTUnwrap(second.draft.checkoutOrderId)
        XCTAssertNotEqual(canonical, closed)
        let seen = await a.controller.refresh()
        XCTAssertEqual(seen.draft.checkoutOrderId, canonical)
        XCTAssertNotEqual(seen.draft.checkoutKey, first.draft.checkoutKey, "the old key would replay the closed order")
        XCTAssertNil(seen.paymentBlock)
        let resumed = await a.controller.continueToPayment()
        XCTAssertNil(resumed.failure)
        XCTAssertNotNil(resumed.checkoutURL)
        XCTAssertEqual(resumed.draft.checkoutOrderId, canonical)
        XCTAssertEqual(t.orderRows.filter { $0.state == "open" }.count, 1)
        XCTAssertEqual(t.orderRows.count, 2)
    }

    func testSameOrderKeepsItsKeyAndTheHintReplacesAConflictingLocalOrder() async throws {
        let t = tower()
        let a = try await ready(t)
        let first = await a.controller.continueToPayment()
        let same = await a.controller.refresh()
        XCTAssertEqual(same.draft.checkoutKey, first.draft.checkoutKey, "the same order keeps the key that created it")
        var conflicting = same.draft
        conflicting.checkoutOrderId = UUID().uuidString.lowercased()
        try a.store.save(conflicting)
        let relaunched = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: a.store, returnURL: nil)
        let loaded = await relaunched.load()
        XCTAssertEqual(loaded.draft.checkoutOrderId, first.draft.checkoutOrderId, "NStack's single outstanding order wins")
        XCTAssertNotEqual(loaded.draft.checkoutKey, first.draft.checkoutKey, "the unknown local order's key is not replayed")
        XCTAssertNil(loaded.paymentBlock)
        XCTAssertEqual(t.orderRows.count, 1)
    }

    func testAnOrderOtherThanTheOneThisDeviceWasToldIsNeverOpened() async throws {
        let t = tower()
        let a = try await ready(t)
        let first = await a.controller.continueToPayment()
        var conflicting = first.draft
        conflicting.checkoutOrderId = UUID().uuidString.lowercased()
        try a.store.save(conflicting)
        t.reportsPaymentAttempt = false                          // an older NStack gives no hint to reconcile with
        let relaunched = try await OnboardingFixture.controller(t, signer: makeIdentity(), store: a.store, returnURL: nil)
        _ = await relaunched.load()
        let answer = await relaunched.continueToPayment()
        XCTAssertNil(answer.checkoutURL)
        XCTAssertEqual(answer.failure?.kind, .paymentNeedsSupport)
        XCTAssertEqual(answer.paymentBlock, .unverifiable)
        XCTAssertTrue(answer.paymentOptions.allSatisfy { !$0.available })
    }

    func testBlockedPaymentNeverLeavesAnInvoiceOrWalletLinkVisible() async throws {
        let changes: [(String, @Sendable (FakeOnboardingTower, String) -> Void)] = [
            ("needs support", { t, quote in t.resolveQuote(quote, to: "late_payment") }),
            ("ambiguous", { t, _ in t.orderRows.append(.init(id: UUID().uuidString.lowercased(), intentId: t.intents[0].id, cents: 2100)) }),
            ("invalid hint", { t, _ in t.attemptTamper = { $0["amount_cents"] = 7 } }),
        ]
        for (label, change) in changes {
            let t = tower()
            let a = try await ready(t)
            let open = await a.controller.continueToLightning()
            XCTAssertNotNil(open.lightningInvoice, label)
            change(t, try XCTUnwrap(open.lightning?.id))
            let blocked = await a.controller.refresh()
            XCTAssertNotNil(blocked.paymentBlock, label)
            XCTAssertNil(blocked.lightningInvoice, "\(label): no payable invoice")
            XCTAssertTrue(blocked.lightning == nil || blocked.lightning?.state.needsSupport == true, "\(label): an open quote is hidden; only a support status may remain")
            XCTAssertTrue(blocked.paymentOptions.allSatisfy { !$0.available }, label)
        }
    }

    // MARK: Durability

    func testFailedSaveAfterReleaseKeepsKeysAndSendsNothingUntilItSucceeds() async throws {
        let t = tower()
        let armed = ArmedFlag()
        let store = FlakyDraftStore(failWhen: { armed.value && $0.intentId != nil && $0.paymentMethod == nil })
        let a = try await ready(t, store: store)
        let paid = await a.controller.continueToPayment()
        armed.set(true)
        let failed = await a.controller.releasePayment()
        XCTAssertEqual(failed.failure?.kind, .persistence)
        XCTAssertEqual(failed.draft.paymentMethod, "card", "memory never gets ahead of disk")
        XCTAssertEqual(failed.draft.checkoutKey, paid.draft.checkoutKey)
        XCTAssertEqual(store.load(origin: t.origin, signerNpub: failed.draft.signerNpub)?.paymentMethod, "card")
        let before = t.requests.count
        let lightning = await a.controller.continueToLightning()
        XCTAssertEqual(lightning.failure?.kind, .paymentMethodLocked)
        XCTAssertEqual(t.requests.count, before, "no new payment request while the release is not durable")
        armed.set(false)
        let retry = await a.controller.releasePayment()
        XCTAssertNil(retry.failure)
        XCTAssertNil(retry.draft.paymentMethod)
        XCTAssertNil(store.load(origin: t.origin, signerNpub: retry.draft.signerNpub)?.paymentMethod)
        let next = await a.controller.continueToLightning()
        XCTAssertNotNil(next.lightningInvoice)
    }

    func testFailedSaveWhileAdoptingAPaymentExposesNothing() async throws {
        let t = tower()
        let a = try await ready(t)
        _ = await a.controller.continueToLightning()
        let store = FlakyDraftStore(failWhen: { $0.paymentMethod != nil })
        let (b, loaded) = try await {
            let d = try await device(t, name: "B", store: store)
            return (d, await d.controller.load())
        }()
        XCTAssertEqual(loaded.failure?.kind, .persistence)
        XCTAssertNil(loaded.draft.paymentMethod)
        XCTAssertNil(loaded.lightning)
        XCTAssertNil(loaded.lightningInvoice)
        _ = await b.controller.continueToLightning()
        _ = await b.controller.continueToPayment()
        XCTAssertEqual(posts(t, "/checkout"), 0)
        XCTAssertEqual(posts(t, "/lightning/quote"), 1, "only the first device ever asked")
        XCTAssertEqual(t.quotes.count, 1)
    }

    // MARK: Delayed responses

    func testHeldCheckoutAnswerBlocksEveryOtherPaymentOperationUntilItLands() async throws {
        let t = tower()
        let a = try await ready(t)
        let held = HeldAnswer()
        defer { held.release() }
        t.responseGate = { seen in if seen.path.hasSuffix("/checkout") { await held.hold() } }
        let card = Task { await a.controller.continueToPayment() }
        try await held.waitUntilHeld()
        let mark = t.requests.count
        let lightning = Task { await a.controller.continueToLightning() }
        try await waitForQueue(a.controller, 1)                   // arrival order is part of what is asserted
        let release = Task { await a.controller.releasePayment() }
        try await waitForQueue(a.controller, 2)
        let refresh = Task { await a.controller.refresh() }
        try await waitForQueue(a.controller, 3)
        XCTAssertEqual(t.requests.count, mark, "later operations wait; the held answer cannot be overtaken or overwritten")
        held.release()
        let results = await (card.value, lightning.value, release.value, refresh.value)
        XCTAssertNotNil(results.0.checkoutURL)
        XCTAssertEqual(results.1.failure?.kind, .paymentMethodLocked)
        XCTAssertEqual(t.orderRows.count, 1)
        XCTAssertTrue(t.quotes.isEmpty, "the lightning request was refused locally after the card answer landed")
        let order = t.orderRows[0]
        // The queued release was an explicit request and ran afterwards; it closed the order, so the keys were freed in order, not mid-flight.
        XCTAssertEqual(order.state, "expired")
        let final = await a.controller.snapshot()
        XCTAssertNil(final.draft.paymentMethod)
    }

    func testLostCheckoutAnswerIsReplayedWithTheSameKeyAndReturnsTheCanonicalOrder() async throws {
        let t = tower()
        let a = try await ready(t)
        t.dropResponses["/checkout"] = 1
        let lost = await a.controller.continueToPayment()
        XCTAssertEqual(lost.failure?.kind, .network)
        XCTAssertEqual(lost.draft.paymentMethod, "card")
        let (b, loaded) = try await restored(t)                    // another device sees the order the lost answer created
        XCTAssertEqual(loaded.draft.checkoutOrderId, t.orderRows[0].id)
        let replay = await a.controller.continueToPayment()
        XCTAssertNotNil(replay.checkoutURL)
        let resumed = await b.controller.continueToPayment()
        XCTAssertNotNil(resumed.checkoutURL)
        XCTAssertEqual(t.orderRows.count, 1)
    }
}

private final class ArmedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set(_ v: Bool) { lock.withLock { flag = v } }
}

private final class HeldAnswer: @unchecked Sendable {
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
            guard ContinuousClock.now < deadline else { throw NSError(domain: "HeldAnswerTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func release() { lock.withLock { released = true; continuations.forEach { $0.resume() }; continuations = [] } }
}
