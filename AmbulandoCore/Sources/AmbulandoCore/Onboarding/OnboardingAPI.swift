import Foundation

/// A classified onboarding failure. Messages never include request bodies, invite codes or response text.
public struct OnboardingFailure: Error, Equatable, Sendable, LocalizedError {
    public enum Kind: Equatable, Sendable {
        case backendMissing, rolloutDisabled, paymentUnavailable, signerRefused
        case inviteFull, inviteInvalid, nameTaken, agentUnavailable, tooManyIntents
        case staleRevision, idempotencyConflict, notFound
        case fundingRequired, fundingReversed, checkoutOutstanding, notEditable
        case validation, provisioningFailed, server, network, malformed, persistence
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
        case (_, "invite_full"): kind = .inviteFull
        case (_, "invite_not_found"), (_, "invite_revoked"): kind = .inviteInvalid
        case (_, "workspace_name_taken"): kind = .nameTaken
        case (_, "agent_offer_unavailable"): kind = .agentUnavailable
        case (_, "too_many_open_intents"): kind = .tooManyIntents
        case (_, "stale_revision"): kind = .staleRevision
        case (_, "idempotency_conflict"): kind = .idempotencyConflict
        case (_, "intent_not_found"): kind = .notFound
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

    public func account() async throws -> OnboardingAccount? {
        let data = try await send("GET", Self.base + "/account")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OnboardingFailure(kind: .malformed) }
        if object["account"] is NSNull || object["account"] == nil { return nil }
        return try decode(OnboardingAccount.self, data, key: "account")
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
}
