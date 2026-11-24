import CryptoSwift
import Foundation
import P256K
import Security

public enum NIP49Error: LocalizedError, Equatable, Sendable {
    case malformed, unsupportedVersion, costOutOfRange, passwordRejected, wrongPasswordOrDamaged, invalidKey, randomUnavailable, cryptoUnavailable

    public var errorDescription: String? {
        switch self {
        case .malformed: "This is not a valid encrypted key backup (ncryptsec)."
        case .unsupportedVersion: "This encrypted backup uses a version this app does not support."
        case .costOutOfRange: "This encrypted backup asks for more (or less) password hashing work than this app accepts."
        case .passwordRejected: "Enter a backup password (at most 512 bytes)."
        case .wrongPasswordOrDamaged: "Wrong password, or the backup was changed or damaged. Nothing was imported."
        case .invalidKey: "The backup does not contain a valid Nostr secret key."
        case .randomUnavailable: "The system could not provide secure random bytes."
        case .cryptoUnavailable: "The encryption library could not be started."
        }
    }
}

/// NIP-49 private key encryption (`ncryptsec`): scrypt (r=8, p=1) over the NFKC-normalised password, XChaCha20-Poly1305 with the
/// key-security byte as associated data. Both primitives come from CryptoSwift 1.9.0 (`Scrypt`, `AEADXChaCha20Poly1305`);
/// nothing here implements them. (swift-sodium's Clibsodium xcframework is a minimal build with no scrypt, so it cannot do this.)
///
/// Honest limits: Swift `Data`/`String` values (the password, the decrypted key) can be copied by the runtime and cannot be
/// guaranteed wiped, and CryptoSwift copies its inputs and frees (does not zero) its scrypt scratch memory. The arrays this type
/// owns (derived key, normalised password, working copies) are overwritten before release, best effort. Keep secrets short-lived.
public enum NIP49 {
    /// Security byte (NIP-49 KEY_SECURITY_BYTE). Newly generated keys that were never shown or copied unencrypted use `.safe`.
    public enum KeySecurity: UInt8, Sendable { case insecure = 0, safe = 1, untracked = 2 }

    public struct Decrypted: Sendable {
        public let secretKey: Data
        public let keySecurity: KeySecurity
    }

    public static let version: UInt8 = 2
    public static let payloadLength = 91
    /// 1 + 1 + 16 + 24 + 1 + (32 + 16) = 91 bytes; `ncryptsec1` + 152 bech32 characters.
    public static let maxEncodedLength = 200
    /// Cost bounds, checked before any scrypt memory is requested (N·r·128 bytes: 2^18 is 256 MiB, 2^16 is 64 MiB). Decrypt accepts
    /// 10...18 (a hostile ncryptsec can never ask for more than 256 MiB); new and hosted backups are 16...18. The default is the
    /// hosted floor: 18 is not used by default because only a Mac has been measured (about 0.75 s in a release build), not an iPhone.
    public static let minLogN: UInt8 = 10
    public static let maxLogN: UInt8 = 18
    public static let hostedMinLogN: UInt8 = 16
    public static let defaultLogN: UInt8 = 16
    public static let maxPasswordBytes = 512

    // MARK: Public API (scrypt runs off the caller's actor)

    /// At most one KDF runs at a time process-wide, so concurrent (or hostile) requests queue instead of each allocating up to 256 MiB.
    private actor KDFGate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func acquire() async {
            if !busy { busy = true; return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
    }
    private static let gate = KDFGate()

    public static func encrypt(secretKey: Data, password: String, logN: UInt8 = defaultLogN, keySecurity: KeySecurity = .safe) async throws -> String {
        try await serialized { try seal(secretKey: secretKey, password: password, logN: logN, keySecurity: keySecurity) }
    }

    public static func decrypt(_ ncryptsec: String, password: String) async throws -> Decrypted {
        try await serialized { try open(ncryptsec, password: password) }
    }

    private static func serialized<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        await gate.acquire()
        let result: Result<T, Error> = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
        await gate.release()
        return try result.get()
    }

    // MARK: Synchronous core (blocking; only the async wrappers above and tests call it)

    static func seal(secretKey: Data, password: String, logN: UInt8 = defaultLogN, keySecurity: KeySecurity = .safe) throws -> String {
        try seal(secretKey: secretKey, password: password, logN: logN, keySecurity: keySecurity, salt: try random(16), nonce: try random(24))
    }

    /// Deterministic form for known-answer tests: callers must never reuse a salt or nonce with a real key.
    static func seal(secretKey: Data, password: String, logN: UInt8, keySecurity: KeySecurity, salt: Data, nonce: Data) throws -> String {
        guard (minLogN...maxLogN).contains(logN) else { throw NIP49Error.costOutOfRange }
        guard secretKey.count == 32, validScalar(secretKey), salt.count == 16, nonce.count == 24 else { throw NIP49Error.invalidKey }
        var key = try derive(password: password, salt: salt, logN: logN)
        defer { wipe(&key) }
        var plain = Array(secretKey)
        defer { wipe(&plain) }
        let sealed: (cipherText: [UInt8], authenticationTag: [UInt8])
        do { sealed = try AEADXChaCha20Poly1305.encrypt(plain, key: key, iv: Array(nonce), authenticationHeader: [keySecurity.rawValue]) }
        catch { throw NIP49Error.cryptoUnavailable }
        let cipher = sealed.cipherText + sealed.authenticationTag
        guard cipher.count == 48 else { throw NIP49Error.cryptoUnavailable }
        let associated = [keySecurity.rawValue]
        var payload = Data([version, logN]) + salt + nonce + Data(associated) + Data(cipher)
        defer { payload.resetBytes(in: 0..<payload.count) }
        precondition(payload.count == payloadLength)
        return Bech32.encode(hrp: "ncryptsec", data: payload)
    }

    static func open(_ ncryptsec: String, password: String) throws -> Decrypted {
        // Every bound is checked before scrypt allocates anything or the password is touched.
        guard let decoded = Bech32.decode(ncryptsec, maxLength: maxEncodedLength), decoded.hrp == "ncryptsec" else { throw NIP49Error.malformed }
        let payload = Array(decoded.data)
        guard payload.count == payloadLength else { throw NIP49Error.malformed }
        guard payload[0] == version else { throw NIP49Error.unsupportedVersion }
        let logN = payload[1]
        guard (minLogN...maxLogN).contains(logN) else { throw NIP49Error.costOutOfRange }
        guard let security = KeySecurity(rawValue: payload[42]) else { throw NIP49Error.malformed }
        let salt = Data(payload[2..<18]), nonce = Array(payload[18..<42])
        let associated = [payload[42]]
        let cipher = Array(payload[43..<91])
        var key = try derive(password: password, salt: salt, logN: logN)
        defer { wipe(&key) }
        let opened: (plainText: [UInt8], success: Bool)
        do {
            opened = try AEADXChaCha20Poly1305.decrypt(Array(cipher[0..<32]), key: key, iv: nonce, authenticationHeader: associated,
                                                       authenticationTag: Array(cipher[32..<48]))
        } catch { throw NIP49Error.wrongPasswordOrDamaged }
        var plain = opened.plainText
        defer { wipe(&plain) }
        guard opened.success, plain.count == 32 else { throw NIP49Error.wrongPasswordOrDamaged }
        let secret = Data(plain)
        guard validScalar(secret) else { throw NIP49Error.invalidKey }
        return Decrypted(secretKey: secret, keySecurity: security)
    }

    // MARK: Internals

    /// scrypt(NFKC(password), salt, N=2^logN, r=8, p=1) → 32 bytes, through CryptoSwift.
    private static func derive(password: String, salt: Data, logN: UInt8) throws -> [UInt8] {
        var normalized = Array(password.precomposedStringWithCompatibilityMapping.utf8)
        defer { wipe(&normalized) }
        guard !normalized.isEmpty, normalized.count <= maxPasswordBytes else { throw NIP49Error.passwordRejected }
        do { return try Scrypt(password: normalized, salt: Array(salt), dkLen: 32, N: 1 << Int(logN), r: 8, p: 1).calculate() }
        catch { throw NIP49Error.cryptoUnavailable }
    }

    private static func validScalar(_ data: Data) -> Bool { NostrKeys.isValidScalar(data) }

    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw NIP49Error.randomUnavailable }
        return Data(bytes)
    }

    private static func wipe(_ bytes: inout [UInt8]) {
        for index in bytes.indices { bytes[index] = 0 }
    }
}
