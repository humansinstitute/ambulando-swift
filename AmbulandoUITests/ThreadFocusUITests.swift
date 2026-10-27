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

    /// Closing and reopening a thread returns to the message the reader was on, not the newest; a thread left at its newest
    /// message reopens at the newest. While the thread is open only its own composer is reachable.
    func testReopenKeepsReadingPositionAndHidesTheAppBehind() {
        let app = launch(reset: true)
        openGeneralThread(app, replies: 3)
        let panel = focus(app)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "composer.field").count, 1,
                       "the channel composer behind the thread is hidden from accessibility")
        let root = panel.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND identifier != 'thread.focus.title'", "Ship it")).firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        let reply = composer(in: panel)
        reply.tap()
        // Tall replies until the first message has scrolled away, then more: the reopened thread has no keyboard, so its
        // list is taller than now (the iPad's card holds many more than the iPhone).
        var sent = 0, extra = 0
        while sent < 40 && extra < 6 {
            sent += 1
            if !root.isHittable { extra += 1 }
            reply.typeText("Filler reply #\(sent)#" + String(repeating: "\nmore", count: 5))
            app.buttons["composer.send"].firstMatch.tap()
        }
        let newest = panel.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Filler reply #\(sent)#")).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertFalse(root.isHittable, "the thread is longer than the screen")
        let list = panel.scrollViews.firstMatch
        for _ in 0..<8 where !(root.exists && root.isHittable) { list.swipeDown() }
        XCTAssertTrue(root.isHittable, "scrolled up to the first message")
        XCTAssertFalse(newest.isHittable)
        capture(app, "thread-focus-scrolled-up")
        close(app)

        openGeneralThread(app, replies: 3 + sent)
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertTrue(root.isHittable, "reopening returns to the first message")
        XCTAssertFalse(newest.isHittable, "not to the newest")
        capture(app, "thread-focus-reopened-at-position")

        for _ in 0..<8 where !(newest.exists && newest.isHittable) { list.swipeUp() }
        XCTAssertTrue(newest.isHittable)
        close(app)
        openGeneralThread(app, replies: 3 + sent)
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertTrue(newest.isHittable, "a thread left at its newest message reopens at the newest")
    }

    /// The thread menu sits in the header between pin and close (web `.thread-title-menu`), offers the actions for the
    /// thread's first message with the message menu's rules, copies a reference without leaving the thread, and pin and
    /// close keep working. The exact FD Ref text is checked by `ThreadMenuContextTests` and the Mac check: reading another
    /// app's pasteboard here would raise the system paste prompt.
    func testHeaderThreadMenuBesidePinAndClose() {
        let app = launch(reset: true)
        openGeneralThread(app, replies: 3)
        let menu = app.buttons["thread.focus.actions"].firstMatch
        let pin = app.buttons["pin.toggle"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the header has a thread menu")
        XCTAssertTrue(pin.exists && app.buttons["thread.focus.close"].firstMatch.exists, "pin and close stay in the header")
        XCTAssertLessThan(pin.frame.midX, menu.frame.midX, "the menu follows pin")
        XCTAssertLessThan(menu.frame.midX, app.buttons["thread.focus.close"].firstMatch.frame.midX, "and precedes close")
        XCTAssertEqual(menu.frame.midY, pin.frame.midY, accuracy: 8, "on the header row")

        menu.tap()
        XCTAssertTrue(app.buttons["thread.menu.ref"].waitForExistence(timeout: 5), "FD Ref")
        XCTAssertTrue(app.buttons["thread.menu.copy"].exists, "Copy message")
        XCTAssertTrue(app.buttons["thread.menu.getitdone"].exists, "Get it done")
        XCTAssertFalse(app.buttons["thread.menu.delete"].exists, "only its author can delete the first message")
        XCTAssertFalse(app.buttons["thread.menu.autopilot"].exists, "no message here came from an Autopilot session")
        capture(app, "thread-menu-open")
        UIPasteboard.general.items = []
        app.buttons["thread.menu.ref"].tap()
        XCTAssertTrue(app.buttons["thread.menu.ref"].waitForNonExistence(timeout: 5), "choosing closes the menu")
        XCTAssertTrue(UIPasteboard.general.hasStrings, "FD Ref copies a reference")
        XCTAssertTrue(focus(app).exists, "and leaves the thread open")

        menu.tap()
        XCTAssertTrue(app.buttons["thread.menu.getitdone"].waitForExistence(timeout: 5))
        app.buttons["thread.menu.getitdone"].tap()
        XCTAssertTrue(app.textFields["getitdone.title"].firstMatch.waitForExistence(timeout: 5), "Get it done opens its task form")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(focus(app).exists, "cancelling returns to the thread")

        let toggled = expectation(for: NSPredicate(format: "label != %@", pin.label), evaluatedWith: pin)
        pin.tap()
        wait(for: [toggled], timeout: 5)
        pin.tap()
        close(app)
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
