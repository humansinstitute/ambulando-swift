import Foundation

/// Consent only, never authorization. Construct after fresh code, binding and data access verification.
/// No tracker values, immutable data revision, credentials or source text enter a receipt.
public struct FileNappletTrustReceipt: Codable, Equatable, Sendable {
    public let policyVersion: Int
    public let origin: String
    public let connection: String
    public let service: String?
    public let viewer: String
    public let workspace: String
    public let app: String
    public let codeFile: String
    public let codeSHA256: String
    public let manifestVersion: Int
    public let appId: String
    public let bindingName: String
    public let dataFile: String
    public let format: String
    public let privacy: String
    public let operations: [String]
    public let canWrite: Bool

    public init(connection: ConnectionRecord, workspace: WorkspaceRecord, codeFile: String, code: FileNappletCode, canWrite: Bool) throws {
        guard let binding = code.binding, UUID(uuidString: codeFile) != nil,
              !connection.id.isEmpty, !connection.signerNpub.isEmpty, !workspace.appNpub.isEmpty else { throw FileNappletError.invalid }
        // Binding/manifest is admitted by the narrow v1 parser; revalidate rather than trusting app_id alone.
        let metadata = try rawJSON(["napplet": ["version": 1, "app_id": "daily-tracker", "bindings": ["tracker": ["file_id": binding.dataFileId]]]])
        guard try FileNappletBinding.parse(html: code.html, metadata: metadata) == binding else { throw FileNappletError.invalid }
        self.policyVersion = 1
        self.origin = try TowerOrigin(connection.origin).url.absoluteString
        self.service = connection.towerNpub
        self.connection = connection.id; self.viewer = connection.signerNpub
        self.workspace = workspace.id; self.app = workspace.appNpub; self.codeFile = codeFile.lowercased()
        self.codeSHA256 = code.sha256
        self.manifestVersion = 1; self.appId = "daily-tracker"; self.bindingName = "tracker"
        self.dataFile = binding.dataFileId; self.format = "daily-tracker-v1"; self.privacy = "self"
        self.operations = ["read", "save"]; self.canWrite = canWrite
    }
    /// One current receipt per app instance and viewer/context. Replacement does not accumulate old grants.
    var slot: String {
        let fields = [origin, connection, service ?? "", viewer, workspace, app, codeFile]
        return SHA256Hex.of(try! JSONEncoder().encode(fields))
    }
}

/// Native app-container storage, never ubiquitous preferences/Keychain or server state.
/// Separate files avoid losing concurrent grants for other app instances. Read errors fail closed.
public struct FileNappletTrustStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static var local: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(directory: root.appendingPathComponent(Bundle.main.bundleIdentifier ?? "studio.otherstuff.ambulando", isDirectory: true)
            .appendingPathComponent("NappletTrust", isDirectory: true))
    }
    private func url(_ receipt: FileNappletTrustReceipt) -> URL { directory.appendingPathComponent(receipt.slot + ".json") }
    public func contains(_ receipt: FileNappletTrustReceipt) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url(receipt)) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 16385), bytes.count <= 16384,
              let saved = try? JSONDecoder().decode(FileNappletTrustReceipt.self, from: bytes) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let expected = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any],
              Set(object.keys) == Set(expected.keys) else { return false }
        return saved == receipt
    }
    public func remember(_ receipt: FileNappletTrustReceipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let file = url(receipt)
        do {
            try JSONEncoder().encode(receipt).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            var excluded = file; try excluded.setResourceValues(values)
            guard contains(receipt) else { throw FileNappletError.unavailable }
        } catch {
            // A partly completed remember must not become an automatic grant on the next open.
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
    public func forget(_ receipt: FileNappletTrustReceipt) throws {
        let file = url(receipt)
        do { try FileManager.default.removeItem(at: file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // Missing is already forgotten. Other errors (including inaccessible storage) must surface.
        }
    }
}
