import AmbulandoCore
import SwiftUI
import WebKit

/// The full-screen browser. All chrome is one compact bar at the bottom: **Ambulando** (always returns to the app
/// exactly as it was), back, forward, the site/address field, the tab switcher and an overflow menu for everything else.
struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var address = ""
    @FocusState private var editing: Bool

    private var browser: BrowserModel { model.browser }

    var body: some View {
        @Bindable var browser = browser
        VStack(spacing: 0) {
            FixtureBanner()
            ZStack {
                if let tab = browser.selected {
                    WebViewHost(webView: tab.webView).id(tab.id)
                    if tab.isBlank && !tab.loading { BrowserStartPage() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let refusal = browser.selected?.refusal { notice(refusal, systemImage: "exclamationmark.triangle").accessibilityIdentifier("browser.refusal") }
            if browser.locked {
                notice("Ambulando is locked. Websites cannot use your Nostr key until you unlock.", systemImage: "lock")
                    .accessibilityIdentifier("browser.locked")
            }
            bottomBar
        }
        .background(Amb.background)
        .onAppear { syncAddress() }
        .onChange(of: browser.selected?.url) { _, _ in if !editing { syncAddress() } }
        .onChange(of: browser.selectedId) { _, _ in syncAddress() }
        .sheet(item: Binding(get: { browser.prompt }, set: { value in
            // Swiped away: the same as rejecting.
            if value == nil, let prompt = browser.prompt { browser.answer(prompt, .deny(remember: false)) }
        })) { prompt in
            NostrApprovalSheet(prompt: prompt) { browser.answer(prompt, $0) }
        }
        .sheet(isPresented: $browser.showingTabs) { BrowserTabsView() }
        .confirmationDialog("Open in another app?", isPresented: Binding(get: { browser.pendingExternal != nil }, set: { if !$0 { browser.pendingExternal = nil } }),
                            titleVisibility: .visible, presenting: browser.pendingExternal) { url in
            Button("Open \(url.scheme ?? "link"):") { openURL(url); browser.pendingExternal = nil }
            Button("Cancel", role: .cancel) { browser.pendingExternal = nil }
        } message: { url in Text(String(url.absoluteString.prefix(300))) }
        .alert(browser.dialog?.origin ?? "", isPresented: Binding(get: { browser.dialog != nil }, set: { if !$0 { browser.dialog?.reply(false); browser.dialog = nil } }),
               presenting: browser.dialog) { dialog in
            if dialog.confirm { Button("Cancel", role: .cancel) { dialog.reply(false); browser.dialog = nil } }
            Button("OK") { dialog.reply(true); browser.dialog = nil }
        } message: { dialog in Text(dialog.message) }
    }

    /// The only browser chrome. While the address is being edited the bar gives the field the full width, plus Cancel.
    private var bottomBar: some View {
        HStack(spacing: 2) {
            if !editing {
                Button { browser.presented = false } label: {
                    Image("PassageMark").resizable().scaledToFit().frame(width: 22, height: 22).barTarget()
                }
                .accessibilityLabel("Back to Ambulando")
                .accessibilityIdentifier("browser.return")
                Button { browser.selected?.webView.goBack() } label: { Image(systemName: "chevron.left").barTarget() }
                    .disabled(!(browser.selected?.canGoBack ?? false)).accessibilityLabel("Back").accessibilityIdentifier("browser.back")
                Button { browser.selected?.webView.goForward() } label: { Image(systemName: "chevron.right").barTarget() }
                    .disabled(!(browser.selected?.canGoForward ?? false)).accessibilityLabel("Forward").accessibilityIdentifier("browser.forward")
            }
            addressField
            if editing {
                Button("Cancel") { editing = false }.font(.amb(.subheadline)).padding(.leading, 8).frame(minHeight: 44)
                    .accessibilityIdentifier("browser.address.cancel")
            } else {
                Button { browser.showingTabs = true } label: {
                    Text("\(browser.tabs.count)").font(.amb(.caption).weight(.bold)).frame(minWidth: 20, minHeight: 20)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Amb.foreground, lineWidth: 1.5))
                        .barTarget()
                }
                .accessibilityLabel("\(browser.tabs.count) open \(browser.tabs.count == 1 ? "tab" : "tabs")")
                .accessibilityIdentifier("browser.tabs")
                menu
            }
        }
        .font(.amb(.body).weight(.medium))
        .tabletReadingWidth()
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Amb.card.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            if let tab = browser.selected, tab.loading {
                ProgressView(value: tab.progress).progressViewStyle(.linear).tint(Amb.primary).frame(height: 2)
            } else {
                Rectangle().fill(Amb.border).frame(height: 0.5)
            }
        }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: browser.selected?.origin != nil ? "lock.fill" : "globe").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            TextField("Search or enter address", text: $address)
                .focused($editing)
                .urlEntry()
                .autocorrectionDisabled()
                .submitLabel(.go)
                .font(.amb(.subheadline))
                .onSubmit {
                    guard let tab = browser.selected else { return }
                    if browser.go(address, in: tab) { editing = false }
                }
                .onChange(of: editing) { _, on in
                    address = on ? (browser.selected?.url.flatMap { $0.scheme == "about" ? nil : $0.absoluteString } ?? "") : hostLabel
                }
                .accessibilityIdentifier("browser.address")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(Amb.muted, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 4)
    }

    /// Everything that is not used on every page, grouped: the current page, the tab, the site and browsing data.
    /// Page-level actions (such as saving the page as a favourite) are in `pageActions`; the bar itself stays at six controls.
    private var menu: some View {
        Menu {
            if let tab = browser.selected {
                Section { pageActions(tab) }
                Section {
                    Button { browser.open(nil) } label: { Label("New tab", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { browser.close(tab) } label: { Label("Close tab", systemImage: "xmark") }
                }
                if let origin = tab.origin, browser.sites[origin] != nil {
                    Section {
                        Button(role: .destructive) { browser.forget(origin: origin) } label: {
                            Label("Forget Nostr permission for \(URL(string: origin)?.host ?? origin)", systemImage: "key.slash")
                        }
                    }
                }
            } else {
                Button { browser.open(nil) } label: { Label("New tab", systemImage: "plus.square.on.square") }
            }
            Section {
                Button(role: .destructive) { Task { await browser.clearBrowsingData() } } label: { Label("Clear browsing data", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis.circle").barTarget()
        }
        .accessibilityLabel("Browser menu")
        .accessibilityIdentifier("browser.menu")
    }

    @ViewBuilder private func pageActions(_ tab: BrowserTab) -> some View {
        if tab.loading {
            Button { tab.webView.stopLoading() } label: { Label("Stop loading", systemImage: "xmark") }
        } else if let url = tab.url, !tab.isBlank {
            Button { browser.reload(url, in: tab) } label: { Label("Reload", systemImage: "arrow.clockwise") }
        }
        if let url = tab.url, url.scheme == "https" {
            if browser.favourites.favourite(for: url) != nil {
                Button { browser.toggleFavourite(tab) } label: { Label("Remove from Favourites", systemImage: "star.slash") }
            } else {
                Button { browser.toggleFavourite(tab) } label: { Label("Add to Favourites", systemImage: "star") }
            }
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            Button { openURL(url) } label: { Label("Open in Safari", systemImage: "safari") }
        }
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.amb(.caption)).foregroundStyle(Amb.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Amb.muted)
    }

    private var hostLabel: String {
        guard let url = browser.selected?.url, url.scheme != "about" else { return "" }
        return url.host ?? url.absoluteString
    }

    private func syncAddress() { address = editing ? address : hostLabel }
}

private extension View {
    /// A 44-point touch target for an icon in the browser bar.
    func barTarget() -> some View { frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
}

extension BrowserModel {
    func reload(_ url: URL, in tab: BrowserTab) {
        if let sample = samplePage, url.host == sample.url.host { load(url, in: tab) } else { tab.webView.reload() }
    }
}

/// Hosts a tab's existing `WKWebView`; switching tabs swaps which view is inside, never recreating one.
@MainActor
private struct WebViewHost {
    let webView: WKWebView

    private func attach(to container: PlatformView) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

#if os(iOS)
extension WebViewHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) { attach(to: container) }
}
#else
extension WebViewHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) { attach(to: container) }
}
#endif

/// Ambulando first, then every open tab.
struct BrowserTabsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let browser = model.browser
        NavigationStack {
            List {
                Section {
                    Button {
                        browser.showingTabs = false
                        browser.presented = false
                    } label: {
                        Label { Text("Ambulando").font(.amb(.body).weight(.semibold)) } icon: { Image("PassageMark").resizable().scaledToFit().frame(width: 22, height: 22) }
                    }
                    .accessibilityIdentifier("browser.tabs.ambulando")
                }
                Section("Tabs") {
                    ForEach(browser.tabs) { tab in
                        HStack {
                            Button { browser.select(tab) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tab.displayTitle).font(.amb(.subheadline).weight(tab.id == browser.selected?.id ? .semibold : .regular)).lineLimit(1)
                                    if let host = tab.url?.host { Text(host).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { browser.close(tab) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Amb.mutedForeground) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close \(tab.displayTitle)")
                        }
                        .accessibilityIdentifier("browser.tabs.item")
                    }
                }
            }
            .navigationTitle("Tabs")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { browser.showingTabs = false; browser.open(nil) } label: { Label("New tab", systemImage: "plus") }
                        .accessibilityIdentifier("browser.tabs.new")
                }
            }
        }
        // Without a size the Mac sheet collapsed to its toolbar and showed no tabs.
        .macSheetSize(minWidth: 440, idealWidth: 520, minHeight: 360, idealHeight: 480)
    }
}

/// The native question for `window.nostr`: which site is asking and, for a signature, exactly what is signed.
struct NostrApprovalSheet: View {
    let prompt: NIP07Prompt
    let decide: (NIP07Decision) -> Void
    @State private var remember: Bool

    init(prompt: NIP07Prompt, decide: @escaping (NIP07Decision) -> Void) {
        self.prompt = prompt; self.decide = decide
        // "Remember this site" starts on for the public key; an until-lock signing grant always starts off.
        _remember = State(initialValue: prompt.kind == .connect)
    }

    private var host: String { URL(string: prompt.context.origin)?.host ?? prompt.context.origin }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(host, systemImage: "lock.fill").font(.amb(.title3).weight(.semibold)).foregroundStyle(Amb.foreground)
                            .accessibilityIdentifier("nostr.origin")
                        Text(prompt.context.origin).font(.amb(.caption).monospaced()).foregroundStyle(Amb.mutedForeground)
                        Text(summary).font(.amb(.subheadline)).foregroundStyle(Amb.foreground)
                    }
                    .padding(.vertical, 4)
                }
                if case .sign(let event) = prompt.kind {
                    Section("What will be signed") {
                        LabeledContent("Kind", value: "\(event.kind) · \(Self.kindName(event.kind))")
                        LabeledContent("Time", value: Date(timeIntervalSince1970: TimeInterval(event.createdAt)).formatted(date: .abbreviated, time: .standard))
                        if event.content.isEmpty {
                            Text("No content").foregroundStyle(Amb.mutedForeground)
                        } else {
                            ScrollView { Text(String(event.content.prefix(4000)) + (event.content.count > 4000 ? "…" : ""))
                                    .font(.amb(.footnote).monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                                .frame(maxHeight: 180)
                                .accessibilityIdentifier("nostr.content")
                        }
                    }
                    if !event.tags.isEmpty {
                        Section("Tags (\(event.tags.count))") {
                            ForEach(Array(event.tags.prefix(20).enumerated()), id: \.offset) { _, tag in
                                Text(tag.map { String($0.prefix(120)) }.joined(separator: " · ")).font(.amb(.caption).monospaced()).lineLimit(3)
                            }
                            if event.tags.count > 20 { Text("and \(event.tags.count - 20) more").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
                        }
                    }
                }
                if let npub = prompt.npub {
                    Section("Your key") { Text(shortNpub(npub)).font(.amb(.footnote).monospaced()) }
                }
                if prompt.kind == .connect {
                    Section { Toggle("Remember for \(host)", isOn: $remember).accessibilityIdentifier("nostr.remember") } footer: {
                        Text("You can forget this in the browser menu. Signing still asks every time.")
                    }
                } else if prompt.offersSessionGrant {
                    Section { Toggle("Don't ask again for this kind on \(host) until Ambulando locks", isOn: $remember)
                            .accessibilityIdentifier("nostr.remember") } footer: {
                        Text("Only for sign-in requests. Other kinds always ask.")
                    }
                }
            }
            .navigationTitle(prompt.kind == .connect ? "Connect to Nostr" : "Sign with Nostr")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(prompt.kind == .connect ? "Don't allow" : "Reject") { decide(.deny(remember: prompt.kind == .connect && remember)) }
                        .accessibilityIdentifier("nostr.deny")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(prompt.kind == .connect ? "Allow" : "Sign") { decide(.allow(remember: remember)) }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("nostr.allow")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var summary: String {
        switch prompt.kind {
        case .connect: "wants to know your public Nostr key, so it can recognise you."
        case .sign: "asks you to sign this event with your Nostr key."
        }
    }

    static func kindName(_ kind: Int) -> String {
        switch kind {
        case 0: "Profile"
        case 1: "Note"
        case 3: "Follow list"
        case 4: "Direct message (NIP-04)"
        case 5: "Deletion"
        case 6: "Repost"
        case 7: "Reaction"
        case 1111: "Comment"
        case 9734: "Zap request"
        case 10002: "Relay list"
        case 22242: "Relay sign-in (NIP-42)"
        case 24242: "Blossom authorisation"
        case 27235: "HTTP sign-in (NIP-98)"
        case 30023: "Article"
        default: "Other"
        }
    }
}
