import XCTest

/// Lock gate and trusted-device session on sample data (`-AmbulandoUITestFixture`, fixture PIN 135790).
@MainActor
final class UnlockUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture"] + args
        app.launch()
        return app
    }

    private func unlock(_ app: XCUIApplication, pin: String) {
        let field = app.secureTextFields["lock.pin"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(pin)
        app.buttons["lock.unlock"].tap()
    }

    func testLockedLaunchShowsFullScreenGateAndRejectsWrongPin() {
        let prime = launch(["-AmbulandoFixtureReset"])   // connects the sample workspace
        XCTAssertTrue(prime.buttons["channel.general"].waitForExistence(timeout: 20))
        prime.terminate()
        let app = launch(["-AmbulandoFixtureLocked"])
        let shown = app.secureTextFields["lock.pin"].waitForExistence(timeout: 20)
        XCTAssertTrue(shown, "full-screen unlock shown while locked")
        XCTAssertFalse(app.buttons["channel.general"].exists, "the workspace is not shown behind the gate")
        unlock(app, pin: "111111")
        XCTAssertTrue(app.descendants(matching: .any)["lock.error"].waitForExistence(timeout: 10), "wrong PIN reported")
        XCTAssertTrue(app.secureTextFields["lock.pin"].exists, "still locked")
        unlock(app, pin: "135790")
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15), "correct PIN opens the workspace")
    }

    func testStaysUnlockedAcrossRelaunchUntilLockNow() {
        var app = launch(["-AmbulandoFixtureReset"])
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
        app.terminate()
        // Relaunch without the fixture's automatic unlock: only the trusted-device session can open it.
        app = launch(["-AmbulandoFixtureNoAutoUnlock"])
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20), "stays unlocked across relaunch")
        app.buttons["settings"].tap()
        let lockNow = app.buttons["Lock now"]
        XCTAssertTrue(lockNow.waitForExistence(timeout: 10))
        lockNow.tap()
        XCTAssertTrue(app.secureTextFields["lock.pin"].waitForExistence(timeout: 10), "Lock now shows the gate at once")
        app.terminate()
        app = launch(["-AmbulandoFixtureNoAutoUnlock"])
        XCTAssertTrue(app.secureTextFields["lock.pin"].waitForExistence(timeout: 20), "a manual lock survives relaunch")
        XCTAssertFalse(app.buttons["channel.general"].exists)
        unlock(app, pin: "135790")
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
    }
}
