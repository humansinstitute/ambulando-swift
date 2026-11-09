import AmbulandoCore
import SwiftUI
import WebKit

/// A single read-only selection document per rich chat body. No account credentials or network are exposed.
/// The outer conversation owns vertical scrolling; tables and code retain their horizontal scrollers.
struct ChatSelectionView: View {
    let blocks: [RenderBlock]
    var muted = false
    var workspace: WorkspaceRecord?
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.imageLightbox) private var lightbox
    @Environment(AppModel.self) private var model
    @State private var page = ChatSelectionPage()
    @State private var image: LightboxImage?
    @State private var height: CGFloat = 24

    private var size: CGFloat {
        #if os(macOS)
        15 * ChatTypography.scale
        #else
        // Resolve the SwiftUI size, including the isolated layout fixture's override.
        let sizes: [DynamicTypeSize: CGFloat] = [.xSmall:14,.small:15,.medium:16,.large:17,.xLarge:19,.xxLarge:21,.xxxLarge:23,.accessibility1:28,.accessibility2:33,.accessibility3:40,.accessibility4:47,.accessibility5:53]
        return sizes[typeSize] ?? 17
        #endif
    }
    var body: some View {
        ChatSelectionWeb(page: page, html: ChatSelectionHTML.blocks(blocks), size: size, dark: scheme == .dark, muted: muted,
                         onHeight: { height = $0 }, onLink: open)
            .frame(height: height)
            .frame(maxWidth: ChatTypography.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .imageLightboxCover($image)
            .task(id: ChatSelectionHTML.blocks(blocks)) { await deliverImages() }
    }
    private func open(_ url: URL) {
        if url.scheme == "ambulando-image", let id = url.host, let workspace {
            if let file = model.fileCache?.attachment(workspaceId: workspace.id, objectId: id) {
                let shown = LightboxImage(objectId: id, file: file, alt: "Image")
                if let lightbox { lightbox.show(shown) } else { image = shown }
            } else { model.downloadAttachment(id, in: workspace) }
        } else { openURL(url) }
    }
    private func deliverImages() async {
        guard let workspace else { return }
        let html = ChatSelectionHTML.blocks(blocks)
        let pattern = #"data-object="([a-f0-9-]+)""#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = html as NSString
        var waiting = Set(regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
        guard !waiting.isEmpty else { return }
        var requested: Set<String> = []
        // Subscribe before reading cache; download completion invalidates messages in this workspace.
        guard let store = model.store else { return }
        let changes = await store.changes.stream()
        var iterator = changes.makeAsyncIterator()
        while !Task.isCancelled {
            for id in waiting {
                if let file = model.fileCache?.attachment(workspaceId: workspace.id, objectId: id) {
                    if let data = await Task.detached(priority: .userInitiated, operation: { DocumentEditorImages.dataURL(file) }).value {
                        page.images[id] = data; page.deliverImages()
                    }
                    waiting.remove(id)
                } else if model.isUnlocked, requested.insert(id).inserted { model.downloadAttachment(id, in: workspace) }
            }
            guard !waiting.isEmpty else { return }
            // This iterator suspends until a store change or view cancellation; no polling process.
            guard await iterator.next() != nil else { return }
        }
    }
}

@MainActor final class ChatSelectionPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var web: WKWebView?
    var html: String?
    var ready = false
    var images: [String:String] = [:]
    var onHeight: (CGFloat) -> Void = { _ in }
    var onLink: (URL) -> Void = { _ in }
    private var style: String?
    // Share an ephemeral store across message views so WebKit can share processes; no persistent website state.
    static let dataStore = WKWebsiteDataStore.nonPersistent()
    static let script = Bundle.main.url(forResource: "ChatSelection", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    static let template = Bundle.main.url(forResource: "ChatSelection", withExtension: "html").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    func update(html: String, size: CGFloat, dark: Bool, muted: Bool) {
        if self.html != html {
            let initial = self.html == nil
            self.html = html
            if initial {
                ready = false; style = nil
                web?.loadHTMLString(Self.template.replacingOccurrences(of: "<!--CONTENT-->", with: html), baseURL: nil)
            } else if ready {
                web?.callAsyncJavaScript("chatContent(html)", arguments: ["html":html], in: nil, in: .page, completionHandler: nil)
                deliverImages()
            }
        }
        let next = "chatStyle(\(size),\(dark),\(muted))"
        if style != next { style = next; if ready { web?.evaluateJavaScript(next) } }
    }
    func deliverImages() {
        guard ready else { return }
        for (id, data) in images {
            web?.callAsyncJavaScript("chatImage(id,data)", arguments: ["id":id,"data":data], in: nil, in: .page, completionHandler: nil)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let html { webView.callAsyncJavaScript("chatContent(html)", arguments: ["html":html], in: nil, in: .page, completionHandler: nil) }
        if let style { webView.evaluateJavaScript(style) }
        deliverImages()
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === web, let value = message.body as? [String:Any] else { return }
        switch value["type"] as? String {
        case "height":
            if let h = value["height"] as? Double, h.isFinite, h > 0 { onHeight(CGFloat(h)) }
        case "link": if let href = value["href"] as? String, let url = URL(string: href) { onLink(url) }
        case "code": if let text = value["text"] as? String { Pasteboard.copy(text) }
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.absoluteString == "about:blank" && action.navigationType == .other ? .allow : .cancel
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Recreate the read-only page after WebKit eviction; source text is unchanged.
        let saved = html; html = nil
        if let saved { webView.loadHTMLString(Self.template.replacingOccurrences(of: "<!--CONTENT-->", with: saved), baseURL: nil); html = saved }
    }
}

@MainActor struct ChatSelectionWeb {
    let page: ChatSelectionPage
    let html: String
    let size: CGFloat
    let dark: Bool
    let muted: Bool
    var onHeight: (CGFloat) -> Void
    var onLink: (URL) -> Void
    func make() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ChatSelectionPage.dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(WeakMessageHandler(page), name: "chatSelection")
        config.userContentController.addUserScript(WKUserScript(source: ChatSelectionPage.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = page
        #if os(iOS)
        web.isOpaque = false; web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.accessibilityIdentifier = "chat.selection"
        #else
        web.setValue(false, forKey: "drawsBackground")
        web.setAccessibilityIdentifier("chat.selection")
        #endif
        web.allowsLinkPreview = false
        page.web = web
        return web
    }
    func update() {
        page.onHeight = onHeight; page.onLink = onLink
        page.update(html: html, size: size, dark: dark, muted: muted)
    }
}
#if os(iOS)
extension ChatSelectionWeb: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { make() }
    func updateUIView(_ view: WKWebView, context: Context) { update() }
}
#else
extension ChatSelectionWeb: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { make() }
    func updateNSView(_ view: WKWebView, context: Context) { update() }
}
#endif
