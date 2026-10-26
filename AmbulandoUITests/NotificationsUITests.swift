import XCTest

/// The notification inbox on local sample data (`-AmbulandoUITestFixture`): the bell, unread/all/archived views, read and
/// archive, opening a thread/task/document, a generic detail for another app's object, a live arrival, and the Lab
/// workspace (no inbox: "backend not supported"). Not evidence of live Tower behaviour.
@MainActor
final class NotificationsUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
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

    private func openNotifications(_ app: XCUIApplication) {
        let bell = app.buttons["notifications.open"].firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 15))
        bell.tap()
        XCTAssertTrue(app.otherElements["notifications.screen"].waitForExistence(timeout: 10) || app.navigationBars["Notifications"].waitForExistence(timeout: 10))
    }

    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(identifier: "notifications.row").containing(.staticText, identifier: title).firstMatch
    }

    func testBellShowsUnreadCountAndInboxListsTheSampleNotifications() {
        let app = launch()
        let bell = app.buttons["notifications.open"].firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 15))
        // Five unread (one is already read) once the sample inbox has been listed.
        let counted = NSPredicate(format: "label CONTAINS 'unread'")
        expectation(for: counted, evaluatedWith: bell)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(bell.label.contains("5 unread"), bell.label)
        capture(app, "notifications-bell")
        bell.tap()
        XCTAssertTrue(app.staticTexts["Ana mentioned you"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Ana assigned you a task"].exists)
        XCTAssertTrue(app.staticTexts["Blinkers needs attention"].exists)
        XCTAssertFalse(app.staticTexts["New replies in a conversation"].exists, "the already-read item is not in Unread")
        capture(app, "notifications-unread")
        app.segmentedControls["notifications.filter"].buttons["All"].tap()
        XCTAssertTrue(app.staticTexts["New replies in a conversation"].waitForExistence(timeout: 10))
        capture(app, "notifications-all")
    }

    func testMarkReadAndArchiveUpdateCountsAndFilters() {
        let app = launch()
        openNotifications(app)
        let mention = app.staticTexts["Ana mentioned you"]
        XCTAssertTrue(mention.waitForExistence(timeout: 15))
        mention.swipeRight()
        app.buttons["Read"].firstMatch.tap()
        XCTAssertTrue(mention.waitForNonExistence(timeout: 10), "a read item leaves the Unread view")
        app.segmentedControls["notifications.filter"].buttons["All"].tap()
        XCTAssertTrue(mention.waitForExistence(timeout: 10), "but stays in All")
        mention.swipeLeft()
        app.buttons["Archive"].firstMatch.tap()
        XCTAssertTrue(mention.waitForNonExistence(timeout: 10))
        app.segmentedControls["notifications.filter"].buttons["Archived"].tap()
        XCTAssertTrue(mention.waitForExistence(timeout: 15), "archived items are listed on request")
        capture(app, "notifications-archived")
        app.segmentedControls["notifications.filter"].buttons["Unread"].tap()
        let all = app.buttons["notifications.markAll"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        XCTAssertTrue(app.otherElements["notifications.empty"].waitForExistence(timeout: 15) || app.staticTexts["You're all caught up"].waitForExistence(timeout: 15))
        capture(app, "notifications-caught-up")
    }

    func testOpeningATaskAndAnAppObjectAndLiveArrival() {
        let app = launch()
        openNotifications(app)
        let generic = app.staticTexts["Blinkers needs attention"]
        XCTAssertTrue(generic.waitForExistence(timeout: 15))
        generic.tap()
        XCTAssertTrue(app.otherElements["notifications.detail"].waitForExistence(timeout: 10) || app.staticTexts["Notification"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'can\\'t open this kind of item'")).firstMatch.exists)
        capture(app, "notifications-generic-detail")
        app.buttons["Done"].firstMatch.tap()
        app.staticTexts["Ana assigned you a task"].tap()
        XCTAssertTrue(app.staticTexts["Review the native inbox"].waitForExistence(timeout: 15), "the task opens in Tasks")
        capture(app, "notifications-opened-task")
    }

    func testIncomingNotificationAppearsWithoutReopening() {
        let app = launch()
        app.buttons["settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let simulate = app.buttons["fixture.notification"]
        for _ in 0..<8 where !simulate.exists { app.swipeUp() }
        XCTAssertTrue(simulate.exists)
        for _ in 0..<8 where !app.descendants(matching: .any)["settings.notifications.alerts"].exists { app.swipeUp() }
        XCTAssertTrue(app.descendants(matching: .any)["settings.notifications.alerts"].exists, "alerts are stated as not available")
        capture(app, "notifications-settings")
        simulate.tap()
        app.buttons["Done"].firstMatch.tap()
        let bell = app.buttons["notifications.open"].firstMatch
        let six = NSPredicate(format: "label CONTAINS '6 unread'")
        expectation(for: six, evaluatedWith: bell)
        waitForExpectations(timeout: 30)
        bell.tap()
        XCTAssertTrue(app.staticTexts["Rick mentioned you"].waitForExistence(timeout: 15))
    }

    func testCategoryChoiceHidesItInThisAppsViewAndCountsAgree() {
        let app = launch()
        let bell = app.buttons["notifications.open"].firstMatch
        let five = NSPredicate(format: "label CONTAINS '5 unread'")
        expectation(for: five, evaluatedWith: bell)
        waitForExpectations(timeout: 20)
        app.buttons["settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let toggle = app.switches["settings.notifications.category.mention"]
        for _ in 0..<10 where !toggle.exists { app.swipeUp() }
        XCTAssertTrue(toggle.exists)
        capture(app, "notifications-settings-categories")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        sleep(2)
        capture(app, "notifications-settings-after-toggle")
        app.buttons["Done"].firstMatch.tap()
        // The two-update mention is hidden from Ambulando's view: list and count agree (4).
        let four = NSPredicate(format: "label CONTAINS '4 unread'")
        expectation(for: four, evaluatedWith: bell)
        waitForExpectations(timeout: 30)
        bell.tap()
        XCTAssertTrue(app.staticTexts["Ana assigned you a task"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Ana mentioned you"].exists)
    }
}
