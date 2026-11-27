import Foundation

/// One verified code head and its data, saved atomically. Approval remains in GenericNappletTrustStore.
public struct CachedGenericNapplet: Sendable {
    public let code: GenericNappletCode
    public let data: FileNappletData
}

extension WorkspaceSync {
    private struct SavedGeneric: Codable {
        let html: String; let manifest: Data; let resources: Data; let version: String; let digest: String
        let bytes: Data; let dataVersion: String; let canWrite: Bool; let range: String?; let codeChannels: [String]; let dataChannel: String?
    }
    private func contentCache(_ c: ConnectionRecord, _ w: WorkspaceRecord) throws -> LocalContentSnapshot {
        LocalContentSnapshot(store: store, identity: identity, boundary: try WorkspaceBoundary(connection: c, workspace: w))
    }
    public func cachedGenericNapplet(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, range: String? = nil) async -> CachedGenericNapplet? {
        do {
            let cache = try contentCache(c, w)
            guard let bytes = try await cache.read("generic:" + fileId + ":" + (range ?? "json")) else { return nil }
            let saved = try JSONDecoder().decode(SavedGeneric.self, from: bytes)
            let manifest = try JSONSerialization.jsonObject(with: saved.manifest) as? [String: Any]
            let resources = try JSONSerialization.jsonObject(with: saved.resources)
            let metadata = try rawJSON(["napplet": ["version": 2, "app_id": manifest?["app_id"] ?? "", "bindings": resources]])
            guard SHA256Hex.of(Data(saved.html.utf8)) == saved.digest,
                  let binding = try GenericNappletBinding.parse(html: saved.html, metadata: metadata),
                  binding.capability != "workspace-aggregate" || binding.resourceId == w.id else { return nil }
            if binding.capability == "private-json-file" { _ = try GenericJSON.canonicalData(saved.bytes) }
            return CachedGenericNapplet(code: GenericNappletCode(html: saved.html, binding: binding, versionId: saved.version, sha256: saved.digest, channelIds: saved.codeChannels),
                                        data: FileNappletData(bytes: saved.bytes, versionId: saved.dataVersion, canWrite: saved.canWrite, channelId: saved.dataChannel))
        } catch { return nil }
    }
    func rememberGeneric(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: GenericNappletCode, data: FileNappletData, range: String? = nil, epoch: String? = nil) async {
        let saved = SavedGeneric(html: code.html, manifest: code.binding.manifest, resources: code.binding.resources, version: code.versionId, digest: code.sha256,
                                 bytes: data.bytes, dataVersion: data.versionId, canWrite: data.canWrite, range: range, codeChannels: code.channelIds, dataChannel: data.channelId)
        if let bytes = try? JSONEncoder().encode(saved), let cache = try? contentCache(c, w) {
            try? await cache.save("generic:" + fileId + ":" + (range ?? "json"), bytes, dependencies: [fileId, code.binding.resourceId] + code.channelIds + [data.channelId].compactMap { $0 }, expectedEpoch: epoch)
        }
    }
    public func forgetCachedGeneric(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String) async {
        guard let cache = try? contentCache(c, w) else { return }
        for range in ["json"] + Array(WorkspaceReportRequest.ranges) { await cache.remove("generic:" + fileId + ":" + range) }
    }
}
