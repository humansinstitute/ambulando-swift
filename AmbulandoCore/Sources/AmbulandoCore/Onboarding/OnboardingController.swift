import Foundation

public enum OnboardingUnavailability: Equatable, Sendable {
    case originRejected(String)
    case backendMissing
    case rolloutDisabled
    case offline
    case signerRefused
    case signerMismatch
}

public enum OnboardingPhase: Equatable, Sendable {
    case checking
    case unavailable(OnboardingUnavailability)
    case form
    case review
    case awaitingPayment
    case readyToProvision
    case provisioning
    case provisioned
    case cancelled
}

public struct OnboardingPaymentOption: Equatable, Sendable {
    public enum Method: String, Sendable { case card, lightning }
    public let method: Method
    public let available: Bool
    /// Always honest: card checkout is Stripe test mode only in this slice.
    public let label: String
    public let unavailableReason: String?
}

/// Where a provisioned workspace may land. Only what the server's recorded steps prove: selecting an agent proves nothing.
public struct OnboardingLanding: Equatable, Sendable {
    public let workspaceId: String?
    public let generalReady: Bool
    public let agentName: String?
    public let agentRunning: Bool
}

public struct OnboardingSnapshot: Equatable, Sendable {
    public var phase: OnboardingPhase = .checking
    public var draft: OnboardingDraft
    public var intent: OnboardingIntent?
    public var account: OnboardingAccount?
    public var offers: [OnboardingAgentOffer] = []
    public var failure: OnboardingFailure?
    public var notice: String?
    /// Transient: the Stripe test-mode page to open. Never persisted; a relaunch asks again with the same operation key.
    public var checkoutURL: URL?
    public var paymentOptions: [OnboardingPaymentOption] = []
    public var landing: OnboardingLanding?
    public var busy = false
    /// The user must pick a first request themselves; the app never sends paid work on their behalf.
    public var agentNeedsFirstRequest: Bool { intent?.agent_state == .selected_not_provisioned || intent?.agent_state == .provisioned }
}

/// Durable, resumable controller for the invited-onboarding wizard of one (Tower origin, signer) pair.
///
/// Rules it enforces: nothing signed is sent until the Tower's own descriptor confirms the origin; the draft and every server
/// read are scoped to this signer (a different unlocked identity gets `signerMismatch`, never this state); money is "in" only when
/// the server reports a verified funded intent (a redirect, a return URL or a flag never funds); provisioning is refused locally
/// until funding is confirmed and is coalesced so a double tap or relaunch never issues two requests; operation keys are stable.
public actor OnboardingController {
    private let api: OnboardingAPI
    private let transport: HTTPTransport
    private let signer: EventSigner
    private let signerNpub: String
    private let store: OnboardingDraftStore
    private let returnURL: URL?
    private let makeKey: @Sendable () -> String
    private var state: OnboardingSnapshot
    private var inflight: [String: Task<OnboardingSnapshot, Never>] = [:]
    private var loaded = false

    public init(origin: TowerOrigin, signerNpub: String, signer: EventSigner, transport: HTTPTransport, store: OnboardingDraftStore,
                returnURL: URL?, makeKey: @escaping @Sendable () -> String = OnboardingController.randomKey) {
        self.api = OnboardingAPI(client: TowerClient(origin: origin, transport: transport, signer: signer))
        self.transport = transport; self.signer = signer; self.signerNpub = signerNpub; self.store = store
        self.returnURL = returnURL.flatMap(Self.approvedReturn); self.makeKey = makeKey
        let draft = store.load(origin: origin.description, signerNpub: signerNpub)
            ?? OnboardingDraft(origin: origin.description, signerNpub: signerNpub, createKey: makeKey(), checkoutKey: makeKey())
        state = OnboardingSnapshot(draft: draft)
        state.paymentOptions = Self.options(returnURL: self.returnURL, paymentBlocked: false)
    }

    public static let randomKey: @Sendable () -> String = {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let text = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "ob_" + text
    }

    /// The return URL is sent to the server, which accepts only an exact allowlist member; the client also refuses anything that
    /// is not plain https (or loopback http) without credentials, query or fragment.
    static func approvedReturn(_ url: URL) -> URL? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return nil }
        let loopback = ["localhost", "127.0.0.1"].contains(host)
        guard c.scheme == "https" || (c.scheme == "http" && loopback) else { return nil }
        return url
    }

    static func options(returnURL: URL?, paymentBlocked: Bool) -> [OnboardingPaymentOption] {
        let card: OnboardingPaymentOption
        if returnURL == nil {
            card = .init(method: .card, available: false, label: "Card (test mode)", unavailableReason: "This build has no approved payment return address, so card checkout is switched off.")
        } else if paymentBlocked {
            card = .init(method: .card, available: false, label: "Card (test mode)", unavailableReason: "The Tower reports payment is not available right now.")
        } else {
            card = .init(method: .card, available: true, label: "Card (Stripe test mode; no real money)", unavailableReason: nil)
        }
        return [card, .init(method: .lightning, available: false, label: "Lightning", unavailableReason: "No Lightning provider is connected to NStack yet.")]
    }

    public func snapshot() -> OnboardingSnapshot { state }

    // MARK: Loading and resume

    /// Verifies the origin, reads the account and catalogue, then resumes the server's record of this signer's intent.
    @discardableResult public func load() async -> OnboardingSnapshot {
        await coalesced("load") { await $0.doLoad() }
    }

    private func doLoad() async -> OnboardingSnapshot {
        state.phase = .checking; state.failure = nil
        guard await signerMatches() else { return fail(.unavailable(.signerMismatch), nil) }
        do { _ = try await TowerAPI(client: TowerClient(origin: api.origin, transport: transport, signer: nil)).descriptor() }
        catch { return fail(.unavailable(.originRejected(error.localizedDescription)), nil) }
        do {
            state.account = try await api.account()
            state.offers = (try? await api.agentOffers()) ?? []
            try await resumeIntent()
        } catch { return failed(error) }
        loaded = true
        return settle()
    }

    private func resumeIntent() async throws {
        if let id = state.draft.intentId {
            do { adopt(try await api.intent(id)) }
            catch let f as OnboardingFailure where f.kind == .notFound {
                // Not this signer's intent (or removed): never reuse it. Form choices stay; keys rotate so nothing is replayed.
                dropIntent(note: "The earlier setup could not be found for this identity, so a new one will be created.")
            }
        } else if let active = try await api.intents().first(where: { [.open, .funded, .provisioning].contains($0.status) }) {
            adopt(active)
        }
    }

    // MARK: Form

    public func edit(name: String? = nil, fundingCents: Int? = nil, agentOfferId: String?? = nil, agentDailyCapCents: Int?? = nil, invite: OnboardingInviteCode? = nil) -> OnboardingSnapshot {
        var d = state.draft
        if let name { d.workspaceName = name }
        if let fundingCents { d.fundingCents = fundingCents }
        if let agentOfferId { d.agentOfferId = agentOfferId; if agentOfferId == nil { d.agentDailyCapCents = nil } }
        if let agentDailyCapCents { d.agentDailyCapCents = agentDailyCapCents }
        if let invite, d.intentId == nil { d.invite = invite }
        state.draft = d
        save()
        return settle()
    }

    /// Back from the review screen to editing.
    public func reopenForEditing() -> OnboardingSnapshot {
        state.draft.reviewedDigest = nil; save(); return settle()
    }

    /// Validates the choices locally. Nothing is sent. The review screen is the gate in front of every side effect.
    public func confirmReview() -> OnboardingSnapshot {
        state.failure = nil
        if let failure = validateForm() { state.failure = failure; return settle() }
        // Pin the effective cap so the reviewed choices equal what the server will record.
        if let id = state.draft.agentOfferId, state.draft.agentDailyCapCents == nil { state.draft.agentDailyCapCents = state.offers.first { $0.id == id }?.default_daily_cap_cents }
        state.draft.reviewedDigest = state.draft.formDigest
        save()
        return settle()
    }

    private func validateForm() -> OnboardingFailure? {
        let d = state.draft
        guard OnboardingName.normalized(d.workspaceName) != nil, OnboardingFunding.valid(d.fundingCents) else { return OnboardingFailure(kind: .validation, code: "invalid_form") }
        if d.intentId == nil, d.invite == nil { return OnboardingFailure(kind: .inviteInvalid) }
        if let offerId = d.agentOfferId {
            guard let offer = state.offers.first(where: { $0.id == offerId }) else { return OnboardingFailure(kind: .agentUnavailable) }
            let cap = d.agentDailyCapCents ?? offer.default_daily_cap_cents
            guard (1...offer.max_daily_cap_cents).contains(cap) else { return OnboardingFailure(kind: .validation, code: "invalid_agent_daily_cap") }
        }
        return nil
    }

    // MARK: Create / update, then pay

    /// After review: make sure the server holds this intent (create, adopt a lost-response duplicate, or push option changes),
    /// then ask for the test-mode checkout. Safe to call again after any failure or relaunch.
    @discardableResult public func continueToPayment() async -> OnboardingSnapshot {
        await coalesced("pay") { await $0.doPay() }
    }

    private func doPay() async -> OnboardingSnapshot {
        state.failure = nil; state.notice = nil; state.checkoutURL = nil
        guard await signerMatches() else { return fail(.unavailable(.signerMismatch), nil) }
        guard state.draft.reviewedDigest == state.draft.formDigest, validateForm() == nil else { return settle(OnboardingFailure(kind: .validation, code: "review_required")) }
        do {
            try await ensureIntent()
            guard let intent = state.intent else { return settle() }
            if intent.fundingConfirmed { return settle() }
            try await requestCheckout(intent)
        } catch { return failed(error) }
        return settle()
    }

    private func ensureIntent() async throws {
        var d = state.draft
        let name = OnboardingName.normalized(d.workspaceName)!
        if let intent = state.intent, d.intentId != nil {
            try await pushOptions(intent, name: name)
            return
        }
        guard let invite = d.invite else { throw OnboardingFailure(kind: .inviteInvalid) }
        let cap = d.agentOfferId.map { id in d.agentDailyCapCents ?? state.offers.first { $0.id == id }?.default_daily_cap_cents } ?? nil
        let digest = SHA256Hex.of("\(invite.rawValue)\n\(name)\n\(d.fundingCents)\n\(d.agentOfferId ?? "-")\n\(cap.map(String.init) ?? "-")")
        // A different body needs a different key; the same body keeps its key across retries and relaunches.
        if d.createDigest != nil, d.createDigest != digest {
            // The earlier attempt may or may not have reached the server: look for it by name before creating a second one.
            if let existing = try await api.intents().first(where: { [.open, .funded, .provisioning].contains($0.status) && $0.workspace_name.lowercased() == name.lowercased() }) {
                adopt(existing); return
            }
            d.createKey = makeKey()
        }
        d.createDigest = digest
        state.draft = d; save()
        // Account before workspace: idempotent, opens the owner account with no promotional credit.
        state.account = try await api.openAccount()
        do {
            adopt(try await api.createIntent(OnboardingCreateRequest(clientRequestKey: d.createKey, invite: invite, workspaceName: name,
                                                                      fundingCents: d.fundingCents, agentOfferId: d.agentOfferId, agentDailyCapCents: cap)))
        } catch let f as OnboardingFailure where f.kind == .nameTaken {
            // Possibly our own earlier create whose answer was lost: adopt it rather than failing.
            guard let existing = try await api.intents().first(where: { [.open, .funded, .provisioning].contains($0.status) && $0.workspace_name.lowercased() == name.lowercased() }) else { throw f }
            adopt(existing)
        }
    }

    private func pushOptions(_ intent: OnboardingIntent, name: String) async throws {
        let d = state.draft
        var update = OnboardingOptionsUpdate(expectedRevision: intent.revision)
        var changed = false
        if name != intent.workspace_name { update.workspaceName = name; changed = true }
        if d.fundingCents != intent.funding_cents {
            if intent.status != .open || d.checkoutOrderId != nil { throw OnboardingFailure(kind: .notEditable, code: "funding_locked") }
            update.fundingCents = d.fundingCents; changed = true
        }
        if d.agentOfferId != intent.agent?.id || (d.agentOfferId != nil && d.agentDailyCapCents != nil && d.agentDailyCapCents != intent.agent?.daily_cap_cents) {
            update.agentOfferId = .some(d.agentOfferId)
            if d.agentOfferId != nil { update.agentDailyCapCents = d.agentDailyCapCents }
            changed = true
        }
        guard changed else { return }
        do { adopt(try await api.updateIntent(intent.id, update)) }
        catch let f as OnboardingFailure where f.kind == .staleRevision {
            // Someone else moved the revision. Take the server's latest and make the user look again.
            adopt(try await api.intent(intent.id))
            state.draft.reviewedDigest = nil; save()
            throw f
        }
    }

    private func requestCheckout(_ intent: OnboardingIntent) async throws {
        guard intent.status == .open else { throw OnboardingFailure(kind: .notEditable, code: "intent_not_open") }
        guard let returnURL else { throw OnboardingFailure(kind: .paymentUnavailable, code: "no_return_url") }
        guard state.draft.reviewedDigest == Self.intentDigest(intent) else { throw OnboardingFailure(kind: .validation, code: "review_required") }
        let checkout = try await api.checkout(intent.id, idempotencyKey: state.draft.checkoutKey, returnURL: returnURL)
        guard checkout.mode == "test", checkout.amount_cents == intent.funding_cents, let url = Self.safeCheckoutURL(checkout.checkout_url) else {
            throw OnboardingFailure(kind: .paymentUnavailable, code: "unexpected_checkout")
        }
        state.draft.checkoutOrderId = checkout.order_id; save()
        state.checkoutURL = url
    }

    /// Stripe-hosted https only; never a link the Tower (or a man in the middle) could use to send the user elsewhere.
    static func safeCheckoutURL(_ text: String) -> URL? {
        guard let c = URLComponents(string: text), c.scheme == "https", c.user == nil, c.password == nil, let host = c.host?.lowercased(),
              host == "stripe.com" || host.hasSuffix(".stripe.com"), let url = c.url else { return nil }
        return url
    }

    static func intentDigest(_ i: OnboardingIntent) -> String {
        OnboardingDraft.digest(name: i.workspace_name, fundingCents: i.funding_cents, agentOfferId: i.agent?.id, agentDailyCapCents: i.agent?.daily_cap_cents)
    }

    // MARK: Payment return and refresh

    /// A return to the app. The address only decides whether the app bothers to ask: anything that is not the configured
    /// return address is ignored, and even the real one funds nothing. Funding is read from the server.
    @discardableResult public func paymentReturned(_ url: URL?) async -> OnboardingSnapshot {
        guard let url, let expected = returnURL, Self.sameAddress(url, expected) else {
            state.notice = "Ignored a payment return that did not match this app's approved address."
            return settle()
        }
        state.notice = nil
        return await refresh()
    }

    static func sameAddress(_ a: URL, _ b: URL) -> Bool {
        guard let x = URLComponents(url: a, resolvingAgainstBaseURL: false), let y = URLComponents(url: b, resolvingAgainstBaseURL: false) else { return false }
        return x.scheme == y.scheme && x.host?.lowercased() == y.host?.lowercased() && x.port == y.port && x.path == y.path && x.user == nil && x.password == nil
    }

    /// Re-reads the intent from the server (foreground, return from payment, relaunch).
    @discardableResult public func refresh() async -> OnboardingSnapshot {
        await coalesced("refresh") { await $0.doRefresh() }
    }

    private func doRefresh() async -> OnboardingSnapshot {
        guard await signerMatches() else { return fail(.unavailable(.signerMismatch), nil) }
        guard let id = state.draft.intentId else { return settle() }
        do { adopt(try await api.intent(id)) } catch { return failed(error) }
        return settle()
    }

    // MARK: Provision, cancel, finish

    /// Only after the server reports verified funding. Repeating it (double tap, relaunch, after a failed step) is safe: the
    /// server runs each step once, and concurrent calls here share one request.
    @discardableResult public func provision() async -> OnboardingSnapshot {
        await coalesced("provision") { await $0.doProvision() }
    }

    private func doProvision() async -> OnboardingSnapshot {
        state.failure = nil
        guard await signerMatches() else { return fail(.unavailable(.signerMismatch), nil) }
        guard let id = state.draft.intentId else { return settle(OnboardingFailure(kind: .fundingRequired)) }
        // The local view may be stale after a relaunch: confirm funding from the server before asking it to build anything.
        do { adopt(try await api.intent(id)) } catch { return failed(error) }
        guard let intent = state.intent, intent.fundingConfirmed else { return settle(OnboardingFailure(kind: .fundingRequired)) }
        if intent.status == .provisioned { return settle() }
        do { adopt(try await api.provision(id)) }
        catch {
            if let latest = try? await api.intent(id) { adopt(latest) }
            return failed(error)
        }
        return settle()
    }

    @discardableResult public func cancelSetup() async -> OnboardingSnapshot {
        await coalesced("cancel") { await $0.doCancel() }
    }

    private func doCancel() async -> OnboardingSnapshot {
        state.failure = nil
        guard let id = state.draft.intentId else { return settle() }
        do { adopt(try await api.cancel(id)) } catch { return failed(error) }
        return settle()
    }

    /// The user has seen the result: forget the local draft (the server keeps the record).
    public func finish() -> OnboardingSnapshot {
        store.clear(origin: state.draft.origin, signerNpub: signerNpub)
        state.draft = OnboardingDraft(origin: state.draft.origin, signerNpub: signerNpub, createKey: makeKey(), checkoutKey: makeKey())
        state.intent = nil; state.checkoutURL = nil
        return settle()
    }

    // MARK: Internals

    private func signerMatches() async -> Bool {
        guard let hex = try? await signer.publicKeyHex(), NostrKeys.npub(publicKeyHex: hex) == signerNpub else { return false }
        return true
    }

    /// Same operation requested twice runs once; both callers get that result.
    private func coalesced(_ name: String, _ work: @escaping @Sendable (OnboardingController) async -> OnboardingSnapshot) async -> OnboardingSnapshot {
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

    private func adopt(_ intent: OnboardingIntent) {
        state.intent = intent
        var d = state.draft
        if intent.status == .cancelled {
            d.intentId = nil; d.intentRevision = nil; d.checkoutOrderId = nil; d.reviewedDigest = nil
            d.createKey = makeKey(); d.createDigest = nil; d.checkoutKey = makeKey()
            state.intent = intent
        } else {
            d.intentId = intent.id; d.intentRevision = intent.revision
            d.invite = nil                      // the server holds the claim now; the secret is no longer needed on this device
            d.workspaceName = intent.workspace_name; d.fundingCents = intent.funding_cents
            d.agentOfferId = intent.agent?.id; d.agentDailyCapCents = intent.agent?.daily_cap_cents
            // A review survives only if the server's choices are exactly the reviewed ones.
            if d.reviewedDigest != d.formDigest { d.reviewedDigest = nil }
        }
        state.draft = d; save()
    }

    private func dropIntent(note: String) {
        var d = state.draft
        d.intentId = nil; d.intentRevision = nil; d.checkoutOrderId = nil; d.reviewedDigest = nil
        d.createKey = makeKey(); d.createDigest = nil; d.checkoutKey = makeKey()
        state.draft = d; state.intent = nil; state.notice = note; save()
    }

    private func save() { try? store.save(state.draft) }

    private func fail(_ phase: OnboardingPhase, _ failure: OnboardingFailure?) -> OnboardingSnapshot {
        state.phase = phase; state.failure = failure; return state
    }

    private func failed(_ error: Error) -> OnboardingSnapshot {
        let failure = (error as? OnboardingFailure) ?? OnboardingFailure(kind: (error is TowerError) ? .malformed : .network)
        return settle(failure)
    }

    /// Derives phase, payment options and landing from the draft and the server's intent, recording any failure.
    private func settle(_ failure: OnboardingFailure? = nil) -> OnboardingSnapshot {
        if let failure { state.failure = failure }
        var blocked = false
        if let f = state.failure {
            switch f.kind {
            case .backendMissing: state.phase = .unavailable(.backendMissing); return finalize()
            case .rolloutDisabled: state.phase = .unavailable(.rolloutDisabled); return finalize()
            case .signerRefused: state.phase = .unavailable(.signerRefused); return finalize()
            case .paymentUnavailable: blocked = true
            default: break
            }
        }
        state.paymentOptions = Self.options(returnURL: returnURL, paymentBlocked: blocked)
        let d = state.draft
        if let intent = state.intent {
            switch intent.status {
            case .cancelled: state.phase = .cancelled
            case .provisioned: state.phase = .provisioned
            case .provisioning: state.phase = .provisioning
            case .funded: state.phase = intent.fundingConfirmed ? .readyToProvision : .awaitingPayment
            case .open: state.phase = (d.checkoutOrderId != nil || state.checkoutURL != nil) ? .awaitingPayment : (d.reviewedDigest == d.formDigest ? .review : .form)
            }
        } else {
            state.phase = d.reviewedDigest != nil && d.reviewedDigest == d.formDigest ? .review : .form
        }
        return finalize()
    }

    private func finalize() -> OnboardingSnapshot {
        if let i = state.intent, i.status == .provisioned {
            state.landing = OnboardingLanding(workspaceId: i.workspace_id, generalReady: i.hasGeneral, agentName: i.agent?.template, agentRunning: i.hasAgentDM)
        } else { state.landing = nil }
        return state
    }
}
