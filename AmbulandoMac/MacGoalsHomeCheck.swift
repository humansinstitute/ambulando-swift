#if DEBUG
import AppKit
import SwiftUI
import AmbulandoCore

/// Home (Ambulando-Next board v3) and the goal form, against the sample Goals space (`-AmbulandoFixtureGoals`). Keys are
/// real AppKit key events through the window's first responder; nothing is set on the form's state directly. At each
/// visual state the check renders the window's own view hierarchy to a bitmap (no screen recording), requires it to hold
/// real content, and emits it as `SNAPSHOT_BASE64`. The description's caret is checked in those pixels: ink at the caret
/// while the field is focused, none at the same place once focus moves away.
extension MacThreadRegression {
    static func goalsHomeCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", let tower = model.fixture?.tower.goals else {
            throw Failure(description: "Goals Home check requires the isolated Test app with -AmbulandoFixtureGoals")
        }
        let capturePause = Double(ProcessInfo.processInfo.environment["AMBULANDO_CAPTURE_PAUSE"] ?? "") ?? 2.5
        func bitmap(_ target: NSWindow) throws -> (NSBitmapImageRep, NSView) {
            guard let view = target.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw Failure(description: "Cannot render window")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            return (rep, view)
        }
        func luminance(_ c: NSColor?) -> CGFloat {
            guard let c = c?.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        let formOnly = ProcessInfo.processInfo.arguments.contains("-AmbulandoMacGoalsFormOnly")
        func capture(_ target: NSWindow, _ name: String) async throws {
            if formOnly { return }
            try await Task.sleep(for: .milliseconds(300))
            let (rep, _) = try bitmap(target)
            // Not blank: many distinct colours and a real share of pixels away from the corner background.
            var colours = Set<Int>(), away = 0, samples = 0
            let background = luminance(rep.colorAt(x: 2, y: 2))
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    colours.insert(Int(c.redComponent * 31) << 10 | Int(c.greenComponent * 31) << 5 | Int(c.blueComponent * 31))
                    if abs(luminance(c) - background) > 0.08 { away += 1 }
                    samples += 1
                }
            }
            let share = samples == 0 ? 0 : Double(away) / Double(samples)
            print("RENDER_STATS \(name) \(rep.pixelsWide)x\(rep.pixelsHigh) colours=\(colours.count) content=\(String(format: "%.3f", share))")
            try require(colours.count >= 24 && share >= 0.01, "\(name) renders real content, not a blank bitmap")
            guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "Cannot encode \(name)") }
            print("SNAPSHOT_BASE64 \(name) \(png.base64EncodedString())"); fflush(stdout)
            try await Task.sleep(for: .seconds(max(0, capturePause - 1.4)))
        }
        /// Pixels at the caret position of `view` that stand out from the empty line just right of it.
        func caretInk(_ target: NSWindow, _ text: NSTextView, at location: Int) throws -> Int {
            let (rep, view) = try bitmap(target)
            let screen = text.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
            let rect = view.convert(target.convertFromScreen(screen), from: nil)
            let sx = CGFloat(rep.pixelsWide) / view.bounds.width, sy = CGFloat(rep.pixelsHigh) / view.bounds.height
            let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
            let x0 = max(0, Int((rect.minX - 1) * sx)), x1 = min(rep.pixelsWide - 1, Int((rect.minX + 2) * sx))
            let y0 = max(0, Int((top + 2) * sy)), y1 = min(rep.pixelsHigh - 1, Int((top + max(rect.height, 8) - 2) * sy))
            guard x1 > x0, y1 > y0 else { return 0 }
            let background = luminance(rep.colorAt(x: min(rep.pixelsWide - 1, x1 + Int(10 * sx)), y: (y0 + y1) / 2))
            var ink = 0
            for y in y0...y1 { for x in x0...x1 where abs(luminance(rep.colorAt(x: x, y: y)) - background) > 0.3 { ink += 1 } }
            return ink
        }
        func wait(_ what: String, seconds: Double = 8, _ condition: () -> Bool) async throws {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < end else { throw Failure(description: "Timed out waiting for \(what)") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        func all(_ object: Any, _ id: String, depth: Int = 0) -> [NSObject] {
            guard depth < 60 else { return [] }
            var out: [NSObject] = []
            if value(object, "AXIdentifier") as? String == id, let node = object as? NSObject { out.append(node) }
            for child in children(object) { out += all(child, id, depth: depth + 1) }
            return out
        }
        func key(_ target: NSWindow, _ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) async throws {
            try postKey(target, key: characters, code: code, modifiers: modifiers)
            try await Task.sleep(for: .milliseconds(250))
        }
        func typeKeys(_ target: NSWindow, _ text: String) async throws {
            for ch in text { try postKey(target, key: String(ch), code: ch == " " ? 49 : 0, modifiers: ch.isUppercase ? .shift : []) }
            try await Task.sleep(for: .milliseconds(400))
        }
        func label(_ node: NSObject) -> String {
            let description = (value(node, "AXDescription") as? String) ?? ""
            return description.isEmpty ? (value(node, "AXValue") as? String) ?? "" : description
        }
        let activeIds = { tower.goalIds(status: .active) }

        // Where the app is before the check touches anything, and whether Goals has asked Tower for anything yet.
        func goalsState(_ tag: String) {
            let goals = model.selectedWorkspace.flatMap { model.goalsModel(for: $0) }
            print("GOALS_STATE \(tag) mode=\(model.mode.rawValue) surface=\(model.deckSurface) homeVisible=\(find(window, "home") != nil) model=\(goals != nil) loaded=\(goals?.loaded ?? false) loading=\(goals?.loading ?? false) error=\(goals?.error ?? "nil") goalRequests=\(tower.requestCount) cards=\(all(window, "home.goal").count) refreshLog=\(goals?.refreshLog ?? []) isCurrent=\(goals.map { model.selectedWorkspaceBoundary == $0.boundary } ?? false)")
            fflush(stdout)
        }
        goalsState("start")
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacGoalsHomeReadyOnly") {
            // Home as the app opened it: no navigation if it is already showing, so a refresh that never started stays visible.
            if find(window, "home") == nil { model.showWorkspaceHome() }
            do { try await wait("Home goals load in place", seconds: 12) { all(window, "home.goal").count == 4 } }
            catch { goalsState("timeout"); throw error }
            goalsState("loaded")
            print("PASS goals home ready: Home loaded its goals without navigating away")
            return
        }
        window.setContentSize(NSSize(width: 1320, height: 900))
        model.showWorkspaceHome()
        if formOnly {
            // Only the form's keys: open it from Home once goals are loaded.
            try await wait("Home goals") { find(window, "home.goals.new") != nil }
        } else {
            do { try await wait("Home goals") { all(window, "home.goal").count == 4 } }
            catch { goalsState("timeout"); throw error }
            try require(model.workspaceHomeSelected && !model.deckDashboardSelected, "globe selects Home, not the Deck section")
            try require(find(window, "deck.card.inbox") == nil && find(window, "deck.desktop") == nil, "Home does not show the Deck dashboard")
            try require(find(window, "home.briefing") != nil && find(window, "home.latest") != nil, "Home shows Daily Briefing and Latest")
            try require(find(window, "home.goals.showAll").map(label) == "Show all 5 goals", "goal area is bounded: three in focus, one peeking, then Show all")
            try await capture(window, "home-wide")
            window.setContentSize(NSSize(width: 820, height: 1000))
            try await Task.sleep(for: .milliseconds(600))
            try require(all(window, "home.goal").count == 4 && find(window, "home.briefing") != nil, "narrow Home keeps the bounded goals and the briefing")
            if let briefing = find(window, "home.briefing") {
                try require(frame(of: briefing).maxY > 0, "briefing is laid out")
            }
            try await capture(window, "home-narrow")
            window.setContentSize(NSSize(width: 1320, height: 900))
            try await Task.sleep(for: .milliseconds(600))
            try press(window, "home.goals.showAll")
            try await wait("all goals shown") { all(window, "home.goal").count == 5 }
            let order = all(window, "home.goal").map(label)
            print("HOME_ORDER \(order)")
            try require(order.count == 5 && order[0].hasPrefix("Ship Ambulando") && order[1].hasPrefix("Run a half marathon") && order[2].hasPrefix("Learn to sail"),
                        "ranked goals first, in focus order")
            try require(order[3].hasPrefix("Read twelve books") && order[3].hasSuffix("Out of focus") && order[4].hasPrefix("Tidy the garden"),
                        "unranked goals after, by target date, marked out of focus")
            try require(!all(window, "home.briefing.fact").isEmpty, "briefing lists facts from saved goals")
            try require((find(window, "home.briefing.source").map(label) ?? "").contains("05:30 daily"), "briefing labels its schedule and keeps saved-goal facts separate")
            try await wait("latest chats") { !all(window, "home.latest.chat").isEmpty }
            try require(all(window, "home.latest.chat").count <= 5, "at most five latest chats")
            try snapshot(window, model: model, name: "home-all-goals")
            try await capture(window, "home-all-goals")

            // Reorder through the card's own action (the same closure as its menu): "Tidy the garden" (unranked, 5th) to top.
            let saves = tower.acceptedSaves
            guard let garden = all(window, "home.goal").first(where: { label($0).hasPrefix("Tidy the garden") }),
                  let toTop = (garden.perform(NSSelectorFromString("accessibilityCustomActions"))?.takeUnretainedValue() as? [NSAccessibilityCustomAction] ?? [])
                    .first(where: { $0.name == "Move to top" }) else {
                throw Failure(description: "Missing Move to top on an out-of-focus goal")
            }
            guard let perform = toTop.handler else { throw Failure(description: "Move to top has no handler") }
            try require(perform(), "Move to top performed")
            try await wait("reordered Home") { all(window, "home.goal").first.map(label)?.hasPrefix("Tidy the garden") == true }
            try require(tower.acceptedSaves == saves + 1, "moving a goal to the top writes only that goal")
            try require(GoalFocus.rank(tower.goal(FixtureTower.uuid(15, "f1c7a0a1"))!) != nil, "moved goal now carries a focus rank")
            print("HOME_ORDER_AFTER \(all(window, "home.goal").map(label))")
            try await capture(window, "home-reordered")

            // The Deck section is still the dashboard.
            try click(window, "section.deck")
            try await wait("Deck dashboard") { find(window, "deck.desktop") != nil }
            try require(model.deckDashboardSelected && !model.workspaceHomeSelected && find(window, "home") == nil, "Deck tab shows the dashboard")
            try click(window, "section.home")
            try await wait("Home again") { find(window, "home") != nil }
            try require(model.workspaceHomeSelected, "globe returns to Home")

            // A goal card opens the existing goal detail on top of Home.
            try press(window, "home.goal")
            try await wait("goal detail") { if case .goal = model.deckPath.last { true } else { false } }
            try await Task.sleep(for: .milliseconds(800))
            try await capture(window, "goal-detail")
            model.popToRoot(.deck)
            try await wait("back to Home") { find(window, "home") != nil }

            // A mention of a goal File (as an agent writes it) opens the goal, not its JSON.
            model.openRecord(kind: "file", id: FixtureTower.uuid(11, "f1c7a0a1"))
            try await wait("goal detail from a file mention", seconds: 10) { find(window, "goal.detail") != nil }
            try require(model.mode == .files, "the mention opened in Files")
            try await capture(window, "goal-from-file-mention")
            // A deleted goal File and a File this identity cannot read never open as a goal.
            for (name, id) in [("deleted", FixtureTower.uuid(16, "f1c7a0a1")), ("unreadable", FixtureTower.uuid(99, "f1c7a0a1"))] {
                model.openRecord(kind: "file", id: id)
                try await Task.sleep(for: .seconds(2.5))
                try require(find(window, "goal.detail") == nil, "a \(name) goal File does not open as a goal")
                print("FILE_MENTION \(name) goal.detail=absent file.name=\(find(window, "file.name") != nil)")
            }
            model.showWorkspaceHome()
            try await wait("Home again") { find(window, "home") != nil }
        }

        // The form: labels above bordered fields, keys as documented in GoalFormSheet.
        let before = activeIds().count
        try press(window, "home.goals.new")
        try await wait("goal form") { window.attachedSheet.map { find($0, "goal.form.name") != nil } ?? false }
        let sheet = window.attachedSheet!
        sheet.makeKey()
        try await Task.sleep(for: .milliseconds(500))
        let description = find(sheet, "goal.form.description") as? NSTextView
        try require(description != nil, "description is a native multiline text view")
        // Name is focused only when the window's field editor is editing the Name text field itself.
        // SwiftUI tags an accessibility proxy, so match the real NSTextField by where that element is on screen.
        let nameNode = find(sheet, "goal.form.name")
        let nameCenter = nameNode.map { frame(of: $0) }.map { NSPoint(x: $0.midX, y: $0.midY) }
        let fields = sheet.contentView.map { textFields(in: $0) } ?? []
        let nameField = nameNode as? NSTextField ?? fields.first { field in
            guard let center = nameCenter, let window = field.window else { return false }
            return field.isEditable && window.convertToScreen(field.convert(field.bounds, to: nil)).contains(center)
        }
        if nameField == nil {
            print("NAME_FIELD_DIAG node=\(nameNode.map { "\(Swift.type(of: $0)) \(frame(of: $0))" } ?? "nil") fields=\(fields.map { f in "\(Swift.type(of: f)) editable=\(f.isEditable) \(f.window.map { w in w.convertToScreen(f.convert(f.bounds, to: nil)) } ?? .zero)" })")
        }
        try require(nameField != nil, "Name is a native text field")
        func nameFocused() -> Bool {
            guard let editor = sheet.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
            return (editor.delegate as? NSTextField) === nameField
        }
        try require(nameFocused(), "focus starts in Name")
        try require((find(sheet, "goal.form.save").map { value($0, "AXEnabled") as? Bool } ?? nil) != true, "Create is disabled while empty")
        try await capture(sheet, "form-empty")

        try await typeKeys(sheet, "Write a short guide")
        try await key(sheet, "\r", 36)
        try require(sheet.firstResponder === description, "Return in Name moves to the description")
        try require(window.attachedSheet === sheet, "Return in Name does not save")
        try await typeKeys(sheet, "First line")
        try await key(sheet, "\r", 36)
        try await typeKeys(sheet, "Second line")
        try require(description!.string == "First line\nSecond line", "Return in the description is a newline")
        // The caret: the focused text view draws its insertion point, in a visible colour, at the end of what was typed.
        let caretColor = description!.insertionPointColor.usingColorSpace(.sRGB)
        try require(description!.shouldDrawInsertionPoint && (caretColor?.alphaComponent ?? 0) > 0.5, "the description shows a visible caret")
        try require(description!.selectedRange() == NSRange(location: (description!.string as NSString).length, length: 0), "caret follows typing")
        print("CARET color=\(caretColor.map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent),\($0.alphaComponent)" } ?? "nil") at=\(description!.selectedRange().location)")
        // The caret blinks: sample its pixels across more than one blink period.
        let caretAt = description!.selectedRange().location
        var inkFocused = 0
        for _ in 0..<10 { inkFocused = max(inkFocused, try caretInk(sheet, description!, at: caretAt)); try await Task.sleep(for: .milliseconds(140)) }
        try require(window.attachedSheet === sheet, "Return in the description does not save")
        try await capture(sheet, "form-typed")

        try await key(sheet, "\u{19}", 48, .shift)
        try require(nameFocused(), "Shift-Tab moves from the description to Name")
        var inkUnfocused = 0
        for _ in 0..<5 { inkUnfocused = max(inkUnfocused, try caretInk(sheet, description!, at: caretAt)); try await Task.sleep(for: .milliseconds(140)) }
        print("CARET_PIXELS focused=\(inkFocused) unfocused=\(inkUnfocused)")
        try require(inkFocused >= 6 && inkUnfocused * 3 < inkFocused, "the caret is drawn in the focused description and gone once focus leaves")

        // Tab order through every field, both directions, with the optional dates unset and then set. Date controls stay
        // enabled so the keyboard always reaches them; checkboxes join the loop only with Full Keyboard Access (macOS rule).
        let fullKeyboard = NSApp.isFullKeyboardAccessEnabled
        print("FULL_KEYBOARD_ACCESS \(fullKeyboard)")
        // What the keyboard is in, as assistive technology sees it: the focused accessibility element, or the nearest
        // ancestor carrying one of the form's identifiers. Name and the description are also confirmed by ownership.
        let formIds = ["goal.form.name": "name", "goal.form.description": "description", "goal.form.start": "startDate",
                       "goal.form.target": "targetDate", "goal.form.start.include": "startInclude", "goal.form.target.include": "targetInclude"]
        func focused() -> String {
            if sheet.firstResponder === description { return "description" }
            if nameFocused() { return "name" }
            var node: Any? = value(NSApp as Any, "AXFocusedUIElement")
            for _ in 0..<8 {
                guard let current = node else { break }
                if let id = value(current, "AXIdentifier") as? String, let name = formIds[id] { return name }
                node = value(current, "AXParent")
            }
            // Otherwise: the first responder view lies inside one of the form controls on screen.
            if let view = sheet.firstResponder as? NSView, let w = view.window {
                let center = w.convertToScreen(view.convert(view.bounds, to: nil))
                for (id, name) in formIds where name != "name" && name != "description" {
                    if let control = find(sheet, id), frame(of: control).insetBy(dx: -2, dy: -2).contains(NSPoint(x: center.midX, y: center.midY)) { return name }
                }
            }
            return "other:\(sheet.firstResponder.map { "\(Swift.type(of: $0))" } ?? "none")"
        }
        func included(_ id: String) -> Bool { (find(sheet, id).flatMap { value($0, "AXValue") as? NSNumber })?.intValue == 1 }
        // A macOS date field takes Tab through its own parts (day, month, year) before leaving, so consecutive stops in
        // the same control count once. Each pass starts at the description and runs until it comes back (at most 16 keys).
        func pass(_ characters: String, _ modifiers: NSEvent.ModifierFlags) async throws -> (order: [String], raw: [String]) {
            sheet.makeFirstResponder(description)
            try await Task.sleep(for: .milliseconds(200))
            var raw = ["description"]
            for _ in 0..<16 {
                try await key(sheet, characters, 48, modifiers)
                raw.append(focused())
                if raw.last == "description" { break }
            }
            let order = raw.enumerated().compactMap { i, stop in i > 0 && raw[i - 1] == stop ? nil : stop }
            return (order, raw)
        }
        func cycle(_ state: String) async throws {
            let (forward, forwardRaw) = try await pass("\t", [])
            let (backward, backwardRaw) = try await pass("\u{19}", .shift)
            print("TAB_ORDER \(state) forward=\(forward) backward=\(backward) keys forward=\(forwardRaw) backward=\(backwardRaw)")
            if fullKeyboard {
                try require(forward.contains("startDate") && forward.contains("targetDate") && backward.contains("startDate") && backward.contains("targetDate"),
                            "Tab and Shift-Tab reach both dates (\(state))")
            } else {
                try require(forward == ["description", "startDate", "targetDate", "name", "description"], "Tab order with dates \(state)")
                try require(backward == ["description", "name", "targetDate", "startDate", "description"], "Shift-Tab order with dates \(state)")
            }
        }
        try require(!included("goal.form.start.include") && !included("goal.form.target.include"), "dates start unset")
        try await cycle("unset")
        try require(!included("goal.form.start.include") && !included("goal.form.target.include"), "tabbing through the dates does not set them")
        // Setting a date from the keyboard includes it: Tab to the start and press Up, Tab to the target and press Up
        // twice (same field), so target > start.
        sheet.makeFirstResponder(description)
        try await Task.sleep(for: .milliseconds(200))
        try await key(sheet, "\t", 48)
        try require(focused() == "startDate", "Tab from the description reaches the start date")
        let startBefore = find(sheet, "goal.form.start").flatMap { value($0, "AXValue") as? Date }
        try await key(sheet, "\u{F700}", 126, [.numericPad, .function])
        let startAfter = find(sheet, "goal.form.start").flatMap { value($0, "AXValue") as? Date }
        print("START_DATE before=\(startBefore.map { "\($0)" } ?? "nil") after=\(startAfter.map { "\($0)" } ?? "nil")")
        try require(startBefore != nil && startAfter != nil && startAfter! > startBefore!, "Up in the start date moves the date later")
        for _ in 0..<4 where focused() == "startDate" { try await key(sheet, "\t", 48) }
        try require(focused() == "targetDate", "Tab from the start date (through its parts) reaches the target date")
        try await key(sheet, "\u{F700}", 126, [.numericPad, .function])
        try await key(sheet, "\u{F700}", 126, [.numericPad, .function])
        try await wait("dates included from the keyboard") { included("goal.form.start.include") && included("goal.form.target.include") }
        try require(find(sheet, "goal.form.datesProblem") == nil, "target after start is valid")
        try await cycle("set")
        // The checkbox clears a date (and including it again restores it).
        try press(sheet, "goal.form.target.include")
        try await wait("target cleared") { !included("goal.form.target.include") }
        try press(sheet, "goal.form.target.include")
        try await wait("target included again") { included("goal.form.target.include") }
        try await capture(sheet, "form-dates-set")
        sheet.makeFirstResponder(description)
        try await Task.sleep(for: .milliseconds(200))
        try await key(sheet, "\t", 48)
        for _ in 0..<4 where focused() == "startDate" { try await key(sheet, "\t", 48) }
        try require(focused() == "targetDate", "Tab from the description, through the start date, reaches the target date")
        for _ in 0..<2 { try await key(sheet, "\u{F701}", 125, [.numericPad, .function]) }
        try await wait("dates problem") { find(sheet, "goal.form.datesProblem") != nil }
        try require((find(sheet, "goal.form.save").map { value($0, "AXEnabled") as? Bool } ?? nil) != true, "Create is disabled while the target is before the start")
        try await capture(sheet, "form-invalid-dates")
        for _ in 0..<2 { try await key(sheet, "\u{F700}", 126, [.numericPad, .function]) }
        try await wait("dates valid") { find(sheet, "goal.form.datesProblem") == nil }

        sheet.makeFirstResponder(description)
        try await key(sheet, "\r", 36, .command)
        try await wait("saved goal") { window.attachedSheet == nil && activeIds().count == before + 1 }
        let created = tower.goals().first { $0.name == "Write a short guide" }
        try require(created?.description == "First line\nSecond line" && created?.startDate != nil && created?.targetDate != nil,
                    "⌘Return saved name, multiline description and both dates")
        if let more = find(window, "home.goals.showAll"), label(more).hasPrefix("Show all") { try press(window, "home.goals.showAll") }
        try await wait("new goal on Home") { all(window, "home.goal").contains { label($0).hasPrefix("Write a short guide") } }

        // ⌘Return also saves from a date control.
        try press(window, "home.goals.new")
        try await wait("goal form") { window.attachedSheet.map { find($0, "goal.form.name") != nil } ?? false }
        let second = window.attachedSheet!
        second.makeKey()
        try await Task.sleep(for: .milliseconds(400))
        try await typeKeys(second, "Second goal")
        try await key(second, "\t", 48)
        try await typeKeys(second, "Saved from a date")
        try await key(second, "\t", 48)
        var secondNode: Any? = value(NSApp as Any, "AXFocusedUIElement"), inSecondDate = false
        for _ in 0..<8 { guard let n = secondNode else { break }; if value(n, "AXIdentifier") as? String == "goal.form.start" { inSecondDate = true; break }; secondNode = value(n, "AXParent") }
        try require(inSecondDate, "⌘Return test starts from the start date control")
        try await key(second, "\r", 36, .command)
        try await wait("saved from a date control") { window.attachedSheet == nil && activeIds().count == before + 2 }

        // Escape cancels from Name, the description and a date control; nothing is saved.
        for field in ["name", "description", "date"] {
            try press(window, "home.goals.new")
            try await wait("goal form") { window.attachedSheet.map { find($0, "goal.form.name") != nil } ?? false }
            let s = window.attachedSheet!
            s.makeKey()
            try await Task.sleep(for: .milliseconds(400))
            try await typeKeys(s, "Discard me")
            if field != "name" { try await key(s, "\r", 36); try await typeKeys(s, "draft") }
            if field == "date" {
                try await key(s, "\t", 48)
                let inDate = { () -> Bool in
                    var node: Any? = value(NSApp as Any, "AXFocusedUIElement")
                    for _ in 0..<8 { guard let n = node else { return false }; if value(n, "AXIdentifier") as? String == "goal.form.start" { return true }; node = value(n, "AXParent") }
                    return false
                }
                try require(inDate(), "Escape test starts from the start date control")
            }
            try await key(s, "\u{1b}", 53)
            try await wait("form closed by Escape in \(field)") { window.attachedSheet == nil }
        }
        try require(!tower.goals().contains { $0.name.hasPrefix("Discard me") }, "Escape saves nothing")

        // The caret in light and dark, through the app's own Appearance setting (never the system's).
        if !formOnly {
            let saved = UserDefaults.standard.string(forKey: "appearance")
            defer { if let saved { UserDefaults.standard.set(saved, forKey: "appearance") } else { UserDefaults.standard.removeObject(forKey: "appearance") } }
            for appearance in ["light", "dark"] {
                UserDefaults.standard.set(appearance, forKey: "appearance")
                try await Task.sleep(for: .milliseconds(700))
                try press(window, "home.goals.new")
                try await wait("goal form (\(appearance))") { window.attachedSheet.map { find($0, "goal.form.name") != nil } ?? false }
                let s = window.attachedSheet!
                s.makeKey()
                try await Task.sleep(for: .milliseconds(400))
                try await typeKeys(s, "Theme check")
                try await key(s, "\r", 36)
                try await typeKeys(s, "Caret here")
                guard let text = find(s, "goal.form.description") as? NSTextView else { throw Failure(description: "Missing description (\(appearance))") }
                try require(s.firstResponder === text, "description focused (\(appearance))")
                var caret: NSColor?, card: NSColor?
                s.effectiveAppearance.performAsCurrentDrawingAppearance {
                    caret = text.insertionPointColor.usingColorSpace(.sRGB); card = NSColor(Amb.card).usingColorSpace(.sRGB)
                }
                func relative(_ c: NSColor?) -> CGFloat {
                    guard let c else { return 0 }
                    func ch(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                    return 0.2126 * ch(c.redComponent) + 0.7152 * ch(c.greenComponent) + 0.0722 * ch(c.blueComponent)
                }
                let (l1, l2) = (relative(caret), relative(card))
                let contrast = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
                let at = text.selectedRange().location
                var on = 0
                for _ in 0..<10 { on = max(on, try caretInk(s, text, at: at)); try await Task.sleep(for: .milliseconds(140)) }
                try await capture(s, "form-\(appearance)")
                try await key(s, "\u{19}", 48, .shift)
                var off = 0
                for _ in 0..<5 { off = max(off, try caretInk(s, text, at: at)); try await Task.sleep(for: .milliseconds(140)) }
                print("CARET_THEME \(appearance) appearance=\(s.effectiveAppearance.name.rawValue) contrast=\(String(format: "%.2f", contrast)) focused=\(on) unfocused=\(off)")
                try require(contrast >= 3, "the caret contrasts with the field in \(appearance)")
                try require(on >= 6 && off * 3 < on, "the caret is drawn in \(appearance)")
                try await key(s, "\u{1b}", 53)
                try await wait("form closed (\(appearance))") { window.attachedSheet == nil }
            }
        }
        if formOnly {
            print("PASS goals form: focus starts in Name, Return Name→description, multiline Return, visible caret, Tab/Shift-Tab through every field with dates unset and set, keyboard-set dates, checkbox clears, invalid dates block Create, ⌘Return saves from the description and a date, Escape cancels from Name, description and a date")
            return
        }
        print("PASS goals home: Home (not Deck) with goals in focus order, briefing from saved goals, latest chats, narrow layout, one-write reorder, Deck tab separate, goal detail; form focus starts in Name, Return moves Name→description, Return is a newline in the description, visible caret, Tab/Shift-Tab through every field with dates unset and set, keyboard-set dates, invalid dates block Create, ⌘Return saves from the description and a date, Escape cancels from Name, description and a date")
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }
}

extension SampleGoalsTower {
    func goals() -> [Goal] { fileIds().compactMap { goal($0) } }
    func goalIds(status: GoalStatus) -> [String] { fileIds().filter { goal($0)?.status == status } }
}
#endif
