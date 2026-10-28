import XCTest

/// Wiki links on iPhone/iPad against the sample Tower (`-AmbulandoFixtureWiki` adds disposable documents). The documents open
/// straight into the formatted editor page, so these exercise the links as a person edits.
@MainActor
final class WikiLinksUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(reset: Bool = true, document: String = "Wiki hub") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureWiki"] + (reset ? ["-AmbulandoFixtureReset"] : [])
        app.launch()
        app.section("Docs")
        let row = app.buttons["doc.\(document)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "\(document) listed")
        row.tap()
        return app
    }

    /// The link text in the editor page (a node view or a marked literal), found by its visible title.
    private func link(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let page = app.webViews["doc.editor"].firstMatch
        let byLabel = page.links.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        if byLabel.waitForExistence(timeout: 20) { return byLabel }
        return page.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testDocumentAtPickerUsesKeyboardVisibleHeightAndScrollsToLaterResult() {
        let app = launch()
        let page = app.webViews["doc.editor"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        let prose = page.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Pick one of'")).firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 20))
        prose.tap(); app.typeText(" @")
        let picker = app.webViews.otherElements["Link to a record"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let viewport = page.frame, popup = picker.frame, keyboard = app.keyboards.firstMatch.frame
        print("PICKER_GEOMETRY viewport=\(viewport) popup=\(popup) keyboard=\(keyboard)")
        XCTAssertGreaterThan(popup.height, viewport.height * 0.75, "substantially more than the old 45% cap")
        XCTAssertLessThanOrEqual(popup.maxY, min(viewport.maxY, keyboard.minY) + 1)
        attach(app, "document-picker-keyboard-height")
        let options = picker.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS ' · '"))
        let initiallyVisible = Set(options.allElementsBoundByIndex.filter { popup.intersects($0.frame) }.map(\.label))
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: popup.midX, dy: popup.maxY - 12))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: popup.midX, dy: popup.minY + 12)))
        let later = options.allElementsBoundByIndex.last(where: {
            popup.contains($0.frame) && !$0.frame.isEmpty && !initiallyVisible.contains($0.label)
        })
        XCTAssertNotNil(later, "a later result is reachable by scrolling")
        let chosen = later?.label.components(separatedBy: " · ").first ?? ""
        XCTAssertFalse(chosen.isEmpty)
        later?.tap()
        XCTAssertFalse(picker.exists)
        XCTAssertTrue(page.links.containing(NSPredicate(format: "label CONTAINS %@", chosen)).firstMatch.waitForExistence(timeout: 5), "the newly revealed result was inserted")
        app.typeText(" kept typing")
        XCTAssertTrue(page.staticTexts.containing(NSPredicate(format: "label CONTAINS 'kept typing'")).firstMatch.waitForExistence(timeout: 5))
        app.typeText(" @")
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "fresh trigger reopens without losing editor focus")
        attach(app, "document-picker-reopened")
    }

    func testDocumentAtPickerInsertsAndReopensRecordLink() {
        let app = launch()
        let page = app.webViews["doc.editor"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        let prose = page.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Pick one of'")).firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 20))
        prose.tap()
        app.typeText(" @doc:Wiki target")
        let option = page.otherElements.matching(NSPredicate(format: "label == 'Wiki target · Doc'")).firstMatch
        // The panel is a page-level overlay beside the editor root.
        let fallback = app.webViews.otherElements.matching(NSPredicate(format: "label == 'Wiki target · Doc'")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 8) || fallback.waitForExistence(timeout: 5))
        (option.exists ? option : fallback).tap()
        let linked = page.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Wiki target'")).firstMatch
        XCTAssertTrue(linked.waitForExistence(timeout: 10))
        attach(app, "document-at-link-inserted")
        let reference = page.links.matching(NSPredicate(format: "label == 'Wiki target'")).firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 10))
        reference.tap()
        let title = app.textFields["editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.value as? String, "Wiki target")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        XCTAssertTrue(page.links.matching(NSPredicate(format: "label == 'Wiki target'")).firstMatch.waitForExistence(timeout: 10), "the stored local draft reopens with the stable record link")
    }

    func testDocumentAtCanvasLinkOpensNativeCanvasAndBackKeepsDraft() {
        let app = launch()
        let page = app.webViews["doc.editor"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        let prose = page.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Pick one of'")).firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 20))
        prose.tap(); app.typeText(" @canvas:Launch board")
        let option = app.webViews.otherElements.matching(NSPredicate(format: "label == 'Launch board · Canvas'")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        option.tap()
        let reference = page.links.matching(NSPredicate(format: "label == 'Launch board'")).firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 10))
        reference.tap()
        XCTAssertTrue(app.buttons["canvas.items"].waitForExistence(timeout: 20), "the native canvas opens rather than a browser tab")
        attach(app, "document-at-canvas-opened")
        app.buttons["canvas.back"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        XCTAssertTrue(page.links.matching(NSPredicate(format: "label == 'Launch board'")).firstMatch.waitForExistence(timeout: 10), "Back restores the draft with its portable canvas link")
    }

    func testStableLinkOpensItsPageUnderTheCurrentTitleAndBackKeepsTheDraft() {
        let app = launch()
        let page = app.webViews["doc.editor"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        // The link was written as "Old target name"; the page it points at is now called "Wiki target".
        let target = link(app, "Wiki target")
        XCTAssertTrue(target.waitForExistence(timeout: 20), "the link shows the page's current title")
        let typed = page.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Pick one of'")).firstMatch
        typed.tap()
        app.typeText(" kept words")
        attach(app, "wiki-before-open")
        target.tap()
        XCTAssertTrue(app.staticTexts["doc.title"].waitForExistence(timeout: 20) || app.webViews["doc.editor"].exists)
        XCTAssertTrue(app.staticTexts["Wiki target"].waitForExistence(timeout: 20) || app.textFields["editor.title"].waitForExistence(timeout: 20), "the linked page opened")
        attach(app, "wiki-opened-page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let back = app.webViews["doc.editor"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 20), "Back returns to the hub")
        XCTAssertTrue(back.staticTexts.containing(NSPredicate(format: "label CONTAINS 'kept words'")).firstMatch.waitForExistence(timeout: 20), "the unsaved words survived the trip")
    }

    func testMissingLinkOffersCreationAndCreatesOnePageThatTheLinkOpens() {
        let app = launch()
        let missing = link(app, "Fresh page")
        XCTAssertTrue(missing.waitForExistence(timeout: 20))
        missing.tap()
        let confirm = app.buttons["wiki.create.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "tapping a missing page offers to create it")
        XCTAssertTrue(app.pickers["wiki.destination"].exists || app.buttons["wiki.destination"].exists || app.staticTexts["Create in"].exists)
        attach(app, "wiki-create-sheet")
        confirm.tap()
        // The page is made, linked into the hub, and opened for the person who is still on the hub.
        let title = app.textFields["editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the created page opened")
        XCTAssertEqual(title.value as? String, "Fresh page")
        attach(app, "wiki-created-page-open")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Back on the hub the text is a stable link to that page: tapping it opens it, with no second offer to create.
        let again = link(app, "Fresh page")
        XCTAssertTrue(again.waitForExistence(timeout: 20))
        again.tap()
        XCTAssertFalse(app.buttons["wiki.create.confirm"].waitForExistence(timeout: 3), "no second creation offer")
        XCTAssertEqual(app.textFields["editor.title"].value as? String, "Fresh page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["editor.close"].tap()
        if app.buttons["editor.keepDraft"].waitForExistence(timeout: 3) { app.buttons["editor.keepDraft"].firstMatch.tap() }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["doc.Fresh page"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.buttons.matching(identifier: "doc.Fresh page").count, 1, "exactly one page was made")
    }

    func testToolbarPickerSearchesThisChannelFirstShowsPlacesAndOffersEverywhere() {
        let app = launch()
        XCTAssertTrue(app.webViews["doc.editor"].firstMatch.waitForExistence(timeout: 20))
        let button = app.buttons["editor.format.wikilink"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the toolbar has Link to doc or note")
        XCTAssertEqual(button.label, "Link to doc or note")
        button.tap()
        let search = app.textFields["wiki.picker.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Twin")
        let twins = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Twin,'"))
        XCTAssertEqual(twins.count, 2, "same-titled pages are both listed")
        XCTAssertTrue(twins.element(boundBy: 0).label.contains("/"), "each result names its scope and channel")
        search.clearAndType("Ops runbook")
        attach(app, "wiki-picker-local-only")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ops runbook,'")).firstMatch.exists, "another scope is not searched by default")
        let wide = app.switches["wiki.picker.everywhere"]
        XCTAssertTrue(wide.waitForExistence(timeout: 5))
        (wide.switches.firstMatch.exists ? wide.switches.firstMatch : wide).tap()
        XCTAssertEqual(wide.value as? String, "1", "the wider search is on")
        let ops = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ops runbook,'")).firstMatch
        XCTAssertTrue(ops.waitForExistence(timeout: 5), "an explicit wider search finds it")
        attach(app, "wiki-picker-everywhere")
        ops.tap()
        XCTAssertTrue(link(app, "Ops runbook").waitForExistence(timeout: 10), "the chosen page is linked in the document")
    }

    func testSharedTitleAsksWhichPageBeforeLinking() {
        let app = launch()
        let twin = link(app, "Twin")
        XCTAssertTrue(twin.waitForExistence(timeout: 20))
        twin.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Several pages are called'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Twin,'")).count, 2)
        attach(app, "wiki-ambiguous")
    }

    func testMovePageToAnotherScopeShowsConsequencesAndOldLinkStillOpensIt() {
        let app = launch(document: "Wiki target")
        XCTAssertTrue(app.buttons["doc.actions"].waitForExistence(timeout: 20))
        app.buttons["doc.actions"].tap()
        app.buttons["doc.move"].tap()
        let destination = app.buttons["wiki.move.destination"].exists ? app.buttons["wiki.move.destination"] : app.pickers["wiki.move.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.tap()
        let ops = app.buttons.containing(NSPredicate(format: "label CONTAINS 'deploys'")).firstMatch
        XCTAssertTrue(ops.waitForExistence(timeout: 5))
        ops.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'never grants access'")).firstMatch.waitForExistence(timeout: 5), "the access consequence is stated")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'changes scope'")).firstMatch.exists)
        attach(app, "wiki-move-sheet")
        app.buttons["wiki.move.confirm"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Moved to'")).firstMatch.waitForExistence(timeout: 20))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["doc.Wiki hub"].tap()
        let target = link(app, "Wiki target")
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        target.tap()
        XCTAssertTrue(app.textFields["editor.title"].waitForExistence(timeout: 20), "the old link opened a page")
        XCTAssertEqual(app.textFields["editor.title"].value as? String, "Wiki target", "it is the same record")
        app.buttons["doc.actions"].tap()
        app.buttons["doc.move"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'deploys'")).firstMatch.waitForExistence(timeout: 10), "and it now lives where it was moved")
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
