import AmbulandoCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// The document editor page (`BoardEditor/web/document.html`, built into `BoardEditor.bundle`): the web app's document
// editor (Tiptap with sol's schema), shown inside the app's white paper while the user edits. It is served from the
// bundle through the same `ambulando-board:` scheme as the board editor, but gets only its own `document` message
// bridge. The page has no signer, keys or `window.nostr`, cannot navigate or fetch (its CSP and the navigation policy),
// keeps no website data, and sees stored images only as data URLs the app hands it. Everything it edits comes back to
// `DocEditorModel`, which alone drafts and saves through Tower with the edit lease and version checks.

/// What the page reports as active at the selection (its `state` message).
struct DocumentFormatting: Equatable, Sendable {
    var bold = false, italic = false, strike = false, code = false
    var heading = 0
    var bulletList = false, orderedList = false, taskList = false, blockquote = false, codeBlock = false
    var link: String?
    var canUndo = false, canRedo = false, selection = false

    init() {}
    init(_ o: [String: Any]) {
        bold = o["bold"] as? Bool ?? false; italic = o["italic"] as? Bool ?? false
        strike = o["strike"] as? Bool ?? false; code = o["code"] as? Bool ?? false
        heading = o["heading"] as? Int ?? 0
        bulletList = o["bulletList"] as? Bool ?? false; orderedList = o["orderedList"] as? Bool ?? false
        taskList = o["taskList"] as? Bool ?? false; blockquote = o["blockquote"] as? Bool ?? false
        codeBlock = o["codeBlock"] as? Bool ?? false; link = o["link"] as? String
        canUndo = o["canUndo"] as? Bool ?? false; canRedo = o["canRedo"] as? Bool ?? false
        selection = o["selection"] as? Bool ?? false
    }
}

/// One loaded editor page. The model talks to it only through this object.
@MainActor
final class DocumentEditorPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let path = "/document.html"
    /// Small messages (ready, change, state, image requests, paste announcements).
    static let handler = "document"
    /// One pasted file per message, base64, within the upload pipeline's own limit (`ComposerUploads.maxBytes`).
    static let fileHandler = "documentFile"
    /// A document's edited JSON or Markdown is far below this; anything larger is refused (the draft is unchanged).
    static let maxMessageBytes = 32 * 1024 * 1024
    static var maxFileMessageBytes: Int { (ComposerUploads.maxBytes + 2) / 3 * 4 + 1024 }

    weak var webView: WKWebView?
    weak var editor: DocEditorModel?
    private var loaded = false
    private var ready = false
    private var pendingLoad: String?
    private var style: String?

    func attach(_ webView: WKWebView, editor: DocEditorModel) {
        self.webView = webView
        self.editor = editor
        editor.page = self
        var components = URLComponents()
        components.scheme = BoardEditorBundle.scheme; components.host = "editor"; components.path = Self.path
        if let url = components.url { webView.load(URLRequest(url: url)) }
    }

    func stop() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handler)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.fileHandler)
        if editor?.page === self { editor?.page = nil }
    }

    // MARK: To the page

    /// Opens the document in the page (once it is ready).
    func load(_ payload: String) {
        pendingLoad = payload
        if ready { deliverLoad() }
    }

    private func deliverLoad() {
        guard let payload = pendingLoad else { return }
        pendingLoad = nil
        if let style { call("setStyle", style) }
        call("load", payload)
    }

    func setStyle(_ sizes: [String: CGFloat]) {
        guard let data = try? JSONSerialization.data(withJSONObject: sizes.mapValues { Double($0) }, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8), json != style else { return }
        style = json
        if ready { call("setStyle", json) }
    }

    func command(_ name: String, _ args: [String: String] = [:]) {
        let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
        call("command", name, String(decoding: data, as: UTF8.self))
    }

    func insertUploads(_ tokens: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: tokens) else { return }
        call("insertUploads", String(decoding: data, as: UTF8.self))
    }

    func replaceUpload(_ token: String, node: JSONValue?) {
        call("replaceUpload", token, node?.serializedString())
    }

    func setImage(_ objectId: String, dataURL: String) { call("setImage", objectId, dataURL) }

    func focus() { call("focus") }

    func reveal(_ anchor: DocumentAnchor) {
        guard let data = try? JSONSerialization.data(withJSONObject: anchor.metadata) else { return }
        call("reveal", String(decoding: data, as: UTF8.self))
    }


    /// The edited document now, flushed from the page (nil: no page or it failed).
    func snapshot() async -> String? {
        guard ready, let webView else { return nil }
        let result = try? await webView.callAsyncJavaScript("return window.ambulandoDocument ? window.ambulandoDocument.snapshot() : null",
                                                            arguments: [:], contentWorld: .page)
        return result as? String
    }

    private func call(_ function: String, _ arguments: String?...) {
        guard let webView else { return }
        var args: [String: Any] = [:]
        var names: [String] = []
        for (index, value) in arguments.enumerated() {
            args["a\(index)"] = value ?? NSNull()
            names.append("a\(index)")
        }
        let script = "return window.ambulandoDocument ? window.ambulandoDocument.\(function)(\(names.joined(separator: ", "))) : false"
        webView.callAsyncJavaScript(script, arguments: args, in: nil, in: .page, completionHandler: nil)
    }

    #if DEBUG
    /// Sample data only (`-AmbulandoFixtureDocBridgeProbe`): the page sends what the bridge must refuse, an oversize
    /// message, an undecodable file and a post from a frame, so the refusals can be checked in the running app.
    func probeBridge() {
        let script = """
        const h = window.webkit.messageHandlers;
        h.document.postMessage('{"type":"change","content":"' + 'x'.repeat(33 * 1024 * 1024) + '"}');
        setTimeout(() => h.documentFile.postMessage('0\\nprobe.png\\nimage/png\\n@@not-base64@@'), 4000);
        setTimeout(() => {
          const frame = document.createElement('iframe');
          frame.style.display = 'none';
          frame.srcdoc = '<script>parent.webkit.messageHandlers.document.postMessage(JSON.stringify({type:"change",content:"from a frame"}))<\\/script>';
          document.body.append(frame);
        }, 8000);
        return true;
        """
        webView?.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page, completionHandler: nil)
    }
    #endif

    // MARK: From the page

    /// Only the bundled document page itself, in the main frame of this editor's web view, may talk to the editor.
    static func isEditorPage(_ message: WKScriptMessage, of webView: WKWebView?) -> Bool {
        guard message.frameInfo.isMainFrame, let webView, message.webView === webView, let url = message.frameInfo.request.url else { return false }
        return url.scheme == BoardEditorBundle.scheme && url.host == "editor" && url.path == path && url.user == nil && url.port == nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard Self.isEditorPage(message, of: webView), let body = message.body as? String else { return }
        if message.name == Self.fileHandler {
            // `<index>\n<name>\n<type>\n<base64>`; decoded off the main actor by the model.
            guard body.utf8.count <= Self.maxFileMessageBytes else {
                editor?.pageError(ComposerUploadError.tooLarge.localizedDescription)
                return
            }
            editor?.pageSentFile(body)
            return
        }
        guard message.name == Self.handler else { return }
        guard body.utf8.count <= Self.maxMessageBytes else {
            editor?.pageError("The editor sent more than this app accepts, so it was ignored. Your saved draft is unchanged.")
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            deliverLoad()
        case "loaded":
            editor?.pageLoaded(ok: object["ok"] as? Bool ?? false, message: object["message"] as? String)
        case "change":
            if let content = object["content"] as? String { editor?.pageChanged(content) }
        case "selection":
            editor?.selection = (object["anchor"] as? [String: Any]).flatMap { DocumentAnchor(metadata: $0) }
        case "state":
            editor?.formatting = DocumentFormatting(object["active"] as? [String: Any] ?? [:])
        case "need-image":
            if let id = object["objectId"] as? String { editor?.pageNeedsImage(id) }
        case "paste-files":
            editor?.pageAnnouncedPaste(skipped: object["skipped"] as? Int ?? 0, tooLarge: object["tooLarge"] as? Int ?? 0)
        case "error":
            editor?.pageError(object["message"] as? String ?? "The editor reported an error.")
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        // The bundled page itself (first load, or a reload after its process ended); nothing else, no frames.
        if url.scheme == BoardEditorBundle.scheme, url.host == "editor", url.path == Self.path, action.targetFrame?.isMainFrame == true,
           !loaded || action.navigationType == .reload {
            loaded = true
            return .allow
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The model keeps the last change and the durable draft; the page reopens from them.
        ready = false
        loaded = false
        editor?.pageTerminated()
        webView.reload()
    }
}

/// The editor page as a view. The paper around it is native.
@MainActor struct DocumentEditorWebView {
    let editor: DocEditorModel

    func makeCoordinator() -> DocumentEditorPage { DocumentEditorPage() }

    @MainActor func makeWebView(_ page: DocumentEditorPage) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(BoardSchemeHandler(), forURLScheme: BoardEditorBundle.scheme)
        configuration.userContentController.add(WeakMessageHandler(page), name: DocumentEditorPage.handler)
        configuration.userContentController.add(WeakMessageHandler(page), name: DocumentEditorPage.fileHandler)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        configuration.dataDetectorTypes = []
        #endif
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = page
        webView.uiDelegate = page
        webView.allowsLinkPreview = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.accessibilityIdentifier = "doc.editor"
        #else
        webView.setAccessibilityIdentifier("doc.editor")
        #endif
        page.attach(webView, editor: editor)
        editor.pageAttached()
        return webView
    }
}

#if os(iOS)
extension DocumentEditorWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: DocumentEditorPage) { coordinator.stop() }
}
#else
extension DocumentEditorWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: DocumentEditorPage) { coordinator.stop() }
}
#endif

// MARK: Images for the page

enum DocumentEditorImages {
    /// A stored image file as a downsampled JPEG (PNG when it has transparency) data URL, off the main actor.
    nonisolated static func dataURL(_ file: URL, maxPixels: CGFloat = 1800) -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let alpha = image.alphaInfo
        let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
        let type = opaque ? UTType.jpeg : UTType.png
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/\(opaque ? "jpeg" : "png");base64," + (data as Data).base64EncodedString()
    }
}
