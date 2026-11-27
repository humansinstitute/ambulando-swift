#if DEBUG
import AppKit
import AmbulandoCore

extension MacThreadRegression {
    static func briefingCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", let fixture = model.fixture,
              let sample = fixture.tower.briefing else { throw Failure(description: "Briefing check requires isolated Test fixture") }
        func text(_ id: String) -> String {
            guard let node = find(window, id) else { return "" }
            return (value(node, "AXValue") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (value(node, "AXDescription") as? String) ?? ""
        }
        func wait(_ name: String, _ predicate: () -> Bool) async throws {
            let until = Date().addingTimeInterval(20)
            while !predicate() {
                guard Date() < until else { throw Failure(description: "Timed out waiting for briefing \(name); error=\(text("home.briefing.error"))") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        func enabled(_ id: String) -> Bool {
            guard let node = find(window, id) else { return false }
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            typealias Read = @convention(c) (AnyObject, Selector) -> Bool
            return node.responds(to: selector) && unsafeBitCast(node.method(for: selector), to: Read.self)(node, selector)
        }
        func refresh() async throws {
            try await wait("refresh ready") { enabled("home.briefing.refresh") }
            let previousReads = sample.paths.count
            try press(window, "home.briefing.refresh")
            try await wait("refresh completed") { (fixture.tower.offline ? find(window, "home.briefing.error") != nil : sample.paths.count > previousReads) && enabled("home.briefing.refresh") }
        }
        print("BRIEFING_FIXTURE_DIRECTORY \(fixture.directory.path)"); fflush(stdout)
        window.setContentSize(NSSize(width: 1320, height: 1000)); model.showWorkspaceHome()
        try await wait("published paragraphs") { find(window, "home.briefing.paragraph") != nil }
        try await wait("saved goals preserved") { find(window, "home.goal") != nil && find(window, "home.briefing.fact") != nil }
        try require(text("home.briefing.author").contains("Rick"), "briefing shows verified author")
        try require(text("home.briefing.source").contains("Australia/Perth"), "briefing uses explicit timezone")
        try require(text("home.briefing.coverage").contains("Synthetic"), "coverage caveat visible")
        try require(find(window, "home.briefing.link") != nil, "native source link visible")
        let next = find(window, "home.briefing.next")!
        let enabledSelector = NSSelectorFromString("isAccessibilityEnabled")
        typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
        guard next.responds(to: enabledSelector) else { throw Failure(description: "Next-day control has no enabled state") }
        try require(!unsafeBitCast(next.method(for: enabledSelector), to: Enabled.self)(next, enabledSelector), "history stops at today")
        try press(window, "home.briefing.previous")
        try await wait("history") { !text("home.briefing.day").contains("Today") && find(window, "home.briefing.paragraph") != nil }
        let historicalDay = text("home.briefing.day"), historicalAuthor = text("home.briefing.author")
        sample.missingToday = true; try await refresh()
        try await wait("selected history after refresh") { enabled("home.briefing.refresh") && find(window, "home.briefing.paragraph") != nil }
        try require(text("home.briefing.day") == historicalDay && text("home.briefing.author") == historicalAuthor, "refresh retains historical date and generation time when today is absent")
        try require(find(window, "home.briefing.fact") == nil, "historical writing excludes present-day goal facts")
        try press(window, "home.briefing.next")
        try await wait("today") { text("home.briefing.day").contains("Today") }
        try await refresh()
        try await wait("missing today") { find(window, "home.briefing.stale") != nil && find(window, "home.briefing.paragraph") == nil }
        try press(window, "home.briefing.stale")
        try await wait("latest saved history") { text("home.briefing.day") == historicalDay && find(window, "home.briefing.paragraph") != nil }
        sample.missingToday = false; try await refresh()
        try await wait("history retained after new today") { enabled("home.briefing.refresh") && text("home.briefing.day") == historicalDay }
        try press(window, "home.briefing.next")
        try await wait("restored") { find(window, "home.briefing.paragraph") != nil }
        fixture.tower.offline = true; try await refresh()
        try await wait("cached offline") { find(window, "home.briefing.error") != nil && find(window, "home.briefing.cached") != nil }
        try require(find(window, "home.briefing.paragraph") != nil, "offline keeps explicitly cached verified writing")
        fixture.tower.offline = false; sample.unsafe = true; try await refresh()
        try await wait("access withdrawn") { find(window, "home.briefing.paragraph") == nil && text("home.briefing.error").contains("private access") }
        sample.unsafe = false; try await refresh()
        try await wait("access restored") { find(window, "home.briefing.paragraph") != nil }
        window.setContentSize(NSSize(width: 820, height: 1000))
        try await Task.sleep(for: .milliseconds(500))
        try require(find(window, "home.briefing.paragraph") != nil && find(window, "home.briefing.refresh") != nil, "narrow Home keeps writing and refresh accessible")
        try await wait("narrow refresh settled") { enabled("home.briefing.refresh") && find(window, "home.briefing.cached") == nil }
        // Evidence contains only synthetic fixture prose. The runner supplies an already ignored task-owned path.
        if let path = ProcessInfo.processInfo.environment["AMBULANDO_BRIEFING_CAPTURE"], let view = window.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: path)) }
        }
        model.selectWorkspace(FixtureTower.lab); model.showWorkspaceHome()
        try await wait("other workspace isolation") { model.selectedWorkspace?.id == FixtureTower.lab && find(window, "home.briefing.paragraph") == nil }
        print("PASS briefing: real SwiftUI private reader, author/timezone/coverage/native links, bounded dated history retained across refresh and new-today arrival, missing-today stale link, offline verified cache, unsafe access clears writing, recovery, saved-goal facts preserved, narrow Home, workspace isolation")
    }
}
#endif
