import XCTest

@MainActor
final class DeckComposeUITests: XCTestCase {
    func testPlusOpensComposerImmediatelyAndCancelKeepsDraftThenSendOpensThread() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        // A channel context: + opens the message field at once (several eligible channels ask first, see below).
        app.selectSidebarChannel("general")
        app.deckCard("inbox")
        let plus = app.buttons["deck.inbox.new"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15))
        plus.tap()
        XCTAssertTrue(app.navigationBars["New thread"].waitForExistence(timeout: 5))
        let field = app.textViews["composer.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "composer opens directly without a channel menu or chat detour")
        field.tap(); field.typeText("A new thread from Deck")
        app.buttons["deck.compose.cancel"].tap()
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "A new thread from Deck", "cancel preserves the durable draft")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.buttons["thread.focus.close"].firstMatch.waitForExistence(timeout: 15), "accepted creation opens the new thread")
        XCTAssertTrue(app.staticTexts["A new thread from Deck"].firstMatch.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "deck-created-thread"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["thread.focus.close"].firstMatch.tap()
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "closing returns to the same Deck")
    }

    /// The floating + sits above the page dots on every card and opens the composer for the channel Deck shows.
    func testFloatingPlusOpensComposerForTheShownChannelFromAnyCard() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        app.selectSidebarChannel("design")
        let fab = app.buttons["deck.fab.new"].firstMatch
        for card in ["inbox", "recent"] {
            app.deckCard(card)
            XCTAssertTrue(fab.waitForExistence(timeout: 10), "floating + on \(card)")
            let dot = app.buttons["deck.page.\(card)"].firstMatch
            XCTAssertLessThanOrEqual(fab.frame.maxY, dot.frame.minY + 1, "floating + stays above the page dots")
            XCTAssertGreaterThanOrEqual(fab.frame.width, 44); XCTAssertGreaterThanOrEqual(fab.frame.height, 44)
            let visible = XCTAttachment(screenshot: app.screenshot()); visible.name = "deck-fab-visible-\(card)"; visible.lifetime = .keepAlways; add(visible)
            fab.tap()
            XCTAssertTrue(app.navigationBars["New thread"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textViews["composer.field"].firstMatch.waitForExistence(timeout: 10), "one tap reaches the message field")
            XCTAssertTrue(app.buttons["#design"].firstMatch.exists || app.staticTexts["#design"].firstMatch.exists, "targets the shown channel")
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "deck-fab-\(card)"; shot.lifetime = .keepAlways; add(shot)
            app.buttons["deck.compose.cancel"].tap()
            XCTAssertTrue(fab.waitForExistence(timeout: 5), "cancel returns to Deck without posting")
        }
    }

    /// With several eligible channels (a scope or Home) nothing is preselected: no message field or Send until chosen.
    func testScopeWithSeveralChannelsAsksBeforeSending() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        app.openSidebar()
        app.buttons["sidebar.home"].firstMatch.tap()
        let fab = app.buttons["deck.fab.new"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 10))
        fab.tap()
        XCTAssertTrue(app.navigationBars["New thread"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Choose a channel here to start your thread."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["composer.field"].firstMatch.exists, "no field until a channel is chosen")
        XCTAssertFalse(app.buttons["composer.send"].firstMatch.exists, "no Send until a channel is chosen")
        let picker = app.buttons["deck.compose.channel"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let general = app.buttons["deck.compose.option.f1c70000-0000-4000-8000-0000000000c1"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        general.tap()
        XCTAssertTrue(app.textViews["composer.field"].firstMatch.waitForExistence(timeout: 10), "the field appears once chosen")
        app.buttons["deck.compose.cancel"].tap()
    }

    /// Inbox's four type filters and Search share one row, each a comfortable target, on the narrowest phone too.
    func testInboxFiltersAndSearchShareOneRow() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        app.section("Deck")
        app.deckCard("inbox")
        let search = app.textFields["deck.inbox.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        var right: CGFloat = 0
        for kind in ["chat", "task", "document", "file"] {
            let toggle = app.buttons["deck.inbox.type.\(kind)"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "\(kind) filter shown")
            XCTAssertTrue(toggle.isHittable, "\(kind) filter tappable")
            XCTAssertGreaterThanOrEqual(toggle.frame.width, 43.5, "\(kind) filter width")
            XCTAssertGreaterThanOrEqual(toggle.frame.height, 43.5, "\(kind) filter target")
            XCTAssertEqual(toggle.frame.midY, search.frame.midY, accuracy: 6, "\(kind) filter on the search row")
            right = max(right, toggle.frame.maxX)
        }
        XCTAssertLessThanOrEqual(right, search.frame.minX, "search follows the filters")
        XCTAssertGreaterThanOrEqual(search.frame.width, app.windows.firstMatch.frame.width < 390 ? 80 : 100, "search keeps usable room")
        let chats = app.buttons["deck.inbox.type.chat"].firstMatch
        chats.tap()
        XCTAssertEqual(chats.value as? String, "Hidden")
        search.tap(); search.typeText("zzz no match\n")
        XCTAssertEqual(chats.value as? String, "Hidden", "filter state kept while searching")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "deck-inbox-one-row"; shot.lifetime = .keepAlways; add(shot)
    }
}
