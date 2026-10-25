import XCTest

/// The focused thread view (web-style thread modal) against local sample data (`-AmbulandoUITestFixture`): opening,
/// replying, closing back to the same place, the draft on reopen, relaunch, Search from another channel and workspace
/// switches. Only Tower is replaced by an in-process stand-in; this is not evidence of live Tower behaviour.
@MainActor
final class ThreadFocusUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(reset: Bool, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture"] + (reset ? ["-AmbulandoFixtureReset"] : []) + extra
        app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sample data on this'")).firstMatch.waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func focus(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["thread.focus"].firstMatch }

    private func composer(in container: XCUIElement) -> XCUIElement {
        let view = container.textViews["composer.field"].firstMatch
        return view.waitForExistence(timeout: 5) ? view : container.textFields["composer.field"].firstMatch
    }

    private func value(_ element: XCUIElement) -> String {
        let text = (element.value as? String) ?? ""
        return text == element.placeholderValue ? "" : text
    }

    private func openGeneralThread(_ app: XCUIApplication, replies: Int) {
        let general = app.buttons["channel.general"]
        if general.waitForExistence(timeout: 10) { general.tap() }
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
        let thread = app.buttons["thread.\(replies)"].firstMatch
        for _ in 0..<6 where !(thread.exists && thread.isHittable) { app.scrollViews.firstMatch.swipeDown() }
        thread.tap()
        XCTAssertTrue(focus(app).waitForExistence(timeout: 10), "the thread opens focused")
    }

    /// The iPhone's drawer opens from the toolbar; the iPad's sidebar is already shown.
    private func showSidebar(_ app: XCUIApplication) {
        if !app.buttons["sidebar.home"].firstMatch.waitForExistence(timeout: 3) { app.openSidebar() }
    }

    private func close(_ app: XCUIApplication) {
        app.buttons["thread.focus.close"].firstMatch.tap()
        XCTAssertTrue(focus(app).waitForNonExistence(timeout: 10), "Close dismisses the focused thread")
    }

    /// Open → reply → close back to the channel → reopen with the draft → relaunch restores it → closed state persists.
    func testOpenReplyCloseReopenKeepsDraftAndPlace() {
        let app = launch(reset: true)
        openGeneralThread(app, replies: 3)
        let panel = focus(app)
        XCTAssertTrue(app.staticTexts["thread.focus.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ship it")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["section.deck"].isHittable, "the app behind is out of reach")
        capture(app, "thread-focus-open")

        let reply = composer(in: panel)
        reply.tap()
        reply.typeText("Reply from focus")
        app.buttons["composer.send"].firstMatch.tap()
        XCTAssertTrue(panel.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Reply from focus")).firstMatch.waitForExistence(timeout: 10))
        reply.typeText("Draft kept in focus")
        sleep(1)   // draft debounce
        capture(app, "thread-focus-draft")
        close(app)

        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 5), "closing returns to the same channel")
        XCTAssertTrue(app.buttons["thread.4"].firstMatch.waitForExistence(timeout: 10), "the channel shows the new reply count")
        capture(app, "thread-focus-closed")

        openGeneralThread(app, replies: 4)
        XCTAssertEqual(value(composer(in: focus(app))), "Draft kept in focus", "the draft is kept on reopen")
        app.terminate()

        let relaunched = launch(reset: false)
        XCTAssertTrue(focus(relaunched).waitForExistence(timeout: 15), "the focused thread is restored on relaunch")
        XCTAssertEqual(value(composer(in: focus(relaunched))), "Draft kept in focus")
        close(relaunched)
        sleep(1)
        relaunched.terminate()

        let again = launch(reset: false)
        XCTAssertTrue(again.navigationBars["#general"].waitForExistence(timeout: 15))
        XCTAssertFalse(focus(again).waitForExistence(timeout: 3), "a closed thread stays closed after relaunch")
    }

    /// A conversation found in Search while another channel's Deck is open: it opens focused over Deck, and closing returns
    /// to the same Deck card and context.
    func testSearchFromAnotherChannelReturnsToTheSameDeck() {
        let app = launch(reset: true)
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        showSidebar(app)
        app.buttons["sidebar.channel.deploys"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Inbox: #deploys"].waitForExistence(timeout: 10))
        app.buttons["search"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Ship it")
        // Tasks and documents are listed first; the conversation is the message hit.
        let hit = app.buttons.matching(NSPredicate(format: "identifier == 'search.hit' AND label CONTAINS 'Ship it' AND label CONTAINS '#general'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 10))
        hit.tap()
        XCTAssertTrue(focus(app).waitForExistence(timeout: 10), "a conversation from Search opens focused")
        XCTAssertTrue(focus(app).staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ship it")).firstMatch.waitForExistence(timeout: 10))
        capture(app, "thread-focus-from-search")
        close(app)
        XCTAssertTrue(app.staticTexts["Inbox: #deploys"].waitForExistence(timeout: 5), "Deck and its context are unchanged behind the thread")
        XCTAssertTrue(app.buttons["section.deck"].isSelected)
    }

    /// Deck's pinned conversation and an Inbox conversation open focused once (never also pushed onto Deck), and closing
    /// returns to the same card with nothing pushed.
    func testDeckPinnedAndInboxThreadsOpenFocusedOverTheSameCard() {
        let app = launch(reset: true)
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        app.section("Deck")
        app.deckCard("pinned")
        let pinned = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck.pinned.' AND label BEGINSWITH 'Thread'")).firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 15), "the seeded thread pin")
        pinned.tap()
        XCTAssertTrue(focus(app).waitForExistence(timeout: 10), "a pinned conversation opens focused")
        XCTAssertTrue(focus(app).staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ship it")).firstMatch.waitForExistence(timeout: 10))
        capture(app, "thread-focus-from-deck-pin")
        close(app)
        XCTAssertTrue(app.buttons["deck.page.pinned"].isSelected, "the same Deck card")
        XCTAssertTrue(pinned.isHittable, "nothing was pushed onto Deck")

        app.deckCard("inbox")
        app.buttons["context.home"].firstMatch.tap()
        let search = app.textFields["deck.inbox.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Inbox counts\n")
        let item = app.buttons.matching(NSPredicate(format: "identifier == 'deck.inbox.item' AND label BEGINSWITH 'Chat' AND label CONTAINS 'Inbox counts'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "the conversation is in the Inbox")
        item.tap()
        XCTAssertTrue(focus(app).waitForExistence(timeout: 10), "an Inbox conversation opens focused")
        close(app)
        XCTAssertTrue(app.buttons["deck.page.inbox"].isSelected)
        XCTAssertTrue(item.isHittable, "nothing was pushed onto Deck")
        XCTAssertEqual(search.value as? String, "Inbox counts", "the Inbox search is kept")
    }

    /// A thread left open in one workspace never shows in another.
    func testWorkspaceSwitchShowsNoForeignThread() {
        let app = launch(reset: true)
        openGeneralThread(app, replies: 3)
        app.terminate()
        let relaunched = launch(reset: false)
        XCTAssertTrue(focus(relaunched).waitForExistence(timeout: 15))
        close(relaunched)
        showSidebar(relaunched)
        // The iPad sidebar's container identifier replaces the switcher's own; its label is the same on both.
        relaunched.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Switch workspace'")).firstMatch.tap()
        relaunched.buttons["Lab (sample)"].tap()
        XCTAssertTrue(relaunched.buttons["channel.notes"].waitForExistence(timeout: 15))
        XCTAssertFalse(focus(relaunched).waitForExistence(timeout: 3), "no thread from the other workspace")
    }
}
