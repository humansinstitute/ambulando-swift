import XCTest

/// Real native comment fields against the labelled, isolated sample transport. No real Tower or agent is contacted.
@MainActor
final class CommentMentionUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-appearance", "light"] + (reset ? ["-AmbulandoFixtureReset"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sample data on this'")).firstMatch.waitForExistence(timeout: 15))
        return app
    }

    private func field(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let expected = app.textViews[id]
        if expected.waitForExistence(timeout: 3) { return expected }
        let native = app.textViews["composer.field"].firstMatch
        XCTAssertTrue(native.waitForExistence(timeout: 5)); return native
    }

    private func openTask(_ app: XCUIApplication) {
        app.section("Tasks")
        let task = app.buttons["task.Write release notes for build 3"]
        XCTAssertTrue(task.waitForExistence(timeout: 15)); task.tap()
        let tabs = app.segmentedControls["task.tabs"]
        if tabs.exists { tabs.buttons["Comments"].tap() }
    }

    func testActualTaskCommentPickerTouchSendDraftRelaunch() {
        var app = launch(reset: true)
        openTask(app)
        var input = field(app, "comment.field")
        input.tap(); input.typeText("Before @ric")
        let pick = app.buttons["mention.rick"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "@ric opens picker on the actual task comment field")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "task-comment-ric-picker"; shot.lifetime = .keepAlways; add(shot)
        pick.tap()
        XCTAssertTrue((input.value as? String)?.contains("@[rick](mention:agent:npub1") == true, "visible canonical token retains actual identity")
        XCTAssertFalse(app.descendants(matching: .any)["mention.list"].exists)
        input.typeText("after selection")
        XCTAssertTrue((input.value as? String)?.hasSuffix(" after selection") == true)
        app.buttons["comment.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Before @rick after selection'")).firstMatch.waitForExistence(timeout: 10))
        let tag = app.links.containing(NSPredicate(format: "label CONTAINS 'rick'")).firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 5), "saved tag is clickable")
        tag.tap()
        XCTAssertTrue(app.staticTexts["mention.identity.npub"].waitForExistence(timeout: 5))
        app.buttons["mention.identity.done"].tap()
        input.tap(); input.typeText("Unsent @ric")
        XCTAssertTrue(pick.waitForExistence(timeout: 5)); pick.tap()
        let saved = input.value as? String
        // The content upload/draft host saves in sequence; relaunch must restore the canonical token, not a display-only label.
        sleep(1)
        app.terminate()
        app = launch(reset: false)
        openTask(app)
        input = field(app, "comment.field")
        XCTAssertTrue(NSPredicate(format: "value == %@", saved ?? "").evaluate(with: input) ||
                      XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "value == %@", saved ?? ""), evaluatedWith: input)], timeout: 5) == .completed)
    }

    func testDocumentRootAndReplyUseSameActorPicker() {
        let app = launch(reset: true)
        app.section("Docs")
        let doc = app.buttons["doc.Native app plan"]
        XCTAssertTrue(doc.waitForExistence(timeout: 15)); doc.tap()
        XCTAssertTrue(app.buttons["doc.comments"].waitForExistence(timeout: 15)); app.buttons["doc.comments"].tap()
        var input = field(app, "doccomment.field")
        input.tap(); input.typeText("Document @ric")
        let pick = app.buttons["mention.rick"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5)); pick.tap()
        XCTAssertTrue((input.value as? String)?.contains("@[rick](mention:agent:npub1") == true)
        input.typeText("root")
        app.buttons["doccomment.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Document @rick root'")).firstMatch.waitForExistence(timeout: 10))
        let reply = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'doccomment.reply.'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5)); reply.tap()
        input = field(app, "doccomment.field")
        input.tap(); input.typeText("Reply @ric")
        XCTAssertTrue(pick.waitForExistence(timeout: 5)); pick.tap()
        input.typeText("retained")
        app.buttons["doccomment.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Reply @rick retained'")).firstMatch.waitForExistence(timeout: 10))
    }
    private func avatarApp(reset: Bool, fallback: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoCommentAvatarCheck", "-appearance", "light"]
            + (reset ? ["-AmbulandoFixtureReset"] : []) + (fallback ? ["-AmbulandoCommentAvatarFallback"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sample data on this'")).firstMatch.waitForExistence(timeout: 15))
        app.section("Docs")
        let doc = app.buttons["doc.Native app plan"]
        XCTAssertTrue(doc.waitForExistence(timeout: 15)); doc.tap()
        XCTAssertTrue(app.buttons["doc.comments"].waitForExistence(timeout: 15)); app.buttons["doc.comments"].tap()
        return app
    }

    private func assertPhotos(_ app: XCUIApplication, count: Int) {
        let avatars = app.descendants(matching: .any).matching(identifier: "comment").descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'avatar.' AND label BEGINSWITH 'Sample Explorer •'"))
        XCTAssertTrue(avatars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(avatars.count, count)
        for index in 0..<avatars.count {
            let loaded = NSPredicate(format: "value == 'Profile photo'")
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: loaded, evaluatedWith: avatars.element(boundBy: index))], timeout: 10), .completed)
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "comment-profile-photos"; shot.lifetime = .keepAlways; add(shot)
    }

    func testDocumentCommentPhotosForActorOnlyRootReplyAndReopen() {
        let app = avatarApp(reset: true)
        var input = field(app, "doccomment.field")
        input.tap(); input.typeText("A")
        app.buttons["doccomment.send"].tap()
        assertPhotos(app, count: 1)
        let reply = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'doccomment.reply.'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5)); reply.tap()
        input = field(app, "doccomment.field")
        input.tap(); input.typeText("B")
        app.buttons["doccomment.send"].tap()
        assertPhotos(app, count: 2)
        app.terminate()
        let reopened = avatarApp(reset: false)
        assertPhotos(reopened, count: 2)
    }

    func testBrokenCommentPictureKeepsInitials() {
        let app = avatarApp(reset: true, fallback: true)
        let avatar = app.descendants(matching: .any).matching(identifier: "comment").descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'avatar.' AND label BEGINSWITH 'rick •'")).firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        XCTAssertEqual(avatar.value as? String, "Initials")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "comment-invalid-picture-fallback"; shot.lifetime = .keepAlways; add(shot)
    }

}
