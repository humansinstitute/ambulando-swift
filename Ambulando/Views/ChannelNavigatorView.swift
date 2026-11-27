import AmbulandoCore
import SwiftUI

/// Chat follows the shared context with one compact conversation inbox. Inbox selections push the existing
/// thread renderer inline; Deck, restored links and mentions retain their existing focused presentation.
struct ChatStack<Banner: View>: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    @ViewBuilder let banner: () -> Banner
    /// Owned here, not by the toolbar button: toolbar content is rebuilt as sync state changes, which would drop the sheet.
    @State private var newScope: ScopeRecord?
    @State private var created: ChannelRecord?

    var body: some View {
        @Bindable var model = model
        let showingInboxThread = model.chatInboxRoute != nil
        NavigationStack(path: $model.chatPath) {
            VStack(spacing: 0) {
                banner()
                ContextBar()
                ZStack {
                    ChatContextRoot(active: !showingInboxThread) { model.chatPath = []; model.chatInboxRoute = $0 }
                        .opacity(showingInboxThread ? 0 : 1)
                        .accessibilityHidden(showingInboxThread)
                        .allowsHitTesting(!showingInboxThread)
                    if case .thread(let w, let channel, let thread)? = model.chatInboxRoute,
                       let workspace = model.selectedWorkspace, workspace.id == w,
                       let store = model.store, let connection = model.connection {
                        ThreadView(target: ChatTarget(connectionId: connection.id, workspaceId: w, channelId: channel, threadId: thread),
                                   workspace: workspace, store: store, inlineHeader: true)
                            .id("\(w):\(thread)")
                    }
                }
            }
            .background(Amb.background)
            .toolbarItems(showSettings: $showSettings, pin: ToolbarPin.chat(nil, channel: model.context.channelId, workspace: model.selectedWorkspace), showsSidebar: !showingInboxThread)
            .toolbar {
                if showingInboxThread {
                    ToolbarItem(placement: .leadingBar) {
                        Button {
                            model.chatInboxRoute = nil
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .help("Back")
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("chat.thread.back")
                    }
                }
            }

            .navigationDestination(for: ChatRoute.self) { route in
                Group {
                if let workspace = model.selectedWorkspace, route.workspaceId == workspace.id, let store = model.store, let connection = model.connection {
                    switch route {
                    case .channel(_, let channelId):
                        ChannelView(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: channelId),
                                    workspace: workspace, store: store)
                    case .thread(_, let channelId, let threadId):
                        ThreadView(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: channelId, threadId: threadId),
                                   workspace: workspace, store: store)
                    }
                } else {
                    ContentUnavailableView("Not in this workspace", systemImage: "arrow.uturn.backward",
                                           description: Text("This conversation belongs to another workspace."))
                }
                }
                .toolbarItems(showSettings: $showSettings, pin: ToolbarPin.chat(route, channel: nil, workspace: model.selectedWorkspace), showsSidebar: false)
            }
        }
        .onChange(of: model.chatCreatedThread) { _, focus in
            guard let focus, focus.workspaceId == model.selectedWorkspace?.id, let route = focus.chatRoute else { return }
            model.chatCreatedThread = nil
            model.chatPath = []
            model.chatInboxRoute = route
        }
        .onChange(of: model.context) { _, _ in model.chatInboxRoute = nil }
        .onChange(of: model.selectedWorkspaceBoundary?.id) { _, _ in model.chatInboxRoute = nil }
        .sheet(item: $newScope, onDismiss: {
            guard let channel = created else { return }
            created = nil
            model.selectContext(WorkContext(scopeId: channel.scopeId, channelId: channel.id))
        }) { scope in
            NewChannelSheet(scope: scope) { created = $0 }
        }
    }
}

/// Chat's root for the current context.
struct ChatContextRoot: View {
    @Environment(AppModel.self) private var model
    var active = true
    var openConversation: (ChatRoute) -> Void

    var body: some View {
        if let workspace = model.selectedWorkspace, let store = model.store, let connection = model.connection {
            ConversationInbox(workspace: workspace, store: store, connection: connection, active: active, openConversation: openConversation)
            .id(model.selectedWorkspaceBoundary?.id ?? workspace.id)
        } else {
            ContentUnavailableView {
                Label("No workspace", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text(model.workspaces.loaded ? "Discovery found no workspaces for this identity yet. Pull to refresh or check Settings." : "Loading saved workspaces…")
            }
            .refreshable { model.refresh(force: true) }
        }
    }
}

/// "New" in Chat's toolbar for the selected scope: a direct message in a DM scope, a channel elsewhere (where the member
/// may create one). `ChatStack` presents the same sheet the sidebar's plus opens, then shows the created or reused conversation.
struct ChatNewButton: View {
    @Environment(AppModel.self) private var model
    @Binding var sheetScope: ScopeRecord?

    var body: some View {
        let nav = model.navigation.value
        if let scope = nav.scope(model.context.scopeId), ManagementPermissions.canCreateChannel(in: scope, membership: model.membership) {
            let direct = ManagementPermissions.isDirectMessageScope(scope)
            Button { sheetScope = scope } label: { Label(direct ? "New message" : "New channel", systemImage: "square.and.pencil") }
                .accessibilityLabel(direct ? "New direct message" : "New channel in \(scope.name)")
                .accessibilityIdentifier("chat.new")
        }
    }
}

private struct ConversationInboxSnapshot: Sendable, Equatable {
    var rows: [ConversationRow] = []
    var people = PeopleDirectory()
}

/// One local conversation per row. Selection uses the same focused thread and composer as Deck.
struct ConversationInbox: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    let connection: ConnectionRecord
    var active = true
    var openConversation: (ChatRoute) -> Void
    @State private var query = ""
    @State private var filter = ConversationFilter.all
    @State private var snapshot = LiveQuery<ConversationInboxSnapshot>(initial: .init())
    @State private var composing = false
    @State private var created: ThreadFocus?
    @State private var position = ScrollPosition(edge: .top)
    @State private var startedIdentity = ""
    #if os(iOS)
    @State private var keyboardShown = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search chats", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("chat.inbox.search")
                Picker("Conversations", selection: $filter) {
                    ForEach(ConversationFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 240)
            }.padding(12)
            if let error = snapshot.error { SyncNote(text: error, tone: .warning) }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(snapshot.value.rows) { row in
                        Button { open(row) } label: { conversation(row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("chat.conversation.\(row.id)")
                    }
                    if snapshot.loaded && snapshot.value.rows.isEmpty {
                        Text(query.isEmpty ? "No conversations in this view." : "No matches in downloaded history.")
                            .foregroundStyle(Amb.mutedForeground).padding(32)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, DeckLayout.newThreadButton + 28)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }.scrollPosition($position)
            ForEach(model.navigation.value.channels(in: model.context)) { channel in
                let key = WorkspaceSync.messagesKey(workspace.id, channel.id)
                if model.isSyncing(key) { Text("Downloading #\(model.navigation.value.label(channel))…").font(.amb(.caption)) }
                if let error = model.syncError(forKey: key) { SyncNote(text: error, tone: .warning) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            #if os(iOS)
            if !keyboardShown {
                floatingNewThreadButton
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
            }
            #else
            floatingNewThreadButton
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            #endif
        }
        .task(id: "\(model.context.encoded()):\(filter.rawValue):\(query):\(active)") { if active { start() } else { snapshot.pause() } }
        .onDisappear { snapshot.pause() }
        .onAppear {
            model.openDeckActivity(workspace, channelIds: model.navigation.value.channels(in: model.context).map(\.id))
        }
        #if os(iOS)
        .onKeyboard(willHide: { keyboardShown = false }, didShow: { keyboardShown = true })
        .fullScreenCover(isPresented: $composing, onDismiss: {
            if let created, let route = created.chatRoute { openConversation(route); self.created = nil }
        }) { DeckThreadComposer(workspace: workspace, store: store, onCreated: { created = $0 }) }
        #endif
    }

    private var floatingNewThreadButton: some View {
        Button {
            #if os(macOS)
            model.threadCreationFromChat = true
            model.composingThread = true
            #else
            composing = true
            #endif
        } label: {
            Image(systemName: "plus").font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Amb.primaryForeground)
                .frame(width: DeckLayout.newThreadButton, height: DeckLayout.newThreadButton)
                .background(Amb.primary, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("New thread")
        .accessibilityLabel("New thread")
        .accessibilityHint("Starts a new thread in the current scope or channel")
        .accessibilityIdentifier("chat.inbox.new")
    }

    private func open(_ row: ConversationRow) {
        let target = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: row.summary.channelId, threadId: row.id)
        if let hit = row.hitMessageId { ReadingPositions.shared.record(target, firstVisible: hit) }
        if row.standalone {
            let channelTarget = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: row.summary.channelId)
            ReadingPositions.shared.record(channelTarget, firstVisible: row.hitMessageId ?? row.id)
            model.chatPath.append(.channel(workspaceId: workspace.id, channelId: row.summary.channelId))
        } else {
            openConversation(.thread(workspaceId: workspace.id, channelId: row.summary.channelId, threadId: row.id))
        }
    }

    private func conversation(_ row: ConversationRow) -> some View {
        let summary = row.summary
        let nav = model.navigation.value
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if row.unread {
                    Circle().fill(Amb.brandOrange).frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                }
                Text(MentionCodec.plain(summary.title ?? summary.rootBody))
                    .font(.amb(.body).weight(row.unread ? .bold : .regular))
                    .foregroundStyle(Amb.foreground)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if row.unread {
                    Text("Unread")
                        .font(.amb(.caption2).weight(.semibold))
                        .foregroundStyle(Amb.brandOrange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Amb.brandOrange.opacity(0.14), in: Capsule())
                }
                Text(String(summary.lastActivityAt.prefix(10))).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            }
            HStack(spacing: 8) {
                Text(nav.channel(summary.channelId).map { nav.label($0) } ?? "Conversation").font(.amb(.caption).weight(.medium))
                ForEach(Array(row.participants.prefix(4)), id: \.self) { npub in
                    PersonAvatar(person: snapshot.value.people.person(npub)).frame(width: 20, height: 20).clipped()
                }
                Text("\(summary.replyCount) \(summary.replyCount == 1 ? "reply" : "replies")").font(.amb(.caption))
                Text(highlighted(MentionCodec.plain(row.excerpt))).font(.amb(.subheadline)).lineLimit(1)
            }.foregroundStyle(Amb.mutedForeground)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((row.unread ? Amb.brandOrange : .clear).opacity(0.06), in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .overlay(
            RoundedRectangle(cornerRadius: Amb.radiusPanel)
                .stroke(row.unread ? Amb.brandOrange.opacity(0.8) : Amb.border, lineWidth: row.unread ? 1.5 : 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: Amb.radiusPanel))
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        var match = false
        var buffer = ""
        func append() {
            var part = AttributedString(buffer)
            if match { part.font = .body.bold(); part.backgroundColor = .yellow.opacity(0.25) }
            result += part; buffer = ""
        }
        for character in text {
            if character == "⟦" { append(); match = true }
            else if character == "⟧" { append(); match = false }
            else { buffer.append(character) }
        }
        append()
        return result
    }

    private func start() {
        let context = model.context, viewer = connection.signerNpub, query = query, filter = filter
        let workspaceId = workspace.id, connectionId = connection.id, store = store
        let identity = "\(workspaceId):\(context.encoded()):\(filter.rawValue):\(query)"
        let resume = startedIdentity == identity
        startedIdentity = identity
        snapshot.start(store: store, keepingValue: resume, invalidatedBy: [.access, .messages, .threads, .channels, .viewStates], matches: { key in
            key.workspaceId == nil || key.workspaceId == workspaceId || key.table == .profiles
        }) {
            let rows = try await store.reader.conversations(workspaceId: workspaceId, context: context, viewer: viewer, filter: filter, query: query)
            return ConversationInboxSnapshot(rows: rows, people: try await store.reader.people(connectionId: connectionId, workspaceId: workspaceId))
        }
    }
}
