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
}
