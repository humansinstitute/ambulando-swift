import XCTest

/// Live agent activity in a conversation (sample data, `-AmbulandoFixtureAgentActivity`): Rick's public commentary
/// appears as it is published through the event stream, the turn clears when it completes (the durable reply stays),
/// and a turn that stops renewing its 20 s lease shows "Stopped responding" — never finished — while a draft in the
/// composer is kept throughout.
@MainActor
final class AgentActivityUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func openReview(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"] + extra
        app.launch()
        let general = app.buttons["channel.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 20))
        general.tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
        // The reviewed conversation (#39, three replies) is the second newest: wait for its reply count, then scroll gently.
        let thread = app.buttons["thread.3"].firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 20))
        for _ in 0..<5 where !thread.isHittable { app.scrollViews.firstMatch.swipeDown(velocity: .slow) }
        thread.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ship it")).firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func headerLabel(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'thread.activity.header' AND label CONTAINS %@", text)).firstMatch
    }

    /// The activity card's header text (agent and state), or a description of what is there instead.
    private func status(_ app: XCUIApplication) -> String {
        let header = app.descendants(matching: .any).matching(identifier: "thread.activity.header").firstMatch
        if header.exists { return header.label }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "hierarchy"; tree.lifetime = .keepAlways
        add(tree)
        return "<no header>"
    }

    private func line(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'thread.activity.line' AND label CONTAINS %@", text)).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["thread.focus"].firstMatch.textViews["composer.field"].firstMatch
    }

    func testPublicCommentaryAppearsLiveAndClearsOnCompletion() {
        let app = openReview(["-AmbulandoFixtureAgentActivity"])
        let reply = composer(app)
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        reply.tap()
        reply.typeText("Draft kept while Rick works")
        // Put the keyboard away (the draft stays) so the activity card at the end of the thread is on screen.
        let hide = app.descendants(matching: .any)["thread.focus"].firstMatch.buttons["composer.hideKeyboard"].firstMatch
        if hide.exists { hide.tap() } else { app.swipeDown() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(line(app, "Reading the conversation").waitForExistence(timeout: 20), "first public line arrives through the stream")
        XCTAssertTrue(status(app).contains("Working"), status(app))
        shot(app, "01-working-first-line")
        XCTAssertTrue(line(app, "Checking the outbox retry states").waitForExistence(timeout: 15), "later lines append while work happens")
        XCTAssertTrue(line(app, "Reading the conversation").exists, "earlier lines stay as history")
        shot(app, "02-working-more-lines")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Retry states are consistent")).firstMatch.waitForExistence(timeout: 40),
                      "the durable final reply arrives")
        XCTAssertTrue(headerLabel(app, containing: "Earlier activity · completed").waitForExistence(timeout: 10), "header leaves working on completion")
        XCTAssertFalse(headerLabel(app, containing: "Working").exists, "no working indicator after the terminal state")
        XCTAssertFalse(headerLabel(app, containing: "Stopped responding").exists, "no stopped flash on normal completion")
        shot(app, "03-completed")
        XCTAssertEqual(reply.value as? String, "Draft kept while Rick works", "live updates never touch the draft")
    }

    func testTurnThatStopsRenewingShowsStoppedRespondingNotFinished() {
        let app = openReview(["-AmbulandoFixtureAgentActivityStall"])
        XCTAssertTrue(line(app, "Comparing request ids across retries").waitForExistence(timeout: 30))
        XCTAssertTrue(status(app).contains("Working"), status(app))
        shot(app, "04-stall-working")
        // Lease 20 s after the last write, plus 15 s grace: cleared without any event from the producer.
        XCTAssertTrue(headerLabel(app, containing: "Stopped responding").waitForExistence(timeout: 60), "expired lease clears working locally")
        XCTAssertFalse(headerLabel(app, containing: "Working").exists)
        XCTAssertFalse(headerLabel(app, containing: "completed").exists, "never shown as finished")
        shot(app, "05-stopped-responding")
    }
}
