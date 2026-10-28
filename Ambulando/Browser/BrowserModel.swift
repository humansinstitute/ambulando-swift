import AmbulandoCore
import SwiftUI
import WebKit

/// One browser tab: a live `WKWebView` (so its page, scroll and back/forward history stay while other tabs or
/// Ambulando are shown) and what the chrome shows about it.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    @ObservationIgnored let webView: WKWebView
    var title = ""
    var url: URL?
    var canGoBack = false
    var canGoForward = false
    var loading = false
    var progress = 0.0
    /// The last navigation the browser refused, shown above the page until the next page loads.
    var refusal: String?
    /// Bumped on every main-frame commit; `window.nostr` requests are bound to the document that made them.
    @ObservationIgnored var documentId: UInt64 = 0
    /// The committed page's HTTPS origin (nil for `about:blank` and anything not HTTPS).
    @ObservationIgnored var origin: String?
    @ObservationIgnored var closed = false
    /// The WApp or artifact address this tab was opened for from an Ambulando launcher, so launching it again returns here.
    @ObservationIgnored var launchURL: URL?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    var isBlank: Bool { url == nil || url?.scheme == "about" }
    var displayTitle: String { title.isEmpty ? (url?.host ?? "New tab") : title }

    init(webView: WKWebView) {
        self.webView = webView
        observations = [
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.loading = view.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
        ]
    }

    func invalidate() {
        closed = true
        observations.forEach { $0.invalidate() }
        observations = []
    }
}

/// A JavaScript `alert()` or `confirm()` waiting for the user.
struct BrowserDialog: Identifiable {
    let id = UUID()
    let origin: String
    let message: String
    let confirm: Bool
    let reply: (Bool) -> Void
}

/// The in-app browser: full-screen tabs over Ambulando, with `window.nostr` answered natively by `NIP07Broker`.
///
/// Ambulando's own screens stay alive underneath (the browser is a cover, not a navigation change), so returning
/// finds the same section, channel, scroll position and composer draft. Tabs live while the app runs.
@MainActor
@Observable
final class BrowserModel {
    static let handlerName = "ambulandoNostr"
    /// Website data (cookies, local storage) for the browser only, kept across launches and separate from the
    /// Toolbox's non-persistent views. The identifier names the store; it is not a secret.
    static let dataStoreIdentifier = UUID(uuidString: "6E1B5A55-0B1D-4C35-9A0E-AB0B2C0B7E12")!
    static let sitesStateKey = "browser.sites.v1"
    static let maxTabs = 12

    private(set) var tabs: [BrowserTab] = []
    var selectedId: UUID?
    var presented = false {
        didSet {
            if oldValue && !presented {
                for tab in tabs { broker?.tabClosed(tab.id) }
                dialog?.reply(false); dialog = nil
            }
        }
    }
    var showingTabs = false
    /// An address for another app (mail, phone, wallet...) waiting for the user to confirm the hand-off.
    var pendingExternal: URL?
    var dialog: BrowserDialog?
    /// The broker's current question, mirrored for SwiftUI.
    private(set) var prompt: NIP07Prompt?
    private(set) var locked = true
    private(set) var sites: [String: NIP07SitePermission] = [:]
    /// Sites saved to the new-tab page, kept on this device apart from website data and Nostr permissions.
    private(set) var favourites = BrowserFavourites()

    /// Sample-data mode: this HTML answers for `sampleOrigin` instead of the network.
    @ObservationIgnored var samplePage: (url: URL, html: String)?
    @ObservationIgnored private(set) var broker: NIP07Broker?
    @ObservationIgnored private var dataStore: WKWebsiteDataStore?
    @ObservationIgnored private var contentController: WKUserContentController?
    @ObservationIgnored private var delegate: BrowserWebDelegate?
    @ObservationIgnored private var handler: BrowserScriptHandler?
    @ObservationIgnored private var favouritesStore: LocalStore?
    /// Favourites writes run one after another, so the stored list is always the latest.
    @ObservationIgnored private var favouritesWrite: Task<Void, Never>?

    var selected: BrowserTab? { tabs.first { $0.id == selectedId } ?? tabs.last }

    /// Connects the broker to the identity. Called once the store and signer exist.
    func configure(store: LocalStore, signer: @escaping @Sendable () async -> IdentityService?, locked: Bool) async {
        let saved = (try? await store.reader.state(Self.sitesStateKey)).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: NIP07SitePermission].self, from: $0) } ?? [:]
        let broker = NIP07Broker(locked: locked, sites: saved,
                                 publicKey: {
                                     guard let service = await signer() else { throw IdentityError.locked }
                                     return try await service.publicKeyHex()
                                 },
                                 signer: { template in
                                     guard let service = await signer() else { throw IdentityError.locked }
                                     return try await service.sign(template)
                                 },
                                 persist: { sites in
                                     let text = sites.isEmpty ? nil : (try? JSONEncoder().encode(sites)).map { String(decoding: $0, as: UTF8.self) }
                                     Task { try? await store.writer.setState(Self.sitesStateKey, text) }
                                 })
        broker.onChange = { [weak self, weak broker] in
            guard let self, let broker else { return }
            self.prompt = broker.current
            self.locked = broker.locked
            self.sites = broker.sites
        }
        self.broker = broker
        self.locked = locked
        self.sites = saved
        favouritesStore = store
        favourites = BrowserFavourites.decode(try? await store.reader.state(BrowserFavourites.stateKey))
    }

    // MARK: Favourites

    /// Adds the tab's page to the favourites (or removes it if it is one), then looks for the icon the page advertises.
    func toggleFavourite(_ tab: BrowserTab) {
        guard let url = tab.url else { return }
        if let saved = favourites.favourite(for: url) {
            removeFavourite(saved.id)
            return
        }
        let saved: BrowserFavourite
        do { saved = try favourites.add(title: tab.title, url: url) } catch {
            tab.refusal = (error as? BrowserFavouriteError)?.message
            return
        }
        persistFavourites()
        Task { [weak self, weak tab] in
            guard let tab, tab.url.map(BrowserFavourites.canonical) == BrowserFavourites.canonical(url),
                  let icon = await Self.siteIcon(in: tab.webView), let self else { return }
            self.favourites.setSiteIcon(icon, for: saved.id)
            self.persistFavourites()
        }
    }

    /// Saves an edited favourite, or a new one typed on the start page. Throws the reason it was refused.
    func saveFavourite(_ favourite: BrowserFavourite) throws {
        if favourites.items.contains(where: { $0.id == favourite.id }) {
            try favourites.update(favourite)
        } else {
            let added = try favourites.add(title: favourite.title, url: favourite.url)
            var edited = favourite
            edited.id = added.id
            do { try favourites.update(edited) } catch { favourites.remove(added.id); throw error }
        }
        persistFavourites()
    }

    func removeFavourite(_ id: UUID) {
        favourites.remove(id)
        persistFavourites()
    }

    func moveFavourites(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        favourites.move(fromOffsets: offsets, toOffset: destination)
        persistFavourites()
    }

    func moveFavourite(_ id: UUID, by step: Int) {
        guard let index = favourites.items.firstIndex(where: { $0.id == id }) else { return }
        favourites.move(id, to: index + step)
        persistFavourites()
    }

    /// Opens a favourite in the tab showing the start page (or a new tab if there is none).
    func openFavourite(_ favourite: BrowserFavourite) {
        if let tab = selected, tab.isBlank { load(favourite.url, in: tab) } else { open(favourite.url) }
    }

    private func persistFavourites() {
        guard let store = favouritesStore else { return }
        let text = favourites.encoded(), previous = favouritesWrite
        favouritesWrite = Task {
            await previous?.value
            try? await store.writer.setState(BrowserFavourites.stateKey, text)
        }
    }

    /// The icon the page names for home screens (`apple-touch-icon`), else its largest `icon`, else `/favicon.ico`.
    /// Run in Ambulando's own script world, so the page cannot replace the functions used; the links themselves are the
    /// page's, so only an HTTPS address is kept (`BrowserFavourites.setSiteIcon`).
    private static func siteIcon(in webView: WKWebView) async -> URL? {
        let script = """
        (() => {
          const links = [...document.querySelectorAll('link[rel][href]')].map(l => ({ rel: l.rel.toLowerCase(), href: l.href, size: parseInt((l.sizes && l.sizes.value || '0').split('x')[0]) || 0 }));
          const touch = links.filter(l => l.rel.includes('apple-touch-icon')).sort((a, b) => b.size - a.size)[0];
          const icon = links.filter(l => l.rel.split(/\\s+/).includes('icon')).sort((a, b) => b.size - a.size)[0];
          return (touch || icon || {}).href || (location.origin + '/favicon.ico');
        })()
        """
        guard let found = try? await webView.evaluateJavaScript(script, contentWorld: .defaultClient) as? String else { return nil }
        return URL(string: found)
    }

    // MARK: Tabs

    /// Opens `url` (or an empty tab for the address field) as a new tab and shows the browser.
    func open(_ url: URL?) {
        let tab = addTab(configuration: nil)
        if let url { load(url, in: tab) }
        presented = true
    }

    /// A launcher in Ambulando (Deck's Apps, the Toolbox, Context Tree artifacts) opening an HTTPS web app as a browser
    /// tab, where it may ask to use `window.nostr`. The tab it opened before is shown again (page, sign-in and history
    /// kept) rather than a new one. Returns false if the address is not one the browser opens.
    @discardableResult
    func launch(_ url: URL) -> Bool {
        guard BrowserURLPolicy.decide(url, mainFrame: true) == .load else { return false }
        if let tab = tabs.first(where: { $0.launchURL == url }) {
            select(tab)
        } else {
            open(url)
            selected?.launchURL = url
        }
        presented = true
        return true
    }

    /// The page menu's **Open in Safari**: hands the address to the system's browser. It does not go through `openURL`,
    /// which inside the app opens an in-app tab (the default for links), so the choice here is always explicit.
    func openInSystemBrowser(_ url: URL) {
        guard url.scheme?.lowercased() == "https" else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    /// The globe button: back to the open tabs, or a new tab when there are none.
    func show() {
        if tabs.isEmpty { open(nil) } else { presented = true }
    }

    func select(_ tab: BrowserTab) {
        selectedId = tab.id
        showingTabs = false
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        broker?.tabClosed(tab.id)
        tab.invalidate()
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
        tabs.remove(at: index)
        if selectedId == tab.id { selectedId = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id }
        if tabs.isEmpty { presented = false; showingTabs = false }
    }

    func closeAll() { for tab in tabs { close(tab) } }

    @discardableResult
    func addTab(configuration: WKWebViewConfiguration?) -> BrowserTab {
        if tabs.count >= Self.maxTabs, let oldest = tabs.first(where: { $0.id != selectedId }) { close(oldest) }
        let webView = WKWebView(frame: .zero, configuration: configuration ?? newConfiguration())
        webView.navigationDelegate = webDelegate
        webView.uiDelegate = webDelegate
        webView.allowsBackForwardNavigationGestures = true
        #if os(iOS)
        webView.accessibilityIdentifier = "browser.page"
        #else
        webView.setAccessibilityIdentifier("browser.page")
        #endif
        let tab = BrowserTab(webView: webView)
        tabs.append(tab)
        selectedId = tab.id
        return tab
    }

    func tab(for webView: WKWebView) -> BrowserTab? { tabs.first { $0.webView === webView } }

    /// Loads an address typed in the address field. Returns false if it is not one the browser opens.
    @discardableResult
    func go(_ text: String, in tab: BrowserTab) -> Bool {
        guard let url = BrowserURLPolicy.typedAddress(text) else {
            tab.refusal = "Enter an HTTPS address, for example example.com."
            return false
        }
        load(url, in: tab)
        return true
    }

    func load(_ url: URL, in tab: BrowserTab) {
        switch BrowserURLPolicy.decide(url, mainFrame: true) {
        case .load:
            tab.refusal = nil
            if let sample = samplePage, url.host == sample.url.host {
                tab.webView.loadHTMLString(sample.html, baseURL: sample.url)
            } else {
                tab.webView.load(URLRequest(url: url))
            }
        case .external(let other): pendingExternal = other
        case .refuse(let why): tab.refusal = why
        }
    }

    /// Links tapped in Ambulando (messages, documents, the Toolbox): HTTPS opens a tab; other apps' schemes and
    /// anything else go to iOS as before.
    func handleLink(_ url: URL) -> OpenURLAction.Result {
        switch BrowserURLPolicy.decide(url, mainFrame: true) {
        case .load: open(url)
        case .external: return .systemAction
        case .refuse(let reason): show(); selected?.refusal = reason
        }
        return .handled
    }

    // MARK: Signing state

    func answer(_ prompt: NIP07Prompt, _ decision: NIP07Decision) { broker?.resolve(prompt.id, decision) }

    func setLocked(_ value: Bool) {
        locked = value
        broker?.setLocked(value)
        if value { dialog?.reply(false); dialog = nil }
    }

    func forget(origin: String) { broker?.forget(origin) }

    /// The identity was removed or the Tower disconnected: tabs close and no site keeps a permission.
    func reset() {
        closeAll()
        broker?.reset()
    }

    func clearBrowsingData() async {
        await store().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    // MARK: WebKit plumbing

    private var webDelegate: BrowserWebDelegate {
        if let delegate { return delegate }
        let made = BrowserWebDelegate(model: self)
        delegate = made
        return made
    }

    private func store() -> WKWebsiteDataStore {
        if let dataStore { return dataStore }
        let made = WKWebsiteDataStore(forIdentifier: Self.dataStoreIdentifier)
        dataStore = made
        return made
    }

    /// One content controller for every tab (popups reuse their opener's configuration, so the script and handler
    /// are registered exactly once).
    private func controller() -> WKUserContentController {
        if let contentController { return contentController }
        let made = WKUserContentController()
        made.addUserScript(WKUserScript(source: Self.nostrScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        let handler = BrowserScriptHandler(model: self)
        made.addScriptMessageHandler(handler, contentWorld: .page, name: Self.handlerName)
        self.handler = handler
        contentController = made
        return made
    }

    private func newConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store()
        configuration.userContentController = controller()
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    func documentCommitted(_ tab: BrowserTab) {
        tab.documentId &+= 1
        tab.origin = BrowserURLPolicy.origin(of: tab.webView.url)
        tab.refusal = nil
        broker?.documentChanged(tabId: tab.id, documentId: tab.documentId)
    }

    /// NIP-07 for the top frame of HTTPS pages. The page only ever gets the public key and events the user approved;
    /// every call goes to the native handler, which checks the calling frame itself.
    static let nostrScript = """
    (() => {
      if (window.top !== window || location.protocol !== 'https:') return;
      if (window.nostr && window.nostr.__ambulando) return;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler) return;
      const call = (method, params) => handler.postMessage({ method, params: params === undefined ? null : params });
      const unsupported = (name) => () => Promise.reject(new Error(name + ' is not supported by Ambulando.'));
      const nostr = {
        getPublicKey: () => call('getPublicKey'),
        signEvent: (event) => {
          try { return call('signEvent', JSON.parse(JSON.stringify(event))); } catch (error) { return Promise.reject(error); }
        },
        getRelays: () => call('getRelays'),
        nip04: { encrypt: unsupported('nip04.encrypt'), decrypt: unsupported('nip04.decrypt') },
        nip44: { encrypt: unsupported('nip44.encrypt'), decrypt: unsupported('nip44.decrypt') },
      };
      Object.defineProperty(nostr, '__ambulando', { value: true });
      Object.defineProperty(window, 'nostr', { value: Object.freeze(nostr), configurable: true, writable: false });
    })();
    """
}

/// Receives `window.nostr` calls. Only the top frame of a tab, at the tab's committed HTTPS origin and current
/// document, is answered; the broker asks the user and re-checks the document before signing.
@MainActor
final class BrowserScriptHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var model: BrowserModel?
    init(model: BrowserModel) { self.model = model }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let model, model.presented, let broker = model.broker, let webView = message.webView, let tab = model.tab(for: webView) else {
            return (nil, NIP07Error.closed.message)
        }
        guard message.frameInfo.isMainFrame else { return (nil, NIP07Error.invalid("only the top page may use window.nostr").message) }
        let security = message.frameInfo.securityOrigin
        guard let origin = BrowserURLPolicy.origin(scheme: security.protocol, host: security.host, port: security.port),
              origin == tab.origin else { return (nil, NIP07Error.pageChanged.message) }
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else {
            return (nil, NIP07Error.invalid("malformed request").message)
        }
        let document = tab.documentId
        let result = await broker.handle(method: method, params: body["params"],
                                         context: NIP07Context(tabId: tab.id, documentId: document, origin: origin)) { [weak model, weak tab, weak webView] in
            guard let model, model.presented, let tab, let webView, !tab.closed, tab.webView === webView else { return false }
            return tab.documentId == document && tab.origin == origin
        }
        switch result {
        case .success(let reply): return (reply.javaScriptValue, nil)
        case .failure(let error): return (nil, error.message)
        }
    }
}

/// Navigation, popups, `window.close()` and JavaScript dialogs for every tab.
@MainActor
final class BrowserWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var model: BrowserModel?
    init(model: BrowserModel) { self.model = model }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        switch BrowserURLPolicy.decide(url, mainFrame: mainFrame) {
        case .load: return .allow
        case .external(let other):
            // Only a navigation the user started may leave for another app.
            if action.navigationType == .linkActivated || action.navigationType == .formSubmitted { model?.pendingExternal = other }
            return .cancel
        case .refuse(let why):
            if mainFrame { model?.tab(for: webView)?.refusal = why }
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let model, let tab = model.tab(for: webView) else { return }
        model.documentCommitted(tab)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let model, let tab = model.tab(for: webView) else { return }
        model.documentCommitted(tab)
        webView.reload()
    }

    /// `target=_blank` links and `window.open()`: a new tab built from WebKit's configuration (so `window.opener`
    /// works), unless the address is one the browser does not open.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let model else { return nil }
        if let url = action.request.url, !url.absoluteString.isEmpty {
            switch BrowserURLPolicy.decide(url, mainFrame: true) {
            case .load: break
            case .external(let other): model.pendingExternal = other; return nil
            case .refuse(let why): model.tab(for: webView)?.refusal = why; return nil
            }
        }
        let tab = model.addTab(configuration: configuration)
        #if DEBUG
        if let url = action.request.url, let sample = model.samplePage, url.host == sample.url.host {
            model.load(url, in: tab)
            return nil
        }
        #endif
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let model, let tab = model.tab(for: webView) else { return }
        model.close(tab)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await ask(message, frame: frame, confirm: false)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await ask(message, frame: frame, confirm: true)
    }

    private func ask(_ message: String, frame: WKFrameInfo, confirm: Bool) async -> Bool {
        guard let model, model.presented, model.dialog == nil else { return false }
        let origin = frame.securityOrigin.host.isEmpty ? "This page" : frame.securityOrigin.host
        return await withCheckedContinuation { continuation in
            var answered = false
            model.dialog = BrowserDialog(origin: origin, message: String(message.prefix(2000)), confirm: confirm) { value in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: value)
            }
        }
    }
}
