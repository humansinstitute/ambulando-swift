#if AMBULANDO_TEST
import AmbulandoCore
import Foundation

// Only synthetic fixture credentials belong here. File persistence lets lifecycle tests relaunch
// without ever consulting Security/Keychain. The separate test bundle owns this cache directory.
class FixtureCredentialFile<Value: Codable>: @unchecked Sendable {
    let file: URL
    private let lock = NSLock()
    init(file: URL) { self.file = file }
    func load() throws -> Value? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: file))
        }
    }
    func save(_ value: Value?) throws {
        try lock.withLock {
            if let value { try JSONEncoder().encode(value).write(to: file, options: .atomic) }
            else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
final class FixtureVaultStore: FixtureCredentialFile<Data>, VaultSecretStore, @unchecked Sendable {
    func read() throws -> Data? { try load() }
    func write(_ data: Data) throws { try save(data) }
}
final class FixtureBackgroundStore: FixtureCredentialFile<BackgroundReadCredential>, BackgroundCredentialStore, @unchecked Sendable {
    func read() throws -> BackgroundReadCredential? { try load() }
    func write(_ credential: BackgroundReadCredential) throws { try save(credential) }
    func delete() throws { try save(nil) }
}
final class FixtureSessionStore: FixtureCredentialFile<SessionKey>, SessionKeyStore, @unchecked Sendable {
    func read() throws -> SessionKey? { try load() }
    func write(_ key: SessionKey) throws { try save(key) }
    func delete() throws { try save(nil) }
}
#endif
