import XCTest

/// The sidebar loads scopes and channels in the states real phones are in, on local sample data
/// (`-AmbulandoUITestFixture`). Not evidence of live Tower behaviour.
///
/// Regression for builds 6–7: a workspace choice is stored only when the switcher is used. Without one the sidebar never
/// started reading and stayed on "Loading navigation…", and the Chat channel list spun forever.
@MainActor
final class NavigationLoadUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture"] + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Opens the sidebar and checks the shown workspace's scopes and channels are listed (sample data: "Lab (sample)" sorts
    /// first and has Research/#notes; "Studio (sample)" has Ambulando/#general and Operations/#deploys).
    private func assertSidebarLoaded(_ app: XCUIApplication, scopes: [String], channels: [String], workspace: String? = nil, _ note: String) {
        app.openSidebar()
        if let workspace {
            let group = app.descendants(matching: .any)["workspace.group.\(workspace)"].firstMatch
            XCTAssertTrue(group.waitForExistence(timeout: 15), "workspace group listed: \(note)")
            for scope in scopes { XCTAssertTrue(group.buttons[scope].exists, "\(scope) in \(workspace): \(note)") }
            for channel in channels {
                XCTAssertTrue(app.buttons["workspace.channel.\(workspace).\(channel)"].exists, "#\(channel) in \(workspace): \(note)")
            }
        } else {
            XCTAssertTrue(app.buttons["sidebar.scope.\(scopes[0])"].waitForExistence(timeout: 15), "scopes listed: \(note)")
            for scope in scopes { XCTAssertTrue(app.buttons["sidebar.scope.\(scope)"].exists, "\(scope): \(note)") }
            for channel in channels { XCTAssertTrue(app.buttons["sidebar.channel.\(channel)"].exists, "#\(channel): \(note)") }
        }
        XCTAssertFalse(app.staticTexts["sidebar.state.loading"].exists, "not stuck loading: \(note)")
        XCTAssertFalse(app.staticTexts["sidebar.state.error"].exists, note)
    }

    private func workspaceLabel(_ app: XCUIApplication) -> String { app.buttons["sidebar.workspace"].firstMatch.label }

    func testSidebarLoadsWhenNoWorkspaceWasEverChosen() {
        var app = launch(["-AmbulandoFixtureReset", "-AmbulandoFixtureNoWorkspaceChoice"])
        XCTAssertTrue(app.buttons["channel.notes"].waitForExistence(timeout: 15), "Chat lists the first workspace's channels")
        assertSidebarLoaded(app, scopes: ["Research"], channels: ["notes"], "first launch")
        XCTAssertTrue(workspaceLabel(app).contains("Lab (sample)"), workspaceLabel(app))
        capture(app, "navload-no-choice-sidebar")
        app.buttons["sidebar.channel.notes"].tap()
        // As on the web, a sidebar choice opens Deck for the channel; Chat then shows it.
        XCTAssertTrue(app.staticTexts["Inbox: #notes"].waitForExistence(timeout: 10), "Deck opens for the chosen channel")
        app.section("Chat")
        XCTAssertTrue(app.navigationBars["#notes"].waitForExistence(timeout: 10), "Chat shows the chosen channel")

        // Relaunch: still no stored workspace choice; the saved scopes and the chosen channel come back.
        app.terminate()
        app = launch(["-AmbulandoFixtureNoWorkspaceChoice"])
        XCTAssertTrue(app.navigationBars["#notes"].waitForExistence(timeout: 15), "the context is restored for the shown workspace")
        assertSidebarLoaded(app, scopes: ["Research"], channels: ["notes"], "relaunch")

        // Switching workspace loads its navigation, and the choice is remembered.
        app.buttons["sidebar.workspace"].firstMatch.tap()
        app.buttons["Choose workspaces…"].tap()
        let studio = app.descendants(matching: .any)["workspace.enabled.Studio (sample)"].firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 5))
        studio.tap()
        app.buttons["Done"].tap()
        let studioHome = app.buttons["workspace.home.Studio (sample)"]
        XCTAssertTrue(studioHome.waitForExistence(timeout: 10))
        studioHome.tap()
        assertSidebarLoaded(app, scopes: ["Ambulando", "Operations"], channels: ["general", "design", "deploys"], workspace: "Studio (sample)", "after switching")
        app.terminate()
        app = launch(["-AmbulandoFixtureNoWorkspaceChoice"])
        assertSidebarLoaded(app, scopes: ["Ambulando", "Operations"], channels: ["general", "design", "deploys"], workspace: "Studio (sample)", "switch remembered")
        XCTAssertTrue(workspaceLabel(app).contains("Studio (sample)"), workspaceLabel(app))
    }

    func testSidebarFallsBackWhenTheChosenWorkspaceIsNoLongerListed() {
        let app = launch(["-AmbulandoFixtureReset", "-AmbulandoFixtureStaleWorkspaceChoice"])
        XCTAssertTrue(app.buttons["channel.notes"].waitForExistence(timeout: 15), "Chat lists a listed workspace's channels")
        assertSidebarLoaded(app, scopes: ["Research"], channels: ["notes"], "stale choice")
        XCTAssertTrue(workspaceLabel(app).contains("Lab (sample)"), workspaceLabel(app))
    }

    func testFailedScopeListIsShownWithRetry() {
        var app = launch(["-AmbulandoFixtureReset", "-AmbulandoFixtureScopesFail"])
        app.openSidebar()
        // Shown both in the sidebar and in the Chat channel list behind it.
        let error = app.staticTexts["sidebar.state.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15), "the failure is shown, not an empty sidebar")
        XCTAssertTrue(error.label.contains("500"), error.label)
        XCTAssertTrue(app.buttons["sidebar.retry"].firstMatch.exists)
        capture(app, "navload-scopes-failed")
        app.buttons["sidebar.retry"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["sidebar.state.error"].firstMatch.waitForExistence(timeout: 15), "still failing: the error stays visible")

        // Tower answers again: the same running app loads the scopes (no relaunch).
        app.buttons["sidebar.backdrop"].firstMatch.tap()
        app.buttons["settings"].firstMatch.tap()
        app.setFixtureSwitch("fixture.failScopes", on: false)   // scope lists answer again
        XCTAssertEqual(app.switches["fixture.reject"].value as? String, "0", "only the intended switch changed")
        app.buttons["Done"].tap()
        app.openSidebar()
        // The engine's own backoff retry may already have succeeded while Settings was open; otherwise Retry does it.
        let retry = app.buttons["sidebar.retry"].firstMatch
        if retry.exists { retry.tap() }
        XCTAssertTrue(app.buttons["sidebar.scope.Ambulando"].waitForExistence(timeout: 15), "recovers in the same process")
        XCTAssertTrue(app.buttons["sidebar.channel.general"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["sidebar.state.error"].waitForNonExistence(timeout: 5), "the error is gone after a successful retry")
        capture(app, "navload-retry-recovered")

        // And the next launch loads them from the saved copy and Tower.
        app.terminate()
        app = launch([])
        assertSidebarLoaded(app, scopes: ["Ambulando", "Operations"], channels: ["general", "deploys"], "after recovery")
    }
    private func restores(_ app: XCUIApplication) -> String {
        let row = app.descendants(matching: .any)["fixture.restores"].firstMatch
        // The sample-data section is at the bottom of a lazy list: it exists only once scrolled to.
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // LabeledContent reads as "Context restores" with value "1", or as one combined label.
        return "\(row.label) \((row.value as? String) ?? "")".split(whereSeparator: { $0 == " " || $0 == "," }).last.map(String.init) ?? ""
    }

    /// The launch restores the saved context exactly once, and a workspace list stored later (any refresh does) never
    /// restores again over what the user opened: the channel and the composer text stay. Reading the saved context is
    /// slowed by a second, so a list stored during the launch restore is always seen first; before this fix that started
    /// a second, unawaited restore which could land after the screen was ready.
    func testLaunchRestoresOnceAndALateWorkspaceListKeepsTheOpenChannelAndComposer() {
        let app = launch(["-AmbulandoFixtureReset", "-AmbulandoFixtureNoWorkspaceChoice", "-AmbulandoFixtureSlowContextRestore"])
        let notes = app.buttons["channel.notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 15))
        notes.tap()
        XCTAssertTrue(app.navigationBars["#notes"].waitForExistence(timeout: 10))
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Kept while the list is stored again")

        app.buttons["settings"].firstMatch.tap()
        XCTAssertEqual(restores(app), "1", "one launch restore")
        let again = app.buttons["fixture.storeWorkspaces"]
        for _ in 0..<4 where !(again.exists && again.isHittable) { app.swipeUp() }
        again.tap()
        sleep(3)   // longer than the slowed context read, so a restore started by the stored list would have landed
        XCTAssertEqual(restores(app), "1", "no restore after the late list")
        capture(app, "navload-late-list-settings")
        app.buttons["Done"].tap()

        XCTAssertTrue(app.navigationBars["#notes"].waitForExistence(timeout: 5), "the open channel stays")
        XCTAssertEqual(field.value as? String, "Kept while the list is stored again", "the composer text stays")
        capture(app, "navload-late-list-channel")
    }
}
