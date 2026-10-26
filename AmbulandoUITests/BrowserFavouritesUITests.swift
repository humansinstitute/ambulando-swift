import XCTest

/// Browser favourites on local sample data (`-AmbulandoUITestFixture`, no network): saving the open page from the
/// menu, the new-tab grid over the Nostr Browser background, editing a favourite's name and icon, adding one by
/// address, arranging the list, keeping them across relaunch, and opening one in the start-page tab. Also the
/// composer keeping Attach photos beside Hide keyboard while typing.
@MainActor
final class BrowserFavouritesUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-appearance", "light"] + (reset ? ["-AmbulandoFixtureReset"] : [])
        app.launch()
        // A relaunch without reset reopens the channel that was open.
        let general = app.buttons["channel.general"], open = app.navigationBars["#general"]
        let deadline = Date().addingTimeInterval(15)
        while !open.exists && !general.exists && Date() < deadline { usleep(250_000) }
        if !open.exists { XCTAssertTrue(general.exists); general.tap() }
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        return app
    }

    private func webText(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    func testSaveEditArrangeKeepAndOpenFavourites() {
        var app = launch(reset: true)
        app.buttons["browser.open"].firstMatch.tap()

        // A new tab with no favourites explains how to add them.
        XCTAssertTrue(any(app, "browser.start").waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "browser.favourites.empty").exists)
        capture(app, "favourites-empty-start")

        // Save the open page from the menu's page actions.
        let address = app.textFields["browser.address"]
        address.tap()
        address.typeText("browser.sample.invalid\n")
        XCTAssertTrue(webText(app, "window.nostr: ready").waitForExistence(timeout: 15))
        app.buttons["browser.menu"].tap()
        let add = app.buttons["Add to Favourites"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        capture(app, "favourites-menu-add")
        add.tap()
        app.buttons["browser.menu"].tap()
        XCTAssertTrue(app.buttons["Remove from Favourites"].waitForExistence(timeout: 5), "the menu knows the page is saved")
        app.buttons["New tab"].tap()

        // The new tab shows it as a tile named after the page.
        let tile = app.buttons["browser.favourite"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertEqual(tile.label, "Sample Nostr app")
        XCTAssertFalse(any(app, "browser.favourites.empty").exists)
        capture(app, "favourites-grid")

        // Edit: a new name and a text icon.
        tile.press(forDuration: 1.0)
        app.buttons["Edit…"].firstMatch.tap()
        let name = app.textFields["favourite.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replace(name, with: "Sample")
        app.textFields["favourite.symbol"].tap()
        app.textFields["favourite.symbol"].typeText("SN")
        XCTAssertTrue(app.staticTexts["Your emoji or text"].exists)
        capture(app, "favourite-editor")
        app.buttons["favourite.save"].tap()
        XCTAssertTrue(app.buttons["Sample"].waitForExistence(timeout: 5))

        // An address that is not HTTPS is refused with the reason; a typed address is added.
        app.buttons["browser.favourites.add"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replace(name, with: "Field Notes")
        let link = app.textFields["favourite.address"]
        link.tap()
        link.typeText("http://fieldnotes.sample.invalid")
        app.buttons["favourite.save"].tap()
        XCTAssertTrue(any(app, "favourite.error").waitForExistence(timeout: 5))
        replace(link, with: "fieldnotes.sample.invalid")
        app.buttons["favourite.save"].tap()
        XCTAssertTrue(app.buttons["Field Notes"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["Sample"].frame.minX, app.buttons["Field Notes"].frame.minX, "added at the end")

        // Arrange: both listed; moving Field Notes earlier from its context menu reorders the grid.
        app.buttons["browser.favourites.edit"].tap()
        XCTAssertTrue(app.buttons["browser.favourites.done"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "browser.favourites.row").count, 2)
        capture(app, "favourites-arrange")
        app.buttons["browser.favourites.done"].tap()
        app.buttons["Field Notes"].press(forDuration: 1.0)
        app.buttons["Move Earlier"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Field Notes"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["Field Notes"].frame.minX, app.buttons["Sample"].frame.minX, "moved earlier")

        // Kept on the device across relaunch.
        app.terminate()
        app = launch(reset: false)
        app.buttons["browser.open"].firstMatch.tap()
        let kept = app.buttons["Sample"]
        XCTAssertTrue(kept.waitForExistence(timeout: 10), "favourites survive relaunch")
        XCTAssertLessThan(app.buttons["Field Notes"].frame.minX, kept.frame.minX, "order survives relaunch")
        capture(app, "favourites-after-relaunch")

        // Opening one loads it in this tab rather than adding a tab.
        let tabs = app.buttons["browser.tabs"].label
        kept.tap()
        XCTAssertTrue(webText(app, "window.nostr: ready").waitForExistence(timeout: 15), "the favourite opened")
        XCTAssertEqual(app.buttons["browser.tabs"].label, tabs)

        // Removing it from the menu takes it off the start page.
        app.buttons["browser.menu"].tap()
        app.buttons["Remove from Favourites"].tap()
        app.buttons["browser.menu"].tap()
        XCTAssertTrue(app.buttons["Add to Favourites"].waitForExistence(timeout: 5))
        app.buttons["New tab"].tap()
        XCTAssertTrue(app.buttons["Field Notes"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Sample"].exists)
    }

    func testAttachPhotosStaysVisibleWhileTyping() {
        let app = launch(reset: true)
        let field = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let photo = app.buttons["composer.photo"].firstMatch
        XCTAssertTrue(photo.exists)
        XCTAssertFalse(app.buttons["composer.hideKeyboard"].exists)
        field.tap()
        field.typeText("Typing with the keyboard up")
        let hide = app.buttons["composer.hideKeyboard"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.exists && photo.isHittable, "Attach photos stays while typing")
        XCTAssertTrue(hide.isHittable)
        XCTAssertLessThan(hide.frame.maxX, photo.frame.minX + 1, "Hide keyboard sits beside it")
        XCTAssertLessThanOrEqual(photo.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "above the keyboard")
        XCTAssertGreaterThan(field.frame.width, 120, "room is left to type")
        capture(app, "composer-typing-photo-and-hide")
        photo.tap()
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS[c] 'photo'")).firstMatch.waitForExistence(timeout: 10)
                      || app.buttons["Cancel"].waitForExistence(timeout: 5), "the photo picker opens mid-sentence")
        capture(app, "composer-photo-picker")
    }
}
