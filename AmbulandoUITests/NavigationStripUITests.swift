import XCTest

@MainActor
final class NavigationStripUITests: XCTestCase {
    func testWholeStripScrollsAndNavigationResets() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture"]
        app.launch()
        let home = app.buttons["section.home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 20))
        let strip = app.descendants(matching: .any)["section.bar"].firstMatch
        let width = app.buttons["section.deck"].firstMatch.frame.width
        XCTAssertEqual(strip.frame.width / width, 4.5, accuracy: 0.15)
        home.tap()
        XCTAssertTrue(home.isSelected)
        strip.swipeLeft()
        XCTAssertFalse(home.isHittable, "Home scrolls away with the controls")
        let toolbox = app.buttons["section.toolbox"].firstMatch
        XCTAssertTrue(toolbox.isHittable)
        toolbox.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(home.isHittable, "actual navigation resets strip left")
        XCTAssertFalse(home.isSelected)
        home.tap()
        XCTAssertTrue(home.isSelected)
    }

    /// Run on both iPhone and iPad; compact uses the strip, wide uses the tablet sidebar.
    func testShowChatSettingRetainsConversationAndPersists() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        let general = app.buttons["channel.general"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["section.chat"].exists, "fresh default hides primary Chat control")
        general.tap() // Explicit Deck entry remains available while navigation is hidden.
        let field = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Visibility keeps this draft")
        app.buttons["composer.hideKeyboard"].firstMatch.tap()

        func setChat(_ on: Bool) {
            app.buttons["settings"].firstMatch.tap()
            let toggle = app.switches["settings.sections.chat"].firstMatch
            for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            if (toggle.value as? String == "1") != on { toggle.tap() }
            app.navigationBars["Settings"].buttons["Done"].tap()
        }
        setChat(true)
        XCTAssertTrue(app.buttons["section.chat"].firstMatch.exists)
        setChat(false)
        XCTAssertFalse(app.buttons["section.chat"].exists)
        XCTAssertEqual(field.value as? String, "Visibility keeps this draft")
        setChat(true)
        app.terminate()
        app.launchArguments = ["-AmbulandoUITestFixture"] // no reset or preference override
        app.launch()
        XCTAssertTrue(app.buttons["section.chat"].firstMatch.waitForExistence(timeout: 20), "ON survives relaunch")
        setChat(false)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["settings"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["section.chat"].exists, "OFF survives relaunch")
    }

}
