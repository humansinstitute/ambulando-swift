#if DEBUG
import AppKit
import AmbulandoCore

// Task-owned opt-in transport delay, switched only after the cache is populated.
enum MacRemindersFixture {
    static let slowTransport = MacRegressionMemory<Bool>()
}

extension MacThreadRegression {
    static func remindersCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", let fixture = model.fixture,
              let workspace = model.selectedWorkspace, let store = model.store, let connection = model.connection,
              let manager = model.manager, let sync = model.sync else { throw Failure(description: "isolated Test fixture required") }
        print("REMINDERS_FIXTURE_DIRECTORY \(fixture.directory.path)")
        let board = try await manager.createDirectMessage(connection, workspace, scopeId: FixtureTower.scopeDMs, participantNpub: connection.signerNpub)
        let personal = fixture.tower.work.seedTask(scope: board.scopeId, channel: board.id, title: "Personal reminder", state: "ready", assignee: connection.signerNpub)
        let other = fixture.tower.work.seedTask(scope: FixtureTower.scopeAmbulando, channel: FixtureTower.generalChannel, title: "Shared reminder", state: "new", assignee: connection.signerNpub)
        fixture.tower.work.seedTask(scope: FixtureTower.scopeAmbulando, channel: FixtureTower.designChannel, title: "Other person excluded", state: "ready", assignee: FixtureTower.ana)
        await sync.refreshTasks(connection, workspace, force: true)
        for _ in 0..<150 {
            if try await store.reader.task(workspaceId: workspace.id, id: personal) != nil,
               try await store.reader.task(workspaceId: workspace.id, id: other) != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let cached = try await store.reader.task(workspaceId: workspace.id, id: personal)
        try require(cached != nil, "cache populated before delayed navigation")
        model.showWorkspaceHome(); await settle()
        MacRemindersFixture.slowTransport.save(true)
        let started = ContinuousClock.now
        try press(window, "sidebar.reminders")
        let routed = started.duration(to: .now)
        try require(model.remindersSelected, "actual click sets destination synchronously")
        for _ in 0..<35 {
            if find(window, "reminder.Personal reminder") != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let populated = started.duration(to: .now)
        print("REMINDERS_TIMING delayed1500ms route=\(routed) firstCachedRow=\(populated)")
        try require(populated < .milliseconds(750), "cached row visible within750ms while network delayed")
        try require(find(window, "reminders.list") != nil && find(window, "reminders.divider") != nil, "native list with divider")
        try require(find(window, "reminder.Shared reminder") != nil, "cross-channel own task included")
        try require(find(window, "reminder.Other person excluded") == nil, "other assignee excluded")
        try snapshot(window, model: model, name: "reminders-list")
        MacRemindersFixture.slowTransport.save(false)
        fixture.offline = true
        model.showWorkspaceHome(); await settle()
        let offlineStart = ContinuousClock.now
        try press(window, "sidebar.reminders")
        try await waitFor(window, "reminder.Personal reminder", "offline cached list", seconds: 2)
        print("REMINDERS_TIMING offlineCached=\(offlineStart.duration(to: .now))")
        try press(window, "reminder.Personal reminder")
        try await waitFor(window, "task.assignee", "existing task detail")
        try require(model.tasksPath.last == .task(workspaceId: workspace.id, taskId: personal), "canonical detail identity")
        try press(window, "task.assignee")
        let picker = try await assigneeWindow()
        try await searchAssignee(picker, "Ana")
        try require(find(picker, "task.assignee.option.\(FixtureTower.ana)") != nil, "display name filters eligible member")
        try require(find(picker, "task.assignee.option.\(FixtureTower.rick)") == nil, "unmatched agent hidden")
        try press(picker, "task.assignee.cancel"); await settle()
        let afterCancel = try await store.reader.writes(connectionId: connection.id, workspaceId: workspace.id, targetId: personal)
        try require(afterCancel.isEmpty, "cancel never queues assignment")
        try press(window, "task.assignee")
        let picker2 = try await assigneeWindow()
        try await searchAssignee(picker2, "Ana")
        try snapshot(picker2, model: model, name: "assignee-typeahead")
        try press(picker2, "task.assignee.option.\(FixtureTower.ana)")
        try press(picker2, "task.assignee.save"); await settle()
        model.tasksPath.removeLast(); await settle()
        try require(find(window, "reminder.Personal reminder") == nil, "offline reassignment removes row immediately")
        let queued = try await store.reader.writes(connectionId: connection.id, workspaceId: workspace.id, targetId: personal)
        try require(queued.contains { $0.kind == .taskAssign && $0.isPending }, "existing durable assignment queue")
        fixture.offline = false
        await model.writes?.kick(connection, force: true)
        for _ in 0..<100 {
            let current = try await store.reader.task(workspaceId: workspace.id, id: personal)
            if current?.assignedToNpub == FixtureTower.ana { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        let assigned = try await store.reader.task(workspaceId: workspace.id, id: personal)
        try require(assigned?.assignedToNpub == FixtureTower.ana, "selection persisted through existing sender")
        fixture.tower.work.externalTaskEdit(personal, fields: ["assigned_to_npub": connection.signerNpub])
        await sync.refreshTasks(connection, workspace, force: true)
        try await waitFor(window, "reminder.Personal reminder", "live reassignment restores row", seconds: 10)
        fixture.tower.work.externalTaskEdit(personal, fields: ["state": "review"])
        await sync.refreshTasks(connection, workspace, force: true)
        for _ in 0..<100 {
            if find(window, "reminder.Personal reminder") == nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try require(find(window, "reminder.Personal reminder") == nil, "live review status removes row")
        // Keyboard staging uses the real field editor and SwiftUI submit/key handlers.
        fixture.offline = true
        try press(window, "reminder.Shared reminder")
        try await waitFor(window, "task.assignee", "shared task detail")
        try press(window, "task.assignee")
        let keyboardPicker = try await assigneeWindow()
        try await searchAssignee(keyboardPicker, "Rick")
        try reminderKey(keyboardPicker, key: "\u{f701}", code: 125, modifiers: [])
        await settle()
        try reminderKey(keyboardPicker, key: "\u{f700}", code: 126, modifiers: [])
        await settle()
        try reminderKey(keyboardPicker, key: "\r", code: 36, modifiers: [])
        await settle()
        let directory = try await store.reader.directoryMembers(workspaceId: workspace.id)
        let people = try await store.reader.people(workspaceId: workspace.id)
        let expected = directory.first { people.person($0.npub).name.localizedStandardContains("Rick") || $0.label.localizedStandardContains("Rick") || $0.npub.localizedCaseInsensitiveContains("Rick") }
        try require(expected != nil, "eligible keyboard option")
        try press(keyboardPicker, "task.assignee.save"); await settle(); await settle()
        let keyboardWrites = try await store.reader.writes(connectionId: connection.id, workspaceId: workspace.id, targetId: other)
        guard let keyboardWrite = keyboardWrites.first(where: { $0.kind == .taskAssign }) else { throw Failure(description: "keyboard selection must queue assignment") }
        try require(keyboardWrite.string("assigned_to_npub") == expected?.npub, "Up/Down/Return staged the highlighted option")
        let allAssignments = try await store.reader.writes(connectionId: connection.id, workspaceId: workspace.id).filter { $0.kind == .taskAssign }
        let firstUnchanged = try await store.reader.task(workspaceId: workspace.id, id: personal)
        try require(allAssignments.map(\.targetId) == [other] && firstUnchanged?.assignedToNpub == connection.signerNpub,
            "only the second task receives the keyboard assignment; first task remains unchanged")
        // The canonical queue failure is the existing sender's rollback boundary. No fake UI state is substituted.
        try await store.writer.markWrite(id: keyboardWrite.id, state: .failed, status: 403, code: "forbidden", error: "Synthetic assignment rejected")
        model.tasksPath.removeLast(); await settle(); await settle()
        try await waitFor(window, "reminder.Shared reminder", "failed assignment rolls back to list")
        try require(containsText(window, "Synthetic assignment rejected"), "failed write visibly explained")
        try await store.writer.discardWrite(id: keyboardWrite.id)
        try press(window, "reminder.Shared reminder")
        try await waitFor(window, "task.assignee", "unassign detail")
        try press(window, "task.assignee")
        let escapePicker = try await assigneeWindow()
        try reminderKey(escapePicker, key: "\u{1b}", code: 53, modifiers: [])
        await settle(); await settle()
        try require(!NSApp.windows.contains { $0.isVisible && find($0, "task.assignee.search") != nil }, "Escape cancels picker")
        try press(window, "task.assignee")
        let unassignPicker = try await assigneeWindow()
        try press(unassignPicker, "task.assignee.unassign")
        try press(unassignPicker, "task.assignee.save"); await settle(); await settle()
        model.tasksPath.removeLast(); await settle()
        try require(find(window, "reminder.Shared reminder") == nil, "pending unassign removes row")
        fixture.offline = false
        await model.writes?.kick(connection, force: true)
        for _ in 0..<100 {
            if try await store.reader.task(workspaceId: workspace.id, id: other)?.assignedToNpub == nil { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        let unassigned = try await store.reader.task(workspaceId: workspace.id, id: other)
        try require(unassigned?.assignedToNpub == nil, "unassign persisted")
        // Tombstone/access notification reaches the active query, not just a reopened destination.
        fixture.tower.work.externalTaskEdit(personal, fields: ["state": "ready"])
        await sync.refreshTasks(connection, workspace, force: true)
        try await waitFor(window, "reminder.Personal reminder", "ready state restores row", seconds: 10)
        fixture.offline = true
        try await store.writer.applyTombstones(workspaceId: workspace.id, [.task(personal)])
        await settle(); await settle()
        try require(find(window, "reminder.Personal reminder") == nil, "active query removes access-deleted task")
        fixture.offline = false
        fixture.tower.work.externalTaskEdit(other, fields: ["assigned_to_npub": connection.signerNpub])
        await sync.refreshTasks(connection, workspace, force: true)
        try await waitFor(window, "reminder.Shared reminder", "populated list before lock and workspace switch", seconds: 10)
        fixture.offline = true
        await model.lock(); await settle()
        try require(find(window, "reminder.Shared reminder") == nil, "lock immediately hides populated cached row")
        await model.unlock(pin: FixtureEnvironment.pin)
        model.showReminders()
        try await waitFor(window, "reminder.Shared reminder", "unlock restores same workspace cache", seconds: 10)
        try press(window, "reminder.Shared reminder")
        try await waitFor(window, "task.assignee", "populated task before workspace switch")
        try press(window, "task.assignee")
        _ = try await assigneeWindow()
        model.selectWorkspace(FixtureTower.lab)
        for _ in 0..<100 {
            if model.selectedWorkspace?.id == FixtureTower.lab { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try require(model.selectedWorkspace?.id == FixtureTower.lab && find(window, "reminder.Shared reminder") == nil, "workspace switch excludes old rows")
        for _ in 0..<25 {
            if !NSApp.windows.contains(where: { $0.isVisible && find($0, "task.assignee.search") != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(!NSApp.windows.contains { $0.isVisible && find($0, "task.assignee.search") != nil }, "workspace boundary clears open assignee picker")
        model.showReminders(); await settle()
        try require(find(window, "reminder.Personal reminder") == nil, "new workspace reminder query isolated")
        await model.lock(); await settle()
        try require(find(window, "reminder.Personal reminder") == nil && find(window, "reminder.Shared reminder") == nil, "lock hides cached rows")
        print("REMINDERS_PASS delayed/offline cache list; own cross-channel partition; canonical detail; avatar typeahead filter/cancel/select/offline persistence; keyboard arrows/Return/Escape; failure rollback; unassign; live reassignment/status/tombstone; workspace switch/lock")

    }

    /// Deliver native events to the real popover window. The unsigned Test app cannot claim
    /// global keyboard focus on every host; posting to NSApp would send to another app/window.
    private static func reminderKey(_ window: NSWindow, key: String, code: UInt16, modifiers: NSEvent.ModifierFlags) throws {
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else { throw Failure(description: "native keyboard event") }
            if kind == .keyDown, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                editor.interpretKeyEvents([event])
            } else { window.sendEvent(event) }
        }
    }

    private static func assigneeWindow() async throws -> NSWindow {
        for _ in 0..<50 {
            if let window = NSApp.windows.first(where: { $0.isVisible && find($0, "task.assignee.search") != nil }) { return window }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failure(description: "Missing native assignee popover")
    }

    private static func searchAssignee(_ window: NSWindow, _ query: String) async throws {
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let node = find(window, "task.assignee.search"), let content = window.contentView else { throw Failure(description: "search field") }
        let bounds = frame(of: node), center = NSPoint(x: bounds.midX, y: bounds.midY)
        guard let field = node as? NSTextField ?? fields(content).first(where: { $0.isEditable && window.convertToScreen($0.convert($0.bounds, to: nil)).contains(center) }) else { throw Failure(description: "native search NSTextField") }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw Failure(description: "search field editor") }
        editor.selectAll(nil); editor.insertText(query, replacementRange: editor.selectedRange())
        await settle()
    }
}
#endif
