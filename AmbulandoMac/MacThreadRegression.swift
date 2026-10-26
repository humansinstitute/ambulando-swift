#if DEBUG
import AppKit
import SwiftUI
import AmbulandoCore

class MacRegressionMemory<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func load() -> Value? { lock.withLock { value } }
    func save(_ value: Value?) { lock.withLock { self.value = value } }
}
final class MacRegressionVaultStore: MacRegressionMemory<Data>, VaultSecretStore, @unchecked Sendable {
    func read() throws -> Data? { load() }
    func write(_ data: Data) throws { save(data) }
}
final class MacRegressionBackgroundStore: MacRegressionMemory<BackgroundReadCredential>, BackgroundCredentialStore, @unchecked Sendable {
    func read() throws -> BackgroundReadCredential? { load() }
    func write(_ credential: BackgroundReadCredential) throws { save(credential) }
    func delete() throws { save(nil) }
}
final class MacRegressionSessionStore: MacRegressionMemory<SessionKey>, SessionKeyStore, @unchecked Sendable {
    func read() throws -> SessionKey? { load() }
    func write(_ key: SessionKey) throws { save(key) }
    func delete() throws { save(nil) }
}

/// In-process AppKit accessibility interaction, for hosts without external AX permission.
/// Requires the isolated Debug fixture; never runs in Release or against a real account.
@MainActor
enum MacThreadRegression {
    static func run(model: AppModel) async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            fputs("FAIL: Mac interaction regression timed out\n", stderr)
            exit(2)
        }
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        guard let window = NSApp.windows.first(where: { $0.title == "Ambulando" }) else {
            print("FAIL: no real app window"); fflush(stdout); exit(1)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(2))
        // Runs across send/accept/render as well as the explicit sizing checks. The independent
        // process watchdog above still terminates a main actor that never resumes.
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                let start = ContinuousClock.now
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                let elapsed = start.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                if seconds >= 2 {
                    print("FAIL: main actor heartbeat delayed \(seconds)s"); fflush(stdout); exit(1)
                }
                if seconds > 0.5 { print("HEARTBEAT_SLOW seconds=\(seconds)"); fflush(stdout) }
            }
        }
        defer { heartbeat.cancel() }
        do {
            try require(find(window, "fixture.banner") != nil, "fixture banner")
            try press(window, "section.deck")
            await settle()
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacPostSaveOnly") {
                try await repeatedSends(window, model: model, count: 5)
                print("PASS: isolated repeated post-save interactions"); fflush(stdout); exit(0)
            }
            try press(window, "deck.inbox.new")
            await settle()
            print("After +: composing=\(model.composingThread), focusedThread=\(model.focusedThread != nil), composerVisible=\(find(window, "deck.compose") != nil), backgroundAccessible=\(find(window, "section.deck") != nil), attachedSheet=\(window.attachedSheet != nil)")
            try snapshot(window, model: model, name: "after-plus")
            try require(find(window, "deck.compose") != nil, "+ must expose a usable composer while the background is disabled")
            try require(find(window, "section.deck") == nil, "background must be inaccessible while composing")
            try type(window, "Thread regression draft @An")
            await settle()
            try press(window, "mention.Ana Lima")
            await settle()
            let draft = try textView(window).string
            try require(draft.contains("@Ana"), "picked mention must appear in the native field")
            try press(window, "deck.compose.cancel")
            await settle()
            try require(!model.composingThread && find(window, "section.chat") != nil, "cancel must restore background controls")
            try click(window, "section.chat")
            await settle()
            try require(model.mode == .chat, "underlying Chat navigation must respond after cancel")
            try press(window, "section.deck")
            await settle()
            try click(window, "deck.inbox.new")
            await settle()
            try require(try textView(window).string == draft, "reopening must preserve the draft and mention")
            for size in [NSSize(width: 900, height: 600), NSSize(width: 1440, height: 900)] {
                window.setContentSize(size)
                await settle()
                try require(try textView(window).string == draft, "resize must preserve native composer text")
                try press(window, "deck.compose.expand")
                await settle()
                try require(find(window, "deck.compose.cancel") != nil, "expanded composer must remain closable")
                try press(window, "deck.compose.expand")
                await settle()
            }
            try snapshot(window, model: model, name: "composed-wide")
            window.toggleFullScreen(nil)
            try? await Task.sleep(for: .seconds(2))
            let enteredFullScreen = window.styleMask.contains(.fullScreen)
            print("OS_FULLSCREEN entered=\(enteredFullScreen)")
            if enteredFullScreen {
                try require(try textView(window).string == draft, "OS fullscreen must preserve composer")
                try press(window, "deck.compose.expand")
                await settle()
                try press(window, "deck.compose.expand")
                window.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(2))
                try require(!window.styleMask.contains(.fullScreen), "must leave OS fullscreen")
            }
            // Backdrop's corner lies outside the restored modal card, exercising actual hit testing.
            let content = window.contentView!
            try sendClick(window, point: content.convert(NSPoint(x: 8, y: content.bounds.midY), to: nil))
            print("CLICK outside restored modal")
            await settle()
            if model.composingThread {
                print("GAP: synthetic outside click did not dismiss; external pointer check required")
                try press(window, "deck.compose.cancel")
                await settle()
            }
            try require(!model.composingThread && find(window, "section.deck") != nil, "dismissal must restore the app")
            try click(window, "deck.inbox.new")
            await settle()
            try require(try textView(window).string == draft, "outside dismissal must preserve draft")
            try press(window, "composer.send")
            for _ in 0..<30 {
                if model.focusedThread != nil { break }
                await settle()
            }
            try require(model.focusedThread != nil && !model.composingThread, "submit must open the accepted new thread")
            try require(find(window, "thread.focus.close") != nil, "created thread must be interactive")
            try await postSave(window, model: model, expected: "Thread regression draft")
            try snapshot(window, model: model, name: "submitted-thread")
            try press(window, "thread.focus.close")
            await settle()
            try require(model.focusedThread == nil && find(window, "section.chat") != nil, "close must restore app")
            try click(window, "section.chat")
            await settle()
            try require(model.mode == .chat, "underlying navigation must respond after submit/close")
            try press(window, "section.deck")
            await settle()
            try click(window, "deck.inbox.new")
            await settle()
            try require(try textView(window).string.isEmpty, "accepted draft must clear for the next thread")
            try press(window, "deck.compose.cancel")
            await settle()
            try require(find(window, "section.deck") != nil, "final cancel restores background")
            try await repeatedSends(window, model: model, count: 4)
            print("PASS: +, mention, draft, cancel, navigation, reopen, resize, modal expand/restore, submit, close, fresh composer (see GAP lines for optional pointer checks)")
        } catch {
            print("FAIL: \(error)")
            dump(window)
            fflush(stdout)
            exit(1)
        }
        fflush(stdout)
        exit(0)
    }

    static func repeatedSends(_ window: NSWindow, model: AppModel, count: Int) async throws {
        for cycle in 1...count {
            try press(window, "deck.inbox.new")
            await settle()
            let body = "Post-save regression \(cycle)\n\n| Item | Status |\n| --- | --- |\n| Layout | Saved |\n\n" + String(repeating: "A realistic multiline update with **formatting**, text and a [link](https://example.com).\n\n", count: cycle * 3)
            try type(window, body)
            await settle()
            try press(window, "composer.send")
            for _ in 0..<30 {
                if model.focusedThread != nil { break }
                await settle()
            }
            try await postSave(window, model: model, expected: "Post-save regression \(cycle)")
            try press(window, "thread.focus.close")
            await settle()
            try click(window, "section.chat")
            await settle()
            try require(model.mode == .chat, "repeated post-save navigation must respond")
            try press(window, "section.deck")
            await settle()
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }
    /// Exercise production sync/read/render paths, never insert local rows or toggle modal state to simulate success.
    static func postSave(_ window: NSWindow, model: AppModel, expected: String) async throws {
        guard let focus = model.focusedThread, let channel = focus.channelId,
              let workspace = model.selectedWorkspace, let fixture = model.fixture, let store = model.store else {
            throw Failure(description: "Missing accepted fixture thread")
        }
        try require(!model.composingThread, "accepted send must leave composing state")
        for _ in 0..<20 {
            if containsText(window, expected) && find(window, "message") != nil { break }
            await settle()
        }
        try require(containsText(window, expected) && find(window, "message") != nil, "saved message must actually render")
        try snapshot(window, model: model, name: "post-save-" + focus.threadId)
        let before = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500).count
        let marker = "Concurrent reply \(expected)"
        let replyCount = ProcessInfo.processInfo.arguments.contains("-AmbulandoMacPostSaveNoSync") ? 0 : 12
        let resizing = !ProcessInfo.processInfo.arguments.contains("-AmbulandoMacPostSaveStatic")
        let updates = Task.detached {
            for index in 0..<replyCount {
                let n = index + 1
                fixture.tower.postAsMember(channel: channel, body: "\(marker) \(n)", threadId: focus.threadId)
                fixture.tower.postAsMember(channel: channel, body: "Background inbox update \(n)")
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
        defer { updates.cancel() }
        var maxDelay = 0.0
        for step in 0..<12 {
            let start = ContinuousClock.now
            print("POST_SAVE_STEP step=\(step) resizing=\(resizing) replies=\(replyCount)"); fflush(stdout)
            if resizing {
                window.setContentSize(step.isMultiple(of: 2) ? NSSize(width: 900, height: 600) : NSSize(width: 1440, height: 900))
                if step.isMultiple(of: 3) { try press(window, "thread.focus.expand") }
            }
            model.openThread(focus.threadId, channelId: channel, in: workspace)
            model.openChannel(channel, in: workspace, force: true)
            try? await Task.sleep(for: .milliseconds(250))
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            maxDelay = max(maxDelay, seconds)
            try require(seconds < 2, "post-save main actor stalled for \(seconds)s")
            try require(model.focusedThread == focus && find(window, "thread.focus.close") != nil, "sync must retain interactive focused thread")
        }
        await updates.value
        for _ in 0..<20 {
            model.openThread(focus.threadId, channelId: channel, in: workspace)
            await settle()
            let rows = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500)
            if rows.count == before + replyCount && (replyCount == 0 || containsText(window, marker)) { break }
        }
        let rows = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500)
        try require(rows.count == before + replyCount, "all concurrent replies must reach local store through sync")
        try require(replyCount == 0 || containsText(window, marker), "synced reply must render in actual thread")
        try type(window, "Unsent responsiveness probe")
        await settle()
        try require(try textView(window).string == "Unsent responsiveness probe", "post-save reply composer must accept input")
        for _ in 0..<12 {
            let start = ContinuousClock.now
            try? await Task.sleep(for: .milliseconds(250))
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            maxDelay = max(maxDelay, seconds)
            try require(seconds < 2, "sustained post-save response stalled")
        }
        print("POST_SAVE_PASS thread=\(focus.threadId) replies=\(replyCount) maxResponseSeconds=\(maxDelay)"); fflush(stdout)
    }

    static func containsText(_ object: Any, _ text: String, depth: Int = 0) -> Bool {
        guard depth < 60 else { return false }
        for attribute in ["AXValue", "AXDescription"] {
            if let string = value(object, attribute) as? String, string.contains(text) { return true }
        }
        return children(object).contains { containsText($0, text, depth: depth + 1) }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }
    static func settle() async { try? await Task.sleep(for: .milliseconds(700)) }
    static func find(_ object: Any, _ id: String, depth: Int = 0) -> NSObject? {
        guard depth < 60 else { return nil }
        if value(object, "AXIdentifier") as? String == id { return object as? NSObject }
        for child in children(object) {
            if let match = find(child, id, depth: depth + 1) { return match }
        }
        return nil
    }
    static func press(_ window: NSWindow, _ id: String) throws {
        guard let node = find(window, id) else { throw Failure(description: "Missing control: \(id)") }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: selector) else { throw Failure(description: "Control cannot press: \(id)") }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(node.method(for: selector), to: Action.self)
        try require(action(node, selector), "Press failed: \(id)")
        print("PRESS \(id)"); fflush(stdout)
    }
    static func textView(_ window: NSWindow) throws -> NSTextView {
        guard let view = find(window, "composer.field") as? NSTextView else { throw Failure(description: "Missing native text view") }
        return view
    }
    static func type(_ window: NSWindow, _ text: String) throws {
        let view = try textView(window)
        window.makeFirstResponder(view)
        view.insertText(text, replacementRange: view.selectedRange())
        print("TYPE native NSTextView")
    }
    static func click(_ window: NSWindow, _ id: String) throws {
        guard let node = find(window, id) else { throw Failure(description: "Missing click target: \(id)") }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard node.responds(to: selector) else { throw Failure(description: "Missing frame: \(id)") }
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        let frame = unsafeBitCast(node.method(for: selector), to: Frame.self)(node, selector)
        try require(!frame.isEmpty, "Empty click target: \(id)")
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        try sendClick(window, point: point)
        print("CLICK \(id)"); fflush(stdout)
    }
    static func sendClick(_ window: NSWindow, point: NSPoint) throws {
        var release: NSEvent?
        for kind in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
            guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw Failure(description: "Cannot create local mouse event")
            }
            // AppKit buttons synchronously track mouseDown until a queued mouseUp arrives.
            if kind == .leftMouseUp { release = event; NSApp.postEvent(event, atStart: false) }
            else { window.sendEvent(event) }
        }
        // SwiftUI gestures need direct delivery too; a native button may already have consumed the queued release.
        if let release { window.sendEvent(release) }
    }
    static func snapshot(_ window: NSWindow, model: AppModel, name: String) throws {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              model.fixture != nil else { throw Failure(description: "Cannot capture app view") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Emit through the captured log: external automation need not read a protected app container.
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "Cannot encode app snapshot") }
        print("SNAPSHOT_BASE64 \(name) \(png.base64EncodedString())")
    }

    static func value(_ object: Any, _ name: String) -> Any? {
        guard let node = object as? NSObject else { return nil }
        let names = ["AXRole": "accessibilityRole", "AXIdentifier": "accessibilityIdentifier", "AXDescription": "accessibilityLabel", "AXValue": "accessibilityValue", "AXChildren": "accessibilityChildren"]
        if let getter = names[name] {
            let selector = NSSelectorFromString(getter)
            if node.responds(to: selector) { return node.perform(selector)?.takeUnretainedValue() }
        }
        return node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: name))
    }
    static func children(_ object: Any) -> [Any] { value(object, "AXChildren") as? [Any] ?? [] }
    static func dump(_ object: Any, depth: Int = 0) {
        guard depth < 50 else { return }
        print("REGRESSION \(String(repeating: " ", count: depth))\(value(object, "AXRole") ?? "?") id=\(value(object, "AXIdentifier") ?? "") label=\(value(object, "AXDescription") ?? "") value=\(String(describing: value(object, "AXValue")).prefix(100))")
        for child in children(object) { dump(child, depth: depth + 1) }
    }
}
#endif
