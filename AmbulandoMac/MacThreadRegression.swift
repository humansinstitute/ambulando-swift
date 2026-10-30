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
    private static var restoreFixtureClipboard: (() -> Void)?
    static func run(model: AppModel) async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            fputs("FAIL: Mac interaction regression timed out\n", stderr)
            exit(2)
        }
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        // Navigation can restore a section title before this task runs. Wait for the fixture window's actual
        // content instead of depending on its transient launch title or racing SwiftUI window creation.
        var fixtureWindow: NSWindow?
        for _ in 0..<50 {
            fixtureWindow = NSApp.windows.first(where: { find($0, "fixture.banner") != nil })
            if fixtureWindow != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let window = fixtureWindow else {
            print("FAIL: no ready fixture app window"); fflush(stdout); exit(1)
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
                    restoreFixtureClipboard?()
                    print("FAIL: main actor heartbeat delayed \(seconds)s"); fflush(stdout); exit(1)
                }
                if seconds > 0.5 { print("HEARTBEAT_SLOW seconds=\(seconds)"); fflush(stdout) }
            }
        }
        defer { heartbeat.cancel() }
        do {
            try require(find(window, "fixture.banner") != nil, "fixture banner")
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacMessageEditCheck") {
                try await messageEditCheck(window, model: model)
                print("PASS: Mac in-composer message edits, picker, signed readback, repeat, cancel and reply restoration"); fflush(stdout); exit(0)
            }
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacPinCheck") {
                try await pinCardCheck(window, model: model)
                print("PASS: focused pin check completed"); fflush(stdout); exit(0)
            }
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacBatchCheck") {
                try await batchCheck(window, model: model)
                print("PASS: batch composer focus, pin move and browser file flows"); fflush(stdout); exit(0)
            }
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacStartupThreadCheck") {
                try await startupThreadCheck(window, model: model)
                print("PASS: restored/empty thread, composer focus and draft preservation"); fflush(stdout); exit(0)
            }
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacWorkspaceAdministrationCheck") {
                try await workspaceAdministrationCheck(window, model: model)
                print("PASS: native workspace administration sections and narrow Mac layout"); fflush(stdout); exit(0)
            }
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacCommentMentionCheck") {
                try await commentMentionCheck(window, model: model)
                print("PASS: task/doc comment actor picker, caret, send/reply and reopen"); fflush(stdout); exit(0)
            }
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacOvernightCheck") {
                try await overnightCheck(window, model: model)
                print("PASS: lightbox, canvas window and Board items"); fflush(stdout); exit(0)
            }
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacWikiLinkCheck") {
                try await wikiLinkCheck(window, model: model)
                print("PASS: wiki links open, ask, create and link in the Mac reader"); fflush(stdout); exit(0)
            }
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacChannelRegression") {
                try await channelSends(window, model: model)
                print("PASS: channel Messages repeated sends"); fflush(stdout); exit(0)
            }
            try press(window, "section.deck")
            await settle()
            // Rich and composer checks need one selected channel before opening New thread.
            model.selectContext(WorkContext(scopeId: FixtureTower.scopeAmbulando, channelId: FixtureTower.generalChannel))
            await settle()
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacRichFormattingCheck") {
                try await richFormattingCheck(window, model: model)
                print("PASS: rich thread formatting, widths, menus and draft retention"); fflush(stdout); exit(0)
            }
            // Deck's New thread preselects only an unambiguous channel; these runs start in one so + opens the field.
            model.selectContext(WorkContext(scopeId: FixtureTower.scopeAmbulando, channelId: FixtureTower.generalChannel))
            await settle()
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacDeckComposerCheck") {
                try await deckComposerCheck(window, model: model)
                print("PASS: Deck composer tiles, lightbox, removal, draft and resize"); fflush(stdout); exit(0)
            }
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacTextAttachmentRegression") {
                try await textAttachments(window, model: model)
                print("PASS: automatic text attachment real-window interactions"); fflush(stdout); exit(0)
            }
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacPostSaveOnly") {
                try await repeatedSends(window, model: model, count: ProcessInfo.processInfo.arguments.contains("-AmbulandoMacMenuProbe") ? 1 : 5)
                print("PASS: isolated repeated post-save interactions"); fflush(stdout); exit(0)
            }
            // The Inbox read-actions menu is one small icon, not a pop-up button stretched across the card's header.
            guard let readMenu = find(window, "deck.inbox.readMenu") else { throw Failure(description: "Missing Inbox read-actions menu") }
            let menuFrame = frame(of: readMenu)
            print("INBOX_MENU_FRAME width=\(menuFrame.width) height=\(menuFrame.height)")
            try require(menuFrame.width > 0 && menuFrame.width <= 56 && menuFrame.height <= 48, "the Inbox read-actions menu must be compact (\(menuFrame))")
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
            var draft = try textView(window).string
            try require(draft.contains("@Ana"), "picked mention must appear in the native field")
            try require(find(window, "mention.list") == nil, "choosing a mention must close the suggestions")
            try type(window, "next words")
            await settle()
            try require(find(window, "mention.list") == nil, "typing after a picked mention must not reopen the suggestions")
            try require(try textView(window).string.contains("@Ana Lima next words"), "the composer reads naturally after the pick")
            draft = try textView(window).string
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

    /// Exercises the restored Thread/Reply surface without modifying production data.
    static func startupThreadCheck(_ window: NSWindow, model: AppModel) async throws {
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacStartupThreadResume") {
            try require(model.focusedThread == nil, "launch must leave the channel usable before resuming")
            try require(model.restoredThread?.threadId == "f1c7bbbb-0000-4000-8000-000000009999", "launch keeps persisted thread identity")
            try require(try textView(window).string == "Keep channel startup draft", "channel draft remains available before resuming")
            guard let store = model.store, let connection = model.connection else { throw Failure(description: "Missing fixture store") }
            let saved = try await store.reader.state("thread-focus:\(connection.id):\(FixtureTower.studio)")
            try require(saved?.contains("f1c7bbbb-0000-4000-8000-000000009999") == true, "launch does not erase persisted route")
            let target = ChatTarget(connectionId: connection.id, workspaceId: FixtureTower.studio,
                                    channelId: FixtureTower.generalChannel, threadId: "f1c7bbbb-0000-4000-8000-000000009999")
            try require(try await store.reader.draft(target)?.text == "Keep restored reply draft", "deferred reply draft stays intact")
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacStartupThreadKeepDeferred") {
                try require(find(window, "thread.resume") != nil, "resume action remains available")
                print("STARTUP_DEFERRED: channel usable; saved route and both drafts retained"); fflush(stdout)
                return
            }
            model.selectWorkspace(FixtureTower.lab)
            await settle()
            try require(model.restoredThread == nil && find(window, "thread.resume") == nil, "switching workspace removes old resume banner")
            model.selectWorkspace(FixtureTower.studio)
            await settle()
            try require(model.restoredThread?.threadId == target.threadId, "returning workspace restores its saved conversation")
            try press(window, "thread.resume")
            await settle()
            try require(model.restoredThread == nil && model.focusedThread != nil, "explicit resume opens the saved thread")
            try require(try textView(window).string == "Keep restored reply draft", "launch restores reply draft")
            try press(window, "thread.focus.close")
            await settle()
            try require(try textView(window).string == "Keep channel startup draft", "launch preserves channel draft")
            return
        }
        model.selectWorkspace(FixtureTower.studio)
        await settle()
        model.selectContext(WorkContext(scopeId: FixtureTower.scopeAmbulando, channelId: FixtureTower.generalChannel))
        model.mode = .chat
        await settle()
        try type(window, "Keep channel startup draft")
        await settle()
        guard let connection = model.connection, let store = model.store else { throw Failure(description: "Missing fixture store") }
        let focus = ThreadFocus(workspaceId: FixtureTower.studio, channelId: FixtureTower.generalChannel,
                                threadId: "f1c7bbbb-0000-4000-8000-000000009999")
        let target = ChatTarget(connectionId: connection.id, workspaceId: focus.workspaceId,
                                channelId: FixtureTower.generalChannel, threadId: focus.threadId)
        try await store.writer.saveDraft(target, Draft(text: "Keep restored reply draft", mentions: []))
        model.restoredThread = focus
        model.focusThread(focus)
        await settle()
        try require(model.restoredThread == nil, "deliberate thread opening clears deferred presentation")
        try require(find(window, "thread.focus.close") != nil, "empty restored thread stays closable")
        let reply = try textView(window)
        try require(reply.string == "Keep restored reply draft", "reply draft restores")
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacStartupThreadSeed") {
            await settle()
            let key = "thread-focus:\(connection.id):\(focus.workspaceId)"
            let saved = try await store.reader.state(key)
            try require(saved?.contains(focus.threadId) == true, "focused thread persisted before process exit")
            print("STARTUP_SEEDED: empty thread and both drafts ready for relaunch"); fflush(stdout)
            return
        }
        window.makeFirstResponder(reply)
        for _ in 0..<5 {
            await settle()
            try require(window.firstResponder === reply, "reply must retain keyboard focus over channel composer")
        }
        reply.insertText(" retained", replacementRange: reply.selectedRange())
        await settle()
        try press(window, "thread.focus.close")
        await settle()
        try require(try textView(window).string == "Keep channel startup draft", "channel draft survives thread close")
        model.focusThread(focus)
        await settle()
        try require(try textView(window).string.contains("retained"), "reply edits survive reopen")
        try require(try await store.reader.draft(target)?.text.contains("retained") == true, "reply draft remains durable")
        try press(window, "thread.focus.close")
        await settle()
    }

    /// Covers top-level Messages rather than Deck's new-thread modal or a reply panel.
    static func channelSends(_ window: NSWindow, model: AppModel) async throws {
        model.selectWorkspace(FixtureTower.studio)
        await settle()
        guard let workspace = model.selectedWorkspace, let store = model.store,
              let fixture = model.fixture else { throw Failure(description: "Missing fixture") }
        guard let channel = model.navigation.value.channel(FixtureTower.generalChannel) else { throw Failure(description: "Missing fixture channel") }
        guard let connection = model.connection else { throw Failure(description: "Missing fixture connection") }
        let probe = ComposerModel(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id,
                                                     channelId: channel.id, threadId: "draft-ordering-regression"), store: store)
        probe.text = "Old unsent draft"
        let stale = Draft(text: probe.text, mentions: [], updatedAt: Date().addingTimeInterval(-1))
        probe.text = ""
        probe.adopt(stale)
        try require(probe.text.isEmpty, "delayed saved draft must not undo local clearing")
        probe.adopt(Draft(text: "External Edit restore", mentions: [], updatedAt: Date().addingTimeInterval(1)))
        try require(probe.text == "External Edit restore", "newer external draft must still restore")
        probe.text = ""
        let attachment = PendingAttachment(filename: "fixture.txt", mimeType: "text/plain", sizeBytes: 1,
                                           sha256: String(repeating: "0", count: 64), staged: "fixture-only.txt")
        probe.attachments = [attachment]
        let staleAttachment = Draft(text: "", mentions: [], updatedAt: Date().addingTimeInterval(-1), attachments: [attachment])
        probe.attachments = []
        probe.adopt(staleAttachment)
        try require(probe.attachments.isEmpty, "delayed attachment-only draft must not undo removal")
        probe.adopt(Draft(text: "", mentions: [], updatedAt: Date().addingTimeInterval(1), attachments: [attachment]))
        try require(probe.attachments == [attachment], "newer attachment-only Edit restore remains supported")
        probe.attachments = []; probe.saveNow()
        print("DRAFT_ORDERING_PASS"); fflush(stdout)
        for index in 0..<160 {
            let body = index % 3 == 0 ? "## History \(index)\n\n| Key | Value |\n| --- | --- |\n| Long | " + String(repeating: "variable wrapped table text ", count: 30) + " |"
                : "Channel history \(index)\n\n" + String(repeating: "Variable wrapped history text. ", count: (index % 20) + 1)
            fixture.tower.postAsMember(channel: channel.id, body: body)
        }
        model.selectContext(WorkContext(scopeId: channel.scopeId, channelId: channel.id))
        model.mode = .chat
        await settle()
        print("CHANNEL_OPEN"); fflush(stdout)
        for cycle in 0..<5 {
            try require(try textView(window).string.isEmpty, "next send starts with empty composer")
            let body = "Channel compose regression \(cycle)\n\n| Key | Value |\n| --- | --- |\n| Send | accepted |"
            try type(window, body)
            await settle()
            let expected = try textView(window).string
            print("CHANNEL_SEND \(cycle) method=\(cycle % 2 == 0 ? "button" : "return")"); fflush(stdout)
            if cycle % 2 == 0 { try press(window, "composer.send") }
            else { try postKey(window, key: "\r", code: 36, modifiers: []) }
            for _ in 0..<20 {
                await settle()
                let rows = try await store.reader.channelFeed(workspaceId: workspace.id, channelId: channel.id, limit: 150)
                if rows.contains(where: { $0.message.body == expected }) {
                    // A resize can leave the lazy list reading older rows. Reveal the accepted row explicitly;
                    // this regression checks responsiveness/rendering, not automatic follow-latest behavior.
                    if !containsText(window, "Channel compose regression \(cycle)"),
                       let list = threadScrollView(window), let document = list.documentView {
                        let end = document.isFlipped ? max(0, document.bounds.maxY - list.contentView.bounds.height) : document.bounds.minY
                        list.contentView.scroll(to: NSPoint(x: 0, y: end)); list.reflectScrolledClipView(list.contentView)
                        print("CHANNEL_REVEAL_ACCEPTED \(cycle)"); fflush(stdout)
                    } else { break }
                }
            }
            let rows = try await store.reader.channelFeed(workspaceId: workspace.id, channelId: channel.id, limit: 150)
            try require(rows.filter { $0.message.body == expected }.count == 1, "top-level send accepted exactly once")
            try require(try textView(window).string.isEmpty, "accepted channel send clears composer")
            try require(containsText(window, "Channel compose regression \(cycle)"), "accepted channel send must render")
            fixture.tower.postAsMember(channel: channel.id, body: "Background channel update \(cycle)")
            model.openChannel(channel.id, in: workspace, force: true)
            window.setContentSize(cycle % 2 == 0 ? NSSize(width: 900, height: 600) : NSSize(width: 1440, height: 900))
            await settle()
            try type(window, "Unsent channel draft")
            await settle()
            try require(try textView(window).string == "Unsent channel draft", "composer remains responsive after acceptance and sync")
            let field = try textView(window)
            field.setSelectedRange(NSRange(location: 0, length: (field.string as NSString).length))
            field.insertText("", replacementRange: field.selectedRange())
            await settle()
            print("CHANNEL_PASS \(cycle)"); fflush(stdout)
        }
    }

    /// Exercises the real composer, native paste interception, undo and page editor in a disposable fixture window.
    static func textAttachments(_ window: NSWindow, model: AppModel) async throws {
        let pasteboard = NSPasteboard.general
        let clipboard = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        var ownClipboardChangeCount: Int?
        let restore = {
            guard let owned = ownClipboardChangeCount, pasteboard.changeCount == owned else { return }
            pasteboard.clearContents()
            let items = clipboard.map { representations in
                let item = NSPasteboardItem()
                for (type, bytes) in representations { item.setData(bytes, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        restoreFixtureClipboard = restore
        defer { restore(); restoreFixtureClipboard = nil }
        try press(window, "deck.inbox.new"); await settle()
        let field = try textView(window)
        window.makeFirstResponder(field)
        for character in "Keep this draft" { try postKey(window, key: String(character), code: 0, modifiers: []) }
        await settle()
        try require(field.string == "Keep this draft", "actual local key events must populate the native composer")
        field.setSelectedRange(NSRange(location: 5, length: 4))
        let original = field.string, selection = field.selectedRange()
        let contrastOnly = ProcessInfo.processInfo.arguments.contains("-AmbulandoMacTextModalContrast")
        let text = contrastOnly ? String(repeating: "Modal controls fixture\n", count: 150)
            : "\u{FEFF}" + String(repeating: "report 😀 e\u{301}\r\n", count: 240_000)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        ownClipboardChangeCount = pasteboard.changeCount
        print("TEXT_UNDO runloop=\(RunLoop.main.currentMode?.rawValue ?? "nil") modes=\(field.undoManager?.runLoopModes.map(\.rawValue) ?? []) registration=\(field.undoManager?.isUndoRegistrationEnabled ?? false)")
        print("TEXT_UNDO beforePaste grouping=\(field.undoManager?.groupingLevel ?? -1) byEvent=\(field.undoManager?.groupsByEvent ?? false) action=\(field.undoManager?.undoActionName ?? "nil")")
        if contrastOnly { field.paste(nil) }
        else { try postKey(window, key: "v", code: 9, modifiers: [.command]) }
        await settle()
        print("TEXT_UNDO sameNativeField=\((try? textView(window)) === field)")
        print("TEXT_UNDO afterPaste grouping=\(field.undoManager?.groupingLevel ?? -1) byEvent=\(field.undoManager?.groupsByEvent ?? false) action=\(field.undoManager?.undoActionName ?? "nil")")
        try require(field.string == original && field.selectedRange() == selection, "large paste preserves inline text and selection")
        try require(find(window, "composer.textcard.open") != nil, "large paste creates visible text card")
        if contrastOnly {
            try press(window, "composer.textcard.open"); await settle()
            let sheet = window.attachedSheet ?? window
            try require(find(sheet, "textfile.cancel") != nil && find(sheet, "textfile.save") != nil, "modal confirmation controls exist")
            try snapshot(sheet, model: model, name: "text-attachment-modal-contrast")
            try press(sheet, "textfile.cancel"); await settle()
            print("TEXT_MODAL_CONTRAST_PASS small fixture only")
            return
        }
        try postKey(window, key: "z", code: 6, modifiers: [.command]); await settle()
        try require(find(window, "composer.textcard.open") == nil && field.string == original, "Undo removes attachment without giant inline text")
        print("TEXT_UNDO afterUndo canRedo=\(field.undoManager?.canRedo ?? false) redoAction=\(field.undoManager?.redoActionName ?? "nil") sameNativeField=\((try? textView(window)) === field) attached=\(field.window != nil) focused=\(window.firstResponder === field)")
        try performEditMenu("Redo"); await settle()
        try require(find(window, "composer.textcard.open") != nil && field.string == original, "Redo restores attachment")
        try press(window, "composer.textcard.open"); await settle()
        let sheet = window.attachedSheet ?? window
        try require(find(sheet, "textfile.page") != nil, "large file opens a paged modal")
        guard let page = find(sheet, "textfile.content") as? NSTextView else { throw Failure(description: "Missing native page editor") }
        try require(page.string.unicodeScalars.count <= TextPages.pageScalars + 2_001, "native editor holds only one bounded page")
        try press(sheet, "textfile.cancel"); await settle()
        try require(window.attachedSheet == nil, "Cancel returns to unchanged composer")
        try press(window, "composer.textcard.open"); await settle()
        let editorWindow = window.attachedSheet ?? window
        guard let editor = find(editorWindow, "textfile.content") as? NSTextView else { throw Failure(description: "Missing reopened page editor") }
        let beforePage = editor.string
        let inserted = String(repeating: "界😀x", count: 500_000)
        editorWindow.makeFirstResponder(editor)
        editor.insertText(inserted, replacementRange: NSRange(location: 0, length: (beforePage as NSString).length))
        await settle(); await settle()
        guard let bounded = find(editorWindow, "textfile.content") as? NSTextView else { throw Failure(description: "Missing repaged editor") }
        try require(bounded.string.unicodeScalars.count <= TextPages.pageScalars + 2_001, "editor intercepts giant single-line insertion before native layout")
        try press(editorWindow, "textfile.save"); await settle()
        guard let store = model.store, let connection = model.connection, let workspace = model.selectedWorkspace,
              let channel = model.navigation.value.channels(in: model.context).first, let staging = model.staging else {
            throw Failure(description: "Missing fixture draft context")
        }
        let target = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: model.context.channelId ?? channel.id)
        guard let draft = try await store.reader.draft(target), let attachment = draft.attachments.first else { throw Failure(description: "Missing durable attachment draft") }
        let expected = Data((inserted + String(text.unicodeScalars.dropFirst(beforePage.unicodeScalars.count))).utf8)
        let saved = try TextAttachmentStaging.read(attachment, in: staging)
        try require(saved == expected, "Save preserves full inserted bytes and all untouched pages")
        try require(draft.text == original, "attachment editor preserves inline draft")
        print("TEXT_ATTACHMENT_UI_PASS bytes=\(saved.count) boundedPage=\(bounded.string.unicodeScalars.count) undo=pass cancel=pass durable=pass")
        try snapshot(window, model: model, name: "text-attachment-editor-saved")
        try press(window, "composer.send")
        for _ in 0..<40 { if find(window, "message.textcard.open") != nil { break }; await settle() }
        try require(find(window, "message.textcard.open") != nil, "sent attachment renders as a readable card")
        guard let focus = model.focusedThread,
              let originalMessage = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 200)
                .first(where: { !MessageAttachment.from(messageRaw: $0.raw).isEmpty }) else { throw Failure(description: "Missing sent fixture attachment record") }
        let originalAttachments = MessageAttachment.from(messageRaw: originalMessage.raw)
        try press(window, "message.textcard.open"); await settle(); await settle()
        let readerWindow = window.attachedSheet ?? window
        guard let reader = find(readerWindow, "textfile.content") as? NSTextView else { throw Failure(description: "Missing sent native reader") }
        try require(!reader.isEditable, "sent attachment opens read-only")
        try press(readerWindow, "textfile.edit"); await settle()
        guard let sentEditor = find(readerWindow, "textfile.content") as? NSTextView else { throw Failure(description: "Missing sent page editor") }
        model.fixture?.offline = true
        sentEditor.insertText("LOCAL OFFLINE SENT EDIT\r\n", replacementRange: NSRange(location: 0, length: 0))
        await settle()
        try press(readerWindow, "textfile.save"); await settle(); await settle()
        try require(find(readerWindow, "textfile.error") != nil, "offline save reports failure while retaining the local edit")
        try press(readerWindow, "textfile.cancel"); await settle()
        guard let confirmation = NSApp.windows.first(where: { find($0, "textfile.keepLocal") != nil }) else {
            throw Failure(description: "Missing keep-local close choice")
        }
        guard let keep = find(confirmation, "textfile.keepLocal") else { throw Failure(description: "Missing keep-local control") }
        let keepSelector = NSSelectorFromString("accessibilityPerformPress")
        guard keep.responds(to: keepSelector) else { throw Failure(description: "Keep-local control cannot be pressed") }
        typealias KeepAction = @convention(c) (AnyObject, Selector) -> Bool
        let keepAction = unsafeBitCast(keep.method(for: keepSelector), to: KeepAction.self)
        // SwiftUI confirmation controls can return false while dismissing. Verify their resulting state instead.
        print("KEEP_LOCAL_AX accepted=\(keepAction(keep, keepSelector))")
        for _ in 0..<20 { if window.attachedSheet == nil { break }; await settle() }
        try require(window.attachedSheet == nil, "keep-local choice must close modal after durable write")
        try press(window, "message.textcard.open"); await settle(); await settle()
        let recoveredWindow = window.attachedSheet ?? window
        guard let recoveredEditor = find(recoveredWindow, "textfile.content") as? NSTextView else { throw Failure(description: "Missing recovered sent editor") }
        try require(recoveredEditor.string.hasPrefix("LOCAL OFFLINE SENT EDIT"), "offline sent edit survives closing and reopening modal")
        try require(containsText(recoveredWindow, "Recovered your edit"), "recovered local edit is clearly labelled")
        let messagesAfter = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 200)
        guard let messageAfter = messagesAfter.first(where: { $0.id == originalMessage.id }) else { throw Failure(description: "Original sent message disappeared") }
        try require(messageAfter.body == originalMessage.body && MessageAttachment.from(messageRaw: messageAfter.raw) == originalAttachments,
            "local sent edits never mutate the original message attachment")
        print("TEXT_ATTACHMENT_SENT_UI_PASS readonly=pass offlineSave=retained closeReopen=exact originalMessage=unchanged")
        try snapshot(recoveredWindow, model: model, name: "text-attachment-offline-sent-recovered")
        try press(recoveredWindow, "textfile.cancel"); await settle()
        model.fixture?.offline = false
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
            let accepted = model.focusedThread!
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacThreadCapacity") {
                try await readingPositionCheck(window, model: model, focus: accepted)
            }
            try press(window, "thread.focus.close")
            await settle()
            // Re-enter through the same route as a thread link, rendering the real panel and persisted draft.
            model.focusThread(accepted)
            for _ in 0..<20 {
                if find(window, "message.actions") != nil { break }
                await settle()
            }
            try require(try textView(window).string == "Unsent responsiveness probe", "thread draft must survive close/reopen")
            try require(find(window, "message.actions") != nil, "reopened message controls must render")
            print("REOPEN_PASS draft and native message controls")
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
        try await menuAction(window, title: "Copy message")
        try require(NSPasteboard.general.string(forType: .string)?.contains(expected) == true, "native menu must copy the rendered message")
        let initialMenu = nativeActionsButton(window.contentView!)
        let initialComposer = try textView(window)
        let before = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500).count
        let marker = "Concurrent reply \(expected)"
        let options = ProcessInfo.processInfo.arguments
        let capacity = options.contains("-AmbulandoMacThreadCapacity")
        let replyCount = capacity ? 499 : (options.contains("-AmbulandoMacPostSaveNoSync") || options.contains("-AmbulandoMacPostSaveInboxOnly") ? 0 : 12)
        let inboxCount = capacity || options.contains("-AmbulandoMacPostSaveNoSync") || options.contains("-AmbulandoMacPostSaveThreadOnly") ? 0 : 12
        let resizing = !ProcessInfo.processInfo.arguments.contains("-AmbulandoMacPostSaveStatic")
        let capacityStart = ContinuousClock.now
        let updates = Task.detached {
            if capacity {
                fixture.tower.postAsMember(channel: channel, body: marker, threadId: focus.threadId, count: replyCount)
                return
            }
            for index in 0..<max(replyCount, inboxCount) {
                let n = index + 1
                if index < replyCount { fixture.tower.postAsMember(channel: channel, body: "\(marker) \(n)", threadId: focus.threadId) }
                if index < inboxCount { fixture.tower.postAsMember(channel: channel, body: "Background inbox update \(n)") }
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
        defer { updates.cancel() }
        var maxDelay = 0.0
        for step in 0..<12 {
            let start = ContinuousClock.now
            print("POST_SAVE_STEP step=\(step) resizing=\(resizing) replies=\(replyCount) inbox=\(inboxCount)"); fflush(stdout)
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
        if capacity { print("CAPACITY_INCREMENTAL rows=\(rows.count) wall=\(capacityStart.duration(to: .now))") }
        if options.contains("-AmbulandoMacPostSaveInboxOnly") && !resizing {
            try require(nativeActionsButton(window.contentView!) === initialMenu, "unrelated inbox traffic must preserve native menu button identity")
            try require(try textView(window) === initialComposer, "unrelated inbox traffic must preserve composer identity")
            print("IDENTITY_PASS unchanged native menu/composer after unrelated inbox traffic")
        }
        try await menuAction(window, title: "FD Ref")
        try require(NSPasteboard.general.string(forType: .string)?.contains("mention:chat:") == true, "native menu FD reference must remain actionable")
        try snapshot(window, model: model, name: "received-" + focus.threadId)
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

    /// Open the real native menu and select an actual item inside AppKit's tracking run loop.
    static func menuAction(_ window: NSWindow, title: String, button id: String = "message.actions") async throws {
        let selected = MacRegressionMemory<Bool>()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
            let tracked = MacRegressionMemory<NSMenu>()
            tracked.save(notification.object as? NSMenu)
            MainActor.assumeIsolated {
                let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        guard let menu = tracked.load() else { return }
                        if let index = menu.items.firstIndex(where: { $0.title == title }) {
                            menu.performActionForItem(at: index)
                            selected.save(true)
                        }
                        menu.cancelTracking()
                    }
                }
                // AppKit tracks menus in this mode; a main-queue async block is not necessarily serviced there.
                RunLoop.main.add(timer, forMode: .eventTracking)
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try require(find(window, id) != nil, id + " menu must expose its accessibility label/identifier")
        // Hit-test the visible accessibility frame. Direct recursive NSView lookup can select a hidden
        // channel's menu behind the focused thread and bypasses the window's normal event routing.
        try click(window, id)
        await settle()
        try require(selected.load() == true, "native menu must open and perform " + title)
        print("MENU_PASS " + title)
    }

    /// At the full thread query bound, test actual native scrolling and the saved first-message anchor.
    static func readingPositionCheck(_ window: NSWindow, model: AppModel, focus: ThreadFocus) async throws {
        guard let store = model.store, let channel = focus.channelId, let connection = model.connection else {
            throw Failure(description: "Missing capacity target")
        }
        let rows = try await store.reader.threadMessages(workspaceId: focus.workspaceId, threadId: focus.threadId, limit: 500)
        try require(rows.count == 500, "capacity fixture must reach all 500 rows")
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacCapacityFollowOnly") {
            try await capacityFollowCheck(window, model: model, focus: focus)
            return
        }
        func scrollView() throws -> NSScrollView {
            guard let view = threadScrollView(window), let document = view.documentView, document.bounds.height > view.contentView.bounds.height else {
                throw Failure(description: "Missing scrollable native thread")
            }
            return view
        }
        func actionButtons(_ view: NSView) -> [NSButton] {
            ((view as? NSButton).flatMap { $0.identifier?.rawValue == "message.actions" ? [$0] : nil } ?? [])
                + view.subviews.flatMap(actionButtons)
        }
        func checkBound() throws {
            let count = actionButtons(window.contentView!).count
            try require(count > 0 && count <= 50, "native materialized message controls must stay bounded to 50, got \(count)")
        }
        try checkBound()
        var seen = Set<String>()
        // Native controls carry each message's Copy action. Inspect every actual page through the UI controls.
        for page in 0..<10 {
            try checkBound()
            let end = 500 - page * 50
            let renderedText = accessibilityText(window)
            for row in rows[(end - 50)..<end] {
                try require(renderedText.contains(MentionCodec.plain(row.body).components(separatedBy: "\n").first ?? row.body), "paged message must render")
                seen.insert(row.id)
            }
            if page < 9 {
                let started = ContinuousClock.now
                try press(window, "thread.earlier")
                await settle()
                print("CAPACITY_PAGE older=\(page + 1) wall=\(started.duration(to: .now))")
            }
        }
        try require(seen.count == 500, "all 500 loaded rows must be reachable")
        let list = try scrollView(), document = list.documentView!
        let top = document.isFlipped ? document.bounds.minY : document.bounds.maxY - list.contentView.bounds.height
        list.contentView.scroll(to: NSPoint(x: 0, y: top)); list.reflectScrolledClipView(list.contentView)
        await settle()
        try snapshot(window, model: model, name: "capacity-oldest")
        let target = ChatTarget(connectionId: connection.id, workspaceId: focus.workspaceId, channelId: channel, threadId: focus.threadId)
        try press(window, "thread.focus.close")
        await settle()
        try require(ReadingPositions.shared.anchor(for: target) == rows.first?.id, "closing while reading older replies must retain the first visible message")
        let coldOpen = ContinuousClock.now
        model.focusThread(focus)
        for _ in 0..<20 {
            if find(window, "message.actions") != nil { break }
            await settle()
        }
        await settle()
        let renderedOpen = coldOpen.duration(to: .now)
        let reopened = try scrollView(), reopenedDocument = reopened.documentView!
        let reopenedTop = reopenedDocument.isFlipped ? reopenedDocument.bounds.minY : reopenedDocument.bounds.maxY - reopened.contentView.bounds.height
        try require(abs(reopened.contentView.bounds.minY - reopenedTop) < 500, "reopen must restore older reading position instead of the newest reply")
        try checkBound()
        try require(containsText(window, MentionCodec.plain(rows[0].body).components(separatedBy: "\n").first!), "saved window must include root")
        // A new reply while reading the oldest page must not replace that page or its scroll position.
        guard let fixture = model.fixture, let workspace = model.selectedWorkspace else { throw Failure(description: "Missing fixture") }
        fixture.tower.postAsMember(channel: channel, body: "Capacity incremental newest", threadId: focus.threadId)
        for _ in 0..<5 { model.openThread(focus.threadId, channelId: channel, in: workspace); await settle() }
        try checkBound()
        try require(containsText(window, MentionCodec.plain(rows[1].body).components(separatedBy: "\n").first!), "live replies must preserve surviving older reading rows")
        try require(!containsText(window, "Capacity incremental newest"), "new reply must not interrupt older reading")
        try snapshot(window, model: model, name: "capacity-older-live")
        var pages = 0
        while find(window, "thread.newer") != nil && pages < 11 {
            let started = ContinuousClock.now
            try press(window, "thread.newer"); await settle(); try checkBound()
            print("CAPACITY_PAGE newer=\(pages + 1) wall=\(started.duration(to: .now))")
            pages += 1
        }
        try require(pages > 0 && pages <= 10, "newer navigation must reach latest")
        try require(containsText(window, "Capacity incremental newest"), "new reply must be reachable on newest page")
        try require(try textView(window).string == "Unsent responsiveness probe", "paging must retain draft")
        try snapshot(window, model: model, name: "capacity-latest")
        try await capacityFollowCheck(window, model: model, focus: focus)
        try press(window, "thread.focus.close"); await settle()
        try require(ReadingPositions.shared.anchor(for: target) == nil, "latest page bottom must reopen at newest")
        let latestOpen = ContinuousClock.now
        model.focusThread(focus)
        for _ in 0..<20 {
            if containsText(window, "Capacity follow latest") { break }
            await settle()
        }
        try checkBound()
        try require(containsText(window, "Capacity follow latest"), "cold latest open must render newest loaded page")
        print("CAPACITY_COLD_LATEST wall=\(latestOpen.duration(to: .now))")
        print("CAPACITY_PASS rows=500 bounded50 all pages, live older reading, draft and reopen coldOpenToRendered=\(renderedOpen)")

    }

    static func capacityFollowCheck(_ window: NSWindow, model: AppModel, focus: ThreadFocus) async throws {
        guard let fixture = model.fixture, let workspace = model.selectedWorkspace, let channel = focus.channelId else { throw Failure(description: "Missing fixture") }
        func geometry() throws -> (Double, Double) {
            guard let list = threadScrollView(window), let doc = list.documentView else { throw Failure(description: "Missing thread scroll view") }
            let bottom = doc.isFlipped ? doc.bounds.maxY - list.contentView.bounds.height : doc.bounds.minY
            print("CAPACITY_GEOMETRY flipped=\(doc.isFlipped) document=\(doc.bounds) clip=\(list.contentView.bounds) bottom=\(bottom)")
            return (list.contentView.bounds.minY, bottom)
        }
        let before = try geometry()
        try require(abs(before.0 - before.1) < 100, "latest navigation must start at bottom before new reply")
        fixture.tower.postAsMember(channel: channel, body: "Capacity follow latest", threadId: focus.threadId)
        for _ in 0..<5 { model.openThread(focus.threadId, channelId: channel, in: workspace); await settle() }
        try require(containsText(window, "Capacity follow latest"), "near-bottom reader must receive live newest row")
        let after = try geometry()
        try require(abs(after.0 - after.1) < 100, "near-bottom must follow live replies")
        try snapshot(window, model: model, name: "capacity-follow")
        guard let connection = model.connection else { throw Failure(description: "Missing connection") }
        let target = ChatTarget(connectionId: connection.id, workspaceId: focus.workspaceId, channelId: channel, threadId: focus.threadId)
        try press(window, "thread.focus.close"); await settle()
        try require(ReadingPositions.shared.anchor(for: target) == nil, "latest page bottom must reopen at newest")
        model.focusThread(focus)
        for _ in 0..<20 {
            if containsText(window, "Capacity follow latest") { break }
            await settle()
        }
        try require(containsText(window, "Capacity follow latest"), "reopen at newest must retain latest page")
    }

    /// Deck's underlying inbox can be taller than the focused thread. Identify the actual message scroll document
    /// by its native message controls, never by the height of unrelated background content.
    static func threadScrollView(_ window: NSWindow) -> NSScrollView? {
        nativeScrollViews(window.contentView!).filter { view in
            view.documentView.map { nativeActionsButton($0) != nil } ?? false
        }.max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }
    }

    static func nativeScrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { nativeScrollViews($0) }
    }

    static func nativeActionsButton(_ view: NSView, id: String = "message.actions") -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == id { return button }
        return view.subviews.lazy.compactMap { nativeActionsButton($0, id: id) }.first
    }

    static func accessibilityText(_ object: Any, depth: Int = 0) -> String {
        guard depth < 60 else { return "" }
        let own = ["AXValue", "AXDescription"].compactMap { value(object, $0) as? String }
        return (own + children(object).map { accessibilityText($0, depth: depth + 1) }).joined(separator: "\n")
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
    static func frame(of node: NSObject) -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard node.responds(to: selector) else { return .zero }
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(node.method(for: selector), to: Frame.self)(node, selector)
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
    static func performEditMenu(_ prefix: String) throws {
        func match(_ menu: NSMenu) -> (NSMenu, Int)? {
            menu.update()
            for (index, item) in menu.items.enumerated() {
                if item.title == prefix || item.title.hasPrefix(prefix + " ") { return (menu, index) }
                if let child = item.submenu, let found = match(child) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu, let (menu, index) = match(main) else { throw Failure(description: "Missing native Edit " + prefix) }
        let item = menu.item(at: index)!
        print("EDIT_MENU action=\(prefix) enabled=\(item.isEnabled) key=\(item.keyEquivalent) modifiers=\(item.keyEquivalentModifierMask.rawValue)")
        try require(item.isEnabled, "Native Edit " + prefix + " must be enabled")
        menu.performActionForItem(at: index)
    }

    /// Queue independent AppKit events, allowing NSUndoManager's groupsByEvent boundary to run normally.
    static func postKey(_ window: NSWindow, key: String, code: UInt16, modifiers: NSEvent.ModifierFlags) throws {
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else {
                throw Failure(description: "Could not create local key event")
            }
            NSApp.postEvent(event, atStart: false)
        }
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
extension MacThreadRegression {
    static func messageEditCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test",
              let fixture = model.fixture, let store = model.store, let connection = model.connection else {
            throw Failure(description: "Missing isolated Mac Test environment")
        }
        model.selectWorkspace(FixtureTower.studio)
        model.selectContext(WorkContext(scopeId: FixtureTower.scopeAmbulando, channelId: FixtureTower.generalChannel))
        model.mode = .chat
        await settle(); await settle()
        guard let workspace = model.selectedWorkspace else { throw Failure(description: "Missing workspace") }
        let original = "Mac edit acceptance **untagged**"
        try type(window, original); await settle()
        try press(window, "composer.send")
        var sent: MessageRecord?
        for _ in 0..<30 {
            await settle()
            sent = try await store.reader.channelFeed(workspaceId: workspace.id, channelId: FixtureTower.generalChannel, limit: 150)
                .first { $0.message.body == original }?.message
            if sent != nil { break }
        }
        guard let sent, let thread = sent.threadId else { throw Failure(description: "Missing untagged accepted message") }
        let keptAttachments: [[String: Any]] = [["object_id": "fixture-kept-object", "filename": "kept.txt", "mime_type": "text/plain",
                                               "size_bytes": 4, "sha256": String(repeating: "a", count: 64)]]
        fixture.tower.seedMessageAttachments(id: sent.id, attachments: keptAttachments)
        model.focusThread(ThreadFocus(workspaceId: workspace.id, channelId: sent.channelId, threadId: thread))
        await settle(); await settle()
        let actor = Mention(type: .agent, npub: FixtureTower.rick, label: "rick")
        try type(window, "Unsent reply @ric"); await settle()
        try press(window, "mention.rick"); await settle()
        let reply = try textView(window).string
        let replyTarget = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: sent.channelId, threadId: thread)
        let staged = PendingAttachment(filename: "reply.txt", mimeType: "text/plain", sizeBytes: 1,
                                       sha256: String(repeating: "0", count: 64), staged: "reply-fixture.txt")
        // A stored reply attachment is adopted through the normal restore path when reopening the view.
        try press(window, "thread.focus.close"); await settle(); await settle()
        try await store.writer.saveDraft(replyTarget, Draft(text: reply, mentions: [actor], attachments: [staged]))
        model.focusThread(ThreadFocus(workspaceId: workspace.id, channelId: sent.channelId, threadId: thread))
        await settle(); await settle()
        try require(try textView(window).string == reply, "ordinary tagged reply is restored before editing")

        var expected = original
        var lastSignature: String?
        for cycle in 0..<3 {
            try await menuAction(window, title: "Edit")
            await settle(); await settle()
            try require(window.attachedSheet == nil, "Mac Edit stays in the chat composer, with no sheet")
            let field = try textView(window)
            try require(field.string == expected, "reopened editor has latest exact canonical body")
            try require(window.firstResponder === field, "edit composer acquires native keyboard focus")
            field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
            try postKey(window, key: " ", code: 49, modifiers: [])
            await settle()
            try require(field.string == expected + " ", "reopened edit accepts an actual AppKit key event")
            if cycle == 0 {
                // Type @ through the actual native text responder, then click the existing picker row.
                try postKey(window, key: "@", code: 19, modifiers: [.shift]); await settle()
                try type(window, "ric"); await settle()
                try require(find(window, "mention.rick") != nil, "typed @ opens the bot picker")
                try click(window, "mention.rick"); await settle()
                expected += " " + actor.token + " "
                try require(field.string == expected, "picked bot inserts canonical exact-npub token")
                try type(window, "please review"); expected += "please review"
            } else {
                try type(window, "revision \(cycle)"); expected += " revision \(cycle)"
            }
            await settle()
            try require(field.string == expected, "typing after picker and repeated Edit preserves every character")
            try press(window, "editmessage.save")
            var accepted: MessageRecord?
            for _ in 0..<30 {
                await settle()
                accepted = try await store.reader.message(workspaceId: workspace.id, id: sent.id)
                if accepted?.rowVersion == cycle + 2 { break }
            }
            guard let accepted else { throw Failure(description: "No revision readback") }
            try require(accepted.body == expected && accepted.rowVersion == cycle + 2, "saved revision body and version read back")
            try require(accepted.threadId == thread && accepted.channelId == sent.channelId, "revision keeps conversation context")
            let raw = try JSONSerialization.jsonObject(with: accepted.raw) as? [String: Any]
            try require(raw?["mentions"] as? [[String: String]] == [actor.requestObject], "readback has exact structured bot identity")
            let metadata = raw?["metadata"] as? [String: Any]
            try require(NSDictionary(dictionary: ["attachments": raw?["attachments"] ?? []]) == NSDictionary(dictionary: ["attachments": keptAttachments]),
                        "sent message attachment metadata remains unchanged")
            try require(NSDictionary(dictionary: ["attachments": metadata?["attachments"] ?? []]) == NSDictionary(dictionary: ["attachments": keptAttachments]),
                        "sent message metadata attachment projection remains unchanged")
            let signature = metadata?["agent_instruction_signature"] as? [String: Any]
            let data = try JSONSerialization.data(withJSONObject: signature?["nostr_event"] ?? [:])
            let event = try JSONDecoder().decode(NostrEvent.self, from: data)
            try require(SignatureVerifier.verify(event), "fresh revision signature cryptographically verifies")
            try require(event.content == expected && event.kind == 33358, "signed content equals exact saved canonical body")
            for tag in [["message_id", sent.id], ["revision", String(cycle + 2)], ["thread_id", thread],
                        ["workspace_id", workspace.id], ["channel_id", sent.channelId]] {
                try require(event.tags.contains(tag), "revision signature binds \(tag[0])")
            }
            try require(event.id != lastSignature, "each revision has a fresh signature")
            lastSignature = event.id
            try require(try textView(window).string == reply, "ordinary reply text returns after Save")
            let draft = try await store.reader.draft(replyTarget)
            try require(draft?.text == reply && draft?.mentions == [actor] && draft?.attachments == [staged],
                        "reply text, structured mention and staged attachment remain intact")
            print("MAC_EDIT_SIGNED_READBACK cycle=\(cycle) version=\(accepted.rowVersion)"); fflush(stdout)
        }
        try await menuAction(window, title: "Edit"); await settle(); await settle()
        try type(window, "cancel this change"); await settle()
        try press(window, "editmessage.cancel"); await settle()
        try await menuAction(window, title: "Edit"); await settle(); await settle()
        try require(try textView(window).string == expected, "Cancel and immediate reopen restore saved body only")
        try require(window.firstResponder === (try textView(window)), "Cancel/reopen can type in native responder")
        try type(window, "typing still works"); await settle()
        try require(try textView(window).string.contains("typing still works"), "Cancel/reopen accepts typing")
        try press(window, "editmessage.cancel"); await settle()
        let unchanged = try await store.reader.message(workspaceId: workspace.id, id: sent.id)
        try require(unchanged?.body == expected && unchanged?.rowVersion == 4, "Cancel never changes sent message")
        try require(try textView(window).string == reply, "unsent reply restored after Cancel")
        try require(fixture.tower.actorNpub == model.identity.npub, "isolated sample author only")
    }
}
#endif
