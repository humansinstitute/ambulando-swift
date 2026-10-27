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

    func testAutomaticTextAttachmentPagesRenameAndSurviveOfflineRelaunch() {
        let app = launch()
        openChannel(app, "general")
        let composer = field(app)
        composer.tap(); composer.typeText("Keep this draft")
        let large = "\u{FEFF}" + String(repeating: "report 😀 e\u{301}\r\n", count: 240_000)
        UIPasteboard.general.string = large
        paste(app, into: composer)
        let card = app.buttons["composer.textcard.open"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertEqual(value(composer), "Keep this draft")
        app.buttons["composer.textcard.open"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "textfile.page").firstMatch.waitForExistence(timeout: 15))
        let editor = app.textViews["textfile.content"].exists ? app.textViews["textfile.content"] : app.textViews["textfile.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual((editor.value as? String ?? "").unicodeScalars.count, 14_001)
        let name = app.textFields["textfile.name"]
        XCTAssertTrue(name.exists)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + "Offline report.txt")
        app.buttons["textfile.save"].tap()
        XCTAssertTrue(app.staticTexts["Offline report.txt"].waitForExistence(timeout: 10))
        XCTAssertEqual(value(composer), "Keep this draft")
        // Reopen the same disposable test container, retaining draft and staged bytes.
        app.terminate()
        app.launchArguments.removeAll { $0 == "-AmbulandoFixtureReset" }
        app.launchArguments.append("-AmbulandoFixtureOffline")
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15))
        if app.buttons["channel.general"].exists { openChannel(app, "general") }
        XCTAssertTrue(app.staticTexts["Offline report.txt"].waitForExistence(timeout: 15))
        XCTAssertEqual(value(field(app)), "Keep this draft")
        app.buttons["composer.textcard.open"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "textfile.page").firstMatch.waitForExistence(timeout: 15))
        app.buttons["textfile.cancel"].tap()
        XCTAssertTrue(app.staticTexts["Offline report.txt"].exists)
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
        // The image's Markdown stays in the text where it was pasted (it can be moved or edited, as on the web); the
        // thumbnail above the field previews it and can remove it.
        XCTAssertTrue(uploadedStrip(app).waitForExistence(timeout: 20), "uploaded image previewed above the field: \(value(composer))")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove message-image-'")).firstMatch.exists, "thumbnail can be removed")
        let text = value(composer)
        XCTAssertTrue(text.hasPrefix("Hi plain words![message-image-"), "the image Markdown is where it was pasted: \(text)")
        XCTAssertTrue(text.contains("](storage://"), text)
        XCTAssertFalse(text.contains("[ Uploading"), text)

        // Typing goes on in the same field, and nothing was sent on its own.
        composer.typeText(" done")
        XCTAssertTrue(waitFor(composer, contains: " done"))
        XCTAssertTrue(app.buttons["composer.send"].isEnabled)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hi plain words")).firstMatch.exists, "not sent automatically")

        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hi plain words")).firstMatch.waitForExistence(timeout: 10),
                      "sent on Send")

        // The sent image opens large in the lightbox (Quick Look showed cached images as an empty page), and closes again.
        let image = app.descendants(matching: .any).matching(identifier: "image.loaded").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 20), "the sent image is shown inline")
        image.tap()
        let large = app.descendants(matching: .any)["lightbox.image"].firstMatch
        XCTAssertTrue(large.waitForExistence(timeout: 10), "the image opens in the lightbox")
        // The 24 × 16 sample is enlarged to its 4× limit (a larger image is fitted to the screen).
        XCTAssertEqual(large.frame.width, 96, accuracy: 1, "enlarged: \(large.frame)")
        XCTAssertTrue(app.buttons["lightbox.share"].exists, "it can be shared")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "chat-image-lightbox"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["lightbox.close"].firstMatch.tap()
        XCTAssertTrue(large.waitForNonExistence(timeout: 5), "closed")
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
        XCTAssertTrue(value(back).hasPrefix("Later ![message-image-"), "the image Markdown replaced its placeholder in place: \(value(back))")
        XCTAssertTrue(value(back).hasSuffix("still typing"), value(back))
        XCTAssertTrue(app.buttons["composer.send"].isEnabled)

        app.showChannels()
        openChannel(app, "deploys")
        XCTAssertFalse(uploadedStrip(app).exists, "the result went only to #general, not #deploys")
    }
}
