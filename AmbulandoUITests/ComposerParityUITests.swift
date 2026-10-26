import XCTest

/// Mention pills, Backspace and per-message menus against the app's labelled local sample data
/// (`-AmbulandoUITestFixture`, simulator only). Not evidence of live Tower behaviour.
@MainActor
final class ComposerParityUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15), "sample data is labelled")
        let general = app.buttons["channel.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 15))
        general.tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
        return app
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }

    private func value(_ element: XCUIElement) -> String {
        let text = (element.value as? String) ?? ""
        return text == element.placeholderValue ? "" : text
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPickedAgentShowsAsPillAndBackspaceRemovesTheWholeName() {
        let app = launch()
        let composer = field(app)
        composer.tap()
        composer.typeText("Ping @Ri")
        let pick = app.buttons["mention.rick"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "the list opens while typing @")
        pick.tap()
        XCTAssertEqual(value(composer), "Ping @rick ")
        XCTAssertTrue(element(app, "composer.mention.pill").waitForExistence(timeout: 5), "the picked agent shows as a pill")
        capture(app, "mention-pill")

        // First Backspace deletes the space after the name, the second removes the whole name and its pill.
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(value(composer), "Ping @rick")
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(value(composer), "Ping ")
        XCTAssertTrue(element(app, "composer.mention.pill").waitForNonExistence(timeout: 5), "the pill goes with the name")
    }

    func testPillCanBeRemovedWithItsButton() {
        let app = launch()
        let composer = field(app)
        composer.tap()
        composer.typeText("@Ri")
        app.buttons["mention.rick"].tap()
        let remove = app.buttons["composer.mention.remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertEqual(value(composer), "")
        XCTAssertTrue(element(app, "composer.mention.pill").waitForNonExistence(timeout: 5))
    }

    func testMessageMenuIsVisibleAndSyncedMessagesShowTheGreenDot() {
        let app = launch()
        XCTAssertTrue(app.buttons["message.actions"].firstMatch.waitForExistence(timeout: 10), "every message has a visible actions menu")
        // A channel opens at its newest message: the last menu button is the one on screen.
        let actions = app.buttons.matching(identifier: "message.actions").allElementsBoundByIndex.last(where: { $0.isHittable }) ?? app.buttons["message.actions"].firstMatch
        XCTAssertTrue(element(app, "message.sync.synced").exists, "a message Tower holds is marked as synced")
        capture(app, "message-menu-closed")
        actions.tap()
        XCTAssertTrue(app.buttons["message.copy"].waitForExistence(timeout: 5), "Copy message")
        XCTAssertTrue(app.buttons["message.ref"].exists, "FD Ref")
        capture(app, "message-menu-open")
    }
}
