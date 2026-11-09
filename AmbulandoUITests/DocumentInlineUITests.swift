import XCTest

@MainActor
final class DocumentInlineUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch(reset: Bool, document: String = "Native app plan", edit: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture"] + (reset ? ["-AmbulandoFixtureReset"] : [])
        app.launch()
        app.section("Docs")
        XCTAssertTrue(app.buttons["doc.\(document)"].waitForExistence(timeout: 15))
        app.buttons["doc.\(document)"].tap()
        if edit { enterEdit(app) }
        return app
    }

    private func enterEdit(_ app: XCUIApplication) {
        if !app.buttons["doc.edit"].exists { app.buttons["More"].firstMatch.tap() }
        let edit = app.buttons["doc.edit"].exists ? app.buttons["doc.edit"] : app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
    }

    func testReaderDocumentActionsAndDeleteCancellation() {
        let app = launch(reset: true, edit: false)
        func openActions() {
            let actions = app.buttons["doc.actions"].exists ? app.buttons["doc.actions"] : app.buttons["Document actions"]
            if actions.exists { actions.tap() }
            else {
                app.buttons["More"].firstMatch.tap()
                if app.buttons["Document actions"].exists { app.buttons["Document actions"].tap() }
            }
        }
        openActions()
        let menuShot = XCTAttachment(screenshot: app.screenshot()); menuShot.name = "native-document-action-menu"; menuShot.lifetime = .keepAlways; add(menuShot)
        for label in ["Export as .md", "Export as .pdf", "FD Ref", "Versioning", "Move…", "Archive document", "Delete document"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "Reader exposes \(label)")
        }
        app.buttons["Delete document"].tap()
        XCTAssertTrue(app.sheets["Delete this document?"].waitForExistence(timeout: 5))
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)).tap() }
        XCTAssertTrue(app.staticTexts["doc.title"].waitForExistence(timeout: 5), "cancel keeps the reader and shared record")
        openActions(); app.buttons["Export as .md"].tap()
        let exportCancel = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch
        XCTAssertTrue(exportCancel.waitForExistence(timeout: 10), "Markdown opens native file export")
        let exportShot = XCTAttachment(screenshot: app.screenshot()); exportShot.name = "native-document-markdown-export"; exportShot.lifetime = .keepAlways; add(exportShot)
        exportCancel.tap()
    }

    func testReaderSharedHistoryPreview() {
        let app = launch(reset: true, edit: false)
        if app.buttons["doc.actions"].exists { app.buttons["doc.actions"].tap() }
        else { app.buttons["More"].firstMatch.tap(); app.buttons["Document actions"].tap() }
        app.buttons["Versioning"].tap()
        XCTAssertTrue(app.staticTexts["Versioning"].waitForExistence(timeout: 10) || app.navigationBars["Versioning"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Copy source"].waitForExistence(timeout: 10), "canonical Tower snapshot loaded for history preview")
        let historyShot = XCTAttachment(screenshot: app.screenshot()); historyShot.name = "native-document-canonical-history"; historyShot.lifetime = .keepAlways; add(historyShot)
        app.buttons["Copy source"].tap()
        app.buttons["Done"].tap()
    }

    func testDefaultViewAndSavedOpeningPreferenceAcrossRestart() {
        var app = launch(reset: true, edit: false)
        XCTAssertTrue(app.staticTexts["doc.title"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.webViews["doc.editor"].exists)
        func choose(_ value: String) {
            app.buttons["settings"].tap()
            let picker = app.descendants(matching: .any)["settings.documentOpeningMode"].firstMatch
            for _ in 0..<12 where !picker.isHittable { app.swipeUp() }
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            picker.tap()
            app.buttons[value].firstMatch.tap()
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "document-opening-\(value)"; shot.lifetime = .keepAlways; add(shot)
            app.buttons["Done"].tap()
        }
        choose("Edit")
        app.terminate()
        app = launch(reset: false, edit: false)
        XCTAssertTrue(app.webViews["doc.editor"].waitForExistence(timeout: 15))
        choose("View")
        app.terminate()
        app = launch(reset: false, edit: false)
        XCTAssertTrue(app.staticTexts["doc.title"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.webViews["doc.editor"].exists)
        enterEdit(app)
        XCTAssertTrue(app.webViews["doc.editor"].waitForExistence(timeout: 15))
    }

    func testInlineFormattedEditingSelectionCommentReplyAndReload() {
        let app = launch(reset: true)
        let page = app.webViews["doc.editor"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15), "manual Edit opens the formatted page")
        let paragraph = page.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Every screen reads'")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 15))
        paragraph.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let saveFrame = app.buttons["editor.save"].frame
        let editorFrame = page.frame
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).doubleTap()
        if app.menuItems["Select"].waitForExistence(timeout: 2) { app.menuItems["Select"].tap() }
        else if app.buttons["Select"].exists { app.buttons["Select"].tap() }
        let selectionShot = XCTAttachment(screenshot: app.screenshot()); selectionShot.name = "document-word-selection"; selectionShot.lifetime = .keepAlways; add(selectionShot)
        let selected = app.buttons["Comment on selected text"]
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        XCTAssertTrue(selected.isEnabled, "highlighted text offers an anchored comment")
        XCTAssertEqual(app.buttons["editor.save"].frame, saveFrame, "selection adds no toolbar space")
        XCTAssertEqual(page.frame, editorFrame, "selection adds no editor space")
        XCTAssertGreaterThanOrEqual(selected.frame.width, 44)
        XCTAssertGreaterThanOrEqual(selected.frame.height, 44)
        XCTAssertLessThanOrEqual(selected.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "action stays above keyboard")
        XCTAssertGreaterThan(selected.frame.midX, page.frame.midX, "action stays at page right")
        selected.tap()
        XCTAssertTrue(app.staticTexts["Selected text"].waitForExistence(timeout: 10), "action captures selected anchor before opening composer")
        let field = app.textFields["doccomment.field"].exists ? app.textFields["doccomment.field"] : app.textViews["doccomment.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        for character in "Comment on highlighted passage" { field.typeText(String(character)) }
        XCTAssertEqual(field.value as? String, "Comment on highlighted passage")
        app.buttons["doccomment.send"].tap()
        XCTAssertTrue(app.staticTexts["Comment on highlighted passage"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "document-anchored-comment"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Reply"].firstMatch.tap()
        field.tap()
        for character in "Reply to highlighted passage" { field.typeText(String(character)) }
        XCTAssertEqual(field.value as? String, "Reply to highlighted passage")
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
        let reopened = again.buttons["Comment on selected text"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        XCTAssertTrue(reopened.isEnabled, "reopening the comment highlights its original passage")
    }

    func testReaderTableSelectionResolveReopenAndReload() {
        let app = launch(reset: true, edit: false)
        let cell = app.textViews.matching(identifier: "doc.selectable.4.0.0.0").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "table header uses the native selection bridge")
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)).press(forDuration: 1.2)
        if app.menuItems["Select"].waitForExistence(timeout: 2) { app.menuItems["Select"].tap() }
        else if app.buttons["Select"].exists { app.buttons["Select"].tap() }
        let action = app.buttons["doc.selection.comment"].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        action.tap()
        XCTAssertTrue(app.staticTexts["Selected text"].waitForExistence(timeout: 10))
        let field = app.textViews["doccomment.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); for character in "Reader table selection comment" { field.typeText(String(character)) }
        XCTAssertEqual(field.value as? String, "Reader table selection comment")
        app.buttons["doccomment.send"].tap()
        XCTAssertTrue(app.staticTexts["Reader table selection comment"].waitForExistence(timeout: 15))
        app.buttons.matching(NSPredicate(format: "label == %@", "Resolve")).allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(app.staticTexts["Reader table selection comment"].waitForNonExistence(timeout: 15))
        app.buttons["Resolved"].tap()
        XCTAssertTrue(app.staticTexts["Reader table selection comment"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label == %@", "Reopen")).allElementsBoundByIndex.last!.tap()
        app.buttons["Active"].tap()
        XCTAssertTrue(app.staticTexts["Reader table selection comment"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "reader-table-comment-reopened"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
        let again = launch(reset: false, edit: false)
        again.buttons["doc.comments"].tap()
        XCTAssertTrue(again.staticTexts["Reader table selection comment"].waitForExistence(timeout: 15))
        XCTAssertTrue(again.buttons.containing(NSPredicate(format: "label CONTAINS 'Locate text'")).firstMatch.exists)
    }

    func testMarkdownOpensFormattedAndSelectionAnchorSurvivesReload() {
        let app = launch(reset: true, document: "Theme notes (Markdown)")
        let heading = app.webViews["doc.editor"].staticTexts["Theme notes"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 15), "raw Markdown opens formatted in the same editor")
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).press(forDuration: 1.2)
        if app.menuItems["Select"].waitForExistence(timeout: 2) { app.menuItems["Select"].tap() }
        else if app.buttons["Select"].exists { app.buttons["Select"].tap() }
        let selected = app.buttons["Comment on selected text"]
        XCTAssertTrue(selected.isEnabled)
        selected.tap()
        XCTAssertTrue(app.staticTexts["Selected text"].waitForExistence(timeout: 10), "action captures selected anchor before opening composer")
        let field = app.textFields["doccomment.field"].exists ? app.textFields["doccomment.field"] : app.textViews["doccomment.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for character in "Markdown passage comment" { field.typeText(String(character)) }
        XCTAssertEqual(field.value as? String, "Markdown passage comment")
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
        XCTAssertTrue(again.buttons["Comment on selected text"].isEnabled)
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
