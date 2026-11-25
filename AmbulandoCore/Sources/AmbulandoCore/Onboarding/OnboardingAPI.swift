import Foundation

/// A classified onboarding failure. Messages never include request bodies, invite codes or response text.
public struct OnboardingFailure: Error, Equatable, Sendable, LocalizedError {
    public enum Kind: Equatable, Sendable {
        case backendMissing, rolloutDisabled, paymentUnavailable, signerRefused
        case inviteFull, inviteInvalid, nameTaken, agentUnavailable, tooManyIntents
        case staleRevision, idempotencyConflict, notFound
        case fundingRequired, fundingReversed, checkoutOutstanding, notEditable
        case validation, provisioningFailed, server, network, malformed, persistence
        /// A newly created identity has not completed its required backups; nothing was sent.
        case backupRequired, hostedBackupRequired
        /// Funding for this setup or top-up was already started with another method (or another amount); nothing new was sent.
        case paymentMethodLocked
        /// Repeat top-ups need a provisioned account.
        case accountNotProvisioned
        case tooManyOpenQuotes
        /// NStack holds more than one, or an unverifiable, payment for this setup; both payment methods stay closed until support resolves it.
        case paymentNeedsSupport
        /// This NStack has no way to close a payment from the app; the payment and its keys stay as they were.
        case releaseUnavailable
    }
    public let kind: Kind
    public let status: Int?
    public let code: String?

    /// Failures that leave the durable draft exactly as it was and are safe to repeat with the same operation key.
    public var retryable: Bool { [.network, .server, .provisioningFailed].contains(kind) }

    public init(kind: Kind, status: Int? = nil, code: String? = nil) { self.kind = kind; self.status = status; self.code = code }

    static func classify(status: Int, code: String?) -> OnboardingFailure {
        let kind: Kind
        switch (status, code) {
        case (404, nil), (405, _): kind = .backendMissing
        case (_, "onboarding_rollout_disabled"): kind = .rolloutDisabled
        case (_, "stripe_unconfigured"), (_, "stripe_live_rollout_blocked"), (_, "lightning_unavailable"),
             (_, "return_url_not_allowed"), (_, "invalid_return_url"): kind = .paymentUnavailable
        case (401, _), (403, _): kind = .signerRefused
        case (_, "identity_backup_required"): kind = .hostedBackupRequired
        case (_, "invite_full"): kind = .inviteFull
        case (_, "invite_not_found"), (_, "invite_revoked"): kind = .inviteInvalid
        case (_, "workspace_name_taken"): kind = .nameTaken
        case (_, "agent_offer_unavailable"): kind = .agentUnavailable
        case (_, "too_many_open_intents"): kind = .tooManyIntents
        case (_, "stale_revision"): kind = .staleRevision
        case (_, "idempotency_conflict"): kind = .idempotencyConflict
        case (_, "payment_attempt_outstanding"): kind = .paymentMethodLocked
        case (_, "payment_attempt_ambiguous"): kind = .paymentNeedsSupport
        case (_, "intent_amount_changed"): kind = .staleRevision
        case (_, "intent_not_found"), (_, "quote_not_found"): kind = .notFound
        case (_, "account_not_found"), (_, "account_not_provisioned"): kind = .accountNotProvisioned
        case (429, _), (_, "too_many_open_topup_quotes"): kind = .tooManyOpenQuotes
        case (_, "invalid_quote_request"), (_, "invalid_checkout"): kind = .validation
        case (_, "funding_required"): kind = .fundingRequired
        case (_, "funding_reversed"): kind = .fundingReversed
        case (_, "checkout_outstanding"): kind = .checkoutOutstanding
        case (_, "intent_not_editable"), (_, "funding_locked"), (_, "intent_not_open"), (_, "intent_not_cancellable"), (_, "intent_cancelled"): kind = .notEditable
        case (400, _): kind = .validation
        case (_, "provisioning_step_failed"): kind = .provisioningFailed
        default: kind = .server
        }
        return OnboardingFailure(kind: kind, status: status, code: code)
    }

    public var errorDescription: String? {
        switch kind {
        case .backendMissing: "This NStack does not offer invited onboarding."
        case .rolloutDisabled: "Invited onboarding is currently unavailable on this NStack. Your progress is kept; check the status again later."
        case .paymentUnavailable: "This payment method is currently unavailable. Your progress is kept; check the status again later before paying again."
        case .signerRefused: "This NStack did not accept the signed request. Check the unlocked identity."
        case .inviteFull: "This invitation has no places left."
        case .inviteInvalid: "This invitation is not valid or has been withdrawn."
        case .nameTaken: "You already have a workspace or pending setup with that name."
        case .agentUnavailable: "That agent is no longer on offer. Choose again."
        case .tooManyIntents: "You have too many unfinished setups. Cancel one first."
        case .staleRevision: "This setup changed elsewhere. The latest version has been loaded; review it and choose again."
        case .idempotencyConflict: "That request was already used with different details."
        case .notFound: "This setup was not found for the unlocked identity."
        case .fundingRequired: "Payment has not been confirmed by the server yet."
        case .fundingReversed: "The payment was refunded or reversed, so setup cannot continue."
        case .checkoutOutstanding: "A payment is still open. It has to finish or expire first."
        case .notEditable: "This setup can no longer be changed."
        case .validation: "NStack rejected these details\(code.map { " (\(TowerClient.summary($0)))" } ?? "")."
        case .provisioningFailed: "Workspace setup stopped part-way. Your payment and finished steps are kept; try again."
        case .server: "NStack had a problem (HTTP \(status ?? 0)). Try again shortly."
        case .network: "Could not reach the NStack. Your progress is saved; try again."
        case .malformed: "NStack sent an unexpected answer."
        case .backupRequired: "Save and confirm an encrypted backup of your new identity first (Settings > Identity backup)."
        case .hostedBackupRequired: HostedBackup.requirementNotice
        case .paymentMethodLocked: "A payment is already open for this. Finish it, or wait until the NStack confirms it closed, before choosing another way to pay."
        case .accountNotProvisioned: "Top-ups open once your first workspace has been created on this NStack."
        case .paymentNeedsSupport: "NStack could not confirm a single payment for this setup. Do not pay again; your setup is saved. Check again later or contact NStack support."
        case .releaseUnavailable: "This NStack cannot close a payment from the app. The payment is kept; let it finish or expire, then check the status."
        case .tooManyOpenQuotes: "There are too many unpaid Lightning invoices open. Let them expire or finish them first, then try again."
        case .persistence: "This device could not save your setup progress, so no new step was started. Free some space, then check the status and try again."
        }
    }
}

public struct OnboardingCreateRequest: Sendable, Equatable {
    public var clientRequestKey: String
    public var invite: OnboardingInviteCode
    public var workspaceName: String
    public var fundingCents: Int
    public var agentOfferId: String?
    public var agentDailyCapCents: Int?
    /// `"new"` for an identity created in this app (the server then withholds payment until a hosted backup exists); omitted otherwise,
    /// which the server reads as `existing`. A client-declared guardrail, not proof of origin.
    public var identityOrigin: String?
}

/// Options update; `nil` fields are left out of the body so the server keeps them.
public struct OnboardingOptionsUpdate: Sendable, Equatable {
    public var expectedRevision: Int
    public var workspaceName: String?
    public var fundingCents: Int?
    /// `.some(nil)` clears the agent; `nil` leaves it untouched.
    public var agentOfferId: String??
    public var agentDailyCapCents: Int?
}

/// Signed client for `/api/v4/onboarding`. Every mutation carries a JSON body (at least `{}`), because the server's strict
/// NIP-98 check requires a payload hash even for bodiless actions. Reads send none. The invitation code appears only in the
/// create-intent body, never in a path or query (the public `GET /invites/{code}` is deliberately not used for that reason).
public struct OnboardingDeploymentConfig: Decodable, Sendable {
    public struct Card: Decodable, Sendable {
        public let available: Bool
        public let mode: String?
        public let return_urls: [String]
    }
    public struct Funding: Decodable, Sendable {
        public let min_cents: Int?
        public let max_cents: Int?
        public let topup_min_cents: Int?
        public let topup_max_cents: Int?
    }
    public struct Lightning: Decodable, Sendable { public let available: Bool }
    public let version: Int
    public let onboarding_enabled: Bool
    public let card: Card
    public let funding: Funding?
    public let lightning: Lightning?

    /// Card checkout is offered only for an enabled onboarding, available card, test mode and a safe server-approved return address.
    var approvedCardReturn: URL? {
        onboarding_enabled && card.available && card.mode == "test"
            ? card.return_urls.compactMap { URL(string: $0).flatMap(OnboardingController.approvedReturn) }.first : nil
    }
    var lightningOffered: Bool { onboarding_enabled && lightning?.available == true }
    var topupLimits: TopupLimits {
        guard let lo = funding?.topup_min_cents, let hi = funding?.topup_max_cents, lo >= 1, hi >= lo else { return .documented }
        return TopupLimits(minCents: lo, maxCents: hi)
    }
}

public struct OnboardingAPI: Sendable {
    public static let base = "/api/v4/onboarding"
    let client: TowerClient
    public var origin: TowerOrigin { client.origin }

    public init(client: TowerClient) { self.client = client }

    static func intentPath(_ id: String, _ suffix: String = "") throws -> String {
        guard UUID(uuidString: id) != nil, id == id.lowercased() else { throw TowerError.unsafePath }
        return "\(base)/intents/\(id)\(suffix)"
    }

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        let payload: Data?
        if method == "GET" { payload = nil } else { payload = try JSONSerialization.data(withJSONObject: body ?? [:], options: [.sortedKeys]) }
        let status: Int, data: Data
        do { (status, data) = try await client.exchange(method: method, path: path, appNpub: nil, jsonBody: payload) }
        catch is CancellationError { throw CancellationError() }
        catch let error as IdentityError { throw error }
        catch let error as TowerError { throw error }
        catch { throw OnboardingFailure(kind: .network) }
        guard (200..<300).contains(status) else {
            let failure = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw OnboardingFailure.classify(status: status, code: failure?["code"] as? String)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, key: String? = nil) throws -> T {
        do {
            if let key {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object[key] else { throw OnboardingFailure(kind: .malformed) }
                return try JSONDecoder().decode(T.self, from: try JSONSerialization.data(withJSONObject: value))
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let failure as OnboardingFailure { throw failure } catch { throw OnboardingFailure(kind: .malformed) }
    }

    /// The account plus the server's reversal-debt and lifecycle projections from the same read. Missing blocks stay `nil`.
    public func accountOverview() async throws -> OnboardingAccountOverview {
        let data = try await send("GET", Self.base + "/account")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OnboardingFailure(kind: .malformed) }
        func block<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            guard let value = object[key], !(value is NSNull), let raw = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode(T.self, from: raw)
        }
        let account: OnboardingAccount? = (object["account"] is NSNull || object["account"] == nil) ? nil : try decode(OnboardingAccount.self, data, key: "account")
        return OnboardingAccountOverview(account: account, funding: block("funding", FundingReversalSummary.self), lifecycle: block("lifecycle", AccountLifecycle.self))
    }
    public func account() async throws -> OnboardingAccount? {
        let data = try await send("GET", Self.base + "/account")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OnboardingFailure(kind: .malformed) }
        if object["account"] is NSNull || object["account"] == nil { return nil }
        return try decode(OnboardingAccount.self, data, key: "account")
    }
    /// Older deployments may lack this read. Their explicitly configured build return URL remains subject to server validation.
    public func deploymentConfig() async throws -> OnboardingDeploymentConfig? {
        let result: (status: Int, body: Data)
        do { result = try await client.exchange(method: "GET", path: Self.base + "/config", appNpub: nil, jsonBody: nil) }
        catch is CancellationError { throw CancellationError() }
        catch let error as IdentityError { throw error }
        catch { throw OnboardingFailure(kind: .network) }
        if result.status == 404 { return nil }
        guard result.status == 200 else { throw OnboardingFailure(kind: .paymentUnavailable, status: result.status) }
        let config = try decode(OnboardingDeploymentConfig.self, result.body)
        guard config.version == 1 else { throw OnboardingFailure(kind: .malformed) }
        return config
    }
    /// Idempotent. Opens the owner account with no welcome or promotional credit.
    public func openAccount() async throws -> OnboardingAccount {
        try decode(OnboardingAccount.self, try await send("POST", Self.base + "/account"), key: "account")
    }
    public func agentOffers() async throws -> [OnboardingAgentOffer] {
        try decode([OnboardingAgentOffer].self, try await send("GET", Self.base + "/agent-offers"), key: "offers")
    }
    public func intents() async throws -> [OnboardingIntent] {
        try decode([OnboardingIntent].self, try await send("GET", Self.base + "/intents"), key: "intents")
    }
    public func intent(_ id: String) async throws -> OnboardingIntent {
        try decode(OnboardingIntent.self, try await send("GET", try Self.intentPath(id)), key: "intent")
    }
    /// 201 on first creation, 200 on replay of the same key and body.
    public func createIntent(_ request: OnboardingCreateRequest) async throws -> OnboardingIntent {
        var body: [String: Any] = ["client_request_key": request.clientRequestKey, "invite_code": request.invite.rawValue,
                                   "workspace_name": request.workspaceName, "funding_cents": request.fundingCents]
        if let offer = request.agentOfferId { body["agent_offer_id"] = offer }
        if let cap = request.agentDailyCapCents { body["agent_daily_cap_cents"] = cap }
        if let origin = request.identityOrigin { body["identity_origin"] = origin }
        return try decode(OnboardingIntent.self, try await send("POST", Self.base + "/intents", body: body), key: "intent")
    }
    public func updateIntent(_ id: String, _ update: OnboardingOptionsUpdate) async throws -> OnboardingIntent {
        var body: [String: Any] = ["expected_revision": update.expectedRevision]
        if let name = update.workspaceName { body["workspace_name"] = name }
        if let funding = update.fundingCents { body["funding_cents"] = funding }
        if let offer = update.agentOfferId { body["agent_offer_id"] = offer ?? NSNull() }
        if let cap = update.agentDailyCapCents { body["agent_daily_cap_cents"] = cap }
        return try decode(OnboardingIntent.self, try await send("POST", try Self.intentPath(id, "/options"), body: body), key: "intent")
    }
    public func cancel(_ id: String) async throws -> OnboardingIntent {
        try decode(OnboardingIntent.self, try await send("POST", try Self.intentPath(id, "/cancel")), key: "intent")
    }
    /// The amount is always the intent's server-held figure. `returnURL` must be an exact member of the server's allowlist.
    public func checkout(_ id: String, idempotencyKey: String, returnURL: URL) async throws -> OnboardingCheckout {
        try decode(OnboardingCheckout.self, try await send("POST", try Self.intentPath(id, "/checkout"),
                                                           body: ["idempotency_key": idempotencyKey, "return_url": returnURL.absoluteString]))
    }
    public func provision(_ id: String) async throws -> OnboardingIntent {
        try decode(OnboardingIntent.self, try await send("POST", try Self.intentPath(id, "/provision")), key: "intent")
    }

    // MARK: Lightning (intent funding)

    static func quotePath(_ intentId: String, _ quoteId: String) throws -> String {
        guard UUID(uuidString: quoteId) != nil, quoteId == quoteId.lowercased() else { throw TowerError.unsafePath }
        return try intentPath(intentId, "/lightning/quotes/\(quoteId)/refresh")
    }
    /// The USD amount is the intent's server-held funding; the body carries only the operation key. A replay of the same key returns the same quote.
    public func lightningQuote(_ intentId: String, idempotencyKey: String) async throws -> LightningQuote {
        try await lightningQuoteResult(intentId, idempotencyKey: idempotencyKey).quote
    }
    /// `reused` is true when NStack returned the intent's existing canonical quote for a key it had not seen (another device or a lost key).
    public func lightningQuoteResult(_ intentId: String, idempotencyKey: String) async throws -> (quote: LightningQuote, reused: Bool) {
        let data = try await send("POST", try Self.intentPath(intentId, "/lightning/quote"), body: ["idempotency_key": idempotencyKey])
        let reused = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["reused"] as? Bool ?? false
        return (try decode(LightningQuote.self, data, key: "quote"), reused)
    }
    /// Asks NStack to settle or expire/cancel the intent's outstanding payment at the provider. The returned intent's hint stays present when
    /// that could not be verified; nothing is cleared client-side from this call alone.
    public func releasePaymentAttempt(_ id: String) async throws -> OnboardingIntent {
        try decode(OnboardingIntent.self, try await send("POST", try Self.intentPath(id, "/payment-attempt/release")), key: "intent")
    }
    /// The server re-polls its provider; this client supplies no settlement evidence.
    public func refreshLightningQuote(_ intentId: String, quoteId: String) async throws -> (quote: LightningQuote, intent: OnboardingIntent) {
        let data = try await send("POST", try Self.quotePath(intentId, quoteId))
        return (try decode(LightningQuote.self, data, key: "quote"), try decode(OnboardingIntent.self, data, key: "intent"))
    }

    // MARK: Repeat account top-ups

    public func topups() async throws -> TopupList { try decode(TopupList.self, try await send("GET", Self.base + "/topups")) }
    public func topupCheckout(idempotencyKey: String, returnURL: URL, amountCents: Int) async throws -> OnboardingCheckout {
        try decode(OnboardingCheckout.self, try await send("POST", Self.base + "/topups/checkout",
                                                           body: ["idempotency_key": idempotencyKey, "return_url": returnURL.absoluteString, "amount_cents": amountCents]))
    }
    public func topupQuote(idempotencyKey: String, amountCents: Int) async throws -> LightningQuote {
        try decode(LightningQuote.self, try await send("POST", Self.base + "/topups/lightning/quote",
                                                       body: ["idempotency_key": idempotencyKey, "amount_cents": amountCents]), key: "quote")
    }
    public func refreshTopupQuote(_ quoteId: String) async throws -> LightningQuote {
        guard UUID(uuidString: quoteId) != nil, quoteId == quoteId.lowercased() else { throw TowerError.unsafePath }
        return try decode(LightningQuote.self, try await send("POST", Self.base + "/topups/lightning/quotes/\(quoteId)/refresh"), key: "quote")
    }
}
