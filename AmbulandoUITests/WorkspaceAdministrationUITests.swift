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
        app.buttons["admin.save"].tap(); app.buttons["admin.confirm"].firstMatch.tap()
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
    func testPopulatedGroupQuickAddAndNestedMembership() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureAdmin", "-AmbulandoFixtureGroups", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        openGroups(app)
        capture(app, "iphone-group-browser-populated")
        let product = app.buttons["groups.open.10000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(product.waitForExistence(timeout: 10)); product.tap()
        let search = app.textFields["groups.add.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Rick")
        let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'groups.add.' AND identifier != 'groups.add.search'")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        capture(app, "iphone-group-typeahead-agent")
        candidate.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Added Rick'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(search.exists)
        capture(app, "iphone-group-agent-added")
        search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        app.segmentedControls["groups.add.mode"].buttons["Groups"].tap()
        search.tap(); search.typeText("Launch")
        let nested = app.buttons["groups.add.10000000-0000-4000-8000-000000000004"]
        XCTAssertTrue(nested.waitForExistence(timeout: 5)); nested.tap()
        XCTAssertTrue(app.staticTexts["Added Launch planning · Australia & Europe."].waitForExistence(timeout: 10))
        capture(app, "iphone-nested-group-attached")
        app.swipeUp()
        capture(app, "iphone-group-members-and-nested")
    }

    func testNewNpubEnrolsAtomicallyWithoutLeavingGroup() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureAdmin", "-AmbulandoFixtureGroups", "-AmbulandoFixtureReset"]
        app.launch(); XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15)); openGroups(app)
        app.buttons["groups.open.10000000-0000-4000-8000-000000000004"].tap()
        let search = app.textFields["groups.add.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("npub-bad")
        XCTAssertTrue(app.staticTexts["Enter a complete valid npub, including its checksum."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["groups.enrol"].exists)
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        search.typeText("npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg")
        app.swipeUp()
        let enrol = app.buttons["groups.enrol"]
        XCTAssertTrue(enrol.waitForExistence(timeout: 5)); enrol.tap()
        capture(app, "iphone-new-npub-confirmation")
        app.buttons["Confirm enrolment"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'to the workspace and group'")).firstMatch.waitForExistence(timeout: 10))
        capture(app, "iphone-new-npub-enrolled")
    }

}
