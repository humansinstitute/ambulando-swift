import Foundation

public struct CachedRuntimeContent: Sendable {
    public let code: RuntimeCode
    public let collections: Data
}
extension WorkspaceSync {
    private struct SavedRuntime: Codable { let installation: Data; let html: String; let collections: Data }
    private func runtimeCache(_ c: ConnectionRecord, _ w: WorkspaceRecord) throws -> LocalContentSnapshot {
        LocalContentSnapshot(store: store, identity: identity, boundary: try WorkspaceBoundary(connection: c, workspace: w))
    }
    public func rememberRuntime(_ c: ConnectionRecord, _ w: WorkspaceRecord, code: RuntimeCode, collections: Data, epoch: String? = nil) async {
        guard let cache = try? runtimeCache(c, w), let bytes = try? JSONEncoder().encode(SavedRuntime(installation: code.installation.raw, html: code.html, collections: collections)) else { return }
        try? await cache.save("runtime:" + code.installation.id, bytes, expectedEpoch: epoch)
    }
    public func cachedRuntime(_ c: ConnectionRecord, _ w: WorkspaceRecord, id: String) async -> CachedRuntimeContent? {
        do {
            let cache = try runtimeCache(c, w)
            guard let bytes = try await cache.read("runtime:" + id) else { return nil }
            let saved = try JSONDecoder().decode(SavedRuntime.self, from: bytes)
            let installation = try RuntimeInstallation.parse(GenericJSON.decode(saved.installation), context: runtimeContext(c, w))
            guard installation.id == id, SHA256Hex.of(Data(saved.html.utf8)) == installation.bundle.digest,
                  try NappletRuntimeManifest.parse(html: saved.html) == installation.manifest else { return nil }
            return CachedRuntimeContent(code: RuntimeCode(installation: installation, html: saved.html), collections: saved.collections)
        } catch { return nil }
    }
    public func forgetCachedRuntime(_ c: ConnectionRecord, _ w: WorkspaceRecord, id: String) async {
        guard let cache = try? runtimeCache(c, w) else { return }
        await cache.remove("runtime:" + id)
    }
    private func runtimeReadSlot(_ installation: RuntimeInstallation, _ request: NappletRuntimeRequest, _ selections: [String: String], authority: Data) -> String {
        "runtime-read:" + installation.id + ":" + WorkspaceBoundary.digest([installation.bundle.digest, String(installation.revision), SHA256Hex.of(authority), request.operation, request.collection ?? "", request.record ?? "", String(request.limit ?? 0), request.cursor ?? "", selections.sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: ",")])
    }
    public func cachedRuntimeRead(_ c: ConnectionRecord, _ w: WorkspaceRecord, installation: RuntimeInstallation, request: NappletRuntimeRequest, selections: [String: String]) async -> Data? {
        guard ["list", "get"].contains(request.operation), let cache = try? runtimeCache(c, w),
              let installed = await cachedRuntime(c, w, id: installation.id), installed.code.installation == installation else { return nil }
        return try? await cache.read(runtimeReadSlot(installation, request, selections, authority: installed.collections))
    }
    func rememberRuntimeRead(_ c: ConnectionRecord, _ w: WorkspaceRecord, installation: RuntimeInstallation, request: NappletRuntimeRequest, selections: [String: String], bytes: Data, epoch: String? = nil) async {
        guard ["list", "get"].contains(request.operation), let cache = try? runtimeCache(c, w),
              let installed = await cachedRuntime(c, w, id: installation.id), installed.code.installation == installation else { return }
        try? await cache.save(runtimeReadSlot(installation, request, selections, authority: installed.collections), bytes, expectedEpoch: epoch)
    }
}
