import Foundation

/// The one repeat-top-up payment this device has started for an (origin, signer) and not yet seen closed by NStack. It is saved before the
/// request that can create a payable order or invoice, and replayed unchanged (same key, amount, return address) after any failure or relaunch.
public struct TopupAttempt: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable { case card, lightning }
    public let method: Method
    public let key: String
    public let amountCents: Int
    /// Card only: the server-approved return address sent with the checkout (NStack treats a different one under the same key as a conflict).
    public let returnURL: String?
    public var orderId: String?
    public var quoteId: String?
}

public struct TopupDraft: Codable, Equatable, Sendable {
    public var version = 1
    public let origin: String
    public let signerNpub: String
    public var attempt: TopupAttempt?
    public init(origin: String, signerNpub: String, attempt: TopupAttempt? = nil) { self.origin = origin; self.signerNpub = signerNpub; self.attempt = attempt }
}

public enum TopupDraftError: Error, Equatable, Sendable { case unreadable }

public protocol TopupDraftStore: Sendable {
    /// `nil` only when no draft was ever saved. A file that exists but cannot be read, decoded or matched to this (origin, signer) throws:
    /// treating it as absent would let a second payable attempt start while the first one's key and order are lost.
    func load(origin: String, signerNpub: String) throws -> TopupDraft?
    func save(_ draft: TopupDraft) throws
}

/// One small JSON file per (origin, signer), named by a hash; excluded from backup and, on iOS, under complete file protection.
public struct FileTopupDraftStore: TopupDraftStore {
    let directory: URL
    public init(directory: URL) { self.directory = directory }
    func url(_ origin: String, _ signer: String) -> URL { directory.appendingPathComponent(SHA256Hex.of("topup-draft-v1\n\(origin)\n\(signer)") + ".json") }

    public func load(origin: String, signerNpub: String) throws -> TopupDraft? {
        let file = url(origin, signerNpub)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        let draft = try JSONDecoder().decode(TopupDraft.self, from: data)
        guard draft.version == 1, draft.origin == origin, draft.signerNpub == signerNpub else { throw TopupDraftError.unreadable }
        return draft
    }
    public func save(_ draft: TopupDraft) throws {
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
}

public final class MemoryTopupDraftStore: TopupDraftStore, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [String: TopupDraft] = [:]
    public init() {}
    public func load(origin: String, signerNpub: String) throws -> TopupDraft? { lock.withLock { drafts[origin + "\n" + signerNpub] } }
    public func save(_ draft: TopupDraft) throws { lock.withLock { drafts[draft.origin + "\n" + draft.signerNpub] = draft } }
}
