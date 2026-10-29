import XCTest

@MainActor final class WorkspaceAdministrationUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }
    private func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureAdmin"] + (reset ? ["-AmbulandoFixtureReset"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        return app
    }
    private func openGroups(_ app: XCUIApplication) {
        app.openSidebar()
        let menu = app.buttons["sidebar.workspace"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        app.buttons["Manage Workspace"].tap()
        let groups = app.buttons["admin.section.groups"].firstMatch
        XCTAssertTrue(groups.waitForExistence(timeout: 5)); groups.tap()
        XCTAssertTrue(app.buttons["admin.editor.group"].waitForExistence(timeout: 10))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testGroupWriteAndDraftRelaunchInNativeManagement() {
        var app = launch()
        openGroups(app)
        capture(app, "iphone-workspace-groups")
        app.buttons["admin.editor.group"].tap()
        let name = app.textFields["admin.field.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Operations fixture")
        app.buttons["keyboard.done"].firstMatch.tap()
        app.buttons["admin.save"].tap(); app.buttons["admin.confirm"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Saved on Tower'")).firstMatch.waitForExistence(timeout: 10))
        capture(app, "iphone-group-confirmed")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Operations fixture"].waitForExistence(timeout: 10))
        app.buttons["admin.editor.group"].tap()
        let restored = app.textFields["admin.field.name"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        restored.tap(); restored.typeText(" unsent draft")
        sleep(1)
        app.terminate(); app = launch(reset: false); openGroups(app)
        app.buttons["admin.editor.group"].tap()
        XCTAssertTrue(app.textFields["admin.field.name"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textFields["admin.field.name"].value as? String)?.contains("unsent draft") == true)
        capture(app, "iphone-admin-draft-restored")
    }
    func testReadOnlyIdentityCannotUseAdministratorControls() {
        let app = XCUIApplication(); app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]; app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15)); openGroups(app)
        XCTAssertFalse(app.buttons["admin.editor.group"].isEnabled)
        capture(app, "iphone-workspace-read-only")
    }
}
