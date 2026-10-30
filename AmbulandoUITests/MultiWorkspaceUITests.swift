import XCTest

/// Local fixture checks only; no claim of live Tower subscriptions or installed-device validation.
@MainActor
final class MultiWorkspaceUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture"] + (reset ? ["-AmbulandoFixtureReset"] : [])
        app.launch()
        return app
    }

    private func chooseWorkspaces(_ app: XCUIApplication) {
        app.openSidebar()
        let menu = app.buttons["sidebar.workspace"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Choose workspaces…"].tap()
        XCTAssertTrue(app.otherElements["workspace.selection"].waitForExistence(timeout: 10)
                      || app.navigationBars["Choose workspaces"].exists)
    }

    private func checkbox(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any)["workspace.enabled.\(label)"].firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOptInStackedNavigationCollapseAndExactWorkspaceRouting() {
        let app = launch(reset: true)
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
        chooseWorkspaces(app)
        let lab = checkbox(app, "Lab (sample)")
        XCTAssertTrue(lab.waitForExistence(timeout: 10))
        lab.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["workspace.home.Studio (sample)"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["workspace.home.Lab (sample)"].exists)
        let unread = app.buttons["workspace.unread.Studio (sample).general"]
        XCTAssertTrue(unread.waitForExistence(timeout: 15), "shared unread keeps the source workspace")
        XCTAssertTrue(unread.label.contains("Studio (sample)"))
        capture(app, "multi-workspace-stacked-navigation")
        let labNotes = app.buttons["workspace.channel.Lab (sample).notes"]
        XCTAssertTrue(labNotes.waitForExistence(timeout: 15))
        app.buttons["workspace.collapse.Lab (sample)"].tap()
        XCTAssertFalse(labNotes.exists, "collapse hides only the workspace tree")
        XCTAssertTrue(unread.exists, "another workspace's unread activity remains visible")
        app.buttons["sidebar.workspace"].firstMatch.tap()
        app.buttons["Choose workspaces…"].tap()
        let stillEnabled = checkbox(app, "Lab (sample)")
        XCTAssertTrue(stillEnabled.waitForExistence(timeout: 5))
        XCTAssertTrue(stillEnabled.isSelected || (stillEnabled.value as? String) == "Enabled" || (stillEnabled.value as? String) == "1",
                      "collapse is visual; the workspace remains checked")
        app.buttons["Done"].tap()
        app.buttons["workspace.collapse.Lab (sample)"].tap()
        XCTAssertTrue(labNotes.waitForExistence(timeout: 5))
        labNotes.tap()
        app.section("chat")
        XCTAssertTrue(app.staticTexts["Working in Lab (sample)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["context.workspace"].exists)
        capture(app, "multi-workspace-lab-context")
    }

    func testHeaderColourChangesAndWorkingContextInLightAndDark() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-appearance", appearance]
            app.launch()
            XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
            app.buttons["channel.general"].tap()
            XCTAssertTrue(app.staticTexts["Working in Studio (sample)"].waitForExistence(timeout: 10))
            for id in ["sidebar.open", "search", "notifications.open", "pin.toggle", "browser.open", "settings"] {
                let control = app.buttons[id].firstMatch
                XCTAssertTrue(control.exists && control.isHittable, id)
                XCTAssertGreaterThanOrEqual(control.frame.width, 44, id)
                XCTAssertGreaterThanOrEqual(control.frame.height, 44, id)
            }
            capture(app, "header-\(appearance)-blue-composer")
            chooseWorkspaces(app)
            app.buttons["workspace.colour.Studio (sample)"].tap()
            app.buttons["Red"].tap()
            app.buttons["Done"].tap()
            app.buttons["sidebar.channel.general"].firstMatch.tap()
            app.section("chat")
            XCTAssertTrue(app.buttons["search"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["settings"].exists)
            XCTAssertFalse(app.staticTexts["context.workspace"].exists)
            XCTAssertTrue(app.staticTexts["Working in Studio (sample)"].exists)
            capture(app, "header-\(appearance)-red-composer")
            let thread = app.buttons["thread.3"].firstMatch
            for _ in 0..<5 where !(thread.exists && thread.isHittable) { app.scrollViews.firstMatch.swipeDown() }
            XCTAssertTrue(thread.exists)
            thread.tap()
            let modal = app.descendants(matching: .any)["thread.focus"].firstMatch
            XCTAssertTrue(modal.staticTexts["Working in Studio (sample)"].waitForExistence(timeout: 10))
            capture(app, "header-\(appearance)-modal-wording")
            app.terminate()
        }
    }

    func testCompactWorkspaceRowsInBothAppearances() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-appearance", appearance]
            app.launch()
            XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
            chooseWorkspaces(app)
            checkbox(app, "Lab (sample)").tap()
            app.buttons["Done"].tap()
            for colour in ["Blue", "Green", "Purple", "Red", "Slate"] {
                let row = app.buttons["workspace.unread.Studio (sample).general"]
                XCTAssertTrue(row.waitForExistence(timeout: 10))
                XCTAssertLessThanOrEqual(row.frame.height, 40, "one compact line")
                XCTAssertTrue(row.label.contains("Studio (sample)"))
                XCTAssertTrue(row.label.contains("unread"))
                capture(app, "rows-\(appearance)-\(colour.lowercased())")
                if colour != "Slate" {
                    app.buttons["sidebar.workspace"].firstMatch.tap()
                    app.buttons["Choose workspaces…"].tap()
                    app.buttons["workspace.colour.Studio (sample)"].tap()
                    let next = ["Blue": "Green", "Green": "Purple", "Purple": "Red", "Red": "Slate"][colour]!
                    app.buttons[next].tap()
                    app.buttons["Done"].tap()
                }
            }
            app.terminate()
        }
    }

    func testPauseFinalWorkspacePersistsEmptySelectionAndReenable() {
        let app = launch(reset: true)
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
        chooseWorkspaces(app)
        checkbox(app, "Studio (sample)").tap()
        // The sheet stays mounted when its final checkbox pauses the workspace; close it to reveal the empty state.
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["workspace.empty.choose"].waitForExistence(timeout: 10))
        capture(app, "multi-workspace-empty-selection")
        app.terminate()
        let resumed = launch(reset: false)
        XCTAssertTrue(resumed.buttons["workspace.empty.choose"].waitForExistence(timeout: 20))
        resumed.buttons["workspace.empty.choose"].tap()
        let studio = checkbox(resumed, "Studio (sample)")
        XCTAssertTrue(studio.waitForExistence(timeout: 10))
        studio.tap()
        if resumed.buttons["Done"].exists { resumed.buttons["Done"].tap() }
        XCTAssertTrue(resumed.buttons["channel.general"].waitForExistence(timeout: 15))
    }
}
