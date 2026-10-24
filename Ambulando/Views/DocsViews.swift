import AmbulandoCore
import SwiftUI

// MARK: List

struct DocsSnapshot: Sendable, Equatable {
    var docs: [DocRecord] = []
    var drafts: Set<String> = []
    var creating: [WriteItem] = []
    var choice = ScopeChoice()
}

struct DocumentsView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var scopeId: String?
    @State private var filter = ""
    @State private var snapshot = LiveQuery<DocsSnapshot>(initial: DocsSnapshot())
    @State private var creating = false

    private var visible: [DocRecord] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? snapshot.value.docs : snapshot.value.docs.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        List {
            ForEach(snapshot.value.creating) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.string("title") ?? "Document").font(.subheadline.weight(.semibold))
                    WriteStatusLine(item: item, label: "New document")
                }
            }
            ForEach(visible) { doc in
                NavigationLink(value: WorkRoute.doc(workspaceId: workspace.id, docId: doc.id)) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").foregroundStyle(Amb.primary)
                            Text(doc.title).font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(2)
                        }
                        HStack(spacing: 6) {
                            if let channel = snapshot.value.choice.channelName(doc.channelId) { Text("#\(channel)") }
                            Text(ChatTime.label(doc.updatedAt))
                            if snapshot.value.drafts.contains(doc.id) { Label("Unsaved edits", systemImage: "pencil.circle").foregroundStyle(Amb.warning) }
                        }
                        .font(.caption).foregroundStyle(Amb.mutedForeground)
                    }
                }
                .accessibilityIdentifier("doc.\(doc.title)")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter documents")
        .overlay {
            if snapshot.loaded && snapshot.value.docs.isEmpty && snapshot.value.creating.isEmpty {
                EmptyNote(title: "No documents", systemImage: "doc.text", detail: model.isUnlocked ? "Documents in this scope appear here." : "Unlock to load documents.")
            }
        }
        .navigationTitle("Docs")
        .safeAreaInset(edge: .top, spacing: 0) {
            ListHeaderBar {
                ScopeMenu(choice: snapshot.value.choice, selection: $scopeId)
                Spacer()
                Button { creating = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                    .accessibilityLabel("New document").accessibilityIdentifier("docs.new")
            }
        }
        .sheet(isPresented: $creating) { DocumentCreateSheet(workspace: workspace, choice: snapshot.value.choice, scopeId: scopeId) }
        .refreshable { model.openDocs(workspace, scopeId: scopeId, force: true) }
        .task(id: scopeId) { start(); model.openDocs(workspace, scopeId: scopeId) }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { model.openDocs(workspace, scopeId: scopeId) } }
    }

    private func start() {
        let w = workspace.id, scope = scopeId, store = store, connection = model.connection?.id ?? ""
        snapshot.start(store: store, matches: { $0.workspaceId == w && [.docs, .docDrafts, .writes, .channels, .scopes].contains($0.table) }) {
            async let docs = store.reader.docs(workspaceId: w, scopeId: scope)
            async let drafts = store.reader.docDraftIds(connectionId: connection, workspaceId: w)
            async let writes = store.reader.writes(connectionId: connection, workspaceId: w)
            async let choice = scopeChoice(store, w)
            return DocsSnapshot(docs: try await docs, drafts: try await drafts, creating: try await writes.filter { $0.kind == .docCreate },
                                choice: try await choice)
        }
    }
}

struct DocumentCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceRecord
    let choice: ScopeChoice
    let scopeId: String?
    @State private var title = ""
    @State private var text = ""
    @State private var channelId: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title).accessibilityIdentifier("newdoc.title")
                Picker("Channel", selection: $channelId) {
                    ForEach(choice.channels.filter { scopeId == nil || $0.scopeId == scopeId }) { Text("#\($0.name)").tag(Optional($0.id)) }
                }
                Section("Text") { TextEditor(text: $text).frame(minHeight: 160).accessibilityIdentifier("newdoc.text") }
                if let error { Text(error).foregroundStyle(Amb.destructive) }
            }
            .navigationTitle("New document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || channelId == nil)
                        .accessibilityIdentifier("newdoc.create")
                }
            }
            .onAppear { channelId = channelId ?? choice.channels.first { scopeId == nil || $0.scopeId == scopeId }?.id }
        }
    }

    /// The body is built in the web format and staged on the device; the write queue uploads it and creates the record.
    private func create() {
        guard let channelId, let staging = model.staging else { return }
        let created = DocumentBody.newDocument(text: text)
        let name = UUID().uuidString.lowercased() + ".document.json"
        do {
            try created.bytes.write(to: staging.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { self.error = error.localizedDescription; return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: any Sendable] = ["channel_id": channelId, "title": clean, "staged": name, "content_type": created.contentType,
                                               "file_name": String(clean.prefix(60)) + ".document.json"]
        if model.submit(WriteIntent(kind: .docCreate, targetId: channelId, payload: payload), in: workspace) { dismiss() }
    }
}

// MARK: Reader

struct DocumentSnapshot: Sendable, Equatable {
    var doc: DocRecord?
    var blocks: [RenderBlock] = []
    var hasBody = false
    var editable = false
    var readOnlyReason: String?
    var draft: DocDraft?
    var comments: [CommentRecord] = []
    var pendingComments: [WriteItem] = []
    var names: [String: String] = [:]
    var choice = ScopeChoice()
}

struct DocumentView: View {
    @Environment(AppModel.self) private var model
    let docId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var snapshot = LiveQuery<DocumentSnapshot>(initial: DocumentSnapshot())
    @State private var editing = false
    @State private var comment = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let doc = snapshot.value.doc {
                    Text(doc.title).font(Amb.editorial).foregroundStyle(Amb.foreground).accessibilityIdentifier("doc.title")
                    Text([snapshot.value.choice.scopeName(doc.scopeId), snapshot.value.choice.channelName(doc.channelId).map { "#\($0)" }, ChatTime.label(doc.updatedAt)]
                        .compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(Amb.mutedForeground)
                }
                if let draft = snapshot.value.draft {
                    Button { editing = true } label: {
                        Notice(tone: draft.state == .recovery || draft.state == .conflict ? .warning : .info,
                               text: draft.lastError ?? "You have unsaved edits on this iPhone. Tap to continue editing.")
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("doc.draftBanner")
                }
                if let reason = snapshot.value.readOnlyReason { Notice(tone: .info, text: reason) }
                if snapshot.value.hasBody {
                    RichBlocksView(blocks: snapshot.value.blocks, style: .document, workspace: workspace)
                        .accessibilityElement(children: .contain).accessibilityIdentifier("doc.body")
                } else if snapshot.loaded {
                    SyncNote(text: model.syncError(forKey: WorkspaceSync.docKey(workspace.id, docId))
                             ?? (model.isUnlocked ? "Loading document…" : "This document is not saved on this iPhone yet. Unlock to load it."))
                }
                Divider()
                docComments
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { composer }
        .background(Amb.background)
        .fixtureLabel()
        .navigationTitle("Document")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(snapshot.value.draft == nil ? "Edit" : "Continue") { editing = true }
                    .disabled(!snapshot.value.editable && snapshot.value.draft == nil)
                    .accessibilityIdentifier("doc.edit")
            }
        }
        .fullScreenCover(isPresented: $editing) {
            if let doc = snapshot.value.doc { DocumentEditorView(doc: doc, workspace: workspace, store: store) }
        }
        .refreshable { model.openDoc(docId, in: workspace, force: true) }
        .task { start() }
        .onAppear { model.openDoc(docId, in: workspace); model.markViewed(.document, docId, in: workspace) }
    }

    private var docComments: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comments").font(.headline).foregroundStyle(Amb.itemHeading)
            ForEach(snapshot.value.comments) { c in
                CommentRow(comment: c, names: snapshot.value.names, me: model.identity.npub)
                    .contextMenu {
                        let resolved = c.status == "resolved"
                        Button(resolved ? "Reopen" : "Resolve") {
                            model.submit(WriteIntent(kind: .docCommentStatus, targetId: c.id,
                                                     payload: ["doc_id": docId, "status": resolved ? "open" : "resolved", "row_version": c.rowVersion]), in: workspace)
                        }
                    }
            }
            ForEach(snapshot.value.pendingComments) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.string("body") ?? "").foregroundStyle(Amb.mutedForeground)
                    WriteStatusLine(item: item, label: "Comment")
                }
            }
            if snapshot.value.comments.isEmpty && snapshot.value.pendingComments.isEmpty {
                Text("No comments yet.").font(.footnote).foregroundStyle(Amb.mutedForeground)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Comment on this document", text: $comment, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Amb.muted, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityIdentifier("doccomment.field")
            Button {
                let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                if model.submit(WriteIntent(kind: .docComment, targetId: docId, payload: ["body": text]), in: workspace) { comment = "" }
            } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send comment").accessibilityIdentifier("doccomment.send")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
    }

    private func start() {
        let w = workspace.id, id = docId, store = store, connection = model.connection?.id ?? ""
        snapshot.start(store: store, matches: { $0.workspaceId == w && [.docs, .docBodies, .docDrafts, .comments, .writes, .members, .channels].contains($0.table) }) {
            async let doc = store.reader.doc(workspaceId: w, id: id)
            async let cached = store.reader.docBody(workspaceId: w, docId: id)
            async let draft = store.reader.docDraft(key: DocDraft.key(connectionId: connection, workspaceId: w, docId: id))
            async let comments = store.reader.comments(workspaceId: w, parent: .doc, parentId: id)
            async let writes = store.reader.writes(connectionId: connection, workspaceId: w, targetId: id)
            async let names = directoryNames(store, w)
            async let choice = scopeChoice(store, w)
            var snapshot = DocumentSnapshot(doc: try await doc, draft: try await draft, comments: try await comments,
                                            pendingComments: try await writes.filter { $0.kind == .docComment },
                                            names: try await names, choice: try await choice)
            // Decoding and layout preparation happen here, off the main actor.
            if let body = try await cached {
                let decoded = DocumentBody(bytes: body.bytes, contentType: body.contentType)
                snapshot.hasBody = true
                snapshot.blocks = DocumentRender.blocks(decoded)
                snapshot.editable = decoded.isEditable
                if case .readOnly(let reason) = decoded.editing { snapshot.readOnlyReason = reason + " Open it on the web to edit." }
            }
            return snapshot
        }
    }
}

// MARK: Editor

/// Editor state on the main actor holds only the text being typed. Applying edits to the document JSON, encoding the
/// body and writing the durable draft happen in detached tasks, so typing never waits for them.
@MainActor
@Observable
final class DocEditorModel {
    enum Mode: Equatable { case blocks, markdown, unavailable(String) }

    private(set) var mode: Mode = .unavailable("Loading…")
    private(set) var blocks: [EditableBlock] = []
    var texts: [String: String] = [:] { didSet { scheduleDraft() } }
    var markdown = "" { didSet { if markdown != oldValue { scheduleDraft() } } }
    var title = "" { didSet { if title != oldValue { scheduleDraft() } } }
    private(set) var status: String?
    private(set) var statusTone: Notice.Tone = .info
    private(set) var saving = false
    private(set) var leaseState = "Checking the edit lease…"
    private(set) var dirty = false

    @ObservationIgnored let doc: DocRecord
    @ObservationIgnored let workspace: WorkspaceRecord
    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let connection: ConnectionRecord
    @ObservationIgnored private var body: DocumentBody?
    @ObservationIgnored private var state: JSONValue?
    @ObservationIgnored private var base: (rowVersion: Int, sha: String, object: String)?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var renew: Task<Void, Never>?
    @ObservationIgnored private var loading = true

    init(doc: DocRecord, workspace: WorkspaceRecord, store: LocalStore, connection: ConnectionRecord) {
        self.doc = doc; self.workspace = workspace; self.store = store; self.connection = connection
    }

    var draftKey: String { DocDraft.key(connectionId: connection.id, workspaceId: workspace.id, docId: doc.id) }

    /// A saved draft wins over the cached body: unsaved work is never replaced by a newer download.
    func load() async {
        let store = store, w = workspace.id, d = doc.id, key = draftKey
        let draft = try? await store.reader.docDraft(key: key)
        let cached = try? await store.reader.docBody(workspaceId: w, docId: d)
        let source: (Data, String)? = draft.map { ($0.body, $0.contentType) } ?? cached.map { ($0.bytes, $0.contentType) }
        guard let source else { mode = .unavailable("This document's text is not on this iPhone yet. Go back, unlock and open it again."); return }
        let decoded = await Task.detached { DocumentBody(bytes: source.0, contentType: source.1) }.value
        body = decoded
        if let draft { base = (draft.baseRowVersion, draft.baseSha256, draft.baseStorageObjectId); dirty = true; status = draft.lastError }
        else if let cached { base = (cached.docRowVersion, cached.sha256, cached.storageObjectId) }
        title = draft?.title ?? doc.title
        switch decoded.editing {
        case .proseMirror:
            state = decoded.editorState
            blocks = state.map(DocumentEditor.blocks) ?? []
            texts = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.text) })
            mode = .blocks
        case .markdown, .markdownModel:
            markdown = decoded.markdown
            mode = .markdown
        case .readOnly(let reason):
            mode = .unavailable(reason)
        }
        loading = false
    }

    // MARK: Lease

    func holdLease(saver: DocumentSaver?, unlocked: Bool) {
        guard let saver, unlocked else { leaseState = "Editing on this iPhone. Unlock to save."; return }
        let connection = connection, workspace = workspace, id = doc.id
        renew?.cancel()
        renew = Task { [weak self] in
            do {
                try await saver.acquire(connection, workspace, docId: id)
                self?.leaseState = "You are editing (lease held)."
            } catch {
                self?.leaseState = (error as? LocalizedError)?.errorDescription ?? "Could not take the edit lease; your edits stay on this iPhone."
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

    func releaseLease(saver: DocumentSaver?) {
        renew?.cancel()
        guard let saver else { return }
        let connection = connection, workspace = workspace, id = doc.id
        Task.detached { await saver.release(connection, workspace, docId: id) }
    }

    // MARK: Structure edits (flush typed text first so paths stay valid)

    func toggleTask(_ block: EditableBlock) { restructure { try DocumentEditor.toggleTask($0, containing: block.path) } }
    func insertAfter(_ block: EditableBlock) { restructure { try DocumentEditor.insertParagraph($0, after: block.path) } }
    func remove(_ block: EditableBlock) { restructure { try DocumentEditor.removeBlock($0, path: block.path) } }
    func appendParagraph() { restructure { DocumentEditor.appendParagraph($0) } }

    private func restructure(_ edit: @escaping @Sendable (JSONValue) throws -> JSONValue) {
        guard var next = state else { return }
        do {
            next = try applyTexts(next)
            next = try edit(next)
        } catch { status = error.localizedDescription; statusTone = .warning; return }
        state = next
        blocks = DocumentEditor.blocks(next)
        texts = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.text) })
        dirty = true
    }

    private func applyTexts(_ start: JSONValue) throws -> JSONValue {
        var current = start
        for block in blocks {
            if let text = texts[block.id], text != block.text { current = try DocumentEditor.setText(current, path: block.path, text: text) }
        }
        return current
    }

    // MARK: Draft persistence

    private func scheduleDraft() {
        guard !loading else { return }
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
        let blocks = blocks, texts = texts, markdown = markdown, mode = mode, current = state, title = title
        let identity = (connection.id, workspace.id, doc.id)
        let encoded: (Data, String)? = await Task.detached {
            do {
                if mode == .markdown { let r = try body.encoded(markdown: markdown); return (r.bytes, r.contentType) }
                guard var next = current else { return nil }
                for block in blocks { if let text = texts[block.id], text != block.text { next = try DocumentEditor.setText(next, path: block.path, text: text) } }
                let r = try body.encoded(editorState: next)
                return (r.bytes, r.contentType)
            } catch { return nil }
        }.value
        guard let encoded else { status = "This edit could not be encoded without loss, so it was not saved."; statusTone = .error; return nil }
        let draft = DocDraft(connectionId: identity.0, workspaceId: identity.1, docId: identity.2, title: title.isEmpty ? doc.title : title,
                             body: encoded.0, contentType: encoded.1, baseRowVersion: base.rowVersion, baseSha256: base.sha,
                             baseStorageObjectId: base.object, state: draftState)
        try? await store.writer.saveDocDraft(draft)
        return draft
    }

    func save(saver: DocumentSaver?) async -> Bool {
        guard let saver else { return false }
        debounce?.cancel()
        saving = true
        defer { saving = false }
        guard let draft = await persistDraft(state: .editing) else {
            if !dirty { status = "No changes to save."; statusTone = .info }
            return !dirty
        }
        let result = await saver.save(draft, connection: connection, workspace: workspace)
        switch result {
        case .saved(_, let body):
            dirty = false
            base = (body.docRowVersion, body.sha256, body.storageObjectId)
            status = "Saved."; statusTone = .success
            return true
        case .recovery(_, let message), .leaseHeld(let message), .notSaved(let message):
            status = message; statusTone = .warning
            return false
        }
    }

    /// Drops the local draft (the user chose the latest version over their unsaved edit).
    func discardDraft() async {
        debounce?.cancel()
        try? await store.writer.deleteDocDraft(key: draftKey, workspaceId: workspace.id)
        dirty = false
    }

    var draftText: String {
        if mode == .markdown { return markdown }
        return blocks.map { texts[$0.id] ?? $0.text }.joined(separator: "\n\n")
    }
}

struct DocumentEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let doc: DocRecord
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var editor: DocEditorModel?
    @State private var confirmDiscard = false
    @FocusState private var focused: String?

    var body: some View {
        NavigationStack {
            Group {
                if let editor { content(editor) } else { ProgressView() }
            }
            .background(Amb.background)
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { Task { _ = await editor?.persistDraft(state: .editing); dismiss() } }.accessibilityIdentifier("editor.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await editor?.save(saver: model.saver) == true { dismiss() } } }
                        .disabled(editor?.saving ?? true || !model.isUnlocked)
                        .accessibilityIdentifier("editor.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
            .confirmationDialog("Discard your unsaved edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard edits", role: .destructive) { Task { await editor?.discardDraft(); dismiss() } }
            }
        }
        .task {
            guard editor == nil, let connection = model.connection else { return }
            let created = DocEditorModel(doc: doc, workspace: workspace, store: store, connection: connection)
            editor = created
            await created.load()
            created.holdLease(saver: model.saver, unlocked: model.isUnlocked)
        }
        .onDisappear { editor?.releaseLease(saver: model.saver) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { _ = await editor?.persistDraft(state: .editing) } } }
    }

    @ViewBuilder private func content(_ editor: DocEditorModel) -> some View {
        @Bindable var editor = editor
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: $editor.title, axis: .vertical).font(Amb.editorial).accessibilityIdentifier("editor.title")
                Text(editor.leaseState).font(.caption).foregroundStyle(Amb.mutedForeground).accessibilityIdentifier("editor.lease")
                if let status = editor.status {
                    Notice(tone: editor.statusTone, text: status).accessibilityIdentifier("editor.status")
                    if editor.statusTone == .warning {
                        HStack(spacing: 16) {
                            Button("Copy my text") { UIPasteboard.general.string = editor.draftText }
                            Button("Discard my edits", role: .destructive) { confirmDiscard = true }.accessibilityIdentifier("editor.discard")
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }
                switch editor.mode {
                case .blocks:
                    ForEach(editor.blocks) { block in blockEditor(block, editor: editor) }
                    Button { editor.appendParagraph() } label: { Label("Add paragraph", systemImage: "plus") }
                        .font(.footnote.weight(.semibold)).padding(.top, 4).accessibilityIdentifier("editor.addParagraph")
                case .markdown:
                    Text("Markdown").font(.caption.weight(.semibold)).foregroundStyle(Amb.mutedForeground)
                    TextEditor(text: $editor.markdown).font(.body.monospaced()).frame(minHeight: 320)
                        .scrollContentBackground(.hidden).padding(8).background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                        .focused($focused, equals: "markdown").accessibilityIdentifier("editor.markdown")
                case .unavailable(let reason):
                    Notice(tone: .info, text: reason)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private func blockEditor(_ block: EditableBlock, editor: DocEditorModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let checked = block.taskChecked {
                Button { editor.toggleTask(block) } label: { Image(systemName: checked ? "checkmark.square.fill" : "square") }
                    .buttonStyle(.borderless).accessibilityLabel(checked ? "Completed item" : "Open item")
            } else if block.container == "listItem" {
                Text("•").foregroundStyle(Amb.mutedForeground)
            } else if block.container == "blockquote" {
                Rectangle().fill(Amb.border).frame(width: 3, height: 18)
            }
            TextField(placeholder(block), text: Binding(get: { editor.texts[block.id] ?? block.text }, set: { editor.texts[block.id] = $0 }), axis: .vertical)
                .font(font(block))
                .focused($focused, equals: block.id)
                .accessibilityIdentifier("editor.block")
            if block.rich {
                Image(systemName: "textformat").font(.caption2).foregroundStyle(Amb.mutedForeground)
                    .accessibilityLabel("Formatting in this block is kept")
            }
        }
        .padding(.vertical, 4).padding(.leading, block.container == "tableCell" ? 12 : 0)
        .contextMenu {
            Button { editor.insertAfter(block) } label: { Label("Insert paragraph below", systemImage: "text.insert") }
            Button(role: .destructive) { editor.remove(block) } label: { Label("Delete block", systemImage: "trash") }
        }
    }

    private func placeholder(_ block: EditableBlock) -> String {
        switch block.type {
        case "heading": "Heading"
        case "codeBlock": "Code"
        default: "Text"
        }
    }

    private func font(_ block: EditableBlock) -> Font {
        switch block.type {
        case "heading": (block.level ?? 1) <= 1 ? .title2.weight(.bold) : .title3.weight(.semibold)
        case "codeBlock": Amb.code
        default: .body
        }
    }
}
