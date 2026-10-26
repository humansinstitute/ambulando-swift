#if AMBULANDO_TEST
import XCTest

/// Safety and launch contract for the dedicated Test build, without the legacy fixture flag.
@MainActor
final class TestVariantUITests: XCTestCase {
    func testDefaultSampleLaunchRelaunchAndReset() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.banner"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        app.buttons["channel.general"].tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
        let field = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        field.tap()
        field.typeText("Dedicated Test draft")
        sleep(1) // Let the normal draft debounce persist before terminating the process.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.banner"].waitForExistence(timeout: 20))
        let restored = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        XCTAssertTrue(restored.waitForExistence(timeout: 15))
        XCTAssertEqual(restored.value as? String, "Dedicated Test draft")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Ambulando Test sample draft after relaunch"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
        app.launchArguments = ["-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
        app.buttons["channel.general"].tap()
        let cleared = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        XCTAssertTrue(cleared.waitForExistence(timeout: 10))
        XCTAssertNotEqual(cleared.value as? String, "Dedicated Test draft")
    }

    func testMissingFixturesRefuseProductionFallback() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoTestMissingFixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ambulando Test requires local fixtures; production access refused.")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["channel.general"].exists)
        XCTAssertFalse(app.secureTextFields["nsec1…"].exists)
    }
}

#endif
