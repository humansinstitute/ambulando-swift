import XCTest

/// Interactive canvas naplets on local sample data (`-AmbulandoUITestFixture`): replying in an embedded conversation,
/// a document's comments and Edit entry, a sandboxed HTML artefact running inline, and a task tree choosing its root,
/// adding a sub task and opening a task. Not evidence of live Tower behaviour.
@MainActor
final class CanvasNapletsUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func select(_ app: XCUIApplication, _ title: String) {
        let header = app.descendants(matching: .any)["naplet.\(title)"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15), "\(title) on the canvas")
        header.tap()
    }

    func testNapletsAreInteractiveOnTheCanvas() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
        app.section("Deck")
        app.deckCard("canvas")
        let canvas = app.buttons["canvas.Launch board"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        canvas.tap()
        XCTAssertTrue(app.descendants(matching: .any)["naplet.Native chat review"].waitForExistence(timeout: 15))
        capture(app, "naplets-board")

        // Conversation: reply from the canvas through the normal composer and outbox.
        select(app, "Native chat review")
        let field = app.descendants(matching: .any)["composer.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "reply composer inside the conversation naplet")
        field.tap()
        field.typeText("Reply from the canvas")
        app.buttons["composer.send"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Reply from the canvas'")).firstMatch.waitForExistence(timeout: 15),
                      "the reply shows in the naplet")
        capture(app, "naplet-chat-replied")
        if app.buttons["composer.hideKeyboard"].exists { app.buttons["composer.hideKeyboard"].tap() }

        // Document: rendered body, comments and Edit entry.
        select(app, "Build 7 launch notes")
        XCTAssertTrue(app.buttons["naplet.doc.edit"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Comments ('")).firstMatch.exists)
        capture(app, "naplet-document")

        // HTML: runs inline in the sandbox, with no signer.
        select(app, "Status page")
        XCTAssertTrue(app.webViews.staticTexts["All green."].waitForExistence(timeout: 15), "artefact runs inline")
        XCTAssertTrue(app.webViews.staticTexts["Sandbox nostr: undefined"].exists, "no window.nostr in the artefact")
        capture(app, "naplet-html")

        // Task tree: choose an existing root, add a sub task, open a task.
        select(app, "Task Tree")
        let existing = app.buttons["tree.existing"].firstMatch
        XCTAssertTrue(existing.waitForExistence(timeout: 10))
        existing.tap()
        let choice = app.buttons["tree.choose.Ship build 7 to TestFlight-free phone"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 15))
        choice.tap()
        XCTAssertTrue(app.buttons["tree.node.Ship build 7 to TestFlight-free phone"].firstMatch.waitForExistence(timeout: 15), "root task in the tree on the canvas")
        capture(app, "naplet-tree-root")
        // Expand: the same tree at full size (phones), where + targets are comfortable.
        app.buttons["Open Task Tree"].firstMatch.tap()
        XCTAssertTrue(app.buttons["naplet.focus.done"].waitForExistence(timeout: 10))
        let root = app.buttons["tree.node.Ship build 7 to TestFlight-free phone"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 15))
        app.buttons["tree.child.Ship build 7 to TestFlight-free phone"].firstMatch.tap()
        let entry = app.textFields["tree.entry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        entry.typeText("Sub task from canvas")
        app.buttons["tree.add"].firstMatch.tap()
        let child = app.buttons["tree.node.Sub task from canvas"].firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 15), "created sub task appears below its parent")
        XCTAssertGreaterThan(child.frame.minY, root.frame.maxY, "children are drawn below")
        capture(app, "naplet-tree-child")
        child.tap()
        XCTAssertTrue(app.staticTexts["Sub task from canvas"].waitForExistence(timeout: 10), "the task opens in the normal task screen")
        capture(app, "naplet-tree-task-opened")
    }
}
