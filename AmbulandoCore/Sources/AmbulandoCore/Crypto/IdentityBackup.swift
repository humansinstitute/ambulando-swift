import Foundation
import P256K

/// A freshly generated identity. The secret exists only in memory until the vault stores it.
public enum NewIdentity {
    /// Secure random 32 bytes (SecRandomCopyBytes), redrawn until they are a valid secp256k1 scalar.
    public static func generateSecret() throws -> Data {
        for _ in 0..<16 {
            var candidate = try NIP49.random(32)
            if NostrKeys.isValidScalar(candidate) { return candidate }
            candidate.resetBytes(in: 0..<candidate.count)
        }
        throw NIP49Error.randomUnavailable
    }

    public static func npub(secret: Data) throws -> String {
        let hex = try Data(P256K.Schnorr.PrivateKey(dataRepresentation: secret).xonly.bytes).hex
        guard let npub = NostrKeys.npub(publicKeyHex: hex) else { throw IdentityError.invalidNsec }
        return npub
    }
}

/// What hosted (username-retrievable) key backup honestly is. The client is written against the committed NStack source contract
/// (tower docs/contract/hosted-identity-backup-v1.md); no live NStack has been exercised, so the app never claims recovery works
/// until the save sequence itself has read the stored copy back and decrypted it to this identity.
public enum HostedBackup {
    public static let requirementNotice = "A new identity also needs a hosted backup: your encrypted key stored on your NStack under a username you choose, so you can get it back with the username and your backup password. A saved file or your PIN does not replace it, and paid setup stays off until it is saved and checked."
    public static let residualRisk = "Anyone who knows the username can download the encrypted key and try passwords offline, so use a long, unique backup password. NStack never sees the password, and cannot reset it: forget it and the key is gone."
}

/// Why paid setup is or is not allowed for the unlocked identity.
public enum PaymentBackupGate: Equatable, Sendable {
    case allowed
    /// A newly created identity has no confirmed, verified local encrypted backup.
    case localBackupRequired
    /// A newly created identity has its local backup, but the hosted username backup is a separate requirement that is not done.
    case hostedBackupRequired
}

/// Public facts about how this device's identity came to be and which backups the user confirmed. No secret is stored here, and
/// nothing here is part of an onboarding draft.
public struct IdentityBackupRecord: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case created, imported }
    public var npub: String
    public var origin: Origin
    public var localBackupConfirmedAt: Date?
    public var hostedBackupConfirmedAt: Date?
    public var hostedUsername: String?
    public var hostedRevision: String?
    public var hostedOrigin: String?
    /// The exact upload in flight (username and ciphertext, which is encrypted and meant to be stored remotely). It is saved before the
    /// request so a lost response is recovered by replaying the identical body; it never holds a password or plaintext key.
    public var hostedAttempt: HostedAttempt?

    public struct HostedAttempt: Codable, Equatable, Sendable {
        public var username: String
        public var ncryptsec: String
        public var expectedRevision: String
        public var origin: String?
        public init(username: String, ncryptsec: String, expectedRevision: String, origin: String? = nil) {
            self.username = username; self.ncryptsec = ncryptsec; self.expectedRevision = expectedRevision; self.origin = origin
        }
    }

    public init(npub: String, origin: Origin, localBackupConfirmedAt: Date? = nil, hostedBackupConfirmedAt: Date? = nil) {
        self.npub = npub; self.origin = origin
        self.localBackupConfirmedAt = localBackupConfirmedAt; self.hostedBackupConfirmedAt = hostedBackupConfirmedAt
    }

    /// Imported identities (and any key with no record) keep their existing behaviour: nothing is forced on them.
    public var gate: PaymentBackupGate {
        guard origin == .created else { return .allowed }
        guard localBackupConfirmedAt != nil else { return .localBackupRequired }
        return hostedBackupConfirmedAt != nil ? .allowed : .hostedBackupRequired
    }

    public func gate(for origin: String) -> PaymentBackupGate {
        let result = gate
        guard self.origin == .created, result == .allowed else { return result }
        return hostedOrigin == origin ? .allowed : .hostedBackupRequired
    }
}

public struct IdentityBackupStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The record for `npub`, nil if there is none. A file that exists but cannot be read or belongs to another key is `.unreadable`,
    /// which callers treat as "not allowed" rather than "no record".
    public enum Reading: Equatable, Sendable { case none, record(IdentityBackupRecord), unreadable }

    public func read(npub: String) -> Reading {
        guard exists else { return .none }
        guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(IdentityBackupRecord.self, from: data) else { return .unreadable }
        return record.npub == npub ? .record(record) : .none
    }

    public func save(_ record: IdentityBackupRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    public func remove() throws {
        if exists { try FileManager.default.removeItem(at: url) }
    }
}
