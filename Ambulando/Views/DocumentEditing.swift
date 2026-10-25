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
    private(set) var status: String?
    private(set) var statusTone: Notice.Tone = .info
    private(set) var saving = false
    private(set) var leaseState = "Checking the edit lease…"
    private(set) var dirty = false
    private(set) var pageReady = false

    @ObservationIgnored let doc: DocRecord
    @ObservationIgnored let workspace: WorkspaceRecord
    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let connection: ConnectionRecord
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored weak var page: DocumentEditorPage?
    @ObservationIgnored private var body: DocumentBody?
    @ObservationIgnored private var original: JSONValue?
    @ObservationIgnored private var payload: String?
    @ObservationIgnored private var base: (rowVersion: Int, sha: String, object: String)?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var renew: Task<Void, Never>?
    @ObservationIgnored private var loading = true
    @ObservationIgnored private var waitingImages: Set<String> = []

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
            payload = JSONValue.object([("mode", .string("rich")), ("state", state)]).serializedString()
            mode = .rich
        case .markdown, .markdownModel:
            if draft != nil { content = decoded.markdown }
            payload = JSONValue.object([("mode", .string("markdown")), ("markdown", .string(decoded.markdown))]).serializedString()
            mode = .markdown
        case .readOnly(let reason):
            mode = .unavailable(reason)
        }
        loading = false
        if let payload { page?.load(payload) }
        if let uploads = app?.uploads { uploads.attach(self) }
    }

    // MARK: Page

    func pageAttached() {
        if let payload { page?.load(payload) }
    }

    func pageLoaded(ok: Bool, message: String?) {
        pageReady = ok
        if !ok { setStatus(message.map { "The editor could not open this document: \($0)" } ?? "The editor could not open this document.", .error) }
        else { page?.focus() }
    }

    func pageChanged(_ next: String) {
        guard !loading, next != content else { return }
        content = next
        markDirty()
    }

    func pageError(_ message: String) { setStatus(message, .error) }

    /// The page's process ended; it reloads and gets the latest edit back (the draft, or what it last reported).
    func pageTerminated() {
        pageReady = false
        guard let body else { return }
        if !content.isEmpty {
            switch mode {
            case .rich:
                if let state = try? JSONValue.parse(Data(content.utf8)) {
                    payload = JSONValue.object([("mode", .string("rich")), ("state", state)]).serializedString()
                }
            case .markdown:
                payload = JSONValue.object([("mode", .string("markdown")), ("markdown", .string(content))]).serializedString()
            default: break
            }
        } else if body.editing == .proseMirror, let state = body.editorState {
            payload = JSONValue.object([("mode", .string("rich")), ("state", state)]).serializedString()
        }
        if let payload { page?.load(payload) }
    }

    private func setStatus(_ text: String?, _ tone: Notice.Tone) { status = text; statusTone = tone }

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
        debounce?.cancel()
        renew?.cancel()
        app?.uploads?.detach(self)
        guard let saver = app?.saver else { return }
        let connection = connection, workspace = workspace, id = doc.id
        Task.detached { await saver.release(connection, workspace, docId: id) }
    }

    // MARK: Formatting

    func command(_ name: String, _ args: [String: String] = [:]) { page?.command(name, args) }

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
            try? await store.writer.saveDocDraft(draft)
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
        guard !UploadToken.contains(in: content) else { setStatus(ComposerUploadError.unresolved.localizedDescription, .warning); return false }
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
        case .recovery(_, let message), .leaseHeld(let message), .notSaved(let message):
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

    /// Sends the page every image it asked for that is now in the file cache; asks for downloads of the rest.
    func deliverImages() {
        guard let app, let cache = app.fileCache else { return }
        for id in waitingImages {
            if let file = cache.attachment(workspaceId: workspace.id, objectId: id) {
                waitingImages.remove(id)
                Task { [weak self] in
                    guard let url = await Task.detached(priority: .userInitiated, operation: { DocumentEditorImages.dataURL(file) }).value else { return }
                    self?.page?.setImage(id, dataURL: url)
                }
            } else if app.isUnlocked {
                app.downloadAttachment(id, in: workspace)
            }
        }
    }

    // MARK: Pasted files (sol doc rich paste → native upload pipeline)

    func pagePasted(_ files: [[String: Any]]) {
        guard let app, let uploads = app.uploads else { setStatus(ComposerUploadError.locked.localizedDescription, .warning); return }
        var providers: [NSItemProvider] = []
        var tooLarge = false
        for file in files {
            if file["tooLarge"] as? Bool == true { tooLarge = true; continue }
            guard let encoded = file["data"] as? String, let data = Data(base64Encoded: encoded) else { continue }
            let mime = (file["type"] as? String) ?? ""
            let name = (file["name"] as? String) ?? ""
            let type = UTType(mimeType: mime) ?? UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            if !name.isEmpty { provider.suggestedName = name }
            providers.append(provider)
        }
        if tooLarge { setStatus(ComposerUploadError.tooLarge.localizedDescription, .warning) }
        let tokens = uploads.paste(providers, target: uploadTarget, appNpub: workspace.appNpub, context: "doc-rich")
        if !tokens.isEmpty { page?.insertUploads(tokens) }
    }

    // MARK: UploadTokenHost

    var uploadTarget: ChatTarget { ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: "content-doc-\(doc.id)") }
    var uploadText: String { content }

    /// Puts the uploaded image or file where its placeholder is (sol `replaceDocRichUploadPlaceholder`), or removes it.
    func replaceUploadToken(_ token: String, with replacement: String) -> Bool {
        guard let page, UploadToken.contains(token: token, in: content) else { return false }
        page.replaceUpload(token, node: Self.storageNode(replacement))
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
