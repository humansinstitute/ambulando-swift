import Foundation
import Observation
import UniformTypeIdentifiers

/// One image or file pasted into a chat composer, from the paste until its placeholder becomes storage Markdown.
public struct ComposerUpload: Identifiable, Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Reading the pasted item and staging it on the device.
        case preparing
        /// Staged; waiting for the upload ahead of it.
        case waiting
        case uploading
        case failed(String)
        case done(objectId: String)
    }

    public let id: String
    /// Connection, workspace, channel and thread captured at paste. The result only ever goes to this draft.
    public let target: ChatTarget
    public let appNpub: String
    public let kind: UploadToken.Kind
    public internal(set) var filename: String
    public internal(set) var mimeType: String
    public internal(set) var phase: Phase
    /// False when the staged bytes are gone (only Remove is left).
    public internal(set) var retryable: Bool
    var sizeBytes = 0
    var sha256: String?
    /// The pasted file came with its own name (otherwise the staged copy's name is used).
    var named = true
    var prepared: PreparedObject?

    public var token: String { UploadToken.make(kind, id: id) }
    public var isActive: Bool { switch phase { case .preparing, .waiting, .uploading: true; default: false } }

    /// The Markdown that replaces the placeholder (sol `createStorageMarkdown` / `createStorageFileMarkdown`).
    public var markdown: String? {
        guard case .done(let objectId) = phase else { return nil }
        return kind == .image ? StorageMarkdown.image(objectId: objectId, alt: filename) : StorageMarkdown.file(objectId: objectId, name: filename)
    }
}

public enum ComposerUploadError: LocalizedError, Equatable, Sendable {
    case locked, otherConnection, tooLarge, unreadable, unresolved
    public var errorDescription: String? {
        switch self {
        case .locked: "Unlock to upload."
        case .otherConnection: "This upload belongs to another connection."
        case .tooLarge: "Pasted items over 100 MB are not uploaded from this app."
        case .unreadable: "Could not read the pasted item."
        case .unresolved: "Wait for pasted items to finish uploading, or remove them."
        }
    }
}

/// A live composer showing one target's text. Results for that target are applied to it directly.
@MainActor
public protocol UploadTokenHost: AnyObject {
    var uploadTarget: ChatTarget { get }
    var uploadText: String { get }
    /// Replaces the first `token` in the live text, keeping the caret; false when the text no longer holds it.
    func replaceUploadToken(_ token: String, with replacement: String) -> Bool
}

/// What an upload needs to reach Tower: staged bytes, the captured target and a prepared object to reuse.
public struct ComposerUploadJob: Sendable {
    public let id: String
    public let target: ChatTarget
    public let appNpub: String
    public let staged: URL
    public let mimeType: String
    public let filename: String
    public let sha256: String
    public let prepared: PreparedObject?
    public let onPrepared: @Sendable (PreparedObject) async throws -> Void
}

/// Uploads a job through the sync engine (`user` priority) with the existing storage route
/// (`TowerAPI.store`: prepare → upload → complete, prepared object reused, background transfers for presigned URLs),
/// signed by the connection's own unlocked identity.
public struct ComposerUploadTransfer: Sendable {
    public let engine: SyncEngine
    public let identity: IdentityService
    public let transport: HTTPTransport
    public let transfers: BackgroundTransfers?

    public init(engine: SyncEngine, identity: IdentityService, transport: HTTPTransport, transfers: BackgroundTransfers? = nil) {
        self.engine = engine; self.identity = identity; self.transport = transport; self.transfers = transfers
    }

    public func upload(_ job: ComposerUploadJob, connection: ConnectionRecord) async throws -> String {
        guard connection.id == job.target.connectionId else { throw ComposerUploadError.otherConnection }
        let identity = identity, transport = transport, transfers = transfers
        return try await engine.perform("paste:\(connection.id):\(job.id)", priority: .user) {
            guard case .unlocked(let npub) = await identity.state, npub == connection.signerNpub else { throw ComposerUploadError.locked }
            let bytes = try Data(contentsOf: job.staged)
            guard SHA256Hex.of(bytes) == job.sha256 else { throw FileTransferError.integrity }
            let client = TowerClient(origin: try TowerOrigin(connection.origin), transport: transport, signer: identity)
            return try await TowerAPI(client: client, transfers: transfers).store(
                workspaceId: job.target.workspaceId, appNpub: job.appNpub, bytes: bytes, contentType: job.mimeType,
                fileName: job.filename, prepared: job.prepared, onPrepared: job.onPrepared)
        }
    }
}

/// Pasted images and files of every composer (sol `handleChatPaste` / `uploadChatFileDraft`).
///
/// - A paste inserts one placeholder per item at the caret straight away; reading, privacy-stripping (images, as for
///   picked photos) and staging run off the main actor, and one upload runs at a time.
/// - Each upload keeps the target captured at paste. Its Markdown replaces the placeholder in that target's live
///   composer, or in that target's stored draft when the user has moved on, never anywhere else.
/// - Staged bytes and a small record sit in the staging directory until the result is in the draft, so a relaunch can
///   still retry or apply it.
@MainActor
@Observable
public final class ComposerUploads {
    /// At most this many items per paste (as the photo picker).
    nonisolated public static let maxItemsPerPaste = 4
    /// The same per-file limit as Files uploads.
    nonisolated public static let maxBytes = TowerAPI.maxDownloadBytes

    public typealias Upload = @Sendable (ComposerUploadJob) async throws -> String

    public private(set) var items: [ComposerUpload] = []
    /// A short message about the last paste (for example items over the limit), keyed by draft.
    public private(set) var notices: [String: String] = [:]

    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let staging: URL
    @ObservationIgnored private let upload: Upload
    @ObservationIgnored private var hosts: [String: WeakHost] = [:]
    @ObservationIgnored private var running: (id: String, task: Task<Void, Never>)?
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]

    public init(store: LocalStore, staging: URL, upload: @escaping Upload) {
        self.store = store; self.staging = staging; self.upload = upload
    }

    public func uploads(for target: ChatTarget) -> [ComposerUpload] { items.filter { $0.target == target && $0.markdown == nil } }

    public func notice(for target: ChatTarget) -> String? { notices[target.draftKey] }
    public func clearNotice(for target: ChatTarget) { notices[target.draftKey] = nil }

    // MARK: Paste

    /// The pasted items that are images or files. Anything else (text, links, rich text) is an ordinary text paste.
    nonisolated public static func attachments(in providers: [NSItemProvider]) -> [(provider: NSItemProvider, kind: UploadToken.Kind, type: UTType)] {
        providers.compactMap { provider in
            let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            if let image = types.first(where: { $0.conforms(to: .image) }) { return (provider, .image, image) }
            let file = types.first(where: { ($0.conforms(to: .data) || $0.conforms(to: .content)) && !$0.conforms(to: .url) })
            // A copied file carries its name or file address (a text file is still a file); a text or link selection does not.
            let named = !((provider.suggestedName ?? "") as NSString).pathExtension.isEmpty || types.contains { $0.conforms(to: .fileURL) }
            if let file, named { return (provider, .file, file) }
            if types.contains(where: { $0.conforms(to: .text) || $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }) { return nil }
            return file.map { (provider, .file, $0) }
        }
    }

    /// Starts uploads for the pasted images and files and returns the placeholders to insert at the caret, in order
    /// (empty: nothing to upload, paste the text as usual). `context` names images as the web does ("message",
    /// "thread").
    public func paste(_ providers: [NSItemProvider], target: ChatTarget, appNpub: String, context: String) -> [String] {
        let found = Self.attachments(in: providers)
        guard !found.isEmpty else { return [] }
        notices[target.draftKey] = found.count > Self.maxItemsPerPaste
            ? "Only the first \(Self.maxItemsPerPaste) pasted items are uploaded." : nil
        var tokens: [String] = []
        for (provider, kind, type) in found.prefix(Self.maxItemsPerPaste) {
            let id = UUID().uuidString.lowercased()
            let name = kind == .image ? Self.imageName(context: context) : Self.fileName(provider.suggestedName, type: type)
            var item = ComposerUpload(id: id, target: target, appNpub: appNpub, kind: kind, filename: name,
                                      mimeType: kind == .image ? "image/png" : (type.preferredMIMEType ?? "application/octet-stream"),
                                      phase: .preparing, retryable: false)
            item.named = kind == .image || !(provider.suggestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            items.append(item)
            tokens.append(UploadToken.make(kind, id: id))
            let staging = staging
            loads[id] = Task { [weak self] in
                let staged = await Self.stage(provider, kind: kind, type: type, id: id, in: staging)
                self?.staged(id, staged)
            }
        }
        return tokens
    }

    /// `<context>-image-<UTC time>.png` (sol `defaultPastedImageName`).
    nonisolated static func imageName(context: String, now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let stamp = f.string(from: now).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "Z", with: "")
        return "\(context)-image-\(stamp).png"
    }

    nonisolated static func fileName(_ suggested: String?, type: UTType) -> String {
        let base = (suggested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? "Attachment" : base
        guard let ext = type.preferredFilenameExtension, (name as NSString).pathExtension.isEmpty else { return name }
        return name + "." + ext
    }

    struct Staged: Sendable { let file: String; let size: Int; let sha256: String; var name: String? = nil }

    /// Reads, strips (images) and writes one pasted item into the staging directory, off the main actor.
    nonisolated static func stage(_ provider: NSItemProvider, kind: UploadToken.Kind, type: UTType, id: String, in staging: URL) async -> Result<Staged, ComposerUploadError> {
        do { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) } catch { return .failure(.unreadable) }
        switch kind {
        case .image:
            let data: Data? = await withCheckedContinuation { c in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in c.resume(returning: data) }
            }
            guard let data else { return .failure(.unreadable) }
            guard data.count <= maxBytes else { return .failure(.tooLarge) }
            return await Task.detached(priority: .userInitiated) { () -> Result<Staged, ComposerUploadError> in
                guard let png = try? ImagePrivacy.strippedPNG(data) else { return .failure(.unreadable) }
                let name = "paste-\(id).png"
                guard (try? write(png, to: staging.appendingPathComponent(name))) != nil else { return .failure(.unreadable) }
                return .success(Staged(file: name, size: png.count, sha256: SHA256Hex.of(png)))
            }.value
        case .file:
            let ext = type.preferredFilenameExtension.map { "." + $0 } ?? ""
            let name = "paste-\(id)\(ext)"
            let destination = staging.appendingPathComponent(name)
            // The provider's file is deleted when the handler returns, so it is copied inside it.
            let copied: Result<(size: Int, name: String), ComposerUploadError> = await withCheckedContinuation { c in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return c.resume(returning: .failure(.unreadable)) }
                    guard size <= maxBytes else { return c.resume(returning: .failure(.tooLarge)) }
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.copyItem(at: url, to: destination)
                        c.resume(returning: .success((size, url.lastPathComponent)))
                    } catch { c.resume(returning: .failure(.unreadable)) }
                }
            }
            switch copied {
            case .failure(let error): return .failure(error)
            case .success(let copy):
                guard let sha = try? SHA256Hex.ofFile(destination) else { return .failure(.unreadable) }
                return .success(Staged(file: name, size: copy.size, sha256: sha, name: copy.name))
            }
        }
    }

    nonisolated private static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    private func staged(_ id: String, _ result: Result<Staged, ComposerUploadError>) {
        loads[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            if case .success(let s) = result { try? FileManager.default.removeItem(at: staging.appendingPathComponent(s.file)) }   // removed meanwhile
            return
        }
        switch result {
        case .failure(let error):
            items[index].phase = .failed(error.errorDescription ?? "Could not read the pasted item.")
        case .success(let s):
            if items[index].kind == .file, items[index].named == false, let name = s.name, !name.isEmpty { items[index].filename = name }
            items[index].sizeBytes = s.size
            items[index].sha256 = s.sha256
            items[index].phase = .waiting
            items[index].retryable = true
            saveRecord(items[index], staged: s.file)
            pump()
        }
    }

    // MARK: Uploading

    public func retry(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .failed = items[index].phase, items[index].retryable else { return }
        items[index].phase = .waiting
        pump()
    }

    /// Cancels the upload, deletes its staged bytes and takes its placeholder out of the target's text.
    public func remove(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        loads.removeValue(forKey: id)?.cancel()
        if running?.id == id { running?.task.cancel(); running = nil }
        items.removeAll { $0.id == id }
        deliver(item.token, replacement: "", target: item.target)
        discardFiles(id)
        pump()
    }

    private func pump() {
        guard running == nil, let next = items.first(where: { $0.phase == .waiting }), let sha = next.sha256,
              let record = readRecord(next.id) else {
            if running == nil, let stuck = items.firstIndex(where: { $0.phase == .waiting }) {
                items[stuck].phase = .failed("This pasted item is no longer on this device.")
                items[stuck].retryable = false
                pump()
            }
            return
        }
        let id = next.id
        updatePhase(id, .uploading)
        let job = ComposerUploadJob(id: id, target: next.target, appNpub: next.appNpub, staged: staging.appendingPathComponent(record.staged),
                                    mimeType: next.mimeType, filename: next.filename, sha256: sha, prepared: next.prepared,
                                    onPrepared: { [weak self] fresh in await self?.prepared(id, fresh) })
        let upload = upload
        let task = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await upload(job)) } catch { result = .failure(error) }
            self?.finished(id, result)
        }
        running = (id, task)
    }

    private func prepared(_ id: String, _ fresh: PreparedObject) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].prepared = fresh
        if var record = readRecord(id) { record.prepared = fresh; writeRecord(record) }
    }

    private func finished(_ id: String, _ result: Result<String, Error>) {
        if running?.id == id { running = nil }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return pump() }   // removed
        switch result {
        case .success(let objectId):
            items[index].phase = .done(objectId: objectId)
            if var record = readRecord(id) {
                try? FileManager.default.removeItem(at: staging.appendingPathComponent(record.staged))
                record.objectId = objectId
                writeRecord(record)
            }
            items[index].retryable = false
            let item = items[index]
            if let markdown = item.markdown { deliver(item.token, replacement: markdown, target: item.target, completing: id) }
        case .failure(let error):
            items[index].phase = .failed(Self.message(error))
        }
        pump()
    }

    static func message(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "Upload was interrupted." }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "Offline. Retry when connected."
            case .timedOut: return "Tower did not answer in time."
            default: return "Network problem (\(url.code.rawValue))."
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? "Upload failed."
    }

    private func updatePhase(_ id: String, _ phase: ComposerUpload.Phase) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].phase = phase }
    }

    // MARK: Results

    /// Puts `replacement` where `token` is in the target's live composer, else in its stored draft. A completed upload
    /// is forgotten once its Markdown is in the text; if neither holds the placeholder (it is still being saved), the
    /// result is kept and applied when that composer shows the text again.
    private func deliver(_ token: String, replacement: String, target: ChatTarget, completing id: String? = nil) {
        if let host = hosts[target.draftKey]?.host, host.uploadTarget == target {
            let applied = host.replaceUploadToken(token, with: replacement)
            if let id, applied { forget(id) }
            return
        }
        let store = store
        Task { [weak self] in
            let applied = (try? await store.writer.replaceDraftToken(target, token: token, with: replacement)) ?? false
            if let id, applied { self?.forget(id) }
        }
    }

    private func forget(_ id: String) {
        items.removeAll { $0.id == id }
        discardFiles(id)
    }

    /// A composer starts showing `host.uploadTarget`: finished results are applied to its text, and placeholders from
    /// an earlier launch become retryable (or removable) uploads again.
    public func attach(_ host: UploadTokenHost) {
        let target = host.uploadTarget
        hosts[target.draftKey] = WeakHost(host: host)
        for (kind, id) in UploadToken.ids(in: host.uploadText) {
            if let item = items.first(where: { $0.id == id }) {
                guard item.target == target else { continue }
                if let markdown = item.markdown, host.replaceUploadToken(item.token, with: markdown) { forget(id) }
                continue
            }
            guard let record = readRecord(id), record.target == target, record.kind == kind else {
                items.append(ComposerUpload(id: id, target: target, appNpub: "", kind: kind, filename: kind == .image ? "Image" : "File",
                                            mimeType: "", phase: .failed("This pasted item is no longer on this device."), retryable: false))
                continue
            }
            var item = ComposerUpload(id: id, target: target, appNpub: record.appNpub, kind: kind, filename: record.filename, mimeType: record.mimeType,
                                      phase: .failed("Upload was interrupted."), retryable: false)
            item.sizeBytes = record.sizeBytes
            item.sha256 = record.sha256
            item.prepared = record.prepared
            if let objectId = record.objectId {
                item.phase = .done(objectId: objectId)
                if let markdown = item.markdown, host.replaceUploadToken(item.token, with: markdown) { discardFiles(id); continue }
            } else {
                item.retryable = FileManager.default.fileExists(atPath: staging.appendingPathComponent(record.staged).path)
                if !item.retryable { item.phase = .failed("This pasted item is no longer on this device.") }
            }
            items.append(item)
        }
    }

    public func detach(_ host: UploadTokenHost) {
        let key = host.uploadTarget.draftKey
        if hosts[key]?.host === host { hosts[key] = nil }
    }

    // MARK: Staging records

    struct Record: Codable, Equatable {
        let id: String
        let target: ChatTarget
        let appNpub: String
        let kind: UploadToken.Kind
        let filename: String
        let mimeType: String
        let sizeBytes: Int
        let sha256: String
        let staged: String
        var prepared: PreparedObject?
        var objectId: String?
    }

    private func recordURL(_ id: String) -> URL { staging.appendingPathComponent("paste-\(id).json") }

    private func saveRecord(_ item: ComposerUpload, staged: String) {
        guard let sha = item.sha256 else { return }
        writeRecord(Record(id: item.id, target: item.target, appNpub: item.appNpub, kind: item.kind, filename: item.filename, mimeType: item.mimeType,
                           sizeBytes: item.sizeBytes, sha256: sha, staged: staged, prepared: item.prepared))
    }

    private func writeRecord(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? Self.write(data, to: recordURL(record.id))
    }

    func readRecord(_ id: String) -> Record? {
        guard UUID(uuidString: id) != nil, let data = try? Data(contentsOf: recordURL(id)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func discardFiles(_ id: String) {
        guard UUID(uuidString: id) != nil else { return }
        if let record = readRecord(id) { try? FileManager.default.removeItem(at: staging.appendingPathComponent(record.staged)) }
        try? FileManager.default.removeItem(at: recordURL(id))
    }
}

private struct WeakHost { weak var host: UploadTokenHost? }
