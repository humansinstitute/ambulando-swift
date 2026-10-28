#if DEBUG
import AppKit
import SwiftUI
import AmbulandoCore

/// `-AmbulandoMacWikiLinkCheck` (with `-AmbulandoMacThreadRegression -AmbulandoFixtureWiki` on the isolated Test app): wiki links in
/// the Mac document reader. A stable link shows its page's current title and opens that page; a missing page offers creation in the
/// source channel and, once created, is linked and opened; a title two pages share asks which; code stays literal.
extension MacThreadRegression {
    static func wikiLinks(in object: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 60 else { return [] }
        var found: [NSObject] = []
        if value(object, "AXRole") as? String == "AXLink", let node = object as? NSObject { found.append(node) }
        for child in children(object) { found += wikiLinks(in: child, depth: depth + 1) }
        return found
    }

    static func buttons(in object: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 60 else { return [] }
        var found: [NSObject] = []
        if value(object, "AXRole") as? String == "AXButton", let node = object as? NSObject { found.append(node) }
        for child in children(object) { found += buttons(in: child, depth: depth + 1) }
        return found
    }

    static func press(_ node: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: selector) else { throw Failure(description: "Control cannot press") }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        try require(unsafeBitCast(node.method(for: selector), to: Action.self)(node, selector), "Press failed")
    }

    static func linkLabel(_ node: NSObject) -> String {
        ["AXTitle", "AXValue", "AXDescription"].compactMap { value(node, $0) as? String }.first { !$0.isEmpty } ?? ""
    }

    static func wikiLinkCheck(_ window: NSWindow, model: AppModel) async throws {
        try press(window, "section.docs"); await settle()
        model.openRecord(kind: "doc", id: FixtureTower.wikiHub)
        for _ in 0..<40 where find(window, "doc.body") == nil { await settle() }
        guard let body = find(window, "doc.body") else { throw Failure(description: "The Wiki hub document did not open") }
        await settle()
        let labels = wikiLinks(in: body).map(linkLabel)
        print("WIKI_LINKS \(labels)")
        try require(labels.contains { $0.contains("Wiki target") }, "the stable link shows the page's current title, not the title it was written with")
        try require(!labels.contains { $0.contains("Old target name") }, "the written title is not shown")
        try require(labels.contains { $0.contains("Fresh page") }, "a literal [[Title]] is a link")
        try require(!labels.contains { $0.contains("Literal in code") }, "text in code stays literal")
        guard let workspaceId = model.selectedWorkspace?.id else { throw Failure(description: "no workspace") }

        // A shared title asks which page.
        guard let twin = wikiLinks(in: body).first(where: { linkLabel($0).contains("Twin") }) else { throw Failure(description: "no Twin link") }
        try await performPress(twin) { NSApp.windows.contains(where: { containsText($0, "Several pages are called") }) }
        for _ in 0..<30 where !NSApp.windows.contains(where: { containsText($0, "Several pages are called") }) { await settle() }
        try require(NSApp.windows.contains(where: { containsText($0, "Several pages are called") }), "a shared title asks which page")
        print("WIKI_AMBIGUOUS_PASS")
        // Dismissed the way a person does: the sheet's own Cancel button.
        guard let sheetWindow = window.attachedSheet, let cancel = buttons(in: sheetWindow).first(where: { linkLabel($0) == "Cancel" }) else { throw Failure(description: "no Cancel in the sheet") }
        try press(cancel)
        for _ in 0..<20 where window.attachedSheet != nil { await settle() }
        try require(window.attachedSheet == nil, "Cancel closes the sheet")

        // Open the stable link.
        guard let target = wikiLinks(in: find(window, "doc.body") ?? body).first(where: { linkLabel($0).contains("Wiki target") }) else { throw Failure(description: "no target link") }
        try await performPress(target) { model.docsPath.last == .doc(workspaceId: workspaceId, docId: FixtureTower.wikiTarget) }
        for _ in 0..<30 where model.docsPath.last != .doc(workspaceId: workspaceId, docId: FixtureTower.wikiTarget) { await settle() }
        try require(model.docsPath.last == .doc(workspaceId: workspaceId, docId: FixtureTower.wikiTarget), "the link opened its page by id")
        print("WIKI_OPEN_PASS")
        model.docsPath.removeLast(); await settle(); await settle(); await settle()
        try require(model.docsPath.isEmpty || model.docsPath.last == .doc(workspaceId: workspaceId, docId: FixtureTower.wikiHub), "back on the hub")
        print("WIKI_BACK path=\(model.docsPath.count)")

        // A missing page offers creation, then is created once, linked and opened.
        guard let body3 = find(window, "doc.body"), let missing = wikiLinks(in: body3).first(where: { linkLabel($0).contains("Fresh page") }) else { throw Failure(description: "no Fresh page link") }
        try await performPress(missing) { find(window, "wiki.create.confirm") != nil || window.attachedSheet.flatMap { find($0, "wiki.create.confirm") } != nil }
        for _ in 0..<30 where find(window, "wiki.create.confirm") == nil && (window.attachedSheet.flatMap { find($0, "wiki.create.confirm") } == nil) { await settle() }
        let sheet = window.attachedSheet ?? window
        try require(find(sheet, "wiki.create.confirm") != nil, "a missing page offers to create it")
        print("WIKI_CREATE_OFFER_PASS")
        try press(sheet, "wiki.create.confirm")
        var created: DocRecord?
        for _ in 0..<60 {
            created = try await model.store?.reader.docs(workspaceId: workspaceId, limit: 2000).first { $0.title == "Fresh page" }
            if created != nil, model.docsPath.last == .doc(workspaceId: workspaceId, docId: created!.id) { break }
            await settle()
        }
        guard let page = created else { throw Failure(description: "the page was not created") }
        try require(model.docsPath.last == .doc(workspaceId: workspaceId, docId: page.id), "the created page opened")
        let all = try await model.store?.reader.docs(workspaceId: workspaceId, limit: 2000).filter { $0.title == "Fresh page" }
        try require(all?.count == 1, "exactly one page was created")
        print("WIKI_CREATE_PASS id=\(page.id)")
    }

    /// The paragraph (static text) a link is in, found by its text; SwiftUI reports a link's own frame in text-local space, so
    /// clicks are aimed from the paragraph's frame and the link's position in its text.
    static func paragraph(containing label: String, in root: Any) -> (frame: NSRect, text: String)? {
        func walk(_ object: Any, _ depth: Int) -> (NSRect, String)? {
            guard depth < 12 else { return nil }
            if let node = object as? NSObject, value(node, "AXRole") as? String == "AXStaticText", let text = value(node, "AXValue") as? String, text.contains(label) {
                return (frame(of: node), text)
            }
            for child in children(object) { if let found = walk(child, depth + 1) { return found } }
            return nil
        }
        return walk(root, 0)
    }

    /// A real mouse click on the link (SwiftUI text links do not answer an accessibility press). The mouse is moved onto the
    /// text first, as a person's pointer would, and the click is tried along the link's estimated span until `landed` is true.
    static func performPress(_ node: NSObject, landed: @MainActor () -> Bool = { true }) async throws {
        guard let window = NSApp.windows.first(where: { find($0, "fixture.banner") != nil }) else { throw Failure(description: "no window") }
        let label = linkLabel(node)
        guard let (box, text) = paragraph(containing: label, in: window), let range = text.range(of: label), !box.isEmpty else {
            throw Failure(description: "No paragraph found for link \(label)")
        }
        let start = Double(text.distance(from: text.startIndex, to: range.lowerBound)), length = Double(label.count), total = Double(text.count)
        for spread in [0.0, -0.25, 0.25, -0.4, 0.4] {
            let x = box.minX + box.width * (start + length * (0.5 + spread)) / total
            let point = window.convertPoint(fromScreen: NSPoint(x: x, y: box.midY))
            if let move = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                window.sendEvent(move)
            }
            try? await Task.sleep(for: .milliseconds(200))
            try sendClick(window, point: point)
            print("CLICK link \(label) x=\(Int(x)) paragraph=\(box)"); fflush(stdout)
            try? await Task.sleep(for: .milliseconds(900))
            if landed() { return }
        }
        throw Failure(description: "Clicking the link \(label) had no effect")
    }
}
#endif
