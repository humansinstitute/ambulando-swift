import XCTest

/// Canvas editing on local sample data (`-AmbulandoUITestFixture`, `SampleSurfaceTower`, which applies Tower's version
/// and permission checks): create a canvas, add an item, move and resize it, remove it, rename the canvas. Not evidence
/// of live Tower behaviour.
@MainActor
final class CanvasEditingUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitFrame(_ element: XCUIElement, timeout: TimeInterval = 10, _ check: (CGRect) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if element.exists, check(element.frame) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// The canvas's name: in the bottom bar on the iPhone (the canvas uses the whole screen), the navigation bar elsewhere.
    private func canvasTitle(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let bar = app.descendants(matching: .any)["canvas.bottomBar"].firstMatch
        return bar.exists || UIDevice.current.userInterfaceIdiom == .phone ? bar.staticTexts[title].firstMatch : app.navigationBars[title].firstMatch
    }

    private func openNewCanvas(_ app: XCUIApplication, _ name: String) {
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        app.section("Deck")
        app.deckCard("canvas")
        let new = app.buttons["canvas.new"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        new.tap()
        let title = app.alerts["New canvas"].textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText(name)
        app.alerts["New canvas"].buttons["Create"].firstMatch.tap()
        XCTAssertTrue(canvasTitle(app, name).waitForExistence(timeout: 15), "the created canvas opens")
    }

    /// The iPhone canvas fills the screen: no section bar, Back and the controls at the bottom; Back returns to Deck.
    func testPhoneCanvasUsesTheWholeScreenWithBottomControls() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout") }
        let app = XCUIApplication()
        openNewCanvas(app, "Thumb reach")
        XCTAssertFalse(app.descendants(matching: .any)["section.bar"].exists, "the section bar is hidden over a canvas")
        let bar = app.descendants(matching: .any)["canvas.bottomBar"].firstMatch
        XCTAssertTrue(bar.exists)
        XCTAssertGreaterThan(bar.frame.minY, app.frame.height * 0.75, "the canvas controls sit at the bottom: \(bar.frame)")
        XCTAssertTrue(app.buttons["canvas.items"].firstMatch.exists)
        capture(app, "canvas-phone-bottom-controls")
        app.buttons["canvas.back"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["section.bar"].waitForExistence(timeout: 10), "the section bar is back on Deck")
    }

    /// Drawing elements and a new whiteboard, as on the web: add text, a shape and an arrow, edit the text, duplicate,
    /// delete; create a board File and place it.
    func testElementsAndANewWhiteboard() {
        let app = XCUIApplication()
        openNewCanvas(app, "Sketchbook")
        app.buttons["canvas.editMenu"].firstMatch.tap()
        app.buttons["canvas.edit"].firstMatch.tap()

        // Text.
        app.buttons["canvas.add"].firstMatch.tap()
        app.buttons["canvas.add.text"].firstMatch.tap()
        let field = app.textViews["canvas.text.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Kick-off")
        app.buttons["canvas.text.save"].firstMatch.tap()
        let text = app.descendants(matching: .any)["element.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 15), "the text element is on the board after Tower answers")
        XCTAssertTrue(app.descendants(matching: .any)["canvas.elementBar"].waitForExistence(timeout: 5), "and selected")
        XCTAssertFalse(app.descendants(matching: .any)["canvas.editError"].exists)

        // Edit it.
        app.buttons["element.editText"].firstMatch.tap()
        let edit = app.textViews["canvas.text.field"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.typeText(" notes")
        app.buttons["canvas.text.save"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Text: Kick-off notes'")).firstMatch.waitForExistence(timeout: 15))

        // Duplicate, then delete the copy.
        app.buttons["element.duplicate"].firstMatch.tap()
        let texts = app.descendants(matching: .any).matching(identifier: "element.text")
        XCTAssertTrue(waitCount(texts, 2), "duplicated")

        // A shape and an arrow.
        app.buttons["canvas.add"].firstMatch.tap()
        app.buttons["Ellipse"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["element.ellipse"].waitForExistence(timeout: 15))
        app.buttons["canvas.add"].firstMatch.tap()
        app.buttons["canvas.add.arrow"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["element.arrow"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["element.end"].waitForExistence(timeout: 5), "an arrow is reshaped by its ends")
        app.buttons["element.delete"].firstMatch.tap()
        XCTAssertTrue(waitGone(app.descendants(matching: .any)["element.arrow"].firstMatch), "deleted")

        // A line and a frame.
        app.buttons["canvas.add"].firstMatch.tap()
        app.buttons["canvas.add.line"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["element.line"].waitForExistence(timeout: 15))
        app.buttons["canvas.add"].firstMatch.tap()
        app.buttons["canvas.add.frame"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["element.frame"].waitForExistence(timeout: 15))

        // Group two items: pick them, then Group.
        app.buttons["canvas.add"].firstMatch.tap()
        app.buttons["canvas.add.group"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["canvas.groupBar"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["canvas.pick.ellipse"].firstMatch.tap()
        app.descendants(matching: .any)["canvas.pick.line"].firstMatch.tap()
        app.buttons["canvas.group.confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Ungroup"].waitForExistence(timeout: 15), "the new group is selected and can be ungrouped")
        XCTAssertFalse(app.descendants(matching: .any)["canvas.editError"].exists)
        capture(app, "canvas-elements")

        // A new whiteboard in #general, placed on the canvas.
        app.buttons["canvas.add"].firstMatch.tap()
        app.buttons["canvas.add.board"].firstMatch.tap()
        let name = app.textFields["canvas.board.title"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Retro board")
        app.buttons["canvas.board.create"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["naplet.Retro board"].firstMatch.waitForExistence(timeout: 20), "the new board is on the canvas")
        XCTAssertFalse(app.descendants(matching: .any)["canvas.editError"].exists)
        capture(app, "canvas-new-board")
    }

    private func waitCount(_ query: XCUIElementQuery, _ count: Int, timeout: TimeInterval = 15) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if query.count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    func testAddMoveResizeRemoveAndRenameOnABoard() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        app.section("Deck")
        app.deckCard("canvas")

        // New canvas from the list opens its (empty) board.
        let new = app.buttons["canvas.new"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        new.tap()
        let title = app.alerts["New canvas"].textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Field notes")
        app.alerts["New canvas"].buttons["Create"].firstMatch.tap()
        XCTAssertTrue(canvasTitle(app, "Field notes").waitForExistence(timeout: 15), "the created canvas opens")

        // Add a document as an item.
        app.buttons["canvas.editMenu"].firstMatch.tap()
        app.buttons["Add item…"].firstMatch.tap()
        let choice = app.buttons["canvas.add.Build 7 launch notes"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        choice.tap()
        // A document naplet is a live window (an element, not a button) since the canvas parity build.
        let item = app.descendants(matching: .any)["naplet.Build 7 launch notes"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "the added item is on the board after Tower answers")
        XCTAssertTrue(app.descendants(matching: .any)["canvas.editing"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["canvas.editError"].exists)

        // Select, then move it.
        item.tap()
        let before = item.frame
        let start = item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -60, dy: 90)))
        XCTAssertTrue(waitFrame(item) { abs($0.minY - before.minY - 90) < 12 && abs($0.minX - before.minX + 60) < 12 },
                      "moved by the drag: \(before) → \(item.frame)")
        XCTAssertFalse(app.descendants(matching: .any)["canvas.editError"].exists)

        // Resize from the corner handle.
        let moved = item.frame
        let handle = app.descendants(matching: .any)["naplet.resize"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let corner = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 40, dy: 50)))
        // The identified element is the naplet window's title bar, so the new size shows in its width.
        XCTAssertTrue(waitFrame(item) { $0.width > moved.width + 25 }, "resized: \(moved) → \(item.frame)")
        XCTAssertFalse(app.descendants(matching: .any)["canvas.editError"].exists)
        capture(app, "canvas-edit-moved")

        // Remove it (confirmed).
        app.buttons["naplet.remove"].firstMatch.tap()
        let confirm = app.buttons["naplet.remove.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitGone(item), "the item is gone after Tower answers")

        // Rename the canvas.
        app.buttons["canvas.done"].firstMatch.tap()
        app.buttons["canvas.editMenu"].firstMatch.tap()
        app.buttons["canvas.rename"].firstMatch.tap()
        let field = app.alerts["Rename canvas"].textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Field notes v2")
        app.alerts["Rename canvas"].buttons["Rename"].firstMatch.tap()
        XCTAssertTrue(canvasTitle(app, "Field notes v2").waitForExistence(timeout: 15), "renamed on Tower and shown")
        capture(app, "canvas-edit-renamed")
    }
}
