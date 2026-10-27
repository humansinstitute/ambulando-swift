import UIKit
import XCTest

/// The composer's one strip of mention pills and image tiles, against the app's labelled local sample data
/// (`-AmbulandoUITestFixture`, simulator only; pasted images upload to the in-process stand-in, nothing is sent).
@MainActor
final class ComposerStripUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launchInGeneral(_ extra: [String] = []) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-AmbulandoDiagnosticPlainKeyboard"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sample data on this'")).firstMatch.waitForExistence(timeout: 15))
        let channel = app.buttons["channel.general"]
        XCTAssertTrue(channel.waitForExistence(timeout: 15))
        channel.tap()
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return (app, field)
    }

    /// Pastes a tall phone-screenshot-shaped image, as in the report that started this work.
    private func pasteImage(_ app: XCUIApplication, into field: XCUIElement, hue: UIColor) {
        UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 118, height: 256)).image { context in
            hue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 118, height: 256))
        }
        field.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "Paste offered in the edit menu")
        paste.tap()
    }

    private func tiles(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "composer.uploaded").descendants(matching: .any).matching(identifier: "image.loaded")
    }

    func testPillAndImageTileShareOneStripWithSeparatePreviewAndRemove() {
        let (app, field) = launchInGeneral()
        field.tap()
        field.typeText("@Ri")
        app.buttons["mention.rick"].tap()
        field.typeText("can we update the deck ")
        pasteImage(app, into: field, hue: .systemPurple)

        let pill = element(app, "composer.mention.pill")
        let tile = tiles(app).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "the upload shows as a tile")
        capture(app, "composer-strip-pill-and-tile")
        XCTAssertEqual(tile.frame.width, 72, accuracy: 1, "a comfortable square tile, not a sliver")
        XCTAssertEqual(tile.frame.height, 72, accuracy: 1)
        XCTAssertLessThan(pill.frame.maxX, tile.frame.minX, "the tile follows the pill")
        XCTAssertLessThan(abs(pill.frame.midY - tile.frame.midY), 12, "on the same line as the pill")

        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove message-image-'")).firstMatch
        XCTAssertTrue(remove.exists)
        XCTAssertGreaterThanOrEqual(remove.frame.width, 44); XCTAssertGreaterThanOrEqual(remove.frame.height, 44)
        let centre = CGPoint(x: tile.frame.midX, y: tile.frame.midY)
        XCTAssertFalse(remove.frame.contains(centre), "the tile's centre previews, it does not remove")

        // Preview leaves the draft, the pill and the tile as they were.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)).tap()
        XCTAssertTrue(element(app, "lightbox").waitForExistence(timeout: 5), "tapping the tile opens the in-app viewer")
        element(app, "lightbox.close").tap()
        XCTAssertTrue(element(app, "lightbox").waitForNonExistence(timeout: 5))
        XCTAssertTrue(tile.exists && pill.exists)

        // Remove takes only the image.
        remove.tap()
        XCTAssertTrue(tile.waitForNonExistence(timeout: 5), "the image is removed")
        XCTAssertTrue(pill.exists, "the mention stays")
        XCTAssertTrue(((field.value as? String) ?? "").hasPrefix("@rick can we update the deck"), "the text and exact mention stay")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "can we update the deck")).firstMatch.exists, "nothing was sent")
    }

    func testSeveralImagesWrapAndKeepTheFieldAndKeyboardControlsReachable() {
        let (app, field) = launchInGeneral()
        field.tap()
        field.typeText("@Ri")
        app.buttons["mention.rick"].tap()
        for hue in [UIColor.systemPurple, .systemOrange, .systemTeal, .systemPink] { pasteImage(app, into: field, hue: hue) }
        let all = tiles(app)
        let deadline = Date().addingTimeInterval(30)
        while all.count < 4 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        XCTAssertEqual(all.count, 4, "every pasted image has its own tile")
        capture(app, "composer-strip-wrapped")
        let frames = (0..<all.count).map { all.element(boundBy: $0).frame }
        let lines = Set(frames.map { Int($0.minY.rounded()) })
        if app.windows.firstMatch.frame.width < 500 {
            XCTAssertGreaterThan(lines.count, 1, "the strip wraps on a phone instead of scrolling sideways")
        }
        for frame in frames { XCTAssertLessThanOrEqual(frame.maxX, app.windows.firstMatch.frame.maxX, "no tile is pushed off screen") }
        XCTAssertTrue(field.isHittable, "the field stays reachable")
        XCTAssertTrue(app.buttons["composer.photo"].isHittable, "Photos stays reachable")
        XCTAssertTrue(app.buttons["composer.hideKeyboard"].isHittable, "Hide keyboard stays reachable")
        XCTAssertTrue(app.buttons["composer.send"].isHittable)
    }

    /// A failed image tile is one Retry target and its corner Remove another: each tap does only its own action.
    func testFailedTileRetryAndCornerRemoveHitOnlyTheirOwnAction() {
        // The next two stored-object downloads fail once each (HTTP 500 from the sample stand-in); later ones succeed.
        let (app, field) = launchInGeneral(["-AmbulandoFixtureFailImageDownloads", "2"])
        field.tap()
        field.typeText("@Ri")
        app.buttons["mention.rick"].tap()
        field.typeText("failed tiles ")
        pasteImage(app, into: field, hue: .systemTeal)
        pasteImage(app, into: field, hue: .systemOrange)
        let pill = element(app, "composer.mention.pill")
        let failed = app.descendants(matching: .any).matching(identifier: "composer.uploaded").descendants(matching: .any).matching(identifier: "image.error")
        let deadline = Date().addingTimeInterval(30)
        while failed.count < 2 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        XCTAssertEqual(failed.count, 2, "both first downloads fail and each tile says so")
        capture(app, "composer-strip-failed-tiles")
        let removes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove message-image-'"))
        XCTAssertEqual(removes.count, 2)

        // Hit areas: each target is at least 44pt, the tile centre is Retry and the corner is Remove.
        let first = failed.element(boundBy: 0), firstRemove = removes.element(boundBy: 0)
        XCTAssertGreaterThanOrEqual(first.frame.width, 44); XCTAssertGreaterThanOrEqual(first.frame.height, 44)
        XCTAssertGreaterThanOrEqual(firstRemove.frame.width, 44); XCTAssertGreaterThanOrEqual(firstRemove.frame.height, 44)
        XCTAssertFalse(firstRemove.frame.contains(CGPoint(x: first.frame.midX, y: first.frame.midY)), "the tile centre is Retry, not Remove")
        XCTAssertFalse(first.frame.contains(CGPoint(x: firstRemove.frame.maxX - 4, y: firstRemove.frame.minY + 4)), "the corner is Remove, not Retry")

        // Remove only removes: the other failed tile is not retried, and the mention and draft stay.
        firstRemove.tap()
        let gone = Date().addingTimeInterval(5)
        while removes.count > 1 && Date() < gone { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertEqual(removes.count, 1, "Remove takes that image")
        XCTAssertEqual(failed.count, 1, "the other tile is still failed: Remove did not retry anything")
        XCTAssertFalse(element(app, "lightbox").exists)
        XCTAssertTrue(pill.exists, "the mention stays")
        XCTAssertTrue(((field.value as? String) ?? "").hasPrefix("@rick failed tiles"), "the draft stays")

        // Retry only retries: the image loads, nothing is removed, no viewer opens, the mention and draft stay.
        let remaining = failed.element(boundBy: 0)
        remaining.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)).tap()
        let loaded = app.descendants(matching: .any).matching(identifier: "composer.uploaded").descendants(matching: .any)["image.loaded"].firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 15), "Retry loads the image")
        XCTAssertEqual(removes.count, 1, "Retry removes nothing")
        XCTAssertFalse(element(app, "lightbox").exists, "Retry does not open the viewer")
        XCTAssertTrue(pill.exists, "the mention stays")
        XCTAssertTrue(((field.value as? String) ?? "").hasPrefix("@rick failed tiles"), "the draft stays")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "failed tiles")).firstMatch.exists, "nothing was sent")
        capture(app, "composer-strip-retried-tile")
    }
}
