import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches avatar bytes. Production uses an ephemeral session; tests and sample-data mode inject their own.
public protocol AvatarTransport: Sendable {
    /// The body of `url` (at most `maxBytes`) and its response. Must not follow redirects or send credentials.
    func fetch(_ url: URL, maxBytes: Int) async throws -> (Data, HTTPURLResponse)
}

public enum AvatarError: Error, Equatable {
    case refusedURL, httpStatus(Int), notAnImage, tooLarge, undecodable
}

/// Avatar requests go to whatever host a profile names, so they carry nothing that identifies the user to it beyond
/// the request itself: no Authorization header, no cookies (neither sent nor stored) and no shared HTTP cache.
/// Redirects are followed only a few times and only to an address the avatar URL policy accepts (Blossom servers such
/// as blossom.primal.net answer every picture with a redirect to their CDN); anything else, such as a local address,
/// ends the request.
public final class URLSessionAvatarTransport: AvatarTransport {
    let session: URLSession

    public convenience init(timeout: TimeInterval = 15) { self.init(timeout: timeout, protocolClasses: nil) }

    /// `protocolClasses` lets tests observe the exact requests without a network.
    init(timeout: TimeInterval = 15, protocolClasses: [AnyClass]?) {
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: AvatarRedirects(), delegateQueue: nil)
    }

    public func fetch(_ url: URL, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AvatarError.notAnImage }
        guard http.statusCode == 200 else { bytes.task.cancel(); throw AvatarError.httpStatus(http.statusCode) }
        if http.expectedContentLength > Int64(maxBytes) { bytes.task.cancel(); throw AvatarError.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(min(max(http.expectedContentLength, 0), Int64(maxBytes))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { bytes.task.cancel(); throw AvatarError.tooLarge }
        }
        return (data, http)
    }
}

/// Follows at most `maxRedirects` redirects per request, each to an address `AvatarURLPolicy` accepts, without
/// credentials or cookies.
final class AvatarRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let maxRedirects = 3
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.follow(request, redirectNumber: nextCount(task.taskIdentifier)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock(); counts[task.taskIdentifier] = nil; lock.unlock()
    }

    private func nextCount(_ id: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let next = (counts[id] ?? 0) + 1
        counts[id] = next
        return next
    }

    /// The request to follow, or nil to stop at the redirect (which then fails as a non-200 answer).
    static func follow(_ request: URLRequest, redirectNumber: Int) -> URLRequest? {
        guard redirectNumber <= maxRedirects, let url = request.url, let allowed = AvatarURLPolicy.validate(url.absoluteString) else { return nil }
        var next = URLRequest(url: allowed)
        next.httpMethod = "GET"
        next.httpShouldHandleCookies = false
        next.setValue("image/*", forHTTPHeaderField: "Accept")
        return next
    }
}

/// Downloaded avatars, stored on disk as small re-encoded PNG thumbnails named by the SHA-256 of their URL. A changed
/// profile picture is a different URL and so a different file; old files age out of the bounded cache.
///
/// Everything here runs off the main actor: downloads (at most `maxConcurrent` at once, one per URL), validation and
/// decoding. A failed URL is not asked for again for a while.
public actor AvatarStore {
    /// Largest download accepted (bytes, 5 MiB). Public profile pictures are often full-size photos over 2 MB; the pixel bound
    /// and the thumbnail decode keep memory small whatever the file size.
    public static let maxBytes = 5 * 1024 * 1024
    /// Largest source image accepted (pixels); bigger images are refused before decoding.
    public static let maxSourcePixels = 40_000_000
    public static let thumbnailPixels = 192
    public static let maxFiles = 400
    public static let maxDiskBytes = 16 * 1024 * 1024
    static let acceptedTypes: Set<String> = [UTType.png, .jpeg, .gif, .webP, .heic, .heif, .bmp, .tiff].map(\.identifier).reduce(into: []) { $0.insert($1) }

    public nonisolated let directory: URL
    let transport: AvatarTransport
    let maxConcurrent: Int
    let now: @Sendable () -> Date
    private var inFlight: [URL: Task<URL?, Never>] = [:]
    private var failedUntil: [URL: Date] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var downloads = 0
    /// Off when the user turned off public profiles: nothing new is downloaded; cached thumbnails are still shown.
    public private(set) var enabled = true

    /// Turning downloads off also cancels the ones in flight.
    public func setEnabled(_ on: Bool) {
        enabled = on
        guard !on else { return }
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
    }

    /// Bumped when the stored thumbnail format changes; files of other versions are ignored and removed.
    public static let cacheVersion = "v1"

    /// `root` holds one directory per cache version.
    public init(directory root: URL, transport: AvatarTransport, maxConcurrent: Int = 3, now: @escaping @Sendable () -> Date = { Date() }) {
        let directory = root.appendingPathComponent(Self.cacheVersion, isDirectory: true)
        if let old = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for entry in old where entry.lastPathComponent != Self.cacheVersion { try? FileManager.default.removeItem(at: entry) }
        }
        self.directory = directory; self.transport = transport; self.maxConcurrent = max(1, maxConcurrent); self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
    }

    /// The cached thumbnail for `url`, if one was downloaded (safe from any thread).
    public nonisolated func cachedFile(for url: URL) -> URL? {
        let file = fileURL(for: url)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    public nonisolated func fileURL(for url: URL) -> URL {
        directory.appendingPathComponent(SHA256Hex.of(url.absoluteString) + ".png")
    }

    /// The thumbnail file for `url`, downloading it if needed. nil when the URL is refused, recently failed, or the
    /// download or image is unusable. Concurrent callers for one URL share a single download.
    public func thumbnail(for url: URL) async -> URL? {
        if let file = cachedFile(for: url) { return file }
        guard AvatarURLPolicy.validate(url.absoluteString) != nil else { return nil }
        guard enabled else { return nil }
        if let until = failedUntil[url], until > now() { return nil }
        if let task = inFlight[url] { return await task.value }
        let task = Task { await self.download(url) }
        inFlight[url] = task
        let result = await task.value
        if inFlight[url] == task { inFlight[url] = nil }
        return result
    }

    private func download(_ url: URL) async -> URL? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled, enabled else { return nil }
        do {
            downloads += 1
            let (data, response) = try await transport.fetch(url, maxBytes: Self.maxBytes)
            if let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(), !type.hasPrefix("image/") { throw AvatarError.notAnImage }
            // Turned off (or cancelled) while the bytes were arriving: nothing is decoded or stored.
            guard enabled, !Task.isCancelled else { return nil }
            let png = try Self.thumbnailPNG(data)
            let file = fileURL(for: url)
            try png.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            prune()
            return file
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
            // Image problems are permanent for this URL; network trouble is retried sooner.
            let permanent = (error as? AvatarError).map { $0 != .httpStatus(429) && $0 != .httpStatus(503) } ?? false
            failedUntil[url] = now().addingTimeInterval(permanent ? 6 * 3600 : 300)
            if failedUntil.count > 500 { failedUntil = failedUntil.filter { $0.value > now() } }
            return nil
        }
    }

    private func acquire() async {
        if running < maxConcurrent { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }

    /// Validates and shrinks downloaded bytes: only known still-image types, at most `maxSourcePixels`, decoded as an
    /// ImageIO thumbnail (no full-size bitmap) and re-encoded as PNG, which also drops any metadata.
    public static func thumbnailPNG(_ data: Data, maxPixels: Int = thumbnailPixels, maxSourcePixels: Int = maxSourcePixels) throws -> Data {
        guard !data.isEmpty, data.count <= maxBytes else { throw AvatarError.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), let type = CGImageSourceGetType(source) as String?,
              acceptedTypes.contains(type), CGImageSourceGetCount(source) >= 1 else { throw AvatarError.notAnImage }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw AvatarError.undecodable }
        guard width * height <= maxSourcePixels else { throw AvatarError.tooLarge }
        let thumbnail = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                         kCGImageSourceCreateThumbnailWithTransform: true,
                         kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, max(width, height))] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail) else { throw AvatarError.undecodable }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw AvatarError.undecodable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AvatarError.undecodable }
        return out as Data
    }

    /// Keeps the cache within `maxFiles` and `maxDiskBytes`, removing the oldest files first.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { file -> (URL, Date, Int)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard entries.count > Self.maxFiles || total > Self.maxDiskBytes else { return }
        entries.sort { $0.1 < $1.1 }
        var count = entries.count
        for (file, _, size) in entries {
            guard count > Self.maxFiles || total > Self.maxDiskBytes else { break }
            try? FileManager.default.removeItem(at: file)
            total -= size
            count -= 1
        }
    }

    /// Removes every cached avatar (disconnect, or Settings › Refresh Nostr profiles).
    public func clear() {
        failedUntil = [:]
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
