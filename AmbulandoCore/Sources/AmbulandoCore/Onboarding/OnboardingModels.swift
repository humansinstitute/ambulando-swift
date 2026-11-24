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
