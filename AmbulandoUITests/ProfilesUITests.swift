import XCTest

/// Build 10 on local sample data (`-AmbulandoUITestFixture`): names and avatars from the profile cache in the profile
/// menu and on chat authors (workspace name first, public profile otherwise, npub and initials for nobody), kept offline
/// and after opting out; chat's date separators, conversation cards and the thread replies rule; and the white /
/// dark-purple theme in light and dark mode. Sample profiles are synthetic; no relay or picture host is contacted.
@MainActor
final class ProfilesUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(reset: Bool = true, dark: Bool = false, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-appearance", dark ? "dark" : "light"] + (reset ? ["-AmbulandoFixtureReset"] : []) + extra
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

    private func text(_ app: XCUIApplication, containing value: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func openChannel(_ app: XCUIApplication, _ name: String) {
        if name == "general" {
            let general = app.buttons["channel.general"]
            XCTAssertTrue(general.waitForExistence(timeout: 15))
            general.tap()
        } else {
            app.selectSidebarChannel(name)
            app.section("Chat")
        }
        XCTAssertTrue(app.navigationBars["#\(name)"].waitForExistence(timeout: 10))
    }

    private func openSettings(_ app: XCUIApplication) {
        let button = app.buttons["settings"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func closeSettings(_ app: XCUIApplication) { app.navigationBars["Settings"].buttons["Done"].tap() }

    /// The profile menu shows the workspace name with its source and the public profile name; chat authors resolve the
    /// same way. Names stay after an offline relaunch and after turning public profiles off.
    func testProfileMenuAndChatAuthorsComeFromTheCache() {
        let app = launch()
        let profileButton = app.buttons["settings"].firstMatch
        XCTAssertTrue(profileButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(profileButton, "value == %@", "You (sample identity)"), "the profile button names the signed-in person")
        openSettings(app)
        let header = app.descendants(matching: .any)["profile.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(header, "label CONTAINS %@", "Public profile: Sample Explorer"), header.label)
        XCTAssertTrue(header.label.contains("Your name in this workspace"), header.label)
        capture(app, "profile-menu-light")
        closeSettings(app)

        // #design: Bea has no workspace name, so her public profile names her; Ana keeps her workspace name.
        openChannel(app, "design")
        XCTAssertTrue(text(app, containing: "Bea Ortiz").waitForExistence(timeout: 15), "named from the public profile")
        XCTAssertTrue(text(app, containing: "Ana").exists)
        XCTAssertFalse(text(app, containing: "Ana Lima").exists, "the workspace name wins over the public profile")
        capture(app, "chat-authors-design-light")

        // #deploys: someone with neither shows the short npub.
        openChannel(app, "deploys")
        XCTAssertTrue(text(app, containing: "npub16h2at…h2l3").waitForExistence(timeout: 15), "short npub for someone without a name")
        capture(app, "chat-authors-npub-fallback-light")
        app.terminate()

        // Offline relaunch: names come from the cache straight away.
        let offline = launch(reset: false, ["-AmbulandoFixtureOffline"])
        openChannel(offline, "design")
        XCTAssertTrue(text(offline, containing: "Bea Ortiz").waitForExistence(timeout: 10), "cached names are shown offline")

        // Opting out stops requests but keeps saved names.
        openSettings(offline)
        let toggle = offline.switches["settings.profiles.toggle"]
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable) { offline.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "on by default, as on the web")
        (toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(offline.buttons["settings.profiles.refresh"].isEnabled)
        closeSettings(offline)
        XCTAssertTrue(text(offline, containing: "Bea Ortiz").exists, "saved names stay after opting out")
    }

    /// Date labels start each day, every conversation is a card, a thread shows a labelled rule before its replies, and
    /// a message sent today gets a "Today" label after older history.
    func testChatSeparators() {
        let app = launch()
        openChannel(app, "general")
        // A label sits above the first message of each day, so earlier days come into view while scrolling back.
        let days = app.descendants(matching: .any).matching(identifier: "chat.day")
        XCTAssertTrue(text(app, containing: "Release notes for build 2 (#40)").waitForExistence(timeout: 10))
        var labels = Set<String>()
        for _ in 0..<16 where labels.count < 2 {
            app.scrollViews.firstMatch.swipeDown()
            labels.formUnion(days.allElementsBoundByIndex.map(\.label))
        }
        XCTAssertGreaterThanOrEqual(labels.count, 2, "history over several days has a label per day: \(labels)")
        XCTAssertFalse(labels.contains("Today"), "no message of the seeded history is from today")
        capture(app, "chat-general-day-separator-light")

        // Thread: the first message, then the replies rule.
        for _ in 0..<16 { app.scrollViews.firstMatch.swipeUp() }
        let thread = app.buttons["thread.3"].firstMatch
        for _ in 0..<6 where !(thread.exists && thread.isHittable) { app.scrollViews.firstMatch.swipeDown() }
        thread.tap()
        let rule = app.descendants(matching: .any)["thread.repliesRule"]
        XCTAssertTrue(rule.waitForExistence(timeout: 10))
        XCTAssertEqual(rule.label, "3 replies")
        capture(app, "chat-thread-replies-rule-light")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Sending now adds today's label under older history.
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Separator check")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(text(app, containing: "Separator check").waitForExistence(timeout: 10))
        XCTAssertTrue(days.matching(NSPredicate(format: "label == %@", "Today")).firstMatch.waitForExistence(timeout: 10), "Today label above the new message")
        capture(app, "chat-general-today-light")
    }

    /// Rendered surfaces in dark mode (and the sidebar and Deck in light mode) for review.
    func testThemeScreensLightAndDark() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = launch(dark: dark)
            openChannel(app, "general")
            sleep(1)
            capture(app, "chat-general-\(mode)")
            app.openSidebar()
            capture(app, "sidebar-\(mode)")
            app.buttons["sidebar.channel.design"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Inbox: #design"].waitForExistence(timeout: 10))
            capture(app, "deck-inbox-design-\(mode)")
            app.section("Chat")
            XCTAssertTrue(text(app, containing: "Bea Ortiz").waitForExistence(timeout: 15))
            capture(app, "chat-design-\(mode)")
            openSettings(app)
            XCTAssertTrue(app.descendants(matching: .any)["profile.header"].waitForExistence(timeout: 10))
            sleep(1)
            capture(app, "profile-menu-\(mode)")
            closeSettings(app)
            app.terminate()
        }
    }

    private func waitFor(_ element: XCUIElement, _ format: String, _ value: String, timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
