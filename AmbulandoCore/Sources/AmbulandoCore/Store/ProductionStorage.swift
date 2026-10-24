import Foundation

/// Where the installed app keeps the user's account. These names are a compatibility contract: every build since the
/// first (0.1.0 build 1) has used them, and an update must find the identity, Tower connection, selections, drafts and
/// unsent work exactly where the previous build left them. Changing any of them strands existing data, so they are
/// pinned by `AccountRetentionTests`; a rename needs a migration that copies, verifies and only then switches.
public enum ProductionStorage {
    /// Application Support subdirectory holding `Store/ambulando.sqlite`, `Identity/vault.json`, `Staging` and `Transfers`.
    public static let dataDirectoryName = "AmbulandoNative"
    public static let storeDirectoryName = "Store"
    public static let databaseFileName = "ambulando.sqlite"
    public static let vaultPath = "Identity/vault.json"
    /// Keychain services (generic passwords, this app's default access group, device-only, not synchronized).
    public static let vaultSecretService = "studio.otherstuff.ambulando.native.identity-vault.v1"
    public static let backgroundReadService = "studio.otherstuff.ambulando.native.background-read.v1"
    public static let sessionService = "studio.otherstuff.ambulando.native.session.v1"
    /// Caches subdirectory for downloaded files (re-downloadable; iOS may purge it).
    public static let fileCacheDirectoryName = "AmbulandoFiles"

    public static func dataDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(dataDirectoryName, isDirectory: true)
    }
    public static func storeDirectory(_ data: URL) -> URL { data.appendingPathComponent(storeDirectoryName, isDirectory: true) }
    public static func vaultURL(_ data: URL) -> URL { data.appendingPathComponent(vaultPath) }
}
