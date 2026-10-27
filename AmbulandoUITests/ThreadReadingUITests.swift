import XCTest

/// A long conversation opens with messages on screen without scrolling, and reopening it after reading back shows the
/// messages where the reader left them (never a blank list that only fills on scroll). Sample data
/// (`-AmbulandoUITestFixture`: #deploys holds a 60-reply conversation of mixed lengths).
@MainActor
final class ThreadReadingUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func focus(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["thread.focus"].firstMatch }

    /// Messages of the long conversation currently on screen.
    private func visibleReplies(_ app: XCUIApplication) -> [String] {
        let rows = focus(app).staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Rota reply' OR label BEGINSWITH 'Rota note'"))
        return rows.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map(\.label)
    }

    private func waitForVisibleReplies(_ app: XCUIApplication, _ why: String) -> [String] {
        for _ in 0..<20 {
            let shown = visibleReplies(app)
            if !shown.isEmpty { return shown }
            usleep(250_000)
        }
        XCTFail("no message on screen: \(why)")
        return []
    }

    private func open(_ app: XCUIApplication) {
        let root = app.buttons["thread.60"].firstMatch
        for _ in 0..<6 where !(root.exists && root.isHittable) { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        root.tap()
        XCTAssertTrue(focus(app).waitForExistence(timeout: 10), "the thread opens focused")
    }

    func testLongThreadOpensFilledAndReopensWhereTheReaderLeft() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sample data on this'")).firstMatch.waitForExistence(timeout: 20))
        app.selectSidebarChannel("deploys")
        // A sidebar choice opens Deck for the channel; the conversation list is in Chat.
        let chat = app.buttons["section.chat"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        XCTAssertTrue(app.navigationBars["#deploys"].waitForExistence(timeout: 10))

        // First open: the newest replies are on screen straight away.
        open(app)
        let first = waitForVisibleReplies(app, "first open")
        capture(app, "thread-first-open")
        XCTAssertTrue(first.contains { $0.hasPrefix("Rota reply 59") || $0.hasPrefix("Rota note 60") || $0.hasPrefix("Rota reply 58") }, "opens at the newest: \(first)")

        // Read back through the conversation, then close it.
        for _ in 0..<5 { focus(app).swipeDown() }
        sleep(1)
        let middle = waitForVisibleReplies(app, "after reading back")
        capture(app, "thread-read-back")
        app.buttons["thread.focus.close"].firstMatch.tap()
        XCTAssertTrue(focus(app).waitForNonExistence(timeout: 10))

        // Reopen several times: the same part of the conversation is on screen at once, without scrolling.
        for round in 1...3 {
            open(app)
            let again = waitForVisibleReplies(app, "reopen \(round)")
            capture(app, "thread-reopen-\(round)")
            XCTAssertFalse(Set(again).isDisjoint(with: middle), "reopen \(round) shows where the reader left (\(middle)), got \(again)")
            app.buttons["thread.focus.close"].firstMatch.tap()
            XCTAssertTrue(focus(app).waitForNonExistence(timeout: 10))
        }
    }
}
