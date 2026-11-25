import CryptoKit
import Foundation

/// Everything the wizard must remember across relaunch. It belongs to exactly one (Tower origin, signer) pair and is never
/// read for another identity. The invitation code is kept only until the server has accepted the intent, so an interrupted
/// create can be replayed with the identical request; it is removed as soon as the intent id is recorded.
public struct OnboardingDraft: Codable, Equatable, Sendable {
    public var version = 1
    public let origin: String
    public let signerNpub: String
    public var workspaceName = ""
    public var fundingCents = OnboardingFunding.minimumCents
    public var agentOfferId: String?
    public var agentDailyCapCents: Int?
    public var invite: OnboardingInviteCode?
    /// Stable operation keys: generated once, reused by every retry and relaunch, rotated only when the operation they
    /// name genuinely changes (a different create body, a new intent after cancellation).
    public var createKey: String
    public var createDigest: String?
    public var checkoutKey: String
    public var intentId: String?
    public var intentRevision: Int?
    /// Digest of the choices the user confirmed on the review screen. Checkout needs it to equal the intent's own choices.
    public var reviewedDigest: String?
    public var checkoutOrderId: String?
    /// The payment method that has been started for this intent ("card" or "lightning"), saved before the first request of that method. While
    /// it is set no other method is started: either one may have produced a payable order, and NStack alone says when it is closed.
    public var paymentMethod: String?
    /// Absent in older card-only drafts: a reviewed intent may already have an unanswered checkout, so migration binds it conservatively.
    public var paymentMethodTracked: Bool?
    /// Lightning operation key and the quote NStack bound to it. The key is saved before the quote request and replayed on every retry and
    /// relaunch; it is replaced only after NStack reports the quote expired or cancelled (a verified unpaid end).
    public var lightningKey: String?
    public var lightningQuoteId: String?

    public init(origin: String, signerNpub: String, createKey: String, checkoutKey: String) {
        self.origin = origin; self.signerNpub = signerNpub; self.createKey = createKey; self.checkoutKey = checkoutKey
        paymentMethodTracked = true
    }

    public static func digest(name: String, fundingCents: Int, agentOfferId: String?, agentDailyCapCents: Int?) -> String {
        SHA256Hex.of("onboarding-review-v1\n\(name)\n\(fundingCents)\n\(agentOfferId ?? "-")\n\(agentDailyCapCents.map(String.init) ?? "-")")
    }
    public var formDigest: String {
        Self.digest(name: OnboardingName.normalized(workspaceName) ?? workspaceName, fundingCents: fundingCents,
                    agentOfferId: agentOfferId, agentDailyCapCents: agentOfferId == nil ? nil : agentDailyCapCents)
    }
}

public protocol OnboardingDraftStore: Sendable {
    func load(origin: String, signerNpub: String) -> OnboardingDraft?
    func save(_ draft: OnboardingDraft) throws
    func clear(origin: String, signerNpub: String)
}

/// One small JSON file per (origin, signer), named by a hash so neither appears in file names. Excluded from backup; on iOS
/// complete file protection. Lives under the app's own data directory, never shared with another identity's file.
public struct FileOnboardingDraftStore: OnboardingDraftStore {
    let directory: URL
    public init(directory: URL) { self.directory = directory }

    func url(_ origin: String, _ signer: String) -> URL {
        directory.appendingPathComponent(SHA256Hex.of("onboarding-draft-v1\n\(origin)\n\(signer)") + ".json")
    }

    public func load(origin: String, signerNpub: String) -> OnboardingDraft? {
        guard let data = try? Data(contentsOf: url(origin, signerNpub)),
              let draft = try? JSONDecoder().decode(OnboardingDraft.self, from: data),
              draft.version == 1, draft.origin == origin, draft.signerNpub == signerNpub else { return nil }
        return draft
    }

    public func save(_ draft: OnboardingDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var dir = directory; try? dir.setResourceValues(values)
        let data = try JSONEncoder().encode(draft)
        #if os(iOS)
        try data.write(to: url(draft.origin, draft.signerNpub), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url(draft.origin, draft.signerNpub), options: [.atomic])
        #endif
    }

    public func clear(origin: String, signerNpub: String) { try? FileManager.default.removeItem(at: url(origin, signerNpub)) }
}

public final class MemoryOnboardingDraftStore: OnboardingDraftStore, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [String: OnboardingDraft] = [:]
    public init() {}
    private func key(_ o: String, _ s: String) -> String { o + "\n" + s }
    public func load(origin: String, signerNpub: String) -> OnboardingDraft? { lock.withLock { drafts[key(origin, signerNpub)] } }
    public func save(_ draft: OnboardingDraft) throws { lock.withLock { drafts[key(draft.origin, draft.signerNpub)] = draft } }
    public func clear(origin: String, signerNpub: String) { lock.withLock { _ = drafts.removeValue(forKey: key(origin, signerNpub)) } }
}
