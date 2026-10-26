import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A site saved to the browser's new-tab page. The tile shows, in order of preference, the user's own picture, the
/// user's own short text (an emoji or initials), the icon the site advertised when it was saved, or the title's first
/// letter.
public struct BrowserFavourite: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: URL
    /// The site's own icon (`apple-touch-icon`, `icon`), HTTPS only, found when the page was saved.
    public var siteIcon: URL?
    /// The user's text icon: one to three characters, such as an emoji.
    public var symbol: String?
    /// The user's picture icon: PNG bytes, already scaled down on the device.
    public var image: Data?

    public init(id: UUID = UUID(), title: String, url: URL, siteIcon: URL? = nil, symbol: String? = nil, image: Data? = nil) {
        self.id = id; self.title = title; self.url = url; self.siteIcon = siteIcon; self.symbol = symbol; self.image = image
    }

    /// The letter shown when there is no icon.
    public var initial: String { (title.first ?? url.host?.first).map { String($0).uppercased() } ?? "?" }
}

public enum BrowserFavouriteError: Error, Equatable, Sendable {
    case address
    case duplicate
    case symbol
    case image
    case full

    public var message: String {
        switch self {
        case .address: "Enter an HTTPS address, for example example.com."
        case .duplicate: "That address is already a favourite."
        case .symbol: "Use up to three characters, such as an emoji."
        case .image: "That picture could not be used. Choose a PNG or JPEG photo."
        case .full: "There are already \(BrowserFavourites.maxCount) favourites. Remove one to add another."
        }
    }
}

/// The ordered favourites list, stored on this device (`LocalStore` app state under `stateKey`). It is separate from
/// website data and from per-site Nostr permissions, so clearing either keeps the favourites.
public struct BrowserFavourites: Codable, Sendable, Equatable {
    public static let stateKey = "browser.favourites.v1"
    public static let maxCount = 120
    public static let maxTitleLength = 80
    public static let maxSymbolLength = 3
    /// A picture icon after scaling; a larger one is refused rather than stored.
    public static let maxImageBytes = 512 * 1024

    public private(set) var items: [BrowserFavourite]

    public init(_ items: [BrowserFavourite] = []) { self.items = items }

    /// Same scheme, host, port, path and query; case-insensitive host; a trailing slash and the fragment are ignored.
    public static func canonical(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        parts.fragment = nil
        if parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string ?? url.absoluteString
    }

    /// An address a favourite may hold: an HTTPS page the browser opens, typed or full.
    public static func address(_ text: String) -> URL? { BrowserURLPolicy.typedAddress(text) }

    public func favourite(for url: URL?) -> BrowserFavourite? {
        guard let url else { return nil }
        let key = Self.canonical(url)
        return items.first { Self.canonical($0.url) == key }
    }

    /// Saves a page at the end of the list. The title defaults to the host.
    @discardableResult
    public mutating func add(title: String, url: URL, siteIcon: URL? = nil) throws -> BrowserFavourite {
        guard items.count < Self.maxCount else { throw BrowserFavouriteError.full }
        guard Self.opens(url) else { throw BrowserFavouriteError.address }
        guard favourite(for: url) == nil else { throw BrowserFavouriteError.duplicate }
        let made = BrowserFavourite(title: Self.title(title, url: url), url: url, siteIcon: Self.httpsIcon(siteIcon))
        items.append(made)
        return made
    }

    /// Replaces a favourite after checking it. A changed address drops the site icon found for the old one.
    public mutating func update(_ favourite: BrowserFavourite) throws {
        guard let index = items.firstIndex(where: { $0.id == favourite.id }) else { return }
        guard Self.opens(favourite.url) else { throw BrowserFavouriteError.address }
        if let other = self.favourite(for: favourite.url), other.id != favourite.id { throw BrowserFavouriteError.duplicate }
        var next = favourite
        next.title = Self.title(favourite.title, url: favourite.url)
        let symbol = favourite.symbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard symbol.count <= Self.maxSymbolLength else { throw BrowserFavouriteError.symbol }
        next.symbol = symbol.isEmpty ? nil : symbol
        if let image = favourite.image, !Self.isPNG(image) || image.count > Self.maxImageBytes { throw BrowserFavouriteError.image }
        next.siteIcon = Self.canonical(favourite.url) == Self.canonical(items[index].url) ? Self.httpsIcon(favourite.siteIcon) : nil
        items[index] = next
    }

    /// Records the icon a saved page advertised (found after saving, once the page answered).
    public mutating func setSiteIcon(_ icon: URL?, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), let icon = Self.httpsIcon(icon) else { return }
        items[index].siteIcon = icon
    }

    public mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    /// Moves a favourite to `index` in the list as it is after removing it (clamped to the ends).
    public mutating func move(_ id: UUID, to index: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: min(max(index, 0), items.count))
    }

    /// Moves the favourites at `offsets` so they sit before `destination`, as a list's drag-to-reorder reports it.
    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.filter { items.indices.contains($0) }.map { items[$0] }
        let before = items[..<min(max(destination, 0), items.count)].filter { item in !moving.contains { $0.id == item.id } }.count
        items.removeAll { item in moving.contains { $0.id == item.id } }
        items.insert(contentsOf: moving, at: before)
    }

    // MARK: Storage

    public func encoded() -> String? {
        guard !items.isEmpty, let data = try? JSONEncoder().encode(Stored(version: 1, items: items)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The stored list; anything unreadable, unopenable or oversized is dropped rather than shown.
    public static func decode(_ text: String?) -> BrowserFavourites {
        guard let data = text?.data(using: .utf8), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return .init() }
        var seen = Set<String>()
        let items = stored.items.prefix(maxCount).compactMap { item -> BrowserFavourite? in
            guard opens(item.url), seen.insert(canonical(item.url)).inserted else { return nil }
            var item = item
            item.siteIcon = httpsIcon(item.siteIcon)
            if let image = item.image, !isPNG(image) || image.count > maxImageBytes { item.image = nil }
            if let symbol = item.symbol, symbol.isEmpty || symbol.count > maxSymbolLength { item.symbol = nil }
            return item
        }
        return .init(items)
    }

    private struct Stored: Codable {
        var version: Int
        var items: [BrowserFavourite]
    }

    // MARK: Rules

    static func opens(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && BrowserURLPolicy.decide(url, mainFrame: true) == .load }

    static func httpsIcon(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", BrowserURLPolicy.decide(url, mainFrame: true) == .load else { return nil }
        return url
    }

    static func title(_ text: String, url: URL) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? (url.host?.lowercased() ?? url.absoluteString) : trimmed).prefix(maxTitleLength))
    }

    /// A picked photo as a picture icon: at most `maxPixels` on its longer side, upright, re-encoded as PNG without the
    /// original's metadata (location, camera). Nil if the data is not an image ImageIO can read.
    public static func iconPNG(from data: Data, maxPixels: Int = 256) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maxImageBytes else { return nil }
        return output as Data
    }

    static func isPNG(_ data: Data) -> Bool { data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) }
}
