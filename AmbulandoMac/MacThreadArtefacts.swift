import AmbulandoCore
import SwiftUI
import AppKit

@MainActor @Observable
final class MacThreadArtefactTab: Identifiable {
    let id: String
    let kind: String
    var title: String
    var icon = "doc"
    var open = true
    @ObservationIgnored var validate: ((ArtefactChatReference) async -> Bool)?
    @ObservationIgnored var checkpoint: (() async -> Bool)?
    @ObservationIgnored var prepare: (() async throws -> ArtefactChatReference)?
    init(kind: String, id: String) { self.kind = kind; self.id = id; self.title = kind == "doc" ? "Document" : "Artefact" }
}

@MainActor @Observable
final class MacThreadArtefacts: Equatable {
    nonisolated static func == (lhs: MacThreadArtefacts, rhs: MacThreadArtefacts) -> Bool { lhs === rhs }
    var tabs: [MacThreadArtefactTab] = []
    var selected: String?
    var browsing = false
    var shown = false
    var expanded = false
    var busy = false
    var failure: String?
    #if DEBUG
    static weak var testingState: MacThreadArtefacts?
    #endif
    func open(kind: String, id: String) {
        guard !busy else { return }
        let kind = kind == "document" ? "doc" : kind
        if let tab = tabs.first(where: { $0.id == id && $0.kind == kind }) { tab.open = true }
        else { tabs.append(MacThreadArtefactTab(kind: kind, id: id)) }
        selected = id; shown = true
    }
    func close(_ tab: MacThreadArtefactTab) {
        guard !busy else { return }
        busy = true; failure = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task { @MainActor in
            defer { busy = false }
            do {
                if let prepare = tab.prepare { _ = try await prepare() }
                tab.open = false
                selected = tabs.first(where: \.open)?.id
                if selected == nil { shown = false }
            } catch {
                failure = "Tab kept open: \(error.localizedDescription) Save or resolve this tab, then retry close."
            }
        }
    }
    func checkpointAll() async -> Bool {
        guard !busy else { return false }
        NSApp.keyWindow?.makeFirstResponder(nil)
        busy = true
        defer { busy = false }
        for tab in tabs {
            if let checkpoint = tab.checkpoint, !(await checkpoint()) {
                failure = "Keep this conversation open: an editor could not preserve its latest changes. Retry closing after resolving the tab."
                return false
            }
        }
        return true
    }
    func prepare(target: ChatTarget, holdForEnqueue: Bool = false) async throws -> Data? {
        guard !busy else { throw ArtefactChatContext.ContextError.unresolved }
        guard let thread = target.threadId else { return nil }
        let open = tabs.filter(\.open)
        // Hidden workspace has no visible artefact, but dirty open editors must still save.
        guard !open.isEmpty else { return nil }
        NSApp.keyWindow?.makeFirstResponder(nil)
        busy = true; failure = nil
        var prepared = false
        defer { if !holdForEnqueue || !prepared { busy = false } }
        var preparingTitle = "artefact"
        do {
            var refs: [ArtefactChatReference] = []
            for tab in open {
                preparingTitle = tab.title
                guard let prepare = tab.prepare else { throw ArtefactChatContext.ContextError.unresolved }
                refs.append(try await prepare())
            }
            for (tab, reference) in zip(open, refs) {
                preparingTitle = tab.title
                if let validate = tab.validate, !(await validate(reference)) { throw ArtefactChatContext.ContextError.unresolved }
            }
            let context = try ArtefactChatContext(workspaceID: target.workspaceId, channelID: target.channelId,
                threadID: thread, visibleRecordID: selected ?? open[0].id, workspaceVisible: shown, open: refs).encoded(for: target)
            prepared = true
            return context
        } catch {
            failure = "Send paused for \(preparingTitle): \(error.localizedDescription) Resolve the affected tab, then press Send to retry."
            throw error
        }
    }
}

struct MacThreadArtefactOwnerKey: PreferenceKey {
    static let defaultValue: MacThreadArtefacts? = nil
    static func reduce(value: inout MacThreadArtefacts?, nextValue: () -> MacThreadArtefacts?) { value = nextValue() ?? value }
}
struct MacThreadArtefactExpandedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
extension EnvironmentValues {
    @Entry var macThreadArtefacts: MacThreadArtefacts? = nil
    @Entry var macThreadArtefactTab: MacThreadArtefactTab? = nil
}

/// Keep both conversation and editor trees mounted across tab/visibility changes.
struct MacThreadArtefactLayout<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openMention) private var inheritedOpen
    let state: MacThreadArtefacts
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    @ViewBuilder let content: () -> Content
    @State private var fraction: CGFloat = 0.34
    @State private var retainedWorkspaceWidth: CGFloat = 640
    @State private var retainedChatWidth: CGFloat = 360
    @State private var dragStart: CGFloat?
    var body: some View {
        GeometryReader { proxy in
            let chatWidth: CGFloat = state.expanded && state.shown ? 0 : state.shown ? max(280, min(proxy.size.width - 340, proxy.size.width * fraction)) : proxy.size.width
            let workspaceWidth = state.shown ? max(340, proxy.size.width - chatWidth - 6) : retainedWorkspaceWidth
            HStack(spacing: 0) {
                content().frame(width: chatWidth > 0 ? chatWidth : retainedChatWidth).frame(width: chatWidth).clipped()
                    .accessibilityHidden(state.expanded && state.shown)
                    .environment(\.macThreadArtefacts, state)
                    .environment(\.openMention, OpenMentionAction { kind, id in
                        if ["file", "doc", "document"].contains(kind.lowercased()) {
                            state.open(kind: kind.lowercased(), id: id.lowercased())
                        } else { inheritedOpen(kind: kind, id: id) }
                    })
                Rectangle().fill(Amb.border).frame(width: state.shown ? 6 : 0)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { value in
                        if dragStart == nil { dragStart = fraction }
                        fraction = max(0.2, min(0.7, (dragStart ?? fraction) + value.translation.width / max(1, proxy.size.width)))
                    }.onEnded { _ in dragStart = nil })
                    .accessibilityLabel("Resize conversation and artefact workspace")
                    .accessibilityIdentifier("thread.artefacts.divider")
                workspaceBody.frame(width: workspaceWidth).frame(width: max(0, proxy.size.width - chatWidth - (state.shown ? 6 : 0)))
                    .clipped().opacity(state.shown ? 1 : 0).allowsHitTesting(state.shown)
                    .accessibilityHidden(!state.shown)
            }
            .onChange(of: workspaceWidth) { _, width in if state.shown { retainedWorkspaceWidth = width } }
            .onChange(of: chatWidth) { _, width in if width > 0 { retainedChatWidth = width } }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacThreadArtefactsCheck") { MacThreadArtefacts.testingState = state }
        }
        #endif
        .sheet(isPresented: Bindable(state).browsing) {
            MacThreadArtefactBrowser(state: state, target: target, workspace: workspace, store: store)
        }
        .preference(key: MacThreadArtefactOwnerKey.self, value: state)
        .preference(key: MacThreadArtefactExpandedKey.self, value: state.shown)
    }
    private var workspaceBody: some View {
        VStack(spacing: 0) {
            HStack {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(state.tabs.filter(\.open)) { tab in
                                MacThreadArtefactTabLabel(state: state, tab: tab).id(tab.id)
                            }
                        }.padding(2)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
                        Task { @MainActor in
                            await Task.yield()
                            if let id = state.selected { proxy.scrollTo(id, anchor: .trailing) }
                        }
                    }
                    .onChange(of: state.shown) { _, shown in
                        if shown, let id = state.selected { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: state.selected) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onChange(of: state.tabs.filter(\.open).map(\.id)) { _, _ in
                        if let id = state.selected { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                Button { state.browsing = true } label: { Image(systemName: "plus").frame(width: 26, height: 28).contentShape(Rectangle()) }
                    .help("Open an existing Doc or artefact")
                    .accessibilityLabel("Browse artefacts")
                    .accessibilityIdentifier("thread.artefacts.add")
                Button { state.expanded.toggle() } label: { Image(systemName: state.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 26, height: 28).contentShape(Rectangle()) }
                    .help(state.expanded ? "Restore conversation split" : "Expand artefact workspace")
                    .accessibilityLabel(state.expanded ? "Restore conversation split" : "Expand artefact workspace")
                    .accessibilityIdentifier("thread.artefacts.expand")
                Button { state.shown = false; state.expanded = false } label: { Image(systemName: "sidebar.right").frame(width: 26, height: 28).contentShape(Rectangle()) }
                    .help("Close workspace; keep tabs and edits")
                    .accessibilityLabel("Close artefact workspace")
                    .accessibilityIdentifier("thread.artefacts.close")
            }.buttonStyle(.borderless).controlSize(.small).padding(6).background(Amb.card).disabled(state.busy)
            if let failure = state.failure { Text(failure).font(.caption).foregroundStyle(Amb.destructive).padding(8) }
            Text("Send includes exact saved revisions of open tabs. Unsaved changes must save first.")
                .font(.caption).foregroundStyle(Amb.mutedForeground).padding(.horizontal, 8)
            Divider()
            ZStack {
                ForEach(state.tabs) { tab in
                    NavigationStack {
                        Group {
                            if tab.kind == "doc" { DocumentView(docId: tab.id, workspace: workspace, store: store) }
                            else { FileDetailView(fileId: tab.id, workspace: workspace, store: store) }
                        }
                        .environment(\.macThreadArtefactTab, tab)
                    }
                    .opacity(state.selected == tab.id && tab.open ? 1 : 0)
                    .allowsHitTesting(state.selected == tab.id && tab.open && !state.busy)
                    .disabled(state.busy)
                    .accessibilityHidden(state.selected != tab.id || !tab.open)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread.artefacts.workspace")
    }
}


private struct MacThreadArtefactTabLabel: View {
    let state: MacThreadArtefacts
    let tab: MacThreadArtefactTab
    @State private var hovering = false
    private var selected: Bool { state.selected == tab.id }
    var body: some View {
        HStack(spacing: 2) {
            Button { state.selected = tab.id; state.shown = true } label: {
                Label(tab.title, systemImage: tab.kind == "doc" ? "doc.text" : tab.icon)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 70, maxWidth: 180, alignment: .leading)
                    .padding(.leading, 9).padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .help(tab.title).accessibilityLabel(tab.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("thread.artefacts.tab.\(tab.id)")
            Button { state.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 23, height: 26).contentShape(Rectangle())
            }
            .foregroundStyle(selected || hovering ? Amb.foreground : Amb.mutedForeground)
            .help("Close tab; save pending changes first")
            .accessibilityLabel("Close \(tab.title) tab; retain work")
            .accessibilityIdentifier("thread.artefacts.tab.close.\(tab.id)")
        }
        .buttonStyle(.plain)
        .background(selected ? Amb.selectedFill : hovering ? Color.primary.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottom) {
            if selected { Capsule().fill(Amb.primary).frame(height: 2).padding(.horizontal, 8) }
        }
        .onHover { hovering = $0 }
    }
}

/// Labels come only from the current workspace's authorized local records; opening uses existing editors.
struct MacThreadArtefactBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let state: MacThreadArtefacts
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var query = LiveQuery<DocsSnapshot>(initial: DocsSnapshot())
    @State private var channel: String
    @State private var search = ""
    @State private var type: ArtefactType?
    @FocusState private var searching: Bool

    init(state: MacThreadArtefacts, target: ChatTarget, workspace: WorkspaceRecord, store: LocalStore) {
        self.state = state; self.target = target; self.workspace = workspace; self.store = store
        _channel = State(initialValue: target.channelId)
    }
    struct Row: Identifiable {
        let id: String
        let kind: String
        let title: String
        let type: ArtefactType
        let channel: String?
        let updated: String
    }
    static func rows(_ snapshot: DocsSnapshot, channel: String, search: String, type: ArtefactType?) -> [Row] {
        let docs = snapshot.docs.map { Row(id: $0.id, kind: "doc", title: $0.title, type: .document, channel: $0.channelId, updated: $0.updatedAt) }
        let files = snapshot.files.compactMap { file -> Row? in
            guard let type = ArtefactType.file(file) else { return nil }
            return Row(id: file.id, kind: "file", title: file.displayName, type: type, channel: file.channelId, updated: file.updatedAt)
        }
        let allowed = Set(snapshot.choice.channels.map(\.id))
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (docs + files).filter {
            guard let c = $0.channel, allowed.contains(c) else { return false }
            return (channel.isEmpty || c == channel) && (type == nil || $0.type == type)
                && (q.isEmpty || $0.title.localizedCaseInsensitiveContains(q))
        }.sorted { $0.updated == $1.updated ? $0.id < $1.id : $0.updated > $1.updated }
    }
    private var boundaryValid: Bool {
        model.connection?.id == target.connectionId && model.selectedWorkspace?.id == workspace.id
            && model.identity.npub == model.connection?.signerNpub
    }
    private var rows: [Row] { Self.rows(query.value, channel: channel, search: search, type: type) }
    private var listKeys: Set<String> {
        Set(query.value.choice.channels.filter { channel.isEmpty || $0.id == channel }.flatMap {
            [WorkspaceSync.docsKey(workspace.id, $0.id), WorkspaceSync.filesKey(workspace.id, $0.id)]
        })
    }
    private var refreshing: Bool {
        !model.syncStatus.running.union(model.syncStatus.queued).isDisjoint(with: listKeys)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open artefact").font(.title2.weight(.semibold))
            Text("Browse existing Docs, whiteboards and HTML in this workspace.").foregroundStyle(.secondary)
            TextField("Search titles", text: $search).textFieldStyle(.roundedBorder)
                .focused($searching).accessibilityIdentifier("thread.artefacts.browser.search")
            HStack {
                Picker("Channel", selection: $channel) {
                    Text("All authorised channels · this workspace").tag("")
                    if !query.value.choice.channels.contains(where: { $0.id == target.channelId }) {
                        Text("Conversation channel").tag(target.channelId)
                    }
                    ForEach(query.value.choice.channels) { c in
                        Text("\(query.value.choice.scopeName(c.scopeId) ?? "Scope") / #\(query.value.choice.channelName(c.id) ?? "Channel")\(c.id == target.channelId ? " · conversation" : "")").tag(c.id)
                    }
                }.accessibilityIdentifier("thread.artefacts.browser.channel")
                Picker("Type", selection: $type) {
                    Text("All types").tag(Optional<ArtefactType>.none)
                    ForEach(ArtefactType.allCases) { Text($0.label).tag(Optional($0)) }
                }
            }
            if !model.isUnlocked {
                ContentUnavailableView("Workspace locked", systemImage: "lock", description: Text("Unlock Ambulando to browse authorised artefacts."))
            } else if let error = query.error {
                ContentUnavailableView("Could not load artefacts", systemImage: "exclamationmark.triangle", description: Text(error))
                Button("Retry") { start() }
            } else if !query.loaded {
                ProgressView("Loading artefacts…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    Button {
                        guard model.isUnlocked, boundaryValid, !state.busy else { return }
                        state.open(kind: row.kind, id: row.id)
                        if let tab = state.tabs.first(where: { $0.id == row.id && $0.kind == row.kind }) {
                            tab.title = row.title; tab.icon = row.type.icon
                        }
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: row.type.icon).frame(width: 22).foregroundStyle(Amb.primary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title).lineLimit(1)
                                Text("\(row.type.label) · #\(query.value.choice.channelName(row.channel) ?? "Channel") · \(ChatTime.label(row.updated))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityIdentifier("thread.artefacts.browser.row.\(row.id)")
                }
                .overlay {
                    if rows.isEmpty && !refreshing {
                        ContentUnavailableView(search.isEmpty && type == nil ? "No artefacts" : "No matching artefacts", systemImage: "doc.text.magnifyingglass",
                            description: Text("Choose another channel or change the title search."))
                    }
                }
                Text("Showing up to 500 saved Docs and 500 Files. Refresh loads authorised lists; content loads when opened.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if refreshing { ProgressView("Refreshing authorised lists…").controlSize(.small) }
            if !model.syncStatus.connectionFailures.isDisjoint(with: listKeys) {
                Text("Connection unavailable. Showing saved artefacts; Refresh retries the lists.")
                    .font(.caption).foregroundStyle(Amb.warning)
            }
            ForEach(query.value.choice.channels.filter { channel.isEmpty || $0.id == channel }) { c in
                SyncErrorNote(key: WorkspaceSync.docsKey(workspace.id, c.id))
                SyncErrorNote(key: WorkspaceSync.filesKey(workspace.id, c.id))
            }
            HStack {
                Button("Refresh") { refresh(force: true) }.disabled(!model.isUnlocked)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("thread.artefacts.browser.cancel")
            }
        }.padding(20).frame(minWidth: 560, idealWidth: 660, minHeight: 460, idealHeight: 540)
        .task { start(); refresh(); searching = true }
        .onChange(of: channel) { _, _ in start(); refresh() }
        .onChange(of: boundaryValid) { _, valid in if !valid { query.stop(); dismiss() } }
        .onChange(of: model.isUnlocked) { _, unlocked in
            if unlocked { start(); refresh() } else { query.stop() }
        }
        .onDisappear { query.stop() }
    }
    private func refresh(force: Bool = false) {
        guard model.isUnlocked, boundaryValid else { return }
        let scope = query.value.choice.scope(ofChannel: channel) ?? model.navigation.value.channel(channel)?.scopeId
        model.openDocs(workspace, scopeId: scope, force: force); model.openFiles(workspace, scopeId: scope, force: force)
    }
    private func start() {
        guard model.isUnlocked, boundaryValid else { query.stop(); return }
        let w = workspace.id, store = store, selectedChannel = channel
        query.start(store: store, matches: { $0.table == .access || ($0.workspaceId == w && [.docs, .files, .channels, .scopes].contains($0.table)) }) {
            let choice = try await scopeChoice(store, w)
            let context: WorkContext
            if selectedChannel.isEmpty { context = .home }
            else if let scope = choice.scope(ofChannel: selectedChannel) {
                context = WorkContext(scopeId: scope, channelId: selectedChannel)
            } else { return DocsSnapshot(choice: choice) }
            async let docs = store.reader.docs(workspaceId: w, context: context)
            async let files = store.reader.files(workspaceId: w, context: context)
            return DocsSnapshot(docs: try await docs, files: try await files, choice: choice)
        }
    }
}
