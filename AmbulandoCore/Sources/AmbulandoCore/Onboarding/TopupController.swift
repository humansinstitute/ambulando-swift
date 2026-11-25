import Foundation

public enum TopupUnavailability: Equatable, Sendable {
    case originRejected(String)
    case backendMissing
    case rolloutDisabled
    /// No account yet, or the first workspace has not finished provisioning.
    case notProvisioned
    case signerRefused
    case signerMismatch
    case identityLocked
    /// A read failed (offline, server error); the failure is shown and checking again is safe.
    case loadFailed
    /// A saved attempt exists on this device but cannot be read. Nothing is started until it is understood: its key and order may still be payable.
    case draftUnreadable
}

public enum TopupPhase: Equatable, Sendable {
    case checking
    case unavailable(TopupUnavailability)
    case ready
}

public struct TopupSnapshot: Equatable, Sendable {
    public var phase: TopupPhase = .checking
    public var overview: OnboardingAccountOverview?
    public var list: TopupList?
    /// Exact limits from the server's signed config when it publishes them, else the documented US$21 minimum.
    public var limits = TopupLimits.documented
    public var cardAvailable = false
    public var lightningAvailable = false
    public var attempt: TopupAttempt?
    public var quote: LightningQuote?
    public var invoice: PayableInvoice?
    /// Transient: the Stripe test-mode page for the open attempt. Never persisted; a relaunch replays the same key.
    public var checkoutURL: URL?
    public var failure: OnboardingFailure?
    public var notice: String?
    public var busy = false
    public var backupGate: PaymentBackupGate = .allowed
    public init() {}
    /// Quotes NStack lists as unresolved (late or mismatched payment): money may have moved and only support can settle it.
    public var needsSupport: [TopupPendingQuote] { (list?.pending_lightning ?? []).filter { LightningQuoteState($0.state).needsSupport } }
}

/// Repeat account top-ups after provisioning (tower docs/contract/onboarding-v1.md "Repeat account top-ups"). Account credit only: nothing
/// here creates an intent, workspace, seat or introduction, and nothing is automatic or recurring.
///
/// Rules: nothing signed is sent before the Tower's own descriptor confirms the origin; every request is bound to the expected signer; at most
/// one payment attempt is open per device and it is saved (key, amount, return address) before the request that can create a payable order;
/// credit exists only as a settlement NStack lists, never because of a redirect, a wallet return, a "paid" hint or elapsed time.
public actor TopupController {
    private let api: OnboardingAPI
    private let transport: HTTPTransport
    private let signer: EventSigner
    private let signerNpub: String
    private let store: TopupDraftStore
    private let makeKey: @Sendable () -> String
    private let backupGate: (@Sendable () async -> PaymentBackupGate)?
    private var cardReturn: URL?
    private var state: TopupSnapshot
    private var draft: TopupDraft
    private let draftUnreadable: Bool
    private var inflight: [String: Task<TopupSnapshot, Never>] = [:]

    public init(origin: TowerOrigin, signerNpub: String, signer: EventSigner, transport: HTTPTransport, store: TopupDraftStore,
                backupGate: (@Sendable () async -> PaymentBackupGate)? = nil, makeKey: @escaping @Sendable () -> String = OnboardingController.randomKey) {
        let bound = BoundSigner(inner: signer, expectedHex: NostrKeys.publicKeyHex(npub: signerNpub) ?? "")
        self.api = OnboardingAPI(client: TowerClient(origin: origin, transport: transport, signer: bound))
        self.transport = transport; self.signer = bound; self.signerNpub = signerNpub; self.store = store; self.makeKey = makeKey; self.backupGate = backupGate
        let loaded: TopupDraft?
        do { loaded = try store.load(origin: origin.description, signerNpub: signerNpub); draftUnreadable = false }
        catch { loaded = nil; draftUnreadable = true }
        draft = loaded ?? TopupDraft(origin: origin.description, signerNpub: signerNpub)
        state = TopupSnapshot(); state.attempt = draft.attempt
    }

    public func snapshot() -> TopupSnapshot { state }

    // MARK: Load and reconcile

    @discardableResult public func load() async -> TopupSnapshot { await coalesced("load") { await $0.doLoad() } }

    private func doLoad() async -> TopupSnapshot {
        state.phase = .checking; state.failure = nil; state.notice = nil
        guard !draftUnreadable else { return unavailable(.draftUnreadable) }
        guard await signerMatches() else { return unavailable(.signerMismatch) }
        state.backupGate = await backupGate?() ?? .allowed
        do { _ = try await TowerAPI(client: TowerClient(origin: api.origin, transport: transport, signer: nil)).descriptor() }
        catch { return unavailable(.originRejected(error.localizedDescription)) }
        do {
            if let config = try await api.deploymentConfig() {
                cardReturn = config.approvedCardReturn
                state.cardAvailable = cardReturn != nil
                state.lightningAvailable = config.lightningOffered
                state.limits = config.topupLimits
            } else { cardReturn = nil; state.cardAvailable = false; state.lightningAvailable = false; state.limits = .documented }
            state.overview = try await api.accountOverview()
            try await resumeAttempt()
            state.list = try await api.topups()
        } catch { return failed(error) }
        state.phase = .ready
        return state
    }

    /// Replays the open attempt with its own key (idempotent), or asks the server's provider for the quote's current state, then closes the
    /// attempt locally only on NStack's own word.
    private func resumeAttempt() async throws {
        guard let attempt = draft.attempt else { return }
        switch attempt.method {
        case .lightning:
            if let quoteId = attempt.quoteId { try applyQuote(try await api.refreshTopupQuote(quoteId), for: attempt) }
            else { try applyQuote(try await api.topupQuote(idempotencyKey: attempt.key, amountCents: attempt.amountCents), for: attempt) }
        case .card:
            if let orderId = attempt.orderId {
                // NStack lists an order only while it is neither fulfilled nor terminal; absence is its word that nothing is payable any more.
                let list = try await api.topups()
                if !list.pending_checkout.contains(where: { $0.order_id == orderId }) {
                    try closeAttempt("That card payment is no longer open at NStack. If you paid, the credit appears in your credited top-ups once NStack has verified it.")
                }
            } else if let url = attempt.returnURL.flatMap(URL.init(string:)) {
                try await openCheckout(attempt, returnURL: url)
            }
        }
    }

    @discardableResult public func refresh() async -> TopupSnapshot { await coalesced("refresh") { await $0.doRefresh() } }

    private func doRefresh() async -> TopupSnapshot {
        state.failure = nil
        guard !draftUnreadable else { return unavailable(.draftUnreadable) }
        guard await signerMatches() else { return unavailable(.signerMismatch) }
        do {
            state.overview = try await api.accountOverview()
            try await resumeAttempt()
            state.list = try await api.topups()
        } catch { return failed(error) }
        state.phase = .ready
        return state
    }

    /// A return to the app. The address only decides whether to ask NStack; it credits nothing.
    @discardableResult public func paymentReturned(_ url: URL?) async -> TopupSnapshot {
        guard let url, let attempt = draft.attempt, let text = attempt.returnURL, let expected = URL(string: text), OnboardingController.sameAddress(url, expected) else {
            state.notice = "Ignored a payment return that did not match an open top-up."
            return state
        }
        state.notice = nil
        return await refresh()
    }

    // MARK: Start

    @discardableResult public func startCard(amountCents: Int) async -> TopupSnapshot { await coalesced("start") { await $0.doStartCard(amountCents) } }
    @discardableResult public func startLightning(amountCents: Int) async -> TopupSnapshot { await coalesced("start") { await $0.doStartLightning(amountCents) } }

    private func preflight(_ amountCents: Int) async -> TopupSnapshot? {
        state.failure = nil; state.notice = nil; state.checkoutURL = nil
        guard !draftUnreadable else { return unavailable(.draftUnreadable) }
        guard state.phase == .ready else { return refuse(OnboardingFailure(kind: .fundingRequired)) }
        guard await signerMatches() else { return unavailable(.signerMismatch) }
        state.backupGate = await backupGate?() ?? .allowed
        switch state.backupGate {
        case .allowed: break
        case .localBackupRequired: return refuse(OnboardingFailure(kind: .backupRequired))
        case .hostedBackupRequired: return refuse(OnboardingFailure(kind: .hostedBackupRequired))
        }
        if draft.attempt != nil { return refuse(OnboardingFailure(kind: .paymentMethodLocked)) }
        guard state.limits.valid(amountCents) else { return refuse(OnboardingFailure(kind: .validation, code: "invalid_amount")) }
        return nil
    }

    private func doStartCard(_ amountCents: Int) async -> TopupSnapshot {
        if let stop = await preflight(amountCents) { return stop }
        guard state.cardAvailable, let returnURL = cardReturn else { return refuse(OnboardingFailure(kind: .paymentUnavailable, code: "card_unavailable")) }
        let attempt = TopupAttempt(method: .card, key: makeKey(), amountCents: amountCents, returnURL: returnURL.absoluteString, orderId: nil, quoteId: nil)
        do { try save(attempt); try await openCheckout(attempt, returnURL: returnURL) } catch { return failed(error, attempt: attempt) }
        return state
    }

    private func doStartLightning(_ amountCents: Int) async -> TopupSnapshot {
        if let stop = await preflight(amountCents) { return stop }
        guard state.lightningAvailable else { return refuse(OnboardingFailure(kind: .paymentUnavailable, code: "lightning_unavailable")) }
        let attempt = TopupAttempt(method: .lightning, key: makeKey(), amountCents: amountCents, returnURL: nil, orderId: nil, quoteId: nil)
        do { try save(attempt); try applyQuote(try await api.topupQuote(idempotencyKey: attempt.key, amountCents: amountCents), for: attempt) }
        catch { return failed(error, attempt: attempt) }
        return state
    }

    /// Re-requests the open card attempt's page with its own key (the same order) after the page was closed.
    @discardableResult public func reopenCheckout() async -> TopupSnapshot { await coalesced("start") { await $0.doReopen() } }
    private func doReopen() async -> TopupSnapshot {
        state.failure = nil; state.checkoutURL = nil
        guard await signerMatches() else { return unavailable(.signerMismatch) }
        guard let attempt = draft.attempt, attempt.method == .card, let url = attempt.returnURL.flatMap(URL.init(string:)) else { return state }
        do { try await openCheckout(attempt, returnURL: url) } catch { return failed(error) }
        return state
    }

    /// Replays an invoice request whose answer was lost, with the same key.
    @discardableResult public func resumeInvoice() async -> TopupSnapshot { await coalesced("start") { await $0.doResumeInvoice() } }
    private func doResumeInvoice() async -> TopupSnapshot {
        state.failure = nil
        guard await signerMatches() else { return unavailable(.signerMismatch) }
        guard let attempt = draft.attempt, attempt.method == .lightning else { return state }
        do {
            if let quoteId = attempt.quoteId { try applyQuote(try await api.refreshTopupQuote(quoteId), for: attempt) }
            else { try applyQuote(try await api.topupQuote(idempotencyKey: attempt.key, amountCents: attempt.amountCents), for: attempt) }
        } catch { return failed(error) }
        return state
    }

    // MARK: Internals

    private func openCheckout(_ attempt: TopupAttempt, returnURL: URL) async throws {
        let checkout = try await api.topupCheckout(idempotencyKey: attempt.key, returnURL: returnURL, amountCents: attempt.amountCents)
        guard checkout.mode == "test", checkout.amount_cents == attempt.amountCents, let url = OnboardingController.safeCheckoutURL(checkout.checkout_url) else {
            throw OnboardingFailure(kind: .paymentUnavailable, code: "unexpected_checkout")
        }
        var bound = attempt; bound.orderId = checkout.order_id
        try save(bound)                      // the order binding is durable before the browser is opened
        state.checkoutURL = url
    }

    /// Accepts a quote only for this attempt's own amount and as an account (non-intent) quote; closes the attempt only on a state NStack's
    /// provider verified. `settled` is NStack's word; the credit itself is read back from the list.
    private func applyQuote(_ quote: LightningQuote, for attempt: TopupAttempt) throws {
        guard quote.intent_id == nil, quote.amount_cents == attempt.amountCents, attempt.quoteId == nil || attempt.quoteId == quote.id else {
            throw OnboardingFailure(kind: .paymentUnavailable, code: "unexpected_quote")
        }
        if attempt.quoteId == nil { var bound = attempt; bound.quoteId = quote.id; try save(bound) }
        state.quote = quote
        state.invoice = PayableInvoice(quote)
        switch quote.state {
        case .settled: try closeAttempt("NStack verified the Lightning payment. The credit shows below once it is recorded.", keepQuote: true)
        case .expired, .cancelled: try closeAttempt("NStack confirmed that invoice can no longer be paid. Nothing was credited; you can ask for a new one.", keepQuote: true)
        case .latePayment, .mismatch, .unknown:
            try closeAttempt("NStack recorded a payment on this invoice that it did not credit automatically. Do not pay again; contact support with the invoice details below.", keepQuote: true)
        case .open where state.invoice == nil: throw OnboardingFailure(kind: .paymentUnavailable, code: "unexpected_quote")
        case .open, .issuing: break
        }
    }

    private func save(_ attempt: TopupAttempt) throws {
        var next = draft; next.attempt = attempt
        do { try store.save(next) } catch { throw OnboardingFailure(kind: .persistence) }
        draft = next; state.attempt = attempt
    }

    private func closeAttempt(_ note: String, keepQuote: Bool = false) throws {
        var next = draft; next.attempt = nil
        do { try store.save(next) } catch { throw OnboardingFailure(kind: .persistence) }
        draft = next; state.attempt = nil; state.checkoutURL = nil
        if !keepQuote { state.quote = nil; state.invoice = nil }
        state.notice = note
    }

    private func signerMatches() async -> Bool {
        guard let hex = try? await signer.publicKeyHex(), NostrKeys.npub(publicKeyHex: hex) == signerNpub else { return false }
        return true
    }

    private func coalesced(_ name: String, _ work: @escaping @Sendable (TopupController) async -> TopupSnapshot) async -> TopupSnapshot {
        if let running = inflight[name] { return await running.value }
        let task = Task { await work(self) }
        inflight[name] = task
        state.busy = true
        let result = await task.value
        inflight[name] = nil
        state.busy = !inflight.isEmpty
        var out = result; out.busy = state.busy
        return out
    }

    private func refuse(_ failure: OnboardingFailure) -> TopupSnapshot { state.failure = failure; return state }

    private func unavailable(_ why: TopupUnavailability) -> TopupSnapshot { state.phase = .unavailable(why); state.failure = nil; return state }

    /// A definite refusal made no order, so a just-saved attempt is dropped; anything else may have created one and the attempt stays for replay.
    private func failed(_ error: Error, attempt: TopupAttempt? = nil) -> TopupSnapshot {
        if let identity = error as? IdentityError { return unavailable(identity == .locked ? .identityLocked : .signerMismatch) }
        let failure = (error as? OnboardingFailure) ?? OnboardingFailure(kind: (error is TowerError) ? .malformed : .network)
        if let attempt, draft.attempt == attempt, attempt.orderId == nil, attempt.quoteId == nil, OnboardingController.rejectedBeforeAnyOrder(failure) {
            var next = draft; next.attempt = nil
            if (try? store.save(next)) != nil { draft = next; state.attempt = nil }
        }
        switch failure.kind {
        case .backendMissing: state.phase = .unavailable(.backendMissing)
        case .rolloutDisabled: state.phase = .unavailable(.rolloutDisabled)
        case .accountNotProvisioned: state.phase = .unavailable(.notProvisioned)
        case .signerRefused: state.phase = .unavailable(.signerRefused)
        default: if state.phase == .checking { state.phase = .unavailable(.loadFailed) }
        }
        state.failure = failure
        return state
    }
}
