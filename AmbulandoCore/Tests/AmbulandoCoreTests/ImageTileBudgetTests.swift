import CoreGraphics
import XCTest
@testable import AmbulandoCore

/// Decode size for square cropped tiles: short side covers the tile, long edge bounded.
final class ImageTileBudgetTests: XCTestCase {
    func testShortSideCoversTheTile() {
        // A 72pt tile at 3x is 216px. A 4000x3000 photo needs its short side at 216, so the long edge at 288.
        XCTAssertEqual(ImageTileBudget.longEdge(tile: 216, width: 4000, height: 3000), 288, accuracy: 0.001)
        XCTAssertEqual(ImageTileBudget.longEdge(tile: 216, width: 3000, height: 4000), 288, accuracy: 0.001, "orientation does not matter")
        XCTAssertEqual(ImageTileBudget.longEdge(tile: 216, width: 1000, height: 1000), 216, accuracy: 0.001)
    }

    func testPanoramasAreCoveredUpToTheCapThenSoften() {
        // 8:1 panorama: 216 x 8 = 1728, within the cap, so the short side still covers the tile.
        XCTAssertEqual(ImageTileBudget.longEdge(tile: 216, width: 16000, height: 2000), 1728, accuracy: 0.001)
        // 40:1 would need 8640: held at the cap (short side 102px, softer) rather than decoding more.
        XCTAssertEqual(ImageTileBudget.longEdge(tile: 216, width: 40000, height: 1000), ImageTileBudget.cap)
    }

    func testNeverAboveTheImageItself() {
        XCTAssertEqual(ImageTileBudget.longEdge(tile: 216, width: 120, height: 60), 120, "a small image is not enlarged")
    }

    func testUnknownOrInvalidSizesStayBounded() {
        XCTAssertEqual(ImageTileBudget.longEdge(tile: 216, width: nil, height: 100), 216)
        XCTAssertEqual(ImageTileBudget.longEdge(tile: 216, width: 0, height: 100), 216)
        XCTAssertEqual(ImageTileBudget.longEdge(tile: 216, width: .infinity, height: 100), 216)
        XCTAssertEqual(ImageTileBudget.longEdge(tile: .infinity, width: 100, height: 100), 1)
        XCTAssertEqual(ImageTileBudget.longEdge(tile: 9000, width: nil, height: nil), ImageTileBudget.cap)
    }
}
