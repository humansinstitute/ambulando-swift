import XCTest

@MainActor
final class DeckComposeUITests: XCTestCase {
    func testPlusOpensComposerImmediatelyAndCancelKeepsDraftThenSendOpensThread() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        app.section("Deck")
        app.deckCard("inbox")
        let plus = app.buttons["deck.inbox.new"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15))
        plus.tap()
        XCTAssertTrue(app.navigationBars["New thread"].waitForExistence(timeout: 5))
        let field = app.textViews["composer.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "composer opens directly without a channel menu or chat detour")
        field.tap(); field.typeText("A new thread from Deck")
        app.buttons["deck.compose.cancel"].tap()
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "A new thread from Deck", "cancel preserves the durable draft")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.buttons["thread.focus.close"].firstMatch.waitForExistence(timeout: 15), "accepted creation opens the new thread")
        XCTAssertTrue(app.staticTexts["A new thread from Deck"].firstMatch.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "deck-created-thread"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["thread.focus.close"].firstMatch.tap()
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "closing returns to the same Deck")
    }
}
