import AmbulandoCore
import Foundation

/// New-identity creation, encrypted (NIP-49) backup import/export and the paid-setup gate. The key and passwords stay inside
/// `IdentityService`; this layer only sequences explicit user actions and reports failures. Not offered in Grandparent Chat.
extension AppModel {
    /// A new identity is only ever created on a device with no identity and no Tower connection (never a replacement or a switch).
    var canCreateIdentity: Bool { !Product.isGrandparentChat && fixture == nil && identity == .none && connection == nil }
    var canImportBackup: Bool { !Product.isGrandparentChat && identity == .none }

    func beginNewIdentity() async throws -> String {
        guard canCreateIdentity, let sync else { throw IdentityError.exists }
        return try await sync.identity.beginNewIdentity().npub
    }

    func createPendingBackup(password: String) async throws -> String {
        guard let sync else { throw IdentityError.missing }
        return try await sync.identity.createPendingBackup(password: password)
    }

    func notePendingBackupExported() async {
        try? await sync?.identity.notePendingBackupExported()
    }

    func acknowledgePendingBackup(password: String) async throws {
        guard let sync else { throw IdentityError.missing }
        try await sync.identity.acknowledgePendingBackup(password: password)
    }

    func discardNewIdentity() async { await sync?.identity.discardNewIdentity() }

    /// The public ciphertext stored on an NStack for `username` (no signature, no key). Decrypting it still needs the password.
    func fetchHostedBackup(origin: String, username: String) async throws -> String {
        guard let sync else { throw IdentityError.missing }
        let api = HostedBackupAPI(origin: try TowerOrigin(origin), transport: sync.transport, signer: nil)
        return try await api.fetch(username: username).ncryptsec
    }

    /// Explicit user export of the unlocked identity under a password they choose; nothing is written until they copy or save it.
    func exportIdentityBackup(password: String) async throws -> String {
        guard let sync, isUnlocked else { throw IdentityError.locked }
        return try await sync.identity.exportBackup(password: password)
    }
}
