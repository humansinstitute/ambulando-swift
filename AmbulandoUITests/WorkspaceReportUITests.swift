import XCTest

@MainActor
final class WorkspaceReportUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testReportLoadsAndRemembersReadOnlyConsent() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureWorkspaceReport", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20), app.debugDescription)
        app.section("Toolbox")
        let report = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Workspace Report'")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10), app.debugDescription); report.tap()
        let approve = app.buttons["report.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 15), app.debugDescription); approve.tap()
        let total = app.webViews.staticTexts["123"].firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts["Server snapshot · 23 Nov 2026, 00:00 UTC · Complete for your access"].exists || app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Server snapshot'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["napplet.update"].exists)
        XCTAssertFalse(app.webViews.buttons["Save"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "workspace-report-loaded"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["report.reload"].tap()
        XCTAssertTrue(total.waitForExistence(timeout: 15), app.debugDescription); XCTAssertFalse(approve.exists)
        app.terminate()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureWorkspaceReport"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20)); app.section("Toolbox")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Workspace Report'")).firstMatch.tap()
        XCTAssertTrue(total.waitForExistence(timeout: 15), app.debugDescription); XCTAssertFalse(approve.exists)
        app.buttons["report.forget"].tap()
        XCTAssertTrue(approve.waitForExistence(timeout: 15), app.debugDescription)
    }
}
