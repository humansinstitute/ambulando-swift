import AmbulandoCore
import SwiftUI
import WebKit

/// Installed bundle host. It is never used for arbitrary canvas HTML or publisher-owned URLs.
@MainActor @Observable
final class InstalledNappletHost {
    private(set) var page: NappletPage?
    private(set) var failure: String?
    private(set) var authorizing = false
    private(set) var writing = false
    private(set) var dirty = false
    private var authority: Data?
    private var snapshot: NappletSnapshot?
    private var generation = 0
    private var closed = false
    private var request: Task<Void, Never>?
    private var writeRequest: Task<Void, Never>?
    private var refreshPending = false
    private var pendingError: String?
    let key: String
    let read: () async throws -> NappletSnapshot
    let write: (String, String, Data) async throws -> Void
    var requestClose: () -> Void = {}
    var requestRefresh: () -> Void = {}

    init(key: String, read: @escaping () async throws -> NappletSnapshot, write: @escaping (String, String, Data) async throws -> Void) {
        self.key = key; self.read = read; self.write = write
    }
    func destroy(_ error: String? = nil) {
        generation += 1; request?.cancel(); request = nil; writeRequest?.cancel(); writeRequest = nil; refreshPending = false; pendingError = nil
        page?.destroy(); page = nil; authority = nil; snapshot = nil
        authorizing = false; writing = false; dirty = false; failure = error
    }
    func close() { closed = true; destroy() }
    func refresh(background: Bool = false, saveError: String? = nil) {
        guard !closed, background || !writing else { return }
        if authorizing { refreshPending = true; pendingError = saveError ?? pendingError; return }
        authorizing = true; failure = nil; generation += 1
        let current = generation, prior = authority, oldPage = page
        if !background { page?.destroy(); page = nil; dirty = false }
        send(status: "loading", retainDraft: background && dirty)
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await read()
                guard !Task.isCancelled, !closed, current == generation else { return }
                guard let bundle = result.installations.first(where: { $0.key == key }), let html = result.html[key] else { throw TowerError.malformed("installed napplet unavailable") }
                // A changed permission/reference/installation boundary destroys even uncooperative script state.
                if prior != result.authority {
                    oldPage?.destroy(); page = nil; dirty = false
                    writeRequest?.cancel(); writeRequest = nil; writing = false
                }
                authority = result.authority; snapshot = result; authorizing = false
                if refreshPending {
                    refreshPending = false; let nextError = pendingError; pendingError = nil
                    refresh(background: true, saveError: nextError); return
                }
                if page == nil {
                    let newPage = NappletPage(html: html, capabilities: bundle.capabilities) { [weak self] intent in self?.receive(intent) }
                    page = newPage
                    newPage.didFail = { [weak self] reason in self?.destroy("The napplet could not open. " + reason) }
                    newPage.install()
                }
                if page?.ready == true && !writing {
                    send(status: saveError == nil ? "ready" : "error", retainDraft: saveError != nil && prior == result.authority, error: saveError)
                    page?.visible = true
                }
            } catch {
                guard !Task.isCancelled, !closed, current == generation else { return }
                destroy(error.localizedDescription)
            }
        }
    }
    private func send(status: String, retainDraft: Bool = false, error: String? = nil) {
        guard let page else { return }
        var state: [String: Any] = ["version": 1, "session": page.session, "type": "state", "status": status,
                                    "view": "bundle:" + key, "retainDraft": retainDraft]
        if let error { state["error"] = error }
        if page.capabilities.contains("org_data.read"), let snapshot,
           status == "ready" || status == "error" && retainDraft {
            state["projection"] = try? JSONSerialization.jsonObject(with: snapshot.projection)
        }
        page.send(state)
    }
    private func receive(_ intent: NappletIntent) {
        guard !closed, let page else { return }
        switch intent {
        case .ready:
            guard !page.ready else { return }
            page.ready = true
            guard !authorizing, !writing, snapshot != nil else { return }
            page.visible = true; send(status: "ready")
        case .dirty(let value): dirty = value
        case .refresh: if !writing { requestRefresh() }
        case .close: if !writing { requestClose() }
        case .write(let path, let method, let body):
            guard page.ready, !authorizing, !writing, snapshot != nil else { return }
            writing = true
            let writeSession = page.session
            writeRequest = Task { [weak self] in
                guard let self else { return }
                do {
                    try await write(path, method, body)
                    guard !Task.isCancelled, !closed, self.page?.session == writeSession else { return }
                    writing = false; dirty = false; refresh(background: true)
                } catch {
                    guard !Task.isCancelled, !closed, self.page?.session == writeSession else { return }
                    writing = false
                    if case TowerError.http(let status, _, _) = error, status == 403 || status == 404 {
                        destroy("Organisation data access denied.")
                    } else {
                        // Retain the exact original expected_revision and operation_id only after an unchanged authority read.
                        refresh(background: true, saveError: error.localizedDescription)
                    }
                }
            }
        }
    }
}

struct InstalledNappletView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let key: String
    let title: String
    let workspace: WorkspaceRecord
    @State private var host: InstalledNappletHost?
    @State private var confirmation: String?
    @State private var discovery = LiveQuery<String?>(initial: nil)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Workspace napplet · private", systemImage: "app.badge").font(.amb(.caption))
                Spacer()
                if host?.writing == true || host?.authorizing == true { ProgressView().controlSize(.mini) }
                Button("Refresh", systemImage: "arrow.clockwise") { confirm("refresh") }.labelStyle(.iconOnly).disabled(host?.writing == true)
                Button("Close", systemImage: "xmark") { confirm("close") }.labelStyle(.iconOnly).disabled(host?.writing == true)
            }.padding(10).background(Amb.card)
            if let host, let page = host.page {
                InstalledNappletWebView(page: page).id(page.session)
                    .opacity(page.visible && scenePhase == .active ? 1 : 0)
                    .allowsHitTesting(page.visible && scenePhase == .active && !host.authorizing && !host.writing)
                    .overlay { if !page.visible { ProgressView("Authorizing napplet…") } }
            } else if let error = host?.failure {
                EmptyNote(title: "Napplet unavailable", systemImage: "lock", detail: error)
                Button("Retry") { host?.refresh() }.padding()
            } else { ProgressView("Opening napplet…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle(title).inlineTitle()
        .navigationBarBackButtonHidden(host?.dirty == true || host?.writing == true)
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { let action = confirmation; confirmation = nil; perform(action ?? "close") }
            Button("Keep editing", role: .cancel) { confirmation = nil }
        }
        .task(id: hostContext) { await runHost() }
        .onChange(of: discovery.value) { _, _ in host?.refresh(background: true) }
        .onChange(of: model.canRead) { _, canRead in if !canRead { host?.close() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { host?.refresh(background: true) }
            else { host?.page?.visible = false }
        }
        .onDisappear { host?.close() }
    }
    private var hostContext: [String] {
        let connection = model.connection
        let selected = model.selectedWorkspace
        return [connection?.id ?? "", connection?.origin ?? "", connection?.signerNpub ?? "", connection?.towerNpub ?? "",
                selected?.id ?? "", selected?.appNpub ?? "", String(describing: model.identity), String(model.canRead), String(model.wikiContextEpoch)]
    }
    private func runHost() async {
            host?.close()
            guard model.canRead, model.selectedWorkspace?.id == workspace.id,
                  let sync = model.sync, let connection = model.connection else { return }
            let discoveryKey = WorkspaceSync.nappletsKey(connection.id, workspace.id)
            if let store = model.store {
                discovery.start(store: store, matches: { $0.table == .appState }) { try await store.reader.state(discoveryKey) }
            }
            let epoch = model.wikiContextEpoch
            let current: () -> Bool = { model.canRead && model.wikiContextEpoch == epoch && model.selectedWorkspace?.id == workspace.id }
            let h = InstalledNappletHost(key: key, read: {
                guard current() else { throw CancellationError() }
                let result = try await sync.readNapplets(connection, workspace)
                guard current() else { throw CancellationError() }; return result
            }, write: { path, method, body in
                guard current(), model.isUnlocked else { throw IdentityError.locked }
                try await sync.writeNapplet(connection, workspace, path: path, method: method, body: body)
                guard current() else { throw CancellationError() }
            })
            h.requestClose = { confirm("close") }; h.requestRefresh = { confirm("refresh") }
            host = h; h.refresh()
            // A visible authorized document must recheck even without an event connection. Cancellation on disappearance
            // or context changes invalidates in-flight reads and destroys its browsing context.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                guard current() else { break }
                if scenePhase == .active { h.refresh(background: true) }
            }
            h.close()
    }
    private func confirm(_ action: String) {
        guard host?.writing != true else { return }
        if host?.dirty == true { confirmation = action } else { perform(action) }
    }
    private func perform(_ action: String) {
        if action == "refresh" { host?.refresh() } else { host?.close(); dismiss() }
    }
}

/// Host-owned parent document forwards only its own opaque sandbox's messages. The bundle never sees a credential,
/// native signer, Tower URL or arbitrary request API. Native validates the main-frame sender and exact message again.
@MainActor @Observable
final class NappletPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let session = UUID().uuidString
    let capabilities: [String]
    private let html: String
    private let receive: (NappletIntent) -> Void
    private(set) var webView: WKWebView?
    var ready = false
    var visible = false
    var didFail: (String) -> Void = { _ in }
    private var timeout: Task<Void, Never>?

    init(html: String, capabilities: [String], receive: @escaping (NappletIntent) -> Void) {
        self.html = html; self.capabilities = capabilities; self.receive = receive
    }
    static func json(_ value: Any) -> String {
        let bytes = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }
    func install() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(WeakMessageHandler(self), name: "napplet")
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view; view.navigationDelegate = self; view.uiDelegate = self; view.allowsLinkPreview = false
        // Resource blocking complements CSP and the navigation delegate; all bundle resources are inline/data.
        let rules = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "installed-napplet-no-network-v1", encodedContentRuleList: rules) { [weak self, weak view] list, error in
            Task { @MainActor in
                guard let self, let view, self.webView === view else { return }
                guard error == nil, let list else { self.didFail(error?.localizedDescription ?? "Resource policy unavailable."); return }
                configuration.userContentController.add(list)
                let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"
                // Local opaque WK documents do not expose the secure-context-only randomUUID API. Published
                // bundles use it for durable mutation IDs. Supply RFC 4122 v4 from WebCrypto's CSPRNG, never Math.random.
                let bootstrap = """
                window.nappletSession=\(Self.json(self.session));
                if(typeof crypto.randomUUID!=='function')Object.defineProperty(crypto,'randomUUID',{value:()=>{
                  const b=crypto.getRandomValues(new Uint8Array(16));b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;
                  const h=Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');
                  return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);
                }});
                """
                let code = "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><script>\(bootstrap)</script>" + self.html
                let parent = """
                <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;height:100%;overflow:hidden}iframe{border:0;width:100%;height:100%}</style><iframe id="napplet" sandbox="allow-scripts" title="Workspace napplet"></iframe><script>
                const frame=document.getElementById('napplet');
                window.addEventListener('message', e=>{if(e.source===frame.contentWindow&&e.origin==='null'&&e.data?.session===\(Self.json(self.session))) window.webkit.messageHandlers.napplet.postMessage(e.data)});
                frame.srcdoc=\(Self.json(code));
                </script>
                """
                view.loadHTMLString(parent, baseURL: nil)
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, !ready else { return }; didFail("The document did not complete its ready handshake. Retry to reauthorize.")
        }
    }
    func send(_ state: [String: Any]) {
        guard let webView else { return }
        webView.evaluateJavaScript("document.getElementById('napplet')?.contentWindow.postMessage(\(Self.json(state)),'*')", completionHandler: nil)
    }
    func destroy() {
        timeout?.cancel(); timeout = nil; visible = false; ready = false
        if let view = webView {
            view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "napplet")
            view.navigationDelegate = nil; view.uiDelegate = nil; view.removeFromSuperview(); view.loadHTMLString("", baseURL: nil)
        }
        webView = nil
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = webView, message.webView === view, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.absoluteString == "about:blank",
              JSONSerialization.isValidJSONObject(message.body), let data = try? JSONSerialization.data(withJSONObject: message.body),
              let intent = try? NappletIntent.parse(data, session: session, capabilities: capabilities) else { return }
        receive(intent)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url?.absoluteString
        return navigationAction.navigationType == .other && (url == "about:blank" || url == "about:srcdoc") ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { didFail(error.localizedDescription) }
}

#if os(iOS)
private struct InstalledNappletWebView: UIViewRepresentable {
    let page: NappletPage
    func makeUIView(context: Context) -> WKWebView { page.webView ?? WKWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
}
#else
private struct InstalledNappletWebView: NSViewRepresentable {
    let page: NappletPage
    func makeNSView(context: Context) -> WKWebView { page.webView ?? WKWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
}
#endif
