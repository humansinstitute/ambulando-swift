import XCTest

/// Mention pills, Backspace and per-message menus against the app's labelled local sample data
/// (`-AmbulandoUITestFixture`, simulator only). Not evidence of live Tower behaviour.
@MainActor
final class ComposerParityUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sample data on this'")).firstMatch.waitForExistence(timeout: 15), "sample data is labelled")
        let general = app.buttons["channel.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 15))
        general.tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
        return app
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }

    private func value(_ element: XCUIElement) -> String {
        let text = (element.value as? String) ?? ""
        return text == element.placeholderValue ? "" : text
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testMessageEditUsesSharedMentionComposerAndKeepsReplyOnCancelAndSave() {
        let app = launch()
        var input = field(app)
        input.tap(); input.typeText("Mobile mention revision")
        app.buttons["composer.send"].tap()
        let sent = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Mobile mention revision'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        sent.tap()
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'message' AND label CONTAINS 'Mobile mention revision'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        input = field(app)
        input.tap(); input.typeText("Unsent reply")
        app.buttons["composer.hideKeyboard"].tap()
        message.press(forDuration: 1)
        app.buttons["message.edit"].tap()
        XCTAssertTrue(app.buttons["editmessage.cancel"].waitForExistence(timeout: 5))
        input = field(app)
        XCTAssertEqual(value(input), "Mobile mention revision")
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
        input.typeText(" @ric")
        let pick = app.buttons["mention.rick"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5)); pick.tap()
        XCTAssertTrue(value(input).contains("@[rick](mention:agent:npub1"))
        input.typeText("cancelled")
        app.buttons["editmessage.cancel"].tap()
        XCTAssertEqual(value(field(app)), "Unsent reply")
        app.buttons["composer.hideKeyboard"].tap()
        message.press(forDuration: 1)
        app.buttons["message.edit"].tap()
        XCTAssertTrue(app.buttons["editmessage.save"].waitForExistence(timeout: 5))
        input = field(app)
        XCTAssertEqual(value(input), "Mobile mention revision", "cancel discards the private edit draft")
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
        app.buttons["composer.mention"].tap()
        input.typeText("ric")
        XCTAssertTrue(pick.waitForExistence(timeout: 5)); pick.tap()
        input.typeText("saved")
        let canonical = value(input)
        XCTAssertTrue(canonical.hasSuffix(" saved"), "completion keeps the caret after the canonical tag")
        capture(app, "mobile-message-mention-edit")
        app.buttons["editmessage.save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Mobile mention revision @rick saved'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(value(field(app)), "Unsent reply")
        app.buttons["composer.hideKeyboard"].tap()
        message.press(forDuration: 1)
        app.buttons["message.edit"].tap()
        XCTAssertTrue(app.buttons["editmessage.cancel"].waitForExistence(timeout: 5))
        input = field(app)
        XCTAssertEqual(value(input), canonical, "reopening preserves the full saved token")
        // Delete the whole edit using ordinary native Backspace, then save plain text: no stale routing tag.
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: canonical.count) + "Mobile mention revision removed")
        app.buttons["editmessage.save"].tap()
        XCTAssertTrue(app.staticTexts["Mobile mention revision removed"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(value(field(app)), "Unsent reply")
    }

    func testBlankComposerPaddingFocusesAndKeepsDraftAndTools() {
        let app = launch()
        let composer = field(app)
        // Outside the native field, but inside the rounded composer surface.
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 1)).withOffset(CGVector(dx: 0, dy: 5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Blank area draft")
        app.buttons["composer.hideKeyboard"].tap()
        XCTAssertEqual(value(composer), "Blank area draft")
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: -5, dy: 0)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText(" kept")
        XCTAssertEqual(value(composer), "Blank area draft kept")
        app.buttons["composer.mention"].tap()
        XCTAssertTrue(value(composer).contains("@"))
        XCTAssertTrue(app.buttons["composer.photo"].exists)
        capture(app, "batch-blank-composer")
    }

    func testPickedAgentShowsAsPillAndBackspaceRemovesTheWholeName() {
        let app = launch()
        let composer = field(app)
        composer.tap()
        composer.typeText("Ping @Ri")
        let pick = app.buttons["mention.rick"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "the list opens while typing @")
        pick.tap()
        XCTAssertEqual(value(composer), "Ping @rick ")
        XCTAssertTrue(element(app, "composer.mention.pill").waitForExistence(timeout: 5), "the picked agent shows as a pill")
        capture(app, "mention-pill")

        // First Backspace deletes the space after the name, the second removes the whole name and its pill.
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(value(composer), "Ping @rick")
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(value(composer), "Ping ")
        XCTAssertTrue(element(app, "composer.mention.pill").waitForNonExistence(timeout: 5), "the pill goes with the name")
    }

    /// The `@` list offers documents, tasks, conversations, channels and scopes as well as people (as on the web), filtered by
    /// the name typed; a picked record becomes a pill and is sent as its canonical reference.
    func testRecordMentionsLookAheadAndSendTheirReference() {
        let app = launch()
        let composer = field(app)
        composer.tap()
        composer.typeText("Read @native app")
        let doc = app.buttons["mention.Native app plan"]
        XCTAssertTrue(doc.waitForExistence(timeout: 5), "documents are offered by name")
        capture(app, "mention-records")
        doc.tap()
        XCTAssertEqual(value(composer), "Read @Native app plan ")
        XCTAssertTrue(element(app, "composer.mention.pill").waitForExistence(timeout: 5), "the picked document shows as a pill")

        composer.typeText("then @task:inbox")
        let task = app.buttons["mention.Review the native inbox"]
        XCTAssertTrue(task.waitForExistence(timeout: 5), "a kind prefix narrows the list to tasks")
        XCTAssertFalse(app.buttons["mention.rick"].exists, "people are left out for task:")
        task.tap()
        XCTAssertEqual(value(composer), "Read @Native app plan then @Review the native inbox ")

        app.buttons["composer.send"].tap()
        // Records render as their names (no @), as on the web.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Read Native app plan then Review the native inbox")).firstMatch
            .waitForExistence(timeout: 10), "sent with both references")
    }

    func testPillCanBeRemovedWithItsButton() {
        let app = launch()
        let composer = field(app)
        composer.tap()
        composer.typeText("@Ri")
        app.buttons["mention.rick"].tap()
        let remove = app.buttons["composer.mention.remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertEqual(value(composer), "")
        XCTAssertTrue(element(app, "composer.mention.pill").waitForNonExistence(timeout: 5))
    }

    func testMessageMenuIsVisibleAndSyncedMessagesShowTheGreenDot() {
        let app = launch()
        XCTAssertTrue(app.buttons["message.actions"].firstMatch.waitForExistence(timeout: 10), "every message has a visible actions menu")
        // A channel opens at its newest message: the last menu button is the one on screen.
        let actions = app.buttons.matching(identifier: "message.actions").allElementsBoundByIndex.last(where: { $0.isHittable }) ?? app.buttons["message.actions"].firstMatch
        XCTAssertTrue(element(app, "message.sync.synced").exists, "a message Tower holds is marked as synced")
        capture(app, "message-menu-closed")
        actions.tap()
        XCTAssertTrue(app.buttons["message.copy"].waitForExistence(timeout: 5), "Copy message")
        XCTAssertTrue(app.buttons["message.ref"].exists, "FD Ref")
        XCTAssertTrue(app.buttons["message.getitdone"].exists, "Get it done")
        capture(app, "message-menu-open")
        app.buttons["message.getitdone"].tap()
        let title = app.textFields["getitdone.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Get it done opens its task form")
        XCTAssertFalse(app.buttons["getitdone.create"].isEnabled, "a title is required")
        title.tap(); title.typeText("Check the outbox")
        XCTAssertTrue(app.buttons["getitdone.create"].isEnabled)
        capture(app, "get-it-done")
    }
}
