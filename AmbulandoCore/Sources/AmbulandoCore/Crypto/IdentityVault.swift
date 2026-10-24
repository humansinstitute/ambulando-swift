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
    public init(service: String = ProductionStorage.vaultSecretService) { self.service = service }

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
        reload()
    }

    /// Reads the public key from the sealed envelope if it is not known yet. The envelope is written with complete file
    /// protection, so while the iPhone is locked (a background launch, or an install that launched the app on a locked
    /// phone) it exists but cannot be read. That is `unreadable`, never a missing identity; reading again once the
    /// iPhone is unlocked recovers it. Nothing here writes, moves or deletes the vault.
    public func reload() {
        guard publicKeyHex == nil, exists else { return }
        publicKeyHex = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }?.publicKeyHex
    }

    /// A vault file exists but its public key could not be read (protected data unavailable, or damaged).
    public var unreadable: Bool { exists && publicKeyHex == nil }

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

    /// Unlocks from a stored session key, only if it is this vault's key.
    func unlock(secretKey: Data) throws {
        guard exists, let expected = publicKeyHex, secretKey.count == 32,
              try Data(P256K.Schnorr.PrivateKey(dataRepresentation: secretKey).xonly.bytes).hex == expected else { throw IdentityError.invalidVault }
        lock()
        clear = Data(secretKey)
    }

    /// Removes only this app's sealed identity. The per-install secret is retained.
    public func remove() throws {
        lock()
        if exists { try FileManager.default.removeItem(at: url) }
        publicKeyHex = nil
    }

    /// A copy of the unlocked key for the user-enabled background credential only.
    func secretCopy() throws -> Data {
        guard let clear else { throw IdentityError.locked }
        return Data(clear)
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
    /// An identity vault is on this device but cannot be read right now (the iPhone is locked, or the file is damaged).
    /// It is never treated as `.none`: no import is offered, nothing is replaced, and it is read again when possible.
    case unavailable
    case locked(npub: String)
    case unlocked(npub: String)

    public var npub: String? {
        switch self {
        case .none, .unavailable: nil
        case .locked(let npub), .unlocked(let npub): npub
        }
    }
}

/// Actor isolating the vault: PBKDF2 and Schnorr signing never run on the main actor.
///
/// Two signing capabilities exist. The unlocked vault signs anything the app asks for. The optional background
/// credential (see `BackgroundReadCredential`) is used only when the vault is locked, and only for NIP-98 GETs its
/// policy allows; `state` still reports `.locked`, so the UI never treats it as an unlock.
public actor IdentityService: EventSigner {
    private let vault: IdentityVault
    private let backgroundStore: BackgroundCredentialStore?
    private var reader: BackgroundReader?
    /// Trusted-device session: the unlocked key kept in a device-only Keychain item readable only while the iPhone
    /// itself is unlocked, so the app stays unlocked across relaunch until Lock now / remove / disconnect.
    private let sessionStore: SessionKeyStore?
    private let sessionRevocationURL: URL
    /// Durable revocation marker, written before the Keychain item is deleted. While it exists the credential is never
    /// loaded or used, even if deleting the Keychain item failed (revocation fails closed).
    private let revocationURL: URL
    /// The last revocation could not delete the Keychain item; the marker still blocks it and deletion is retried.
    public private(set) var revocationIncomplete = false

    public init(vaultURL: URL, secrets: VaultSecretStore = KeychainVaultSecretStore(), background: BackgroundCredentialStore? = nil,
                session: SessionKeyStore? = nil) {
        vault = IdentityVault(url: vaultURL, secrets: secrets)
        backgroundStore = background
        sessionStore = session
        revocationURL = vaultURL.deletingLastPathComponent().appendingPathComponent("background-read.revoked")
        sessionRevocationURL = vaultURL.deletingLastPathComponent().appendingPathComponent("session.revoked")
    }

    private var sessionRevoked: Bool { FileManager.default.fileExists(atPath: sessionRevocationURL.path) }

    /// Writes the session revocation marker first, then deletes the Keychain item (fails closed like the background
    /// credential). Throws only if neither could be done.
    private func revokeSession() throws {
        guard let sessionStore else { return }
        var markerWritten = sessionRevoked
        if !markerWritten {
            try? FileManager.default.createDirectory(at: sessionRevocationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            markerWritten = (try? Data("revoked".utf8).write(to: sessionRevocationURL, options: [.atomic])) != nil
        }
        do { try sessionStore.delete() } catch {
            revocationIncomplete = true
            if !markerWritten { throw IdentityError.keychainUnavailable }
        }
    }

    /// Keeps the unlocked key for the trusted-device session (after a PIN unlock or import).
    private func storeSession() {
        guard let sessionStore, let hex = vault.publicKeyHex, let key = try? vault.secretCopy() else { return }
        guard (try? sessionStore.write(SessionKey(publicKeyHex: hex, secretKey: key))) != nil else { return }
        try? FileManager.default.removeItem(at: sessionRevocationURL)
    }

    /// Resumes the trusted-device session at launch: unlocked without the PIN only if a session key exists for this
    /// identity and was not revoked by Lock now, remove or disconnect. Returns whether the identity is now unlocked.
    @discardableResult public func resumeSession() -> Bool {
        if vault.isUnlocked { return true }
        vault.reload()
        guard let sessionStore, !sessionRevoked, let stored = try? sessionStore.read(), stored.publicKeyHex == vault.publicKeyHex,
              (try? vault.unlock(secretKey: stored.secretKey)) != nil else {
            if sessionRevoked, (try? sessionStore?.read()) != nil { try? sessionStore?.delete() }   // finish an earlier failed delete
            return false
        }
        return true
    }

    /// Ends the trusted-device session without locking the identity in memory (disconnect).
    public func endSession() throws { try revokeSession() }

    private var revoked: Bool { FileManager.default.fileExists(atPath: revocationURL.path) }

    /// Revokes the background credential: memory first, then the durable marker, then the Keychain item. Throws only
    /// if the marker could not be written either (nothing then guarantees revocation, so the caller must report it).
    private func revokeBackgroundRead() throws {
        reader = nil
        guard let backgroundStore else { return }
        var markerWritten = revoked
        if !markerWritten {
            try? FileManager.default.createDirectory(at: revocationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            markerWritten = (try? Data("revoked".utf8).write(to: revocationURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
            #else
            markerWritten = (try? Data("revoked".utf8).write(to: revocationURL, options: [.atomic])) != nil
            #endif
        }
        do {
            try backgroundStore.delete()
            revocationIncomplete = false
        } catch {
            revocationIncomplete = true
            if !markerWritten { throw IdentityError.keychainUnavailable }
        }
    }

    public var state: IdentityState {
        guard vault.exists else { return .none }
        vault.reload()
        guard let hex = vault.publicKeyHex, let npub = NostrKeys.npub(publicKeyHex: hex) else { return .unavailable }
        return vault.isUnlocked ? .unlocked(npub: npub) : .locked(npub: npub)
    }

    /// True while reads can be signed without the PIN (background credential loaded, matching, not revoked).
    public var canReadWhileLocked: Bool { reader != nil && !revoked }

    /// Whether a usable background credential is stored for this identity (it may not be loaded yet).
    public var backgroundReadEnabled: Bool {
        guard !revoked, let stored = try? backgroundStore?.read() else { return false }
        return stored.publicKeyHex == vault.publicKeyHex
    }

    /// Reads the vault and the trusted-device session again (scene became active, protected data became available).
    /// A launch while the iPhone was locked could read neither; this recovers both without the PIN when allowed.
    @discardableResult public func refreshAvailability() -> IdentityState {
        vault.reload()
        if vault.publicKeyHex != nil { resumeSession() }
        return state
    }

    @discardableResult public func importIdentity(nsec: String, pin: String) throws -> IdentityState {
        try vault.create(nsec: nsec, pin: pin)
        storeSession()
        return state
    }

    @discardableResult public func unlock(pin: String) throws -> IdentityState {
        try vault.unlock(pin: pin)
        storeSession()
        return state
    }

    /// Manual lock. Also revokes the background credential: nothing is signed until the PIN is entered again. The
    /// vault is always locked; a revocation that could not be recorded at all is reported by `revocationIncomplete`.
    @discardableResult public func lock() -> IdentityState {
        vault.lock()
        do { try revokeSession() } catch { revocationIncomplete = true }
        do { try revokeBackgroundRead() } catch { revocationIncomplete = true }
        return state
    }

    @discardableResult public func remove() throws -> IdentityState {
        try revokeSession()
        try revokeBackgroundRead()
        try vault.remove()
        return state
    }

    /// Stores the background credential for `origin` and the given workspaces. Requires the unlocked vault.
    public func enableBackgroundRead(origin: TowerOrigin, workspaceIds: [String]) throws {
        guard let backgroundStore else { throw IdentityError.keychainUnavailable }
        guard let hex = vault.publicKeyHex else { throw IdentityError.missing }
        let credential = BackgroundReadCredential(publicKeyHex: hex, secretKey: try vault.secretCopy(), origin: origin.description,
                                                  workspaceIds: workspaceIds.compactMap(lowerUUID).sorted(),
                                                  createdAt: ISO8601DateFormatter().string(from: Date()))
        try backgroundStore.write(credential)
        // The marker is removed only once the new credential is stored, so a failed enable never un-revokes an old one.
        try? FileManager.default.removeItem(at: revocationURL)
        guard !revoked else { throw IdentityError.keychainUnavailable }
        reader = BackgroundReader(credential: credential)
        revocationIncomplete = false
    }

    public func disableBackgroundRead() throws { try revokeBackgroundRead() }

    /// Updates the pinned workspaces (after discovery while unlocked). Only an existing credential is changed.
    public func updateBackgroundWorkspaces(origin: TowerOrigin, workspaceIds: [String]) throws {
        guard vault.isUnlocked, !revoked, let backgroundStore, let stored = try backgroundStore.read(), stored.publicKeyHex == vault.publicKeyHex,
              stored.origin == origin.description else { return }
        let ids = workspaceIds.compactMap(lowerUUID).sorted()
        guard ids != stored.workspaceIds else { return }
        var updated = stored
        updated.workspaceIds = ids
        try backgroundStore.write(updated)
        reader = BackgroundReader(credential: updated)
    }

    /// Loads a stored background credential if it belongs to this identity (launch, including background launch).
    @discardableResult public func loadBackgroundRead() -> Bool {
        if revoked {
            // Revoked earlier: never load, and finish deleting the Keychain item if that failed before.
            reader = nil
            if revocationIncomplete || (try? backgroundStore?.read()) != nil { try? revokeBackgroundRead() }
            return false
        }
        guard reader == nil else { return true }
        guard let stored = try? backgroundStore?.read(), stored.publicKeyHex == vault.publicKeyHex else { return false }
        reader = BackgroundReader(credential: stored)
        return true
    }

    public func backgroundPolicy() -> ReadPolicy? { revoked ? nil : reader?.credential.policy }

    public func sign(_ template: NostrEventTemplate) throws -> NostrEvent {
        if vault.isUnlocked { return try vault.sign(template) }
        guard let reader, !revoked else { throw IdentityError.locked }
        return try reader.sign(template)
    }

    public func publicKeyHex() throws -> String {
        if vault.isUnlocked, let hex = vault.publicKeyHex { return hex }
        if let reader, !revoked { return reader.credential.publicKeyHex }
        throw IdentityError.locked
    }

    /// Throws unless the unlocked identity is exactly `npub` (connection binding). Required for every write.
    public func requireSigner(npub: String) throws {
        guard case .unlocked(let current) = state else { throw IdentityError.locked }
        guard current == npub else { throw IdentityError.signerMismatch }
    }

    /// Like `requireSigner`, but also satisfied by the background credential of the same identity. For read jobs only;
    /// the credential's policy still refuses anything but GETs on its pinned origin and workspaces.
    public func requireReader(npub: String) throws {
        if case .unlocked = state { return try requireSigner(npub: npub) }
        guard let reader, !revoked else { throw IdentityError.locked }
        guard reader.npub == npub else { throw IdentityError.signerMismatch }
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
