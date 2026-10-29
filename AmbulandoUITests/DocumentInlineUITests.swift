import XCTest

@MainActor
final class DocumentInlineUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch(reset: Bool, document: String = "Native app plan") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture"] + (reset ? ["-AmbulandoFixtureReset"] : [])
        app.launch()
        app.section("Docs")
        XCTAssertTrue(app.buttons["doc.\(document)"].waitForExistence(timeout: 15))
        app.buttons["doc.\(document)"].tap()
        return app
    }

    func testInlineFormattedEditingSelectionCommentReplyAndReload() {
        let app = launch(reset: true)
        let page = app.webViews["doc.editor"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15), "document opens directly into the formatted page")
        let paragraph = page.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Every screen reads'")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 15))
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5)).press(forDuration: 1.2)
        if app.menuItems["Select"].waitForExistence(timeout: 2) { app.menuItems["Select"].tap() }
        else if app.buttons["Select"].exists { app.buttons["Select"].tap() }
        let selectionShot = XCTAttachment(screenshot: app.screenshot()); selectionShot.name = "document-word-selection"; selectionShot.lifetime = .keepAlways; add(selectionShot)
        let selected = app.buttons["doc.commentSelection"]
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        XCTAssertTrue(selected.isEnabled, "highlighted text offers an anchored comment")
        selected.tap()
        let field = app.textFields["doccomment.field"].exists ? app.textFields["doccomment.field"] : app.textViews["doccomment.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Comment on highlighted passage")
        app.buttons["doccomment.send"].tap()
        XCTAssertTrue(app.staticTexts["Comment on highlighted passage"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "document-anchored-comment"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Reply"].firstMatch.tap()
        field.tap(); field.typeText("Reply to highlighted passage")
        app.buttons["doccomment.send"].tap()
        XCTAssertTrue(app.staticTexts["Reply to highlighted passage"].waitForExistence(timeout: 15))
        app.terminate()
        let again = launch(reset: false)
        XCTAssertTrue(again.webViews["doc.editor"].firstMatch.waitForExistence(timeout: 15))
        again.buttons["doc.comments"].tap()
        XCTAssertTrue(again.staticTexts["Comment on highlighted passage"].waitForExistence(timeout: 15))
        XCTAssertTrue(again.staticTexts["Reply to highlighted passage"].exists)
        let locate = again.buttons.containing(NSPredicate(format: "label CONTAINS 'Locate text'")).firstMatch
        XCTAssertTrue(locate.waitForExistence(timeout: 5), "saved comment retains a quote and a locatable anchor")
        locate.tap()
        let reopened = again.buttons["doc.commentSelection"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        XCTAssertTrue(reopened.isEnabled, "reopening the comment highlights its original passage")
    }

    func testMarkdownOpensFormattedAndSelectionAnchorSurvivesReload() {
        let app = launch(reset: true, document: "Theme notes (Markdown)")
        let heading = app.webViews["doc.editor"].staticTexts["Theme notes"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 15), "raw Markdown opens formatted in the same editor")
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).press(forDuration: 1.2)
        if app.menuItems["Select"].waitForExistence(timeout: 2) { app.menuItems["Select"].tap() }
        else if app.buttons["Select"].exists { app.buttons["Select"].tap() }
        let selected = app.buttons["doc.commentSelection"]
        XCTAssertTrue(selected.isEnabled)
        selected.tap()
        let field = app.textFields["doccomment.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Markdown passage comment")
        app.buttons["doccomment.send"].tap()
        XCTAssertTrue(app.staticTexts["Markdown passage comment"].waitForExistence(timeout: 15))
        app.terminate()
        let again = launch(reset: false, document: "Theme notes (Markdown)")
        XCTAssertTrue(again.webViews["doc.editor"].waitForExistence(timeout: 15))
        again.buttons["doc.comments"].tap()
        XCTAssertTrue(again.staticTexts["Markdown passage comment"].waitForExistence(timeout: 15))
        let locate = again.buttons.containing(NSPredicate(format: "label CONTAINS 'Locate text'")).firstMatch
        XCTAssertTrue(locate.waitForExistence(timeout: 5))
        locate.tap()
        XCTAssertTrue(again.buttons["doc.commentSelection"].isEnabled)
    }

    func testDirtyEditorAutosavesWithinOneMinuteAndRenameReopens() {
        let app = launch(reset: true)
        XCTAssertTrue(app.webViews["doc.editor"].waitForExistence(timeout: 15))
        let title = app.textFields["editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let old = (title.value as? String) ?? ""
        let started = Date()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Minute cloud checkpoint")
        XCTAssertTrue(app.staticTexts["Saved locally; waiting to sync."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Saved."].waitForExistence(timeout: 65), "active dirty editor saves without pressing Save")
        XCTAssertLessThan(Date().timeIntervalSince(started), 66)
        XCTAssertFalse(app.staticTexts["editor.dirty"].exists)
        app.terminate()
        let reopened = launch(reset: false, document: "Minute cloud checkpoint")
        XCTAssertEqual(reopened.textFields["editor.title"].value as? String, "Minute cloud checkpoint")
    }

}
