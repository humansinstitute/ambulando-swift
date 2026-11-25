import Foundation

/// Wire types for NStack's Lightning quotes and repeat account top-ups (tower src/services/hosting-lightning.ts `quoteView`,
/// src/services/hosting-topup.ts `listTopups`, src/services/hosting-funding.ts `fundingReversalSummary`,
/// src/services/hosting-lifecycle.ts `accountLifecycle`). Decoding tolerates added fields; money stays in integer US cents.

public enum LightningQuoteState: Equatable, Sendable {
    case issuing, open, settled, expired, cancelled, latePayment, mismatch
    case unknown(String)

    init(_ raw: String) {
        switch raw {
        case "issuing": self = .issuing
        case "open": self = .open
        case "settled": self = .settled
        case "expired": self = .expired
        case "cancelled": self = .cancelled
        case "late_payment": self = .latePayment
        case "mismatch": self = .mismatch
        default: self = .unknown(raw)
        }
    }
    /// The provider has verified that the invoice can no longer be paid, so a new quote cannot double-charge.
    public var verifiedClosedUnpaid: Bool { self == .expired || self == .cancelled }
    /// NStack recorded money or evidence it did not credit automatically. Only support can resolve it.
    public var needsSupport: Bool {
        switch self { case .latePayment, .mismatch, .unknown: true; default: false }
    }
}

public struct LightningQuote: Sendable, Equatable, Decodable {
    public struct Rate: Sendable, Equatable, Decodable { public let source: String; public let quoted_at: String }
    public let id: String
    public let intent_id: String?
    public let rawState: String
    public let amount_cents: Int
    public let amount_sats: Int?
    public let invoice: String?
    public let payment_hash: String?
    public let expires_at: String?
    public let rate: Rate?

    public var state: LightningQuoteState { LightningQuoteState(rawState) }
    public var expiry: Date? { expires_at.flatMap(NStackDate.parse) }

    private enum CodingKeys: String, CodingKey { case id, intent_id, state, amount_cents, amount_sats, invoice, payment_hash, expires_at, rate }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        intent_id = try c.decodeIfPresent(String.self, forKey: .intent_id)
        rawState = try c.decode(String.self, forKey: .state)
        amount_cents = try c.decode(Int.self, forKey: .amount_cents)
        amount_sats = try c.decodeIfPresent(Int.self, forKey: .amount_sats)
        invoice = try c.decodeIfPresent(String.self, forKey: .invoice)
        payment_hash = try c.decodeIfPresent(String.self, forKey: .payment_hash)
        expires_at = try c.decodeIfPresent(String.self, forKey: .expires_at)
        rate = try c.decodeIfPresent(Rate.self, forKey: .rate)
    }

    /// Payable details are shown only when the quote is internally consistent: an `open` quote carries an invoice, a payment hash, sats and an
    /// expiry, and the invoice's own amount (when it names one) equals the quoted sats. Anything else is refused rather than displayed.
    public var payable: Bool { state == .open && PayableInvoice(self) != nil }
}

/// A displayable, wallet-safe invoice. The amount in the BOLT11 human-readable part, when present, must equal the quoted sats.
public struct PayableInvoice: Sendable, Equatable {
    public let invoice: String
    public let sats: Int
    public let expiry: Date
    public var walletURL: URL { URL(string: "lightning:" + invoice.uppercased())! }

    init?(_ quote: LightningQuote) {
        guard quote.state == .open, let raw = quote.invoice, let sats = quote.amount_sats, sats >= 1, let expiry = quote.expiry,
              let hash = quote.payment_hash, hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let named = Self.satsNamed(by: raw) else { return nil }
        if let named, named != sats { return nil }
        invoice = raw.lowercased(); self.sats = sats; self.expiry = expiry
    }

    /// `.some(nil)` is a well-formed amountless invoice; `nil` is not an invoice we will show. Only the prefix is read (the wallet verifies the
    /// checksum and signature); this guards against a mismatch between the shown sats and what the wallet would pay.
    static func satsNamed(by text: String) -> Int?? {
        let invoice = text.lowercased()
        guard invoice.range(of: "^ln(bc|tb|bcrt|tbs)[0-9a-z]*1[02-9ac-hj-np-z]{20,}$", options: .regularExpression) != nil,
              invoice.count >= 20, invoice.count <= 4000,
              let separator = invoice.lastIndex(of: "1") else { return nil }
        let hrp = String(invoice[..<separator])
        guard let prefix = ["lnbcrt", "lntbs", "lnbc", "lntb"].first(where: hrp.hasPrefix) else { return nil }
        let amount = String(hrp.dropFirst(prefix.count))
        if amount.isEmpty { return .some(nil) }
        guard let last = amount.last else { return nil }
        let digits: Substring, multiplier: Character?
        if last.isNumber { digits = amount[...]; multiplier = nil } else { digits = amount.dropLast(); multiplier = last }
        guard !digits.isEmpty, digits.count <= 18, digits.first != "0", let value = Int(digits) else { return nil }
        // Millisatoshi per unit: BTC = 1e11 msat; m = 1e8, u = 1e5, n = 1e2, p = 0.1 (needs a multiple of 10).
        let msat: Int
        switch multiplier {
        case nil: let (v, o) = value.multipliedReportingOverflow(by: 100_000_000_000); if o { return nil }; msat = v
        case "m": let (v, o) = value.multipliedReportingOverflow(by: 100_000_000); if o { return nil }; msat = v
        case "u": let (v, o) = value.multipliedReportingOverflow(by: 100_000); if o { return nil }; msat = v
        case "n": let (v, o) = value.multipliedReportingOverflow(by: 100); if o { return nil }; msat = v
        case "p": guard value % 10 == 0 else { return nil }; msat = value / 10
        default: return nil
        }
        guard msat % 1000 == 0 else { return nil }
        return .some(msat / 1000)
    }
}

enum NStackDate {
    static func parse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}

// MARK: Account and top-ups

public struct FundingAdjustment: Sendable, Equatable, Decodable {
    public let kind: String
    public let state: String
    public let amount_cents: Int
    public let effective_cents: Int
}

/// `GET /account`'s `funding`: reversal (refund / dispute) debt and what is still in dispute. Units are NStack tariff units; they are shown as
/// "present or not", never converted client-side.
public struct FundingReversalSummary: Sendable, Equatable, Decodable {
    public let reversal_debt_units: String
    public let open_cents: Int
    public let adjustments: [FundingAdjustment]
    public var hasDebt: Bool { reversal_debt_units.range(of: "^0+$", options: .regularExpression) == nil && !reversal_debt_units.isEmpty }
}

public struct AccountLifecycle: Sendable, Equatable, Decodable {
    public struct ReadOnly: Sendable, Equatable, Decodable { public let ends_at: String; public let days_remaining: Int }
    public let state: String
    public let read_only: ReadOnly?
}

public struct OnboardingAccountOverview: Sendable, Equatable {
    public let account: OnboardingAccount?
    public let funding: FundingReversalSummary?
    public let lifecycle: AccountLifecycle?
}

public struct TopupCredit: Sendable, Equatable, Decodable, Identifiable {
    public let settlement_id: String
    public let method: String
    public let amount_cents: Int
    public let amount_usd: String
    public let settled_at: String?
    public var id: String { settlement_id }
}
public struct TopupPendingQuote: Sendable, Equatable, Decodable, Identifiable {
    public let quote_id: String
    public let state: String
    public let amount_cents: Int
    public let amount_sats: Int?
    public let invoice: String?
    public let payment_hash: String?
    public let expires_at: String?
    public var id: String { quote_id }
}
public struct TopupPendingCheckout: Sendable, Equatable, Decodable, Identifiable {
    public let order_id: String
    public let amount_cents: Int
    public let created_at: String?
    public var id: String { order_id }
}
public struct TopupList: Sendable, Equatable, Decodable {
    public let credited: [TopupCredit]
    public let pending_lightning: [TopupPendingQuote]
    public let pending_checkout: [TopupPendingCheckout]
}

/// Top-up amounts. The server minimum and the processor bound come from the signed config when it publishes them; otherwise the documented
/// US$21 / US$10,000 figures apply. Presets are 21 / 50 / 100 inside those bounds; no fee, markup or rate is applied here.
public struct TopupLimits: Sendable, Equatable {
    public let minCents: Int
    public let maxCents: Int
    public static let documented = TopupLimits(minCents: 2100, maxCents: 1_000_000)
    public var presetsCents: [Int] { OnboardingFunding.presetsCents.filter(valid) }
    public func valid(_ cents: Int) -> Bool { (minCents...maxCents).contains(cents) }
    public func cents(fromDollars text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^[0-9]{1,5}(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        var fraction = parts.count == 2 ? String(parts[1]) : "0"
        if fraction.count == 1 { fraction += "0" }
        let cents = Int(parts[0])! * 100 + Int(fraction)!
        return valid(cents) ? cents : nil
    }
}
