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
    /// The shared sidebar context (scope, channel or Home); the list reads and new records are written inside it.
    private var context: WorkContext { model.context }
    private var scopeId: String? { model.context.scopeId }
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
                    Text(item.string("title") ?? "Document").font(.amb(.subheadline).weight(.semibold))
                    WriteStatusLine(item: item, label: "New document")
                }
            }
            ForEach(visible) { doc in
                WorkRecordLink(route: WorkRoute.doc(workspaceId: workspace.id, docId: doc.id)) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").foregroundStyle(Amb.primary)
                            Text(doc.title).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(2)
                        }
                        HStack(spacing: 6) {
                            if let channel = snapshot.value.choice.channelName(doc.channelId) { Text("#\(channel)") }
                            Text(ChatTime.label(doc.updatedAt))
                            if snapshot.value.drafts.contains(doc.id) { Label("Unsaved edits", systemImage: "pencil.circle").foregroundStyle(Amb.warning) }
                        }
                        .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                    }
                }
                .accessibilityIdentifier("doc.\(doc.title)")
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
        .searchable(text: $filter, placement: .drawer, prompt: "Filter documents")
        .overlay {
            if snapshot.loaded && snapshot.value.docs.isEmpty && snapshot.value.creating.isEmpty {
                EmptyNote(title: "No documents", systemImage: "doc.text", detail: model.isUnlocked ? "Documents in this scope appear here." : "Unlock to load documents.")
            }
        }
        .navigationTitle("Docs")
        .safeAreaInset(edge: .top, spacing: 0) {
            ListHeaderBar {
                Spacer()
                Button { creating = true } label: { Image(systemName: "plus.circle.fill").font(.amb(.title2)) }
                    .accessibilityLabel("New document").accessibilityIdentifier("docs.new")
            }
        }
        .sheet(isPresented: $creating) { DocumentCreateSheet(workspace: workspace, choice: snapshot.value.choice, context: context) }
        .refreshable { model.openDocs(workspace, scopeId: scopeId, force: true) }
        .task(id: model.context) { start(); model.openDocs(workspace, scopeId: scopeId) }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { model.openDocs(workspace, scopeId: scopeId) } }
    }

    private func start() {
        let w = workspace.id, context = context, store = store, connection = model.connection?.id ?? ""
        snapshot.start(store: store, matches: { $0.workspaceId == w && [.docs, .docDrafts, .writes, .channels, .scopes].contains($0.table) }) {
            async let docs = store.reader.docs(workspaceId: w, context: context)
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
    let context: WorkContext
    @State private var title = ""
    @State private var text = ""
    @State private var channelId: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title).accessibilityIdentifier("newdoc.title")
                Picker("Channel", selection: $channelId) {
                    ForEach(choice.channels(in: context)) { Text("#\($0.name)").tag(Optional($0.id)) }
                }
                Section("Text") { ContentTextEntry(text: $text, placeholder: "Document text", workspace: workspace, field: "newdoc", multilineEditor: true).frame(minHeight: 160).accessibilityIdentifier("newdoc.text") }
                if let error { Text(error).foregroundStyle(Amb.destructive) }
            }
            .navigationTitle("New document")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || channelId == nil)
                        .accessibilityIdentifier("newdoc.create")
                }
            }
            .onAppear { channelId = channelId ?? context.channelId ?? choice.channels(in: context).first?.id }
        }
    }

    /// The body is built in the web format and staged on the device; the write queue uploads it and creates the record.
    private func create() {
        guard let channelId, let staging = model.staging else { return }
        guard !UploadToken.contains(in: text) else { error = ComposerUploadError.unresolved.localizedDescription; return }
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
    var spans: [DocumentTextSpan] = []
    var hasBody = false
    var editable = false
    var readOnlyReason: String?
    var draft: DocDraft?
    var comments: [CommentRecord] = []
    var pendingComments: [WriteItem] = []
    var people = PeopleDirectory()
    var names: [String: String] = [:]
    var choice = ScopeChoice()
    /// Current titles of every page saved here (id → title): wiki links show these, and the editor page is given them.
    var titles: [String: String] = [:]
}

/// A document opens in the user’s preferred mode, with comments in a sheet on iPhone/iPad
/// and beside the page on Mac. Unset preferences open in View.
struct DocumentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let docId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var snapshot = LiveQuery<DocumentSnapshot>(initial: DocumentSnapshot())
    @State private var wiki: WikiLinkController
    @State private var editor: DocEditorModel?
    @State private var showingComments = false
    @State private var commentsExpanded = true
    @State private var automaticEditing = true
    @State private var openingEditor: Task<Void, Never>?
    @State private var openingGeneration = UUID()
    @State private var comment = ""
    @State private var anchor: DocumentAnchor?
    @State private var replyTo: CommentRecord?
    @State private var revealed: DocumentAnchor?
    @State private var revealRevision = 0

    init(docId: String, workspace: WorkspaceRecord, store: LocalStore) {
        self.docId = docId; self.workspace = workspace; self.store = store
        _wiki = State(initialValue: WikiLinkController(workspace: workspace, sourceDocId: docId, store: store))
    }

    private var canEdit: Bool { model.isUnlocked && snapshot.value.doc?.archived == false && (snapshot.value.editable || snapshot.value.draft != nil) }

    var body: some View {
        #if os(iOS)
        // Observe the captured anchor before presenting the sheet; its first content must use this selection.
        let commentComposer = composer
        #endif
        readerLayout
        .fixtureLabel()
        .navigationTitle("Document")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                HStack(spacing: 10) {
                    Menu {
                        Button("Move…") { Task { await wiki.refresh(); wiki.sheet = .move } }
                            .disabled(snapshot.value.doc == nil || !model.isUnlocked)
                            .accessibilityIdentifier("doc.move")
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Document actions").accessibilityIdentifier("doc.actions")
                    if editor == nil {
                        Button(snapshot.value.draft == nil ? "Edit" : "Continue editing") { beginEditing() }
                            .disabled(!canEdit)
                            .accessibilityIdentifier("doc.edit")
                    }
                }
            }
        }
        .environment(\.openWiki, OpenWikiAction { [wiki] target in wiki.activate(target) })
        .wikiSheets(wiki, workspace: workspace)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
                if let banner = wiki.banner {
                    HStack(alignment: .top) {
                        Notice(tone: wiki.bannerIsProblem ? .warning : .info, text: banner).accessibilityIdentifier("wiki.banner")
                        Button { wiki.banner = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss")
                    }
                }
                WikiPendingView(wiki: wiki)
            }
            .padding(.horizontal, 12).padding(.top, 6)
        }
        .onChange(of: snapshot.value.titles) { _, titles in wiki.titles = titles }
        #if os(iOS)
        .sheet(isPresented: $showingComments) {
            NavigationStack {
                ScrollView { docComments.padding() }
                    .safeAreaInset(edge: .bottom) { commentComposer }
                    .navigationTitle("Comments")
                    .inlineTitle()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingComments = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        #endif
        .refreshable { model.openDoc(docId, in: workspace, force: true) }
        .task { wiki.attach(model); start() }
        .onAppear {
            model.openDoc(docId, in: workspace); model.markViewed(.document, docId, in: workspace)
            // Back from a linked page: the editor opens again on the draft that was kept when this screen was left.
            wiki.isVisible = true
            Task { await wiki.refresh() }
            openFormattedPage()
        }
        .onChange(of: snapshot.value.doc?.id) { _, _ in takeEditRequest(); openFormattedPage() }
        .onChange(of: snapshot.value.hasBody) { _, _ in openFormattedPage() }
        .onChange(of: snapshot.value.editable) { _, _ in openFormattedPage() }
        .onChange(of: snapshot.value.doc?.rowVersion) { _, _ in Task { await editor?.reconcileRemote() } }
        .onChange(of: model.isUnlocked) { _, unlocked in if unlocked { openFormattedPage(); Task { await editor?.reconcileRemote() } } }
        .onChange(of: model.docEditRequest) { _, _ in takeEditRequest() }
        .onDisappear {
            // Leaving for a linked page keeps the text as a draft; coming back opens the editor on that draft.
            wiki.isVisible = false
            openingGeneration = UUID()
            openingEditor?.cancel(); openingEditor = nil
            if let leaving = editor {
                editor = nil; wiki.editor = nil
                Task { await leaving.flush(); leaving.close() }
            }
        }
        .onChange(of: scenePhase) { _, phase in editor?.setActive(phase == .active) }
    }

    private func openFormattedPage() {
        takeEditRequest()
        if automaticEditing && model.documentOpeningMode == .edit && canEdit { beginEditing() }
    }

    /// A canvas document's Edit opens this screen with Edit already on.
    private func takeEditRequest() {
        guard model.docEditRequest == docId, snapshot.value.doc != nil, canEdit else { return }
        model.docEditRequest = nil
        if canEdit && editor == nil { beginEditing() }
    }

    private func beginEditing() {
        guard canEdit, editor == nil, openingEditor == nil, let doc = snapshot.value.doc, let connection = model.connection else { return }
        let created = DocEditorModel(doc: doc, workspace: workspace, store: store, connection: connection, app: model)
        created.wiki = wiki
        let generation = UUID()
        openingGeneration = generation
        openingEditor = Task {
            defer { if openingGeneration == generation { openingEditor = nil } }
            await created.load()
            // Resolve known permission denial before displaying an editable surface.
            // Transport failures still permit the existing durable offline draft flow.
            let allowed = await created.prepareOpening()
            guard !Task.isCancelled, openingGeneration == generation, allowed, model.isUnlocked else { created.close(); return }
            wiki.editor = created
            wiki.beforeLeaving = { [weak created] in await created?.checkpoint() ?? true }
            editor = created
            created.holdLease()
        }

    }

    @ViewBuilder private var readerLayout: some View {
        #if os(macOS)
        GeometryReader { geometry in
            let commentsWidth = min(340, max(250, geometry.size.width * 0.3))
            // A narrow page column (small window) gets smaller margins and a two-row edit bar.
            let compact = geometry.size.width - (commentsExpanded ? commentsWidth : 44) < 720
            HStack(alignment: .top, spacing: 0) {
                Group {
                    if let editor {
                        DocumentEditingPage(editor: editor, compact: compact, onFinish: { automaticEditing = false; self.editor = nil })
                    } else {
                        ScrollViewReader { scroll in
                            ScrollView { paper(compact: compact).padding(.horizontal, compact ? 14 : 28).padding(.vertical, 24).frame(maxWidth: .infinity) }
                                .onChange(of: revealRevision) { _, _ in
                                    if let value = revealed, let result = DocumentAnchors.resolve(value, in: snapshot.value.spans) {
                                        withAnimation { scroll.scrollTo(result.span.path.first ?? 0, anchor: .center) }
                                    }
                                }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Amb.paperSurround)
                // The surround is always light, so the page column (edit bar included) is drawn in light appearance.
                .environment(\.colorScheme, .light)
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        if commentsExpanded { Spacer() }
                        Button { commentsExpanded.toggle() } label: {
                            Image(systemName: commentsExpanded ? "sidebar.right" : "text.bubble")
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(commentsExpanded ? "Collapse comments panel" : "Expand comments panel")
                        .help(commentsExpanded ? "Collapse comments panel" : "Expand comments panel")
                        .accessibilityIdentifier("doc.commentsPanel.toggle")
                    }
                    if commentsExpanded {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if let editor {
                                    DocumentEditorStatus(editor: editor)
                                        .accessibilityElement(children: .contain)
                                        .accessibilityIdentifier("doc.statusPanel")
                                    Divider()
                                }
                                docComments
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                        Divider()
                        composer
                    } else if let editor {
                        Button { commentsExpanded = true } label: {
                            Image(systemName: editor.statusTone == .error || editor.statusTone == .warning ? "exclamationmark.circle.fill" : editor.saving ? "arrow.trianglehead.2.clockwise" : editor.dirty ? "circle.dotted" : "checkmark.circle")
                                .foregroundStyle(editor.statusTone == .error || editor.statusTone == .warning ? Color.orange : Amb.mutedForeground)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Document status: \(editor.status ?? editor.leaseState). \(editor.dirty ? "Changes pending sync." : "") Expand comments panel")
                        .help([editor.leaseState, editor.status, editor.dirty ? "Changes pending sync" : nil].compactMap { $0 }.joined(separator: " · "))
                        .accessibilityIdentifier("doc.statusPanel.expand")
                    }
                    if !commentsExpanded { Spacer(minLength: 0) }
                }
                .frame(width: commentsExpanded ? commentsWidth : 44)
                .background(Amb.card)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("doc.commentColumn")
            }
        }
        .background(Amb.background)
        .onChange(of: editor?.commentRequest) { _, selected in beginSelectionComment(selected) }
        #else
        VStack(spacing: 0) {
            if let editor {
                HStack {
                    DocumentCancelButton(editor: editor) { automaticEditing = false; self.editor = nil }
                    Spacer()
                    Button { showingComments = true } label: { Label("Comments", systemImage: "text.bubble") }
                        .accessibilityIdentifier("doc.comments")
                    Spacer()
                    Button("Save") { Task { _ = await editor.save() } }
                        .disabled(editor.saving || !model.isUnlocked || !editor.pageReady)
                        .accessibilityIdentifier("editor.save")
                }.padding(.horizontal, 12).padding(.vertical, 6)
                DocumentFormatBar(editor: editor, compact: true).padding(.horizontal, 12)
                DocumentEditSurface(editor: editor)
                    .modifier(DocumentPaper(fill: true, compact: true))
                    .padding(.horizontal, 10).padding(.bottom, 8)
            } else {
                ScrollView { paper(compact: true).padding(12).tabletReadingWidth() }
                Button("Comments") { showingComments = true }.padding(8).accessibilityIdentifier("doc.comments")
            }
        }
        .background(Amb.paperSurround)
        .environment(\.colorScheme, .light)
        .onChange(of: editor?.commentRequest) { _, selected in beginSelectionComment(selected) }
        #endif
    }

    private func beginSelectionComment(_ selected: DocumentAnchor?) {
        guard let selected, let editor, !editor.saving, model.isUnlocked else { return }
        editor.commentRequest = nil
        Task {
            if let saved = await editor.commentAnchor(selected) {
                commentsExpanded = true
                anchor = saved; replyTo = nil; revealed = saved
                #if os(iOS)
                showingComments = true
                #endif
            }
        }
    }

    private func paper(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let doc = snapshot.value.doc {
                Text(doc.title).font(Amb.editorial).foregroundStyle(Amb.paperInk).accessibilityIdentifier("doc.title")
                Text([snapshot.value.choice.scopeName(doc.scopeId), snapshot.value.choice.channelName(doc.channelId).map { "#\($0)" }, ChatTime.label(doc.updatedAt)]
                    .compactMap { $0 }.joined(separator: " · ")).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            }
            if let draft = snapshot.value.draft {
                Button { beginEditing() } label: {
                    Notice(tone: draft.state == .recovery || draft.state == .conflict ? .warning : .info,
                           text: draft.lastError ?? "You have unsaved edits on this \(Device.name). Continue editing to save or discard them.")
                }
                .buttonStyle(.plain).accessibilityIdentifier("doc.draftBanner")
            }
            if let reason = snapshot.value.readOnlyReason { Notice(tone: .info, text: reason) }
            if snapshot.value.hasBody {
                documentBlocks
                if snapshot.value.doc != nil {
                    WikiBacklinksView(docId: docId, workspace: workspace, store: store, context: wiki.context)
                        .padding(.top, 8)
                }
            } else if snapshot.loaded {
                SyncNote(text: model.syncError(forKey: WorkspaceSync.docKey(workspace.id, docId))
                         ?? (model.isUnlocked ? "Loading document…" : "This document is not saved on this \(Device.name) yet. Unlock to load it."))
            }
        }
        .modifier(DocumentPaper(compact: compact))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("doc.paper")
    }

    private var documentBlocks: some View {
        RichBlocksView(blocks: snapshot.value.blocks, style: .document, workspace: workspace)
            .accessibilityElement(children: .contain).accessibilityIdentifier("doc.body")
            #if os(macOS)
            .environment(\.documentSelection, DocumentSelectionContext(spans: snapshot.value.spans, version: snapshot.value.doc?.rowVersion, selected: revealed, begin: { selected in
                commentsExpanded = true
                anchor = selected; revealed = selected; revealRevision += 1; replyTo = nil
            }))
            #endif
    }

    private var docComments: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comments").font(.amb(.headline)).foregroundStyle(Amb.itemHeading)
            ForEach(snapshot.value.comments.filter { $0.parentCommentId == nil }) { c in
                VStack(alignment: .leading, spacing: 8) {
                    if let quote = c.anchorQuote, !quote.isEmpty {
                        Button {
                            if let found = c.documentAnchor {
                                revealed = found; revealRevision += 1
                                editor?.page?.reveal(found)
                                #if os(iOS)
                                showingComments = false
                                #endif
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("“\(quote)”").lineLimit(4)
                                if c.documentAnchor.flatMap({ DocumentAnchors.resolve($0, in: snapshot.value.spans) }) == nil {
                                    Text("Original selection unavailable").font(.amb(.caption))
                                } else { Label("Locate text", systemImage: "text.magnifyingglass").font(.amb(.caption)) }
                            }
                        }.buttonStyle(.plain).foregroundStyle(Amb.primary)
                    }
                CommentRow(comment: c, people: snapshot.value.people, workspace: workspace)
                    .contextMenu {
                        let resolved = c.status == "resolved"
                        Button(resolved ? "Reopen" : "Resolve") {
                            model.submit(WriteIntent(kind: .docCommentStatus, targetId: c.id,
                                                     payload: ["doc_id": docId, "status": resolved ? "open" : "resolved", "row_version": c.rowVersion]), in: workspace)
                        }
                    }
                    ForEach(snapshot.value.comments.filter { $0.parentCommentId == c.id }) { reply in
                        CommentRow(comment: reply, people: snapshot.value.people, workspace: workspace).padding(.leading, 14)
                    }
                    Button("Reply") { replyTo = c; anchor = c.documentAnchor }.font(.amb(.caption))
                        .accessibilityIdentifier("doccomment.reply.\(c.id)")
                }
                .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(snapshot.value.pendingComments) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.string("body") ?? "").foregroundStyle(Amb.mutedForeground)
                    WriteStatusLine(item: item, label: "Comment")
                }
            }
            if snapshot.value.comments.isEmpty && snapshot.value.pendingComments.isEmpty {
                Text("No comments yet.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if anchor != nil || replyTo != nil {
                HStack(alignment: .top) {
                    Text(replyTo.map { "Replying to \(displayName($0.senderNpub, snapshot.value.names, me: model.identity.npub))" } ?? "Selected text")
                    Spacer()
                    Button { anchor = nil; replyTo = nil; revealed = nil } label: { Image(systemName: "xmark.circle") }
                }.font(.amb(.caption))
                if let anchor { Text("“\(anchor.quote)”").font(.amb(.footnote)).lineLimit(4).foregroundStyle(Amb.primary) }
            }
            HStack(alignment: .bottom, spacing: 8) {
            ContentTextEntry(text: $comment, placeholder: replyTo == nil ? "Comment on this document" : "Reply", workspace: workspace, field: "doc-comment-\(docId)-\(replyTo?.id ?? "root")", actorMentions: true)
                .lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Amb.muted, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityIdentifier("doccomment.field")
            Button {
                let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                var payload: [String: any Sendable] = ["body": text, "mentions": CommentMentions.actors(in: text).map(\.requestObject)]
                if let anchor { payload["metadata"] = anchor.metadata }
                if let replyTo { payload["parent_comment_id"] = replyTo.id }
                if model.submit(WriteIntent(kind: .docComment, targetId: docId, payload: payload), in: workspace) { comment = ""; anchor = nil; replyTo = nil }
            } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                .disabled(!model.isUnlocked || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send comment").accessibilityIdentifier("doccomment.send")
        }
            }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Amb.card)
    }

    private func start() {
        let w = workspace.id, id = docId, store = store, connection = model.connection?.id ?? ""
        snapshot.start(store: store, matches: { ($0.workspaceId == w && [.docs, .docBodies, .docDrafts, .comments, .writes, .members, .agents, .channels, .scopes].contains($0.table)) || $0.table == .profiles }) {
            async let doc = store.reader.doc(workspaceId: w, id: id)
            async let cached = store.reader.docBody(workspaceId: w, docId: id)
            async let draft = store.reader.docDraft(key: DocDraft.key(connectionId: connection, workspaceId: w, docId: id))
            async let comments = store.reader.comments(workspaceId: w, parent: .doc, parentId: id)
            async let writes = store.reader.writes(connectionId: connection, workspaceId: w, targetId: id)
            async let people = store.reader.people(connectionId: connection, workspaceId: w)
            async let choice = scopeChoice(store, w)
            async let everyDoc = store.reader.docs(workspaceId: w, limit: 2000)
            let pages = try await everyDoc
            var snapshot = DocumentSnapshot(doc: try await doc, draft: try await draft, comments: try await comments,
                                            pendingComments: try await writes.filter { $0.kind == .docComment },
                                            people: try await people, names: try await people.names, choice: try await choice)
            snapshot.titles = Dictionary(pages.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            // Decoding and layout preparation happen here, off the main actor.
            if let body = try await cached {
                let decoded = DocumentBody(bytes: body.bytes, contentType: body.contentType)
                snapshot.hasBody = true
                snapshot.blocks = WikiLinks.retitled(DocumentRender.blocks(decoded), docs: pages)
                snapshot.spans = decoded.editorState.map(DocumentAnchors.spans) ?? DocumentAnchors.markdownSpans(decoded.markdown, blocks: snapshot.blocks)
                snapshot.editable = decoded.isEditable
                if case .readOnly(let reason) = decoded.editing { snapshot.readOnlyReason = reason + " Open it on the web to edit." }
            }
            return snapshot
        }
    }
}

/// The white page: generous margins, dark ink in both appearances, centred on the lavender surround.
struct DocumentPaper: ViewModifier {
    var fill = false
    var compact = false
    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .padding(.horizontal, compact ? 24 : 56).padding(.vertical, compact ? 24 : 44)
            #else
            .padding(.horizontal, compact ? 14 : 22).padding(.vertical, compact ? 12 : 24)
            #endif
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(PlatformColor(hex: 0xE4DFF0)), lineWidth: 1))
            .shadow(color: Color(PlatformColor(hex: 0x2B1B3C)).opacity(0.06), radius: 10, y: 2)
            .environment(\.colorScheme, .light)
            .frame(maxWidth: 860)
    }
}

// MARK: Editor

/// Mac: the document page turned into the editor, in place (formatting bar above the page, Save and Cancel beside it).
struct DocumentEditingPage: View {
    let editor: DocEditorModel
    var compact = false
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DocumentEditBar(editor: editor, compact: compact, onFinish: onFinish)
                .padding(.horizontal, compact ? 12 : 20).padding(.vertical, 8)
            DocumentEditSurface(editor: editor)
                .modifier(DocumentPaper(fill: true, compact: compact))
                .padding(.horizontal, compact ? 14 : 28).padding(.bottom, compact ? 12 : 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// iPhone and iPad: the same editor full screen, on the same page and surround.
struct DocumentEditorScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let editor: DocEditorModel
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DocumentFormatBar(editor: editor, compact: isCompact)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                DocumentEditSurface(editor: editor)
                    .modifier(DocumentPaper(fill: true))
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .tabletReadingWidth()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Amb.paperSurround)
            .environment(\.colorScheme, .light)
            .navigationTitle("Edit")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { DocumentCancelButton(editor: editor, onFinish: onFinish) }
                ToolbarItem(placement: .confirmationAction) { DocumentSaveButton(editor: editor, onFinish: onFinish) }
            }
        }
        .onChange(of: scenePhase) { _, phase in editor.setActive(phase == .active) }
    }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
}

/// Formatting on the left; save status, Cancel and Save on the right.
struct DocumentEditBar: View {
    let editor: DocEditorModel
    var compact = false
    let onFinish: () -> Void

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) { Spacer(); actions }
                DocumentFormatBar(editor: editor, compact: true)
            }
            .controlSize(.regular)
        } else {
            HStack(spacing: 12) {
                DocumentFormatBar(editor: editor)
                Spacer(minLength: 8)
                actions
            }
            .controlSize(.regular)
        }
    }

    @ViewBuilder private var actions: some View {
        DocumentCancelButton(editor: editor, onFinish: onFinish).buttonStyle(.bordered)
        DocumentSaveButton(editor: editor, onFinish: onFinish).buttonStyle(.borderedProminent)
    }
}

struct DocumentSaveButton: View {
    @Environment(AppModel.self) private var model
    let editor: DocEditorModel
    let onFinish: () -> Void

    var body: some View {
        Button("Save") {
            Task { if await editor.save() { editor.close(); onFinish() } }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(editor.saving || !model.isUnlocked || !editor.pageReady)
        .font(.amb(.body).weight(.semibold))
        .accessibilityIdentifier("editor.save")
    }
}

/// Cancel: without changes it just closes; with changes it asks whether to keep the draft on this device or discard it.
struct DocumentCancelButton: View {
    let editor: DocEditorModel
    let onFinish: () -> Void
    @State private var asking = false

    var body: some View {
        Button("Cancel") {
            if editor.dirty { asking = true } else { editor.close(); onFinish() }
        }
        .keyboardShortcut(.cancelAction)
        .font(.amb(.body))
        .accessibilityIdentifier("editor.close")
        .confirmationDialog("You have unsaved edits", isPresented: $asking, titleVisibility: .visible) {
            Button("Keep draft on this \(Device.name)") {
                Task { _ = await editor.persistDraft(state: .editing); editor.close(); onFinish() }
            }
            .accessibilityIdentifier("editor.keepDraft")
            Button("Discard edits", role: .destructive) {
                Task { await editor.discardDraft(); editor.close(); onFinish() }
            }
            .accessibilityIdentifier("editor.discard")
        } message: {
            Text("A kept draft stays on this \(Device.name) and is not sent until you save it.")
        }
    }
}

/// The formatting toolbar: block style, inline marks, link, lists, quote, code, rule, undo and redo. It acts on the
/// page's selection and shows what is active there.
struct DocumentFormatBar: View {
    let editor: DocEditorModel
    /// Narrow: the less used tools move into a More menu.
    var compact = false
    @State private var linking = false
    @State private var href = ""

    var body: some View {
        let f = editor.formatting
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Menu {
                    Button("Text") { editor.command("paragraph") }
                    Button("Heading 1") { editor.command("heading", ["level": "1"]) }
                    Button("Heading 2") { editor.command("heading", ["level": "2"]) }
                    Button("Heading 3") { editor.command("heading", ["level": "3"]) }
                } label: {
                    // A fixed width, so the tools after it never move under the pointer when the style changes.
                    Text(f.heading > 0 ? "Heading \(f.heading)" : "Text").font(.amb(.callout).weight(.medium)).lineLimit(1)
                        .frame(width: 84 * TextScaleFactor.current, alignment: .leading)
                }
                .menuStyle(.button).fixedSize()
                .accessibilityLabel("Text style").accessibilityIdentifier("editor.format.style")
                divider
                tool("bold", "Bold", f.bold, "bold")
                tool("italic", "Italic", f.italic, "italic")
                if !compact {
                    tool("strikethrough", "Strikethrough", f.strike, "strike")
                    tool("chevron.left.forwardslash.chevron.right", "Inline code", f.code, "code")
                }
                Button { href = f.link ?? ""; linking = true } label: { icon("link", active: f.link != nil) }
                    .help("Link").accessibilityLabel("Link").accessibilityIdentifier("editor.format.link")
                Button { editor.wiki?.openToolbarPicker() } label: { icon("link.badge.plus", active: false) }
                    .help("Link to doc or note").accessibilityLabel("Link to doc or note").accessibilityIdentifier("editor.format.wikilink")
                divider
                tool("list.bullet", "Bulleted list", f.bulletList, "bulletList")
                tool("list.number", "Numbered list", f.orderedList, "orderedList")
                tool("checklist", "Task list", f.taskList, "taskList")
                if compact {
                    Menu {
                        Button("Strikethrough") { editor.command("strike") }
                        Button("Inline code") { editor.command("code") }
                        Button("Quote") { editor.command("blockquote") }
                        Button("Code block") { editor.command("codeBlock") }
                        Button("Divider") { editor.command("horizontalRule") }
                        Divider()
                        Button("Undo") { editor.command("undo") }.disabled(!f.canUndo)
                        Button("Redo") { editor.command("redo") }.disabled(!f.canRedo)
                    } label: { icon("ellipsis", active: f.strike || f.code || f.blockquote || f.codeBlock) }
                        .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("More formatting").accessibilityIdentifier("editor.format.more")
                } else {
                    tool("text.quote", "Quote", f.blockquote, "blockquote")
                    tool("curlybraces", "Code block", f.codeBlock, "codeBlock")
                    tool("minus", "Divider", false, "horizontalRule")
                    divider
                    tool("arrow.uturn.backward", "Undo", false, "undo").disabled(!f.canUndo)
                    tool("arrow.uturn.forward", "Redo", false, "redo").disabled(!f.canRedo)
                }
            }
            .buttonStyle(.borderless)
            .disabled(!editor.pageReady)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.toolbar")
        .alert("Link", isPresented: $linking) {
            TextField("https://", text: $href).accessibilityIdentifier("editor.link.field")
            Button("Apply") { applyLink() }
            if editor.formatting.link != nil { Button("Remove link", role: .destructive) { editor.command("link", ["href": ""]) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Links open outside the editor.")
        }
    }

    private var divider: some View { Divider().frame(height: 18).padding(.horizontal, 4) }

    private func icon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.amb(.body).weight(active ? .bold : .regular))
            .frame(width: 30, height: 28)
            .foregroundStyle(active ? Amb.primaryForeground : Amb.foreground)
            .background(active ? Amb.primary : Color.clear, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            .contentShape(Rectangle())
    }

    private func tool(_ symbol: String, _ label: String, _ active: Bool, _ command: String) -> some View {
        Button { editor.command(command) } label: { icon(symbol, active: active) }
            .help(label)
            .accessibilityLabel(label)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityIdentifier("editor.format.\(command)")
    }

    /// Only web and mail links (the web Link extension's own rule); anything else is not applied.
    private func applyLink() {
        var value = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { editor.command("link", ["href": ""]); return }
        if !value.contains(":") { value = "https://" + value }
        guard let url = URL(string: value), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        editor.command("link", ["href": value])
    }
}

/// Same status and recovery controls, placed in the Mac comments panel or compact iOS page.
struct DocumentEditorStatus: View {
    @Bindable var editor: DocEditorModel
    @State private var confirmDiscard = false
    @State private var confirmTakeover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(editor.leaseState.contains("lease held") ? Color.green : Amb.mutedForeground).frame(width: 7, height: 7)
                Text(editor.leaseState).accessibilityIdentifier("editor.lease")
                #if os(iOS)
                if editor.dirty { Text("· Changes pending sync").accessibilityIdentifier("editor.dirty") }
                #endif
                if !editor.recoveries.isEmpty {
                    Button { Task { await editor.openVersions() } } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Saved versions — previous edits available").help("Saved versions")
                        .accessibilityIdentifier("editor.versions")
                }
            }
            .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            #if os(macOS)
            if editor.dirty { Text("Changes pending sync").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).accessibilityIdentifier("editor.dirty") }
            #endif
            if let synced = editor.lastSyncedAt { Text("Last synced \(synced.formatted(date: .omitted, time: .shortened))").font(.amb(.caption)) }
            if editor.canTakeover {
                Button("Take over editing…") { confirmTakeover = true }
                    .disabled(editor.saving || editor.takingOver).accessibilityIdentifier("editor.takeover")
                    .confirmationDialog("Take over from the current editor?", isPresented: $confirmTakeover, titleVisibility: .visible) {
                        Button("Preserve my draft and load latest cloud version") { Task { await editor.takeover() } }
                    } message: { Text("This device will load the latest cloud version and stop the previous editor from saving over it. Any divergent local edits are kept as recovery history.") }
            }
            if let status = editor.status {
                Notice(tone: editor.statusTone, text: status).accessibilityIdentifier("editor.status")
                if editor.dirty, editor.statusTone == .warning || editor.statusTone == .error {
                    HStack(spacing: 16) {
                        Button("Copy my text") { Pasteboard.copy(editor.draftText) }
                        Button("Discard my edits", role: .destructive) { confirmDiscard = true }.accessibilityIdentifier("editor.discardEdits")
                    }
                    .font(.amb(.footnote).weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
        }
        .confirmationDialog("Discard your unsaved edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard edits", role: .destructive) { Task { await editor.discardDraft() } }
        }
    }
}

/// Title, lease and save status, pasted uploads, and the editor page, on the white page.
struct DocumentEditSurface: View {
    @Environment(AppModel.self) private var model
    @Bindable var editor: DocEditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $editor.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Amb.editorial)
                .foregroundStyle(Amb.paperInk)
                .accessibilityIdentifier("editor.title").disabled(editor.takingOver || editor.followingRemote || editor.permissionDenied || !model.isUnlocked)
            #if os(iOS)
            DocumentEditorStatus(editor: editor)
            #endif
            if let uploads = model.uploads {
                ComposerPastedUploads(uploads: uploads, target: editor.uploadTarget, text: editor.uploadText)
            }
            switch editor.mode {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .rich, .markdown:
                if BoardEditorBundle.available {
                    DocumentEditorWebView(editor: editor)
                        .allowsHitTesting(!editor.takingOver)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Document text")
                } else {
                    Notice(tone: .error, text: "The document editor is missing from this build.")
                }
            case .unavailable(let reason):
                Notice(tone: .info, text: reason)
            }
        }
        .overlay(alignment: .top) {
            if let query = editor.wikiQuery, let wiki = editor.wiki {
                WikiQueryPanel(wiki: wiki, query: query).padding(.top, 96)
            }
        }
        .sheet(isPresented: $editor.showingVersions) { DocumentVersionChoice(editor: editor) }
        .onChange(of: model.syncStatus) { _, _ in editor.deliverImages() }
        .onChange(of: TextScale.shared.factor, initial: true) { _, _ in editor.page?.setStyle(DocumentEditorStyle.sizes()) }
        .onChange(of: model.isUnlocked) { _, unlocked in editor.page?.setEditable(unlocked && !editor.followingRemote && !editor.permissionDenied) }
        .onChange(of: editor.followingRemote) { _, following in editor.page?.setEditable(model.isUnlocked && !following && !editor.permissionDenied) }
        .onChange(of: editor.pageReady) { _, _ in editor.page?.setStyle(DocumentEditorStyle.sizes()) }

    }
}

enum TextScaleFactor {
    @MainActor static var current: CGFloat {
        #if os(macOS)
        TextScale.shared.factor
        #else
        1
        #endif
    }
}

/// Text sizes for the editor page, the same as the reader's at the app's text size.
enum DocumentEditorStyle {
    @MainActor static func sizes() -> [String: CGFloat] {
        #if os(macOS)
        // The Mac reader's selectable text (DocumentSelection): 15 pt text, 25 pt and 20 pt headings, at the app's scale.
        let f = TextScale.shared.factor
        return ["body": 15 * f, "h1": 25 * f, "h2": 20 * f, "h3": 17 * f, "code": 13 * f]
        #else
        func size(_ style: UIFont.TextStyle) -> CGFloat { UIFont.preferredFont(forTextStyle: style).pointSize }
        return ["body": size(.body), "h1": size(.title2), "h2": size(.title3), "h3": size(.headline), "code": size(.footnote)]
        #endif
    }
}

/// Simple saved snapshots, without a diff engine. Selection never changes bytes until explicitly confirmed.
struct DocumentVersionChoice: View {
    @Bindable var editor: DocEditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved versions").font(.headline)
            Picker("Version", selection: Binding(get: { editor.selectedRecovery?.id ?? "latest" }, set: { id in
                Task { await editor.previewVersion(editor.recoveries.first { $0.id == id }) }
            })) {
                Text("Latest saved version").tag("latest")
                ForEach(editor.recoveries) { version in Text("Previous saved: " + (version.title ?? version.createdAt)).tag(version.id) }
            }
            ScrollView { Text(editor.versionPreview ?? "Loading…").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minHeight: 200)
            if let status = editor.status { Text(status).font(.caption) }
            HStack {
                Button("Close") { editor.showingVersions = false }
                Spacer()
                if editor.selectedRecovery != nil {
                    Button("Dismiss previous version") { Task { await editor.resolveVersion(promote: false) } }
                    Button("Keep selected version") { Task { await editor.resolveVersion(promote: true) } }
                } else {
                    Button("Keep latest") { editor.showingVersions = false }
                }
            }.disabled(editor.saving || editor.versionPreview == nil)
        }.padding(24)
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 640, minHeight: 400)
        #else
        .frame(maxWidth: .infinity, minHeight: 300)
        #endif
    }
}
