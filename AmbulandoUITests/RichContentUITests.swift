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

    func testPlainAndRichTypographyMatchNativeAtNormalAndAccessibilitySize() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-AmbulandoChatTypographyFixture"]
        app.launch()
        let result = app.staticTexts["typography.result"]
        let passed = NSPredicate(format: "label BEGINSWITH 'PASS '")
        expectation(for: passed, evaluatedWith: result)
        waitForExpectations(timeout: 30)
        capture(app, "matching-typography-normal")
        app.buttons["typography.scale"].tap()
        let enlarged = NSPredicate(format: "label BEGINSWITH 'PASS 40'")
        expectation(for: enlarged, evaluatedWith: result)
        waitForExpectations(timeout: 20)
        capture(app, "matching-typography-accessibility")
    }

    func testRichMessageRendersHeadingListCodeTableAndMention() {
        let app = launch()
        app.section("Chat")
        let design = app.buttons["channel.design"]
        XCTAssertTrue(design.waitForExistence(timeout: 15))
        design.tap()
        XCTAssertTrue(app.staticTexts["Build checklist"].waitForExistence(timeout: 10), "the heading renders as text, not '## Build checklist'")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '## Build'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["xcodebuild -scheme Ambulando test"].firstMatch.waitForExistence(timeout: 5), "code is readable by VoiceOver")
        XCTAssertTrue(app.staticTexts["Surface"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Markdown"].firstMatch.exists)
        XCTAssertTrue(app.links["@Ana"].firstMatch.exists, "mention remains an accessible link")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'mention:person'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Copy code"].exists)
        capture(app, "rich-chat-message")
    }

    func testLongBoldMessageTableClearsMetadataAndFollowingMessage() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-AmbulandoRichMessageLayoutFixture"]
        app.launch()
        let scroll = element(app, "rich.fixture.scroll")
        XCTAssertTrue(scroll.waitForExistence(timeout: 20))
        checkLongMessage(app, scroll: scroll, name: "normal")
        let normalHeight = app.webViews["chat.selection"].firstMatch.frame.height
        app.buttons["rich.fixture.large"].tap()
        XCTAssertEqual(app.buttons["rich.fixture.large"].label, "Use normal text")
        XCTAssertGreaterThan(app.webViews["chat.selection"].firstMatch.frame.height, normalHeight, "larger text increases message height")
        checkLongMessage(app, scroll: scroll, name: "larger-text")
    }

    func testLongMessageTextSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-AmbulandoRichMessageLayoutFixture", "-AmbulandoChatSelectionFixture"]
        app.launch()
        let opening = app.staticTexts["First paragraph for selection."].firstMatch
        XCTAssertTrue(opening.waitForExistence(timeout: 20))
        opening.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 16, dy: 10)).press(forDuration: 1.2)
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        capture(app, "rich-native-selection-handles")
        // The standard-size synthetic first word has a known end-handle position. Extend the native handle
        // across the second paragraph and table header, ending partway through the first data row.
        let handle = opening.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 35, dy: 28))
        let cell = app.staticTexts["600"].firstMatch
        XCTAssertTrue(cell.isHittable)
        handle.press(forDuration: 0.05, thenDragTo: cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        capture(app, "rich-native-cross-block-handles")
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        app.buttons["rich.fixture.clipboard.read"].tap()
        let copied = app.staticTexts["rich.fixture.clipboard.value"].label
        XCTAssertTrue(copied.contains("First paragraph for selection."), copied)
        XCTAssertTrue(copied.contains("Second paragraph before table."), copied)
        XCTAssertTrue(copied.contains("Name\tCount"), copied)
        XCTAssertTrue(copied.contains("Alpha\t"), copied)
        XCTAssertFalse(copied.contains("Final paragraph"), "a partial range, not Copy All")
    }

    private func checkLongMessage(_ app: XCUIApplication, scroll: XCUIElement, name: String) {
        for _ in 0..<6 { scroll.swipeDown(velocity: .fast) }
        let author = app.staticTexts.matching(identifier: "message.author").matching(NSPredicate(format: "label == 'Rick'")).firstMatch
        let opening = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Yes—the workspace documents'")).firstMatch
        XCTAssertTrue(opening.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(opening.frame.minY, author.frame.maxY + 2, "body clears sender metadata")
        let web = app.webViews["chat.selection"].firstMatch
        XCTAssertLessThanOrEqual(web.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThan(web.frame.height, 1000, "full content is measured, not a clipped nested viewport")
        XCTAssertTrue(app.staticTexts["Purpose"].firstMatch.exists)
        XCTAssertTrue(app.links["the reference"].firstMatch.exists)
        capture(app, "rich-dm-\(name)-top")
        let final = app.staticTexts["Final paragraph: the complete message remains reachable."].firstMatch
        // WebKit can report offscreen descendants as hittable. Use the outer viewport's actual geometry.
        func visible(_ item: XCUIElement) -> Bool {
            item.exists && item.frame.minY >= scroll.frame.minY && item.frame.maxY <= scroll.frame.maxY
        }
        for _ in 0..<24 { if visible(final) { break }; scroll.swipeUp() }
        XCTAssertTrue(visible(final), "vertical chat scrolling reaches the end of the rich message")
        let after = app.textViews.matching(NSPredicate(format: "label == 'Following ordinary message.'")).firstMatch
        for _ in 0..<4 { if visible(after) { break }; scroll.swipeUp() }
        XCTAssertTrue(visible(after))
        XCTAssertGreaterThan(after.frame.minY, final.frame.maxY, "following message clears full rich body")
        capture(app, "rich-dm-\(name)-bottom")
    }

    func testMarkdownDocumentLoadsStoredImage() {
        let app = launch()
        app.section("Docs")
        let doc = app.buttons["doc.Release board (Markdown)"]
        XCTAssertTrue(doc.waitForExistence(timeout: 15))
        doc.tap()
        XCTAssertTrue(app.staticTexts["Release board"].waitForExistence(timeout: 10))
        // Documents now open in the shared rich editor, whose stored image is a WebKit image
        // rather than the native reader's image.loaded/rich.table accessibility identifiers.
        let image = app.webViews.images["Palette board"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 15), "stored image is exposed in the document editor")
        XCTAssertGreaterThan(image.frame.width, 100)
        XCTAssertGreaterThan(image.frame.height, 100)
        let surface = app.webViews.staticTexts["Step"].firstMatch
        for _ in 0..<4 { if surface.exists { break }; app.webViews.firstMatch.swipeUp() }
        XCTAssertTrue(surface.exists)
        XCTAssertTrue(app.webViews.staticTexts["Owner"].firstMatch.exists)
        capture(app, "rich-doc-image")
    }
}
