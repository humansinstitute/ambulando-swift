import Foundation

/// Verified read snapshots in the existing workspace store, sealed with the unlocked identity's existing self key.
/// These bytes confer no server authority. The authenticated payload includes the full account/backend/app boundary
/// and slot; moving ciphertext between slots or partitions cannot make it usable. No credential or new key is stored.
struct LocalContentSnapshot: Sendable {
    let store: LocalStore
    let identity: IdentityService
    let boundary: WorkspaceBoundary
    private struct Payload: Codable { let boundary: WorkspaceBoundary; let slot: String; let bytes: Data }
    private struct Envelope: Codable { let chunks: [String]; let digest: String; let workspace: String; let dependencies: [String] }
    private func key(_ slot: String) -> String { "local-content.v1:" + boundary.id + ":" + WorkspaceBoundary.digest([slot]) }
    func read(_ slot: String) async throws -> Data? {
        try await identity.requireSigner(npub: boundary.signerNpub)
        guard let text = try await store.reader.state(key(slot)), let encoded = text.data(using: .utf8) else { return nil }
        let envelope = try JSONDecoder().decode(Envelope.self, from: encoded)
        guard envelope.chunks.count <= 512 else { return nil }
        var bytes = Data()
        for chunk in envelope.chunks { bytes.append(try await identity.decryptWorkspaceIndex(chunk)) }
        let digest = try await identity.decryptWorkspaceIndex(envelope.digest)
        guard digest == Data(SHA256Hex.of(bytes).utf8) else { return nil }
        let payload = try JSONDecoder().decode(Payload.self, from: bytes)
        guard payload.boundary == boundary, payload.slot == slot else { return nil }
        try await identity.requireSigner(npub: boundary.signerNpub)
        return payload.bytes
    }
    func epoch() async throws -> String { try await store.reader.state("local-content.epoch") ?? "" }
    func save(_ slot: String, _ bytes: Data, dependencies: [String] = [], expectedEpoch: String? = nil) async throws {
        let epoch: String
        if let expectedEpoch { epoch = expectedEpoch } else { epoch = try await self.epoch() }
        try await identity.requireSigner(npub: boundary.signerNpub)
        let payload = try JSONEncoder().encode(Payload(boundary: boundary, slot: slot, bytes: bytes))
        guard payload.count <= 24 * 1024 * 1024 else { return }
        var chunks: [String] = []
        for offset in stride(from: 0, to: payload.count, by: 60000) {
            chunks.append(try await identity.encryptWorkspaceIndex(payload.subdata(in: offset..<min(offset + 60000, payload.count))))
        }
        let sealedDigest = try await identity.encryptWorkspaceIndex(Data(SHA256Hex.of(payload).utf8))
        try await identity.requireSigner(npub: boundary.signerNpub)
        try await store.writer.saveLocalContent(key: key(slot), value: String(decoding: JSONEncoder().encode(Envelope(chunks: chunks, digest: sealedDigest, workspace: boundary.workspaceId, dependencies: dependencies)), as: UTF8.self), epoch: epoch)
    }
    func remove(_ slot: String) async { try? await store.writer.removeLocalContent(key: key(slot)) }
}

/// Only explicit authority/code failures invalidate verified content; connectivity and validation transport failures do not.
public enum CachedContentFailure {
    public static func invalidates(_ error: Error) -> Bool {
        switch error {
        case TowerError.http(let status, _, _): return status == 403 || status == 404 || status == 410
        case FileNappletError.unavailable, FileNappletError.forbidden: return true
        default: return false
        }
    }
}

extension StoreWriter {
    /// Dependencies live on each sealed snapshot, not in a second cache catalogue. Only explicit removal paths call this.
    func removeLocalContent(key: String) async throws {
        try db.prepare("INSERT OR REPLACE INTO app_state(key,value) VALUES('local-content.epoch',?)").run([.text(UUID().uuidString)])
        try await setState(key, nil)
    }
    func saveLocalContent(key: String, value: String, epoch: String) async throws {
        let current = try db.prepare("SELECT value FROM app_state WHERE key = 'local-content.epoch'")
        let saved = try current.step() ? current.text(0) ?? "" : ""
        guard saved == epoch else { return } // A known removal overtook the verified read.
        try await setState(key, value)
    }
    @discardableResult
    func invalidateLocalContent(workspace: String, record: String? = nil, expectedEpoch: String? = nil) throws -> String {
        if let expectedEpoch {
            let current = try db.prepare("SELECT value FROM app_state WHERE key = 'local-content.epoch'")
            let saved = try current.step() ? current.text(0) ?? "" : ""
            guard saved == expectedEpoch else { throw CancellationError() }
        }
        let nextEpoch = UUID().uuidString
        try db.prepare("INSERT OR REPLACE INTO app_state(key,value) VALUES('local-content.epoch',?)").run([.text(nextEpoch)])
        if let record {
            try db.prepare("DELETE FROM app_state WHERE key LIKE 'local-content.v1:%' AND json_valid(value) AND json_extract(value, '$.workspace') = ? AND EXISTS (SELECT 1 FROM json_each(app_state.value, '$.dependencies') WHERE value = ?)")
                .run([.text(workspace), .text(record)])
        } else {
            try db.prepare("DELETE FROM app_state WHERE key LIKE 'local-content.v1:%' AND json_valid(value) AND json_extract(value, '$.workspace') = ?")
                .run([.text(workspace)])
        }
        return nextEpoch
    }
}
