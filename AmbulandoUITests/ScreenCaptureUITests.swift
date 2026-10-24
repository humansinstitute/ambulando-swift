import XCTest

/// Captures review screenshots of the chat surfaces on sample data (kept in the result bundle).
@MainActor
final class ScreenCaptureUITests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureChatScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        capture(app, "1-channels")
        app.buttons["channel.general"].tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
        sleep(1)
        capture(app, "2-channel")
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        field.tap()
        field.typeText("Checking with @Ri")
        XCTAssertTrue(app.buttons["mention.Rick"].waitForExistence(timeout: 5))
        capture(app, "3-mention-picker")
        app.buttons["mention.Rick"].tap()
        app.buttons["composer.send"].tap()
        sleep(1)
        capture(app, "4-sent")
        let thread = app.buttons["thread.3"].firstMatch
        for _ in 0..<5 where !(thread.exists && thread.isHittable) { app.scrollViews.firstMatch.swipeDown() }
        thread.tap()
        sleep(1)
        capture(app, "5-thread")
    }
}
