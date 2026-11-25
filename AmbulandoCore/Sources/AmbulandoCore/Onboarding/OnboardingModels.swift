import Foundation

/// Wire types of NStack `/api/v4/onboarding` (tower docs/contract/onboarding-v1.md, src/services/onboarding.ts).
/// Decoding is tolerant of added fields; money is carried in integer US cents exactly as the server holds it.

public struct OnboardingAccount: Sendable, Equatable, Decodable {
    public let account_id: String
    public let currency: String
    public let balance_usd: String
    public let paid_usd: String
    public let promo_usd: String
    public let created_at: String
}

public struct OnboardingAgentOffer: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let template: String
    public let model_ref: String
    public let rate_version: String
    public let default_daily_cap_cents: Int
    public let max_daily_cap_cents: Int
}

public struct OnboardingSelectedAgent: Sendable, Equatable, Decodable {
    public let id: String
    public let template: String
    public let model_ref: String
    public let rate_version: String
    public let default_daily_cap_cents: Int
    public let max_daily_cap_cents: Int
    public let daily_cap_cents: Int
}

public enum OnboardingAgentState: String, Sendable, Equatable, Decodable {
    case none, selected_not_provisioned, provisioned
}

public enum OnboardingIntentStatus: String, Sendable, Equatable, Decodable {
    case open, funded, provisioning, provisioned, cancelled
}

/// The owner-only `payment_attempt` hint on an intent (tower docs/contract/onboarding-v1.md, "One canonical payment attempt per intent").
/// Ids and quote state only: it holds no replay key, session secret or provider credential.
public struct PaymentAttempt: Sendable, Equatable, Decodable {
    public let method: String?
    public let state: String
    public let resume: String
    public let orderId: String?
    public let quoteId: String?
    public let amountCents: Int?
    public let createdAt: String?
    public let quote: LightningQuote?
    public let count: Int

    private enum CodingKeys: String, CodingKey { case method, state, resume, order_id, quote_id, amount_cents, created_at, quote, count }
    /// Every documented field must be present (null where the contract allows it); a missing or mistyped one makes the whole hint unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decode(String?.self, forKey: .method); state = try c.decode(String.self, forKey: .state)
        resume = try c.decode(String.self, forKey: .resume); orderId = try c.decode(String?.self, forKey: .order_id)
        quoteId = try c.decode(String?.self, forKey: .quote_id); amountCents = try c.decode(Int?.self, forKey: .amount_cents)
        createdAt = try c.decode(String?.self, forKey: .created_at); quote = try c.decode(LightningQuote?.self, forKey: .quote)
        count = try c.decode(Int.self, forKey: .count)
    }
}

/// What an intent read said about payment attempts. A missing field (an older NStack) is not the same as an explicit null, and neither
/// ordinary read may free a local payment: only an explicit release does.
public enum PaymentAttemptReport: Sendable, Equatable {
    case notReported
    case none
    case attempt(PaymentAttempt)
    /// Present but not in the documented shape: treated as an attempt that cannot be verified.
    case unreadable
}

public struct OnboardingIntent: Sendable, Equatable, Identifiable, Decodable {
    public struct Step: Sendable, Equatable, Decodable { public let completed_at: String }
    public let version: Int
    public let id: String
    public let account_id: String
    public let status: OnboardingIntentStatus
    public let revision: Int
    public let workspace_name: String
    public let agent: OnboardingSelectedAgent?
    public let agent_state: OnboardingAgentState
    public let funding_cents: Int
    public let return_state: String?
    public let funded: Bool
    public let funded_at: String?
    public let funding_reversed: Bool
    public let steps: [String: Step]
    public let last_error: String?
    public let workspace_id: String?
    public let provisioned_at: String?
    public let intro_ends_at: String?
    public let created_at: String
    public let updated_at: String
    public let paymentAttempt: PaymentAttemptReport

    private enum CodingKeys: String, CodingKey {
        case version, id, account_id, status, revision, workspace_name, agent, agent_state, funding_cents, return_state, funded, funded_at
        case funding_reversed, steps, last_error, workspace_id, provisioned_at, intro_ends_at, created_at, updated_at, payment_attempt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version); id = try c.decode(String.self, forKey: .id)
        account_id = try c.decode(String.self, forKey: .account_id); status = try c.decode(OnboardingIntentStatus.self, forKey: .status)
        revision = try c.decode(Int.self, forKey: .revision); workspace_name = try c.decode(String.self, forKey: .workspace_name)
        agent = try c.decodeIfPresent(OnboardingSelectedAgent.self, forKey: .agent)
        agent_state = try c.decode(OnboardingAgentState.self, forKey: .agent_state)
        funding_cents = try c.decode(Int.self, forKey: .funding_cents); return_state = try c.decodeIfPresent(String.self, forKey: .return_state)
        funded = try c.decode(Bool.self, forKey: .funded); funded_at = try c.decodeIfPresent(String.self, forKey: .funded_at)
        funding_reversed = try c.decode(Bool.self, forKey: .funding_reversed); steps = try c.decode([String: Step].self, forKey: .steps)
        last_error = try c.decodeIfPresent(String.self, forKey: .last_error); workspace_id = try c.decodeIfPresent(String.self, forKey: .workspace_id)
        provisioned_at = try c.decodeIfPresent(String.self, forKey: .provisioned_at); intro_ends_at = try c.decodeIfPresent(String.self, forKey: .intro_ends_at)
        created_at = try c.decode(String.self, forKey: .created_at); updated_at = try c.decode(String.self, forKey: .updated_at)
        if !c.contains(.payment_attempt) { paymentAttempt = .notReported }
        else if try c.decodeNil(forKey: .payment_attempt) { paymentAttempt = .none }
        else if let parsed = try? c.decode(PaymentAttempt.self, forKey: .payment_attempt) { paymentAttempt = .attempt(parsed) }
        else { paymentAttempt = .unreadable }
    }

    /// Money has moved and been verified by the server (not a redirect, not a client flag) and has not since been reversed.
    public var fundingConfirmed: Bool {
        funded && !funding_reversed && [.funded, .provisioning, .provisioned].contains(status)
    }
    /// Backend evidence only: the intent's own recorded steps. Nothing is inferred from the agent being selected.
    public var hasGeneral: Bool { steps["general"] != nil }
    public var hasAgentDM: Bool { agent_state == .provisioned || steps["agent"] != nil }
}

public struct OnboardingCheckout: Sendable, Equatable, Decodable {
    public let order_id: String
    public let checkout_url: String
    public let mode: String
    public let amount_cents: Int
    /// Present (true) when NStack returned the intent's existing canonical order for a fresh key instead of creating one.
    public let reused: Bool?
}

/// Funding choices: US$21 is the server minimum; presets 21 / 50 / 100 or a custom amount of at least US$21.
public enum OnboardingFunding {
    public static let minimumCents = 2100
    public static let maximumCents = 1_000_000
    public static let presetsCents = [2100, 5000, 10000]

    public static func valid(_ cents: Int) -> Bool { (minimumCents...maximumCents).contains(cents) }

    /// Exact conversion of "21", "21.5" or "21.50" to cents. Anything else (signs, separators, more than two decimals) is refused.
    public static func cents(fromDollars text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^[0-9]{1,5}(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let whole = Int(parts[0])!
        var fraction = parts.count == 2 ? String(parts[1]) : "0"
        if fraction.count == 1 { fraction += "0" }
        let cents = whole * 100 + Int(fraction)!
        return valid(cents) ? cents : nil
    }

    public static func label(cents: Int) -> String {
        cents % 100 == 0 ? "US$\(cents / 100)" : String(format: "US$%d.%02d", cents / 100, cents % 100)
    }
}

public enum OnboardingName {
    /// The server requires a name that equals its own trim and is 1...80 characters.
    public static func normalized(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...80).contains(name.count) ? name : nil
    }
}
