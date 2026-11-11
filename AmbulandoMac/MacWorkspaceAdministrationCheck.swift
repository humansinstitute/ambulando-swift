#if DEBUG
import AmbulandoCore
import AppKit
import SwiftUI

extension MacThreadRegression {
    static func directMessageCheck(_ window: NSWindow, model: AppModel) async throws {
        guard let workspace = model.selectedWorkspace, let store = model.store else { throw Failure(description: "Sample workspace") }
        model.selectContext(WorkContext(scopeId: FixtureTower.scopeDMs))
        model.show(.deck)
        await settle(); await settle()
        try press(window, "deck.inbox.new"); await settle(); await settle()
        guard let picker = window.attachedSheet else { throw Failure(description: "DM plus must open recipient sheet") }
        try require(find(picker, "deck.compose.channel") == nil, "scope plus must not choose an existing channel")
        guard let createControl = find(picker, "newChannel.create") else { throw Failure(description: "Create control") }
        let enabledSelector = NSSelectorFromString("isAccessibilityEnabled")
        typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
        let enabled = unsafeBitCast(createControl.method(for: enabledSelector), to: Enabled.self)
        try require(!enabled(createControl, enabledSelector), "empty selection disables Create")
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureDMDirectoryEmpty") || ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureDMDirectoryFail") {
            for _ in 0..<30 where find(picker, "newChannel.empty") == nil { await settle() }
            try require(find(picker, "newChannel.empty") != nil, "empty/error directory is explained")
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureDMDirectoryFail") {
                try require(find(picker, "newChannel.retryPeople") != nil, "directory failure offers Retry")
            }
            try press(picker, "newChannel.cancel"); await settle()
            try require(window.attachedSheet == nil, "cancel closes empty/error picker")
            return
        }
        try press(picker, "newChannel.cancel"); await settle()
        try require(window.attachedSheet == nil, "cancel closes recipient picker")
        try require(model.context.channelId == nil && model.mode == .deck, "cancel keeps DM scope")
        try press(window, "deck.inbox.new"); await settle(); await settle()
        guard let create = window.attachedSheet else { throw Failure(description: "Reopened picker") }
        try press(create, "newChannel.recipient.\(FixtureTower.rick)"); await settle()
        try snapshot(create, model: model, name: "dm-deck-picker")
        try press(create, "newChannel.create"); await settle(); await settle()
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureDMCreateFail") {
            try require(find(create, "manage.error") != nil, "creation failure stays visible")
            try require(find(create, "newChannel.recipient.\(FixtureTower.rick)") != nil, "recipient retained after failure")
            try press(create, "newChannel.cancel"); await settle()
            try require(model.context.channelId == nil, "failed creation does not navigate")
            return
        }
        guard let id = model.context.channelId else { throw Failure(description: "Created DM selected") }
        let rows = try await store.reader.channels(workspaceId: workspace.id)
        guard let dm = rows.first(where: { $0.id == id }) else { throw Failure(description: "Created DM stored") }
        try require(SidebarNavigation.participants(dm) == [model.connection!.signerNpub, FixtureTower.rick].sorted(), "exact private participants")
        try require(model.mode == .chat && window.attachedSheet == nil, "created conversation opens in Chat")
        for _ in 0..<20 where model.navigation.value.channel(id) == nil { await settle() }
        try require(model.navigation.value.channel(id) != nil, "sidebar refreshes immediately")
        // Exercise real SQLite profile invalidation in both selected and stacked navigation.
        let hex = NostrKeys.publicKeyHex(npub: FixtureTower.rick)!
        for (offset, name) in ["Cached DM profile", "Updated DM profile"].enumerated() {
            let profile = ProfileRecord(pubkey: hex, npub: FixtureTower.rick, displayName: name, name: "handle",
                                        eventId: String(repeating: "1", count: 64), eventCreatedAt: Int(Date().timeIntervalSince1970) + offset + 10,
                                        status: .found, checkedAt: Date())
            try await store.writer.recordProfileCheck(connectionId: model.connection!.id, found: [profile], checked: [hex: FixtureTower.rick], at: Date())
            for _ in 0..<30 where model.navigation.value.labels[id] != name { await settle() }
            try require(model.navigation.value.labels[id] == name, "selected DM label reacts to profile change")
            for _ in 0..<30 where model.workspaceEntries.first(where: { $0.workspace.id == workspace.id })?.navigation.labels[id] != name { await settle() }
            try require(model.workspaceEntries.first(where: { $0.workspace.id == workspace.id })?.navigation.labels[id] == name, "stacked DM label reacts to profile change")
            try require(containsText(window, name), "profile name is rendered in actual conversation")
        }
        let unchanged = try await store.reader.channels(workspaceId: workspace.id).first(where: { $0.id == id })
        try require(unchanged?.name == dm.name, "profile rendering never rewrites channel records")
        model.selectContext(WorkContext(scopeId: FixtureTower.scopeDMs)); model.show(.deck)
        await settle(); await settle()
        try press(window, "deck.inbox.new"); await settle(); await settle()
        guard let reuse = window.attachedSheet else { throw Failure(description: "Reuse picker") }
        try press(reuse, "newChannel.recipient.\(FixtureTower.rick)"); await settle()
        try press(reuse, "newChannel.create"); await settle(); await settle()
        try require(model.context.channelId == id && model.mode == .chat, "existing DM reused and opened")
        let after = try await store.reader.channels(workspaceId: workspace.id)
        try require(after.count == rows.count, "no duplicate DM")
        model.show(.deck); await settle(); await settle()
        try press(window, "deck.inbox.new"); await settle()
        try require(model.composingThread && find(window, "deck.compose") != nil, "selected DM still starts a thread")
        try press(window, "deck.compose.cancel"); await settle()
        try snapshot(window, model: model, name: "dm-created-selected")
        guard let lab = model.workspaceEntries.first(where: { $0.workspace.id == FixtureTower.lab }) else { throw Failure(description: "Lab fixture workspace") }
        model.setWorkspaceEnabled(lab, true)
        for _ in 0..<30 where model.enabledWorkspaceEntries.count < 2 { await settle() }
        await model.activateWorkspace(lab); await settle(); await settle()
        try press(window, "workspace.addChannel.Studio (sample).DMs"); await settle(); await settle()
        guard let stacked = window.attachedSheet else { throw Failure(description: "Stacked workspace DM picker") }
        try require(model.selectedWorkspace?.id == workspace.id, "plus activates captured workspace")
        try press(stacked, "newChannel.recipient.\(FixtureTower.rick)"); await settle()
        try press(stacked, "newChannel.create"); await settle(); await settle()
        try require(model.context.channelId == id && model.selectedWorkspace?.id == workspace.id, "stacked plus reuses DM in its workspace")
        model.loadMembership(force: true)
        for _ in 0..<30 where model.membership == nil { await settle() }
        try press(window, "workspace.addChannel.Studio (sample).Ambulando"); await settle(); await settle()
        guard let normal = window.attachedSheet else { throw Failure(description: "Ordinary new channel sheet") }
        try require(find(normal, "newChannel.recipient.\(FixtureTower.rick)") == nil, "ordinary scope retains named channel form")
        try click(normal, "newChannel.name"); await settle()
        guard let editor = normal.firstResponder as? NSTextView else { throw Failure(description: "Ordinary channel name editor") }
        editor.insertText("dm-regression-normal", replacementRange: editor.selectedRange()); await settle()
        try press(normal, "newChannel.create"); await settle(); await settle()
        let normalRows = try await store.reader.channels(workspaceId: workspace.id)
        guard let named = normalRows.first(where: { $0.name == "dm-regression-normal" }) else { throw Failure(description: "Ordinary channel created") }
        try require(named.kind == "channel" && named.scopeId == FixtureTower.scopeAmbulando, "ordinary channel contract preserved")
        try require(model.context.channelId == named.id && model.mode == .chat, "ordinary channel opens in Chat")
    }

    static func channelNameCheck(_ original: NSWindow, model: AppModel) async throws {
        guard model.fixture != nil, let workspace = model.selectedWorkspace, let connection = model.connection else { throw Failure(description: "Missing sample workspace") }
        let hostWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        defer { hostWindow.close() }
        hostWindow.contentView = NSHostingView(rootView: ManagementSettingsHost().environment(model))
        hostWindow.makeKeyAndOrderFront(nil)
        await settle(); await settle()
        guard let settings = hostWindow.attachedSheet else { throw Failure(description: "Settings sheet") }
        try press(settings, "settings.manageWorkspace"); await settle(); await settle()
        guard let management = settings.attachedSheet else { throw Failure(description: "Workspace management sheet") }
        try click(management, "admin.section.scopes"); await settle()
        try press(management, "admin.scope.\(FixtureTower.scopeAmbulando)"); await settle()
        try press(management, "admin.newChannel.\(FixtureTower.scopeAmbulando)"); await settle(); await settle()
        guard let window = NSApp.keyWindow, find(window, "newChannel.name") != nil else {
            throw Failure(description: "New channel sheet")
        }
        try snapshot(window, model: model, name: "channel-name-before-click")
        guard let node = find(window, "newChannel.name") else { throw Failure(description: "Missing name field") }
        print("NAME enabled=\(String(describing: value(node, "AXEnabled"))) frame=\(frame(of: node))")
        // Click the visible prompt on the left of the row, where a person naturally clicks.
        // In macOS grouped forms an automatic TextField title can become a noneditable label.
        let rect = frame(of: node)
        try require(rect.width > window.contentView!.bounds.width * 0.65, "name editor spans the visible prompt region")
        // Click the visible prompt near the left edge of the full-width editable control.
        let point = NSPoint(x: window.convertPoint(fromScreen: NSPoint(x: rect.minX + 8, y: rect.midY)).x,
                           y: window.convertPoint(fromScreen: NSPoint(x: rect.minX, y: rect.midY)).y)
        print("NAME_LEFT_HIT \(String(describing: window.contentView?.hitTest(window.contentView!.convert(point, from: nil))))")
        try sendClick(window, point: point); await settle()
        print("NAME responder=\(String(describing: window.firstResponder))")
        try require(window.firstResponder is NSTextView, "click focuses native channel name editor")
        try postKey(window, key: "x", code: 7, modifiers: []); await settle()
        try require(value(node, "AXValue") as? String == "x", "keyboard edits channel name after click")
        guard let nameEditor = window.firstResponder as? NSTextView else { throw Failure(description: "Name editor") }
        nameEditor.insertText("-click-review", replacementRange: nameEditor.selectedRange()); await settle()
        // The default sheet proves name hit testing; enlarge it for the lower content-field checks.
        window.setContentSize(NSSize(width: 700, height: 900)); await settle()
        for (id, text) in [("newChannel.description", "Editable description"), ("newChannel.prompt", "Editable context")] {
            try click(window, id); await settle()
            guard let editor = window.firstResponder as? NSTextView else { throw Failure(description: "Focus \(id)") }
            try require(editor !== nameEditor, "content focus leaves scalar name")
            editor.insertText(text, replacementRange: editor.selectedRange()); await settle()
            // Returning to the prompt side must focus the name even after a content editor was active.
            try click(window, "newChannel.name"); await settle()
            try require(value(node, "AXValue") as? String == "x-click-review", "focus transfer preserves name")
            try require(window.firstResponder is NSTextView, "name regains text focus")
        }
        try snapshot(window, model: model, name: "channel-name-after-editing")
        try press(window, "newChannel.create"); await settle(); await settle()
        let channels = try await model.store!.reader.channels(workspaceId: workspace.id)
        guard let created = channels.first(where: { $0.name == "x-click-review" }) else { throw Failure(description: "Created channel readback") }
        try require(created.contextPrompt == "Editable context", "created context retained")
        let raw = try JSONSerialization.jsonObject(with: created.raw) as? [String: Any]
        try require(raw?["description"] as? String == "Editable description", "created description retained")
        // Check existing-channel editing independently of the management list's post-create refresh.
        let editWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        editWindow.isReleasedWhenClosed = false
        defer { editWindow.close() }
        editWindow.contentView = NSHostingView(rootView: NavigationStack { ChannelSettingsSheet(channelId: created.id) }.environment(model))
        editWindow.makeKeyAndOrderFront(nil); await settle(); await settle()
        try click(editWindow, "channelSettings.name"); await settle()
        guard let rename = editWindow.firstResponder as? NSTextView else { throw Failure(description: "Existing name focus") }
        rename.selectAll(nil); rename.insertText("renamed-click-review", replacementRange: rename.selectedRange()); await settle()
        try press(editWindow, "channelSettings.rename"); await settle(); await settle()
        let renamed = try await model.store!.reader.channel(workspaceId: workspace.id, id: created.id)
        try require(renamed?.name == "renamed-click-review", "existing-channel rename readback")
        try snapshot(editWindow, model: model, name: "channel-name-existing-rename")
        _ = original
        _ = connection
    }

    static func workspaceAdministrationCheck(_ original: NSWindow, model: AppModel) async throws {
        guard model.fixture != nil, let workspace = model.selectedWorkspace, let connection = model.connection else { throw Failure(description: "Missing isolated sample workspace") }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Workspace administration · SAMPLE DATA"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        model.loadMembership(force: true)
        for section in WorkspaceManagementSection.allCases {
            window.contentView = NSHostingView(rootView:
                VStack(spacing: 0) {
                    Text("SAMPLE DATA · Isolated workspace administration check").font(.caption).padding(8)
                    WorkspaceManagementView(workspace: workspace, connection: connection, initialSection: section)
                }.environment(model).preferredColorScheme(.light))
            window.makeKeyAndOrderFront(nil)
            await settle(); await settle()
            try snapshot(window, model: model, name: "mac-workspace-\(section.rawValue)")
            try require(containsText(window, workspace.label), "selected workspace remains visible in \(section.rawValue)")
            if section == .groups, ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureGroups") {
                try require(containsText(window, "Product & customer operations"), "populated group browser")
                try press(window, "groups.open.10000000-0000-4000-8000-000000000001")
                await settle()
                try snapshot(window, model: model, name: "mac-groups-populated")
                try click(window, "groups.add.search")
                guard let editor = window.firstResponder as? NSTextView else { throw Failure(description: "Quick add must retain native text focus") }
                let syncBurst = Task {
                    for index in 0..<20 {
                        try? await model.store?.writer.setState("fixture.groups.sync-burst", "\(index)")
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                var worst = 0.0
                for letter in "Rick" {
                    let start = Date()
                    editor.insertText(String(letter), replacementRange: editor.selectedRange())
                    worst = max(worst, Date().timeIntervalSince(start))
                    try? await Task.sleep(for: .milliseconds(35))
                }
                await syncBurst.value
                print("GROUP_TYPEAHEAD_SYNC_WORST_KEY_SECONDS \(worst)")
                try require(worst < 0.1, "local typeahead remains responsive during store updates")
                await settle()
                try snapshot(window, model: model, name: "mac-groups-typeahead")
                let saved = try await model.store?.reader.administrationRows(connection: connection.id, workspace: workspace.id, list: .members)
                guard let rick = saved?.first(where: { $0.fields["kind"] == "agent" }) else { throw Failure(description: "Missing fixture agent") }
                try press(window, "groups.add.\(rick.id)")
                await settle(); await settle()
                try require(window.firstResponder is NSTextView, "quick addition retains input focus")
                try snapshot(window, model: model, name: "mac-groups-added")
                try click(window, "groups.add.search")
                guard let repeated = window.firstResponder as? NSTextView else { throw Failure(description: "Missing repeated-add editor") }
                repeated.setSelectedRange(NSRange(location: 0, length: repeated.string.utf16.count))
                repeated.insertText("You", replacementRange: repeated.selectedRange()); await settle()
                guard let me = saved?.first(where: { $0.fields["kind"] == "human" && $0.fields["npub"] != FixtureTower.ana }) else { throw Failure(description: "Missing own sample identity") }
                model.fixture?.offline = true
                try press(window, "groups.add.\(me.id)"); await settle(); await settle()
                try snapshot(window, model: model, name: "mac-groups-offline-draft")
                try require(containsText(window, "Your search is retained"), "offline addition has a readable retained-draft failure")
                try snapshot(window, model: model, name: "mac-groups-offline-draft")
                model.fixture?.offline = false
                model.loadMembership(force: true); await settle(); await settle()
                try press(window, "groups.add.\(me.id)"); await settle(); await settle()
                try require(containsText(window, "Added You"), "explicit retry adds another person without reopening")
                try snapshot(window, model: model, name: "mac-groups-repeated-add")
            }
            window.setContentSize(NSSize(width: 800, height: 600)); await settle()
            try snapshot(window, model: model, name: "mac-workspace-\(section.rawValue)-narrow")
            window.setContentSize(NSSize(width: 1100, height: 780))
        }
        window.contentView = NSHostingView(rootView: ManagementSettingsHost().environment(model))
        window.setContentSize(NSSize(width: 900, height: 700)); window.makeKeyAndOrderFront(nil)
        await settle(); await settle()
        guard let settings = window.attachedSheet else { throw Failure(description: "Settings sheet must be presented") }
        try press(settings, "settings.manageWorkspace")
        await settle(); await settle()
        guard let management = settings.attachedSheet else { throw Failure(description: "Manage Workspace must present above Settings") }
        let available = management.screen?.visibleFrame.size ?? NSSize(width: 1200, height: 900)
        let size = management.contentView?.bounds.size ?? .zero
        try require(size.width >= min(1000, available.width - 48) && size.height >= min(700, available.height - 80), "nested management uses larger display-safe size: \(size)")
        try require(management.styleMask.contains(.resizable), "nested management sheet is resizable")
        try click(management, "admin.section.groups"); await settle(); await settle()
        try snapshot(management, model: model, name: "mac-management-nested-settings")
        try require(find(management, "admin.editor.group") != nil, "actual nested sheet navigates to the group browser")
        if let other = model.workspaces.value.first(where: { $0.id != workspace.id }) {
            model.selectWorkspace(other.id); await settle()
            try require(containsText(management, "Workspace changed") || containsText(management, other.label), "workspace switch fences or reconstructs management for the selected workspace")
            try require(find(management, "groups.add.search") == nil, "previous workspace cannot add from retained sheet")
            model.selectWorkspace(workspace.id); await settle()
        }
        print("MANAGEMENT_SHEET_SIZE \(size)")
        settings.endSheet(management); window.endSheet(settings)
        try require(model.selectedWorkspace?.id == workspace.id, "inspection preserves workspace")
        _ = original
    }
}
private struct ManagementSettingsHost: View {
    @State private var settings = true
    var body: some View {
        Color.clear.sheet(isPresented: $settings) {
            SettingsView().frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 760)
        }
    }
}
#endif
