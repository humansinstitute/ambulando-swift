import AmbulandoCore
import SwiftUI
import WebKit

// Toolbox (sol `toolbox-manager.js`): the viewer's personal WApps, listed natively. A WApp's UI is a web document its
// publisher owns at an HTTPS address; it opens as an in-app browser tab (`BrowserModel.launch`), as Context Tree
// artifact pages do, where `window.nostr` asks the user before anything is shared or signed. HTML naplets are workspace
// content with no origin of their own, so they stay in the labelled, sandboxed view below: no script bridge, no network,
// nothing that can reach the app's identity, Tower session or storage.

struct ToolboxView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var wapps = LiveQuery<[PersonalWappRecord]>(initial: [])
    @State private var complete = LiveQuery<Bool>(initial: true)

    var body: some View {
        let key = WorkspaceSync.toolboxKey(workspace.id)
        List {
            Section {
                ForEach(wapps.value) { wapp in
                    if let url = wapp.safeLaunchURL {
                        Button { model.browser.launch(url) } label: { row(wapp, origin: WebContentPolicy.origin(of: url)) }
                            .accessibilityIdentifier("wapp.\(wapp.title)")
                    } else {
                        row(wapp, origin: nil).opacity(0.6)
                            .accessibilityIdentifier("wapp.\(wapp.title)")
                    }
                }
            } footer: {
                if !complete.value {
                    Text("Tower lists at most \(TowerAPI.personalWappLimit) WApps, so this list may be incomplete.").font(.caption).foregroundStyle(Amb.warning)
                }
                Text("WApps are web apps their publishers own. They open as tabs in the Ambulando browser, where a WApp must ask before it can see your Nostr key and you approve each signature. Adding, editing and placing WApps is done in the web app.")
                    .font(.caption)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Toolbox")
        .overlay {
            if wapps.loaded && wapps.value.isEmpty {
                if let error = model.syncError(forKey: key) { EmptyNote(title: "Toolbox unavailable", systemImage: "exclamationmark.icloud", detail: error) }
                else { EmptyNote(title: "No WApps", systemImage: "wrench.and.screwdriver", detail: model.canRead ? "WApps you add in the web app appear here." : "Unlock to load your Toolbox.") }
            }
        }
        .refreshable { model.openToolbox(workspace, force: true) }
        .task {
            let w = workspace.id, store = store, connection = model.connection?.id ?? ""
            wapps.start(store: store, matches: { $0.workspaceId == w && $0.table == .toolbox }) { try await store.reader.personalWapps(connectionId: connection, workspaceId: w) }
            complete.start(store: store, matches: { $0.workspaceId == w && $0.table == .toolbox }) {
                try await store.reader.listSyncComplete(workspaceId: w, key: WorkspaceSync.toolboxKey(w)) ?? true
            }
            model.openToolbox(workspace)
        }
    }

    private func row(_ wapp: PersonalWappRecord, origin: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "app.dashed").font(.title3).foregroundStyle(Amb.primary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(wapp.title).font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground)
                if let d = wapp.description { Text(d).font(.caption).foregroundStyle(Amb.mutedForeground).lineLimit(2) }
                Text(origin.map { "Web content · \($0)" } ?? "Not opened: its address is not HTTPS").font(.caption2).foregroundStyle(Amb.mutedForeground)
            }
        }
    }
}

/// Resolves a web content source and shows it in the labelled view.
struct WebContentView: View {
    @Environment(AppModel.self) private var model
    let source: WebContentSource
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var resolved: Resolved?
    @State private var failure: String?

    enum Resolved: Equatable {
        case html(String, title: String)
    }

    var body: some View {
        Group {
            if let resolved {
                switch resolved {
                case .html(let html, let title):
                    LabelledWebView(content: .html(html), title: title, label: "Web content · HTML artefact from this workspace (no network access)")
                }
            } else if let failure {
                EmptyNote(title: "Cannot open", systemImage: "lock", detail: failure)
            } else {
                ProgressView("Opening…")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await resolve() }
    }

    private func resolve() async {
        switch source {
        case .htmlNaplet(let canvas, let naplet, let title):
            guard let sync = model.sync, let connection = model.connection, model.canRead else { failure = "Unlock to open this HTML artefact."; return }
            do {
                let page = try await sync.napletHTML(connection, workspace, canvasId: canvas, napletId: naplet)
                resolved = .html(page.html, title: page.title.isEmpty ? title : page.title)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "This HTML artefact is not available to you."
            }
        }
    }
}

/// A WKWebView with a persistent label naming where the content comes from. It uses a non-persistent data store (no
/// cookies or storage shared with anything), registers no script bridge, and keeps every navigation — including server
/// redirects and new-window links — on its origin (`WebContentPolicy.decide`). Other HTTPS pages are only offered as
/// a separate tab of the in-app browser (`BrowserModel`, through `openURL`). HTML artefacts get sol's sandbox CSP (no network, frames, forms or plugins).
struct LabelledWebView: View {
    enum Content: Equatable { case url(URL), html(String) }
    let content: Content
    let title: String
    let label: String
    @State private var external: URL?
    @State private var loading = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.caption)
                Text(label).font(.caption).lineLimit(2)
                Spacer(minLength: 0)
                if loading { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(Amb.warning)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Amb.warningBackground)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("web.label")
            WebViewRepresentable(content: content, loading: $loading) { external = $0 }
        }
        .navigationTitle(title)
        .confirmationDialog("This link leaves \(title).", isPresented: Binding(get: { external != nil }, set: { if !$0 { external = nil } }), titleVisibility: .visible) {
            if let url = external { Button("Open \(url.host ?? "link") in a browser tab") { openURL(url); external = nil } }
            Button("Stay here", role: .cancel) { external = nil }
        } message: {
            Text("It opens in a separate browser tab, outside \(title).")
        }
    }
}

/// sol `CANVAS_HTML_CSP`.
private let htmlArtefactCSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; media-src data: blob:; frame-src 'none'; child-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

private struct WebViewRepresentable: UIViewRepresentable {
    let content: LabelledWebView.Content
    @Binding var loading: Bool
    let offerExternal: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsLinkPreview = false
        switch content {
        case .url(let url):
            context.coordinator.origin = WebContentPolicy.origin(of: url) ?? ""
            view.load(URLRequest(url: url))
        case .html(let html):
            context.coordinator.origin = "about:blank"
            let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(htmlArtefactCSP)\"><meta name=\"referrer\" content=\"no-referrer\">"
            view.loadHTMLString(csp + html, baseURL: nil)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: WebViewRepresentable
        var origin = ""
        init(_ parent: WebViewRepresentable) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // HTML artefacts load once from a string and may not navigate anywhere.
            if origin == "about:blank" {
                if action.navigationType == .other, action.request.url?.absoluteString == "about:blank" { return .allow }
                if let url = action.request.url, let safe = WebContentPolicy.launchURL(url.absoluteString) { await MainActor.run { parent.offerExternal(safe) } }
                return .cancel
            }
            // Subframes follow the same origin rule as the page.
            switch WebContentPolicy.decide(action.request.url, within: origin, newWindow: action.targetFrame == nil) {
            case .allow: return .allow
            case .refuse(let external):
                if let external, action.targetFrame?.isMainFrame != false { await MainActor.run { parent.offerExternal(external) } }
                return .cancel
            }
        }

        /// `target=_blank` and `window.open`: never a second web view. Same-origin targets load in place.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            switch WebContentPolicy.decide(action.request.url, within: origin, newWindow: true) {
            case .allow: if origin != "about:blank" { webView.load(action.request) }
            case .refuse(let external): if let external { parent.offerExternal(external) }
            }
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.loading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.loading = false }
    }
}
