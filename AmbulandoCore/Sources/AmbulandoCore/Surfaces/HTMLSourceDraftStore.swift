import Foundation

/// Recovery source belongs to one exact identity, origin, application and workspace.
/// Legacy drafts lack the application boundary: offer review explicitly, never import them automatically.
public struct HTMLSourceDraftStore: Sendable {
    public struct Draft: Codable, Equatable, Sendable {
        public let base: String
        public let source: String
        public init(base: String, source: String) { self.base = base; self.source = source }
    }
    public let url: URL
    public let legacyURL: URL?
    public init(directory: URL, boundary: WorkspaceBoundary, fileId: String, allowLegacy: Bool) {
        let name = "html-" + boundary.workspaceId + "-" + fileId + ".json"
        url = directory.appendingPathComponent(boundary.id, isDirectory: true).appendingPathComponent(name)
        legacyURL = allowLegacy ? directory.appendingPathComponent(name) : nil
    }
    public func load() -> Draft? { read(url) }
    public func legacyForReview() -> Draft? { legacyURL.flatMap(read) }
    private func read(_ url: URL) -> Draft? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
              let bytes = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Draft.self, from: bytes)
    }
    public func save(_ draft: Draft) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    public func remove() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
