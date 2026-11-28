#if DEBUG
import AppKit
import AmbulandoCore

extension MacThreadRegression {
    /// Exercises rendered row callbacks, AppKit menu tracking, ReminderSheet and signed task persistence.
    /// The optional fault installs the actual root callback on the reply button to prove the assertion goes red.
    static func reminderIdentityCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test",
              let fixture = model.fixture, let workspace = model.selectedWorkspace,
              let store = model.store, let sync = model.sync, let connection = model.connection else {
            throw Failure(description: "Reminder identity check requires isolated Test fixture")
        }
        let clipboard = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let clipboard { NSPasteboard.general.setString(clipboard, forType: .string) }
        }
        print("REMINDER_FIXTURE_DIRECTORY \(fixture.directory.path)")
        // This check needs an existing self conversation, as the product deliberately never creates one for reminders.
        guard let manager = model.manager else { throw Failure(description: "fixture management unavailable") }
        _ = try await manager.createDirectMessage(connection, workspace, scopeId: FixtureTower.scopeDMs, participantNpub: connection.signerNpub)
        let thread = FixtureTower.threadReview
        await sync.refreshThread(connection, workspace, channelId: FixtureTower.generalChannel, threadId: thread)
        for _ in 0..<30 {
            if try await store.reader.threadMessages(workspaceId: workspace.id, threadId: thread, limit: 500).count >= 4 { break }
            await settle()
        }
        let rows = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: thread, limit: 500)
        guard let root = rows.first(where: { $0.isThreadRoot }), let reply = rows.first(where: { !$0.isThreadRoot }) else {
            throw Failure(description: "Distinct root/reply fixture missing")
        }
        try require(root.id != reply.id && root.body != reply.body, "distinct root/reply IDs and bodies")
        model.focusThread(ThreadFocus(workspaceId: workspace.id, channelId: root.channelId, threadId: thread))
        await settle(); await settle()
        guard let document = threadScrollView(window)?.documentView else { throw Failure(description: "Missing actual thread rows") }
        func buttons(_ view: NSView) -> [NSButton] {
            ((view as? NSButton).flatMap { $0.identifier?.rawValue == "message.actions" ? [$0] : nil } ?? []) + view.subviews.flatMap(buttons)
        }
        // Identify the real rendered row by its existing Copy action, not traversal order or the shared root ID.
        var rootButton: NSButton?, replyButton: NSButton?
        for button in buttons(document) {
            try await reminderMenu(button, title: "Copy message")
            let text = NSPasteboard.general.string(forType: .string)
            if text == MentionCodec.plain(root.body) { rootButton = button }
            if text == MentionCodec.plain(reply.body) { replyButton = button }
        }
        guard let rootButton, let replyButton else { throw Failure(description: "Actual root and reply menu buttons missing") }
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacReminderRootFault") {
            guard let from = rootButton.target as? NativeMessageActions.Coordinator,
                  let to = replyButton.target as? NativeMessageActions.Coordinator else { throw Failure(description: "Missing native coordinators") }
            to.items = from.items
            print("REMINDER_ROOT_FAULT installed actual root callbacks on reply button")
        }
        try await reminderMenu(replyButton, title: "Remind me")
        try await verifyReminderSheet(window, model: model, expected: reply, other: root)
        try await menuAction(window, title: "Remind me", button: "thread.focus.actions")
        try await verifyReminderSheet(window, model: model, expected: root, other: reply)
        print("REMINDER_IDENTITY_PASS actual reply native menu saves reply body/ID/link; header saves root body/ID/link")
    }

    private static func verifyReminderSheet(_ window: NSWindow, model: AppModel, expected: MessageRecord, other: MessageRecord) async throws {
        guard let store = model.store else { throw Failure(description: "Missing reminder store") }
        for _ in 0..<30 {
            if let sheet = window.attachedSheet, containsText(sheet, "Saved to Reminders") { break }
            await settle()
        }
        guard let sheet = window.attachedSheet else { throw Failure(description: "Reminder sheet missing") }
        try require(containsText(sheet, "Saved to Reminders"), "reminder persistence confirmed: \(accessibilityText(sheet))")
        let tasks = try await store.reader.tasks(workspaceId: expected.workspaceId)
        let matches = tasks.filter { task in
            guard let raw = try? JSONSerialization.jsonObject(with: task.raw) as? [String: Any],
                  let metadata = raw["metadata"] as? [String: Any], let source = metadata["ambulando_reminder"] as? [String: Any] else { return false }
            return source["message_id"] as? String == expected.id
        }
        try require(matches.count == 1, "selected menu must persist expected source ID \(expected.id), not \(other.id)")
        let task = matches[0]
        try require(task.description == Reminders.description(body: expected.body, channel: expected.channelId, message: expected.id), "selected source body and native reference must match exactly")
        try require(task.state == "ready" && task.assignedToNpub == model.identity.npub, "Ready task belongs to human")
        func closeButton(_ object: Any, depth: Int = 0) -> NSObject? {
            guard depth < 60 else { return nil }
            if value(object, "AXRole") as? String == "AXButton", value(object, "AXTitle") as? String == "Close" || value(object, "AXDescription") as? String == "Close" { return object as? NSObject }
            return children(object).lazy.compactMap { closeButton($0, depth: depth + 1) }.first
        }
        guard let close = closeButton(sheet) else { throw Failure(description: "Missing Close button") }
        close.perform(NSSelectorFromString("accessibilityPerformPress"))
        await settle()
        try require(window.attachedSheet == nil, "reminder sheet closes")
    }

    private static func reminderMenu(_ button: NSButton, title: String) async throws {
        let selected = MacRegressionMemory<Bool>()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
            let tracked = MacRegressionMemory<NSMenu>(); tracked.save(notification.object as? NSMenu)
            MainActor.assumeIsolated {
                let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        guard let menu = tracked.load() else { return }
                        if let index = menu.items.firstIndex(where: { $0.title == title }) { menu.performActionForItem(at: index); selected.save(true) }
                        menu.cancelTracking()
                    }
                }
                RunLoop.main.add(timer, forMode: .eventTracking); RunLoop.main.add(timer, forMode: .common)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        button.performClick(nil)
        await settle()
        try require(selected.load() == true, "actual row native menu executes \(title)")
    }
}
#endif
