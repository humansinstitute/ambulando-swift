import XCTest

/// The embedded Excalidraw editor on local sample data (`-AmbulandoUITestFixture`, `SampleBoardTower`): the web
/// editor's toolbar on the canvas and full screen, drawing, Save as a new version, and the saved version after a
/// relaunch. Not evidence of live Tower behaviour.
@MainActor
final class BoardEditorUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture"] + (reset ? ["-AmbulandoFixtureReset"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openLaunchBoard(_ app: XCUIApplication) {
        app.section("Deck")
        app.deckCard("canvas")
        let canvas = app.buttons["canvas.Launch board"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        canvas.tap()
    }

    /// An Excalidraw tool in the web editor's toolbar (labels such as "Rectangle — R or 2").
    private func tool(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    private func status(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["board.status"].firstMatch }

    private func waitForStatus(_ app: XCUIApplication, _ predicate: String, timeout: TimeInterval = 20) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label \(predicate)"), object: status(app))
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func testDrawSaveAndReopenBoardInTheEmbeddedEditor() {
        var app = launch(reset: true)
        openLaunchBoard(app)

        // On the canvas: selecting the board runs the web editor with its toolbar inside the board window.
        let header = app.descendants(matching: .any)["naplet.Architecture sketch"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        header.tap()
        XCTAssertTrue(tool(app, "Rectangle").waitForExistence(timeout: 30), "Excalidraw toolbar inside the board naplet")
        XCTAssertTrue(waitForStatus(app, "== 'v1'"), "saved version shown in the board window")
        capture(app, "board-inline-editor")

        // Full screen: the same editor with history in the navigation bar.
        app.buttons["board.expand"].firstMatch.tap()
        let rectangle = tool(app, "Rectangle")
        XCTAssertTrue(rectangle.waitForExistence(timeout: 30), "Excalidraw toolbar full screen")
        XCTAssertTrue(waitForStatus(app, "== 'v1'"))
        capture(app, "board-fullscreen-before")

        rectangle.tap()
        let web = app.webViews.firstMatch
        let from = web.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45))
        from.press(forDuration: 0.1, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
        XCTAssertTrue(waitForStatus(app, "BEGINSWITH 'Unsaved'"), "drawing makes an unsaved draft")
        capture(app, "board-drawn-unsaved")

        let save = app.webViews.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "the editor's floating Save")
        save.tap()
        XCTAssertTrue(waitForStatus(app, "== 'v2'"), "Save publishes version 2")
        capture(app, "board-saved-v2")

        // Reopen after a relaunch: the board loads version 2 from the (sample) Tower, with the new shape.
        app.terminate()
        app = launch(reset: false)
        openLaunchBoard(app)
        let reopened = app.descendants(matching: .any)["naplet.Architecture sketch"].firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 15))
        app.buttons["board.expand"].firstMatch.tap()
        XCTAssertTrue(tool(app, "Rectangle").waitForExistence(timeout: 30))
        XCTAssertTrue(waitForStatus(app, "== 'v2'"), "reopened at the saved version, no draft left")
        app.buttons["board.menu"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'v2'")).firstMatch.waitForExistence(timeout: 10), "history lists v2")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'v1'")).firstMatch.exists, "and v1")
        capture(app, "board-reopened-history")
    }
}
