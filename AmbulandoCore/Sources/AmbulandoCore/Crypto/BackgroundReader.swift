import Foundation
import P256K
import Security

/// The opt-in "refresh while locked" credential.
///
/// The identity vault is PIN-sealed and its key exists only in memory while unlocked, so after the process ends iOS
/// cannot refresh anything in the background. If the user explicitly turns on background refresh, a copy of the key is
/// kept in a separate device-only Keychain item (`AfterFirstUnlockThisDeviceOnly`, never synchronised) together with a
/// policy. Code holding it can sign **only** NIP-98 `GET` requests to the pinned Tower origin for the pinned workspaces:
/// no message signatures, no POST/PUT/PATCH/DELETE, no other host. Sending still needs the PIN.
///
/// Locking manually removes the item (background refresh stops until the next unlock); turning the setting off or
/// removing the identity removes it as well.
public struct BackgroundReadCredential: Codable, Sendable, Equatable {
    public var version = 1
    public let publicKeyHex: String
    let secretKey: Data
    public let origin: String
    public var workspaceIds: [String]
    public let createdAt: String

    public var policy: ReadPolicy { ReadPolicy(origin: origin, workspaceIds: Set(workspaceIds)) }
}

/// Which signing requests the background credential may answer.
public struct ReadPolicy: Sendable, Equatable {
    public let origin: String
    public let workspaceIds: Set<String>

    public init(origin: String, workspaceIds: Set<String>) { self.origin = origin; self.workspaceIds = workspaceIds }

    static let prefix = "/api/v4/flightdeck-pg/workspaces"

    public func allows(_ template: NostrEventTemplate) -> Bool {
        guard template.kind == NIP98.kind, template.content.isEmpty, template.tags.count == 2,
              template.tags[0].count == 2, template.tags[0][0] == "u", template.tags[1] == ["method", "GET"],
              let url = URL(string: template.tags[0][1]), let pinned = try? TowerOrigin(origin),
              url.scheme == "https", url.host == pinned.url.host, url.port == pinned.url.port,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        let path = url.path
        guard !path.contains(".."), path == Self.prefix || path.hasPrefix(Self.prefix + "/") else { return false }
        if path == Self.prefix { return true }   // workspace discovery
        let workspace = path.dropFirst(Self.prefix.count + 1).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return workspaceIds.contains(workspace)
    }
}

public protocol BackgroundCredentialStore: Sendable {
    func read() throws -> BackgroundReadCredential?
    func write(_ credential: BackgroundReadCredential) throws
    func delete() throws
}

/// Keychain item of this app's own service only; it is never shared, synchronised or backed up off the device.
public struct KeychainBackgroundCredentialStore: BackgroundCredentialStore {
    let service: String
    public init(service: String = ProductionStorage.backgroundReadService) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "reader", kSecAttrSynchronizable as String: false]
    }

    public func read() throws -> BackgroundReadCredential? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw IdentityError.keychainUnavailable }
        return try? JSONDecoder().decode(BackgroundReadCredential.self, from: data)
    }

    public func write(_ credential: BackgroundReadCredential) throws {
        try delete()
        var q = query
        q[kSecValueData as String] = try JSONEncoder().encode(credential)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw IdentityError.keychainUnavailable }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityError.keychainUnavailable }
    }
}

/// In-memory signer for the background credential. It refuses everything outside its policy.
struct BackgroundReader {
    let credential: BackgroundReadCredential

    var npub: String? { NostrKeys.npub(publicKeyHex: credential.publicKeyHex) }

    func sign(_ template: NostrEventTemplate) throws -> NostrEvent {
        guard credential.policy.allows(template) else { throw IdentityError.locked }
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: credential.secretKey)
        let pubkey = Data(key.xonly.bytes).hex
        guard pubkey == credential.publicKeyHex else { throw IdentityError.invalidVault }
        let id = NostrSerialization.eventId(pubkey: pubkey, template: template)
        var digest = Array(Data(hex: id)!)
        var auxiliary = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &auxiliary) == errSecSuccess else { throw IdentityError.keychainUnavailable }
        defer { for i in auxiliary.indices { auxiliary[i] = 0 } }
        let signature = try key.signature(message: &digest, auxiliaryRand: &auxiliary)
        return NostrEvent(id: id, pubkey: pubkey, created_at: template.createdAt, kind: template.kind,
                          tags: template.tags, content: template.content, sig: Data(signature.dataRepresentation).hex)
    }
}

/// The trusted-device session key (see `IdentityService.resumeSession`).
public struct SessionKey: Codable, Sendable, Equatable {
    public var version = 1
    public let publicKeyHex: String
    let secretKey: Data
}

public protocol SessionKeyStore: Sendable {
    func read() throws -> SessionKey?
    func write(_ key: SessionKey) throws
    func delete() throws
}

/// Device-only Keychain item readable only while the iPhone is unlocked (`WhenUnlockedThisDeviceOnly`), never
/// synchronised; a background launch while the device is locked cannot read it.
public struct KeychainSessionKeyStore: SessionKeyStore {
    let service: String
    public init(service: String = ProductionStorage.sessionService) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "session", kSecAttrSynchronizable as String: false]
    }

    public func read() throws -> SessionKey? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw IdentityError.keychainUnavailable }
        return try? JSONDecoder().decode(SessionKey.self, from: data)
    }

    public func write(_ key: SessionKey) throws {
        try delete()
        var q = query
        q[kSecValueData as String] = try JSONEncoder().encode(key)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw IdentityError.keychainUnavailable }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityError.keychainUnavailable }
    }
}
