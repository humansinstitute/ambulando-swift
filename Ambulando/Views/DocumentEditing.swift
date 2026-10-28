import AmbulandoCore
import SwiftUI
import UniformTypeIdentifiers

/// One editing session of a document: the edit lease, the durable draft, Save with Tower's version checks, pasted
/// uploads and the images the editor page shows. The text itself is edited in the page (`DocumentEditorPage`); this
/// model keeps the page's latest document and is the only thing that drafts or saves it.
///
/// - Rich documents (ProseMirror `editor_state`) come back from the page as JSON in which untouched content is the
///   stored JSON; they are checked (`DocumentBody.checkEdited`) and encoded in the representation they came from.
/// - Markdown documents (raw Markdown or a Markdown content model) come back as Markdown with untouched blocks in their
///   stored source, and are saved as Markdown.
/// - Nothing is sent to Tower until Save. A draft is written on every pause in typing and survives relaunch.
@MainActor
@Observable
final class DocEditorModel: UploadTokenHost {
    enum Mode: Equatable { case loading, rich, markdown, unavailable(String) }

    private(set) var mode: Mode = .loading
    var title = "" { didSet { if title != oldValue && !loading { markDirty() } } }
    /// The page's latest document (rich: JSON text; Markdown: text). Empty until the first edit.
    private(set) var content = ""
    var formatting = DocumentFormatting()
    var selection: DocumentAnchor?
    private(set) var status: String?
    private(set) var statusTone: Notice.Tone = .info
    private(set) var saving = false
    private(set) var leaseState = "Checking the edit lease…"
    private(set) var dirty = false
    private(set) var pageReady = false
    /// Upload placeholders this session put into the page; the page's next change event may not have arrived yet.
    private(set) var insertedTokens: [String] = []

    /// The `[[` the person is typing in the page (query text and the range to replace), while a link search is open.
    var wikiQuery: WikiQuery?

    @ObservationIgnored let doc: DocRecord
    @ObservationIgnored let workspace: WorkspaceRecord
    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let connection: ConnectionRecord
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored weak var page: DocumentEditorPage?
    /// Opens, creates and picks wiki links for this document; set by the screen that shows the editor.
    @ObservationIgnored weak var wiki: WikiLinkController?
    @ObservationIgnored private var body: DocumentBody?
    @ObservationIgnored private var original: JSONValue?
    @ObservationIgnored private var payload: String?
    @ObservationIgnored private var base: (rowVersion: Int, sha: String, object: String)?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var renew: Task<Void, Never>?
    @ObservationIgnored private var loading = true
    @ObservationIgnored private var waitingImages: Set<String> = []
    @ObservationIgnored private var downloadsRequested: Set<String> = []
    @ObservationIgnored private var imagePoll: Task<Void, Never>?

    init(doc: DocRecord, workspace: WorkspaceRecord, store: LocalStore, connection: ConnectionRecord, app: AppModel) {
        self.doc = doc; self.workspace = workspace; self.store = store; self.connection = connection; self.app = app
    }

    var draftKey: String { DocDraft.key(connectionId: connection.id, workspaceId: workspace.id, docId: doc.id) }

    // MARK: Load

    /// A saved draft wins over the cached body: unsaved work is never replaced by a newer download.
    func load() async {
        let store = store, w = workspace.id, d = doc.id, key = draftKey
        let draft = try? await store.reader.docDraft(key: key)
        let cached = try? await store.reader.docBody(workspaceId: w, docId: d)
        guard let source = draft.map({ ($0.body, $0.contentType) }) ?? cached.map({ ($0.bytes, $0.contentType) }) else {
            mode = .unavailable("This document's text is not on this \(Device.name) yet. Go back, unlock and open it again.")
            loading = false
            return
        }
        let decoded = await Task.detached { DocumentBody(bytes: source.0, contentType: source.1) }.value
        body = decoded
        if let draft { base = (draft.baseRowVersion, draft.baseSha256, draft.baseStorageObjectId); dirty = true; status = draft.lastError }
        else if let cached { base = (cached.docRowVersion, cached.sha256, cached.storageObjectId) }
        if let state = draft?.state, state == .recovery || state == .conflict { statusTone = .warning }
        title = draft?.title ?? doc.title
        switch decoded.editing {
        case .proseMirror:
            original = decoded.editorState
            let state = decoded.editorState ?? .object([("type", .string("doc")), ("content", .array([]))])
            if draft != nil { content = state.serializedString() }
            payload = Self.payload([("mode", .string("rich")), ("state", state)])
            mode = .rich
        case .markdown, .markdownModel:
            if draft != nil { content = decoded.markdown }
            payload = Self.payload([("mode", .string("markdown")), ("markdown", .string(decoded.markdown))])
            mode = .markdown
        case .readOnly(let reason):
            mode = .unavailable(reason)
        }
        loading = false
        if let payload { page?.load(payload) }
    }

    // MARK: Page

    func pageAttached() {
        // A page created again (the screen came back from a linked document) opens on the latest edit, not the stored text.
        if !content.isEmpty { rebuildPayloadFromContent() }
        if let payload { page?.load(payload) }
        WikiEditors.register(self)
    }

    /// The load message for the page, from the latest edit it reported.
    private func rebuildPayloadFromContent() {
        guard !content.isEmpty else { return }
        switch mode {
        case .rich:
            if let state = try? JSONValue.parse(Data(content.utf8)) { payload = Self.payload([("mode", .string("rich")), ("state", state)]) }
        case .markdown:
            payload = Self.payload([("mode", .string("markdown")), ("markdown", .string(content))])
        default: break
        }
    }

    func pageLoaded(ok: Bool, message: String?) {
        pageReady = ok
        if !ok { setStatus(message.map { "The editor could not open this document: \($0)" } ?? "The editor could not open this document.", .error) }
        else {
            #if os(macOS)
            page?.focus()
            #endif
            // Uploads for this document (also ones that finished while it was closed) apply once the page has it.
            app?.uploads?.attach(self)
            wiki?.pushTitles()
            #if DEBUG
            if app?.fixture != nil, ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureDocBridgeProbe") { page?.probeBridge() }
            #endif
        }
    }

    func pageChanged(_ next: String) {
        guard !loading, next != content else { return }
        content = next
        // A placeholder the page has reported is tracked through `content` from then on (deleting it removes it).
        insertedTokens.removeAll { UploadToken.contains(token: $0, in: next) }
        markDirty()
    }

    func pageError(_ message: String) { setStatus(message, .error) }

    // MARK: Wiki links in the page

    /// A link was opened in the page (`activate`), or the page reported a problem with one.
    func pageWiki(_ message: [String: Any]) {
        switch message["action"] as? String {
        case "activate":
            let id = (message["documentId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let title = (message["title"] as? String) ?? ""
            let range = (message["from"] as? Int).flatMap { from in (message["to"] as? Int).map { WikiEditorRange(from: from, to: $0) } }
            wiki?.activate(WikiTarget(documentId: id, title: title, occurrence: message["occurrence"] as? Int ?? 0, count: message["count"] as? Int ?? 0), range: range)
        case "error":
            if let text = message["message"] as? String { setStatus(text, .warning) }
        default: break
        }
    }

    func pageWikiQuery(_ message: [String: Any]) {
        guard message["active"] as? Bool == true, let from = message["from"] as? Int, let to = message["to"] as? Int else { wikiQuery = nil; return }
        wikiQuery = WikiQuery(text: message["query"] as? String ?? "", range: WikiEditorRange(from: from, to: to))
    }

    typealias WikiBinding = WikiEditorBinding

    /// Binds a created page into this open page and makes the result a durable draft before the creation write is retired.
    func bindWiki(title: String, documentId: String, occurrence: Int?, expectedCount: Int?) async -> WikiBinding {
        guard pageReady, let page, let count = await page.wikiBind(title: title, documentId: documentId, occurrence: occurrence, expectedCount: expectedCount)
        else { return .failed }
        if count > 0 { dirty = true }
        return await WikiEditorBinding.outcome(pageCount: count) { await self.checkpoint() }
    }

    /// Stores the current text as the durable draft. True when nothing is unsaved or the draft was written; false when it
    /// could not be (the caller must not leave, or retire anything that depends on it).
    func checkpoint() async -> Bool {
        if pageReady, let now = await page?.snapshot(), now != content { content = now; dirty = true }
        if !dirty { return true }
        return await persistDraft(state: .editing) != nil
    }

    /// The document moved: its drafts and the next save are based on the version the move produced.
    func rebase(rowVersion: Int) {
        if let current = base { base = (rowVersion, current.sha, current.object) }
    }

    /// Back on screen after another document was shown: the lease and upload results are taken up again.
    func reopen() {
        guard pageReady else { return }
        holdLease()
        app?.uploads?.attach(self)
        WikiEditors.register(self)
    }

    /// The page's process ended; it reloads and gets the latest edit back (the draft, or what it last reported).
    func pageTerminated() {
        pageReady = false
        guard let body else { return }
        if !content.isEmpty {
            switch mode {
            case .rich:
                if let state = try? JSONValue.parse(Data(content.utf8)) {
                    payload = Self.payload([("mode", .string("rich")), ("state", state)])
                }
            case .markdown:
                payload = Self.payload([("mode", .string("markdown")), ("markdown", .string(content))])
            default: break
            }
        } else if body.editing == .proseMirror, let state = body.editorState {
            payload = Self.payload([("mode", .string("rich")), ("state", state)])
        }
        if let payload { page?.load(payload) }
    }

    private func setStatus(_ text: String?, _ tone: Notice.Tone) { status = text; statusTone = tone }

    /// The page's `load` message: the document plus the paste limits of the upload pipeline.
    static func payload(_ fields: [(String, JSONValue)]) -> String {
        let limits = JSONValue.object([("maxFileBytes", .int(ComposerUploads.maxBytes)), ("maxFiles", .int(ComposerUploads.maxItemsPerPaste))])
        return JSONValue.object(fields + [("limits", limits)]).serializedString()
    }

    // MARK: Lease

    func holdLease() {
        guard let saver = app?.saver, app?.isUnlocked == true else { leaseState = "Editing on this \(Device.name). Unlock to save."; return }
        let connection = connection, workspace = workspace, id = doc.id
        renew?.cancel()
        renew = Task { [weak self] in
            do {
                try await saver.acquire(connection, workspace, docId: id)
                self?.leaseState = "You are editing (lease held)."
            } catch {
                self?.leaseState = (error as? LocalizedError)?.errorDescription ?? "Could not take the edit lease; your edits stay on this \(Device.name)."
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                do { try await saver.renew(connection, workspace, docId: id) }
                catch { self?.leaseState = "The edit lease expired; it is taken again when you save."; return }
            }
        }
    }

    /// Ends the session: stops renewing, releases the lease and stops receiving upload results.
    func close() {
        WikiEditors.unregister(self)
        debounce?.cancel()
        renew?.cancel()
        imagePoll?.cancel()
        app?.uploads?.detach(self)
        guard let saver = app?.saver else { return }
        let connection = connection, workspace = workspace, id = doc.id
        Task.detached { await saver.release(connection, workspace, docId: id) }
    }

    // MARK: Formatting

    func command(_ name: String, _ args: [String: String] = [:]) { page?.command(name, args) }

    /// Capture before comments take focus; save first so the anchor refers to canonical content.
    func commentAnchor(_ selected: DocumentAnchor) async -> DocumentAnchor? {
        if let now = await page?.snapshot() { pageChanged(now) }
        if dirty, !(await save()) { return nil }
        guard let cached = try? await store.reader.docBody(workspaceId: workspace.id, docId: doc.id) else { return nil }
        let body = DocumentBody(bytes: cached.bytes, contentType: cached.contentType)
        if let state = body.editorState, DocumentAnchors.selectedText(selected, in: state) == selected.quote {
            return DocumentAnchor(quote: selected.quote, from: selected.from, to: selected.to, version: cached.docRowVersion)
        }
        let spans = body.editorState.map(DocumentAnchors.spans)
            ?? DocumentAnchors.markdownSpans(body.markdown, blocks: DocumentRender.blocks(body))
        guard let resolved = DocumentAnchors.resolve(selected, in: spans) else {
            setStatus("That selection cannot be located in the saved document. Select a passage within a paragraph and try again.", .warning)
            return nil
        }
        return resolved.span.anchor(resolved.range, version: cached.docRowVersion)
    }

    // MARK: Draft persistence

    private func markDirty() {
        dirty = true
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            _ = await self?.persistDraft(state: .editing)
        }
    }

    /// Encodes the current edit (off the main actor) and stores it as the durable draft.
    @discardableResult
    func persistDraft(state draftState: DocDraft.State) async -> DocDraft? {
        if pageReady, let now = await page?.snapshot(), now != content { content = now; dirty = true }
        guard let body, let base, dirty else { return nil }
        let mode = mode, content = content, original = original, title = title
        let identity = (connection.id, workspace.id, doc.id)
        let encoded: Result<(Data, String), Error> = await Task.detached {
            do {
                switch mode {
                case .markdown:
                    let r = try body.encoded(markdown: content.isEmpty ? body.markdown : content)
                    return .success((r.bytes, r.contentType))
                case .rich:
                    guard let state = content.isEmpty ? body.editorState : try JSONValue.parse(Data(content.utf8)) else { throw DocumentEditError.unsupported }
                    try DocumentBody.checkEdited(state, original: original)
                    let r = try body.encoded(editorState: state)
                    return .success((r.bytes, r.contentType))
                default:
                    throw DocumentEditError.unsupported
                }
            } catch { return .failure(error) }
        }.value
        switch encoded {
        case .failure(let error):
            setStatus((error as? LocalizedError)?.errorDescription ?? "This edit could not be encoded without loss, so it was not saved.", .error)
            return nil
        case .success(let bytes):
            let draft = DocDraft(connectionId: identity.0, workspaceId: identity.1, docId: identity.2, title: title.isEmpty ? doc.title : title,
                                 body: bytes.0, contentType: bytes.1, baseRowVersion: base.rowVersion, baseSha256: base.sha,
                                 baseStorageObjectId: base.object, state: draftState)
            do { try await store.writer.saveDocDraft(draft) } catch {
                setStatus("Your edits could not be stored on this \(Device.name): \(error.localizedDescription)", .error)
                return nil
            }
            return draft
        }
    }

    /// Saves through Tower (lease, expected version). True when Tower made it the canonical version.
    func save() async -> Bool {
        guard let saver = app?.saver else { return false }
        debounce?.cancel()
        saving = true
        defer { saving = false }
        // Take the page's document as it is right now (a pause-in-typing event may not have arrived yet).
        if let now = await page?.snapshot(), now != content, !loading {
            content = now
            dirty = true
        }
        guard !UploadToken.contains(in: uploadText) else { setStatus(ComposerUploadError.unresolved.localizedDescription, .warning); return false }
        guard let draft = await persistDraft(state: .editing) else {
            if !dirty { setStatus("No changes to save.", .info) }
            return !dirty
        }
        setStatus("Saving…", .info)
        switch await saver.save(draft, connection: connection, workspace: workspace) {
        case .saved(_, let saved):
            dirty = false
            base = (saved.docRowVersion, saved.sha256, saved.storageObjectId)
            setStatus("Saved.", .success)
            return true
        case .recovery(_, let message):
            // Someone saved first: show their version in the reader behind the editor (the draft stays).
            setStatus(message, .warning)
            app?.openDoc(doc.id, in: workspace, force: true)
            return false
        case .leaseHeld(let message), .notSaved(let message):
            setStatus(message, .warning)
            return false
        }
    }

    /// Drops the local draft (the user chose the stored version over their unsaved edit).
    func discardDraft() async {
        debounce?.cancel()
        try? await store.writer.deleteDocDraft(key: draftKey, workspaceId: workspace.id)
        dirty = false
    }

    /// The edit as text, for "Copy my text" when a save could not go through.
    var draftText: String {
        switch mode {
        case .markdown: return content.isEmpty ? (body?.markdown ?? "") : content
        case .rich:
            guard let state = content.isEmpty ? body?.editorState : try? JSONValue.parse(Data(content.utf8)) else { return "" }
            return ProseMirrorMarkdown.markdown(state)
        default: return ""
        }
    }

    // MARK: Images in the page

    func pageNeedsImage(_ objectId: String) {
        guard UUID(uuidString: objectId) != nil else { return }
        waitingImages.insert(objectId.lowercased())
        deliverImages()
    }

    /// Sends the page every image it asked for that is now in the file cache, asks once for downloads of the rest, and
    /// checks again every second for a minute (a download lands in the cache without any other signal).
    func deliverImages() {
        guard let app, let cache = app.fileCache else { return }
        for id in waitingImages {
            if let file = cache.attachment(workspaceId: workspace.id, objectId: id) {
                waitingImages.remove(id)
                Task { [weak self] in
                    guard let url = await Task.detached(priority: .userInitiated, operation: { DocumentEditorImages.dataURL(file) }).value else { return }
                    self?.page?.setImage(id, dataURL: url)
                }
            } else if app.isUnlocked, !downloadsRequested.contains(id) {
                downloadsRequested.insert(id)
                app.downloadAttachment(id, in: workspace)
            }
        }
        guard !waitingImages.isEmpty, imagePoll == nil else { return }
        imagePoll = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, !self.waitingImages.isEmpty else { break }
                self.deliverImages()
            }
            self?.imagePoll = nil
        }
    }

    // MARK: Pasted files (sol doc rich paste → native upload pipeline)

    /// The page announced a paste: files over the upload limit or past the per-paste count were not sent.
    func pageAnnouncedPaste(skipped: Int, tooLarge: Int) {
        if tooLarge > 0 { setStatus(ComposerUploadError.tooLarge.localizedDescription, .warning) }
        else if skipped > 0 { setStatus("Only the first \(ComposerUploads.maxItemsPerPaste) pasted items are uploaded.", .info) }
    }

    /// One pasted file from the page (`<index>\n<name>\n<type>\n<base64>`). It is decoded off the main actor, then
    /// goes through the same paste pipeline as chat (metadata stripped, staged, uploaded with retry), and its
    /// placeholder goes in at the caret.
    func pageSentFile(_ body: String) {
        guard let uploads = app?.uploads else { setStatus(ComposerUploadError.locked.localizedDescription, .warning); return }
        let target = uploadTarget, appNpub = workspace.appNpub
        Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { () -> (data: Data, name: String, type: UTType)? in
                let parts = body.split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4, let data = Data(base64Encoded: String(parts[3])), data.count <= ComposerUploads.maxBytes else { return nil }
                let name = String(parts[1].prefix(255)), mime = String(parts[2].prefix(127))
                let type = UTType(mimeType: mime) ?? UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
                return (data, name, type)
            }.value
            guard let self else { return }
            guard let decoded else { self.setStatus(ComposerUploadError.unreadable.localizedDescription, .warning); return }
            let provider = NSItemProvider()
            let data = decoded.data
            provider.registerDataRepresentation(forTypeIdentifier: decoded.type.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            if !decoded.name.isEmpty { provider.suggestedName = decoded.name }
            let tokens = uploads.paste([provider], target: target, appNpub: appNpub, context: "doc-rich")
            if !tokens.isEmpty { self.insertedTokens += tokens; self.page?.insertUploads(tokens) }
        }
    }

    // MARK: UploadTokenHost

    var uploadTarget: ChatTarget { ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: "content-doc-\(doc.id)") }
    var uploadText: String { ([content] + insertedTokens).joined(separator: "\n") }

    /// Puts the uploaded image or file where its placeholder is (sol `replaceDocRichUploadPlaceholder`), or removes it.
    func replaceUploadToken(_ token: String, with replacement: String) -> Bool {
        guard let page, UploadToken.contains(token: token, in: uploadText) else { return false }
        page.replaceUpload(token, node: Self.storageNode(replacement))
        insertedTokens.removeAll { $0 == token }
        return true
    }

    /// The editor node for storage Markdown from an upload (`![name](storage://id)` / `[name](storage://id)`).
    static func storageNode(_ markdown: String) -> JSONValue? {
        let pattern = try! NSRegularExpression(pattern: #"^(!?)\[([^\]\n]*)\]\(storage://([A-Fa-f0-9-]{36})\)$"#)
        let ns = markdown as NSString
        guard let m = pattern.firstMatch(in: markdown, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let id = ns.substring(with: m.range(at: 3)), name = ns.substring(with: m.range(at: 2))
        if ns.substring(with: m.range(at: 1)) == "!" {
            return .object([("type", .string("fdStorageImage")), ("attrs", .object([
                ("src", .string("storage://\(id)")), ("objectId", .string(id)), ("alt", .string(name)), ("title", .string(name))]))])
        }
        return .object([("type", .string("fdStorageFile")), ("attrs", .object([
            ("src", .string("storage://\(id)")), ("title", .string(name)), ("label", .string(name))]))])
    }
}
