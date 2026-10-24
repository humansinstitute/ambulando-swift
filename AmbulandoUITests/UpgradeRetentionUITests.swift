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
        // Build 7 surfaces open on the migrated store (schema 4 tables created empty; nothing synced from the invalid origin).
        XCTAssertTrue(app.buttons["sidebar.surface.canvas"].exists && app.buttons["sidebar.surface.context"].exists)
        capture("upgrade-sidebar")
        app.buttons["sidebar.backdrop"].firstMatch.tap()
        app.buttons["settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'https://tower.example.invalid'")).firstMatch
                        .waitForExistence(timeout: 10), "Tower connection kept")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'npub10elfcs4'")).firstMatch.exists, "identity kept")
        XCTAssertTrue(app.buttons["Lock now"].exists, "unlocked by the kept trusted-device session")
        capture("upgrade-settings")
    }
}
