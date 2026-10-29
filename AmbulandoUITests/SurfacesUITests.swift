import XCTest

/// Context Tree, Canvas (naplets, a board, a locked item), agents, Toolbox and personal pins as sections and Deck cards on
/// local sample data
/// (`-AmbulandoUITestFixture`, `SampleSurfaceTower`). Not evidence of live Tower behaviour.
@MainActor
final class SurfacesUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        // Agents and Context are optional sections (off by default, as on the web); these tests turn them on.
        app.launchArguments = ["-AmbulandoUITestFixture", "-sections.agents", "YES", "-sections.context", "YES"] + (reset ? ["-AmbulandoFixtureReset"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openSurface(_ app: XCUIApplication, _ name: String) {
        if name == "canvas" {
            app.section("Deck")
            app.deckCard("canvas")
        } else {
            app.section(name)
        }
    }

    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }

    func testContextTreeOutlineOpensNativeRecordsAndHidesLockedTargets() {
        let app = launch()
        openSurface(app, "context")
        // Home context: choose a scope's tree.
        let scope = app.buttons["context.scope.Ambulando"].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 10))
        scope.tap()
        let root = app.buttons["context.node.Native iPhone app"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["context.bar"].firstMatch.label.contains("Ambulando"), "the shared context follows")
        capture(app, "context-outline")
        root.tap()
        let child = app.buttons["Workspace surfaces"].firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 10))
        child.tap()
        let task = app.buttons["context.reference.Ship build 7 to TestFlight-free phone"].firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Not available to you"].exists, "a locked target is shown without its title")
        XCTAssertFalse(app.staticTexts["Board-only budget"].exists)
        XCTAssertTrue(app.buttons["context.reference.artifact.wingman-suite-arch"].exists)
        capture(app, "context-component")
        task.tap()
        XCTAssertTrue(app.navigationBars.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Ship build 7'")).firstMatch.waitForExistence(timeout: 10)
                      || app.staticTexts["Ship build 7 to TestFlight-free phone"].waitForExistence(timeout: 10), "native task opened")
        capture(app, "context-task")
        back(app)
        XCTAssertTrue(task.waitForExistence(timeout: 5), "back returns to the component")
    }

    func testCanvasBoardShowsSavedNapletsOpensRecordsAndReturnsToTheBoard() {
        let app = launch()
        openSurface(app, "canvas")
        let canvas = app.buttons["canvas.Launch board"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        canvas.tap()
        // Documents and boards are live naplet windows (elements, not buttons) since the canvas parity build.
        let doc = app.descendants(matching: .any)["naplet.Build 7 launch notes"].firstMatch
        XCTAssertTrue(doc.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["naplet.Architecture sketch"].exists)
        XCTAssertTrue(app.buttons["naplet.Not available to you"].exists, "the locked naplet keeps its frame")
        XCTAssertFalse(app.staticTexts["Budget"].exists, "and discloses no title")
        XCTAssertTrue(app.descendants(matching: .any)["naplet.Architecture sketch"].exists)
        XCTAssertFalse(app.buttons["exclamationmark.icloud"].exists, "no sync problem on the board")
        capture(app, "canvas-board")

        // Pan the board, then open the document naplet natively and come back to the same position.
        let board = app.otherElements.firstMatch
        board.swipeLeft()
        let before = doc.frame
        app.buttons["canvas.items"].tap()
        let item = app.buttons["canvas.item.Build 7 launch notes"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(app.navigationBars["Document"].waitForExistence(timeout: 10), "the native document opened")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Build 7 launch notes'")).firstMatch.waitForExistence(timeout: 15))
        capture(app, "canvas-doc")
        back(app)
        XCTAssertTrue(doc.waitForExistence(timeout: 10))
        XCTAssertEqual(doc.frame.origin.x, before.origin.x, accuracy: 2, "returning keeps the board position")

        // The Excalidraw board, full screen, lists what is not drawn.
        app.buttons["canvas.items"].tap()
        app.buttons["canvas.item.Architecture sketch"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["board.unsupported"].waitForExistence(timeout: 20), "unsupported Excalidraw types are listed")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1 × embeddable'")).firstMatch.exists, "with exact counts")
        XCTAssertTrue(app.descendants(matching: .any)["board.canvas"].firstMatch.label.contains("drawn elements"))
        capture(app, "canvas-excalidraw")
    }

    func testAgentsToolboxAndContextPersistAcrossSurfaces() {
        let app = launch()
        openSurface(app, "agents")
        XCTAssertTrue(app.otherElements["agent.Rick"].waitForExistence(timeout: 15) || app.staticTexts["Rick"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Checking the outbox retry states"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'direct Autopilot connection'")).firstMatch.exists, "pipelines are labelled unavailable")
        capture(app, "agents")
        // Choosing a channel in the sidebar opens Deck (web); Agents then reads inside it.
        app.selectSidebarChannel("design")
        XCTAssertTrue(app.buttons["section.deck"].isSelected)
        app.section("Agents")
        XCTAssertTrue(app.buttons["context.bar"].firstMatch.label.contains("design"))
        XCTAssertFalse(app.staticTexts["Checking the outbox retry states"].waitForExistence(timeout: 3), "#general activity is not shown in #design")

        openSurface(app, "toolbox")
        let wapp = app.buttons["wapp.Timesheets"].firstMatch
        XCTAssertTrue(wapp.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Not opened: its address is not HTTPS"].exists)
        capture(app, "toolbox")
        // A WApp opens as an in-app browser tab; Ambulando returns to the Toolbox.
        wapp.tap()
        let returnButton = app.buttons["browser.return"]
        XCTAssertTrue(returnButton.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["browser.tabs"].label, "1 open tab")
        capture(app, "toolbox-web")
        returnButton.tap()
        XCTAssertTrue(wapp.waitForExistence(timeout: 10), "back in the Toolbox")
        app.section("Chat")
        XCTAssertTrue(app.navigationBars["#design"].waitForExistence(timeout: 5), "Chat is one tap away and shows the shared context")
        XCTAssertTrue(app.buttons["context.bar"].firstMatch.label.contains("design"), "the context is shared")
    }

    func testDragMixedPinsPersistsWithoutOpeningOrUnpinning() {
        let app = launch()
        app.section("Deck"); app.deckCard("pinned")
        let all = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'pin.move.'"))
        XCTAssertTrue(all.firstMatch.waitForExistence(timeout: 15))
        let first = all.element(boundBy: 0), last = all.element(boundBy: 1)
        let firstId = first.identifier, lastId = last.identifier
        last.press(forDuration: 0.8, thenDragTo: first)
        let ordered = NSPredicate { _, _ in
            let source = all.matching(identifier: lastId).firstMatch
            let anchor = all.matching(identifier: firstId).firstMatch
            return source.exists && anchor.exists && source.frame.midY < anchor.frame.midY
        }
        let orderExpectation = expectation(for: ordered, evaluatedWith: nil)
        let orderResult = XCTWaiter.wait(for: [orderExpectation], timeout: 10)
        capture(app, "batch-pin-drag-result")
        print("PIN_DRAG_EVIDENCE \(app.staticTexts["pin.drag.evidence"].label)")
        XCTAssertEqual(orderResult, .completed)
        XCTAssertTrue(app.buttons["deck.pinned.design"].exists)
        XCTAssertFalse(app.navigationBars["#design"].exists, "drag does not open the channel")
        XCTAssertEqual(all.count, 2, "drag does not unpin")
        app.terminate()
        let again = launch(reset: false)
        again.section("Deck"); again.deckCard("pinned")
        let restored = again.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'pin.move.'"))
        XCTAssertTrue(restored.firstMatch.waitForExistence(timeout: 15))
        XCTAssertLessThan(restored.matching(identifier: lastId).firstMatch.frame.midY,
                          restored.matching(identifier: firstId).firstMatch.frame.midY)
        XCTAssertNotEqual(firstId, lastId)
    }

    func testPinsShowOnDecksPinnedCardAndPinUnpinFromARecord() {
        let app = launch()
        app.section("Deck")
        app.deckCard("pinned")
        XCTAssertTrue(app.buttons["deck.pinned.design"].waitForExistence(timeout: 15), "seeded channel pin")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck.pinned.'")).count >= 2)
        capture(app, "pins-deck")

        app.section("Tasks")
        let task = app.buttons["task.Review the native inbox"].firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 15))
        task.tap()
        capture(app, "batch-record-toolbar")
        print("TOOLBAR_DIAGNOSTIC \(app.navigationBars.debugDescription)")
        let pin = app.buttons["pin.toggle"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 10))
        XCTAssertEqual(pin.label, "Pin")
        let controls = ["search", "notifications.open", "pin.toggle", "browser.open", "settings"].map { app.buttons[$0].firstMatch }
        for control in controls { XCTAssertTrue(control.isHittable, "ordered toolbar control is visible") }
        for index in 1..<controls.count { XCTAssertLessThan(controls[index - 1].frame.midX, controls[index].frame.midX) }
        pin.tap()
        XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 10), "shows the pin at once")
        back(app)
        app.section("Deck")
        XCTAssertTrue(app.buttons["deck.pinned.Review the native inbox"].waitForExistence(timeout: 15), "the pin reaches Deck")
        capture(app, "pins-added")
        // A channel pin opens Chat in that channel.
        app.buttons["deck.pinned.design"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["#design"].waitForExistence(timeout: 10))
        app.section("Tasks")
        app.buttons["context.home"].firstMatch.tap()   // the channel pin made #design the context
        task.tap()
        XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 10))
        app.buttons["Unpin"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout: 10))
        back(app)
        app.section("Deck")
        let gone = app.buttons["deck.pinned.Review the native inbox"].firstMatch
        let predicate = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: predicate, evaluatedWith: gone)], timeout: 10)

        // Pins survive relaunch (read again through the record-sync feed).
        app.terminate()
        let again = launch(reset: false)
        again.section("Deck")
        again.deckCard("pinned")
        XCTAssertTrue(again.buttons["deck.pinned.design"].waitForExistence(timeout: 15))
    }
}
