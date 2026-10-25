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

    /// Scrolls the current list until `element` exists (rows of lazy lists below the fold are not in the tree).
    @MainActor func scrollTo(_ element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        if element.waitForExistence(timeout: 10) { return true }
        for _ in 0..<maxSwipes {
            swipeUp()
            if element.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    /// Opens a section from the bottom bar (Deck, Chat, Tasks, Docs, Files, Agents, Context, Toolbox).
    @MainActor func section(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = buttons["section.\(name.lowercased())"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "section \(name) in the bar", file: file, line: line)
        button.tap()
    }

    /// Shows one of Deck's cards with its dot (Deck must be open).
    @MainActor func deckCard(_ card: String, file: StaticString = #filePath, line: UInt = #line) {
        let dot = buttons["deck.page.\(card)"].firstMatch
        XCTAssertTrue(dot.waitForExistence(timeout: 10), "Deck card \(card)", file: file, line: line)
        dot.tap()
    }

    /// Chooses a channel in the sidebar. As on the web, Deck then opens for it (unless the current Chat, Tasks, Docs or
    /// Files view is locked); every section reads inside the chosen channel.
    @MainActor func selectSidebarChannel(_ name: String) {
        openSidebar()
        let row = buttons["sidebar.channel.\(name)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }
}
