import XCTest

/// Build 36 chat changes against the local sample data (`-AmbulandoUITestFixture`): visible links that open the in-app
/// browser (with an explicit Open in Safari), the @ list closing after a pick with recently tagged people first and at most
/// seven rows, the web-style reaction bar, and renaming a thread. Only Tower is replaced by an in-process stand-in; this
/// is not evidence of live Tower behaviour.
@MainActor
final class NativeChatReleaseUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-appearance", "light", "-AmbulandoFixtureReset"]
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

    private func openGeneral(_ app: XCUIApplication) {
        let general = app.buttons["channel.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 15))
        general.tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
    }

    private func field(_ container: XCUIElement) -> XCUIElement {
        let view = container.textViews["composer.field"].firstMatch
        return view.waitForExistence(timeout: 10) ? view : container.textFields["composer.field"].firstMatch
    }

    private func text(_ element: XCUIElement) -> String {
        let value = (element.value as? String) ?? ""
        return value == element.placeholderValue ? "" : value
    }

    private func send(_ app: XCUIApplication, _ words: String) {
        let composer = field(app)
        composer.tap()
        composer.typeText(words)
        app.buttons["composer.send"].firstMatch.tap()
    }

    // MARK: Links

    /// A Markdown link and a bare address are links in the message (not plain text); tapping one opens a tab of the in-app
    /// browser, not Safari; Open in Safari is an explicit menu choice; Ambulando returns to the same channel and draft.
    func testLinksAreVisibleOpenInAppBrowserAndSafariIsExplicit() {
        let app = launch()
        openGeneral(app)
        send(app, "See [the docs](https://browser.sample.invalid/doc) and https://browser.sample.invalid/bare")
        let docs = app.links["the docs"].firstMatch
        XCTAssertTrue(docs.waitForExistence(timeout: 10), "a Markdown link is exposed as a link")
        XCTAssertTrue(app.links.matching(NSPredicate(format: "label CONTAINS %@", "browser.sample.invalid/bare")).firstMatch.exists, "a bare address is a link too")
        capture(app, "links-styled-in-message")

        let composer = field(app)
        composer.tap()
        composer.typeText("Draft kept while browsing")
        docs.tap()
        XCTAssertTrue(app.buttons["browser.return"].waitForExistence(timeout: 10), "the link opens the in-app browser")
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertNotEqual(safari.state, .runningForeground, "the link did not leave for Safari")
        capture(app, "link-opened-in-app-browser")

        app.buttons["browser.menu"].tap()
        let openInSafari = app.buttons["browser.openInSafari"]
        XCTAssertTrue(openInSafari.waitForExistence(timeout: 10), "Open in Safari is offered")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()   // dismiss the menu; Safari opens only when asked for
        app.buttons["browser.return"].tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10), "Ambulando returns to the channel")
        XCTAssertTrue(text(field(app)).contains("Draft kept while browsing"), "the composer draft is kept")
    }

    /// Open in Safari hands the page to Safari (the explicit choice), and the app is still where it was on return.
    func testOpenInSafariLeavesTheAppOnlyWhenChosen() {
        let app = launch()
        openGeneral(app)
        send(app, "https://browser.sample.invalid/bare")
        let link = app.links.matching(NSPredicate(format: "label CONTAINS %@", "browser.sample.invalid/bare")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(app.buttons["browser.menu"].waitForExistence(timeout: 10))
        app.buttons["browser.menu"].tap()
        app.buttons["browser.openInSafari"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "Open in Safari opens Safari")
        app.activate()
        XCTAssertTrue(app.buttons["browser.return"].waitForExistence(timeout: 10), "Ambulando is as it was left")
    }

    /// A link in a focused thread (presented outside the shell) also opens the in-app browser.
    func testLinkInAThreadOpensTheInAppBrowser() {
        let app = launch()
        openGeneral(app)
        let thread = app.buttons["thread.3"].firstMatch
        for _ in 0..<6 where !(thread.exists && thread.isHittable) { app.scrollViews.firstMatch.swipeDown() }
        thread.tap()
        let panel = app.descendants(matching: .any)["thread.focus"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let reply = field(panel)
        reply.tap()
        reply.typeText("Read https://browser.sample.invalid/in-thread")
        panel.buttons["composer.send"].firstMatch.tap()
        let link = panel.links.matching(NSPredicate(format: "label CONTAINS %@", "browser.sample.invalid/in-thread")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        capture(app, "thread-link-styled")
        link.tap()
        XCTAssertTrue(app.buttons["browser.return"].waitForExistence(timeout: 10), "a thread link opens the in-app browser")
        XCTAssertNotEqual(XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").state, .runningForeground)
        app.buttons["browser.return"].tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "returning shows the open thread")
    }

    // MARK: @ mentions

    private func rows(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mention.' AND NOT identifier IN {'mention.list'}")).allElementsBoundByIndex
    }

    /// Picking from the list closes it at once and typing on does not reopen it; a person tagged before comes first in the
    /// bare list; the list shows at most seven rows and scrolls for the rest.
    func testMentionPickClosesListRecentFirstAndSevenRowCap() {
        let app = launch()
        openGeneral(app)
        let composer = field(app)
        composer.tap()
        composer.typeText("Hello @Ri")
        let rick = app.buttons["mention.rick"]
        XCTAssertTrue(rick.waitForExistence(timeout: 5))
        rick.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mention.list"].waitForNonExistence(timeout: 3), "the list closes after a pick")
        XCTAssertEqual(text(composer), "Hello @rick ", "the composer reads naturally")
        composer.typeText("please look")
        XCTAssertFalse(app.descendants(matching: .any)["mention.list"].exists, "typing on never reopens it")
        capture(app, "mention-closed-after-pick")
        app.buttons["composer.send"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "please look")).firstMatch.waitForExistence(timeout: 10))

        // The next bare @ leads with the person tagged last.
        composer.tap()
        composer.typeText("@")
        let list = app.descendants(matching: .any)["mention.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let shown = rows(app).filter { $0.exists && $0.frame.height > 0 }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(shown.first?.identifier, "mention.rick", "the most recently tagged person is first")
        // Measure the actual clipped scroll viewport. The enclosing accessibility group's bounds
        // can include offscreen children on smaller phones.
        let viewport = app.scrollViews.containing(.button, identifier: "mention.rick").firstMatch
        capture(app, "mention-cap-before-measurement")
        XCTAssertTrue(viewport.exists)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.lifetime = .keepAlways; add(hierarchy)
        // At most seven rows are visible; the rest scrolls.
        let heights = shown.map(\.frame.height)
        let rowHeight = heights.min() ?? 46
        XCTAssertLessThanOrEqual(viewport.frame.height, rowHeight * 7 + 16, "the list is capped at seven rows")
        XCTAssertGreaterThan(viewport.frame.height, rowHeight * 2, "and still shows several")
        capture(app, "mention-recent-first-seven-rows")
        let before = Set(rows(app).filter { $0.isHittable }.map(\.identifier))
        viewport.swipeUp()
        let after = Set(rows(app).filter { $0.isHittable }.map(\.identifier))
        XCTAssertNotEqual(before, after, "the remainder is reached by scrolling")
        XCTAssertTrue(composer.isHittable, "the composer stays usable with the list open")
        XCTAssertTrue(app.buttons["composer.send"].isHittable, "Send stays reachable with the list and keyboard open")
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "the keyboard does not cover the field")
        }
    }

    // MARK: Reactions

    private func firstHittable(_ app: XCUIApplication, _ identifier: String) -> XCUIElement? {
        app.buttons.matching(identifier: identifier).allElementsBoundByIndex.last { $0.exists && $0.isHittable }
    }

    /// The web's bar under every message: a quiet thumbs-up and + always there; a reaction becomes a pill with its count and
    /// your state; tapping it again removes it; the + opens the emoji picker.
    func testReactionBarAddRemoveAndPicker() {
        let app = launch()
        openGeneral(app)
        send(app, "React to this one")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "React to this one")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reaction.add"].firstMatch.waitForExistence(timeout: 10), "the + is there before any reaction")
        capture(app, "reaction-bar-empty")

        let quick = try? XCTUnwrap(firstHittable(app, "reaction.quick"))
        quick?.tap()
        let pill = app.buttons.matching(identifier: "reaction.thumbs_up").allElementsBoundByIndex.last { $0.exists }
        XCTAssertTrue(pill?.waitForExistence(timeout: 10) ?? false, "the quick thumbs-up adds a reaction")
        XCTAssertEqual(pill?.label, "Thumbs up, 1, including you")
        capture(app, "reaction-pill-added")
        pill?.tap()
        XCTAssertTrue(pill?.waitForNonExistence(timeout: 10) ?? false, "tapping your reaction removes it")

        firstHittable(app, "reaction.add")?.tap()
        capture(app, "reaction-picker")
        let heart = app.buttons["react.heart"].firstMatch
        XCTAssertTrue(heart.waitForExistence(timeout: 5), "the picker offers the emoji")
        XCTAssertTrue(app.buttons["react.shaka"].exists, "all seven of the web's emoji are offered")
        heart.tap()
        XCTAssertTrue(app.buttons["reaction.heart"].firstMatch.waitForExistence(timeout: 10))
        capture(app, "reaction-heart-added")
    }

    /// Seven pills must wrap within phone content bounds; quick and add remain reachable at large text too.
    func testAllSevenReactionsFitPhoneAndAccessibilityText() {
        let app = launch()
        openGeneral(app)
        send(app, "All seven reaction layout")
        let emoji = ["thumbs_up", "smile", "heart", "eyes", "party", "shaka", "white_check_mark"]
        for name in emoji {
            let add = firstHittable(app, "reaction.add")
            XCTAssertNotNil(add)
            add?.tap()
            let choice = app.buttons["react.\(name)"].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            XCTAssertTrue(app.buttons["reaction.\(name)"].firstMatch.waitForExistence(timeout: 10))
        }
        func checkBounds(_ name: String) {
            let bars = app.descendants(matching: .any).matching(identifier: "reaction.bar").allElementsBoundByIndex
            let bar = bars.last { $0.buttons["reaction.white_check_mark"].exists }
            XCTAssertNotNil(bar)
            guard let bar else { return }
            let pills = emoji.map { bar.buttons["reaction.\($0)"].firstMatch }
            for control in pills + [bar.buttons["reaction.add"], bar.buttons["reaction.quick"]] {
                XCTAssertTrue(control.exists)
                XCTAssertGreaterThanOrEqual(control.frame.minX, bar.frame.minX - 1)
                XCTAssertLessThanOrEqual(control.frame.maxX, bar.frame.maxX + 1)
            }
            XCTAssertGreaterThan(pills.last!.frame.minY, pills.first!.frame.minY, "seven pills wrap to another row")
            XCTAssertTrue(bar.buttons["reaction.add"].isHittable)
            XCTAssertTrue(bar.buttons["reaction.quick"].isHittable)
            let quickFrame = bar.buttons["reaction.quick"].frame
            let addFrame = bar.buttons["reaction.add"].frame
            XCTAssertFalse(quickFrame.intersects(addFrame), "quick and add have separate hit targets")
            if name.contains("XXXL") {
                XCTAssertGreaterThan(quickFrame.width, 50, "icon controls grow with accessibility text")
            }
            capture(app, name)
        }
        checkBounds("seven-reactions-phone")
        app.terminate()
        app.launchArguments = ["-AmbulandoUITestFixture", "-appearance", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["reaction.white_check_mark"].firstMatch.waitForExistence(timeout: 15))
        checkBounds("seven-reactions-accessibility-XXXL")
    }

    // MARK: Thread title

    private func openThreadMenuItem(_ app: XCUIApplication, _ id: String) {
        app.buttons["thread.focus.actions"].firstMatch.tap()
        let item = app.buttons[id].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    private func replaceTitle(_ app: XCUIApplication, with title: String) {
        let titleField = app.textFields["thread.rename.field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()   // the caret goes to the end
        let current = (titleField.value as? String) ?? ""
        titleField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + title)
    }

    func testRenameConflictShowsCurrentTitleAndKeepsDraft() {
        let app = launch()
        openGeneral(app)
        let thread = app.buttons.matching(NSPredicate(format: "identifier == 'thread.3' AND label CONTAINS 'Inbox counts mentions and tasks'")).firstMatch
        for _ in 0..<12 where !(thread.exists && thread.isHittable) { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(thread.isHittable)
        thread.tap()
        openThreadMenuItem(app, "thread.menu.rename")
        replaceTitle(app, with: "Simulate title conflict")
        app.buttons["thread.rename.save"].tap()
        let error = app.staticTexts["thread.rename.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("Title from another editor"))
        XCTAssertEqual(app.textFields["thread.rename.field"].value as? String, "Simulate title conflict")
        capture(app, "rename-conflict-draft-kept")
        app.buttons["thread.rename.cancel"].tap()
        XCTAssertEqual(app.staticTexts["thread.focus.title"].label, "Title from another editor")
    }

    /// Renaming from the thread menu: the header and the channel's thread row follow, a refusal is shown with the typed
    /// title kept and nothing changed, and the new title survives a relaunch.
    func testRenameThreadUpdatesHeaderListAndHandlesRefusal() {
        let app = launch()
        openGeneral(app)
        let thread = app.buttons["thread.3"].firstMatch
        for _ in 0..<6 where !(thread.exists && thread.isHittable) { app.scrollViews.firstMatch.swipeDown() }
        thread.tap()
        XCTAssertTrue(app.descendants(matching: .any)["thread.focus"].firstMatch.waitForExistence(timeout: 10))
        let original = app.staticTexts["thread.focus.title"].label

        // A refusal keeps everything and says why.
        openThreadMenuItem(app, "thread.menu.rename")
        replaceTitle(app, with: "Please deny this")
        app.buttons["thread.rename.save"].tap()
        XCTAssertTrue(app.staticTexts["thread.rename.error"].waitForExistence(timeout: 10), "a refusal is shown")
        capture(app, "rename-refused")
        app.buttons["thread.rename.cancel"].tap()
        XCTAssertEqual(app.staticTexts["thread.focus.title"].label, original, "a refused rename changes nothing")

        // A rename shows at once in the header.
        openThreadMenuItem(app, "thread.menu.rename")
        capture(app, "rename-sheet")
        replaceTitle(app, with: "Release thread renamed")
        app.buttons["thread.rename.save"].tap()
        XCTAssertTrue(app.buttons["thread.rename.save"].waitForNonExistence(timeout: 10), "saving closes the sheet")
        XCTAssertEqual(app.staticTexts["thread.focus.title"].label, "Release thread renamed")
        capture(app, "rename-header-updated")

        app.buttons["thread.focus.close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Release thread renamed")).firstMatch.waitForExistence(timeout: 10),
                      "the channel's thread row shows the new title")
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-AmbulandoUITestFixture", "-appearance", "light"]
        relaunched.launch()
        XCTAssertTrue(relaunched.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Release thread renamed")).firstMatch.waitForExistence(timeout: 20),
                      "the cached title survives a relaunch")
    }
}
