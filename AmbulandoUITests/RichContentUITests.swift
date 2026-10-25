import XCTest

/// Markdown and stored images in chat and documents, against the app's labelled local sample data
/// (`-AmbulandoUITestFixture`). The image bytes come through the app's signed storage route from the in-process
/// stand-in; not evidence of live Tower content.
@MainActor
final class RichContentUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
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

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testRichMessageRendersHeadingListCodeTableAndMention() {
        let app = launch()
        app.section("Chat")
        let design = app.buttons["channel.design"]
        XCTAssertTrue(design.waitForExistence(timeout: 15))
        design.tap()
        XCTAssertTrue(app.staticTexts["Build checklist"].waitForExistence(timeout: 10), "the heading renders as text, not '## Build checklist'")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '## Build'")).firstMatch.exists)
        XCTAssertTrue(element(app, "rich.code").waitForExistence(timeout: 5), "fenced code renders as a code block")
        XCTAssertEqual(element(app, "rich.code.text").label, "xcodebuild -scheme Ambulando test", "code is readable by VoiceOver")
        let table = element(app, "rich.table")
        XCTAssertTrue(table.exists, "pipe table renders as a table")
        XCTAssertTrue(table.label.contains("Surface, State. Chat, Markdown"), table.label)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '@Ana'")).firstMatch.exists, "mention shows as a name")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'mention:person'")).firstMatch.exists, "no raw tokens")
        XCTAssertTrue(app.buttons["Copy code"].exists)
        capture(app, "rich-chat-message")
    }

    func testMarkdownDocumentLoadsStoredImage() {
        let app = launch()
        app.section("Docs")
        let doc = app.buttons["doc.Release board (Markdown)"]
        XCTAssertTrue(doc.waitForExistence(timeout: 15))
        doc.tap()
        XCTAssertTrue(app.staticTexts["Release board"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "image.loaded").waitForExistence(timeout: 15), "the stored image downloads and decodes")
        XCTAssertTrue(element(app, "rich.table").exists)
        capture(app, "rich-doc-image")
    }
}
