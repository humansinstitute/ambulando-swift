import XCTest

/// Connection status on local sample data (`-AmbulandoUITestFixture`): the sample Tower's offline switch stands in for a
/// dropped network. Not evidence of live Tower behaviour.
@MainActor
final class ConnectionStatusUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func status(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["settings.connection.status"].firstMatch }

    private func waitForStatus(_ app: XCUIApplication, _ text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: status(app))], timeout: timeout) == .completed
    }

    func testConnectionLostIsSimpleAndRecoversWithoutUserAction() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-AmbulandoFixtureNoWorkspaceChoice"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["channel.notes"].waitForExistence(timeout: 15), "cached channels shown")
        app.buttons["settings"].firstMatch.tap()
        XCTAssertTrue(status(app).waitForExistence(timeout: 10))
        XCTAssertTrue(status(app).label.contains("Connected"), status(app).label)

        // The network drops; an explicit refresh meets it.
        app.setFixtureSwitch("fixture.offline", on: true)
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        app.buttons["Refresh now"].firstMatch.tap()
        // Reconnecting while retries run, then Connection lost once they are used up; never a raw error.
        XCTAssertTrue(waitForStatus(app, "Connection lost", timeout: 60), "status: \(status(app).label)")
        XCTAssertTrue(app.buttons["settings.connection.retry"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'NSURLErrorDomain' OR label CONTAINS 'notConnected'")).firstMatch.exists,
                       "no raw transport error")
        capture(app, "connection-lost")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["channel.notes"].exists, "cached content stays while the connection is lost")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'NSURLErrorDomain' OR label CONTAINS 'could not be completed'")).firstMatch.exists)
        capture(app, "connection-lost-cached-screen")

        // The network returns. Nobody taps Retry: the next scheduled probe recovers.
        app.buttons["settings"].firstMatch.tap()
        app.setFixtureSwitch("fixture.offline", on: false)
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        XCTAssertTrue(waitForStatus(app, "Connected", timeout: 60), "recovered by itself, status: \(status(app).label)")
        capture(app, "connection-recovered")
    }

    func testRetryButtonRecoversImmediately() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-AmbulandoFixtureOffline"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15))
        app.buttons["settings"].firstMatch.tap()
        XCTAssertFalse(status(app).label.contains("Connected"), status(app).label)
        app.setFixtureSwitch("fixture.offline", on: false)
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        let retry = app.buttons["settings.connection.retry"]
        if retry.waitForExistence(timeout: 5), retry.isEnabled { retry.tap() }
        XCTAssertTrue(waitForStatus(app, "Connected", timeout: 30), "status: \(status(app).label)")
    }
}
