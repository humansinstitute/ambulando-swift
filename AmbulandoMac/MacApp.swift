import AmbulandoCore
import AppKit
import SwiftUI

/// The Mac app: one main window over the same `AppModel` as the iPhone app (identity vault, Tower transport, SQLite store,
/// sync engine and outboxes from AmbulandoCore), plus the in-app browser and each open canvas in windows of their own.
/// There is one main window on purpose: the model holds one navigation (section, context and paths), so a second main
/// window would mirror the first rather than be independent. A canvas window keeps its own navigation instead.
@main
struct AmbulandoMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Ambulando", id: MacWindow.main) {
            RootView()
                .background(MacMainWindowCloseGuard(model: delegate.model))
                .appTextSize()
                .environment(delegate.model)
                .environment(delegate.ui)
                .tint(Amb.primary)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    MacHangDiagnostics.shared.start()
                    delegate.model.markFirstFrame()
                    delegate.model.sceneDidBecomeActive()
                }
                .task { await delegate.model.start() }
        }
        .defaultSize(width: 1280, height: 820)
        // The app keeps syncing with the window closed (as desktop chat apps do); live updates restart on activation.
        .onChange(of: scenePhase) { _, phase in if phase == .active { delegate.model.sceneDidBecomeActive() } }
        .commands { AmbulandoCommands(model: delegate.model, ui: delegate.ui) }

        // Each canvas in a window of its own, beside the main window or full screen (as the web's canvas page).
        WindowGroup("Canvas", id: MacWindow.canvas, for: CanvasWindowRoute.self) { $route in
            MacCanvasWindow(route: route)
                .appTextSize()
                .environment(delegate.model)
                .environment(delegate.ui)
                .tint(Amb.primary)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 1200, height: 820)

        Window("Browser", id: MacWindow.browser) {
            MacBrowserWindow()
                .appTextSize()
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
    static let canvas = "canvas"
}

/// Owns the one `AppModel` (and the Mac's window-level UI state) for the life of the process.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()
    @MainActor let ui = MacUI()

    #if DEBUG
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.arguments.contains("-AmbulandoMacThreadRegression"),
              FixtureEnvironment.requested else { return }
        Task { @MainActor in
            await model.start()
            guard model.fixture != nil else { return }
            await MacThreadRegression.run(model: model)
        }
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.fileNappletNavigation?({ sender.terminate(nil) }) == true { return .terminateCancel }
        let artefacts = Array(MacArtefactSession.sessions.values).filter { $0.window != nil }
        if artefacts.contains(where: { session in
            session.requestClose?({ sender.terminate(nil) }) == true
        }) { return .terminateCancel }
        let sessions = Array(MacDocumentWindows.shared.sessions.values)
        guard !sessions.isEmpty || !artefacts.isEmpty else { return .terminateNow }
        Task { @MainActor in
            for artefact in artefacts where artefact.window != nil {
                let allowed = artefact.busy ? false : await artefact.checkpoint?() ?? true
                if !allowed {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            for session in sessions {
                if let beforeClose = session.beforeClose, !(await beforeClose()) {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Window-level presentation state the menu commands and toolbar share (sheets over the main window).
@MainActor
@Observable
final class MacUI {
    var sidebarVisible = true
    var showSettings = false
    var showSearch = false
    var showNotifications = false
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

/// Intercept voluntary main-window closes without replacing SwiftUI's scene lifecycle delegate.
struct MacMainWindowCloseGuard: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> WindowView { WindowView(model: model) }
    func updateNSView(_ view: WindowView, context: Context) {}

    final class WindowView: NSView {
        let closeDelegate: MacMainWindowCloseDelegate
        init(model: AppModel) { closeDelegate = MacMainWindowCloseDelegate(model: model); super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            closeDelegate.attach(to: window)
        }
    }
}

@MainActor
final class MacMainWindowCloseDelegate: NSObject, NSWindowDelegate {
    private let model: AppModel
    private weak var window: NSWindow?
    private weak var sceneDelegate: NSWindowDelegate?
    init(model: AppModel) { self.model = model }

    func attach(to next: NSWindow?) {
        guard window !== next else { return }
        if let window, window.delegate === self { window.delegate = sceneDelegate }
        window = next
        sceneDelegate = next?.delegate
        next?.delegate = self
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || sceneDelegate?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if sceneDelegate?.responds(to: selector) == true { return sceneDelegate }
        return super.forwardingTarget(for: selector)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.fileNappletNavigation?({ [weak sender] in sender?.performClose(nil) }) == true { return false }
        return sceneDelegate?.windowShouldClose?(sender) ?? true
    }
}
