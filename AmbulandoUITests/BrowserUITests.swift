import XCTest

/// Build 12 browser on local sample data (`-AmbulandoUITestFixture`): the explicit browser entry, `window.nostr` on a
/// sample page served from memory (no network), the connect and signing sheets naming the site, a second signature
/// asking again, and the Ambulando return keeping the open channel, its composer draft and the tab.
@MainActor
final class BrowserUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func webText(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    func testBrowserSignsOnlyWithApprovalAndReturnsToTheSameDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-appearance", "light", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15))

        // A draft in #general that must survive the trip to the browser.
        let general = app.buttons["channel.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 15))
        general.tap()
        let field = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Draft kept while browsing")

        // Explicit entry: a new tab with the address field.
        let open = app.buttons["browser.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.otherElements["browser.start"].waitForExistence(timeout: 10) || app.staticTexts["Enter an address above"].exists)
        let address = app.textFields["browser.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("browser.sample.invalid\n")
        XCTAssertTrue(webText(app, "window.nostr: ready").waitForExistence(timeout: 15), "window.nostr is injected on HTTPS pages")

        // getPublicKey asks first, naming the site.
        app.webViews.buttons["Connect"].tap()
        let allow = app.buttons["nostr.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["browser.sample.invalid"].exists || app.descendants(matching: .any)["nostr.origin"].label.contains("browser.sample.invalid"))
        capture(app, "browser-connect-sheet")
        allow.tap()
        XCTAssertTrue(webText(app, "pubkey ").waitForExistence(timeout: 10))

        // signEvent shows what is signed; approving returns a signed event to the page.
        app.webViews.buttons["Sign note"].tap()
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Sign with Nostr"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hello from the sample page")).firstMatch.exists)
        capture(app, "browser-sign-sheet")
        allow.tap()
        XCTAssertTrue(webText(app, "signed 1 sig ok").waitForExistence(timeout: 10))

        // No blanket approval: the next signature asks again; rejecting fails the page's request.
        app.webViews.buttons["Sign note"].tap()
        let deny = app.buttons["nostr.deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 10), "every ordinary signature asks")
        deny.tap()
        XCTAssertTrue(webText(app, "error The user rejected the request.").waitForExistence(timeout: 10))

        // Back to Ambulando: same channel, same draft, and the tab is still open.
        app.buttons["browser.return"].tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
        XCTAssertTrue((field.value as? String ?? "").contains("Draft kept while browsing"), "composer draft kept")
        XCTAssertEqual(app.buttons["browser.open"].firstMatch.label, "Browser, 1 open tab")
        capture(app, "browser-returned-draft")

        // Returning to the browser finds the same page; the tab switcher leads back to Ambulando too.
        app.buttons["browser.open"].firstMatch.tap()
        XCTAssertTrue(webText(app, "error The user rejected the request.").waitForExistence(timeout: 10), "the page was kept")
        app.buttons["browser.tabs"].tap()
        let home = app.buttons["browser.tabs.ambulando"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        XCTAssertTrue(app.navigationBars["#general"].waitForExistence(timeout: 10))
    }

    /// Deck → Hello and Links → Apps opens the WApp as a browser tab with `window.nostr`; **Ambulando** returns to the
    /// same Deck card, and launching the app again shows its existing tab rather than a new one.
    func testDeckAppLaunchesInTheSignedBrowserAndReturnsToTheDeckCard() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-appearance", "light", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].waitForExistence(timeout: 15))
        app.section("Deck")
        app.deckCard("hello")
        let launcher = app.buttons["deck.app.Sample Artifacts"].firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 15), "the WApp is listed under Apps")
        XCTAssertFalse(app.buttons["deck.app.Legacy tool"].exists, "a WApp without HTTPS is not offered")
        launcher.tap()

        // The browser, not the sandboxed labelled view: the page gets window.nostr and signing asks first.
        XCTAssertTrue(app.buttons["browser.return"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["web.label"].exists)
        XCTAssertTrue(webText(app, "window.nostr: ready").waitForExistence(timeout: 15), "window.nostr is available to the WApp")
        app.webViews.buttons["Connect"].tap()
        let allow = app.buttons["nostr.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "the WApp asks before it sees the key")
        allow.tap()
        XCTAssertTrue(webText(app, "pubkey ").waitForExistence(timeout: 10))
        capture(app, "deck-app-browser")

        // Back to Ambulando: the same Deck card, with the tab still open.
        app.buttons["browser.return"].tap()
        XCTAssertTrue(launcher.waitForExistence(timeout: 10), "returns to Hello and Links")
        XCTAssertTrue(app.buttons["section.deck"].isSelected && launcher.isHittable, "the Deck section and card are kept")
        XCTAssertEqual(app.buttons["browser.open"].firstMatch.label, "Browser, 1 open tab")
        capture(app, "deck-app-returned")

        // Launching it again shows the same tab and page.
        launcher.tap()
        XCTAssertTrue(webText(app, "pubkey ").waitForExistence(timeout: 10), "the existing tab is shown again")
        XCTAssertEqual(app.buttons["browser.tabs"].label, "1 open tab")
        app.buttons["browser.return"].tap()
        XCTAssertTrue(launcher.waitForExistence(timeout: 10))
    }
}
