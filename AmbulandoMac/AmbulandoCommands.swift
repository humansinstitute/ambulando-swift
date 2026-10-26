import AmbulandoCore
import SwiftUI

/// Menu bar commands and keyboard shortcuts. They act on the one `AppModel`, so they work whichever view has focus.
struct AmbulandoCommands: Commands {
    let model: AppModel
    let ui: MacUI
    private let textScale = TextScale.shared
    @AppStorage(AppMode.agentsPreference) private var showAgents = false
    @AppStorage(AppMode.contextPreference) private var showContext = false

    private var ready: Bool { model.phase == .ready && model.connection != nil }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { ui.showSettings = true }
                .keyboardShortcut(",")
                .disabled(!ready)
        }
        // One main window (see `AmbulandoMacApp`): no File › New Window.
        CommandGroup(replacing: .newItem) {
            Button("New Browser Tab") { model.browser.open(nil) }
                .keyboardShortcut("t")
                .disabled(!ready)
        }
        CommandGroup(after: .sidebar) {
            Button(ui.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { ui.sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(!ready)
            Divider()
            // The app's own text (not web pages in the browser), kept across launches.
            Button("Increase Text Size") { textScale.increase() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!textScale.canIncrease)
            Button("Decrease Text Size") { textScale.decrease() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!textScale.canDecrease)
            Button("Actual Text Size") { textScale.reset() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(textScale.isDefault)
        }
        CommandMenu("Go") {
            ForEach(Array(AppMode.visible(agents: showAgents, context: showContext).enumerated()), id: \.element) { index, section in
                Button(section.title) { model.show(section) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(!ready)
            }
            Divider()
            Button("Back") { back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!ready)
            Button("Home") { model.chooseInSidebar(.home) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!ready)
            Button("Search…") { ui.showSearch = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!ready || model.selectedWorkspace == nil)
            Button("Notifications…") { ui.showNotifications = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!ready || model.selectedWorkspace == nil)
            Button("Browser") { model.browser.show() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!ready)
        }
        CommandMenu("Account") {
            Button("Refresh Now") { model.refresh(force: true) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!ready || !model.canRead)
            Divider()
            if case .unlocked = model.identity {
                Button("Lock Now") { Task { await model.lock() } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            } else {
                Button("Unlock…") { ui.showUnlock = true }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!ready)
            }
        }
    }

    /// Back one screen in the current section (the navigation stack's Back button).
    private func back() {
        if model.mode == .chat {
            if !model.chatPath.isEmpty { model.chatPath.removeLast() }
        } else if let key = AppModel.pathKey(model.mode), !model[keyPath: key].isEmpty {
            model[keyPath: key].removeLast()
        }
    }
}
