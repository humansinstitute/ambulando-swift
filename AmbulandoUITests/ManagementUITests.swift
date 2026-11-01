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
        XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout: 15) || app.buttons["channel.deploys"].exists)
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

    /// Starts in the normal channel directory; no sidebar settings shortcut or direct sheet launch.
    func testPersonalChannelMuteSavesWithoutManageAccessAndReloads() {
        verifyChannelOptionsRoundTrip(admin: false)
    }

    func testAdminChannelOptionsPreserveManagementAndPersonalMute() {
        verifyChannelOptionsRoundTrip(admin: true)
    }

    func testChannelOptionsAtAccessibilityTextSize() {
        verifyChannelOptionsRoundTrip(admin: false, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"])
    }

    private func verifyChannelOptionsRoundTrip(admin: Bool, extra: [String] = []) {
        let app = launch((admin ? ["-AmbulandoFixtureAdmin"] : ["-AmbulandoFixtureReader"]) + extra)
        // Start on ordinary Deck, then choose the channel through its existing navigation.
        // Operations/deploys is a reader channel; general is manageable by the fixture admin.
        app.section("deck")
        app.selectSidebarChannel(admin ? "general" : "deploys")
        app.deckCard("inbox")
        XCTAssertFalse(app.buttons["channel.options"].exists, "No standalone Channel options row")
        let title = app.staticTexts.matching(NSPredicate(format: "identifier == 'deck.card.title' AND label BEGINSWITH 'Inbox'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(title.frame.height, 0)
        let menu = app.buttons["deck.inbox.readMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertTrue(menu.isHittable)
        XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
        XCTAssertTrue(app.buttons["deck.inbox.new"].exists, "Existing create action remains")
        capture(app, "inbox-without-extra-row")
        openInboxOptions(app)
        let toggle = app.switches["channelSettings.mentionsOnly"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "personal choice is available without Manage access")
        XCTAssertTrue(toggle.isEnabled)
        if admin {
            XCTAssertTrue(app.textFields["channelSettings.name"].exists, "authorized actions remain available")
        } else if extra.isEmpty {
            // The normal-size reader case checks authorization. At accessibility sizes this lazy Form's explanatory
            // management row is below the fold; keep that case focused on the visible personal control and tap path.
            XCTAssertTrue(app.staticTexts["channelSettings.readOnly"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.textFields["channelSettings.name"].exists, "personal mute grants no channel management rights")
        }
        XCTAssertEqual(toggle.value as? String, "0")
        setMute(toggle, on: true)
        capture(app, "channel-notifications-mentions-only")
        app.buttons["Close"].firstMatch.tap()
        openInboxOptions(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1", "reopening reads the saved Tower choice")
        setMute(toggle, on: false)
        app.buttons["Close"].firstMatch.tap()
        openInboxOptions(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0", "unmute also survives reopening")
        app.buttons["Close"].firstMatch.tap()
    }

    private func openInboxOptions(_ app: XCUIApplication) {
        app.buttons["deck.inbox.readMenu"].firstMatch.tap()
        for title in ["Mark all tasks as read", "Mark all docs as read", "Mark all chats as read", "Mark everything as read"] {
            XCTAssertTrue(app.buttons[title].exists, "Existing Inbox action remains: \(title)")
        }
        let options = app.buttons["channel.options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
    }

    func testInboxExistingReadAndCreateActionsRemainUsable() {
        let app = launch()
        app.selectSidebarChannel("general")
        app.deckCard("inbox")
        let menu = app.buttons["deck.inbox.readMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        app.buttons["Mark all tasks as read"].tap()
        let notice = app.descendants(matching: .any)["deck.inbox.notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(notice.label.contains("tasks") && (notice.label.contains("read") || notice.label.contains("unread")))
        app.buttons["deck.inbox.new"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New thread"].waitForExistence(timeout: 10))
        app.buttons["deck.compose.cancel"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
    }

    private func setMute(_ toggle: XCUIElement, on: Bool) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let saved = NSPredicate(format: "value == %@ AND enabled == true", on ? "1" : "0")
        expectation(for: saved, evaluatedWith: toggle)
        waitForExpectations(timeout: 15)
    }

    func testLinkedChannelHasItsOwnVisibleOptions() {
        let app = launch(["-AmbulandoFixtureReader", "-AmbulandoFixtureChannelLink"])
        app.buttons["channel.general"].tap()
        let link = app.links.matching(NSPredicate(format: "label CONTAINS 'design'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        app.section("deck")
        app.deckCard("inbox")
        openInboxOptions(app)
        let toggle = app.switches["channelSettings.mentionsOnly"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        setMute(toggle, on: true)
        app.buttons["Close"].firstMatch.tap()
        openInboxOptions(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        setMute(toggle, on: false)
    }

    func testWorkspaceSwitchDoesNotDisplayPreviousChoiceOnUnsupportedTower() {
        let app = launch(["-AmbulandoFixtureReader"])
        app.buttons["channel.general"].tap()
        app.section("deck"); app.deckCard("inbox"); openInboxOptions(app)
        let toggle = app.switches["channelSettings.mentionsOnly"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        setMute(toggle, on: true)
        app.buttons["Close"].firstMatch.tap()
        app.openSidebar()
        app.buttons["sidebar.workspace"].firstMatch.tap()
        app.buttons["Choose workspaces…"].tap()
        let lab = app.descendants(matching: .any)["workspace.enabled.Lab (sample)"].firstMatch
        XCTAssertTrue(lab.waitForExistence(timeout: 10)); lab.tap()
        app.buttons["Done"].tap()
        app.buttons["workspace.channel.Lab (sample).notes"].firstMatch.tap()
        app.section("chat")
        app.section("deck"); app.deckCard("inbox"); openInboxOptions(app)
        XCTAssertTrue(app.staticTexts["channelSettings.notificationError"].waitForExistence(timeout: 10))
        XCTAssertFalse(toggle.exists, "Lab's unsupported endpoint must not show Studio's saved value")
        app.buttons["Close"].firstMatch.tap()
        app.openSidebar()
        app.buttons["workspace.channel.Studio (sample).general"].firstMatch.tap()
        app.section("chat")
        app.section("deck"); app.deckCard("inbox"); openInboxOptions(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        setMute(toggle, on: false)
    }

    func testPushedChannelFromContextReferenceHasVisibleOptions() {
        let app = launch(["-AmbulandoFixtureReader", "-AmbulandoFixtureChannelLink", "-sections.context", "YES"])
        app.section("context")
        let scope = app.buttons["context.scope.Ambulando"].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 10)); scope.tap()
        let root = app.buttons["context.node.Native iPhone app"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 10)); root.tap()
        let component = app.buttons["Workspace surfaces"].firstMatch
        XCTAssertTrue(component.waitForExistence(timeout: 10)); component.tap()
        let task = app.buttons["context.reference.Ship build 7 to TestFlight-free phone"].firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 10)); task.tap()
        let link = app.links.matching(NSPredicate(format: "label CONTAINS 'design'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10)); link.tap()
        XCTAssertFalse(app.buttons["channel.options"].exists, "Pushed channel adds no standalone row")
        capture(app, "pushed-channel-without-extra-row")
        app.section("deck"); app.selectSidebarChannel("design"); app.deckCard("inbox"); openInboxOptions(app)
        let toggle = app.switches["channelSettings.mentionsOnly"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        setMute(toggle, on: true)
        app.buttons["Close"].firstMatch.tap()
        openInboxOptions(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        setMute(toggle, on: false)
    }

    func testChannelOptionsDoNotReuseAnotherChannelsChoice() {
        let app = launch()
        app.buttons["channel.deploys"].tap()
        app.section("deck"); app.deckCard("inbox"); openInboxOptions(app)
        let toggle = app.switches["channelSettings.mentionsOnly"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        setMute(toggle, on: true)
        app.buttons["Close"].firstMatch.tap()
        app.section("chat"); app.showChannels()
        app.buttons["channel.general"].tap()
        app.section("deck"); app.deckCard("inbox"); openInboxOptions(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0", "a different channel has its own choice")
        app.buttons["Close"].firstMatch.tap()
        app.section("chat"); app.showChannels()
        app.buttons["channel.deploys"].tap()
        app.section("deck"); app.deckCard("inbox"); openInboxOptions(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1", "returning restores only this channel's saved choice")
        setMute(toggle, on: false)
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
