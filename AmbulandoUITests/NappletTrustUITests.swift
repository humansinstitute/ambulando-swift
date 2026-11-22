import XCTest

@MainActor
final class NappletTrustUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func launch(_ app: XCUIApplication, reset: Bool = false, extra: [String] = []) {
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureNappletTrust"] + (reset ? ["-AmbulandoFixtureReset"] : []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20), app.debugDescription)
        app.section("Toolbox")
        let daily = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Daily Metrics'")).firstMatch
        XCTAssertTrue(daily.waitForExistence(timeout: 10), app.debugDescription); daily.tap()
    }
    func testApprovalSurvivesReloadReopenProcessRestartAndCanBeForgotten() {
        let app = XCUIApplication()
        launch(app, reset: true)
        let approve = app.buttons["napplet.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["napplet.forget"].exists)
        approve.tap()
        let forget = app.buttons["napplet.forget"]
        XCTAssertTrue(forget.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.webViews.switches["Metrics"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["napplet.reload"].tap()
        XCTAssertTrue(forget.waitForExistence(timeout: 15)); XCTAssertFalse(approve.exists)
        app.buttons["napplet.close"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Daily Metrics'")).firstMatch.tap()
        XCTAssertTrue(forget.waitForExistence(timeout: 15)); XCTAssertFalse(approve.exists)
        app.terminate(); launch(app)
        XCTAssertTrue(forget.waitForExistence(timeout: 15)); XCTAssertFalse(approve.exists)
        app.webViews.switches["Metrics"].tap()
        let metric = app.webViews.textFields.firstMatch
        XCTAssertTrue(metric.waitForExistence(timeout: 10)); metric.tap(); metric.typeText("Synthetic unsaved metric")
        app.webViews.buttons["Add metric"].tap()
        forget.tap()
        XCTAssertTrue(app.buttons["Discard changes"].waitForExistence(timeout: 5))
        let keep = app.buttons.matching(NSPredicate(format: "label IN %@", ["Keep editing", "Cancel"])).firstMatch
        if keep.exists { keep.tap() } else { app.otherElements["PopoverDismissRegion"].firstMatch.tap() }
        XCTAssertTrue(forget.exists); XCTAssertFalse(approve.exists)
        XCTAssertTrue(app.webViews.textFields.matching(NSPredicate(format: "value == %@", "Synthetic unsaved metric")).firstMatch.exists, app.debugDescription)
        forget.tap(); app.buttons["Discard changes"].tap()
        XCTAssertTrue(approve.waitForExistence(timeout: 15)); XCTAssertFalse(forget.exists)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "native-trust-forgotten"; capture.lifetime = .keepAlways; add(capture)
    }
    func testExplicitUpdatePreservesTrackerAndPromptsOnceForChangedCode() {
        let app = XCUIApplication()
        launch(app, reset: true, extra: ["-AmbulandoFixtureTrackerUpdate"])
        XCTAssertTrue(app.buttons["napplet.approve"].waitForExistence(timeout: 15)); app.buttons["napplet.approve"].tap()
        let update = app.buttons["napplet.update"]
        XCTAssertTrue(update.waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.switches["Metrics"].waitForExistence(timeout: 15))
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "native-tracker-before-update"; before.lifetime = .keepAlways; add(before)
        app.webViews.switches["Metrics"].tap()
        let metric = app.webViews.textFields["Metric label"]
        XCTAssertTrue(metric.waitForExistence(timeout: 10)); metric.tap(); metric.typeText("Synthetic update draft")
        app.webViews.buttons["Add metric"].tap()
        update.tap(); XCTAssertTrue(app.buttons["Discard changes"].waitForExistence(timeout: 5))
        let keep = app.buttons.matching(NSPredicate(format: "label IN %@", ["Keep editing", "Cancel"])).firstMatch
        if keep.exists { keep.tap() } else { app.otherElements["PopoverDismissRegion"].firstMatch.tap() }
        XCTAssertTrue(app.webViews.textFields.matching(NSPredicate(format: "value == %@", "Synthetic update draft")).firstMatch.exists)
        update.tap(); app.buttons["Discard changes"].tap()
        let confirm = app.buttons.matching(identifier: "napplet.update.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.buttons["napplet.approve"].waitForExistence(timeout: 15)); XCTAssertFalse(app.buttons["napplet.forget"].exists)
        app.buttons["napplet.approve"].tap()
        XCTAssertTrue(app.buttons["napplet.forget"].waitForExistence(timeout: 15)); XCTAssertFalse(update.exists)
        XCTAssertTrue(app.webViews.switches["History"].waitForExistence(timeout: 15), app.debugDescription)
        app.webViews.switches["History"].tap()
        let history = app.webViews.buttons["2024-02-29 · 2 answered"]
        XCTAssertTrue(history.waitForExistence(timeout: 10), app.debugDescription); history.tap()
        XCTAssertTrue(app.webViews.staticTexts["Synthetic archived answer (archived)"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.webViews.textFields.matching(NSPredicate(format: "value == %@", "0")).count, 1)
        let loaded = XCTAttachment(screenshot: app.screenshot()); loaded.name = "native-tracker-updated-loaded-history"; loaded.lifetime = .keepAlways; add(loaded)
        app.webViews.firstMatch.swipeUp()
        let values = XCTAttachment(screenshot: app.screenshot()); values.name = "native-tracker-updated-saved-values"; values.lifetime = .keepAlways; add(values)
        app.buttons["napplet.reload"].tap()
        XCTAssertTrue(app.buttons["napplet.forget"].waitForExistence(timeout: 15)); XCTAssertFalse(app.buttons["napplet.approve"].exists)
    }
    func testChangedCodeBindingAccessAndDeniedAccessDoNotReuseReceipt() {
        let app = XCUIApplication()
        launch(app, reset: true)
        XCTAssertTrue(app.buttons["napplet.approve"].waitForExistence(timeout: 15))
        app.buttons["napplet.approve"].tap()
        XCTAssertTrue(app.buttons["napplet.forget"].waitForExistence(timeout: 15))
        for change in ["-AmbulandoFixtureTrustCodeChanged", "-AmbulandoFixtureTrustBindingChanged", "-AmbulandoFixtureTrustReadOnly"] {
            app.terminate(); launch(app, extra: [change])
            XCTAssertTrue(app.buttons["napplet.approve"].waitForExistence(timeout: 15), change + app.debugDescription)
            XCTAssertFalse(app.buttons["napplet.forget"].exists)
        }
        app.terminate(); launch(app, extra: ["-AmbulandoFixtureTrustDenied"])
        XCTAssertTrue(app.staticTexts["Daily Metrics unavailable"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["napplet.approve"].exists); XCTAssertFalse(app.buttons["napplet.forget"].exists)
    }
}
