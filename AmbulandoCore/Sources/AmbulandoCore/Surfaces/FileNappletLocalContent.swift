import Foundation

public struct CachedFileNapplet: Codable, Sendable {
    public let code: FileNappletCode
    public let data: FileNappletData
}
extension WorkspaceSync {
    private func trackerCache(_ c: ConnectionRecord, _ w: WorkspaceRecord) throws -> LocalContentSnapshot {
        LocalContentSnapshot(store: store, identity: identity, boundary: try WorkspaceBoundary(connection: c, workspace: w))
    }
    public func cachedFileNapplet(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String) async -> CachedFileNapplet? {
        do {
            let cache = try trackerCache(c, w)
            guard let bytes = try await cache.read("file-napplet:" + fileId) else { return nil }
            let saved = try JSONDecoder().decode(CachedFileNapplet.self, from: bytes)
            guard let binding = saved.code.binding, SHA256Hex.of(Data(saved.code.html.utf8)) == saved.code.sha256 else { return nil }
            let metadata = try rawJSON(["napplet": ["version": 1, "app_id": "daily-tracker", "bindings": ["tracker": ["file_id": binding.dataFileId]]]])
            guard try FileNappletBinding.parse(html: saved.code.html, metadata: metadata) == binding else { return nil }
            try TrackerDocument.validate(saved.data.bytes)
            return saved
        } catch { return nil }
    }
    func rememberFileNapplet(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: FileNappletCode, data: FileNappletData, epoch: String? = nil) async {
        guard let binding = code.binding, let cache = try? trackerCache(c, w), let bytes = try? JSONEncoder().encode(CachedFileNapplet(code: code, data: data)) else { return }
        try? await cache.save("file-napplet:" + fileId, bytes, dependencies: [fileId, binding.dataFileId] + code.channelIds + [data.channelId].compactMap { $0 }, expectedEpoch: epoch)
    }
    public func forgetCachedFileNapplet(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String) async {
        guard let cache = try? trackerCache(c, w) else { return }
        await cache.remove("file-napplet:" + fileId)
    }
}
