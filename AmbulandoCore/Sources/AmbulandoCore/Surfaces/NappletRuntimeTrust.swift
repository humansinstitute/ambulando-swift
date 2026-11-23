import Foundation

/// Access receipts for v3 are scoped to server identity and authenticated publisher.
/// Legacy exact-code receipts are intentionally neither upgraded nor reused.
public struct NappletRuntimeTrust: Sendable {
    public let directory: URL
    public init(directory: URL = FileNappletTrustStore.local.directory.appendingPathComponent("v3",isDirectory:true)) { self.directory = directory }
    private func url(context: NappletRuntimeContext, napplet: String, publisher: String) throws -> URL {
        guard var origin = URLComponents(string:context.origin), ["http","https"].contains(origin.scheme?.lowercased() ?? ""),
              origin.host != nil, origin.user == nil, origin.password == nil,
              NappletRuntimeManifest.name(napplet), NostrKeys.isValidNpub(publisher),
              NostrKeys.isValidNpub(context.viewer), NostrKeys.isValidNpub(context.app),
              NostrKeys.isValidNpub(context.tower), NostrKeys.isValidNpub(context.service), GenericJSON.uuid(context.workspace) else { throw FileNappletError.invalid }
        origin.scheme = origin.scheme?.lowercased(); origin.host = origin.host?.lowercased()
        if origin.scheme == "https" && origin.port == 443 || origin.scheme == "http" && origin.port == 80 { origin.port = nil }
        if origin.path == "/" { origin.path = "" }
        let key = SHA256Hex.of(try GenericJSON.canonical([origin.string ?? "",context.tower,context.service,context.workspace,context.app,context.viewer,napplet,publisher]))
        return directory.appendingPathComponent(key + ".json")
    }
    public func approved(context: NappletRuntimeContext, publisher: String, manifest: NappletRuntimeManifest) -> Bool {
        guard let path = try? url(context:context,napplet:manifest.id,publisher:publisher),
              let data = try? Data(contentsOf:path), data.count <= GenericJSON.maxBytes,
              let prior = try? NappletRuntimeManifest.parse(data) else { return false }
        return prior.permits(manifest)
    }
    public func remember(context: NappletRuntimeContext, publisher: String, manifest: NappletRuntimeManifest) throws {
        guard manifest.unsupportedReason == nil else { throw FileNappletError.unavailable }
        let path = try url(context:context,napplet:manifest.id,publisher:publisher)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var dir = directory; try dir.setResourceValues(values)
        try manifest.canonical.write(to:path,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        var file = path; try file.setResourceValues(values)
    }
    public func forget(context: NappletRuntimeContext, publisher: String, napplet: String) throws {
        let path = try url(context:context,napplet:napplet,publisher:publisher)
        do { try FileManager.default.removeItem(at:path) }
        catch let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile {}
    }
}
