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

    func testLongBoldMessageTableClearsMetadataAndFollowingMessage() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-AmbulandoRichMessageLayoutFixture"]
        app.launch()
        let scroll = element(app, "rich.fixture.scroll")
        XCTAssertTrue(scroll.waitForExistence(timeout: 20))
        checkLongMessage(app, scroll: scroll, name: "normal")
        let normalHeight = layoutFrames(app)["paragraph.0"]?.height ?? 0
        app.buttons["rich.fixture.large"].tap()
        XCTAssertEqual(app.buttons["rich.fixture.large"].label, "Use normal text")
        XCTAssertGreaterThan(layoutFrames(app)["paragraph.0"]?.height ?? 0, normalHeight, "larger text actually increases wrapped paragraph height")
        checkLongMessage(app, scroll: scroll, name: "larger-text")
    }

    func testLongMessageTextSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset", "-AmbulandoRichMessageLayoutFixture"]
        app.launch()
        let opening = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Yes—the workspace documents'")).firstMatch
        XCTAssertTrue(opening.waitForExistence(timeout: 20))
        opening.press(forDuration: 1.2)
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5) || app.buttons["Copy"].firstMatch.exists, "native text selection retains Copy")
        capture(app, "rich-dm-native-selection")
    }

    private func checkLongMessage(_ app: XCUIApplication, scroll: XCUIElement, name: String) {
        for _ in 0..<6 { scroll.swipeDown(velocity: .fast) }
        let author = app.staticTexts.matching(identifier: "message.author").matching(NSPredicate(format: "label == 'Rick'")).firstMatch
        let opening = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Yes—the workspace documents'")).firstMatch
        XCTAssertTrue(opening.waitForExistence(timeout: 5))
        capture(app, "rich-dm-\(name)-before-check")
        let before = layoutFrames(app)
        XCTAssertGreaterThanOrEqual(opening.frame.minY, author.frame.maxY + 2, "body clears sender metadata")
        if let metadata = before["metadata"], let paragraph = before["paragraph.0"] {
            XCTAssertGreaterThanOrEqual(paragraph.minY, metadata.maxY + 2)
        } else { XCTFail("Missing metadata/paragraph measurements") }
        if let viewport = before["table.viewport"], let content = before["table.content"] {
            XCTAssertEqual(viewport.height, content.height + 2, accuracy: 2, "viewport includes every table row")
        } else { XCTFail("Missing table content/viewport measurements") }
        XCTAssertLessThan(before["table.cell.0.0"]?.height ?? .infinity, name == "normal" ? 60 : 120, "header retains intrinsic height")
        let table = element(app, "rich.table")
        XCTAssertLessThanOrEqual(table.frame.maxX, app.frame.maxX, "table viewport stays within phone")
        XCTAssertLessThan(table.frame.height, name == "normal" ? 1000 : 2400, "table uses content height rather than expanding every row")
        capture(app, "rich-dm-\(name)-top")
        // Text-size changes preserve the current horizontal position. Return to the leading edge first.
        for _ in 0..<4 {
            if table.frame.minY < scroll.frame.maxY - 80 { break }
            scroll.swipeUp()
        }
        let y = max(scroll.frame.minY + 30, min(table.frame.minY + 30, scroll.frame.maxY - 30))
        let left = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: table.frame.minX + 20, dy: y))
        let right = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: table.frame.maxX - 20, dy: y))
        left.press(forDuration: 0.05, thenDragTo: right)
        let leading = layoutFrames(app)
        right.press(forDuration: 0.05, thenDragTo: left)
        let shifted = layoutFrames(app)
        XCTAssertLessThan(shifted["table.content"]?.minX ?? .infinity, (leading["table.content"]?.minX ?? 0) - 30, "horizontal drag reveals the right column")
        capture(app, "rich-dm-\(name)-table-scrolled")
        let final = app.staticTexts["Final paragraph: the complete message remains reachable."]
        for _ in 0..<18 {
            if final.isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(final.isHittable, "full rich message is reachable")
        let after = app.staticTexts["Following ordinary message."]
        for _ in 0..<4 { if after.isHittable { break }; scroll.swipeUp() }
        XCTAssertTrue(after.isHittable)
        XCTAssertGreaterThan(after.frame.minY, final.frame.maxY, "following message clears full rich body")
        capture(app, "rich-dm-\(name)-bottom")
    }

    private func layoutFrames(_ app: XCUIApplication) -> [String: CGRect] {
        let value = element(app, "rich.fixture.geometry").label
        let evidence = XCTAttachment(string: value)
        evidence.name = "Rich message geometry"
        evidence.lifetime = .keepAlways
        add(evidence)
        var frames: [String: CGRect] = [:]
        for item in value.split(separator: ";") {
            let pair = item.split(separator: "=")
            guard pair.count == 2 else { continue }
            let numbers = pair[1].split(separator: ",").compactMap { Double($0) }
            if numbers.count == 4 { frames[String(pair[0])] = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) }
        }
        return frames
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
