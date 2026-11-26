import Foundation

/// Why a `window.nostr` request was not answered. `message` is what the page's promise is rejected with.
public enum NIP07Error: Error, Equatable, Sendable {
    case locked, denied, pageChanged, closed, busy, accountChanged
    case invalid(String)
    case unsupported(String)

    public var message: String {
        switch self {
        case .locked: "Ambulando is locked."
        case .denied: "The user rejected the request."
        case .pageChanged: "The page changed before the request was answered."
        case .closed: "The request was cancelled."
        case .busy: "Too many requests are waiting for the user."
        case .accountChanged: "The active account changed before the request was answered."
        case .invalid(let why): "Invalid request: \(why)"
        case .unsupported(let method): "\(method) is not supported by Ambulando."
        }
    }
}

/// A parsed NIP-07 call. Parameters arrive from page JavaScript, so everything is checked and bounded here.
public enum NIP07Method: Equatable, Sendable {
    case getPublicKey
    /// `requestedPubkey` is the `pubkey` the page put in the event, if any; it must be the user's own.
    case signEvent(NostrEventTemplate, requestedPubkey: String?)
    case getRelays
    case nip44(NIP44Operation)
    case unsupported(String)

    public static let maxContentBytes = 256 * 1024
    public static let maxTags = 2000
    public static let maxTagItems = 100
    public static let maxTagBytes = 256 * 1024
    /// 2100-01-01: later timestamps are refused rather than shown as a plausible date.
    static let latestCreatedAt = 4_102_444_800

    public static func parse(method: String, params: Any?, now: Date) -> Result<NIP07Method, NIP07Error> {
        switch method {
        case "getPublicKey": return .success(.getPublicKey)
        case "getRelays": return .success(.getRelays)
        case "signEvent": return parseEvent(params, now: now)
        case "nip44.encrypt", "nip44.decrypt": return parseNIP44(method, params)
        default:
            let name = String(method.prefix(40)).filter { $0.isLetter || $0.isNumber || $0 == "." }
            return .success(.unsupported(name.isEmpty ? "This method" : name))
        }
    }

    static func parseEvent(_ params: Any?, now: Date) -> Result<NIP07Method, NIP07Error> {
        guard let event = params as? [String: Any] else { return .failure(.invalid("signEvent needs an event object")) }
        guard let kind = integer(event["kind"]), (0...65535).contains(kind) else { return .failure(.invalid("kind must be 0–65535")) }
        let content = event["content"] == nil || event["content"] is NSNull ? "" : event["content"] as? String
        guard let content else { return .failure(.invalid("content must be a string")) }
        guard content.utf8.count <= maxContentBytes else { return .failure(.invalid("content is too large")) }
        var tags: [[String]] = []
        if let raw = event["tags"], !(raw is NSNull) {
            guard let list = raw as? [Any], list.count <= maxTags else { return .failure(.invalid("tags must be a list of at most \(maxTags)")) }
            var bytes = 0
            for item in list {
                guard let tag = item as? [Any], tag.count <= maxTagItems else { return .failure(.invalid("each tag must be a short list of strings")) }
                var strings: [String] = []
                for value in tag {
                    guard let text = value as? String else { return .failure(.invalid("tag values must be strings")) }
                    bytes += text.utf8.count
                    strings.append(text)
                }
                guard bytes <= maxTagBytes else { return .failure(.invalid("tags are too large")) }
                tags.append(strings)
            }
        }
        let createdAt: Int
        if let raw = event["created_at"], !(raw is NSNull) {
            guard let value = integer(raw), value > 0, value <= latestCreatedAt else { return .failure(.invalid("created_at must be a Unix time")) }
            createdAt = value
        } else {
            createdAt = Int(now.timeIntervalSince1970)
        }
        var requested: String?
        if let raw = event["pubkey"], !(raw is NSNull) {
            guard let pubkey = raw as? String else { return .failure(.invalid("pubkey must be a string")) }
            requested = pubkey.lowercased()
        }
        return .success(.signEvent(NostrEventTemplate(kind: kind, tags: tags, content: content, createdAt: createdAt), requestedPubkey: requested))
    }

    /// `{ pubkey, plaintext }` or `{ pubkey, ciphertext }` and nothing else, within the NIP-44 v2 limits.
    static func parseNIP44(_ method: String, _ params: Any?) -> Result<NIP07Method, NIP07Error> {
        let encrypting = method == "nip44.encrypt"
        let field = encrypting ? "plaintext" : "ciphertext"
        guard let body = params as? [String: Any], Set(body.keys) == ["pubkey", field] else {
            return .failure(.invalid("\(method) needs a pubkey and \(field)"))
        }
        guard let pubkey = body["pubkey"] as? String, NIP44.isHexPublicKey(pubkey) else {
            return .failure(.invalid("pubkey must be 64 lowercase hex characters"))
        }
        guard let text = body[field] as? String else { return .failure(.invalid("\(field) must be a string")) }
        if encrypting {
            guard (1...NIP44.maxPlaintextBytes).contains(text.utf8.count) else { return .failure(.invalid("plaintext must be 1–\(NIP44.maxPlaintextBytes) bytes")) }
            return .success(.nip44(.encrypt(peer: pubkey, plaintext: text)))
        }
        guard NIP44.payloadLengthRange.contains(text.utf8.count), !text.hasPrefix("#") else { return .failure(.invalid("ciphertext is not a NIP-44 v2 payload")) }
        return .success(.nip44(.decrypt(peer: pubkey, payload: text)))
    }

    /// A whole JSON number (never a boolean) within the exactly representable range.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) <= 9_007_199_254_740_991 else { return nil }
        return Int(double)
    }
}

/// A site's standing answer to "may this site see your public key" (and, if denied, ask for anything).
public enum NIP07SitePermission: String, Codable, Sendable { case allowed, denied }

/// The page a request came from: the tab, the document loaded in it (a new number on every main-frame commit) and its
/// HTTPS origin as WebKit reported it.
public struct NIP07Context: Equatable, Hashable, Sendable {
    public let tabId: UUID
    public let documentId: UInt64
    public let origin: String
    public init(tabId: UUID, documentId: UInt64, origin: String) { self.tabId = tabId; self.documentId = documentId; self.origin = origin }
}

/// A question shown to the user in a native sheet.
public struct NIP07Prompt: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case connect
        case sign(NostrEventTemplate)
        /// `bytes` is the size of the text going in; the text itself is never shown or kept. `isSelf`: the peer is the
        /// user's own key (a private list or setting), shown as private data in the prompt.
        case encrypt(peer: String, isSelf: Bool, bytes: Int)
        case decrypt(peer: String, isSelf: Bool, bytes: Int)
    }
    public let id: UUID
    public let context: NIP07Context
    public let kind: Kind
    /// The user's own key, as shown in the sheet.
    public let npub: String?
}

public enum NIP07Decision: Equatable, Sendable {
    /// `remember` explicitly saves only this origin/account/operation (and signing kind).
    case allow(remember: Bool)
    case deny(remember: Bool)
}

/// What a request is answered with.
public enum NIP07Reply: Equatable, Sendable {
    case publicKey(String)
    case event(NostrEvent)
    case relays
    case text(String)
}

/// Native side of `window.nostr`. Pages never see the key; they get the public key (after the user allows the site)
/// and operation results approved once or explicitly remembered for this exact origin and account.
///
/// A request is tied to the document that made it: when the tab navigates, reloads or closes, or Ambulando locks, it
/// is cancelled, and `isCurrent` is asked again after the user answers and before anything is signed.
@MainActor
public final class NIP07Broker {
    public nonisolated static let maxPromptsPerTab = 4

    public private(set) var prompts: [NIP07Prompt] = []
    public var current: NIP07Prompt? { prompts.first }
    public private(set) var locked: Bool
    public private(set) var sites: [String: NIP07SitePermission]
    /// Called after `prompts`, `sites` or `locked` change.
    public var onChange: (() -> Void)?

    public private(set) var grants: Set<String>
    private let persistGrants: (Set<String>) -> Void
    private var authorizationEpoch: UInt64 = 0
    private var originEpochs: [String: UInt64] = [:]
    private var waiters: [UUID: CheckedContinuation<NIP07Decision?, Never>] = [:]
    private let publicKey: @Sendable () async throws -> String
    private let accountSigner: (@Sendable (NostrEventTemplate, String) async throws -> NostrEvent)?
    private let signer: @Sendable (NostrEventTemplate) async throws -> NostrEvent
    /// Runs one NIP-44 operation for exactly the given public key (the account the user approved it for).
    private let cipher: @Sendable (NIP44Operation, String) async throws -> String
    private let persist: ([String: NIP07SitePermission]) -> Void
    private let now: () -> Date

    public init(locked: Bool, sites: [String: NIP07SitePermission] = [:], grants: Set<String> = [],
                persistGrants: @escaping (Set<String>) -> Void = { _ in },
                publicKey: @escaping @Sendable () async throws -> String,
                signer: @escaping @Sendable (NostrEventTemplate) async throws -> NostrEvent,
                accountSigner: (@Sendable (NostrEventTemplate, String) async throws -> NostrEvent)? = nil,
                cipher: @escaping @Sendable (NIP44Operation, String) async throws -> String = { _, _ in throw NIP07Error.unsupported("nip44") },
                persist: @escaping ([String: NIP07SitePermission]) -> Void = { _ in },
                now: @escaping () -> Date = { Date() }) {
        self.accountSigner = accountSigner
        self.grants = grants; self.persistGrants = persistGrants
        self.locked = locked; self.sites = sites; self.publicKey = publicKey; self.signer = signer; self.cipher = cipher; self.persist = persist; self.now = now
    }

    /// Answers one request. `isCurrent` reports whether the requesting document is still the one shown in its tab.
    public func handle(method: String, params: Any?, context: NIP07Context, isCurrent: @escaping @MainActor () -> Bool) async -> Result<NIP07Reply, NIP07Error> {
        guard !locked else { return .failure(.locked) }
        guard isCurrent() else { return .failure(.pageChanged) }
        let parsed: NIP07Method
        switch NIP07Method.parse(method: method, params: params, now: now()) {
        case .success(let value): parsed = value
        case .failure(let error): return .failure(error)
        }
        switch parsed {
        case .getRelays: return .success(.relays)
        case .unsupported(let name): return .failure(.unsupported(name))
        case .getPublicKey: return await connect(context, isCurrent: isCurrent)
        case .signEvent(let template, let requested): return await sign(template, requested: requested, context: context, isCurrent: isCurrent)
        case .nip44(let operation): return await encryptOrDecrypt(operation, context: context, isCurrent: isCurrent)
        }
    }

    private func connect(_ context: NIP07Context, isCurrent: @escaping @MainActor () -> Bool) async -> Result<NIP07Reply, NIP07Error> {
        if sites[context.origin] == .denied { return .failure(.denied) }
        let epoch = authorizationEpoch
        let originEpoch = originEpochs[context.origin, default: 0]
        do {
            let own = try await publicKey()
            let grant = Self.operationGrant(context.origin, own, "getPublicKey")
            var remember = false
            if !grants.contains(grant) {
                switch await ask(.connect, context: context, isCurrent: isCurrent, account: own) {
                case .failure(let error): return .failure(error)
                case .success(.deny(let remember)):
                    if remember { setSite(context.origin, .denied) }
                    return .failure(.denied)
                case .success(.allow(let value)): remember = value
                }
            }
            guard try await publicKey() == own else { return .failure(.accountChanged) }
            guard !locked else { return .failure(.locked) }
            guard isCurrent() else { return .failure(.pageChanged) }
            guard authorizationEpoch == epoch, originEpochs[context.origin, default: 0] == originEpoch else { return .failure(.denied) }
            if remember { saveGrant(grant, origin: context.origin) }
            return .success(.publicKey(own))
        } catch { return .failure(locked ? .locked : .invalid("no identity")) }
    }

    private func sign(_ template: NostrEventTemplate, requested: String?, context: NIP07Context,
                      isCurrent: @escaping @MainActor () -> Bool) async -> Result<NIP07Reply, NIP07Error> {
        if sites[context.origin] == .denied { return .failure(.denied) }
        let epoch = authorizationEpoch
        let originEpoch = originEpochs[context.origin, default: 0]
        let own: String
        do { own = try await publicKey() } catch { return .failure(locked ? .locked : .invalid("no identity")) }
        if let requested, requested != own { return .failure(.invalid("the event's pubkey is not this identity")) }
        let grant = Self.operationGrant(context.origin, own, "signEvent:\(template.kind)")
        var rememberGrant = false
        if !grants.contains(grant) {
            switch await ask(.sign(template), context: context, isCurrent: isCurrent, account: own) {
            case .failure(let error): return .failure(error)
            case .success(.deny): return .failure(.denied)
            case .success(.allow(let remember)):
                rememberGrant = remember
            }
        }
        // Re-checked after the user answered: a lock or a navigation in the meantime wins over the approval.
        guard !locked else { return .failure(.locked) }
        guard isCurrent() else { return .failure(.pageChanged) }
        do {
            guard try await publicKey() == own else { return .failure(.accountChanged) }
            guard !locked, authorizationEpoch == epoch, originEpochs[context.origin, default: 0] == originEpoch else { return .failure(.denied) }
            guard isCurrent() else { return .failure(.pageChanged) }
            if rememberGrant { saveGrant(grant, origin: context.origin) }
            let event: NostrEvent
            if let accountSigner { event = try await accountSigner(template, own) }
            else { event = try await signer(template) }
            guard event.pubkey == own, try await publicKey() == own else { return .failure(.accountChanged) }
            guard authorizationEpoch == epoch, originEpochs[context.origin, default: 0] == originEpoch else { return .failure(.denied) }
            guard !locked else { return .failure(.locked) }
            guard isCurrent() else { return .failure(.pageChanged) }
            return .success(.event(event))
        } catch {
            return .failure(locked ? .locked : .invalid("the event could not be signed"))
        }
    }

    /// One NIP-44 call. The account is fixed when the request arrives; the sheet names it, and the operation runs only
    /// if that same account is still active after the user answers (an account switch, lock, navigation or revoked
    /// site in between refuses the call and nothing is decrypted or encrypted).
    private func encryptOrDecrypt(_ operation: NIP44Operation, context: NIP07Context,
                                  isCurrent: @escaping @MainActor () -> Bool) async -> Result<NIP07Reply, NIP07Error> {
        if sites[context.origin] == .denied { return .failure(.denied) }
        let epoch = authorizationEpoch
        let originEpoch = originEpochs[context.origin, default: 0]
        let own: String
        do { own = try await publicKey() } catch { return .failure(locked ? .locked : .invalid("no identity")) }
        let isSelf = operation.peer == own
        let kind: NIP07Prompt.Kind
        let method: String
        switch operation {
        case .encrypt(let peer, let plaintext): kind = .encrypt(peer: peer, isSelf: isSelf, bytes: plaintext.utf8.count); method = "nip44.encrypt"
        case .decrypt(let peer, let payload): kind = .decrypt(peer: peer, isSelf: isSelf, bytes: payload.utf8.count); method = "nip44.decrypt"
        }
        let grant = Self.operationGrant(context.origin, own, method)
        var rememberGrant = false
        if !grants.contains(grant) {
            switch await ask(kind, context: context, isCurrent: isCurrent, account: own) {
            case .failure(let error): return .failure(error)
            case .success(.deny): return .failure(.denied)
            case .success(.allow(let remember)):
                rememberGrant = remember
            }
        }
        guard !locked else { return .failure(.locked) }
        guard isCurrent() else { return .failure(.pageChanged) }
        guard sites[context.origin] != .denied else { return .failure(.denied) }
        do {
            guard try await publicKey() == own else { return .failure(.accountChanged) }
            guard !locked else { return .failure(.locked) }
            guard isCurrent() else { return .failure(.pageChanged) }
            guard sites[context.origin] != .denied,
                  authorizationEpoch == epoch, originEpochs[context.origin, default: 0] == originEpoch else { return .failure(.denied) }
            if rememberGrant { saveGrant(grant, origin: context.origin) }
            let result = try await cipher(operation, own)
            // Both identity lookup and the cipher suspend. Never deliver output after revocation or account change.
            guard try await publicKey() == own else { return .failure(.accountChanged) }
            guard !locked else { return .failure(.locked) }
            guard isCurrent() else { return .failure(.pageChanged) }
            guard sites[context.origin] != .denied,
                  authorizationEpoch == epoch, originEpochs[context.origin, default: 0] == originEpoch else { return .failure(.denied) }
            return .success(.text(result))
        } catch let error as IdentityError where error == .signerMismatch {
            return .failure(.accountChanged)
        } catch {
            return .failure(locked ? .locked : .invalid(encrypting(operation) ? "the text could not be encrypted" : "the payload could not be decrypted"))
        }
    }

    private func encrypting(_ operation: NIP44Operation) -> Bool {
        if case .encrypt = operation { return true }
        return false
    }

    /// `account`: the public key the request was made for; if the active key differs when the sheet is built, the call fails.
    private func ask(_ kind: NIP07Prompt.Kind, context: NIP07Context, isCurrent: @escaping @MainActor () -> Bool, account: String? = nil) async -> Result<NIP07Decision, NIP07Error> {
        guard prompts.filter({ $0.context.tabId == context.tabId }).count < Self.maxPromptsPerTab else { return .failure(.busy) }
        let shown = try? await publicKey()
        if let account, shown != account { return .failure(locked ? .locked : .accountChanged) }
        let npub = shown.flatMap(NostrKeys.npub(publicKeyHex:))
        // The key read above suspends; the page or lock may have changed meanwhile.
        guard !locked else { return .failure(.locked) }
        guard isCurrent() else { return .failure(.pageChanged) }
        let prompt = NIP07Prompt(id: UUID(), context: context, kind: kind, npub: npub)
        let decision: NIP07Decision? = await withCheckedContinuation { continuation in
            waiters[prompt.id] = continuation
            prompts.append(prompt)
            onChange?()
        }
        guard let decision else { return .failure(locked ? .locked : (isCurrent() ? .closed : .pageChanged)) }
        return .success(decision)
    }

    /// The user's answer to `prompt` (from the sheet).
    public func resolve(_ id: UUID, _ decision: NIP07Decision) {
        finish(id, decision)
    }

    /// Cancels what the tab's earlier documents asked (called on every main-frame commit).
    public func documentChanged(tabId: UUID, documentId: UInt64) {
        cancel { $0.context.tabId == tabId && $0.context.documentId != documentId }
    }

    public func tabClosed(_ tabId: UUID) { cancel { $0.context.tabId == tabId } }

    /// Locking invalidates pending work and refuses calls until unlocked. Explicit persistent grants survive.
    public func setLocked(_ value: Bool) {
        guard value != locked else { return }
        locked = value
        if value {
            authorizationEpoch &+= 1
            cancel { _ in true }
        }
        onChange?()
    }

    /// Account transitions invalidate requests even if the user switches back before an await resumes.
    /// Stored grants remain isolated by account.
    public func accountChanged() {
        authorizationEpoch &+= 1
        cancel { _ in true }
    }

    /// Revoke one account/operation, invalidating in-flight work for that site.
    public func revoke(_ grant: String) {
        guard grants.remove(grant) != nil else { return }
        let origin = String(grant.split(separator: "|", omittingEmptySubsequences: false).first ?? "")
        originEpochs[origin, default: 0] &+= 1
        persistGrants(grants)
        cancel { $0.context.origin == origin }
        onChange?()
    }

    /// Settings › browser: forget what was decided for `origin`.
    public func forget(_ origin: String) {
        originEpochs[origin, default: 0] &+= 1
        grants = grants.filter { !$0.hasPrefix(origin + "|") }
        persistGrants(grants)
        cancel { $0.context.origin == origin }
        setSite(origin, nil)
    }

    /// Identity removed or disconnected: nothing a site was allowed survives.
    public func reset() {
        authorizationEpoch &+= 1
        grants = []
        persistGrants(grants)
        cancel { _ in true }
        sites = [:]
        persist(sites)
        onChange?()
    }

    private func setSite(_ origin: String, _ value: NIP07SitePermission?) {
        if value == .denied { originEpochs[origin, default: 0] &+= 1 }
        sites[origin] = value
        persist(sites)
        onChange?()
    }

    private func cancel(where match: (NIP07Prompt) -> Bool) {
        for prompt in prompts where match(prompt) { finish(prompt.id, nil) }
    }

    private func finish(_ id: UUID, _ decision: NIP07Decision?) {
        prompts.removeAll { $0.id == id }
        waiters.removeValue(forKey: id)?.resume(returning: decision)
        onChange?()
    }

    private func saveGrant(_ grant: String, origin: String) {
        grants.insert(grant)
        persistGrants(grants)
        setSite(origin, .allowed)
    }

    static func operationGrant(_ origin: String, _ account: String, _ operation: String) -> String {
        "\(origin)|\(account)|\(operation)"
    }

}

extension NIP07Reply {
    /// The value the page's promise resolves with (plain JSON types, as WebKit converts them).
    public var javaScriptValue: Any {
        switch self {
        case .publicKey(let key): key
        case .relays: [String: Any]()
        case .text(let text): text
        case .event(let e): ["id": e.id, "pubkey": e.pubkey, "created_at": e.created_at, "kind": e.kind, "tags": e.tags,
                             "content": e.content, "sig": e.sig] as [String: Any]
        }
    }
}
