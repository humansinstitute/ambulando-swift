import Foundation

/// A typed failure of the hosted-backup flow. Nothing here carries a key, password or ciphertext.
public struct HostedBackupFailure: LocalizedError, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case usernameInvalid, usernameUnavailable, alreadyBackedUp, ownerMismatch, revisionConflict, invalidBackup, rateLimited
        case notFound, signerRefused, backendMissing, network, server, malformed
        /// What the server holds is not what was uploaded, or does not open to this identity with this password.
        case readbackMismatch, existingBackupDoesNotOpen
        case notEligible, persistence, passwordTooShort
    }
    public let kind: Kind
    public let status: Int?
    public let code: String?
    public init(kind: Kind, status: Int? = nil, code: String? = nil) { self.kind = kind; self.status = status; self.code = code }

    /// Safe to repeat: the staged upload is replayed byte for byte.
    public var retryable: Bool { [.network, .server, .rateLimited].contains(kind) }

    public var errorDescription: String? {
        switch kind {
        case .usernameInvalid: "Use 3–32 lowercase letters, digits, “-” or “_”, starting and ending with a letter or digit. Some names are reserved."
        case .usernameUnavailable: "That username is taken. Choose another one."
        case .alreadyBackedUp: "This identity already has a hosted backup under a different username."
        case .ownerMismatch: "That username belongs to a different identity."
        case .revisionConflict: "The hosted backup changed elsewhere. Check it again."
        case .invalidBackup: "The NStack refused this backup as malformed."
        case .rateLimited: "Too many tries. Wait a moment, then try again."
        case .notFound: "No hosted backup was found for that username."
        case .signerRefused: "The NStack did not accept this identity's signature."
        case .backendMissing: "This NStack does not offer hosted identity backup. The hosted copy is not confirmed, and paid setup stays off for a new identity."
        case .network: "Could not reach the NStack. Your staged backup is kept; try again."
        case .server: "The NStack had a problem (HTTP \(status ?? 0)). Try again shortly."
        case .malformed: "The NStack sent an unexpected answer. The hosted backup is not confirmed."
        case .readbackMismatch: "The NStack returned something different from what was uploaded. The hosted backup is not confirmed."
        case .existingBackupDoesNotOpen: "A hosted backup already exists for this identity, but it does not open with this password to this identity. Nothing was changed."
        case .notEligible: "Only an identity created in this app has a required hosted backup."
        case .passwordTooShort: "Choose a long, unique backup password of at least 16 characters."
        case .persistence: "This device could not record the backup step, so nothing further was sent. Free some space and try again."
        }
    }

    static func classify(status: Int, code: String?) -> HostedBackupFailure {
        let kind: Kind
        switch (status, code) {
        case (404, "backup_not_found"): kind = .notFound
        case (404, _), (405, _): kind = .backendMissing
        case (_, "invalid_username"): kind = .usernameInvalid
        case (_, "username_unavailable"): kind = .usernameUnavailable
        case (_, "identity_already_backed_up"): kind = .alreadyBackedUp
        case (_, "backup_owner_mismatch"): kind = .ownerMismatch
        case (_, "revision_conflict"): kind = .revisionConflict
        case (_, "invalid_backup"), (_, "invalid_json"), (_, "body_too_large"): kind = .invalidBackup
        case (429, _): kind = .rateLimited
        case (401, _), (403, _): kind = .signerRefused
        case (500..., _): kind = .server
        default: kind = .malformed
        }
        return HostedBackupFailure(kind: kind, status: status, code: code)
    }
}

public enum HostedBackupUsername {
    /// Server rule (hosted-identity-backup-v1): NFKC then lowercase, `^[a-z0-9][a-z0-9_-]{1,30}[a-z0-9]$`, minus a reserved set.
    public static let reserved: Set<String> = ["admin", "support", "nstack", "wingman", "root", "system"]

    public static func normalized(_ raw: String) -> String? {
        let name = raw.precomposedStringWithCompatibilityMapping.lowercased()
        guard name.range(of: "^[a-z0-9][a-z0-9_-]{1,30}[a-z0-9]$", options: .regularExpression) != nil, !reserved.contains(name) else { return nil }
        return name
    }
}

/// Signed/public client for `/api/v4/identity-backup` (tower docs/contract/hosted-identity-backup-v1.md). The server stores only the
/// opaque `ncryptsec`; it never sees a password or plaintext key. Writes and `/me` are strict NIP-98; the public read is unsigned.
public struct HostedBackupAPI: Sendable {
    public static let base = "/api/v4/identity-backup"
    public static let ncryptsecLength = 162
    let client: TowerClient
    let transport: HTTPTransport
    /// The scrypt cost range the server accepts. The contract fixes it at 16...18; only tests narrow it (via the internal init).
    let acceptedLogN: ClosedRange<UInt8>
    public var origin: TowerOrigin { client.origin }

    public init(origin: TowerOrigin, transport: HTTPTransport, signer: EventSigner?) {
        self.init(origin: origin, transport: transport, signer: signer, acceptedLogN: NIP49.hostedMinLogN...NIP49.maxLogN)
    }

    init(origin: TowerOrigin, transport: HTTPTransport, signer: EventSigner?, acceptedLogN: ClosedRange<UInt8>) {
        client = TowerClient(origin: origin, transport: transport, signer: signer); self.transport = transport; self.acceptedLogN = acceptedLogN
    }

    public struct Receipt: Equatable, Sendable { public let username: String; public let revision: String; public let created: Bool }
    public struct Stored: Equatable, Sendable { public let username: String; public let ncryptsec: String; public let revision: String }
    public struct Mine: Equatable, Sendable { public let username: String; public let revision: String }

    private func path(_ username: String) throws -> String {
        guard let name = HostedBackupUsername.normalized(username), name == username else { throw HostedBackupFailure(kind: .usernameInvalid) }
        return "\(Self.base)/\(name)"
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HostedBackupFailure(kind: .malformed) }
        return value
    }

    private func failure(_ status: Int, _ data: Data) -> HostedBackupFailure {
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return .classify(status: status, code: body?["code"] as? String)
    }

    /// The ciphertext shape the server accepts, checked before anything is sent: exactly 162 chars, lowercase, v2, logN 16...18.
    func uploadable(_ ncryptsec: String) -> Bool {
        guard ncryptsec.count == Self.ncryptsecLength, ncryptsec == ncryptsec.lowercased(), ncryptsec.hasPrefix("ncryptsec1"),
              let decoded = Bech32.decode(ncryptsec, maxLength: Self.ncryptsecLength), decoded.hrp == "ncryptsec", decoded.data.count == NIP49.payloadLength else { return false }
        let bytes = Array(decoded.data)
        return bytes[0] == NIP49.version && acceptedLogN.contains(bytes[1]) && bytes[42] <= 2
    }

    /// Creates (`expectedRevision == "0"`) or updates under compare-and-swap. A replay of the identical body is answered 200 with the
    /// same revision, so a lost response is recovered by sending exactly the staged body again.
    public func put(username: String, ncryptsec: String, expectedRevision: String) async throws -> Receipt {
        let target = try path(username)
        guard uploadable(ncryptsec), expectedRevision.range(of: "^(0|[1-9][0-9]{0,15})$", options: .regularExpression) != nil else {
            throw HostedBackupFailure(kind: .invalidBackup)
        }
        let body = try JSONSerialization.data(withJSONObject: ["ncryptsec": ncryptsec, "expected_revision": expectedRevision], options: [.sortedKeys])
        let (status, data) = try await exchange("PUT", target, body)
        guard (200..<300).contains(status) else { throw failure(status, data) }
        let value = try object(data)
        guard let name = value["username"] as? String, let revision = value["revision"] as? String, name == username else { throw HostedBackupFailure(kind: .malformed) }
        return Receipt(username: name, revision: revision, created: status == 201)
    }

    /// Public, unauthenticated: ciphertext and revision only. Anyone can fetch it; only the password opens it.
    public func fetch(username: String) async throws -> Stored {
        var request = URLRequest(url: try origin.url(path: try path(username)))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else { throw failure(status, data) }
        let value = try object(data)
        guard let name = value["username"] as? String, name == username, let text = value["ncryptsec"] as? String, text.count == Self.ncryptsecLength,
              let revision = value["revision"] as? String else { throw HostedBackupFailure(kind: .malformed) }
        return Stored(username: name, ncryptsec: text, revision: revision)
    }

    /// Owner-signed proof that this identity has a hosted copy (no ciphertext). `nil` means none.
    public func mine() async throws -> Mine? {
        let (status, data) = try await exchange("GET", Self.base + "/me", nil)
        if status == 404, (try? object(data))?["code"] as? String == "backup_not_found" { return nil }
        guard (200..<300).contains(status) else { throw failure(status, data) }
        let value = try object(data)
        guard let name = value["username"] as? String, HostedBackupUsername.normalized(name) == name, let revision = value["revision"] as? String else { throw HostedBackupFailure(kind: .malformed) }
        return Mine(username: name, revision: revision)
    }

    private func exchange(_ method: String, _ path: String, _ body: Data?) async throws -> (Int, Data) {
        do {
            let result = try await client.exchange(method: method, path: path, appNpub: nil, jsonBody: body)
            return (result.status, result.body)
        } catch is CancellationError { throw CancellationError() }
        catch let error as IdentityError { throw error }
        catch { throw HostedBackupFailure(kind: .network) }
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do { let (data, response) = try await transport.send(request); return (data, response.statusCode) }
        catch is CancellationError { throw CancellationError() }
        catch { throw HostedBackupFailure(kind: .network) }
    }
}

/// The durable hosted-backup sequence for an identity created in this app:
/// 1. encrypt the key under the user's password (scrypt cost 16...18) and decrypt it back locally;
/// 2. stage username + exact ciphertext on disk **before** the upload, so a lost response replays the identical body;
/// 3. PUT with compare-and-swap, then read back the public ciphertext and the owner-signed `/me`, and require them to match the
///    acknowledged write (a `/me` alone proves a row exists, not that it holds the right bytes);
/// 4. decrypt the read-back ciphertext with the password and require it to be this identity's key;
/// 5. only then record the hosted copy as confirmed, which is what lets paid setup start.
public struct HostedBackupSaver: Sendable {
    let origin: TowerOrigin
    let transport: HTTPTransport
    let identity: IdentityService
    let logN: UInt8
    let acceptedLogN: ClosedRange<UInt8>

    public init(origin: TowerOrigin, transport: HTTPTransport, identity: IdentityService, logN: UInt8 = NIP49.defaultLogN) {
        self.init(origin: origin, transport: transport, identity: identity, logN: logN, acceptedLogN: NIP49.hostedMinLogN...NIP49.maxLogN)
    }

    init(origin: TowerOrigin, transport: HTTPTransport, identity: IdentityService, logN: UInt8, acceptedLogN: ClosedRange<UInt8>) {
        self.origin = origin; self.transport = transport; self.identity = identity; self.logN = logN; self.acceptedLogN = acceptedLogN
    }

    public struct Confirmation: Equatable, Sendable { public let username: String; public let revision: String }

    public func save(username requested: String, password: String) async throws -> Confirmation {
        guard let username = HostedBackupUsername.normalized(requested) else { throw HostedBackupFailure(kind: .usernameInvalid) }
        guard case .unlocked(let npub) = await identity.state, let hex = NostrKeys.publicKeyHex(npub: npub) else { throw IdentityError.locked }
        // Every request is signed through a wrapper that refuses any other identity, even if one is imported mid-sequence.
        let api = HostedBackupAPI(origin: origin, transport: transport, signer: BoundSigner(inner: identity, expectedHex: hex), acceptedLogN: acceptedLogN)
        guard let record = await identity.backupRecord(), record.origin == .created, record.localBackupConfirmedAt != nil else { throw HostedBackupFailure(kind: .notEligible) }
        guard record.npub == npub else { throw IdentityError.accountMismatch }
        if record.hostedBackupConfirmedAt != nil, record.hostedOrigin == origin.description, let name = record.hostedUsername, let revision = record.hostedRevision {
            return Confirmation(username: name, revision: revision)   // already durable; never uploads a second time
        }
        let mine = try await api.mine()
        var uploaded: String?
        var target: (username: String, revision: String)
        if let mine {
            // The server already holds a hosted copy for this identity (an earlier upload whose answer was lost, or another device).
            // It is verified, never overwritten.
            if let attempt = record.hostedAttempt, attempt.origin == origin.description, attempt.username == mine.username { uploaded = attempt.ncryptsec }
            target = (mine.username, mine.revision)
        } else {
            var attempt = record.hostedAttempt
            if attempt == nil || attempt?.origin != origin.description || attempt?.username != username {
                guard password.count >= 16 else { throw HostedBackupFailure(kind: .passwordTooShort) }
                // `/me` says nothing was stored for this identity, so an older staged attempt never landed: replace it.
                let fresh = try await identity.exportBackup(password: password, logN: logN)
                var opened = try await NIP49.decrypt(fresh, password: password).secretKey
                defer { opened.resetBytes(in: 0..<opened.count) }
                guard (try? NewIdentity.npub(secret: opened)) == npub else { throw HostedBackupFailure(kind: .readbackMismatch) }
                attempt = IdentityBackupRecord.HostedAttempt(username: username, ncryptsec: fresh, expectedRevision: "0", origin: origin.description)
                try Task.checkCancellation()
                do { try await identity.stageHostedAttempt(attempt!, expectedNpub: npub) }
                catch let error as IdentityError { throw error }
                catch { throw HostedBackupFailure(kind: .persistence) }
            }
            let receipt = try await api.put(username: attempt!.username, ncryptsec: attempt!.ncryptsec, expectedRevision: attempt!.expectedRevision)
            uploaded = attempt!.ncryptsec
            target = (receipt.username, receipt.revision)
        }
        let stored = try await api.fetch(username: target.username)
        guard stored.username == target.username, stored.revision == target.revision else { throw HostedBackupFailure(kind: .readbackMismatch) }
        if let uploaded, stored.ncryptsec != uploaded { throw HostedBackupFailure(kind: .readbackMismatch) }
        guard let proof = try await api.mine(), proof.username == target.username, proof.revision == target.revision else { throw HostedBackupFailure(kind: .readbackMismatch) }
        var opened: Data
        do { opened = try await NIP49.decrypt(stored.ncryptsec, password: password).secretKey }
        catch { throw HostedBackupFailure(kind: uploaded == nil ? .existingBackupDoesNotOpen : .readbackMismatch) }
        defer { opened.resetBytes(in: 0..<opened.count) }
        guard (try? NewIdentity.npub(secret: opened)) == npub else { throw HostedBackupFailure(kind: uploaded == nil ? .existingBackupDoesNotOpen : .readbackMismatch) }
        try Task.checkCancellation()
        do { try await identity.confirmHostedBackup(username: target.username, revision: target.revision, origin: origin.description, expectedNpub: npub) }
        catch let error as IdentityError { throw error }
        catch { throw HostedBackupFailure(kind: .persistence) }
        return Confirmation(username: target.username, revision: target.revision)
    }
}
