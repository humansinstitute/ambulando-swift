import AmbulandoCore
import SwiftUI

// Wiki links in documents: opening a page, creating a missing one, choosing between same-titled pages, the link picker
// (typing `[[` and the toolbar's "Link to doc or note") and Move. Links are the stable `[Title](wiki:<document-id>)` /
// `fdWikiLink` form; where a page lives (scope, channel) is only a label, and a link never grants access to its page.

// MARK: Environment

/// Opens a wiki reference from rendered document text. Screens that can route set it; the default does nothing.
struct OpenWikiAction: Sendable {
    let handler: @MainActor @Sendable (_ target: WikiTarget) -> Void
    @MainActor func callAsFunction(_ target: WikiTarget) { handler(target) }
}

extension EnvironmentValues {
    @Entry var openWiki = OpenWikiAction { _ in }
}

extension RichLinks {
    static let wikiScheme = "ambulando-wiki"

    static func wikiURL(_ target: WikiTarget) -> URL? {
        var components = URLComponents()
        components.scheme = wikiScheme
        components.host = "open"
        var items = [URLQueryItem(name: "title", value: target.title), URLQueryItem(name: "n", value: String(target.occurrence))]
        if let id = target.documentId { items.append(URLQueryItem(name: "id", value: id)) }
        components.queryItems = items
        return components.url
    }

    static func wikiTarget(_ url: URL) -> WikiTarget? {
        guard url.scheme == wikiScheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let title = items.first { $0.name == "title" }?.value ?? ""
        let id = items.first { $0.name == "id" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        guard id != nil || !title.isEmpty else { return nil }
        return WikiTarget(documentId: id, title: title, occurrence: Int(items.first { $0.name == "n" }?.value ?? "") ?? 0)
    }
}

// MARK: Editor registry

struct WikiEditorRange: Equatable, Sendable { var from: Int; var to: Int }

/// What is typed after `[[` in the editor page, and the span it will replace.
struct WikiQuery: Equatable, Sendable {
    var text: String
    var range: WikiEditorRange
}

/// The open editors, so a page created in the background can put its link into an editor that is showing the source
/// (the source must never be rewritten behind an open editor's back).
@MainActor
enum WikiEditors {
    private final class Box { weak var editor: DocEditorModel?; init(_ editor: DocEditorModel) { self.editor = editor } }
    private static var open: [String: Box] = [:]
    private static func key(_ workspaceId: String, _ docId: String) -> String { "\(workspaceId):\(docId)" }
    static func register(_ editor: DocEditorModel) { open[key(editor.workspace.id, editor.doc.id)] = Box(editor) }
    static func unregister(_ editor: DocEditorModel) {
        if open[key(editor.workspace.id, editor.doc.id)]?.editor === editor { open[key(editor.workspace.id, editor.doc.id)] = nil }
    }
    static func editor(workspaceId: String, docId: String) -> DocEditorModel? { open[key(workspaceId, docId)]?.editor }
}

// MARK: Places

/// Documents, channels and names as this device knows them, for labels and search. Only readable, saved rows are here.
struct WikiContext: Sendable, Equatable {
    var docs: [DocRecord] = []
    var choice = ScopeChoice()
    var names: [String: String] = [:]
    var pending: [WriteItem] = []
    var viewerNpub: String?

    func channel(_ id: String) -> ChannelRecord? { choice.channels.first { $0.id == id } }

    func channelLabel(_ id: String) -> String {
        guard let channel = channel(id) else { return "Unknown channel" }
        let label = SidebarNavigation.label(channel, viewerNpub: viewerNpub, names: names)
        return SidebarNavigation.isDirectMessageChannel(channel) ? label : "#\(label)"
    }

    func scopeLabel(_ id: String?) -> String { choice.scopeName(id) ?? "Unknown scope" }

    /// "Scope / #channel", the place shown with every result.
    func place(of doc: DocRecord) -> String { "\(scopeLabel(doc.scopeId ?? choice.scope(ofChannel: doc.channelId))) / \(channelLabel(doc.channelId))" }

    func place(ofChannel id: String) -> String { "\(scopeLabel(channel(id)?.scopeId)) / \(channelLabel(id))" }

    /// "note" for a private note-to-self conversation, otherwise "document".
    func kindWord(forChannel id: String) -> String {
        guard let channel = channel(id), SidebarNavigation.isDirectMessageChannel(channel), SidebarNavigation.participants(channel).count == 1 else { return "document" }
        return "note"
    }

    func titleCount(_ title: String) -> Int { docs.filter { !$0.archived && WikiLinks.normalized($0.title) == WikiLinks.normalized(title) }.count }
}

// MARK: Controller

/// One document screen's wiki behaviour. It reads the local store (never waits on sync to open a saved page), keeps the
/// source document's draft safe before leaving, and does every change to links through the editor or the draft path.
@MainActor
@Observable
final class WikiLinkController {
    enum Pick: Equatable {
        /// An existing unresolved reference (a click): choosing or creating binds exactly that one.
        case reference(WikiTarget)
        /// A new link at the typed `[[` range, or at the selection when the range is nil.
        case insert(WikiEditorRange?)
    }

    enum Sheet: Identifiable, Equatable {
        case create(WikiTarget, WikiEditorRange?)
        case ambiguous(WikiTarget, [DocRecord], WikiEditorRange?)
        case picker(Pick, query: String)
        case move
        var id: String {
            switch self {
            case .create(let t, _): "create:\(t.title):\(t.occurrence)"
            case .ambiguous(let t, _, _): "ambiguous:\(t.title):\(t.occurrence)"
            case .picker: "picker"
            case .move: "move"
            }
        }
    }

    private(set) var context = WikiContext()
    var sheet: Sheet?
    /// A short result for the person ("Creating …", "Moved to …"), shown above the document.
    var banner: String?
    var bannerIsProblem = false

    @ObservationIgnored private(set) var workspace: WorkspaceRecord
    @ObservationIgnored let sourceDocId: String
    @ObservationIgnored private weak var app: AppModel?
    /// Current page titles (id → title) from the screen's snapshot; the editor page shows links under these.
    @ObservationIgnored var titles: [String: String] = [:] { didSet { if titles != oldValue { pushTitles() } } }
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored weak var editor: DocEditorModel?
    /// Keeps the person's unsaved text safe before the screen is left for a linked page.
    @ObservationIgnored var beforeLeaving: () async -> Void = {}

    init(workspace: WorkspaceRecord, sourceDocId: String, store: LocalStore) {
        self.workspace = workspace; self.sourceDocId = sourceDocId; self.store = store
    }

    func attach(_ app: AppModel) { self.app = app }

    var sourceChannelId: String? { context.docs.first { $0.id == sourceDocId }?.channelId }

    // MARK: Context

    func refresh() async {
        let w = workspace.id, store = store, connection = app?.connection?.id ?? ""
        async let docs = store.reader.docs(workspaceId: w, limit: 2000)
        async let choice = scopeChoice(store, w)
        async let names = directoryNames(store, w)
        async let writes = store.reader.writes(connectionId: connection, workspaceId: w)
        let next = WikiContext(docs: (try? await docs) ?? context.docs, choice: (try? await choice) ?? context.choice, names: (try? await names) ?? context.names,
                               pending: (try? await writes) ?? [], viewerNpub: app?.identity.npub)
        if next != context { context = next }
    }

    /// Tells the editor page the current page titles, so renamed pages show their new name.
    func pushTitles() { editor?.page?.setWikiTitles(titles) }

    // MARK: Opening

    /// Opens a page by its stable id: the saved copy shows at once and refreshes behind it; a page not saved here is fetched
    /// by id and shows why when it cannot be opened (deleted, or not shared with this account).
    func openPage(_ id: String) {
        Task {
            await beforeLeaving()
            app?.openRecord(kind: "doc", id: id)
        }
    }

    /// A tapped or clicked reference.
    func activate(_ target: WikiTarget, range: WikiEditorRange? = nil) {
        if let id = target.documentId { openPage(id); return }
        Task {
            await refresh()
            switch WikiLinks.resolve(target, in: context.docs, sourceChannelId: sourceChannelId) {
            case .available(let doc): openPage(doc.id)
            case .unresolved: sheet = .create(target, range)
            case .ambiguous(_, let matches): sheet = .ambiguous(target, matches, range)
            case .unavailable(let id): openPage(id)
            }
        }
    }

    // MARK: Choosing and creating

    /// Links to an existing page the person chose.
    func choose(_ doc: DocRecord, for pick: Pick, openAfter: Bool) {
        sheet = nil
        Task {
            switch pick {
            case .insert(let range):
                guard let page = editor?.page, editor?.pageReady == true,
                      await page.wikiInsert(documentId: doc.id, title: doc.title, range: range.map { ($0.from, $0.to) }) != nil else {
                    show("The link could not be added because the editor is not ready. Try again.", problem: true); return
                }
                editor?.wikiQuery = nil
            case .reference(let target):
                guard await bind(title: target.title, documentId: doc.id, occurrence: target.occurrence) else {
                    show("The link could not be saved yet. The page was not changed.", problem: true); return
                }
            }
            if openAfter { openPage(doc.id) }
        }
    }

    /// Creates a page in `channelId` and links it. The creation is one durable write that carries the link to put into this
    /// document, so a retry, relaunch or lost answer finds the page already made and never makes a second one.
    func createAndLink(title raw: String, channelId: String, for pick: Pick) {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        sheet = nil
        Task {
            await refresh()
            switch WikiCreate.existing(title: title, channelId: channelId, docs: context.docs, pending: context.pending) {
            case .page(let existing)?:
                show("“\(title)” already exists in \(context.place(ofChannel: channelId)), so it was linked instead of creating another.", problem: false)
                choose(existing, for: pick, openAfter: false)
                return
            case .pending?:
                show("“\(title)” is already being created in \(context.place(ofChannel: channelId)).", problem: false)
                return
            case nil: break
            }
            var occurrence: Int?
            switch pick {
            case .reference(let target): occurrence = target.occurrence
            case .insert(let range):
                guard let page = editor?.page, editor?.pageReady == true,
                      let placed = await page.wikiInsert(documentId: nil, title: title, range: range.map { ($0.from, $0.to) }) else {
                    show("The page was not created because the editor is not ready. Try again.", problem: true); return
                }
                occurrence = placed >= 0 ? placed : nil
                editor?.wikiQuery = nil
                _ = await editor?.persistDraft(state: .editing)
            }
            guard let model = app, let staging = model.staging else { return }
            let created = DocumentBody.newDocument(text: "")
            let name = UUID().uuidString.lowercased() + ".document.json"
            do {
                try created.bytes.write(to: staging.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { show(error.localizedDescription, problem: true); return }
            var payload: [String: any Sendable] = ["channel_id": channelId, "title": title, "staged": name, "content_type": created.contentType,
                                                   "file_name": String(title.prefix(60)) + ".document.json"]
            payload.merge(WikiCreate.linkPayload(sourceDocId: sourceDocId, title: title, occurrence: occurrence)) { _, new in new }
            if model.submit(WriteIntent(kind: .docCreate, targetId: channelId, payload: payload), in: workspace) {
                show("Creating the \(context.kindWord(forChannel: channelId)) “\(title)” in \(context.place(ofChannel: channelId)). The link is added when it is saved.", problem: false)
            } else {
                show("The page was not created because this device is not connected to the workspace.", problem: true)
            }
        }
    }

    /// Binds a title-only reference to a page: in the open editor when there is one, otherwise in the saved draft path.
    private func bind(title: String, documentId: String, occurrence: Int?) async -> Bool {
        if let editor {
            guard await editor.bindWiki(title: title, documentId: documentId, occurrence: occurrence) else { return false }
            return true
        }
        guard let model = app, let outcome = try? await model.bindWikiLink(title: title, documentId: documentId, occurrence: occurrence,
                                                                          sourceDocId: sourceDocId, workspace: workspace) else { return false }
        switch outcome {
        case .alreadyBound, .saved: return true
        case .keptInDraft(let message): show("The link is kept as an unsaved edit on this device: \(message)", problem: false); return true
        case .sourceNotSaved: return false
        }
    }

    // MARK: Toolbar and typing

    /// "Link to doc or note": opens the picker at the editor's selection.
    func openToolbarPicker() {
        Task {
            await refresh()
            let selection = await editor?.page?.wikiSelection()
            let range = selection.map { WikiEditorRange(from: $0.from, to: $0.to) }
            sheet = .picker(.insert(range), query: selection?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }

    func show(_ text: String, problem: Bool) { banner = text; bannerIsProblem = problem }
}

// MARK: Presentation

extension View {
    /// Presents the wiki sheets of a document screen.
    func wikiSheets(_ wiki: WikiLinkController, workspace: WorkspaceRecord) -> some View {
        sheet(item: Binding(get: { wiki.sheet }, set: { wiki.sheet = $0 })) { sheet in
            switch sheet {
            case .create(let target, _): WikiCreateSheet(wiki: wiki, target: target)
            case .ambiguous(let target, let matches, _): WikiAmbiguousSheet(wiki: wiki, target: target, matches: matches)
            case .picker(let pick, let query): WikiPickerSheet(wiki: wiki, pick: pick, initialQuery: query)
            case .move: DocumentMoveSheet(wiki: wiki, workspace: workspace)
            }
        }
    }
}

/// Where a page can be created: every channel the viewer can read, labelled Scope / channel.
private struct DestinationPicker: View {
    let context: WikiContext
    @Binding var channelId: String?

    var body: some View {
        Picker("Create in", selection: $channelId) {
            ForEach(context.choice.channels) { channel in
                Text(context.place(ofChannel: channel.id)).tag(Optional(channel.id))
            }
        }
        .accessibilityIdentifier("wiki.destination")
    }
}

struct WikiCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let wiki: WikiLinkController
    let target: WikiTarget
    @State private var channelId: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("There is no page called “\(target.title)” yet.")
                    DestinationPicker(context: wiki.context, channelId: $channelId)
                    if let channelId {
                        Text("It will be created as a \(wiki.context.kindWord(forChannel: channelId)) in \(wiki.context.place(ofChannel: channelId)) and linked here. "
                             + "Anyone who can read that channel can open it; a link does not give anyone access.")
                            .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    }
                }
            }
            .navigationTitle("Create page")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("wiki.create.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create and link") {
                        if let channelId { wiki.createAndLink(title: target.title, channelId: channelId, for: .reference(target)) }
                    }
                    .disabled(channelId == nil)
                    .accessibilityIdentifier("wiki.create.confirm")
                }
            }
            .task {
                await wiki.refresh()
                channelId = channelId ?? wiki.sourceChannelId ?? wiki.context.choice.channels.first?.id
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 300)
        #endif
    }
}

struct WikiAmbiguousSheet: View {
    @Environment(\.dismiss) private var dismiss
    let wiki: WikiLinkController
    let target: WikiTarget
    let matches: [DocRecord]

    var body: some View {
        NavigationStack {
            List {
                Section("Several pages are called “\(target.title)”. Choose the one this link means.") {
                    ForEach(matches) { doc in
                        Button { wiki.choose(doc, for: .reference(target), openAfter: true) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.title).font(.amb(.body).weight(.semibold))
                                Text(wiki.context.place(of: doc)).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                            }
                        }
                        .accessibilityLabel("\(doc.title), \(wiki.context.place(of: doc))")
                    }
                }
            }
            .navigationTitle("Choose a page")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 320)
        #endif
    }
}

/// Search accessible pages and link to one, or create a new page and link it. Search is limited to this channel until the
/// person asks for every channel and scope; same-titled pages are all listed with where they are, never merged.
struct WikiPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let wiki: WikiLinkController
    let pick: WikiLinkController.Pick
    let initialQuery: String
    @State private var query = ""
    @State private var everywhere = false
    @State private var newTitle = ""
    @State private var channelId: String?

    private var results: [DocRecord] {
        WikiLinks.search(query, in: wiki.context.docs, sourceChannelId: wiki.sourceChannelId, excluding: wiki.sourceDocId, everywhere: everywhere)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search pages", text: $query)
                        .accessibilityIdentifier("wiki.picker.search")
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Toggle("Search every channel and scope", isOn: $everywhere).accessibilityIdentifier("wiki.picker.everywhere")
                } footer: {
                    Text(everywhere ? "Showing pages you can read in every scope. Pages with the same title are listed separately; check where each one is."
                                    : "Showing pages in this channel only.")
                }
                Section("Pages") {
                    ForEach(results) { doc in
                        Button { wiki.choose(doc, for: pick, openAfter: false) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.title).font(.amb(.body).weight(.semibold)).foregroundStyle(Amb.foreground)
                                Text(wiki.context.place(of: doc) + (wiki.context.titleCount(doc.title) > 1 ? " · same title as another page" : ""))
                                    .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                            }
                        }
                        .accessibilityLabel("\(doc.title), \(wiki.context.place(of: doc))")
                        .accessibilityIdentifier("wiki.result.\(doc.title)")
                    }
                    if results.isEmpty { Text(everywhere ? "No page matches." : "No page in this channel matches. Turn on search every channel and scope, or create it below.").foregroundStyle(Amb.mutedForeground) }
                }
                Section("Create and link") {
                    TextField("Title of the new page", text: $newTitle).accessibilityIdentifier("wiki.picker.newTitle")
                    DestinationPicker(context: wiki.context, channelId: $channelId)
                    if let channelId {
                        Text("Creates a \(wiki.context.kindWord(forChannel: channelId)) in \(wiki.context.place(ofChannel: channelId)). Anyone who can read that channel can open it.")
                            .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    }
                    Button("Create and link") {
                        if let channelId { wiki.createAndLink(title: newTitle, channelId: channelId, for: pick) }
                    }
                    .disabled(channelId == nil || newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("wiki.picker.create")
                }
            }
            .navigationTitle("Link to doc or note")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("wiki.picker.cancel") } }
            .task {
                await wiki.refresh()
                if query.isEmpty { query = initialQuery }
                if newTitle.isEmpty { newTitle = initialQuery }
                channelId = channelId ?? wiki.sourceChannelId ?? wiki.context.choice.channels.first?.id
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}

/// The results of a `[[` typed in the editor, shown over the page. Choosing replaces what was typed with the link.
struct WikiQueryPanel: View {
    let wiki: WikiLinkController
    let query: WikiQuery
    @State private var everywhere = false

    private var results: [DocRecord] {
        Array(WikiLinks.search(query.text, in: wiki.context.docs, sourceChannelId: wiki.sourceChannelId, excluding: wiki.sourceDocId, everywhere: everywhere).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(results) { doc in
                Button { wiki.choose(doc, for: .insert(query.range), openAfter: false) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(doc.title).font(.amb(.callout).weight(.semibold)).foregroundStyle(Amb.foreground)
                        Text(wiki.context.place(of: doc)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(doc.title), \(wiki.context.place(of: doc))")
                .accessibilityIdentifier("wiki.query.result.\(doc.title)")
                Divider()
            }
            let title = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                Button { wiki.sheet = .picker(.insert(query.range), query: title) } label: {
                    Label("Create “\(title)” or search more…", systemImage: "plus.circle").padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.plain).foregroundStyle(Amb.primary)
                .accessibilityIdentifier("wiki.query.create")
            }
            if !everywhere {
                Button("Search every channel and scope") { everywhere = true }
                    .buttonStyle(.plain).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).padding(.horizontal, 12).padding(.bottom, 6)
                    .accessibilityIdentifier("wiki.query.everywhere")
            }
        }
        .background(Amb.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Amb.border))
        .shadow(radius: 6, y: 2)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link to a page")
        .accessibilityIdentifier("wiki.query")
        .task { await wiki.refresh() }
    }
}

// MARK: Move

struct DocumentMoveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let wiki: WikiLinkController
    let workspace: WorkspaceRecord
    @State private var destination: String?
    @State private var working = false
    @State private var problem: String?
    @State private var acknowledgedPrivate = false

    private var source: DocRecord? { wiki.context.docs.first { $0.id == wiki.sourceDocId } }

    private var consequences: DocMoveConsequences? {
        guard let source, let from = wiki.context.channel(source.channelId), let destination, let to = wiki.context.channel(destination) else { return nil }
        return DocMovePlan.consequences(from: from, to: to, viewerNpub: model.identity.npub, names: wiki.context.names)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let source { LabeledContent("Now in", value: wiki.context.place(of: source)) }
                    Picker("Move to", selection: $destination) {
                        ForEach(wiki.context.choice.channels.filter { $0.id != source?.channelId }) { channel in
                            Text(wiki.context.place(ofChannel: channel.id)).tag(Optional(channel.id))
                        }
                    }
                    .accessibilityIdentifier("wiki.move.destination")
                }
                if let consequences {
                    Section("What changes") {
                        ForEach(consequences.lines, id: \.self) { Text($0).font(.amb(.footnote)) }
                        if consequences.touchesPrivateConversation {
                            Toggle("I understand who can read it afterwards", isOn: $acknowledgedPrivate).accessibilityIdentifier("wiki.move.acknowledge")
                        }
                    }
                }
                if !model.isUnlocked { Text("Moving needs you to be unlocked and connected. Nothing is queued for later.").foregroundStyle(Amb.warning) }
                if let problem { Text(problem).foregroundStyle(Amb.destructive).accessibilityIdentifier("wiki.move.problem") }
            }
            .navigationTitle("Move document")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("wiki.move.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "Moving…" : "Move") { move() }
                        .disabled(working || destination == nil || !model.isUnlocked || (consequences?.touchesPrivateConversation == true && !acknowledgedPrivate))
                        .accessibilityIdentifier("wiki.move.confirm")
                }
            }
            .task { await wiki.refresh() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 440)
        #endif
    }

    private func move() {
        guard let destination, let channel = wiki.context.channel(destination), let saver = model.saver, let connection = model.connection else { return }
        working = true; problem = nil
        Task {
            // The current row version, read just now, and the editor's unsaved text made durable first.
            if let editor = wiki.editor { _ = await editor.persistDraft(state: .editing) }
            let fresh = try? await model.store?.reader.doc(workspaceId: workspace.id, id: wiki.sourceDocId)
            guard let fresh else { problem = "This document is not saved on this device yet, so it cannot be moved now."; working = false; return }
            let result = await saver.move(docId: fresh.id, to: channel, rowVersion: fresh.rowVersion, connection: connection, workspace: workspace)
            working = false
            switch result {
            case .moved(let doc, let note):
                wiki.editor?.rebase(rowVersion: doc.rowVersion)
                if wiki.editor != nil { _ = await wiki.editor?.persistDraft(state: .editing) }
                await wiki.refresh()
                wiki.show("Moved to \(wiki.context.place(ofChannel: doc.channelId)). Links to this document still open it." + (note.map { " " + $0 } ?? ""), problem: note != nil)
                dismiss()
            case .stale(let text), .sameDestination(let text), .denied(let text), .notMoved(let text):
                problem = text
            case .unknown(let text):
                await wiki.refresh()
                problem = text
            }
        }
    }
}

// MARK: Linked from

/// Pages whose saved text links to this one. Only pages saved on this device can be checked; the count says how many were.
struct WikiBacklinksView: View {
    @Environment(AppModel.self) private var model
    let docId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    let context: WikiContext
    @State private var result: WikiLinks.Backlinks?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let result {
                    if result.sources.isEmpty { Text("No page saved on this device links here.").foregroundStyle(Amb.mutedForeground) }
                    ForEach(result.sources) { doc in
                        Button { model.openRecord(kind: "doc", id: doc.id) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(doc.title).font(.amb(.body).weight(.semibold))
                                Text(context.place(of: doc)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(doc.title), \(context.place(of: doc))")
                    }
                    Text(result.isComplete ? "Checked every page you can read."
                         : "Checked \(result.examined) of \(result.total) pages. The others are not saved on this device, so any links in them are not shown here.")
                        .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Linked from").font(.amb(.subheadline).weight(.semibold))
        }
        .accessibilityIdentifier("doc.backlinks")
        .task(id: expanded) { if expanded { await load() } }
    }

    private func load() async {
        let w = workspace.id, id = docId, store = store
        let found = await Task.detached(priority: .utility) { () -> WikiLinks.Backlinks? in
            guard let docs = try? await store.reader.docs(workspaceId: w, limit: 2000), let target = docs.first(where: { $0.id == id }) else { return nil }
            var bodies: [String: DocumentBody] = [:]
            for doc in docs where doc.id != id {
                if let cached = try? await store.reader.docBody(workspaceId: w, docId: doc.id) { bodies[doc.id] = DocumentBody(bytes: cached.bytes, contentType: cached.contentType) }
            }
            return WikiLinks.backlinks(to: target, docs: docs, bodies: bodies)
        }.value
        result = found
    }
}
