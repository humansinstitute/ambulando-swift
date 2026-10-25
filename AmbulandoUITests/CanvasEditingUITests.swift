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
        XCTAssertTrue(app.navigationBars["Field notes"].waitForExistence(timeout: 15), "the created canvas opens")

        // Add a document as an item.
        app.buttons["canvas.editMenu"].firstMatch.tap()
        app.buttons["Add item…"].firstMatch.tap()
        let choice = app.buttons["canvas.add.Build 7 launch notes"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        choice.tap()
        let item = app.buttons["naplet.Build 7 launch notes"].firstMatch
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
        XCTAssertTrue(waitFrame(item) { $0.width > moved.width + 25 && $0.height > moved.height + 30 }, "resized: \(moved) → \(item.frame)")
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
        XCTAssertTrue(app.navigationBars["Field notes v2"].waitForExistence(timeout: 15), "renamed on Tower and shown")
        capture(app, "canvas-edit-renamed")
    }
}
