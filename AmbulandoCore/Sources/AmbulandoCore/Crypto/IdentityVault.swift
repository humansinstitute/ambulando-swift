// Adapted from the NoteToSelf / In Dialogue native identity vault (sol/native).
import CommonCrypto
import CryptoKit
import Foundation
import P256K
import Security

public enum IdentityError: LocalizedError, Equatable, Sendable {
    case invalidNsec, invalidPIN, exists, missing, locked, keychainUnavailable, invalidVault, signerMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidNsec: "Enter a valid Bech32 nsec with a 32-byte Nostr secret key."
        case .invalidPIN: "PIN must contain 4 to 12 digits."
        case .exists: "An identity already exists. Remove it explicitly before importing another."
        case .missing: "No identity has been imported into this app."
        case .locked: "Unlock your identity to sign."
        case .keychainUnavailable: "The Ambulando Keychain secret is unavailable. Your identity has been kept."
        case .invalidVault: "Incorrect PIN or damaged identity vault. Your identity has been kept."
        case .signerMismatch: "The unlocked identity is not the one this connection was made with."
        }
    }
}

/// Holds the per-install secret that, combined with the PIN, derives the vault key.
public protocol VaultSecretStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// Device-only, non-synchronizable Keychain item owned by this app's bundle.
/// It never queries other services or access groups.
public struct KeychainVaultSecretStore: VaultSecretStore {
    let service: String
    public init(service: String = "studio.otherstuff.ambulando.native.identity-vault.v1") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "device-secret",
         kSecAttrSynchronizable as String: false]
    }

    public func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw IdentityError.keychainUnavailable }
        return data
    }

    public func write(_ data: Data) throws {
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw IdentityError.keychainUnavailable }
    }
}

/// PIN + per-install secret → PBKDF2-HMAC-SHA256 (210k) → AES-GCM sealed scalar.
/// Only the sealed envelope is written to disk; the scalar lives in memory while unlocked.
public final class IdentityVault {
    struct Envelope: Codable {
        var version = 1
        var iterations = 210_000
        let salt: Data
        let sealed: Data
        let publicKeyHex: String
    }

    public let url: URL
    private let secrets: VaultSecretStore
    private var clear: Data?
    public private(set) var publicKeyHex: String?

    public var isUnlocked: Bool { clear != nil }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public init(url: URL, secrets: VaultSecretStore) {
        self.url = url
        self.secrets = secrets
        publicKeyHex = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }?.publicKeyHex
    }

    static func validPIN(_ pin: String) -> Bool { pin.range(of: "^[0-9]{4,12}$", options: .regularExpression) != nil }

    private func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw IdentityError.keychainUnavailable }
        return Data(bytes)
    }

    private func key(pin: String, secret: Data, salt: Data) throws -> SymmetricKey {
        guard Self.validPIN(pin) else { throw IdentityError.invalidPIN }
        let password = Array((pin + ":" + secret.base64EncodedString()).utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                                     s.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 210_000, &derived, 32)
            }
        }
        guard status == kCCSuccess else { throw IdentityError.keychainUnavailable }
        defer { for i in derived.indices { derived[i] = 0 } }
        return SymmetricKey(data: derived)
    }

    public func create(nsec: String, pin: String) throws {
        guard !exists else { throw IdentityError.exists }
        guard Self.validPIN(pin) else { throw IdentityError.invalidPIN }
        guard var scalar = NostrKeys.secretKey(nsec: nsec) else { throw IdentityError.invalidNsec }
        defer { scalar.resetBytes(in: 0..<scalar.count) }
        let pubkey = try Data(P256K.Schnorr.PrivateKey(dataRepresentation: scalar).xonly.bytes).hex
        let secret: Data
        if let existing = try secrets.read() { secret = existing } else {
            let created = try random(32)
            try secrets.write(created)
            secret = created
        }
        let salt = try random(16)
        guard let combined = try AES.GCM.seal(scalar, using: key(pin: pin, secret: secret, salt: salt)).combined else { throw IdentityError.invalidVault }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        guard !exists else { throw IdentityError.exists }
        let envelope = Envelope(salt: salt, sealed: combined, publicKeyHex: pubkey)
        #if os(iOS)
        try JSONEncoder().encode(envelope).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try JSONEncoder().encode(envelope).write(to: url, options: [.atomic])
        #endif
        clear = scalar
        publicKeyHex = pubkey
    }

    public func unlock(pin: String) throws {
        lock()
        guard exists else { throw IdentityError.missing }
        guard Self.validPIN(pin) else { throw IdentityError.invalidPIN }
        guard let secret = try secrets.read() else { throw IdentityError.keychainUnavailable }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.version == 1, envelope.iterations == 210_000, envelope.salt.count == 16 else { throw IdentityError.invalidVault }
            let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key(pin: pin, secret: secret, salt: envelope.salt))
            guard opened.count == 32,
                  try Data(P256K.Schnorr.PrivateKey(dataRepresentation: opened).xonly.bytes).hex == envelope.publicKeyHex else { throw IdentityError.invalidVault }
            clear = opened
            publicKeyHex = envelope.publicKeyHex
        } catch { throw IdentityError.invalidVault }
    }

    public func lock() {
        if clear != nil { clear!.resetBytes(in: 0..<clear!.count) }
        clear = nil
    }

    /// Removes only this app's sealed identity. The per-install secret is retained.
    public func remove() throws {
        lock()
        if exists { try FileManager.default.removeItem(at: url) }
        publicKeyHex = nil
    }

    public func sign(_ template: NostrEventTemplate) throws -> NostrEvent {
        guard let clear else { throw IdentityError.locked }
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: clear)
        let pubkey = Data(key.xonly.bytes).hex
        let id = NostrSerialization.eventId(pubkey: pubkey, template: template)
        var digest = Array(Data(hex: id)!)
        var auxiliary = Array(try random(32))
        defer { for i in auxiliary.indices { auxiliary[i] = 0 } }
        let signature = try key.signature(message: &digest, auxiliaryRand: &auxiliary)
        return NostrEvent(id: id, pubkey: pubkey, created_at: template.createdAt, kind: template.kind,
                          tags: template.tags, content: template.content, sig: Data(signature.dataRepresentation).hex)
    }
}

/// Signs and verifies events. Implementations must keep secret material inside.
public protocol EventSigner: Sendable {
    func sign(_ template: NostrEventTemplate) async throws -> NostrEvent
    func publicKeyHex() async throws -> String
}

public enum IdentityState: Sendable, Equatable {
    case none
    case locked(npub: String)
    case unlocked(npub: String)

    public var npub: String? {
        switch self {
        case .none: nil
        case .locked(let npub), .unlocked(let npub): npub
        }
    }
}

/// Actor isolating the vault: PBKDF2 and Schnorr signing never run on the main actor.
public actor IdentityService: EventSigner {
    private let vault: IdentityVault

    public init(vaultURL: URL, secrets: VaultSecretStore = KeychainVaultSecretStore()) {
        vault = IdentityVault(url: vaultURL, secrets: secrets)
    }

    public var state: IdentityState {
        guard vault.exists, let hex = vault.publicKeyHex, let npub = NostrKeys.npub(publicKeyHex: hex) else { return .none }
        return vault.isUnlocked ? .unlocked(npub: npub) : .locked(npub: npub)
    }

    @discardableResult public func importIdentity(nsec: String, pin: String) throws -> IdentityState {
        try vault.create(nsec: nsec, pin: pin)
        return state
    }

    @discardableResult public func unlock(pin: String) throws -> IdentityState {
        try vault.unlock(pin: pin)
        return state
    }

    @discardableResult public func lock() -> IdentityState {
        vault.lock()
        return state
    }

    @discardableResult public func remove() throws -> IdentityState {
        try vault.remove()
        return state
    }

    public func sign(_ template: NostrEventTemplate) throws -> NostrEvent { try vault.sign(template) }

    public func publicKeyHex() throws -> String {
        guard vault.isUnlocked, let hex = vault.publicKeyHex else { throw IdentityError.locked }
        return hex
    }

    /// Throws unless the unlocked identity is exactly `npub` (connection binding).
    public func requireSigner(npub: String) throws {
        guard case .unlocked(let current) = state else { throw IdentityError.locked }
        guard current == npub else { throw IdentityError.signerMismatch }
    }
}

public enum SignatureVerifier {
    /// BIP-340 verification of a NIP-01 event (id recomputed from content).
    public static func verify(_ event: NostrEvent) -> Bool {
        let template = NostrEventTemplate(kind: event.kind, tags: event.tags, content: event.content, createdAt: event.created_at)
        guard NostrSerialization.eventId(pubkey: event.pubkey, template: template) == event.id,
              let pub = Data(hex: event.pubkey), pub.count == 32, let sig = Data(hex: event.sig), sig.count == 64,
              var digest = Data(hex: event.id).map({ Array($0) }),
              let signature = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: sig) else { return false }
        return P256K.Schnorr.XonlyKey(dataRepresentation: pub).isValid(signature, for: &digest)
    }
}
