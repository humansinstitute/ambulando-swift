import XCTest

/// Grandparent Chat against the app's sample Tower (`-AmbulandoUITestFixture` semantics of the Test build). The real
/// identity vault, store, sync engine, binding and outbox run; only Tower is an in-process stand-in. These tests are not
/// evidence of live Tower behaviour.
@MainActor
final class GrandparentChatUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(reset: Bool, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-AmbulandoFixtureReset"] : []) + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.banner"].waitForExistence(timeout: 20), "sample data is labelled")
        return app
    }

    /// Workspace → #general → the seeded "Native chat review" conversation.
    private func chooseFamilyConversation(_ app: XCUIApplication) {
        let studio = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'family.workspace.'")).element(boundBy: 0)
        XCTAssertTrue(studio.waitForExistence(timeout: 20), "setup lists the account's spaces")
        XCTAssertTrue(app.staticTexts["Where does your family chat live?"].exists)
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Studio (sample)'")).firstMatch.tap()
        shot(app, "setup-1-space")
        let general = app.buttons.matching(NSPredicate(format: "label CONTAINS 'general'")).firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 30), "channels of the chosen space")
        general.tap()
        shot(app, "setup-2-channel")
        let conversation = app.buttons.matching(NSPredicate(format: "label CONTAINS '#39'")).firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 30), "existing conversations are listed for explicit choice")
        shot(app, "setup-3-conversation")
        conversation.tap()
        XCTAssertTrue(app.otherElements["family.conversation"].waitForExistence(timeout: 20))
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        let f = app.textFields["family.field"].exists ? app.textFields["family.field"] : app.textViews["family.field"]
        XCTAssertTrue(f.waitForExistence(timeout: 15))
        return f
    }

    func testSetupBindsOneConversationAndRestartRestoresIt() {
        let app = launch(reset: true)
        chooseFamilyConversation(app)
        _ = app.staticTexts["Ship it"].waitForExistence(timeout: 20)
        shot(app, "conversation-loaded")
        XCTAssertTrue(app.staticTexts["Ship it"].exists, "replies of the bound conversation are shown")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no Ambulando navigation")
        XCTAssertFalse(app.buttons["section.chat"].exists)
        shot(app, "conversation")
        app.terminate()

        let relaunched = launch(reset: false)
        XCTAssertTrue(relaunched.otherElements["family.conversation"].waitForExistence(timeout: 30), "relaunch returns straight to the conversation")
        XCTAssertFalse(relaunched.otherElements["family.setup"].exists)
        XCTAssertTrue(relaunched.staticTexts["Ship it"].waitForExistence(timeout: 20))
        XCTAssertTrue(relaunched.staticTexts["family.title"].label.contains("#39"), "the same conversation, not another one")
    }

    func testSendRoundTripAndDraftSurvivesRelaunch() {
        let app = launch(reset: true)
        chooseFamilyConversation(app)
        let composer = field(app)
        composer.tap()
        composer.typeText("Hello from Grandma")
        Thread.sleep(forTimeInterval: 1)   // drafts are written a third of a second after the last keystroke
        app.terminate()
        let again = launch(reset: false)
        let restored = field(again)
        XCTAssertEqual((restored.value as? String) ?? "", "Hello from Grandma", "the draft survives a relaunch")
        again.buttons["family.send"].tap()
        XCTAssertTrue(again.staticTexts["Hello from Grandma"].waitForExistence(timeout: 20), "the sent message appears in the conversation")
        XCTAssertTrue(again.otherElements["outbox.row"].waitForNonExistence(timeout: 20), "delivered")
    }

    func testOfflineMessageIsKeptAndSentWhenOnline() {
        let first = launch(reset: true)
        chooseFamilyConversation(first)
        first.terminate()
        let offline = launch(reset: false, ["-AmbulandoFixtureOffline"])
        XCTAssertTrue(offline.otherElements["family.conversation"].waitForExistence(timeout: 30))
        let composer = field(offline)
        composer.tap()
        composer.typeText("Written offline")
        offline.buttons["family.send"].tap()
        XCTAssertTrue(offline.otherElements["outbox.row"].waitForExistence(timeout: 20), "the message waits in the outbox")
        shot(offline, "offline")
        offline.terminate()
        let relaunchedOffline = launch(reset: false, ["-AmbulandoFixtureOffline"])
        XCTAssertTrue(relaunchedOffline.otherElements["outbox.row"].waitForExistence(timeout: 30), "unsent message survives relaunch")
        relaunchedOffline.terminate()
        let online = launch(reset: false)
        XCTAssertTrue(online.otherElements["outbox.row"].waitForNonExistence(timeout: 40), "sent after reconnect")
        XCTAssertTrue(online.staticTexts["Written offline"].waitForExistence(timeout: 10))
    }

    func testSettingsOffersAccountAndDeliberateChange() {
        let app = launch(reset: true)
        chooseFamilyConversation(app)
        app.buttons["family.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        shot(app, "settings")
        app.swipeUp()
        shot(app, "settings-bottom")
        XCTAssertTrue(app.buttons["family.settings.signout"].waitForExistence(timeout: 5))
        app.buttons["family.settings.change"].tap()
        app.buttons["Choose again"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["family.setup"].firstMatch.waitForExistence(timeout: 15), "change returns to setup")
    }

    /// Largest text, the on-screen keyboard and (on iPad) both orientations, for review screenshots.
    func testLargestTextWithKeyboardAndOrientations() {
        let app = launch(reset: true, ["-family.textSize", "largest"])
        chooseFamilyConversation(app)
        _ = app.staticTexts["Ship it"].waitForExistence(timeout: 20)
        shot(app, "largest-text-conversation")
        let composer = field(app)
        composer.tap()
        composer.typeText("Dear everyone, the photos from Sunday are lovely. See you all soon.")
        shot(app, "largest-text-keyboard")
        XCTAssertTrue(app.buttons["family.send"].isHittable, "Send stays reachable above the keyboard at the largest text size")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 1)
            shot(app, "ipad-landscape-keyboard")
            XCTAssertTrue(app.buttons["family.send"].isHittable)
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func testStandardTextScreens() {
        let app = launch(reset: true)
        chooseFamilyConversation(app)
        _ = app.staticTexts["Ship it"].waitForExistence(timeout: 20)
        shot(app, "standard-conversation")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 1)
            shot(app, "ipad-landscape-conversation")
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// Setup offers existing conversations only: there is no create-conversation action anywhere in the flow.
    func testSetupOffersNoCreateAction() {
        let app = launch(reset: true)
        chooseFamilyConversation(app)
        app.buttons["family.settings"].tap()
        app.swipeUp()
        app.buttons["family.settings.change"].tap()
        app.buttons["Choose again"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["family.setup"].firstMatch.waitForExistence(timeout: 15))
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Studio (sample)'")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'general'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["family.setup.reload"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["family.setup.new"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'new family conversation' OR label CONTAINS[c] 'start a new'")).count, 0)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        // Capture the device canvas so rotated iPad windows are not cropped to a stale app snapshot frame.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
