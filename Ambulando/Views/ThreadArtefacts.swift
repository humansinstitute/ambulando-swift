import AmbulandoCore
import SwiftUI

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
            if let error = state.membershipError { Text(error).foregroundStyle(Amb.warning) }
            if let error = state.failure { Text(error).foregroundStyle(Amb.warning) }
            if !state.members.isEmpty {
                Text("Attached to this thread").font(.headline)
                ScrollView {
                    VStack {
                        ForEach(state.members, id: \.identity) { member in
                            HStack {
                                Button(state.labels[member] ?? "Loading \(member.kind == "doc" ? "document" : "artefact")…") {
                                    state.open(kind: member.kind, id: member.id)
                                }.accessibilityIdentifier("thread.artefacts.attached.\(member.id)")
                                Spacer()
                                Button("Remove from thread", role: .destructive) { state.remove(member) }
                                    .accessibilityIdentifier("thread.artefacts.remove.\(member.id)")
                            }
                        }
                    }
                }.frame(maxHeight: 130).disabled(state.busy || state.membershipError != nil)
            }
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
        }.padding(20)
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 660, minHeight: 460, idealHeight: 540)
        #endif
        .task { start(); refresh(); await state.refresh(); searching = true }
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
