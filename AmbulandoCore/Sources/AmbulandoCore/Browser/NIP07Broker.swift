import Foundation

/// Why a `window.nostr` request was not answered. `message` is what the page's promise is rejected with.
public enum NIP07Error: Error, Equatable, Sendable {
    case locked, denied, pageChanged, closed, busy
    case invalid(String)
    case unsupported(String)

    public var message: String {
        switch self {
        case .locked: "Ambulando is locked."
        case .denied: "The user rejected the request."
        case .pageChanged: "The page changed before the request was answered."
        case .closed: "The request was cancelled."
        case .busy: "Too many requests are waiting for the user."
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
    }
    public let id: UUID
    public let context: NIP07Context
    public let kind: Kind
    /// The user's own key, as shown in the sheet.
    public let npub: String?
    /// Whether "allow for this site until Ambulando locks" may be offered (authentication kinds only).
    public var offersSessionGrant: Bool {
        if case .sign(let event) = kind { return NIP07Broker.sessionGrantKinds.contains(event.kind) }
        return false
    }
}

public enum NIP07Decision: Equatable, Sendable {
    /// `remember`: for connect, keep the answer for the site; for an authentication kind, allow that kind for the site
    /// until Ambulando locks.
    case allow(remember: Bool)
    case deny(remember: Bool)
}

/// What a request is answered with.
public enum NIP07Reply: Equatable, Sendable {
    case publicKey(String)
    case event(NostrEvent)
    case relays
}

/// Native side of `window.nostr`. Pages never see the key; they get the public key (after the user allows the site)
/// and events the user approved one at a time in a sheet that names the site. Only the authentication kinds in
/// `sessionGrantKinds` may be allowed for a site until Ambulando locks.
///
/// A request is tied to the document that made it: when the tab navigates, reloads or closes, or Ambulando locks, it
/// is cancelled, and `isCurrent` is asked again after the user answers and before anything is signed.
@MainActor
public final class NIP07Broker {
    /// NIP-42 relay authentication and NIP-98 HTTP authentication.
    public nonisolated static let sessionGrantKinds: Set<Int> = [22242, 27235]
    public nonisolated static let maxPromptsPerTab = 4

    public private(set) var prompts: [NIP07Prompt] = []
    public var current: NIP07Prompt? { prompts.first }
    public private(set) var locked: Bool
    public private(set) var sites: [String: NIP07SitePermission]
    /// Called after `prompts`, `sites` or `locked` change.
    public var onChange: (() -> Void)?

    private var sessionGrants: Set<String> = []
    private var waiters: [UUID: CheckedContinuation<NIP07Decision?, Never>] = [:]
    private let publicKey: @Sendable () async throws -> String
    private let signer: @Sendable (NostrEventTemplate) async throws -> NostrEvent
    private let persist: ([String: NIP07SitePermission]) -> Void
    private let now: () -> Date

    public init(locked: Bool, sites: [String: NIP07SitePermission] = [:],
                publicKey: @escaping @Sendable () async throws -> String,
                signer: @escaping @Sendable (NostrEventTemplate) async throws -> NostrEvent,
                persist: @escaping ([String: NIP07SitePermission]) -> Void = { _ in },
                now: @escaping () -> Date = { Date() }) {
        self.locked = locked; self.sites = sites; self.publicKey = publicKey; self.signer = signer; self.persist = persist; self.now = now
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
        }
    }

    private func connect(_ context: NIP07Context, isCurrent: @escaping @MainActor () -> Bool) async -> Result<NIP07Reply, NIP07Error> {
        switch sites[context.origin] {
        case .denied: return .failure(.denied)
        case .allowed: break
        case nil:
            switch await ask(.connect, context: context, isCurrent: isCurrent) {
            case .failure(let error): return .failure(error)
            case .success(.deny(let remember)):
                if remember { setSite(context.origin, .denied) }
                return .failure(.denied)
            case .success(.allow(let remember)):
                if remember { setSite(context.origin, .allowed) }
            }
        }
        guard !locked else { return .failure(.locked) }
        guard isCurrent() else { return .failure(.pageChanged) }
        do { return .success(.publicKey(try await publicKey())) } catch { return .failure(locked ? .locked : .invalid("no identity")) }
    }

    private func sign(_ template: NostrEventTemplate, requested: String?, context: NIP07Context,
                      isCurrent: @escaping @MainActor () -> Bool) async -> Result<NIP07Reply, NIP07Error> {
        if sites[context.origin] == .denied { return .failure(.denied) }
        let own: String
        do { own = try await publicKey() } catch { return .failure(locked ? .locked : .invalid("no identity")) }
        if let requested, requested != own { return .failure(.invalid("the event's pubkey is not this identity")) }
        let grant = Self.grantKey(context.origin, template.kind)
        if !sessionGrants.contains(grant) {
            switch await ask(.sign(template), context: context, isCurrent: isCurrent) {
            case .failure(let error): return .failure(error)
            case .success(.deny): return .failure(.denied)
            case .success(.allow(let remember)):
                if remember, Self.sessionGrantKinds.contains(template.kind) { sessionGrants.insert(grant) }
            }
        }
        // Re-checked after the user answered: a lock or a navigation in the meantime wins over the approval.
        guard !locked else { return .failure(.locked) }
        guard isCurrent() else { return .failure(.pageChanged) }
        do {
            let event = try await signer(template)
            guard !locked else { return .failure(.locked) }
            guard isCurrent() else { return .failure(.pageChanged) }
            return .success(.event(event))
        } catch {
            return .failure(locked ? .locked : .invalid("the event could not be signed"))
        }
    }

    private func ask(_ kind: NIP07Prompt.Kind, context: NIP07Context, isCurrent: @escaping @MainActor () -> Bool) async -> Result<NIP07Decision, NIP07Error> {
        guard prompts.filter({ $0.context.tabId == context.tabId }).count < Self.maxPromptsPerTab else { return .failure(.busy) }
        let npub = (try? await publicKey()).flatMap(NostrKeys.npub(publicKeyHex:))
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

    /// Locking cancels every waiting request, forgets the until-lock grants and refuses new requests until unlocked.
    public func setLocked(_ value: Bool) {
        guard value != locked else { return }
        locked = value
        if value {
            sessionGrants = []
            cancel { _ in true }
        }
        onChange?()
    }

    /// Settings › browser: forget what was decided for `origin`.
    public func forget(_ origin: String) {
        sessionGrants = sessionGrants.filter { !$0.hasPrefix(origin + "|") }
        setSite(origin, nil)
    }

    /// Identity removed or disconnected: nothing a site was allowed survives.
    public func reset() {
        sessionGrants = []
        cancel { _ in true }
        sites = [:]
        persist(sites)
        onChange?()
    }

    private func setSite(_ origin: String, _ value: NIP07SitePermission?) {
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

    static func grantKey(_ origin: String, _ kind: Int) -> String { "\(origin)|\(kind)" }
}

extension NIP07Reply {
    /// The value the page's promise resolves with (plain JSON types, as WebKit converts them).
    public var javaScriptValue: Any {
        switch self {
        case .publicKey(let key): key
        case .relays: [String: Any]()
        case .event(let e): ["id": e.id, "pubkey": e.pubkey, "created_at": e.created_at, "kind": e.kind, "tags": e.tags,
                             "content": e.content, "sig": e.sig] as [String: Any]
        }
    }
}
