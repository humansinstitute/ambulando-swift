import XCTest

/// Build 9 navigation on local sample data (`-AmbulandoUITestFixture`): the web's bottom section bar, Deck's swipeable
/// cards, Canvas inside Deck with a way back to Chat, the web's sidebar destination (Deck, or the locked view), and
/// drafts and board positions kept while switching during a sync storm. Not evidence of live Tower behaviour.
@MainActor
final class SectionNavigationUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }

    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }

    /// The keyboard covers the section bar while typing (as with a tab bar); the composer's Hide keyboard button (or
    /// dragging the conversation down) puts it away.
    private func hideKeyboard(_ app: XCUIApplication) {
        let hide = app.buttons["composer.hideKeyboard"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "Hide keyboard while typing")
        hide.tap()
        XCTAssertTrue(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)], timeout: 5) == .completed,
                      "the keyboard is put away")
        _ = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.buttons["section.deck"])], timeout: 5)
    }

    private func tapWhenHittable(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let hittable = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)], timeout: 5) == .completed
        // Rows inside Deck's horizontally paged track can report not hittable while fully on screen; tap the centre.
        if hittable { element.tap() } else { element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }

    func testSectionBarFollowsTheWebOrderAndOptionalSectionsAreOff() {
        let app = launch()
        let order = ["deck", "chat", "tasks", "docs", "files", "toolbox"].map { app.buttons["section.\($0)"].firstMatch }
        for button in order { XCTAssertTrue(button.exists, button.identifier) }
        for (a, b) in zip(order, order.dropFirst()) { XCTAssertLessThan(a.frame.minX, b.frame.minX, "\(a.identifier) before \(b.identifier)") }
        XCTAssertFalse(app.buttons["section.agents"].exists, "Agents is off by default, as on the web")
        XCTAssertFalse(app.buttons["section.context"].exists, "Context is off by default, as on the web")
        XCTAssertTrue(app.buttons["section.chat"].isSelected)
        capture(app, "sections-bar")
    }

    func testCanvasNeverTrapsChatAndBothKeepTheirPlace() {
        let app = launch()
        app.buttons["channel.general"].tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
        composer(app).tap()
        composer(app).typeText("Draft kept across Canvas")
        capture(app, "chat-typing")
        XCTAssertTrue(composer(app).isHittable, "the composer stays above the keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.frame.intersects(app.buttons["section.deck"].frame), "the keyboard covers the bar while typing")
        hideKeyboard(app)

        app.section("Deck")
        app.deckCard("canvas")
        let canvas = app.buttons["canvas.Launch board"].firstMatch
        tapWhenHittable(canvas)
        let doc = app.buttons["naplet.Build 7 launch notes"].firstMatch
        XCTAssertTrue(doc.waitForExistence(timeout: 15))
        app.otherElements.firstMatch.swipeLeft()
        let before = doc.frame
        capture(app, "canvas-with-section-bar")
        let chat = app.buttons["section.chat"].firstMatch
        XCTAssertTrue(chat.isHittable, "Chat is reachable from the open board")
        chat.tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10), "back in the same conversation")
        XCTAssertEqual(composer(app).value as? String, "Draft kept across Canvas", "the draft is untouched")
        capture(app, "chat-after-canvas")

        app.section("Deck")
        XCTAssertTrue(doc.waitForExistence(timeout: 10), "Deck returns to the open board")
        XCTAssertEqual(doc.frame.origin.x, before.origin.x, accuracy: 2, "at the same board position")
        back(app)
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "Back returns to Deck's Canvas card")
        XCTAssertTrue(app.buttons["deck.page.canvas"].isSelected)

        // Tapping the current section again returns it to its first screen.
        canvas.tap()
        XCTAssertTrue(doc.waitForExistence(timeout: 10))
        app.section("Deck")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "tapping Deck again pops to Deck")
    }

    func testDeckSwipesAcrossTheWebCardsAndKeepsTheCard() {
        let app = launch()
        app.section("Deck")
        let dots = ["hello", "inbox", "pinned", "canvas", "feed", "recent"].map { app.buttons["deck.page.\($0)"].firstMatch }
        XCTAssertTrue(dots[1].waitForExistence(timeout: 10))
        XCTAssertTrue(dots[2].waitForExistence(timeout: 15), "Pinned items is shown when there are pins")
        for (a, b) in zip(dots, dots.dropFirst()) { XCTAssertLessThan(a.frame.minX, b.frame.minX, "\(a.identifier) before \(b.identifier)") }
        XCTAssertTrue(dots[1].isSelected, "Deck opens on Inbox")
        capture(app, "deck-inbox")
        let track = app.scrollViews["deck.track"].firstMatch
        for (index, name) in [(2, "pinned"), (3, "canvas"), (4, "feed"), (5, "recent")] {
            track.swipeLeft()
            XCTAssertTrue(waitSelected(dots[index]), "swiped to \(name)")
            capture(app, "deck-\(name)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["deck.feed.notice"].exists || app.buttons["deck.page.feed"].exists)
        track.swipeRight()
        XCTAssertTrue(waitSelected(dots[4]), "swiped back to Feed")
        XCTAssertTrue(app.descendants(matching: .any)["deck.feed.notice"].firstMatch.waitForExistence(timeout: 5), "Feed says where feeds are")

        app.section("Tasks")
        app.section("Deck")
        XCTAssertTrue(dots[4].isSelected, "switching sections keeps Deck's card")
        // Recent channels open Chat in that channel.
        app.deckCard("recent")
        XCTAssertTrue(waitSelected(dots[5]))
        tapWhenHittable(app.buttons["deck.recent.design"].firstMatch)
        // As on the web, Chat opens at that conversation; Back shows the channel, now the context.
        XCTAssertTrue(app.buttons["section.chat"].isSelected)
        XCTAssertTrue(app.textFields["composer.field"].waitForExistence(timeout: 10) || app.textViews["composer.field"].waitForExistence(timeout: 5))
        back(app)
        XCTAssertTrue(app.navigationBars["#design"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["context.bar"].firstMatch.label.contains("design"))
    }

    func testChannelChoiceFromEverySectionOpensDeckUnlessTheViewIsLocked() {
        let app = launch()
        let channels = ["design", "deploys"]
        for (index, section) in ["Chat", "Tasks", "Docs", "Files", "Toolbox", "Deck"].enumerated() {
            let channel = channels[index % 2]
            app.section(section)
            app.selectSidebarChannel(channel)
            XCTAssertTrue(app.staticTexts["Inbox: #\(channel)"].waitForExistence(timeout: 10), "from \(section): Deck shows #\(channel)")
            XCTAssertTrue(app.buttons["section.deck"].isSelected, "from \(section)")
            XCTAssertTrue(app.buttons["deck.page.inbox"].isSelected)
        }
        capture(app, "deck-after-sidebar-choice")

        // A locked Chat stays on a sidebar choice and shows the new channel.
        app.section("Chat")
        let lock = app.buttons["context.lock"].firstMatch
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        lock.tap()
        app.selectSidebarChannel("general")
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10), "locked Chat stays and opens #general")
        XCTAssertTrue(app.buttons["section.chat"].isSelected)
        // The lock is cleared when another section opens, as on the web.
        app.section("Tasks")
        app.section("Chat")
        XCTAssertFalse(app.buttons["context.lock"].firstMatch.isSelected)
    }

    func testDraftAndBoardPositionSurviveSectionSwitchesDuringASyncStorm() {
        let app = launch(["-AmbulandoFixtureStorm"])
        app.buttons["channel.general"].tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
        let field = composer(app)
        field.tap()
        field.typeText("Storm draft")   // the storm starts on the first keystroke
        hideKeyboard(app)
        app.section("Deck")
        app.deckCard("canvas")
        tapWhenHittable(app.buttons["canvas.Launch board"].firstMatch)
        let doc = app.buttons["naplet.Build 7 launch notes"].firstMatch
        XCTAssertTrue(doc.waitForExistence(timeout: 15))
        app.otherElements.firstMatch.swipeLeft()
        let before = doc.frame
        for _ in 0..<3 {
            app.section("Chat")
            XCTAssertEqual(composer(app).value as? String, "Storm draft", "draft kept while rows are written")
            XCTAssertTrue(app.navigationBars["#general"].exists)
            app.section("Deck")
            XCTAssertTrue(doc.waitForExistence(timeout: 10))
            XCTAssertEqual(doc.frame.origin.x, before.origin.x, accuracy: 2, "board position kept while rows are written")
        }
        let storm = app.staticTexts.matching(identifier: "fixture.storm").firstMatch
        XCTAssertTrue(storm.exists && storm.label.hasPrefix("storm:"), "the storm ran during the switches")
    }

    private func waitSelected(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: element)], timeout: timeout) == .completed
    }
}
