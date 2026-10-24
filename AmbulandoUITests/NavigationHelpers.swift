import XCTest

/// Navigation through the shared Workspace → Scope → Channel context (sidebar drawer and context bar).
extension XCUIApplication {
    /// Returns Chat to the channel list by choosing Home (all scopes) in the context bar.
    @MainActor func showChannels() {
        let home = buttons["context.home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        home.tap()
    }

    @MainActor func openSidebar() {
        let open = buttons["sidebar.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(buttons["sidebar.home"].waitForExistence(timeout: 5), "sidebar opened")
    }

    /// Chooses a channel in the sidebar; Chat shows its conversation and the other modes filter to it.
    @MainActor func selectSidebarChannel(_ name: String) {
        openSidebar()
        let row = buttons["sidebar.channel.\(name)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }
}
