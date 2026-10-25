import AmbulandoCore
import AppKit
import SwiftUI

/// The Mac app: one main window over the same `AppModel` as the iPhone app (identity vault, Tower transport, SQLite store,
/// sync engine and outboxes from AmbulandoCore), plus the in-app browser in a window of its own. There is one main window
/// on purpose: the model holds one navigation (section, context and paths), so a second main window would mirror the
/// first rather than be independent.
@main
struct AmbulandoMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Ambulando", id: MacWindow.main) {
            RootView()
                .environment(delegate.model)
                .environment(delegate.ui)
                .tint(Amb.primary)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    delegate.model.markFirstFrame()
                    delegate.model.sceneDidBecomeActive()
                }
                .task { await delegate.model.start() }
        }
        .defaultSize(width: 1280, height: 820)
        // The app keeps syncing with the window closed (as desktop chat apps do); live updates restart on activation.
        .onChange(of: scenePhase) { _, phase in if phase == .active { delegate.model.sceneDidBecomeActive() } }
        .commands { AmbulandoCommands(model: delegate.model, ui: delegate.ui) }

        Window("Browser", id: MacWindow.browser) {
            MacBrowserWindow()
                .environment(delegate.model)
                .tint(Amb.primary)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 800)
    }
}

enum MacWindow {
    static let main = "main"
    static let browser = "browser"
}

/// Owns the one `AppModel` (and the Mac's window-level UI state) for the life of the process.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()
    @MainActor let ui = MacUI()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Window-level presentation state the menu commands and toolbar share (sheets over the main window).
@MainActor
@Observable
final class MacUI {
    var showSettings = false
    var showSearch = false
    var showUnlock = false
}

/// The browser window: the shared `BrowserView`. Its **Ambulando** button and closing the window both end the browsing
/// session's presentation, which also stops `window.nostr` from answering (it answers only while the browser is shown).
struct MacBrowserWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        BrowserView()
            .onAppear { if !model.browser.presented { model.browser.show() } }
            .onDisappear { model.browser.presented = false }
            .onChange(of: model.browser.presented) { _, shown in if !shown { dismissWindow(id: MacWindow.browser) } }
            .environment(\.openMention, OpenMentionAction { kind, id in model.openRecord(kind: kind, id: id) })
    }
}
