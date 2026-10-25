import XCTest

/// Release gate, run only on a simulator prepared by the upgrade procedure (docs/work-packages.md): the previous build imported the
/// public NIP-19 test key in normal mode and synthetic connection, selection, open channel, draft and unsent message
/// rows were written to its store. This build is then installed over it. Skipped unless AMBULANDO_UPGRADE_CHECK=1
/// (pass TEST_RUNNER_AMBULANDO_UPGRADE_CHECK=1 to xcodebuild). Never run against a real account.
@MainActor
final class UpgradeRetentionUITests: XCTestCase {
    func testUpgradeKeepsIdentityConnectionSelectionDraftAndUnsentMessage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AMBULANDO_UPGRADE_CHECK"] == "1", "upgrade check not requested")
        let app = XCUIApplication()
        app.launchArguments = ["-AmbulandoNoPublicNetwork"]   // no relay or picture host from a test run
        app.launch()   // normal mode: production store and Keychain, no sample data
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        XCTAssertFalse(app.staticTexts["Sample data on this iPhone. Not connected to a Tower."].exists)
        // The trusted-device session from the previous build resumes: no import, no PIN, no connect screen.
        let channel = app.navigationBars["#upgrade-general"]
        XCTAssertTrue(channel.waitForExistence(timeout: 20), "the open channel from the previous build is restored as the context")
        XCTAssertFalse(app.secureTextFields["nsec1…"].exists, "no import screen")
        capture("upgrade-channel")
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "Draft written in the previous build", "draft kept")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Unsent message from the previous build'")).firstMatch.waitForExistence(timeout: 10),
                      "unsent message kept")
        XCTAssertTrue(app.buttons["context.bar"].label.contains("Upgrade Scope"), app.buttons["context.bar"].label)
        app.openSidebar()
        XCTAssertTrue(app.buttons["sidebar.channel.upgrade-general"].exists)
        XCTAssertTrue(app.buttons["sidebar.workspace"].label.contains("Upgrade Studio"))
        capture("upgrade-sidebar")
        app.buttons["sidebar.backdrop"].firstMatch.tap()
        // Build 9 sections on the migrated store (schema 4 tables created empty; nothing synced from the invalid origin).
        XCTAssertTrue(app.buttons["section.deck"].waitForExistence(timeout: 5) && app.buttons["section.chat"].isSelected
                      && app.buttons["section.toolbox"].exists, "the saved Chat section is restored in the new section bar")
        XCTAssertTrue(app.buttons["section.agents"].exists && app.buttons["section.context"].exists,
                      "Agents and Context, in the sidebar before the upgrade, stay visible as sections")
        app.buttons["settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'https://tower.example.invalid'")).firstMatch
                        .waitForExistence(timeout: 10), "Tower connection kept")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'npub10elfcs4'")).firstMatch.exists, "identity kept")
        XCTAssertTrue(app.buttons["Lock now"].exists, "unlocked by the kept trusted-device session")
        // Build 10: the profile menu works on the migrated store with no profile fetched (npub and initials, no wait).
        let header = app.descendants(matching: .any)["profile.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "profile menu header on the upgraded store")
        XCTAssertTrue(header.label.contains("npub10elfcs4"), header.label)
        capture("upgrade-settings")
    }
}
