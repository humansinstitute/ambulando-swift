import XCTest

/// WP4 gap: with the composer keyboard up, opening a message's context menu in a channel and closing it brought the
/// keyboard back without keeping the channel at its newest message. Sample data (`-AmbulandoUITestFixture`).
@MainActor
final class ScrollRestorationUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testContextMenuWithKeyboardKeepsNewestMessageInView() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        let general = app.buttons["channel.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 20))
        general.tap()
        let newest = app.staticTexts["Release notes for build 2 (#40)"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let settled = NSPredicate(format: "isHittable == true")
        expectation(for: settled, evaluatedWith: newest)
        waitForExpectations(timeout: 5)

        newest.press(forDuration: 1.0)
        let react = app.buttons["React"]
        XCTAssertTrue(react.waitForExistence(timeout: 5), "context menu opened")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()   // dismiss without choosing
        XCTAssertTrue(react.waitForNonExistence(timeout: 5))
        sleep(1)   // keyboard and list settle
        XCTAssertTrue(newest.isHittable, "newest message still visible above the composer after the menu closed")
    }
}
