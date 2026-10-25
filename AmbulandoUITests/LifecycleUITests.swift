import XCTest

/// Live updates and the background refresh pipeline on local sample data (`-AmbulandoUITestFixture`). The real store,
/// signer, sync engine, event cursor and stream parser run; Tower and its SSE route are in-process stand-ins, and the
/// background window is simulated (the simulator cannot be granted BGAppRefreshTask windows on demand). Not evidence
/// of live Tower behaviour or of iOS scheduling.
@MainActor
final class LifecycleUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15))
        return app
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }

    /// Text of a Settings row (label and value), scrolling it into view first.
    private func settingsRow(_ app: XCUIApplication, _ id: String, containing text: String) -> Bool {
        let row = app.descendants(matching: .any).matching(identifier: id).firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if row.exists, !row.isHittable { app.swipeUp() }
            if row.exists, "\(row.label) \((row.value as? String) ?? "")".contains(text) { return true }
            if !row.exists { app.swipeUp() }
            usleep(300_000)
        }
        return false
    }

    /// Another member's messages arrive over the event stream while the user is typing; the draft is untouched.
    func testLiveMessagesArriveWhileTyping() {
        let app = launch(["-AmbulandoFixtureLive"])
        let general = app.buttons["channel.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 15))
        general.tap()
        let field = composer(app)
        field.tap()
        field.typeText("Typing while updates arrive")
        XCTAssertTrue(app.staticTexts["Live update 2 from Ana"].waitForExistence(timeout: 20), "live message rendered without refresh")
        field.typeText(" still here")
        XCTAssertEqual(field.value as? String, "Typing while updates arrive still here", "no dropped or reset characters")
        app.buttons["settings"].tap()
        XCTAssertTrue(settingsRow(app, "settings.liveStatus", containing: "Connected"), "stream reported connected")
    }

    /// The same pipeline a BGAppRefreshTask runs: a change made while backgrounded is fetched through the event cursor.
    func testSimulatedBackgroundRefreshFetchesChangesAndReports() {
        let app = launch(["-AmbulandoFixtureSimulateBackgroundRefresh"])
        let label = app.staticTexts.matching(identifier: "fixture.background").firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 30))
        let done = NSPredicate(format: "label CONTAINS 'completed events=1'")
        expectation(for: done, evaluatedWith: label)
        waitForExpectations(timeout: 30)
        app.buttons["channel.general"].tap()
        XCTAssertTrue(app.staticTexts["Posted while the app was in the background"].waitForExistence(timeout: 10))
        app.buttons["settings"].tap()
        XCTAssertTrue(settingsRow(app, "settings.lastBackgroundRefresh", containing: "Updated"), "last background refresh shown")
    }

    /// Refresh while locked: enabling it, then a manual lock revokes it (paused until unlock).
    func testBackgroundCredentialToggleAndManualLockRevocation() {
        let app = launch([])
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        app.buttons["settings"].tap()
        let toggle = app.switches["settings.backgroundRefresh"]
        // Settings is a lazy list; the Profile and Nostr profiles sections (build 10) sit above this one.
        XCTAssertTrue(app.scrollTo(toggle))
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        let on = NSPredicate(format: "value == '1'")
        expectation(for: on, evaluatedWith: toggle)
        waitForExpectations(timeout: 10)
        for _ in 0..<4 where !app.buttons["Lock now"].isHittable { app.swipeDown() }
        app.buttons["Lock now"].tap()
        // Manual lock: the full-screen unlock replaces the workspace (the read-only key is revoked in the same step;
        // core tests prove the revocation, including a failing Keychain delete).
        XCTAssertTrue(app.secureTextFields["lock.pin"].waitForExistence(timeout: 10), "full-screen unlock after Lock now")
        let pin = app.secureTextFields["lock.pin"]
        pin.tap()
        pin.typeText("135790")
        app.buttons["lock.unlock"].tap()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15), "unlocking returns to the workspace")
        app.buttons["settings"].tap()
        let again = app.switches["settings.backgroundRefresh"]
        XCTAssertTrue(app.scrollTo(again))
        for _ in 0..<4 where !again.isHittable { app.swipeUp() }
        XCTAssertEqual(again.value as? String, "1", "the user's choice is kept and the key is provisioned again on unlock")
    }
}
