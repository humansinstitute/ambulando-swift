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

    /// Sets a sample-data switch in Settings by its identifier: brings that row into view, taps the row's own switch
    /// control (resolved after scrolling settles, not a screen position a moving list can shift onto a neighbour) and
    /// checks the value.
    @MainActor func setFixtureSwitch(_ id: String, on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let row = switches[id]
        // Settings is a lazy list: rows near the bottom exist only once scrolled to.
        for _ in 0..<6 where !(row.exists && row.isHittable) { swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id) shown", file: file, line: line)
        let want = on ? "1" : "0"
        if row.value as? String != want {
            let control = row.switches.firstMatch
            (control.exists ? control : row).tap()
        }
        XCTAssertEqual(row.value as? String, want, "\(id) set", file: file, line: line)
    }

    /// Chooses a channel in the sidebar; Chat shows its conversation and the other modes filter to it.
    @MainActor func selectSidebarChannel(_ name: String) {
        openSidebar()
        let row = buttons["sidebar.channel.\(name)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }
}
