import AmbulandoCore
import SwiftUI
import WebKit

// The embedded Excalidraw board editor (BoardEditor/README.md): the web app's own editor page, built into the app as
// `BoardEditor.bundle` and served from the `ambulando-board:` scheme. This is the only page that gets the `board`
// message bridge, and it carries no signer, keys or `window.nostr`; HTML naplets and browser tabs never get it. The page
// cannot navigate, fetches nothing beyond its own files (its CSP and the scheme handler), and keeps no website data.
// Everything it edits goes through the board's `BoardController`, which alone reads and saves through Tower.

enum BoardEditorBundle {
    static let scheme = "ambulando-board"
    static var directory: URL? { Bundle.main.url(forResource: "BoardEditor", withExtension: "bundle") }
    static var available: Bool { directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) } ?? false }
}

/// Serves the bundled editor page and its assets; anything outside the bundle is refused.
final class BoardSchemeHandler: NSObject, WKURLSchemeHandler {
    static let types = ["html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css", "json": "application/json",
                        "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "svg": "image/svg+xml", "png": "image/png", "wasm": "application/wasm"]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == BoardEditorBundle.scheme, url.host == "editor", let root = BoardEditorBundle.directory?.standardizedFileURL else {
            task.didFailWithError(URLError(.unsupportedURL)); return
        }
        let relative = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let file = relative.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard !relative.contains(".."), file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            task.didFinish(); return
        }
        let type = Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// The editor web view for one board session. `interactive == false` shows it without taking touches (a board on the
/// canvas that is not selected). Save requests from the page's floating button come back through `onAction`.
@MainActor struct BoardEditorWebView {
    let session: BoardSession
    var interactive = true
    var dark = false
    /// The floating Save as the board offers it now (nil: none, as for read-only views).
    var saveAction: (label: String, enabled: Bool)?
    var onLink: (URL) -> Void = { _ in }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let id = UUID().uuidString
        var session: BoardSession
        var onLink: (URL) -> Void
        weak var webView: WKWebView?
        private var outgoing: AsyncStream<String>.Continuation?
        private var pump: Task<Void, Never>?
        private var loaded = false
        private var lastAction: String?

        init(session: BoardSession, onLink: @escaping (URL) -> Void) {
            self.session = session
            self.onLink = onLink
        }

        /// Attaches to the board and then loads the page, so the page's `ready` always finds its session. Messages to
        /// the page are delivered strictly in order (the page's port semantics).
        func start(_ webView: WKWebView, dark: Bool) {
            self.webView = webView
            let (stream, continuation) = AsyncStream<String>.makeStream()
            outgoing = continuation
            pump = Task { @MainActor [weak self] in
                for await json in stream {
                    guard let web = self?.webView else { continue }
                    _ = try? await web.callAsyncJavaScript("return window.ambulandoBoard ? window.ambulandoBoard.deliver(m) : false",
                                                           arguments: ["m": json], contentWorld: .page)
                }
            }
            let controller = session.controller, id = id
            Task { @MainActor in
                await controller.attach(id) { json in continuation.yield(json) }
                var components = URLComponents()
                components.scheme = BoardEditorBundle.scheme; components.host = "editor"; components.path = "/index.html"
                components.queryItems = [URLQueryItem(name: "theme", value: dark ? "dark" : "light")]
                if let url = components.url { webView.load(URLRequest(url: url)) }
            }
        }

        /// Sends the page its Save button state (sol `action-ui`); the page renders it in Excalidraw's own UI.
        func setAction(_ action: (label: String, enabled: Bool)?) {
            let payload: [String: Any] = action.map { ["action": "save", "label": $0.label, "title": $0.enabled ? "Save a new board version" : "No unsaved changes",
                                                      "disabled": !$0.enabled] } ?? [:]
            let json = BoardController.message(["type": "action-ui", "action": action == nil ? NSNull() : payload])
            guard json != lastAction else { return }
            lastAction = json
            outgoing?.yield(json)
        }

        func stop() {
            let controller = session.controller, id = id
            Task { await controller.detach(id) }
            outgoing?.finish(); pump?.cancel()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "board")
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only the bundled editor document in the main frame may talk to the board.
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == BoardEditorBundle.scheme,
                  let json = message.body as? String, json.utf8.count <= BoardScene.maxBytes * 2 else { return }
            if json.hasPrefix(#"{"type":"action""#),
               let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], o["action"] as? String == "save" {
                // The page only asks; Save runs if the board still offers it.
                if session.state.saveAction?.enabled == true { session.save() }
                return
            }
            // The page could not receive anything before it was ready: give it the current Save state again.
            if json.hasPrefix(#"{"type":"ready""#), let lastAction { outgoing?.yield(lastAction) }
            let board = session.controller, id = id
            Task { await board.receive(id, json) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            // The bundled page itself (first load, or a reload after its process ended); nothing else, no frames.
            if url.scheme == BoardEditorBundle.scheme, url.host == "editor", action.targetFrame?.isMainFrame == true, !loaded || action.navigationType == .reload {
                loaded = true
                return .allow
            }
            if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), action.navigationType == .linkActivated { onLink(url) }
            return .cancel
        }

        /// `window.open` (board element links): http(s) only, opened outside the editor.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { onLink(url) }
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // The draft lives in the controller; reloading re-attaches and receives it again.
            loaded = false
            webView.reload()
        }

        #if os(macOS)
        /// Image insert on the Mac (iOS presents its own picker for file inputs).
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.image]
            return await panel.begin() == .OK ? panel.urls : nil
        }
        #endif
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session, onLink: onLink) }

    @MainActor func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(BoardSchemeHandler(), forURLScheme: BoardEditorBundle.scheme)
        configuration.userContentController.add(WeakMessageHandler(coordinator), name: "board")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = []
        #endif
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsLinkPreview = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        #if os(iOS)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.isOpaque = false
        #endif
        #if os(iOS)
        webView.accessibilityIdentifier = "board.editor"
        #else
        webView.setAccessibilityIdentifier("board.editor")
        #endif
        coordinator.start(webView, dark: dark)
        return webView
    }
}

/// Breaks the user content controller's strong reference to the coordinator.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

#if os(iOS)
extension BoardEditorWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onLink = onLink
        view.isUserInteractionEnabled = interactive
        context.coordinator.setAction(saveAction)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
}
#else
extension BoardEditorWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onLink = onLink
        context.coordinator.setAction(saveAction)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
}
#endif

/// A board editor with the board's own status and history controls, used full screen and inside a board naplet.
struct BoardEditorPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let session: BoardSession
    var interactive = true

    var body: some View {
        let state = session.state
        ZStack {
            Color.white
            if BoardEditorBundle.available && model.canRead {
                BoardEditorWebView(session: session, interactive: interactive && state.status == .ready, dark: colorScheme == .dark,
                                   saveAction: state.saveAction, onLink: { url in model.browser.launch(url) })
                    .opacity(state.status == .ready ? 1 : 0)
            }
            switch state.status {
            case .loading:
                if model.canRead { ProgressView("Loading board…") }
                else { EmptyNote(title: "Board locked", systemImage: "lock", detail: "Unlock to open this board.") }
            case .denied: EmptyNote(title: "Board unavailable", systemImage: "lock", detail: state.error)
            case .error: EmptyNote(title: "Board cannot be shown", systemImage: "exclamationmark.triangle", detail: state.error)
            case .ready:
                if !BoardEditorBundle.available {
                    EmptyNote(title: "Board editor missing", systemImage: "exclamationmark.triangle",
                              detail: "This build has no board editor (scripts/build-board-editor.sh).")
                }
            }
        }
        .onChange(of: model.isUnlocked) { _, _ in session.refreshSigner() }
        // Reading again after a lock without background reading (the scene was cleared from memory).
        .onChange(of: model.canRead) { _, readable in if readable { session.resume() } }
    }
}

/// The board's messages and conflict actions (web: the board window's notices and cog menu).
struct BoardNotices: View {
    let session: BoardSession
    @State private var confirmDiscard = false

    var body: some View {
        let state = session.state
        VStack(alignment: .leading, spacing: 6) {
            if !state.viewingVersionId.isEmpty {
                HStack(spacing: 8) {
                    Text("Viewing version \(state.viewingVersionNumber) (read-only)").font(.amb(.caption).weight(.semibold))
                    Spacer()
                    if state.canWrite { Button("Restore") { session.restoreViewed() }.accessibilityIdentifier("board.restore") }
                    Button("Back to latest") { session.returnToLatest() }.accessibilityIdentifier("board.latest")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            if state.save == .stale || state.newerAvailable {
                HStack(spacing: 8) {
                    Text("Version \(state.latestVersionNumber) was saved by someone else.").font(.amb(.caption))
                    Spacer()
                    Button("Merge my changes") { session.mergeLatest() }.accessibilityIdentifier("board.merge")
                    Button("Discard mine", role: .destructive) { confirmDiscard = true }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            if !state.error.isEmpty || !state.notice.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Notice(tone: state.error.isEmpty ? .info : .warning, text: state.error.isEmpty ? state.notice : state.error)
                    Button { session.clearMessages() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
                }
                .accessibilityIdentifier("board.notice")
            }
        }
        .confirmationDialog("Discard your unsaved board changes and load the latest version?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard and load latest", role: .destructive) { session.discardAndLoadLatest() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// History and save options (web: the board window's cog menu).
struct BoardMenu: View {
    let session: BoardSession
    @State private var saveNote = false
    @State private var note = ""
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        let state = session.state
        Menu {
            if state.saveAction != nil {
                Button { note = ""; saveNote = true } label: { Label("Save with a note…", systemImage: "square.and.arrow.down") }
                    .disabled(state.saveAction?.enabled != true)
            }
            Section("Versions") {
                if state.versions.isEmpty {
                    Button(state.versionsLoading ? "Loading versions…" : "Show versions") { session.loadVersions() }
                        .accessibilityIdentifier("board.versions.load")
                }
                ForEach(state.versions.prefix(30)) { version in
                    Button {
                        session.view(version)
                    } label: {
                        let current = version.id == (state.viewingVersionId.isEmpty ? state.baseVersionId : state.viewingVersionId)
                        Label("v\(version.number)\(version.summary.isEmpty ? "" : " · \(version.summary)")",
                              systemImage: current ? "checkmark" : "clock.arrow.circlepath")
                    }
                }
            }
            if !state.dirty, state.viewingVersionId.isEmpty { Button("Reload latest") { session.discardAndLoadLatest() } }
            if state.canWrite {
                Button { name = session.title; renaming = true } label: { Label("Rename board…", systemImage: "pencil") }
                    .accessibilityIdentifier("board.rename")
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Board options").accessibilityIdentifier("board.menu")
        .onAppear { if state.versions.isEmpty { session.loadVersions() } }
        .alert("Save board", isPresented: $saveNote) {
            TextField("What changed (optional)", text: $note)
            Button("Cancel", role: .cancel) {}
            Button("Save") { session.save(summary: note) }
        }
        .alert("Rename board", isPresented: $renaming) {
            TextField("Board name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { session.rename(name) }.accessibilityIdentifier("board.rename.save")
        }
    }
}

/// The compact status pill of the web board window ("Unsaved · v7").
struct BoardStatusPill: View {
    let state: BoardState
    var body: some View {
        let text = state.headerStatus
        if !text.isEmpty {
            Text(text)
                .font(.amb(.caption2).weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(state.dirty || state.save == .stale ? Color.yellow.opacity(0.25) : Amb.muted, in: Capsule())
                .foregroundStyle(state.dirty || state.save == .stale ? Color.orange : Amb.mutedForeground)
                .lineLimit(1).fixedSize()
                .accessibilityIdentifier("board.status")
        }
    }
}
