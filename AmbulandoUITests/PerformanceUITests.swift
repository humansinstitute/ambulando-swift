import XCTest

/// XCTest performance metrics on local sample data (simulator). Labelled sample-data numbers: the simulator's CPU,
/// display timing and keyboard are not an iPhone's, so these are for comparison between builds and against the
/// matched no-sync control; device numbers come from the phone profiling run.
@MainActor
final class PerformanceUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func app(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture"] + extra
        return app
    }

    private static var options: XCTMeasureOptions {
        let o = XCTMeasureOptions()
        o.iterationCount = 3
        return o
    }

    /// Cold launch to the first frame (XCTApplicationLaunchMetric), on an already-populated store.
    func testColdLaunchToCachedWorkspace() {
        let prime = app(["-AmbulandoFixtureReset"])
        prime.launch()
        XCTAssertTrue(prime.buttons["channel.general"].waitForExistence(timeout: 20))
        prime.terminate()
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: Self.options) {
            let a = app()
            a.launch()
            XCTAssertTrue(a.buttons["channel.general"].waitForExistence(timeout: 20), "cached channel list shown")
            let launch = a.staticTexts.matching(identifier: "fixture.launch").firstMatch
            if launch.waitForExistence(timeout: 5) {
                print("LAUNCH-UI \(launch.label)")
                let ms = Double(launch.label.split(separator: "=").last?.dropLast(2) ?? "") ?? .infinity
                XCTAssertLessThanOrEqual(ms, 400, "first frame to cached channel list (architecture §5)")
            }
            a.terminate()
        }
    }

    /// Opening a channel and going back (navigation transition duration and hitches).
    func testOpenChannelNavigation() {
        let a = app(["-AmbulandoFixtureReset"])
        a.launch()
        let general = a.buttons["channel.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 20))
        general.tap()   // first open loads history; measured opens use the stored rows
        XCTAssertTrue(a.navigationBars["#general"].waitForExistence(timeout: 10))
        a.showChannels()
        measure(metrics: [XCTOSSignpostMetric.navigationTransitionMetric], options: Self.options) {
            general.tap()
            XCTAssertTrue(a.navigationBars["#general"].waitForExistence(timeout: 10))
            a.showChannels()
            XCTAssertTrue(general.waitForExistence(timeout: 10))
        }
    }

    /// Scrolling a channel while 20,000 rows are written into another channel of the same workspace.
    func testScrollDuringSyncStorm() { scroll(storm: true) }

    /// Matched control: identical scrolling with the storm's pacing but no writes.
    func testScrollControlWithoutStorm() { scroll(storm: false) }

    private func scroll(storm: Bool) {
        let a = app(["-AmbulandoFixtureReset", storm ? "-AmbulandoFixtureStorm" : "-AmbulandoFixtureStormControl"])
        a.launch()
        let general = a.buttons["channel.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 20))
        general.tap()
        let field = a.textFields["composer.field"].exists ? a.textFields["composer.field"] : a.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("s")   // the storm starts on the first keystroke
        let list = a.scrollViews.firstMatch
        list.swipeDown()      // dismisses the keyboard interactively
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: Self.options) {
            list.swipeDown(velocity: .fast)
            list.swipeUp(velocity: .fast)
        }
        let label = a.staticTexts.matching(identifier: "fixture.storm").firstMatch
        if label.waitForExistence(timeout: 5) {
            let deadline = Date().addingTimeInterval(60)
            while !label.label.hasPrefix("storm: done") && Date() < deadline { usleep(250_000) }
            print("SCROLL-UI \(storm ? "storm" : "control") \(label.label)")
        }
    }
}
