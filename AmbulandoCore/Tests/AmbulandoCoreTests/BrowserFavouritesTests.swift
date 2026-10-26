import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AmbulandoCore

// Browser favourites: what may be saved, duplicates, editing, ordering and the stored form. No web view.

final class BrowserFavouritesTests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    func testSavingAcceptsHTTPSPagesOnceAndDefaultsTheTitle() throws {
        var list = BrowserFavourites()
        let saved = try list.add(title: "  ", url: URL(string: "https://Example.com/app/")!, siteIcon: URL(string: "https://example.com/icon.png"))
        XCTAssertEqual(saved.title, "example.com")
        XCTAssertEqual(saved.siteIcon?.absoluteString, "https://example.com/icon.png")
        XCTAssertEqual(list.favourite(for: URL(string: "https://example.com/app#top"))?.id, saved.id, "case, trailing slash and fragment are ignored")
        XCTAssertNil(list.favourite(for: URL(string: "https://example.com/other")))
        XCTAssertThrowsError(try list.add(title: "Again", url: URL(string: "https://example.com:443/app")!)) {
            XCTAssertEqual($0 as? BrowserFavouriteError, .duplicate)
        }
        for refused in ["http://example.com", "https://user:pw@example.com", "https://node.fips/", "about:blank"] {
            XCTAssertThrowsError(try list.add(title: "x", url: URL(string: refused)!), refused) { XCTAssertEqual($0 as? BrowserFavouriteError, .address) }
        }
        let insecureIcon = try list.add(title: "B", url: URL(string: "https://b.example")!, siteIcon: URL(string: "http://b.example/i.png"))
        XCTAssertNil(insecureIcon.siteIcon, "only HTTPS icons are kept")
        XCTAssertEqual(list.items.count, 2)
    }

    func testEditingChecksTheAddressIconAndDuplicates() throws {
        var list = BrowserFavourites()
        let a = try list.add(title: "A", url: URL(string: "https://a.example")!, siteIcon: URL(string: "https://a.example/i.png"))
        let b = try list.add(title: "B", url: URL(string: "https://b.example")!)

        var edit = a
        edit.title = " Alpha "
        edit.symbol = " 🚀 "
        edit.image = png
        try list.update(edit)
        XCTAssertEqual(list.items[0].title, "Alpha")
        XCTAssertEqual(list.items[0].symbol, "🚀")
        XCTAssertEqual(list.items[0].image, png)
        XCTAssertNotNil(list.items[0].siteIcon, "same address keeps the site icon")

        edit = list.items[0]
        edit.url = URL(string: "https://alpha.example")!
        try list.update(edit)
        XCTAssertNil(list.items[0].siteIcon, "a new address drops the old site's icon")

        edit.url = b.url
        XCTAssertThrowsError(try list.update(edit)) { XCTAssertEqual($0 as? BrowserFavouriteError, .duplicate) }
        edit.url = URL(string: "http://alpha.example")!
        XCTAssertThrowsError(try list.update(edit)) { XCTAssertEqual($0 as? BrowserFavouriteError, .address) }
        edit = list.items[0]; edit.symbol = "ABCD"
        XCTAssertThrowsError(try list.update(edit)) { XCTAssertEqual($0 as? BrowserFavouriteError, .symbol) }
        edit = list.items[0]; edit.image = Data("not a png".utf8)
        XCTAssertThrowsError(try list.update(edit)) { XCTAssertEqual($0 as? BrowserFavouriteError, .image) }
        edit = list.items[0]; edit.symbol = "  "
        try list.update(edit)
        XCTAssertNil(list.items[0].symbol, "an empty text icon goes back to the picture or site icon")

        list.setSiteIcon(URL(string: "https://alpha.example/touch.png"), for: a.id)
        XCTAssertEqual(list.items[0].siteIcon?.absoluteString, "https://alpha.example/touch.png")
        list.remove(b.id)
        XCTAssertEqual(list.items.map(\.id), [a.id])
    }

    func testReorderingAndTheStoredFormRoundTrip() throws {
        var list = BrowserFavourites()
        let ids = try (1...4).map { try list.add(title: "S\($0)", url: URL(string: "https://s\($0).example")!).id }
        list.move(ids[3], to: 0)
        XCTAssertEqual(list.items.map(\.title), ["S4", "S1", "S2", "S3"])
        list.move(ids[3], to: 99)
        XCTAssertEqual(list.items.map(\.title), ["S1", "S2", "S3", "S4"])
        list.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(list.items.map(\.title), ["S2", "S3", "S1", "S4"], "drag reorder: before the item at offset 3")
        list.move(fromOffsets: IndexSet([2, 3]), toOffset: 0)
        XCTAssertEqual(list.items.map(\.title), ["S1", "S4", "S2", "S3"])

        var withIcon = list.items[0]; withIcon.image = png; withIcon.symbol = "★"
        try list.update(withIcon)
        let text = try XCTUnwrap(list.encoded())
        XCTAssertEqual(BrowserFavourites.decode(text), list)
        XCTAssertNil(BrowserFavourites().encoded(), "an empty list removes the stored value")
        XCTAssertEqual(BrowserFavourites.decode(nil), BrowserFavourites())
        XCTAssertEqual(BrowserFavourites.decode("not json"), BrowserFavourites())
    }

    func testDecodingDropsWhatTheBrowserWouldNotOpenOrShow() throws {
        let good = BrowserFavourite(title: "Good", url: URL(string: "https://good.example")!, siteIcon: URL(string: "http://good.example/i.png"),
                                    symbol: "TOOLONG", image: Data("jpeg?".utf8))
        let items = [good,
                     BrowserFavourite(title: "Dup", url: URL(string: "https://GOOD.example/")!),
                     BrowserFavourite(title: "Plain", url: URL(string: "http://plain.example")!)]
        let json = String(decoding: try JSONEncoder().encode(["version": AnyEncodable(1), "items": AnyEncodable(items)]), as: UTF8.self)
        let decoded = BrowserFavourites.decode(json)
        XCTAssertEqual(decoded.items.map(\.title), ["Good"])
        XCTAssertNil(decoded.items[0].siteIcon)
        XCTAssertNil(decoded.items[0].symbol)
        XCTAssertNil(decoded.items[0].image)
        XCTAssertEqual(decoded.items[0].initial, "G")
    }

    func testAPickedPhotoBecomesASmallPNGWithoutItsMetadata() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                   [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.5]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let icon = try XCTUnwrap(BrowserFavourites.iconPNG(from: jpeg as Data))
        XCTAssertTrue(BrowserFavourites.isPNG(icon))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(icon as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 256)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 128)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "location is not kept")
        XCTAssertNil(BrowserFavourites.iconPNG(from: Data("not an image".utf8)))
    }

    func testTheListIsBounded() throws {
        var list = BrowserFavourites()
        for n in 0..<BrowserFavourites.maxCount { try list.add(title: "", url: URL(string: "https://s\(n).example")!) }
        XCTAssertThrowsError(try list.add(title: "", url: URL(string: "https://one-more.example")!)) { XCTAssertEqual($0 as? BrowserFavouriteError, .full) }
    }
}

private struct AnyEncodable: Encodable {
    let encode: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encode = value.encode }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
