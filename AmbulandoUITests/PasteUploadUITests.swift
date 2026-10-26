import UIKit
import XCTest

/// Pasting into the chat composer against the app's local sample data (`-AmbulandoUITestFixture`): text pastes as
/// before, images upload to (sample) workspace storage and become storage Markdown at the caret, an offline upload
/// fails with Retry, stays with its own channel's draft across navigation, and nothing is sent automatically.
/// The paste goes through the system edit menu, so this is the explicit Paste a person makes.
@MainActor
final class PasteUploadUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-AmbulandoDiagnosticPlainKeyboard"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15), "sample data is labelled")
        return app
    }

    private func openChannel(_ app: XCUIApplication, _ name: String) {
        let channel = app.buttons["channel.\(name)"]
        if !channel.waitForExistence(timeout: 15) {
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "no-channel-\(name)"; tree.lifetime = .keepAlways; add(tree)
            XCTFail("channel \(name) listed")
        }
        channel.tap()
        XCTAssertTrue(app.navigationBars["#\(name)"].waitForExistence(timeout: 10))
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }

    private func value(_ element: XCUIElement) -> String {
        let text = (element.value as? String) ?? ""
        return text == element.placeholderValue ? "" : text
    }

    /// Long-press in the field and choose Paste from the edit menu.
    private func paste(_ app: XCUIApplication, into field: XCUIElement) {
        field.press(forDuration: 1.2)
        let item = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        if !item.waitForExistence(timeout: 5) {
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "no-paste-menu"; tree.lifetime = .keepAlways; add(tree)
            XCTFail("Paste offered in the edit menu")
        }
        item.tap()
    }

    private func samplePNG() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16)).image { context in
            UIColor.systemPurple.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
    }

    private func waitFor(_ field: XCUIElement, contains text: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if value(field).contains(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func uploadedStrip(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer.uploaded").firstMatch
    }

    func testPasteTextThenImageUploadsToStorageWithoutSending() {
        let app = launch()
        openChannel(app, "general")
        let composer = field(app)
        composer.tap()
        composer.typeText("Hi ")

        // Ordinary text paste is the system's own.
        UIPasteboard.general.string = "plain words"
        paste(app, into: composer)
        XCTAssertTrue(waitFor(composer, contains: "plain words"), "text pasted: \(value(composer))")
        XCTAssertFalse(value(composer).contains("Uploading"), "text paste does not start an upload")

        // An image: placeholder at the caret, then the storage Markdown the web inserts.
        UIPasteboard.general.image = samplePNG()
        paste(app, into: composer)
        // The upload shows as a thumbnail above the field (removable), not as Markdown in the text.
        XCTAssertTrue(uploadedStrip(app).waitForExistence(timeout: 20), "uploaded image shown above the field: \(value(composer))")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove message-image-'")).firstMatch.exists, "thumbnail can be removed")
        let text = value(composer)
        XCTAssertFalse(text.contains("storage://"), "no raw Markdown in the field: \(text)")
        XCTAssertTrue(text.hasPrefix("Hi plain words"), "earlier text kept: \(text)")
        XCTAssertFalse(text.contains("[ Uploading"), text)

        // Typing goes on in the same field, and nothing was sent on its own.
        composer.typeText(" done")
        XCTAssertTrue(waitFor(composer, contains: " done"))
        XCTAssertTrue(app.buttons["composer.send"].isEnabled)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hi plain words")).firstMatch.exists, "not sent automatically")

        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hi plain words")).firstMatch.waitForExistence(timeout: 10),
                      "sent on Send")
    }

    func testOfflinePasteFailsWithRetryAndStaysWithItsChannel() {
        let app = launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        app.buttons["settings"].firstMatch.tap()
        app.setFixtureSwitch("fixture.offline", on: true)
        app.navigationBars["Settings"].buttons["Done"].tap()

        openChannel(app, "general")
        let composer = field(app)
        composer.tap()
        composer.typeText("Later ")
        UIPasteboard.general.image = samplePNG()
        paste(app, into: composer)
        let status = app.staticTexts["Offline. Retry when connected."]
        XCTAssertTrue(status.waitForExistence(timeout: 15), "offline upload fails visibly")
        XCTAssertTrue(value(composer).contains("[ Uploading image "), "placeholder kept for Retry: \(value(composer))")
        XCTAssertFalse(app.buttons["composer.send"].isEnabled, "a placeholder is never sent")

        // The composer stays responsive while the upload is unresolved.
        composer.typeText("still typing")
        XCTAssertTrue(waitFor(composer, contains: "still typing"))

        // Another channel: its composer has nothing of this upload.
        app.showChannels()
        openChannel(app, "deploys")
        let other = field(app)
        XCTAssertFalse(value(other).contains("Uploading"), "other channel untouched: \(value(other))")
        XCTAssertFalse(app.otherElements["composer.upload"].exists)

        // Back online and back in #general: the draft still holds the upload, and Retry completes it there.
        app.showChannels()
        app.buttons["settings"].firstMatch.tap()
        app.setFixtureSwitch("fixture.offline", on: false)
        app.navigationBars["Settings"].buttons["Done"].tap()
        openChannel(app, "general")
        let back = field(app)
        XCTAssertTrue(waitFor(back, contains: "Later [ Uploading image "), "draft kept: \(value(back))")
        let retry = app.buttons["composer.upload.retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        XCTAssertTrue(uploadedStrip(app).waitForExistence(timeout: 20), "retried upload shown as a thumbnail: \(value(back))")
        XCTAssertTrue(value(back).hasSuffix("still typing"), value(back))
        XCTAssertTrue(app.buttons["composer.send"].isEnabled)

        app.showChannels()
        openChannel(app, "deploys")
        XCTAssertFalse(uploadedStrip(app).exists, "the result went only to #general, not #deploys")
    }
}
