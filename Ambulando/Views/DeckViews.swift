import AmbulandoCore
import SwiftUI

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

    private var cards: [DeckCard] {
        let hasPins = model.pins.value.items.contains { model.pins.value.isPinned($0.pin.resourceType, $0.pin.resourceId) }
        return DeckCard.allCases.filter { $0 != .pinned || hasPins }
    }

    var body: some View {
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
            DeckPagination(cards: cards, selection: $card)
        }
        .navigationTitle("Deck")
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
    }

    @ViewBuilder private func page(_ card: DeckCard) -> some View {
        switch card {
        case .hello: DeckHelloCard(workspace: workspace, store: store)
        case .inbox: DeckInboxCard(workspace: workspace, store: store, active: model.mode == .deck && self.card == .inbox)
        case .pinned: DeckPinnedCard(workspace: workspace)
        case .canvas: DeckCanvasCard(workspace: workspace, store: store)
        case .feed: DeckFeedCard()
        case .recent: DeckRecentCard(workspace: workspace, store: store, active: model.mode == .deck && self.card == .recent)
        }
    }
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
                Text(title).font(.headline).foregroundStyle(Amb.foreground).lineLimit(1)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("deck.card.title")
                Spacer(minLength: 4)
                actions()
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.horizontal, 12).padding(.bottom, 16)
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
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(unread ? Amb.brandOrange.opacity(0.7) : Amb.border, lineWidth: unread ? 1.2 : 0.8))
    }
}

private struct DeckNote: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(Amb.mutedForeground).padding(.horizontal, 4).padding(.vertical, 8)
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
    let workspace: WorkspaceRecord
    let store: LocalStore
    /// Deck is the current section and this card is shown. Out of sight the query pauses (keeping its rows), so a sync
    /// burst does not re-read the whole feed for a card nobody is looking at.
    let active: Bool
    @State private var snapshot = LiveQuery<DeckInboxSnapshot>(initial: DeckInboxSnapshot())
    @State private var kinds = Set(DeckActivity.Kind.allCases)
    @State private var searchDraft = ""
    @State private var query = ""
    @State private var visible = DeckInbox.pageSize
    @State private var notice: String?
    @State private var startedKey: String?

    var body: some View {
        let nav = model.navigation.value
        let context = model.context
        let filtered = DeckActivity.filter(snapshot.value.items, kinds: kinds, query: query)
        let channel = nav.channel(context.channelId)
        DeckCardFrame(title: channel.map { "Inbox: #\(nav.label($0))" } ?? "Inbox", identifier: "inbox") {
            if let channel { PinButton(type: .channel, id: channel.id, title: nav.label(channel), workspace: workspace) }
            newThreadMenu(nav, context)
            readMenu(filtered)
        } content: {
            controls
            if let notice { DeckNote(text: notice).accessibilityIdentifier("deck.inbox.notice") }
            if let error = model.syncError(forKey: WorkspaceSync.inboxKey(workspace.id)) { SyncNote(text: error, tone: .warning) }
            ForEach(filtered.prefix(visible)) { item in row(item, labels: snapshot.value.channelLabels) }
            if filtered.count > visible {
                Button("Load older activity") { visible += DeckInbox.pageSize }
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                    .accessibilityIdentifier("deck.inbox.more")
            }
            if filtered.isEmpty { DeckNote(text: emptyText).accessibilityIdentifier("deck.inbox.empty") }
        }
        .task(id: "\(workspace.id):\(context.encoded()):\(active)") { if active { start(context) } else { snapshot.pause() } }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { refresh(context) } }
    }

    private var emptyText: String {
        if kinds.isEmpty { return "All record types are hidden. Turn on a type to show activity." }
        if !snapshot.loaded { return "Loading activity…" }
        if !query.isEmpty { return "No matches for “\(query)”." }
        return model.canRead ? "No activity here yet." : "No saved activity here. Unlock to load it."
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(DeckActivity.Kind.allCases, id: \.self) { kind in
                    let on = kinds.contains(kind)
                    Button { if on { kinds.remove(kind) } else { kinds.insert(kind) }; visible = DeckInbox.pageSize } label: {
                        Image(systemName: DeckInbox.icon(kind)).font(.subheadline)
                            .foregroundStyle(on ? Amb.selectedForeground : Amb.mutedForeground)
                            .frame(width: 36, height: 30)
                            .background(on ? Amb.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                            .overlay(RoundedRectangle(cornerRadius: Amb.radiusControl).stroke(Amb.border, lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(DeckInbox.toggleLabel(kind))
                    .accessibilityValue(on ? "Shown" : "Hidden")
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("deck.inbox.type.\(kind.rawValue)")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Amb.mutedForeground)
                TextField("Search", text: $searchDraft)
                    .submitLabel(.search)
                    .onSubmit { query = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines); visible = DeckInbox.pageSize }
                    .onChange(of: searchDraft) { _, text in if text.isEmpty { query = ""; visible = DeckInbox.pageSize } }
                    .accessibilityLabel("Search Inbox")
                    .accessibilityIdentifier("deck.inbox.search")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusControl).stroke(Amb.border, lineWidth: 0.8))
        }
        .padding(.bottom, 2)
    }

    /// New thread (sol `openDeckThreadComposer`): choose a channel in the context; Chat opens there with its composer.
    private func newThreadMenu(_ nav: NavigationSnapshot, _ context: WorkContext) -> some View {
        Menu {
            let channels = nav.channels(in: context)
            if channels.isEmpty { Text("No channels in this context") }
            ForEach(channels) { channel in
                Button("#\(nav.label(channel))") { model.openInChat(channelId: channel.id) }
            }
        } label: {
            Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 30, height: 30)
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
            Image(systemName: "ellipsis.circle").font(.body).frame(width: 30, height: 30)
        }
        .accessibilityLabel("Inbox read actions")
        .accessibilityIdentifier("deck.inbox.readMenu")
    }

    @ViewBuilder private func row(_ item: DeckActivity.Item, labels: [String: String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            NavigationLink(value: route(item)) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: DeckInbox.icon(item.kind)).font(.subheadline).foregroundStyle(item.isUnread ? Amb.brandOrange : Amb.primary)
                        .frame(width: 20).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(kicker(item, labels)).font(.caption.weight(.semibold)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ChatTime.label(item.activityAt)).font(.caption2).foregroundStyle(Amb.mutedForeground)
                        }
                        Text(item.title).font(.subheadline.weight(item.isUnread ? .semibold : .regular)).foregroundStyle(Amb.foreground)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Text(item.kind == .chat ? item.subtitle : item.reason).font(.caption).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                        if item.isWorking { Label("Agent working", systemImage: "sparkles").font(.caption2).foregroundStyle(Amb.primary) }
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
        .modifier(DeckRowStyle(unread: item.isUnread))
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

    var body: some View {
        let snapshot = model.pins.value
        let items = snapshot.items.filter { snapshot.isPinned($0.pin.resourceType, $0.pin.resourceId) }
        DeckCardFrame(title: "Pinned items", identifier: "pinned") { EmptyView() } content: {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    open(item) {
                        HStack(spacing: 10) {
                            Image(systemName: icon(item.pin.resourceType)).foregroundStyle(Amb.mutedForeground).frame(width: 20)
                            Text(item.title ?? unavailable(item.pin.resourceType))
                                .font(.subheadline).foregroundStyle(item.title == nil ? Amb.mutedForeground : Amb.foreground).lineLimit(2)
                            Spacer(minLength: 0)
                            if snapshot.pending[PinsSnapshot.key(item.pin.resourceType, item.pin.resourceId)]?.isPending == true {
                                ProgressView().controlSize(.mini).accessibilityLabel("Saving pin")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(label(item.pin.resourceType)): \(item.title ?? unavailable(item.pin.resourceType))")
                    .accessibilityIdentifier("deck.pinned.\(item.title ?? item.pin.resourceId)")
                    Button { model.setPinned(false, type: item.pin.resourceType, id: item.pin.resourceId, in: workspace) } label: {
                        Image(systemName: "pin.slash").frame(width: 28, height: 26)
                    }
                    .buttonStyle(.plain).foregroundStyle(Amb.mutedForeground)
                    .accessibilityLabel("Unpin \(item.title ?? label(item.pin.resourceType))")
                }
                .modifier(DeckRowStyle())
            }
            DeckNote(text: "Pin channels, conversations, tasks and documents to keep them here across scopes. Reordering pins is done in the web app.")
        }
    }

    @ViewBuilder private func open<Label: View>(_ item: PinnedItem, @ViewBuilder label: () -> Label) -> some View {
        let w = workspace.id, id = item.pin.resourceId
        switch item.pin.resourceType {
        case .channel: Button { model.openInChat(channelId: id) } label: { label() }.buttonStyle(.plain)
        case .thread: NavigationLink(value: WorkRoute.threadById(workspaceId: w, threadId: id)) { label() }.buttonStyle(.plain)
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
        case .thread: "Conversation not on this iPhone"
        case .task: "Task not on this iPhone"
        case .document: "Document not on this iPhone"
        case .channel: "Channel not available"
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
        DeckCardFrame(title: "Canvas", identifier: "canvas") { EmptyView() } content: {
            if canvases.loaded && canvases.value.isEmpty {
                if let error = model.syncError(forKey: key) { SyncNote(text: error, tone: .warning) }
                else if model.isSyncing(key) { DeckNote(text: "Loading canvases…") }
                else { DeckNote(text: model.canRead ? "No canvases yet." : "Unlock to load canvases.") }
            }
            ForEach(canvases.value) { canvas in
                NavigationLink(value: WorkRoute.canvas(workspaceId: workspace.id, canvasId: canvas.id)) {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.3.group").foregroundStyle(Amb.primary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(canvas.title).font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(2)
                            Text(canvas.visibilityMode == "workspace" ? "Everyone in the workspace" : "Shared with selected people")
                                .font(.caption).foregroundStyle(Amb.mutedForeground)
                        }
                        Spacer(minLength: 0)
                        if !canvas.updatedAt.isEmpty { Text(ChatTime.label(canvas.updatedAt)).font(.caption2).foregroundStyle(Amb.mutedForeground) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(DeckRowStyle())
                .accessibilityIdentifier("canvas.\(canvas.title)")
            }
            DeckNote(text: "Creating, renaming and sharing canvases is done in the web app.")
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
                Label("Feeds are in the web app", systemImage: "dot.radiowaves.up.forward").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Amb.foreground)
                Text("Subscribed feeds (RSS) and Nostr notifications are read and managed in the web app's Deck. This iPhone app doesn't show them yet.")
                    .font(.footnote).foregroundStyle(Amb.mutedForeground)
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
            Text("Latest activity").font(.caption).foregroundStyle(Amb.mutedForeground)
        } content: {
            ForEach(rows.value, id: \.channelId) { thread in
                let label = nav.channel(thread.channelId).map(nav.label) ?? "channel"
                Button { model.openInChat(channelId: thread.channelId, threadId: thread.isThread ? thread.threadId : nil) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("# \(label)").font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ChatTime.label(thread.latestAt)).font(.caption2).foregroundStyle(Amb.mutedForeground)
                        }
                        Text(DeckActivity.threadTitle(thread)).font(.footnote).foregroundStyle(Amb.foreground).lineLimit(1)
                        Text(MentionCodec.plain(thread.latestBody)).font(.caption).foregroundStyle(Amb.mutedForeground).lineLimit(1)
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
                Text(greeting).font(.title3.weight(.semibold)).foregroundStyle(Amb.foreground)
                Text(contextLabel(nav)).font(.subheadline).foregroundStyle(Amb.mutedForeground)
            }
            .padding(.horizontal, 4).padding(.bottom, 6)
            Text("Apps").font(.footnote.weight(.heavy)).foregroundStyle(Amb.mutedForeground).padding(.horizontal, 4)
            ForEach(wapps.value) { wapp in
                // A browser tab over Deck (signing through `window.nostr`); **Ambulando** returns to this card.
                if let url = wapp.safeLaunchURL {
                    Button { model.browser.launch(url) } label: {
                        Label(wapp.title, systemImage: "app.dashed").font(.subheadline).foregroundStyle(Amb.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(DeckRowStyle())
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
