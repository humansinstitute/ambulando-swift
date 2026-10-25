import XCTest

/// Inbox, tasks, documents, files, search and message actions against the app's labelled local sample data
/// (`-AmbulandoUITestFixture`). The real store, sync engine, write queue, document saver and signer run; Tower is an
/// in-process stand-in. These are not evidence of live Tower behaviour.
@MainActor
final class WorkFlowUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(reset: Bool = true, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture"] + (reset ? ["-AmbulandoFixtureReset"] : []) + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15), "sample data is labelled")
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func tab(_ app: XCUIApplication, _ name: String) { app.section(name) }

    private func input(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let any = app.descendants(matching: .any)[id]
        _ = any.waitForExistence(timeout: 10)
        let field = app.textFields[id].exists ? app.textFields[id] : app.textViews[id]
        if !field.exists {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "hierarchy-\(id)"; tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(field.waitForExistence(timeout: 2), id)
        return field
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    /// Deck's Inbox (the web's activity feed, not an unread-only list): opening marks read, Mark done finishes a review
    /// task, and read state survives relaunch.
    func testDeckInboxOpenMarksReadAndDoneFinishesAReviewTask() {
        let app = launch()
        tab(app, "Deck")
        app.deckCard("inbox")
        // Hide conversations with the type toggle (web Inbox record types), then search: rows are lazy.
        let chats = app.buttons["deck.inbox.type.chat"].firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        chats.tap()
        let search = app.textFields["deck.inbox.search"].firstMatch
        search.tap(); search.typeText("Native app plan\n")
        let plan = app.buttons.matching(NSPredicate(format: "identifier == 'deck.inbox.item' AND label CONTAINS 'Native app plan'")).firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 15))
        XCTAssertTrue(plan.label.contains("unread"), plan.label)
        capture(app, "deck-inbox")
        // Opening a document marks it read; it stays in the feed (activity), without the unread mark.
        plan.tap()
        XCTAssertTrue(app.textFields["editor.title"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let readPlan = app.buttons.matching(NSPredicate(format: "identifier == 'deck.inbox.item' AND label CONTAINS 'Native app plan' AND NOT (label CONTAINS 'unread')")).firstMatch
        XCTAssertTrue(readPlan.waitForExistence(timeout: 10), "read state shown after Back")
        // The review task: clear the search and find it.
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Review the native\n")
        let review = app.buttons.matching(NSPredicate(format: "identifier == 'deck.inbox.item' AND label CONTAINS 'Review the native inbox'")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        XCTAssertTrue(review.label.contains("unread"), review.label)
        // Mark done on the unread review task (web Deck): it leaves the feed once done and read.
        let done = app.buttons["deck.inbox.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(waitGone(review), "a done, read task leaves Deck's Inbox")
        tab(app, "Tasks")
        XCTAssertTrue(app.scrollTo(app.staticTexts["Done · 2"]), "the task moved to Done")
        app.terminate()
        let again = launch(reset: false)
        tab(again, "Deck")
        again.deckCard("inbox")
        let field = again.textFields["deck.inbox.search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Review the native\n")
        XCTAssertTrue(again.descendants(matching: .any)["deck.inbox.empty"].firstMatch.waitForExistence(timeout: 15), "done and read survive relaunch")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Inbox counts mentions\n")
        XCTAssertTrue(again.buttons.matching(NSPredicate(format: "identifier == 'deck.inbox.item' AND label CONTAINS 'unread'")).firstMatch.waitForExistence(timeout: 15),
                      "the unread conversation is still unread")
    }

    func testTaskCreateStateCommentAndEdit() {
        let app = launch()
        tab(app, "Tasks")
        XCTAssertTrue(app.buttons["task.Write release notes for build 3"].waitForExistence(timeout: 15))
        capture(app, "wp4-tasks-list")
        app.buttons["tasks.new"].tap()
        input(app, "newtask.title").tap()
        app.typeText("Test the phone build")
        app.buttons["newtask.add"].tap()
        XCTAssertTrue(app.buttons["task.Test the phone build"].waitForExistence(timeout: 15))
        app.buttons["task.Test the phone build"].tap()
        XCTAssertTrue(app.staticTexts["task.title"].waitForExistence(timeout: 10))
        app.buttons["task.state"].tap()
        app.buttons["In progress"].tap()
        XCTAssertTrue(app.buttons["task.state"].staticTexts["In progress"].waitForExistence(timeout: 10) || app.buttons["In progress"].waitForExistence(timeout: 5))
        let comment = input(app, "comment.field")
        comment.tap()
        comment.typeText("Started on device")
        app.buttons["comment.send"].tap()
        XCTAssertTrue(app.staticTexts["Started on device"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitGone(app.otherElements["comment.pending"]), "the comment reached Tower")
        app.buttons["task.edit"].tap()
        let title = input(app, "edittask.title")
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        title.typeText(" today")
        app.buttons["edittask.save"].tap()
        XCTAssertTrue(app.staticTexts["Test the phone build today"].waitForExistence(timeout: 10))
        capture(app, "wp4-task-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls["tasks.layout"].buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'In progress ·'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Test the phone build today'")).firstMatch.exists, "the task is in its board column")
        capture(app, "wp4-tasks-board")
    }

    func testDocumentReadEditWithKeyboardAndSave() {
        let app = launch()
        tab(app, "Docs")
        XCTAssertTrue(app.buttons["doc.Native app plan"].waitForExistence(timeout: 15))
        app.buttons["doc.Native app plan"].tap()
        XCTAssertTrue(app.textFields["editor.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'kept unchanged'")).firstMatch.waitForExistence(timeout: 10),
                      "the unknown block is shown as preserved, not dropped")
        capture(app, "wp4-doc-reader")
        app.buttons["doc.comments"].tap()
        let comment = input(app, "doccomment.field")
        comment.tap()
        comment.typeText("Reviewed on the phone")
        app.buttons["doccomment.send"].tap()
        XCTAssertTrue(app.staticTexts["Reviewed on the phone"].waitForExistence(timeout: 10))

        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["You are editing (lease held)."].waitForExistence(timeout: 10))
        // The page itself is the editor (bundled web editor in the document's white page).
        let page = app.webViews["doc.editor"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        let last = page.staticTexts["Edit this paragraph on the phone."].firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 15), "the document's own formatted text is editable in place")
        XCTAssertTrue(page.staticTexts.containing(NSPredicate(format: "label CONTAINS 'kept unchanged'")).firstMatch.exists, "unknown block shown as kept")
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        app.typeText(" Edited on iPhone.")
        // Formatting from the toolbar applies to what is typed next.
        app.buttons["editor.format.bold"].tap()
        app.typeText(" Bold")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editor.save"].isHittable)
        capture(app, "wp4-doc-editor-keyboard")
        app.buttons["editor.save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'on the phone. Edited on iPhone.'")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'kept unchanged'")).firstMatch.exists, "unknown block survived the save")
        capture(app, "wp4-doc-saved")
    }

    func testDocumentDraftSurvivesRelaunchOffline() {
        // Load the document once online, then edit it offline.
        let online = launch()
        tab(online, "Docs")
        online.buttons["doc.Theme notes (Markdown)"].tap()
        XCTAssertTrue(online.textFields["editor.title"].waitForExistence(timeout: 15))
        online.terminate()

        let offline = launch(reset: false, ["-AmbulandoFixtureOffline"])
        tab(offline, "Docs")
        offline.buttons["doc.Theme notes (Markdown)"].tap()
        XCTAssertTrue(offline.webViews["doc.editor"].firstMatch.waitForExistence(timeout: 15))
        let page = offline.webViews["doc.editor"].firstMatch
        let dark = page.staticTexts["Dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 15))
        dark.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        offline.typeText("\nOffline line")
        offline.buttons["editor.close"].tap()
        // Cancel with changes asks; keeping the draft leaves it on the device, unsent.
        XCTAssertTrue(offline.buttons["editor.keepDraft"].waitForExistence(timeout: 5))
        offline.buttons["editor.keepDraft"].firstMatch.tap()
        XCTAssertTrue(offline.buttons["doc.draftBanner"].waitForExistence(timeout: 10), "the draft is kept on the device")
        offline.terminate()

        let back = launch(reset: false)
        tab(back, "Docs")
        XCTAssertTrue(back.staticTexts["Unsaved edits"].waitForExistence(timeout: 15))
        back.buttons["doc.Theme notes (Markdown)"].tap()
        XCTAssertTrue(back.webViews["doc.editor"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(back.webViews["doc.editor"].staticTexts["Offline line"].firstMatch.waitForExistence(timeout: 15), "the draft survived relaunch")
        back.buttons["editor.save"].tap()
        XCTAssertTrue(back.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Offline line'")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(back.buttons["doc.draftBanner"].exists)
    }

    func testFilesDownloadAndPreview() {
        let app = launch()
        tab(app, "Files")
        XCTAssertTrue(app.buttons["file.sync-results.txt"].waitForExistence(timeout: 15))
        capture(app, "wp4-files")
        app.buttons["file.sync-results.txt"].tap()
        app.buttons["file.download"].tap()
        XCTAssertTrue(app.buttons["file.preview"].waitForExistence(timeout: 15), "downloaded and verified")
        app.buttons["file.preview"].tap()
        sleep(2)
        capture(app, "wp4-file-preview")
    }

    func testMessageReactEditDeleteAndSearch() {
        let app = launch()
        app.buttons["channel.general"].tap()
        let field = input(app, "composer.field")
        field.tap()
        field.typeText("Native edit test")
        app.buttons["composer.send"].tap()
        let sent = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Native edit test'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        XCTAssertTrue(waitGone(app.otherElements["outbox.row"]))
        XCTAssertTrue(sent.isHittable, "own send stays in view above the keyboard")
        // Act on the message from its thread (the composer there is not focused).
        sent.tap()
        let root = app.staticTexts["Native edit test"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'message' AND label CONTAINS 'Native edit test'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.press(forDuration: 1.0)
        app.buttons["message.react"].tap()
        app.buttons["react.heart"].tap()
        let chip = app.descendants(matching: .any)["reaction.heart"]
        if !chip.waitForExistence(timeout: 10) {
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "reaction-tree"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertTrue(chip.exists, "reaction chip shown")
        message.press(forDuration: 1.0)
        app.buttons["message.edit"].tap()
        let edit = input(app, "editmessage.field")
        edit.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        edit.typeText(" (edited)")
        app.buttons["editmessage.save"].tap()
        let edited = app.staticTexts["Native edit test (edited)"].firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 10))
        capture(app, "wp4-message-react-edit")
        message.press(forDuration: 1.0)
        app.buttons["message.delete"].tap()
        app.buttons["Delete"].tap()
        XCTAssertTrue(waitGone(edited), "deleted for everyone")
        app.buttons["thread.focus.close"].firstMatch.tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Native edit test'")).firstMatch.waitForExistence(timeout: 3),
                       "gone from the channel too")
        app.showChannels()   // back to the channel list (search lives in the shell toolbar)

        // Search covers what is stored locally: load the task list once, then search from the shell toolbar.
        tab(app, "Tasks")
        XCTAssertTrue(app.buttons["task.Write release notes for build 3"].waitForExistence(timeout: 15))
        app.buttons["search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("release")
        XCTAssertTrue(app.buttons["search.hit"].firstMatch.waitForExistence(timeout: 10))
        capture(app, "wp4-search")
        XCTAssertTrue(app.staticTexts["Tasks"].exists && app.staticTexts["Messages"].exists, "task and message hits")
        app.buttons["search.hit"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["task.title"].waitForExistence(timeout: 10))
    }
}
