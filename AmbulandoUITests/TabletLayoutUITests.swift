import XCTest

/// Layout and retained-draft checks on explicitly labelled local sample data. These do not verify live Tower data.
@MainActor
final class TabletLayoutUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(compact: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-appearance", "light"]
        if compact { app.launchArguments.append("-AmbulandoFixtureCompactWindow") }
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["fixture.banner"].firstMatch.exists)
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "sample-data-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        let view = app.textViews["composer.field"]
        let field = view.exists ? view : app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }

    func testTabletPortraitLandscapeAndDraftRetention() {
        let app = launch()
        let sidebar = app.otherElements["tablet.sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        XCTAssertLessThan(app.buttons["section.chat"].frame.minX, 280)
        capture(app, "ipad-portrait-directory")
        app.buttons["channel.general"].tap()
        let field = composer(app)
        field.tap()
        field.typeText("Tablet draft survives rotation")
        XCTAssertTrue(field.isHittable)
        capture(app, "ipad-portrait-keyboard")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = expectation(for: NSPredicate { _, _ in
            app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        }, evaluatedWith: app)
        wait(for: [landscape], timeout: 10)
        // The orientation notification precedes completion of the window/compositor transition.
        let stableFrame = app.windows.firstMatch.frame
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.windows.firstMatch.frame, stableFrame)
        XCTAssertTrue(app.buttons["section.tasks"].waitForExistence(timeout: 10))
        XCTAssertEqual(composer(app).value as? String, "Tablet draft survives rotation")
        let bounds = app.windows.firstMatch.frame
        for id in ["composer.send", "browser.open", "settings"] {
            let button = app.buttons[id].firstMatch
            XCTAssertTrue(button.isHittable, id)
            XCTAssertTrue(bounds.contains(button.frame), "\(id) is inside the settled window")
        }
        capture(app, "ipad-landscape-keyboard")
        app.buttons["composer.hideKeyboard"].tap()
        app.buttons["sidebar.open"].tap()
        XCTAssertFalse(sidebar.exists)
        XCTAssertEqual(composer(app).value as? String, "Tablet draft survives rotation")
        app.buttons["sidebar.open"].tap()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        XCTAssertEqual(composer(app).value as? String, "Tablet draft survives rotation")
        app.buttons["section.tasks"].tap()
        XCTAssertTrue(app.buttons["tasks.new"].waitForExistence(timeout: 10))
        capture(app, "ipad-landscape-tasks")
        app.buttons["section.docs"].tap()
        let doc = app.buttons["doc.Native app plan"]
        XCTAssertTrue(doc.waitForExistence(timeout: 10))
        doc.tap()
        XCTAssertTrue(app.staticTexts["doc.title"].waitForExistence(timeout: 10))
        capture(app, "ipad-landscape-document")
        app.buttons["section.files"].tap()
        XCTAssertTrue(app.buttons["file.sync-results.txt"].waitForExistence(timeout: 10))
        capture(app, "ipad-landscape-files")
        app.buttons["section.chat"].tap()
        XCTAssertEqual(composer(app).value as? String, "Tablet draft survives rotation")
        app.buttons["browser.open"].tap()
        XCTAssertTrue(app.textFields["browser.address"].waitForExistence(timeout: 10))
        capture(app, "ipad-landscape-browser")
        app.buttons["browser.return"].tap()
        XCTAssertEqual(composer(app).value as? String, "Tablet draft survives rotation")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        capture(app, "ipad-portrait-returned-draft")
    }

    func testCompactWindowKeepsNavigationAndDraft() {
        let app = launch(compact: true)
        XCTAssertFalse(app.otherElements["tablet.sidebar"].exists)
        app.buttons["channel.general"].tap()
        composer(app).tap()
        composer(app).typeText("Compact draft")
        XCTAssertTrue(composer(app).isHittable)
        capture(app, "compact-420-keyboard")
        app.buttons["composer.hideKeyboard"].tap()
        app.buttons["section.tasks"].tap()
        XCTAssertTrue(app.buttons["tasks.new"].waitForExistence(timeout: 10))
        app.buttons["section.chat"].tap()
        XCTAssertEqual(composer(app).value as? String, "Compact draft")
        app.buttons["sidebar.open"].tap()
        XCTAssertTrue(app.buttons["sidebar.home"].waitForExistence(timeout: 10))
        capture(app, "compact-420-drawer")
    }

    func testPhoneKeepsCompactShell() {
        let app = launch()
        XCTAssertFalse(app.otherElements["tablet.sidebar"].exists)
        app.buttons["channel.general"].tap()
        composer(app).tap()
        composer(app).typeText("Phone draft")
        XCTAssertTrue(composer(app).isHittable)
        capture(app, "iphone-keyboard")
        app.buttons["composer.hideKeyboard"].tap()
        app.buttons["section.tasks"].tap()
        app.buttons["section.chat"].tap()
        XCTAssertEqual(composer(app).value as? String, "Phone draft")
        capture(app, "iphone-returned-draft")
    }
}
