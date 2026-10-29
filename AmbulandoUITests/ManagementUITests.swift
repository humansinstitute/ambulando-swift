import XCTest

/// Scope and channel management from the sidebar on local sample data: the in-process Tower stand-in refuses writes to
/// the Operations scope and its channels (403) as for a member without Manage access, and reports duplicate names and a
/// concurrent scope-order edit as Tower does. Not evidence of live Tower behaviour.
@MainActor
final class ManagementUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoUITestFixture", "-AmbulandoFixtureReset"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
        doneTyping(field)
    }

    private func doneTyping(_ field: XCUIElement) {
        let done = XCUIApplication().buttons["keyboard.done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() }
    }

    /// A management result, found by its text (Form rows may merge the notice's identifier into the row).
    private func status(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testCreateWithExplicitRecipientAndOpenChannelAccessFromSettings() {
        let app = launch(["-AmbulandoFixtureAdmin"])
        app.openSidebar()
        app.buttons["sidebar.addChannel.Ambulando"].firstMatch.tap()
        let picker = app.descendants(matching: .any).matching(identifier: "newChannel.accessRecipient").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let ana = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ana'")).firstMatch
        XCTAssertTrue(ana.waitForExistence(timeout: 5)); ana.tap()
        app.buttons["newChannel.addAccess"].tap()
        XCTAssertTrue(app.staticTexts["Ana"].waitForExistence(timeout: 5))
        let name = app.textFields["newChannel.name"]
        name.tap(); name.typeText("access-review"); doneTyping(name)
        capture(app, "channel-explicit-creation-access")
        app.buttons["newChannel.create"].tap()
        XCTAssertTrue(app.navigationBars["#access-review"].waitForExistence(timeout: 10))
        app.openSidebar()
        app.buttons["sidebar.channelSettings.access-review"].tap()
        let access = app.buttons["channelSettings.access"]
        for _ in 0..<5 where !(access.exists && access.isHittable) { app.swipeUp() }
        XCTAssertTrue(access.waitForExistence(timeout: 5)); access.tap()
        XCTAssertTrue(app.buttons["Grant access"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Scope access"].exists)
        capture(app, "channel-settings-direct-access")
    }

    func testCreateRenamePromptMoveAndArchiveAChannelInAScopeYouManage() {
        let app = launch()
        app.openSidebar()
        let add = app.buttons["sidebar.addChannel.Ambulando"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "+ where you may create channels")
        XCTAssertFalse(app.buttons["sidebar.addChannel.Operations"].exists, "no + where the scope refuses it (can_manage false)")
        capture(app, "manage-sidebar")
        add.tap()
        let name = app.textFields["newChannel.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("ops-review"); doneTyping(name)
        capture(app, "manage-new-channel")
        app.buttons["newChannel.create"].tap()
        XCTAssertTrue(app.navigationBars["#ops-review"].waitForExistence(timeout: 10), "the new channel opens in Chat")

        app.openSidebar()
        XCTAssertTrue(app.buttons["sidebar.channel.ops-review"].waitForExistence(timeout: 10))
        app.buttons["sidebar.channelSettings.ops-review"].tap()
        let rename = app.textFields["channelSettings.name"]
        XCTAssertTrue(rename.waitForExistence(timeout: 10))
        replace(rename, with: "general")
        app.buttons["channelSettings.rename"].tap()
        XCTAssertTrue(status(app, "already exists in this scope").waitForExistence(timeout: 10), "duplicate name refused")
        replace(rename, with: "ops-notes")
        app.buttons["channelSettings.rename"].tap()
        XCTAssertTrue(status(app, "Channel renamed.").waitForExistence(timeout: 10))

        let prompt = app.textViews["channelSettings.prompt"].exists ? app.textViews["channelSettings.prompt"] : app.textFields["channelSettings.prompt"]
        prompt.tap(); prompt.typeText("Summarise ops changes"); doneTyping(prompt)
        app.buttons["channelSettings.savePrompt"].tap()
        XCTAssertTrue(status(app, "Channel context settings saved.").waitForExistence(timeout: 10))

        // The new channel is third of three; move it to position 1.
        let decrement = app.buttons.matching(NSPredicate(format: "label == 'Decrement' OR identifier ENDSWITH 'Decrement'")).firstMatch
        XCTAssertTrue(decrement.waitForExistence(timeout: 5))
        decrement.tap(); decrement.tap()
        XCTAssertTrue(app.buttons["Move to position 1"].exists || app.buttons["channelSettings.move"].label.contains("1"))
        app.buttons["channelSettings.move"].tap()
        XCTAssertTrue(status(app, "Channel order saved.").waitForExistence(timeout: 10))
        capture(app, "manage-channel-settings")
        app.buttons["Close"].tap()
        let notes = app.buttons["sidebar.channel.ops-notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        XCTAssertLessThan(notes.frame.minY, app.buttons["sidebar.channel.general"].firstMatch.frame.minY, "moved to the top of its scope")

        app.buttons["sidebar.channelSettings.ops-notes"].tap()
        let archive = app.buttons["channelSettings.archive"]
        for _ in 0..<5 where !(archive.exists && archive.isHittable) { app.swipeUp() }   // the last row of a lazy form
        archive.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Archive channel'")).element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5) || app.sheets.buttons["Archive channel"].exists)
        (app.sheets.buttons["Archive channel"].exists ? app.sheets.buttons["Archive channel"] : confirm).tap()
        XCTAssertTrue(app.staticTexts["Channel not available"].waitForExistence(timeout: 10) || status(app, "Channel archived.").waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        let gone = app.buttons["sidebar.channel.ops-notes"].firstMatch
        XCTAssertTrue(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: gone)], timeout: 10) == .completed,
                      "the archived channel leaves the sidebar")
    }

    func testRefusalsAreExplainedAndNothingChanges() {
        let app = launch()
        app.openSidebar()
        app.buttons["sidebar.channelSettings.deploys"].tap()
        let rename = app.textFields["channelSettings.name"]
        XCTAssertTrue(rename.waitForExistence(timeout: 10))
        replace(rename, with: "deploys-2")
        app.buttons["channelSettings.rename"].tap()
        XCTAssertTrue(status(app, "You need Manage access on this channel.").waitForExistence(timeout: 10), "the refusal is explained")
        XCTAssertFalse(app.buttons["manage.retry"].exists, "a refusal is not offered as Retry")
        capture(app, "manage-refused")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["sidebar.channel.deploys"].waitForExistence(timeout: 5), "the stored name is unchanged")

        app.buttons["sidebar.manageScopes"].tap()
        let ops = app.buttons["scopes.row.Operations"].firstMatch
        XCTAssertTrue(ops.waitForExistence(timeout: 10))
        XCTAssertTrue(ops.label.contains("View only"), ops.label)
        ops.tap()
        XCTAssertTrue(app.staticTexts["You need Manage access to change this scope."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["scopeEdit.save"].exists)
        XCTAssertFalse(app.buttons["scopeEdit.archive"].exists)
    }

    func testScopeOrderConflictIsReportedThenTheMoveSucceeds() {
        let app = launch(["-AmbulandoFixtureScopeOrderConflict"])
        app.openSidebar()
        XCTAssertLessThan(app.buttons["sidebar.scope.Operations"].frame.minY, app.buttons["sidebar.scope.Ambulando"].frame.minY, "sample order")
        app.buttons["sidebar.manageScopes"].tap()
        let up = app.buttons["Move.Ambulando.up"].firstMatch
        XCTAssertTrue(up.waitForExistence(timeout: 10))
        up.tap()
        XCTAssertTrue(status(app, "changed in another session").waitForExistence(timeout: 10), "the conflict is reported")
        capture(app, "manage-scope-conflict")
        // The other session's order (Ambulando first) is now shown; moving Operations up is a fresh, accepted edit.
        let opsUp = app.buttons["Move.Operations.up"].firstMatch
        XCTAssertTrue(opsUp.waitForExistence(timeout: 10))
        XCTAssertTrue(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: opsUp)], timeout: 10) == .completed)
        opsUp.tap()
        XCTAssertTrue(status(app, "Personal scope order saved.").waitForExistence(timeout: 10))

        // New scope (sample identity has scope.create).
        app.buttons["scopes.new"].tap()
        let name = app.textFields["scopeEdit.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Field work"); doneTyping(name)
        app.buttons["scopeEdit.save"].tap()
        XCTAssertTrue(app.buttons["scopes.row.Field work"].firstMatch.waitForExistence(timeout: 10), "the new scope is listed")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["sidebar.scope.Field work"].waitForExistence(timeout: 10), "and in the sidebar")
        XCTAssertLessThan(app.buttons["sidebar.scope.Operations"].frame.minY, app.buttons["sidebar.scope.Ambulando"].frame.minY, "the saved order")
    }
}
