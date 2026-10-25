import XCTest

/// The shared Workspace → Scope → Channel context on local sample data (`-AmbulandoUITestFixture`): the sidebar sets it,
/// Chat, Tasks, Docs and Files follow it, it survives relaunch, and the global Inbox routes back to a record's context.
/// Not evidence of live Tower behaviour.
@MainActor
final class NavigationUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture"] + (reset ? ["-AmbulandoFixtureReset"] : [])
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

    private func tab(_ app: XCUIApplication, _ name: String) { app.section(name) }

    private func contextLabel(_ app: XCUIApplication) -> String { app.buttons["context.bar"].firstMatch.label }

    func testSidebarContextDrivesEveryModeAndSurvivesRelaunch() {
        let app = launch(reset: true)
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        capture(app, "nav-chat-home")
        app.openSidebar()
        XCTAssertTrue(app.buttons["sidebar.scope.Ambulando"].exists)
        XCTAssertTrue(app.buttons["sidebar.channel.design"].exists)
        XCTAssertTrue(app.buttons["sidebar.workspace"].exists, "workspace switcher in the sidebar")
        capture(app, "nav-sidebar")
        app.buttons["sidebar.channel.design"].tap()
        // As on the web, a sidebar choice opens Deck for the new context (its Inbox card).
        XCTAssertTrue(app.staticTexts["Inbox: #design"].waitForExistence(timeout: 10), "Deck opens on the chosen channel's Inbox")
        XCTAssertTrue(app.buttons["section.deck"].isSelected)
        tab(app, "Chat")
        XCTAssertTrue(app.navigationBars["#design"].waitForExistence(timeout: 10), "Chat shows the chosen channel")
        XCTAssertTrue(contextLabel(app).contains("design"), contextLabel(app))
        capture(app, "nav-chat-design")

        // Every context-bound mode reads inside #design only.
        tab(app, "Tasks")
        XCTAssertTrue(app.buttons["task.Passage mark spacing"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["task.Write release notes for build 3"].exists, "a #general task is not shown in #design")
        XCTAssertTrue(contextLabel(app).contains("design"))
        capture(app, "nav-tasks-design")
        tab(app, "Docs")
        XCTAssertTrue(app.buttons["doc.Theme notes (Markdown)"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["doc.Native app plan"].exists)
        tab(app, "Files")
        XCTAssertTrue(app.buttons["file.palette.png"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["file.sync-results.txt"].exists)

        // A scope: its channels' records; Home: everything. Locking Tasks keeps it on a sidebar choice (web view lock).
        tab(app, "Tasks")
        let lock = app.buttons["context.lock"].firstMatch
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        lock.tap()
        XCTAssertTrue(lock.isSelected, "Tasks is locked")
        app.openSidebar()
        app.buttons["sidebar.scope.Operations"].tap()
        XCTAssertTrue(app.buttons["section.tasks"].isSelected, "the locked section stays")
        XCTAssertTrue(app.buttons["task.Rotate staging certificates"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["task.Passage mark spacing"].exists)
        XCTAssertTrue(contextLabel(app).contains("Operations"))
        app.buttons["context.home"].tap()
        XCTAssertTrue(app.buttons["task.Passage mark spacing"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.scrollTo(app.buttons["task.Rotate staging certificates"]), "Home lists every scope's tasks")

        // The selection is kept across relaunch (per connection and workspace).
        app.selectSidebarChannel("deploys")
        tab(app, "Chat")
        XCTAssertTrue(app.navigationBars["#deploys"].waitForExistence(timeout: 10))
        sleep(1)
        app.terminate()
        let relaunched = launch(reset: false)
        XCTAssertTrue(relaunched.navigationBars["#deploys"].waitForExistence(timeout: 15), "context restored after relaunch")
    }

    func testChannelThreadsListAndThreadNavigation() {
        let app = launch(reset: true)
        let general = app.buttons["channel.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 15))
        general.tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
        let pane = app.segmentedControls["channel.pane"]
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.buttons["Threads"].tap()
        let item = app.buttons["threadlist.item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "threads with replies are listed")
        XCTAssertTrue(item.label.contains("3 replies"), item.label)
        capture(app, "nav-thread-list")
        item.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ship it")).firstMatch.waitForExistence(timeout: 10))
        capture(app, "nav-thread-open")
        app.buttons["thread.focus.close"].firstMatch.tap()
        XCTAssertTrue(item.waitForExistence(timeout: 10), "closing returns to the channel's thread list")
        pane.buttons["Messages"].tap()
        XCTAssertTrue(app.buttons["thread.3"].firstMatch.waitForExistence(timeout: 10), "thread roots show their replies in the message list")
    }

    /// Deck reads the sidebar context like the web's Deck; opening a record from it returns to the same card.
    func testDeckFollowsTheContextAndBackReturnsToTheSameCard() {
        let app = launch(reset: true)
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        app.selectSidebarChannel("deploys")
        XCTAssertTrue(app.staticTexts["Inbox: #deploys"].waitForExistence(timeout: 10))
        let review = app.buttons.matching(NSPredicate(format: "identifier == 'deck.inbox.item' AND label CONTAINS 'Review the native inbox'")).firstMatch
        XCTAssertFalse(review.waitForExistence(timeout: 3), "a #general task is not in #deploys' Inbox")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'deck.inbox.item' AND label CONTAINS 'Rotate staging certificates'")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["context.home"].firstMatch.tap()
        // Home lists every scope; search finds the #general task among the workspace's activity (rows are lazy).
        let search = app.textFields["deck.inbox.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Review the native\n")
        XCTAssertTrue(review.waitForExistence(timeout: 15), "Home lists every scope")
        review.tap()
        XCTAssertTrue(app.staticTexts["Review the native inbox"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["section.deck"].isSelected, "the record opened on top of Deck")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(review.waitForExistence(timeout: 10), "Back returns to Deck's Inbox")
        XCTAssertTrue(app.buttons["deck.page.inbox"].isSelected)
        XCTAssertEqual(search.value as? String, "Review the native", "the search is kept on return")
    }
}
