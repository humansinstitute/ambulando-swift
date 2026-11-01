import XCTest

/// Captures Chat (#general) and Deck cards on labelled sample data in light and dark, for visual comparison with other
/// clients. Reference screenshots only; asserts nothing about behaviour.
@MainActor
final class VisualReferenceCaptureUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func run(_ appearance: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-appearance", appearance]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
        capture("\(appearance)-chat-directory")
        app.buttons["channel.general"].tap()
        XCTAssertTrue(app.buttons["composer.send"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        capture("\(appearance)-chat-general")
        app.section("Deck")
        for card in ["hello", "inbox", "recent", "pinned", "canvas"] {
            let dot = app.buttons["deck.page.\(card)"].firstMatch
            guard dot.waitForExistence(timeout: 5) else { continue }
            dot.tap()
            Thread.sleep(forTimeInterval: 1.5)
            capture("\(appearance)-deck-\(card)")
        }
    }

    func testCaptureLight() { run("light") }
    func testCaptureDark() { run("dark") }
}
