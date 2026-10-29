import AmbulandoCore
import SwiftUI
import UniformTypeIdentifiers

// Deck on a phone (sol `index.html` `.deck-columns-track`, `autopilot-overview-manager.js` `DECK_MOBILE_CARDS`): full-width
// cards you swipe between, with dots below: Hello and Links, Inbox (the default), Pinned items (only with pins), Canvas,
// Feed, Recent. The chosen card and each card's scroll position are kept. Records open on top of Deck, so Back returns
// to the same card. Deck reads the sidebar's Scope | Channel context like the web's Deck.

struct DeckView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @SceneStorage("deck.card") private var storedCard = DeckCard.inbox.rawValue
    @State private var card: DeckCard?
    #if os(iOS)
    /// New thread from the floating button or the Inbox heading's +: one composer for the context Deck shows.
    @State private var composingThread = false
    @State private var createdThread: ThreadFocus?
    @State private var keyboardShown = false
    #endif

    private var cards: [DeckCard] {
        let hasPins = model.pins.value.items.contains { model.pins.value.isPinned($0.pin.resourceType, $0.pin.resourceId) }
        return DeckCard.allCases.filter { $0 != .pinned || hasPins }
    }

    var body: some View {
        #if os(macOS)
        MacDeckDashboard(workspace: workspace, store: store).navigationTitle("Deck")
        #else
        let cards = cards
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                // Not lazy: every card stays alive, so each keeps its own scroll position while you swipe.
                HStack(spacing: 0) {
                    ForEach(cards) { card in
                        page(card)
                            .containerRelativeFrame(.horizontal)
                            .id(card)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $card)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("deck.track")
            // Above the dots, so it never covers them or the section bar; hidden while the keyboard is up.
            .overlay(alignment: .bottomTrailing) {
                if !keyboardShown { DeckNewThreadButton { composingThread = true }.padding(.trailing, 16).padding(.bottom, 12) }
            }
            DeckPagination(cards: cards, selection: $card)
        }
        .navigationTitle("Deck")
        .onKeyboard(willHide: { keyboardShown = false }, didShow: { keyboardShown = true })
        .fullScreenCover(isPresented: $composingThread, onDismiss: openCreatedThread) {
            DeckThreadComposer(workspace: workspace, store: store, onCreated: { createdThread = $0 })
        }
        .onAppear {
            // Also called when a pushed record pops back to Deck: the card shown then is kept.
            guard card == nil else { return }
            let stored = DeckCard(rawValue: storedCard) ?? .inbox
            // Opened for the first time by a sidebar choice: its Inbox card, as for any later choice.
            card = cards.contains(stored) && model.deckInboxRequests == 0 ? stored : .inbox
        }
        .onChange(of: card) { _, next in if let next { storedCard = next.rawValue } }
        .onChange(of: model.deckInboxRequests) { _, _ in withAnimation(.snappy) { card = .inbox } }
        // The last pin removed while Pinned items is shown: Inbox takes its place, as on the web.
        .onChange(of: cards) { _, now in if let card, !now.contains(card) { self.card = .inbox } }
        #endif
    }

    @ViewBuilder private func page(_ card: DeckCard) -> some View {
        switch card {
        case .hello: DeckHelloCard(workspace: workspace, store: store)
        case .inbox:
            #if os(iOS)
            DeckInboxCard(workspace: workspace, store: store, active: model.mode == .deck && self.card == .inbox, onNewThread: { composingThread = true })
            #else
            DeckInboxCard(workspace: workspace, store: store, active: model.mode == .deck && self.card == .inbox)
            #endif
        case .pinned: DeckPinnedCard(workspace: workspace)
        case .canvas: DeckCanvasCard(workspace: workspace, store: store)
        case .feed: DeckFeedCard()
        case .recent: DeckRecentCard(workspace: workspace, store: store, active: model.mode == .deck && self.card == .recent)
        }
    }

    #if os(iOS)
    private func openCreatedThread() {
        if let createdThread { model.focusThread(createdThread); self.createdThread = nil }
    }
    #endif
}

#if os(iOS)
/// Deck's floating New thread button (lower right, above the page dots): starts a thread in the context Deck shows.
private struct DeckNewThreadButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Amb.primaryForeground)
                .frame(width: DeckLayout.newThreadButton, height: DeckLayout.newThreadButton)
                .background(Amb.primary, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New thread")
        .accessibilityHint("Starts a thread in the scope Deck is showing")
        .accessibilityIdentifier("deck.fab.new")
    }
}
#endif

enum DeckLayout {
    /// The floating New thread button's side.
    static let newThreadButton: CGFloat = 56
    /// Room left under each card's last row so the floating button never sits on it for good.
    #if os(iOS)
    static let cardBottomInset: CGFloat = newThreadButton + 24
    #else
    static let cardBottomInset: CGFloat = 16
    #endif
}

/// The dots under Deck (sol `.deck-mobile-pagination`). Each is a button labelled with its card.
private struct DeckPagination: View {
    let cards: [DeckCard]
    @Binding var selection: DeckCard?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(cards) { card in
                Button { withAnimation(.snappy) { selection = card } } label: {
                    Circle().fill(selection == card ? Amb.primary : Amb.muted)
                        .frame(width: 8, height: 8)
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(card.title)")
                .accessibilityAddTraits(selection == card ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier("deck.page.\(card.rawValue)")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .background(Amb.background)
    }
}

/// A card's frame: heading row and its own vertical scroll.
private struct DeckCardFrame<Actions: View, Content: View>: View {
    let title: String
    let identifier: String
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.amb(.headline)).foregroundStyle(Amb.foreground).lineLimit(1)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("deck.card.title")
                Spacer(minLength: 4)
                actions()
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.horizontal, 12).padding(.bottom, DeckLayout.cardBottomInset)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deck.card.\(identifier)")
    }
}

private struct DeckRowStyle: ViewModifier {
    var unread = false
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint ?? .clear).opacity(0.06), in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
            .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(unread ? Amb.brandOrange.opacity(0.7) : Amb.border, lineWidth: unread ? 1.2 : 0.8))
    }
}

private struct DeckNote: View {
    let text: String
    var body: some View {
        Text(text).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground).padding(.horizontal, 4).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Inbox

struct DeckInboxSnapshot: Sendable, Equatable {
    var items: [DeckActivity.Item] = []
    var viewStates: [String: ViewStateRecord] = [:]
    var channelLabels: [String: String] = [:]
}

/// Deck's Inbox: the context's activity with the web's type toggles, search, "Load older activity", Pin, Mark read,
/// Mark done (review tasks) and the read menu.
struct DeckInboxCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let workspace: WorkspaceRecord
    let store: LocalStore
    /// Deck is the current section and this card is shown. Out of sight the query pauses (keeping its rows), so a sync
    /// burst does not re-read the whole feed for a card nobody is looking at.
    let active: Bool
    /// The phone Deck's shared New thread composer; without it the card presents its own.
    var onNewThread: (() -> Void)? = nil
    @State private var snapshot = LiveQuery<DeckInboxSnapshot>(initial: DeckInboxSnapshot())
    @State private var kinds = Set(DeckActivity.Kind.allCases)
    @State private var searchDraft = ""
    @State private var query = ""
    @State private var visible = DeckInbox.pageSize
    @State private var notice: String?
    @State private var startedKey: String?
    @State private var composingThread = false
    @State private var createdThread: ThreadFocus?

    var body: some View {
        let nav = model.navigation.value
        let context = model.context
        let filtered = DeckActivity.filter(snapshot.value.items, kinds: kinds, query: query)
        let channel = nav.channel(context.channelId)
        DeckCardFrame(title: channel.map { "Inbox: #\(nav.label($0))" } ?? "Inbox", identifier: "inbox") {
            if let channel { PinButton(type: .channel, id: channel.id, title: nav.label(channel), workspace: workspace) }
            newThreadButton
            readMenu(filtered)
        } content: {
            controls
            if let notice { DeckNote(text: notice).accessibilityIdentifier("deck.inbox.notice") }
            if let error = model.syncError(forKey: WorkspaceSync.inboxKey(workspace.id)) { SyncNote(text: error, tone: .warning) }
            ForEach(filtered.prefix(visible)) { item in row(item, labels: snapshot.value.channelLabels) }
            if filtered.count > visible {
                Button("Load older activity") { visible += DeckInbox.pageSize }
                    .font(.amb(.subheadline).weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                    .accessibilityIdentifier("deck.inbox.more")
            }
            if filtered.isEmpty { DeckNote(text: emptyText).accessibilityIdentifier("deck.inbox.empty") }
        }
        .task(id: "\(workspace.id):\(context.encoded()):\(active)") { if active { start(context) } else { snapshot.pause() } }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { refresh(context) } }
        #if os(iOS)
        .fullScreenCover(isPresented: $composingThread, onDismiss: openCreatedThread) { DeckThreadComposer(workspace: workspace, store: store, onCreated: { createdThread = $0 }) }
        #endif
    }

    private var emptyText: String {
        if kinds.isEmpty { return "All record types are hidden. Turn on a type to show activity." }
        if !snapshot.loaded { return "Loading activity…" }
        if !query.isEmpty { return "No matches for “\(query)”." }
        return model.canRead ? "No activity here yet." : "No saved activity here. Unlock to load it."
    }

    /// The four type toggles and Search on one row (search flexes). At accessibility text sizes Search moves under them,
    /// so no toggle is dropped. Chosen by text size, not by measuring, so typing never moves the field.
    @ViewBuilder private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) { typeToggles; searchField }.padding(.bottom, 2)
        } else {
            HStack(spacing: 6) { typeToggles; searchField }.padding(.bottom, 2)
        }
    }

    private var typeToggles: some View {
        HStack(spacing: 6) {
            ForEach(DeckActivity.Kind.allCases, id: \.self) { kind in
                let on = kinds.contains(kind)
                Button { if on { kinds.remove(kind) } else { kinds.insert(kind) }; visible = DeckInbox.pageSize } label: {
                    Image(systemName: DeckInbox.icon(kind)).font(.amb(.subheadline))
                        .foregroundStyle(on ? Amb.selectedForeground : Amb.mutedForeground)
                        .frame(width: 38, height: 36)
                        .background(on ? Amb.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                        .overlay(RoundedRectangle(cornerRadius: Amb.radiusControl).stroke(Amb.border, lineWidth: 0.8))
                        .frame(minWidth: Amb.touchTarget, minHeight: Amb.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(DeckInbox.toggleLabel(kind))
                .accessibilityValue(on ? "Shown" : "Hidden")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("deck.inbox.type.\(kind.rawValue)")
            }
        }
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Amb.mutedForeground).accessibilityHidden(true)
            TextField("Search", text: $searchDraft)
                .submitLabel(.search)
                .onSubmit { query = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines); visible = DeckInbox.pageSize }
                .onChange(of: searchDraft) { _, text in if text.isEmpty { query = ""; visible = DeckInbox.pageSize } }
                .accessibilityLabel("Search Inbox")
                .accessibilityIdentifier("deck.inbox.search")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
        .overlay(RoundedRectangle(cornerRadius: Amb.radiusControl).stroke(Amb.border, lineWidth: 0.8))
        .frame(minHeight: Amb.touchTarget)
    }

    private func openCreatedThread() {
        if let createdThread { model.focusThread(createdThread); self.createdThread = nil }
    }

    private var newThreadButton: some View {
        Button {
            if let onNewThread { onNewThread(); return }
            #if os(macOS)
            model.composingThread = true
            #else
            composingThread = true
            #endif
        } label: {
            Image(systemName: "plus").font(.amb(.body).weight(.semibold)).frame(width: 30, height: 30)
        }
        .accessibilityLabel("New thread")
        .accessibilityIdentifier("deck.inbox.new")
    }

    private func readMenu(_ items: [DeckActivity.Item]) -> some View {
        Menu {
            Button("Mark all tasks as read") { markAll(items, [.task], label: "tasks") }
            Button("Mark all docs as read") { markAll(items, [.document], label: "docs") }
            Button("Mark all chats as read") { markAll(items, [.chat], label: "chats") }
            Button("Mark everything as read") { markAll(items, [.chat, .task, .document], label: "Inbox items") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.amb(.body)).frame(width: 30, height: 30)
        }
        // On the Mac a bare Menu is a pop-up button that stretched across the card's header; it is one small icon.
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Inbox read actions")
        .accessibilityIdentifier("deck.inbox.readMenu")
    }

    @ViewBuilder private func row(_ item: DeckActivity.Item, labels: [String: String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ThreadRouteLink(route: route(item)) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: DeckInbox.icon(item.kind)).font(.amb(.subheadline)).foregroundStyle(DeckInbox.tint(item.kind))
                        .frame(width: 28, height: 28)
                        .background(DeckInbox.tint(item.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(kicker(item, labels)).font(.amb(.caption).weight(.semibold)).foregroundStyle(DeckInbox.tint(item.kind)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ChatTime.label(item.activityAt)).font(.amb(.caption2)).foregroundStyle(Amb.mutedForeground)
                        }
                        Text(item.title).font(.amb(.subheadline).weight(item.isUnread ? .semibold : .regular)).foregroundStyle(Amb.foreground)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Text(item.kind == .chat ? item.subtitle : item.reason).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                        if item.isWorking { Label("Agent working", systemImage: "sparkles").font(.amb(.caption2)).foregroundStyle(Amb.primary) }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(kicker(item, labels)): \(item.title)\(item.isUnread ? ", unread" : "")")
            .accessibilityIdentifier("deck.inbox.item")
            VStack(spacing: 4) {
                if let type = pinType(item) { PinButton(type: type, id: item.recordId, title: item.title, workspace: workspace) }
                if item.kind == .task, item.taskState == TaskState.review.rawValue, item.isUnread {
                    Button { markDone(item) } label: { Image(systemName: "checkmark.square").frame(width: 28, height: 26) }
                        .buttonStyle(.plain).foregroundStyle(Amb.success)
                        .accessibilityLabel("Mark done").accessibilityIdentifier("deck.inbox.done")
                }
                if item.isUnread, let state = viewState(item) {
                    Button { model.markRead([state], in: workspace) } label: { Image(systemName: "envelope.open").frame(width: 28, height: 26) }
                        .buttonStyle(.plain).foregroundStyle(Amb.info)
                        .accessibilityLabel("Mark read").accessibilityIdentifier("deck.inbox.read")
                }
            }
        }
        .modifier(DeckRowStyle(unread: item.isUnread, tint: DeckInbox.tint(item.kind)))
    }

    private func kicker(_ item: DeckActivity.Item, _ labels: [String: String]) -> String {
        let channel = item.channelId.flatMap { labels[$0] }.map { "#\($0)" }
        switch item.kind {
        case .chat: return ["Chat", channel].compactMap { $0 }.joined(separator: " · ")
        case .task: return "Task · \(item.subtitle)"
        case .document: return "Document"
        case .file: return ["File", channel].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func route(_ item: DeckActivity.Item) -> WorkRoute {
        let w = workspace.id
        switch item.kind {
        case .chat:
            if item.isThread, let channel = item.channelId { return .thread(workspaceId: w, channelId: channel, threadId: item.recordId) }
            return .channel(workspaceId: w, channelId: item.channelId ?? item.recordId)
        case .task: return .task(workspaceId: w, taskId: item.recordId)
        case .document: return .doc(workspaceId: w, docId: item.recordId)
        case .file: return .file(workspaceId: w, fileId: item.recordId)
        }
    }

    private func pinType(_ item: DeckActivity.Item) -> PinRecord.ResourceType? {
        switch item.kind {
        case .chat: item.isThread ? .thread : nil
        case .task: .task
        case .document: .document
        case .file: nil
        }
    }

    private func viewState(_ item: DeckActivity.Item) -> ViewStateRecord? {
        let type: ViewStateRecord.ResourceType? = switch item.kind {
        case .chat: .thread
        case .task: .task
        case .document: .document
        case .file: nil
        }
        return type.flatMap { snapshot.value.viewStates["\($0.rawValue):\(item.recordId)"] }
    }

    private func markAll(_ items: [DeckActivity.Item], _ kinds: Set<DeckActivity.Kind>, label: String) {
        let states = items.filter { kinds.contains($0.kind) && $0.isUnread }.compactMap(viewState)
        guard !states.isEmpty else { notice = "No unread \(label) here."; return }
        model.markRead(states, in: workspace)
        notice = "Marked \(states.count) \(label) as read."
    }

    /// Mark done on a review task (as the web Deck): its state changes and it is marked read.
    private func markDone(_ item: DeckActivity.Item) {
        model.submit(WriteIntent(kind: .taskState, targetId: item.recordId, payload: ["state": TaskState.done.rawValue]), in: workspace)
        if let state = viewState(item) { model.markRead([state], in: workspace) }
    }

    private func refresh(_ context: WorkContext) {
        model.openInbox(workspace)
        model.openTasks(workspace, scopeId: context.scopeId)
        model.openDocs(workspace, scopeId: context.scopeId)
        model.openFiles(workspace, scopeId: context.scopeId)
    }

    private func start(_ context: WorkContext) {
        // A new context starts a fresh list with no search, as the web Deck does. Coming back from a record opened here
        // (the task restarts when Deck reappears) keeps the search and how far the list was revealed.
        let key = "\(workspace.id):\(context.encoded())"
        let resuming = startedKey == key
        if !resuming {
            startedKey = key
            visible = DeckInbox.pageSize; searchDraft = ""; query = ""; notice = nil
        }
        let w = workspace.id, store = store, viewer = model.connection?.signerNpub
        let channelIds = context.scopeId == nil ? nil : model.navigation.value.channels(in: context).map(\.id)
        snapshot.start(store: store, keepingValue: resuming, matches: { key in
            key.workspaceId == w && [.threads, .messages, .tasks, .docs, .files, .viewStates, .comments, .channels, .agents].contains(key.table)
        }) {
            var sources = DeckActivity.Sources()
            async let channels = store.reader.channels(workspaceId: w)
            async let threads = store.reader.deckThreads(workspaceId: w, channelIds: channelIds)
            async let tasks = store.reader.tasks(workspaceId: w, scopeId: context.scopeId, channelId: context.channelId)
            async let docs = store.reader.docs(workspaceId: w, scopeId: context.scopeId)
            async let files = store.reader.files(workspaceId: w, channelId: context.channelId)
            async let states = store.reader.viewStates(workspaceId: w)
            async let taskComments = store.reader.deckCommentActivity(workspaceId: w, parent: .task, viewerNpub: viewer)
            async let docComments = store.reader.deckCommentActivity(workspaceId: w, parent: .doc, viewerNpub: viewer)
            async let activities = store.reader.agentActivities(workspaceId: w, channelIds: channelIds)
            let channelRows = try await channels
            sources.channelScopes = Dictionary(channelRows.map { ($0.id, $0.scopeId) }, uniquingKeysWith: { a, _ in a })
            sources.threads = try await threads
            sources.tasks = try await tasks
            sources.docs = try await docs
            sources.files = try await files
            sources.viewStates = try await states
            sources.taskComments = try await taskComments
            sources.docComments = try await docComments
            sources.activities = try await activities
            return DeckInboxSnapshot(items: DeckActivity.inbox(sources, context: context),
                                     viewStates: Dictionary(sources.viewStates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                                     channelLabels: Dictionary(channelRows.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        }
        if !resuming { refresh(context) }
    }
}

enum DeckInbox {
    /// Cards revealed per "Load older activity" (sol `DECK_INBOX_PAGE_SIZE`).
    static let pageSize = 50

    static func icon(_ kind: DeckActivity.Kind) -> String {
        switch kind {
        case .chat: "bubble.left.and.bubble.right"
        case .task: "checklist"
        case .document: "doc.text"
        case .file: "paperclip"
        }
    }

    /// A quiet colour per record type, so chats, tasks, documents and files can be told apart at a glance.
    static func tint(_ kind: DeckActivity.Kind) -> Color {
        switch kind {
        case .chat: Amb.info
        case .task: Amb.warning
        case .document: Amb.success
        case .file: Amb.mutedForeground
        }
    }

    static func toggleLabel(_ kind: DeckActivity.Kind) -> String {
        switch kind {
        case .chat: "Show chats"
        case .task: "Show tasks"
        case .document: "Show documents"
        case .file: "Show files"
        }
    }
}

/// Pin or unpin from a Deck row (the latest intent shows while the write is queued).
private struct PinButton: View {
    @Environment(AppModel.self) private var model
    let type: PinRecord.ResourceType
    let id: String
    let title: String
    let workspace: WorkspaceRecord

    var body: some View {
        let pinned = model.pins.value.isPinned(type, id)
        Button { model.setPinned(!pinned, type: type, id: id, in: workspace) } label: {
            Image(systemName: pinned ? "pin.fill" : "pin").frame(width: 28, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(pinned ? Amb.primary : Amb.mutedForeground)
        .accessibilityLabel(pinned ? "Unpin \(title)" : "Pin \(title)")
        .accessibilityIdentifier("deck.pin")
    }
}

// MARK: Pinned items

/// The member's pins in Tower's order (sol `pinned-threads.js`). Channels open in Chat; conversations, tasks and
/// documents open on top of Deck.
struct DeckPinnedCard: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    @State private var draggedPin: (item: PinnedItem, token: String)?
    var body: some View {
        let snapshot = model.pins.value
        let items = snapshot.items.filter { snapshot.isPinned($0.pin.resourceType, $0.pin.resourceId) }
        DeckCardFrame(title: "Pinned items", identifier: "pinned") { EmptyView() } content: {
            ForEach(items) { item in
                pinRow(item, items: items, snapshot: snapshot)
            }
            if let write = snapshot.orderWrite, let error = write.lastError {
                HStack {
                    Text(error).font(.amb(.caption))
                    if !write.isPending, let store = model.store {
                        Button("Discard move") { Task { try? await store.writer.discardWrite(id: write.id) } }
                    }
                }
            }
        }
    }

    private func pinRow(_ item: PinnedItem, items: [PinnedItem], snapshot: PinsSnapshot) -> some View {
        HStack(spacing: 8) {
            pinAction(item, items: items, snapshot: snapshot)
            Button { model.setPinned(false, type: item.pin.resourceType, id: item.pin.resourceId, in: workspace) } label: {
                Image(systemName: "pin.slash").frame(width: 28, height: 26)
            }
            .buttonStyle(.plain).foregroundStyle(Amb.mutedForeground)
            .accessibilityLabel("Unpin \(item.title ?? label(item.pin.resourceType))")
        }
        .modifier(DeckRowStyle())
        .modifier(PinInsertionTarget(enabled: draggedPin != nil) { providers, after in
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return false }
            let anchor = after ? (index + 1 < items.count ? items[index + 1] : nil) : item
            return drop(providers, before: anchor)
        })
    }

    private func pinAction(_ item: PinnedItem, items: [PinnedItem], snapshot: PinsSnapshot) -> some View {
        let action = open(item) { pinLabel(item, snapshot: snapshot) }
        .onDrag {
            let token = UUID().uuidString
            draggedPin = (item, token)
            #if DEBUG
            if model.fixture != nil { NSLog("PIN_DRAG main action started") }
            #endif
            return NSItemProvider(object: token as NSString)
        }
        return action
        .accessibilityAction(named: "Move up") { move(item, by: -1, in: items) }
        .accessibilityAction(named: "Move down") { move(item, by: 1, in: items) }
        .accessibilityAction(named: "Move to end") { model.movePin(item, before: nil, in: workspace) }
        .onKeyPress(keys: [.upArrow], phases: .down) { press in
            guard press.modifiers.contains([.command, .option]) else { return .ignored }
            move(item, by: -1, in: items)
            return .handled
        }
        .onKeyPress(keys: [.downArrow], phases: .down) { press in
            guard press.modifiers.contains([.command, .option]) else { return .ignored }
            move(item, by: 1, in: items)
            return .handled
        }
        .accessibilityLabel("\(label(item.pin.resourceType)): \(item.title ?? unavailable(item.pin.resourceType))")
        .accessibilityIdentifier("deck.pinned.\(item.title ?? item.pin.resourceId)")
    }

    private func pinLabel(_ item: PinnedItem, snapshot: PinsSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(item.pin.resourceType)).foregroundStyle(Amb.mutedForeground).frame(width: 20)
            Text(item.title ?? unavailable(item.pin.resourceType))
                .font(.amb(.subheadline)).foregroundStyle(item.title == nil ? Amb.mutedForeground : Amb.foreground).lineLimit(2)
            Spacer(minLength: 0)
            if snapshot.pending[PinsSnapshot.key(item.pin.resourceType, item.pin.resourceId)]?.isPending == true {
                ProgressView().controlSize(.mini).accessibilityLabel("Saving pin")
            }
        }
        .contentShape(Rectangle())
    }

    private func drop(_ providers: [NSItemProvider], before anchor: PinnedItem?) -> Bool {
        #if DEBUG
        if model.fixture != nil { NSLog("PIN_DRAG drop received") }
        #endif
        guard let drag = draggedPin, let provider = providers.first, drag.item.id != anchor?.id else { return false }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            let token = value as? String
            Task { @MainActor in
                guard token == drag.token, draggedPin?.token == drag.token else { return }
                draggedPin = nil
                guard model.pins.value.items.contains(where: { $0.pin == drag.item.pin }),
                      model.pins.value.isPinned(drag.item.pin.resourceType, drag.item.pin.resourceId) else { return }
                model.movePin(drag.item, before: anchor, in: workspace)
            }
        }
        return true
    }

    private func move(_ item: PinnedItem, by step: Int, in items: [PinnedItem]) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let destination = index + step
        guard items.indices.contains(destination) else { return }
        let before = step < 0 ? items[destination] : (destination + 1 < items.count ? items[destination + 1] : nil)
        model.movePin(item, before: before, in: workspace)
    }

    @ViewBuilder private func open<Label: View>(_ item: PinnedItem, @ViewBuilder label: () -> Label) -> some View {
        let w = workspace.id, id = item.pin.resourceId
        switch item.pin.resourceType {
        case .channel: Button { model.openInChat(channelId: id) } label: { label() }.buttonStyle(.plain)
        case .thread: ThreadRouteLink(route: WorkRoute.threadById(workspaceId: w, threadId: id)) { label() }.buttonStyle(.plain)
        case .task: NavigationLink(value: WorkRoute.task(workspaceId: w, taskId: id)) { label() }.buttonStyle(.plain)
        case .document: NavigationLink(value: WorkRoute.doc(workspaceId: w, docId: id)) { label() }.buttonStyle(.plain)
        }
    }

    private func icon(_ type: PinRecord.ResourceType) -> String {
        switch type {
        case .thread: "bubble.left"
        case .task: "checklist"
        case .document: "doc.text"
        case .channel: "number"
        }
    }

    private func label(_ type: PinRecord.ResourceType) -> String {
        switch type {
        case .thread: "Thread"
        case .task: "Task"
        case .document: "Document"
        case .channel: "Channel"
        }
    }

    private func unavailable(_ type: PinRecord.ResourceType) -> String {
        switch type {
        case .thread: "Conversation not on this \(Device.name)"
        case .task: "Task not on this \(Device.name)"
        case .document: "Document not on this \(Device.name)"
        case .channel: "Channel not available"
        }
    }
}

/// Drop on a row's upper/lower half to insert before/after it, including after the last row.
/// Feedback follows native drag enter/exit, so cancelling leaves no idle target behind.
private struct PinInsertionTarget: ViewModifier {
    let enabled: Bool
    let drop: ([NSItemProvider], Bool) -> Bool
    @State private var height: CGFloat = 44
    @State private var after: Bool?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay(alignment: after == true ? .bottom : .top) {
                if after != nil {
                    Capsule().fill(Amb.primary.opacity(0.6)).frame(height: 2).allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.text.identifier], delegate: InsertionDelegate(
                enabled: enabled, height: height, after: $after, drop: drop))
    }

    private struct InsertionDelegate: DropDelegate {
        let enabled: Bool
        let height: CGFloat
        @Binding var after: Bool?
        let drop: ([NSItemProvider], Bool) -> Bool

        func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [UTType.text.identifier]) }
        func dropEntered(info: DropInfo) { after = info.location.y >= height / 2 }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            after = info.location.y >= height / 2
            return DropProposal(operation: .move)
        }
        func dropExited(info: DropInfo) { after = nil }
        func performDrop(info: DropInfo) -> Bool {
            let lowerHalf = info.location.y >= height / 2
            after = nil
            return drop(info.itemProviders(for: [UTType.text.identifier]), lowerHalf)
        }
    }
}

// MARK: Canvas

/// Canvases shared with the member (sol Deck "Canvas" card). A board opens on top of Deck with Back; its pan and zoom are
/// kept for when you return.
struct DeckCanvasCard: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var canvases = LiveQuery<[CanvasRecord]>(initial: [])

    var body: some View {
        let key = WorkspaceSync.canvasesKey(workspace.id)
        DeckCardFrame(title: "Canvas", identifier: "canvas") { NewCanvasButton(workspace: workspace) } content: {
            if canvases.loaded && canvases.value.isEmpty {
                if let error = model.syncError(forKey: key) { SyncNote(text: error, tone: .warning) }
                else if model.isSyncing(key) { DeckNote(text: "Loading canvases…") }
                else { DeckNote(text: model.canRead ? "No canvases yet." : "Unlock to load canvases.") }
            }
            ForEach(canvases.value) { canvas in
                CanvasRouteLink(workspaceId: workspace.id, canvasId: canvas.id) {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.3.group").foregroundStyle(Amb.primary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(canvas.title).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(2)
                            Text(canvas.visibilityMode == "workspace" ? "Everyone in the workspace" : "Shared with selected people")
                                .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                        }
                        Spacer(minLength: 0)
                        if !canvas.updatedAt.isEmpty { Text(ChatTime.label(canvas.updatedAt)).font(.amb(.caption2)).foregroundStyle(Amb.mutedForeground) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(DeckRowStyle())
                .accessibilityIdentifier("canvas.\(canvas.title)")
            }
            DeckNote(text: "Create a canvas with +. Sharing settings are changed in the web app.")
        }
        .refreshable { model.openCanvases(workspace, force: true) }
        .task {
            let w = workspace.id, store = store
            canvases.start(store: store, matches: { $0.workspaceId == w && $0.table == .canvases }) { try await store.reader.canvases(workspaceId: w) }
            model.openCanvases(workspace)
        }
    }
}

// MARK: Feed

/// The web Deck's Feed card (RSS and Nostr notifications) has no native reader yet; the card says so instead of
/// disappearing.
struct DeckFeedCard: View {
    var body: some View {
        DeckCardFrame(title: "Feed", identifier: "feed") { EmptyView() } content: {
            VStack(alignment: .leading, spacing: 8) {
                Label("Feeds are in the web app", systemImage: "dot.radiowaves.up.forward").font(.amb(.subheadline).weight(.semibold))
                    .foregroundStyle(Amb.foreground)
                Text("Subscribed feeds (RSS) and Nostr notifications are read and managed in the web app's Deck. This \(Device.name) app doesn't show them yet.")
                    .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            }
            .modifier(DeckRowStyle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("deck.feed.notice")
        }
    }
}

// MARK: Recent

/// Each channel's newest conversation in the scope (the channel choice is ignored, as on the web). Opening one makes the
/// channel the context and opens the conversation in Chat.
struct DeckRecentCard: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    /// As for the Inbox card: paused (rows kept) while out of sight.
    let active: Bool
    @State private var rows = LiveQuery<[DeckActivity.ThreadActivity]>(initial: [])
    @State private var startedKey: String?

    var body: some View {
        let nav = model.navigation.value
        DeckCardFrame(title: "Recent channels", identifier: "recent") {
            Text("Latest activity").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
        } content: {
            ForEach(rows.value, id: \.channelId) { thread in
                let label = nav.channel(thread.channelId).map(nav.label) ?? "channel"
                Button { model.openInChat(channelId: thread.channelId, threadId: thread.isThread ? thread.threadId : nil) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("# \(label)").font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ChatTime.label(thread.latestAt)).font(.amb(.caption2)).foregroundStyle(Amb.mutedForeground)
                        }
                        Text(DeckActivity.threadTitle(thread)).font(.amb(.footnote)).foregroundStyle(Amb.foreground).lineLimit(1)
                        Text(MentionCodec.plain(thread.latestBody)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(DeckRowStyle())
                .accessibilityLabel("Open \(label) in Chat at \(DeckActivity.threadTitle(thread))")
                .accessibilityIdentifier("deck.recent.\(label)")
            }
            if rows.loaded && rows.value.isEmpty { DeckNote(text: "No recent channel activity.") }
        }
        .task(id: "\(workspace.id):\(model.context.scopeId ?? "all"):\(active)") {
            guard active else { rows.pause(); return }
            let w = workspace.id, store = store, scope = model.context.scopeId
            let key = "\(w):\(scope ?? "all")", resuming = startedKey == key
            startedKey = key
            rows.start(store: store, keepingValue: resuming, matches: { $0.workspaceId == w && [.messages, .threads, .channels].contains($0.table) }) {
                let channels = try await store.reader.channels(workspaceId: w)
                let scopes = Dictionary(channels.map { ($0.id, $0.scopeId) }, uniquingKeysWith: { a, _ in a })
                let ids = scope.map { s in channels.filter { $0.scopeId == s }.map(\.id) }
                return DeckActivity.recentChannels(try await store.reader.deckThreads(workspaceId: w, channelIds: ids), scopeId: scope, channelScopes: scopes)
            }
        }
    }
}

// MARK: Hello and Links

/// Greeting, the current context and the member's WApps (sol `.deck-hello-card`, personal launchers), which open as
/// in-app browser tabs.
struct DeckHelloCard: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var name = LiveQuery<String?>(initial: nil)
    @State private var wapps = LiveQuery<[PersonalWappRecord]>(initial: [])

    var body: some View {
        let nav = model.navigation.value
        DeckCardFrame(title: "Hello and Links", identifier: "hello") { EmptyView() } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.amb(.title3).weight(.semibold)).foregroundStyle(Amb.foreground)
                Text(contextLabel(nav)).font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground)
            }
            .padding(.horizontal, 4).padding(.bottom, 6)
            Text("Apps").font(.amb(.footnote).weight(.heavy)).foregroundStyle(Amb.mutedForeground).padding(.horizontal, 4)
            ForEach(wapps.value) { wapp in
                // A browser tab over Deck (signing through `window.nostr`); **Ambulando** returns to this card.
                if let url = wapp.safeLaunchURL {
                    Button { model.browser.launch(url) } label: {
                        AppLauncherCard(title: wapp.title, subtitle: wapp.description ?? "WApp", sources: wapp.logoCandidates, workspace: workspace)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(wapp.title), \(wapp.description ?? "WApp")")
                    .accessibilityHint("Opens in the browser")
                    .accessibilityIdentifier("deck.app.\(wapp.title)")
                }
            }
            if wapps.loaded && wapps.value.isEmpty { DeckNote(text: "WApps you add in the web app appear here and in Toolbox.") }
        }
        .task {
            let w = workspace.id, store = store, connection = model.connection?.id ?? "", me = model.connection?.signerNpub
            wapps.start(store: store, matches: { $0.workspaceId == w && $0.table == .toolbox }) { try await store.reader.personalWapps(connectionId: connection, workspaceId: w) }
            name.start(store: store, matches: { $0.workspaceId == w && $0.table == .members }) {
                try await store.reader.members(workspaceId: w).first { $0.npub == me }?.label
            }
            model.openToolbox(workspace)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return "\(part), \(name.value ?? model.connection.map { shortNpub($0.signerNpub) } ?? "there")"
    }

    private func contextLabel(_ nav: NavigationSnapshot) -> String {
        guard let scope = nav.scope(model.context.scopeId) else { return "All workspace activity" }
        if let channel = nav.channel(model.context.channelId) { return "\(scope.name) / \(nav.label(channel))" }
        return scope.name
    }
}

/// An app as a card with its logo, title and description (the web's launcher pill), as on the desktop Deck.
struct AppLauncherCard: View {
    let title: String
    let subtitle: String
    let sources: [LauncherLogoSource]
    let workspace: WorkspaceRecord

    var body: some View {
        HStack(spacing: 12) {
            LauncherLogoView(sources: sources, initials: PersonInitials.of(title), workspace: workspace, size: 44)
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(Circle().stroke(Amb.border, lineWidth: 2))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.amb(.subheadline).weight(.bold)).foregroundStyle(Amb.itemHeading).lineLimit(1)
                Text(subtitle).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).lineLimit(2).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.amb(.caption).weight(.semibold)).foregroundStyle(Amb.mutedForeground)
        }
        .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(Amb.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: Amb.radiusPanel))
    }
}

#if os(macOS)
/// Desktop Deck keeps the web's regions visible together. Every card retains its native store query and actions.
private struct MacDeckDashboard: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 850 {
                VStack(spacing: 16) {
                    MacDeckWelcome(workspace: workspace, store: store, compact: false).frame(height: 170)
                    HSplitView {
                        DeckInboxCard(workspace: workspace, store: store, active: model.mode == .deck)
                            .desktopDeckPanel().frame(minWidth: 400, maxWidth: .infinity)
                        VStack(spacing: 16) {
                            DeckPinnedCard(workspace: workspace).desktopDeckPanel()
                            DeckCanvasCard(workspace: workspace, store: store).desktopDeckPanel()
                        }.frame(minWidth: 280, idealWidth: 360, maxWidth: 500)
                    }
                }.padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        MacDeckWelcome(workspace: workspace, store: store, compact: true).frame(height: 260)
                        DeckInboxCard(workspace: workspace, store: store, active: model.mode == .deck).desktopDeckPanel().frame(height: 440)
                        DeckPinnedCard(workspace: workspace).desktopDeckPanel().frame(height: 250)
                        DeckCanvasCard(workspace: workspace, store: store).desktopDeckPanel().frame(height: 280)
                    }.padding(12)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deck.desktop")
    }
}

private extension View {
    /// The web's Deck columns are open surfaces (no outer box or shadow); only their cards are bordered.
    func desktopDeckPanel() -> some View {
        background(Amb.card)
    }
}

private struct MacDeckLaunchers: Equatable, Sendable {
    var name: String?
    var apps: [PersonalWappRecord] = []
    var agents: [PersonalAgentLauncher] = []
    var people = PeopleDirectory()
}

private struct MacDeckWelcome: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    let compact: Bool
    @State private var snapshot = LiveQuery<MacDeckLaunchers>(initial: MacDeckLaunchers())
    /// The one launcher stack shown expanded ("apps" or "agents"); opening one closes the other, as on the web.
    @State private var expanded: String?

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 12) { welcome; HStack(alignment: .top, spacing: 12) { apps; agents } }
            } else {
                HStack(alignment: .top, spacing: 20) { welcome.frame(maxWidth: .infinity, alignment: .leading); apps; agents }
            }
        }
        .task(id: workspace.id) { start() }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome \(snapshot.value.name ?? "back"),\nwhere will we focus today?")
                .font(.amb(.title2).weight(.bold)).foregroundStyle(Amb.foreground)
            let nav = model.navigation.value
            Text([workspace.label, nav.scope(model.context.scopeId)?.name, nav.channel(model.context.channelId).map(nav.label)].compactMap { $0 }.joined(separator: " / "))
                .font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground)
        }.accessibilityIdentifier("deck.welcome")
    }
    private var apps: some View {
        let items = snapshot.value.apps.compactMap { app -> MacLauncherItem? in
            guard let url = app.safeLaunchURL else { return nil }
            return MacLauncherItem(id: app.id, title: app.title, subtitle: app.description ?? "WApp", url: url,
                                   logo: .app(app.logoCandidates, initials: PersonInitials.of(app.title)), identifier: "deck.app.\(app.title)")
        }
        return launcherPanel("Apps") {
            if !items.isEmpty {
                MacLauncherStack(kind: "apps", noun: "apps", items: items, workspace: workspace, expanded: $expanded) {
                    // As on the web: the expanded list ends with the way to choose apps.
                    Button { model.show(.toolbox) } label: { MacLauncherAddPill(title: "Manage apps in Toolbox") }
                        .buttonStyle(.plain).accessibilityIdentifier("deck.apps.manage")
                }
            } else if snapshot.loaded {
                Button { model.show(.toolbox) } label: { MacLauncherAddPill(title: "Choose apps in Toolbox") }
                    .buttonStyle(.plain).accessibilityIdentifier("deck.apps.choose")
            }
        }
    }
    private var agents: some View {
        let people = snapshot.value.people
        let items = snapshot.value.agents.map { agent in
            MacLauncherItem(id: agent.npub, title: people.name(agent.npub),
                            subtitle: agent.safeURL == nil ? "Secure launch URL unavailable" : "Dive deeper in Autopilot",
                            url: agent.safeURL, logo: .person(people.person(agent.npub)), identifier: "deck.agent.\(agent.npub)")
        }
        return launcherPanel("My Agents") {
            if !items.isEmpty {
                MacLauncherStack(kind: "agents", noun: "agents", items: items, workspace: workspace, expanded: $expanded) { EmptyView() }
            } else if snapshot.loaded {
                let error = model.syncError(forKey: WorkspaceSync.personalAgentsKey(model.connection?.id ?? "", workspace.id))
                DeckNote(text: error == nil ? "No personal agents configured." : "Could not load personal agents.")
                if error != nil {
                    Button("Retry") {
                        if let sync = model.sync, let connection = model.connection { Task { await sync.refreshPersonalAgentLaunchers(connection, workspace, force: true) } }
                    }.accessibilityIdentifier("deck.agents.retry")
                }
            }
        }
    }
    private func launcherPanel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.amb(.caption).weight(.bold)).foregroundStyle(Amb.mutedForeground)
            content()
        }.frame(maxWidth: compact ? .infinity : 260, maxHeight: .infinity, alignment: .topLeading)
    }
    private func start() {
        let w = workspace.id, store = store, connection = model.connection?.id ?? "", me = model.connection?.signerNpub
        let key = WorkspaceSync.personalAgentsKey(connection, w)
        snapshot.start(store: store, matches: { $0.table == .appState || ($0.workspaceId == w && [.toolbox, .members, .agents].contains($0.table)) || $0.table == .profiles }) {
            async let apps = store.reader.personalWapps(connectionId: connection, workspaceId: w)
            async let members = store.reader.members(workspaceId: w)
            let saved = try await store.reader.state(key)
            let agents = saved.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([PersonalAgentLauncher].self, from: $0) } ?? []
            let people = try await store.reader.people(workspaceId: w)
            return MacDeckLaunchers(name: try await members.first { $0.npub == me }?.label, apps: try await apps, agents: agents, people: people)
        }
        model.openToolbox(workspace)
        if let sync = model.sync, let connection = model.connection { Task { await sync.refreshPersonalAgentLaunchers(connection, workspace) } }
    }
}

private struct MacLauncherItem: Identifiable {
    enum Logo { case app([LauncherLogoSource], initials: String), person(PersonDisplay) }
    let id: String
    let title: String
    let subtitle: String
    let url: URL?
    let logo: Logo
    let identifier: String
}

/// sol `.launcher-stack-panel`: collapsed, only the first launcher is a real card, with up to two card edges behind
/// it when there are more. Clicking the stack expands every launcher as a list (a popover over the Deck, so the
/// dashboard layout does not move; click outside or Escape closes it). A single launcher opens directly.
private struct MacLauncherStack<Footer: View>: View {
    @Environment(AppModel.self) private var model
    let kind: String
    let noun: String
    let items: [MacLauncherItem]
    let workspace: WorkspaceRecord
    @Binding var expanded: String?
    @ViewBuilder let footer: () -> Footer

    static var layerOffset: CGFloat { 7.5 }  // sol 0.48rem per ghost layer

    var body: some View {
        let first = items[0]
        let layers = min(2, items.count - 1)
        let open = Binding(get: { expanded == kind }, set: { expanded = $0 ? kind : (expanded == kind ? nil : expanded) })
        Button {
            if items.count == 1 { launch(first) } else { expanded = kind }
        } label: {
            MacLauncherPill(item: first, workspace: workspace)
                .background(alignment: .top) {
                    ZStack(alignment: .top) {
                        ForEach((0..<layers).reversed(), id: \.self) { layer in
                            RoundedRectangle(cornerRadius: Amb.radiusPanel)
                                .fill(Amb.card)
                                .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(Amb.border, lineWidth: 1))
                                .shadow(color: .black.opacity(0.06), radius: 9, y: 8)
                                .opacity(layer == 1 ? 0.9 : 1)
                                .offset(y: Self.layerOffset * CGFloat(layer + 1))
                        }
                    }
                }
                .padding(.bottom, Self.layerOffset * CGFloat(layers))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(items.count == 1 && first.url == nil)
        .help(items.count == 1 ? first.title : "Show all \(items.count) \(noun)")
        .accessibilityLabel(items.count == 1 ? "\(first.title), \(first.subtitle)" : "\(first.title) and \(items.count - 1) more \(noun)")
        .accessibilityHint(items.count == 1 ? "Opens in the browser" : "Shows every launcher")
        .accessibilityIdentifier(items.count == 1 ? first.identifier : "deck.\(kind).stack")
        .popover(isPresented: open, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        Button { launch(item) } label: { MacLauncherPill(item: item, workspace: workspace) }
                            .buttonStyle(.plain)
                            .disabled(item.url == nil)
                            .opacity(item.url == nil ? 0.58 : 1)
                            .accessibilityIdentifier(item.identifier)
                    }
                    footer()
                }.padding(12)
            }
            .frame(width: 300).frame(maxHeight: 440).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("deck.\(kind).expanded")
        }
    }

    private func launch(_ item: MacLauncherItem) {
        expanded = nil
        if let url = item.url { model.browser.launch(url) }
    }
}

/// sol `.launcher-pill`: logo ring, title and one line of detail.
private struct MacLauncherPill: View {
    let item: MacLauncherItem
    let workspace: WorkspaceRecord
    var body: some View {
        HStack(spacing: 11) {
            Group {
                switch item.logo {
                case .app(let sources, let initials): LauncherLogoView(sources: sources, initials: initials, workspace: workspace)
                case .person(let person): PersonAvatar(person: person, size: 38)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            .overlay(Circle().stroke(Amb.border, lineWidth: 2))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.amb(.subheadline).weight(.bold)).foregroundStyle(Amb.itemHeading).lineLimit(1)
                Text(item.subtitle).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8).padding(.trailing, 11).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(Amb.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: Amb.radiusPanel))
    }
}

private struct MacLauncherAddPill: View {
    let title: String
    var body: some View {
        Label(title, systemImage: "plus").font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.mutedForeground)
            .frame(maxWidth: .infinity, minHeight: 40)
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(Amb.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(RoundedRectangle(cornerRadius: Amb.radiusPanel))
    }
}
#endif

/// Deck keeps its context and position underneath; routing happens inside the composer.
struct DeckThreadComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceRecord
    let store: LocalStore
    /// Mac: the modal's expand / restore state (the composer fills the window when expanded).
    var expanded: Binding<Bool>? = nil
    let onCreated: (ThreadFocus) -> Void
    @State private var channelId: String?
    @State private var choosingChannel = false
    @State private var requestId: String?
    @State private var openedRequestId: String?
    /// The Deck context the channel choice was made in (a scope change while open asks again).
    @State private var openedContext: WorkContext?
    @State private var sent = LiveQuery<MessageRecord?>(initial: nil)
    @State private var pending = LiveQuery<OutboxItem?>(initial: nil)

    private func close() {
        #if os(macOS)
        model.composingThread = false
        #else
        dismiss()
        #endif
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.pencil").foregroundStyle(Amb.mutedForeground).accessibilityHidden(true)
                Text("New thread").font(.amb(.headline)).foregroundStyle(Amb.foreground).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let expanded {
                    Button { expanded.wrappedValue.toggle() } label: {
                        Image(systemName: expanded.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.amb(.body).weight(.semibold)).frame(width: Amb.touchTarget, height: Amb.touchTarget).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Amb.mutedForeground)
                    .help(expanded.wrappedValue ? "Restore size" : "Full screen")
                    .accessibilityLabel(expanded.wrappedValue ? "Restore size" : "Expand to full screen")
                    .accessibilityIdentifier("deck.compose.expand")
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.amb(.body).weight(.semibold)).frame(width: Amb.touchTarget, height: Amb.touchTarget).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Amb.foreground)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
                .accessibilityLabel(requestId == nil ? "Cancel" : "Close")
                .accessibilityIdentifier("deck.compose.cancel")
            }
            .padding(.leading, 18).padding(.trailing, 6).padding(.vertical, 4)
            .background(Amb.card)
            Divider()
            form
        }
        .background(Amb.background)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("deck.compose")
        #else
        NavigationStack {
            form
                .navigationTitle("New thread")
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(requestId == nil ? "Cancel" : "Close") { close() }.accessibilityIdentifier("deck.compose.cancel")
                    }
                }
        }
        .accessibilityIdentifier("deck.compose")
        #endif
    }

    private var eligibleChannelIds: [String] { model.navigation.value.channels(in: model.context).map(\.id) }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            let nav = model.navigation.value
            let channels = nav.channels(in: model.context)
            Button { choosingChannel = true } label: {
                let selected = channels.first { $0.id == channelId }
                Label(selected.map { "#\(nav.label($0))" } ?? "Choose channel", systemImage: "chevron.up.chevron.down")
                    .frame(minHeight: Amb.touchTarget)
                    .contentShape(Rectangle())
            }
            .disabled(requestId != nil)
            .accessibilityLabel("Channel")
            .accessibilityIdentifier("deck.compose.channel")
            if let channelId, !choosingChannel, let connection = model.connection {
                Text("New conversation").font(.amb(.headline))
                Text("Write the first message to start a thread.").foregroundStyle(Amb.mutedForeground)
                Spacer(minLength: 0)
                if requestId == nil {
                    Composer(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: channelId),
                             workspace: workspace, store: store, placeholder: "Start a new thread…", onEnqueued: { requestId = $0 })
                        .id(channelId)
                } else {
                    Text(pending.value?.lastError ?? "Starting thread… Your message is saved on this device.")
                        .accessibilityIdentifier("deck.compose.pending")
                }
            } else {
                Text(channels.isEmpty ? "No channels in this context." : "Choose a channel here to start your thread.")
                List(channels) { channel in
                    Button("#\(nav.label(channel))") {
                        channelId = channel.id
                        choosingChannel = false
                    }
                    .accessibilityIdentifier("deck.compose.option.\(channel.id)")
                }
                .listStyle(.plain)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Amb.background)
        // Resolved from the Deck context shown when the composer opens: its channel, or the only eligible one; otherwise
        // the member chooses (the message field and Send appear once a channel is chosen).
        .onAppear {
            openedContext = model.context
            channelId = DeckCompose.initialChannel(context: model.context, eligible: eligibleChannelIds)
        }
        .onChange(of: model.context) { previous, context in
            guard requestId == nil else { return }
            channelId = DeckCompose.reconcile(chosen: channelId, from: openedContext ?? previous, to: context, eligible: eligibleChannelIds)
            openedContext = context
        }
        .onChange(of: eligibleChannelIds) { _, eligible in
            guard requestId == nil, let context = openedContext else { return }
            channelId = DeckCompose.reconcile(chosen: channelId, from: context, to: context, eligible: eligible)
        }
        .task(id: requestId) {
            guard let requestId else { return }
            let w = workspace.id, store = store
            sent.start(store: store, matches: { $0.workspaceId == w && $0.table == .messages }) {
                try await store.reader.sentMessage(workspaceId: w, clientRequestId: requestId)
            }
            pending.start(store: store, matches: { $0.workspaceId == w && $0.table == .outbox }) {
                try await store.reader.outboxItem(id: requestId)
            }
        }
        .onChange(of: sent.value) { _, message in
            guard let message, let threadId = message.threadId, openedRequestId != requestId else { return }
            openedRequestId = requestId
            onCreated(ThreadFocus(workspaceId: workspace.id, channelId: message.channelId, threadId: threadId))
            #if !os(macOS)
            close()
            #endif
        }
    }
}
