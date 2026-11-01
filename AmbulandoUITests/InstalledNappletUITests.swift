import XCTest

/// Real WKWebView + opaque iframe bridge, signed production sync/HTTP path against an isolated synthetic Tower.
@MainActor
final class InstalledNappletUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testInstalledRegisterSavesReopensAndExplicitRefreshDiscardsOnlyUnsavedDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
        app.section("Toolbox")
        let launcher = app.buttons["napplet.project_register"].firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 20))
        launcher.tap()
        let note = app.webViews.textViews["Project note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts["Authorized r1"].waitForExistence(timeout: 10))
        note.tap(); note.typeText("Saved phone fixture")
        let save = app.webViews.buttons["Save note"]
        save.tap()
        XCTAssertTrue(app.webViews.staticTexts["Authorized r2"].waitForExistence(timeout: 15))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(launcher.waitForExistence(timeout: 10)); launcher.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        XCTAssertEqual(note.value as? String, "Saved phone fixture")
        note.tap(); note.typeText(" unsaved")
        let unsaved = note.value as? String
        XCTAssertTrue(unsaved?.contains("unsaved") == true)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        XCTAssertTrue(note.exists, "interactive Back must not discard a dirty document")
        XCTAssertEqual(note.value as? String, unsaved)
        app.buttons["Refresh"].firstMatch.tap()
        // iOS may use its system Cancel title for the cancel role in a confirmation dialog.
        XCTAssertTrue(app.buttons["Discard changes"].waitForExistence(timeout: 5))
        let keep = app.buttons.matching(NSPredicate(format: "label IN %@", ["Keep editing", "Cancel"])).firstMatch
        if keep.exists { keep.tap() }
        else {
            // Popover presentations cancel by tapping their system-owned outside dismissal region.
            let outside = app.otherElements["PopoverDismissRegion"].firstMatch
            XCTAssertTrue(outside.exists, app.debugDescription); outside.tap()
        }
        XCTAssertEqual(note.value as? String, unsaved)
        app.buttons["Refresh"].firstMatch.tap(); app.buttons["Discard changes"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Authorized r2"].waitForExistence(timeout: 15))
        XCTAssertEqual(note.value as? String, "Saved phone fixture", "confirmed explicit refresh remounts and discards the draft")
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "installed-register-saved-reopened"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["Close"].firstMatch.tap()
        app.section("Deck"); app.deckCard("hello")
        XCTAssertTrue(app.buttons["deck.napplet.project_register"].firstMatch.waitForExistence(timeout: 15))
    }
    func testDeniedSnapshotDestroysTheLiveDocumentAndClearsLauncher() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20))
        app.section("Toolbox")
        let launcher = app.buttons["napplet.project_register"].firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 20)); launcher.tap()
        let note = app.webViews.textViews["Project note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap(); note.typeText("fixture revoke")
        app.webViews.buttons["Save note"].tap()
        XCTAssertTrue(app.staticTexts["Napplet unavailable"].waitForExistence(timeout: 15))
        XCTAssertFalse(note.exists, "access loss destroys the populated browsing context")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertFalse(launcher.waitForExistence(timeout: 3), "a failed snapshot clears installed launcher authority")
    }

    func testConflictReauthorizesAndRetainsTheOriginalUnsavedNoteUntilDiscard() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20)); app.section("Toolbox")
        let launcher = app.buttons["napplet.project_register"].firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 20)); launcher.tap()
        let note = app.webViews.textViews["Project note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap(); note.typeText("fixture conflict"); app.webViews.buttons["Save note"].tap()
        let conflict = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS 'HTTP 409'")).firstMatch
        XCTAssertTrue(conflict.waitForExistence(timeout: 15))
        XCTAssertEqual(note.value as? String, "fixture conflict")
        XCTAssertTrue(app.webViews.buttons["Save note"].isEnabled, "unchanged-authority conflict retains editable draft")
        app.webViews.buttons["Save note"].tap()
        XCTAssertTrue(conflict.waitForExistence(timeout: 15), "retry retains the original stale revision rather than overwriting")
        XCTAssertEqual(note.value as? String, "fixture conflict")
        app.buttons["Refresh"].firstMatch.tap(); app.buttons["Discard changes"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Authorized r2"].waitForExistence(timeout: 15))
        XCTAssertEqual(note.value as? String, "")
    }

    func testNarrowedFieldsDestroyTheOldDocumentAndCreateANewSession() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20)); app.section("Toolbox")
        let launcher = app.buttons["napplet.project_register"].firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 20)); launcher.tap()
        let note = app.webViews.textViews["Project note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        let session = app.webViews.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Session '")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5)); let before = session.label
        note.tap(); note.typeText("fixture narrow"); app.webViews.buttons["Save note"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Authorized r2"].waitForExistence(timeout: 15))
        XCTAssertNotEqual(session.label, before, "changed field/read authority destroys the prior browsing context")
        XCTAssertEqual(note.value as? String, "", "a field no longer projected cannot survive in the document")
        XCTAssertFalse(app.webViews.buttons["Save note"].isEnabled)
    }

    func testPersonalWappAndCanvasHtmlKeepTheirSeparateLaunchAndSandboxPaths() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"]
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 20)); app.section("Toolbox")
        let wapp = app.buttons["wapp.Timesheets"].firstMatch
        XCTAssertTrue(wapp.waitForExistence(timeout: 15)); wapp.tap()
        let back = app.buttons["browser.return"]
        XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
        XCTAssertTrue(wapp.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["napplet.project_register"].exists, "separate installed launcher is still present")
        app.section("Deck"); app.deckCard("canvas")
        let canvas = app.buttons["canvas.Launch board"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15)); canvas.tap()
        XCTAssertTrue(app.buttons["canvas.items"].waitForExistence(timeout: 15)); app.buttons["canvas.items"].tap()
        let html = app.buttons["canvas.item.Status page"].firstMatch
        XCTAssertTrue(html.waitForExistence(timeout: 10)); html.tap()
        XCTAssertTrue(app.webViews.staticTexts["All green."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.staticTexts["Sandbox nostr: undefined"].exists)
    }

}
