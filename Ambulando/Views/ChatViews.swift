import AmbulandoCore
import PhotosUI
import SwiftUI

// MARK: Snapshots (plain values read off the main actor)

struct ChannelSnapshot: Sendable, Equatable {
    var title = ""
    var posts: [FeedPost] = []
    var pending: [OutboxItem] = []
    var people = PeopleDirectory()
    var historyComplete = false
    var extras = MessageExtras()
    /// Tower thread titles by thread id, shown on thread roots whose title differs from their text.
    var threadTitles: [String: String] = [:]
    /// Posts that begin a new day (date separator above them), and the day of the newest post.
    var dayStarts: [String: ChatDay] = [:]
    var lastDay: ChatDay?
}

struct ThreadSnapshot: Sendable, Equatable {
    var order: [String] = []
    var windowStart = 0
    var hasEarlier = false
    var hasNewer = false
    var pageIdentity = 0
    var title = ""
    var messages: [MessageRecord] = []
    var pending: [OutboxItem] = []
    var people = PeopleDirectory()
    var archived = false
    var extras = MessageExtras()
    var dayStarts: [String: ChatDay] = [:]
    var lastDay: ChatDay?
    /// What the focused view's header menu acts on (the whole stored history, not just this page).
    var menu: ThreadMenuContext?
}

/// Reactions and unsent edits/deletes for the messages on screen.
struct MessageExtras: Sendable, Equatable {
    var reactions: [String: [ReactionRecord]] = [:]
    var writes: [String: [WriteItem]] = [:]

    func forMessage(_ id: String) -> Self {
        Self(reactions: reactions[id].map { [id: $0] } ?? [:], writes: writes[id].map { [id: $0] } ?? [:])
    }
}

private func messageExtras(_ store: LocalStore, _ workspaceId: String, connectionId: String, ids: [String]) async throws -> MessageExtras {
    async let reactions = store.reader.reactions(workspaceId: workspaceId, targetIds: ids)
    async let writes = store.reader.writes(connectionId: connectionId, workspaceId: workspaceId)
    let wanted = Set(ids)
    let relevant = try await writes.filter { [.messageEdit, .messageDelete, .reactionAdd, .reactionRemove].contains($0.kind) && wanted.contains($0.targetId ?? "") }
    return MessageExtras(reactions: Dictionary(grouping: try await reactions, by: \.targetId), writes: Dictionary(grouping: relevant) { $0.targetId ?? "" })
}

/// Names and avatars for the people of a workspace (Tower directory, agents and cached public profiles).
private func people(_ store: LocalStore, _ target: ChatTarget) async throws -> PeopleDirectory {
    try await store.reader.people(connectionId: target.connectionId, workspaceId: target.workspaceId)
}

private func chatMatches(_ workspaceId: String) -> @Sendable (ChangeKey) -> Bool {
    { key in
        (key.workspaceId == workspaceId || key.workspaceId == nil) && [.messages, .outbox, .members, .agents, .threads, .channels, .reactions, .writes].contains(key.table)
            || (key.table == .outbox && key.workspaceId == nil) || key.table == .profiles
    }
}

// MARK: Scroll following

/// Zero-height marker after the last row; reports whether the newest message is on screen.
private struct NewestSentinel: View {
    @Binding var visible: Bool
    var body: some View {
        Color.clear.frame(height: 1)
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .accessibilityHidden(true)
    }
}

/// Where the reader left each conversation, so closing and reopening it returns to the same message rather than the
/// newest. Kept for the app session, per connection, workspace and thread; a thread left at its newest message is not
/// kept and reopens at the newest.
@MainActor final class ReadingPositions {
    static let shared = ReadingPositions()
    private var anchors: [String: String] = [:]

    private static func key(_ target: ChatTarget) -> String? {
        target.threadId.map { "\(target.connectionId):\(target.workspaceId):\($0)" }
    }

    func anchor(for target: ChatTarget) -> String? { Self.key(target).flatMap { anchors[$0] } }

    /// Records the first message on screen, or forgets the thread when the reader was at the newest message.
    func record(_ target: ChatTarget, firstVisible: String?) {
        guard let key = Self.key(target) else { return }
        anchors[key] = firstVisible
    }

    func removeAll() { anchors.removeAll() }
}

/// The rows currently on screen. A plain reference so scrolling never re-renders the list.
private final class VisibleRows {
    private(set) var ids = Set<String>()
    func set(_ id: String, _ visible: Bool) { if visible { ids.insert(id) } else { ids.remove(id) } }
}

/// Keeps the newest message in view when the user sends one, or when one arrives while they are already at the
/// bottom. Reading older messages is never interrupted.
private struct FollowLatest: ViewModifier {
    let lastId: String?
    let pendingCount: Int
    /// Whether the end of the list is on screen, reported by `NewestSentinel` (scroll geometry is unreliable here:
    /// LazyVStack revises its size estimates while the newest rows stay visible).
    let nearBottom: Bool
    /// A message to open at (top of the screen) instead of the newest: where the reader left a reopened thread.
    var resumeAt: String? = nil
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var lastPending = 0
    @State private var positioned = false
    /// The list was at the newest message when the keyboard started to hide (for example a context menu took focus).
    @State private var restoreOnKeyboard = false

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onKeyboard(willHide: { restoreOnKeyboard = nearBottom }, didShow: {
                // The keyboard came back (menu closed, composer refocused): return to the newest message if the user was
                // there, instead of leaving it hidden behind the composer.
                guard restoreOnKeyboard || nearBottom else { return }
                restoreOnKeyboard = false
                Task { @MainActor in withAnimation(.snappy) { position.scrollTo(edge: .bottom) } }
            })
            .onAppear { positionInitially(lastId) }
            .onChange(of: lastId) { _, id in
                // Rows usually arrive after the first (empty) layout: open at the newest message, once.
                guard positioned else { positionInitially(id); lastPending = pendingCount; return }
                let ownSend = pendingCount > lastPending
                lastPending = pendingCount
                guard id != nil, nearBottom || ownSend else { return }
                // Edge scrolling honours the composer and keyboard insets, unlike scrolling to a row id.
                Task { @MainActor in withAnimation(.snappy) { position.scrollTo(edge: .bottom) } }
            }
            .onChange(of: pendingCount) { _, count in if count < lastPending { lastPending = count } }
    }

    private func positionInitially(_ id: String?) {
        guard !positioned, id != nil else { return }
        positioned = true
        if let resumeAt {
            lastPending = pendingCount
            Task { @MainActor in position.scrollTo(id: resumeAt, anchor: .top) }
        } else {
            Task { @MainActor in position.scrollTo(edge: .bottom) }
        }
    }
}

// MARK: Channel

/// A job's last error, read in its own view so sync status changes do not re-render the surrounding list.
struct SyncErrorNote: View {
    @Environment(AppModel.self) private var model
    let key: String
    var body: some View {
        if let error = model.syncError(forKey: key) { SyncNote(text: error, tone: .warning) }
    }
}

/// Sync state for one channel, in its own view so status changes re-render only this note, never the message list.
private struct ChannelSyncNote: View {
    @Environment(AppModel.self) private var model
    let key: String
    let historyComplete: Bool

    var body: some View {
        if !historyComplete {
            SyncNote(text: model.syncError(forKey: key)
                     ?? (model.identity.npub != nil && model.canRead ? "Loading history…" : "Showing saved messages. Unlock to load history."))
        } else if let error = model.syncError(forKey: key) {
            SyncNote(text: error, tone: .warning)
        }
    }
}

/// A channel's conversations (thread roots), newest at the bottom, with unsent messages inline and a composer
/// that starts a new conversation. Reads only the local store; opening it asks the sync engine for catch-up.
struct ChannelView: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    /// The sample-data label of a pushed screen; the Chat root shows the shell's banner instead.
    var pushed = true
    @State private var snapshot = LiveQuery<ChannelSnapshot>(initial: ChannelSnapshot())
    @State private var limit = 150
    @State private var atNewest = true

    // One Messages view: every conversation is a card here, and one with replies opens its real thread (the web's
    // separate Threads list showed the same conversations again).
    var body: some View {
        messages
        .tabletReadingWidth()
        .background(Amb.background)
        .modifier(PushedFixtureLabel(enabled: pushed))
        .navigationTitle(title)
        .inlineTitle()
        .onAppear { model.openChannel(target.channelId, in: workspace) }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { model.openChannel(target.channelId, in: workspace) } }
    }

    /// The channel label from the sidebar (direct messages are named after their participants).
    private var title: String {
        if let channel = model.navigation.value.channel(target.channelId) {
            let label = model.navigation.value.label(channel)
            return SidebarNavigation.isDirectMessageChannel(channel) ? label : "#\(label)"
        }
        return snapshot.value.title.isEmpty ? " " : "#\(snapshot.value.title)"
    }

    private var messages: some View {
        VStack(spacing: 0) {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if snapshot.value.posts.count >= limit {
                    Button("Show earlier messages") { limit += 150 }
                        .font(.amb(.footnote).weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                if snapshot.loaded {
                    ChannelSyncNote(key: WorkspaceSync.messagesKey(workspace.id, target.channelId), historyComplete: snapshot.value.historyComplete)
                }
                // Each conversation is a card (sol `.channel-thread-card`); a date label starts each day.
                // One view per element (a lazy stack mis-lays rows whose element yields a varying number of views).
                ForEach(snapshot.value.posts) { post in
                    VStack(spacing: 0) {
                        if let day = snapshot.value.dayStarts[post.id] { DaySeparator(day: day) }
                        PostRow(post: post, people: snapshot.value.people, workspace: workspace, extras: snapshot.value.extras,
                                threadTitle: post.message.threadId.flatMap { snapshot.value.threadTitles[$0] })
                            .conversationCard()
                    }
                }
                ForEach(snapshot.value.pending) { item in
                    VStack(spacing: 0) {
                        if item.id == snapshot.value.pending.first?.id, snapshot.value.lastDay != ChatDay.today { DaySeparator(day: .today) }
                        OutboxRow(item: item, people: snapshot.value.people).conversationCard()
                    }
                }
                if snapshot.loaded && snapshot.value.posts.isEmpty && snapshot.value.pending.isEmpty && snapshot.value.historyComplete {
                    Text("No messages yet. Start a conversation below.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground).frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.bottom, 8)
            NewestSentinel(visible: $atNewest)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .modifier(FollowLatest(lastId: snapshot.value.pending.last?.id ?? snapshot.value.posts.last?.id,
                               pendingCount: snapshot.value.pending.count, nearBottom: atNewest))
        .scrollDismissesKeyboard(.interactively)
        .refreshable { model.openChannel(target.channelId, in: workspace, force: true) }
            // A stacked composer (not an inset) so keyboard avoidance shrinks the list itself and the newest
            // message stays visible above the composer.
            Composer(target: target, workspace: workspace, store: store,
                     placeholder: "Message \(title.trimmingCharacters(in: .whitespaces).isEmpty ? "#channel" : title)")
        }
        .task(id: limit) { start() }
        .onChange(of: snapshot.value.posts.map(\.id)) { _, ids in model.refreshReactions(workspace, scope: target.channelId, messageIds: ids) }
    }

    private var isUnlocked: Bool { if case .unlocked = model.identity { true } else { false } }

    private func start() {
        let target = target, limit = limit, store = store
        snapshot.start(store: store, matches: chatMatches(target.workspaceId)) {
            async let channel = store.reader.channel(workspaceId: target.workspaceId, id: target.channelId)
            async let posts = store.reader.channelFeed(workspaceId: target.workspaceId, channelId: target.channelId, limit: limit)
            async let pending = store.reader.outbox(target: target)
            async let sync = store.reader.channelSync(workspaceId: target.workspaceId, channelId: target.channelId)
            async let directory = people(store, target)
            async let titles = store.reader.threadTitles(workspaceId: target.workspaceId, channelId: target.channelId)
            let rows = try await posts
            MessageDisplayCache.shared.prepare(rows.map(\.message))
            let extras = try await messageExtras(store, target.workspaceId, connectionId: target.connectionId, ids: rows.map(\.id))
            let days = ChatDay.breaks(rows, id: \.id, time: \.message.createdAt)
            return ChannelSnapshot(title: try await channel?.name ?? "", posts: rows, pending: try await pending,
                                   people: try await directory, historyComplete: try await sync?.complete ?? false, extras: extras,
                                   threadTitles: try await titles, dayStarts: days.starts, lastDay: days.last)
        }
    }
}

// MARK: Thread

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var snapshot = LiveQuery<ThreadSnapshot>(initial: ThreadSnapshot())
    @State private var atNewest = true
    @State private var visibleRows = VisibleRows()
    @State private var windowAnchor: String?
    @State private var pageIdentity = 0
    /// Where the reader left this thread last time it was open (nil: open at the newest message).
    @State private var resumeAt: String?

    init(target: ChatTarget, workspace: WorkspaceRecord, store: LocalStore) {
        self.target = target
        self.workspace = workspace
        self.store = store
        let saved = ReadingPositions.shared.anchor(for: target)
        _resumeAt = State(initialValue: saved)
        _atNewest = State(initialValue: saved == nil)
        _windowAnchor = State(initialValue: saved)
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            ThreadMessageStack {
                if snapshot.value.hasEarlier { pageButton(earlier: true) }
                if let threadId = target.threadId { SyncErrorNote(key: WorkspaceSync.threadKey(workspace.id, threadId)) }
                if snapshot.value.archived { SyncNote(text: "This thread is archived. Replying reopens it.") }
                // The first message, a labelled rule, then the replies; a date label starts each day. No line between replies.
                ForEach(Array(snapshot.value.messages.enumerated()), id: \.element.id) { index, message in
                    VStack(spacing: 0) {
                        if let day = snapshot.value.dayStarts[message.id] { DaySeparator(day: day) }
                        #if os(macOS)
                        // A faint line shows where one message ends and the next begins (not under the replies rule).
                        if index > 0 && !(index == 1 && snapshot.value.messages[0].isThreadRoot) { Rectangle().fill(Amb.border.opacity(0.45)).frame(height: 1).padding(.horizontal, 24) }
                        #endif
                        MessageCell(message: message, people: snapshot.value.people, workspace: workspace, extras: snapshot.value.extras.forMessage(message.id)).equatable()
                        // The root, or the first message of a thread stored without its source id.
                        if (message.isThreadRoot || (index == 0 && snapshot.value.windowStart == 0)) && snapshot.value.order.count > 1 {
                            RepliesRule(count: snapshot.value.order.count - 1)
                        }
                    }
                    .onScrollVisibilityChange(threshold: 0.3) { [visibleRows] in visibleRows.set(message.id, $0) }
                }
                ForEach(snapshot.value.hasNewer ? [] : snapshot.value.pending) { item in
                    VStack(spacing: 0) {
                        if item.id == snapshot.value.pending.first?.id, !snapshot.value.messages.isEmpty, snapshot.value.lastDay != ChatDay.today {
                            DaySeparator(day: .today)
                        }
                        OutboxRow(item: item, people: snapshot.value.people)
                    }
                }
                if snapshot.loaded && snapshot.value.messages.isEmpty {
                    SyncNote(text: isUnlocked ? "Loading thread…" : "This thread is not saved on this \(Device.name) yet. Unlock to load it.")
                }
                if snapshot.value.hasNewer { pageButton(earlier: false) }
            }
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .modifier(FollowLatest(lastId: snapshot.value.pending.last?.id ?? snapshot.value.messages.last?.id,
                               pendingCount: snapshot.value.pending.count, nearBottom: atNewest && !snapshot.value.hasNewer,
                               resumeAt: (pageIdentity > 0 ? windowAnchor : resumeAt).flatMap { id in snapshot.value.messages.contains { $0.id == id } ? id : nil }))
        // Directly measured pages have accurate geometry; a newly inserted visibility sentinel can miss its
        // first callback after page replacement, leaving a latest page incorrectly marked as older reading.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height <= 80
        } action: { _, newest in
            atNewest = newest && !snapshot.value.hasNewer
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting, windowAnchor == nil, snapshot.loaded {
                windowAnchor = snapshot.value.messages.first?.id
            }
            if phase == .idle, snapshot.loaded, atNewest, !snapshot.value.hasNewer { windowAnchor = nil }
        }
        .id(snapshot.value.pageIdentity)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { if let thread = target.threadId { model.openThread(thread, channelId: target.channelId, in: workspace) } }
            Composer(target: target, workspace: workspace, store: store, placeholder: "Reply", onEnqueued: { _ in
                if windowAnchor != nil { windowAnchor = nil; pageIdentity += 1 }
            })
        }
        .tabletReadingWidth()
        .background(Amb.background)
        .fixtureLabel()
        .navigationTitle(snapshot.value.title.isEmpty ? "Thread" : snapshot.value.title)
        .inlineTitle()
        .preference(key: ThreadTitleKey.self, value: snapshot.value.title)
        .preference(key: ThreadMenuKey.self, value: snapshot.value.menu)
        .task(id: windowAnchor) { start() }
        .onAppear {
            if let thread = target.threadId {
                model.openThread(thread, channelId: target.channelId, in: workspace)
                model.markViewed(.thread, thread, in: workspace)
            }
        }
        .onChange(of: snapshot.value.messages.map(\.id)) { _, ids in
            if let thread = target.threadId { model.refreshReactions(workspace, scope: thread, messageIds: ids) }
        }
        .onDisappear {
            let first = atNewest && !snapshot.value.hasNewer ? nil : snapshot.value.messages.first { visibleRows.ids.contains($0.id) }?.id
            ReadingPositions.shared.record(target, firstVisible: first)
        }
    }

    private func pageButton(earlier: Bool) -> some View {
        Button(earlier ? "Earlier replies" : "Newer replies") {
            let value = snapshot.value
            let next = earlier ? max(0, value.windowStart - 50) : value.windowStart + 50
            windowAnchor = !earlier && next >= max(0, value.order.count - 50) ? nil : value.order.indices.contains(next) ? value.order[next] : nil
            atNewest = false
            pageIdentity += 1
        }
        .accessibilityIdentifier(earlier ? "thread.earlier" : "thread.newer")
        .font(.amb(.footnote).weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
        .accessibilityHint("Messages \(snapshot.value.windowStart + 1) through \(snapshot.value.windowStart + snapshot.value.messages.count) of \(snapshot.value.order.count)")
    }

    private var isUnlocked: Bool { if case .unlocked = model.identity { true } else { false } }

    private func start() {
        guard let threadId = target.threadId else { return }
        let target = target, store = store, anchor = windowAnchor, page = pageIdentity
        let selectedStart = anchor.flatMap { snapshot.value.order.firstIndex(of: $0) }
        let fallbackStart = selectedStart ?? snapshot.value.windowStart
        let fallback = selectedStart.map { Array(snapshot.value.order.dropFirst($0)) } ?? snapshot.value.messages.map(\.id)
        snapshot.start(store: store, keepingValue: true, matches: { key in
            chatMatches(target.workspaceId)(key) && key.affectsThread(workspaceId: target.workspaceId, channelId: target.channelId, threadId: threadId)
                || (key.table == .access && (key.workspaceId == nil || key.workspaceId == target.workspaceId))
        }) {
            let historyLimit = 500
            async let thread = store.reader.thread(workspaceId: target.workspaceId, id: threadId)
            async let messages = store.reader.threadMessages(workspaceId: target.workspaceId, threadId: threadId, limit: historyLimit)
            async let pending = store.reader.outbox(target: target)
            async let directory = people(store, target)
            let history = try await messages
            let window = ThreadMessageWindow(history, anchor: anchor, fallback: fallback, fallbackStart: fallbackStart)
            let rows = window.messages
            MessageDisplayCache.shared.prepare(rows)
            let record = try await thread
            let title = record?.title.map(MentionCodec.plain) ?? history.first.map { MentionCodec.plain($0.body) } ?? ""
            let extras = try await messageExtras(store, target.workspaceId, connectionId: target.connectionId, ids: rows.map(\.id))
            let days = ChatDay.breaks(rows, id: \.id, time: \.createdAt)
            return ThreadSnapshot(order: window.order, windowStart: window.start, hasEarlier: window.hasEarlier, hasNewer: window.hasNewer,
                                  pageIdentity: page, title: String(title.prefix(60)), messages: rows, pending: try await pending,
                                  people: try await directory, archived: record?.archived ?? false, extras: extras,
                                  dayStarts: days.starts, lastDay: days.last,
                                  menu: ThreadMenuContext(threadId: threadId, channelId: target.channelId, record: record, history: history,
                                                          historyComplete: history.count < historyLimit))
        }
    }
}

/// A thread renders a 50-message page of its 500-message history, with explicit older/newer navigation, as a plain
/// (measured) stack. Lazy row estimates kept invalidating native text layout on the Mac while sync changed the content,
/// and on the iPhone and iPad they placed a reopened thread at estimated offsets: rows came back a few messages away
/// from where the reader left, or not at all until a scroll (an empty screen). Measured rows put the reader exactly
/// where they were. Channel history remains lazy and paginated.
private struct ThreadMessageStack<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { VStack(alignment: .leading, spacing: 0, content: content) }
}

// MARK: Rows

struct PostRow: View {
    let post: FeedPost
    let people: PeopleDirectory
    let workspace: WorkspaceRecord
    let extras: MessageExtras
    var threadTitle: String? = nil

    var body: some View {
        if let thread = post.message.threadId {
            // Only the message opens the thread; reactions and status lines below it stay separately tappable.
            MessageCell(message: post.message, people: people, workspace: workspace, extras: extras,
                        route: ChatRoute.thread(workspaceId: workspace.id, channelId: post.message.channelId, threadId: thread),
                        replyCount: post.replyCount, lastReplyAt: post.lastReplyAt, threadTitle: threadTitle)
        } else {
            MessageCell(message: post.message, people: people, workspace: workspace, extras: extras)
        }
    }
}

struct MessageRow: View {
    let message: MessageRecord
    let people: PeopleDirectory
    var bodyOverride: String?
    var workspace: WorkspaceRecord?

    /// Resolved from the store with the snapshot: workspace name, Tower's label, public profile, else the short npub.
    private var sender: PersonDisplay { people.person(message.senderNpub, senderLabel: message.senderLabel) }

    private var messageHeaderSpacing: CGFloat {
        #if os(macOS)
        6 * ChatTypography.scale
        #else
        3
        #endif
    }

    var body: some View {
        let display = MessageDisplayCache.shared.display(message)
        // Code, tables and images keep their own controls (copy, scroll, open), so such rows contain elements instead
        // of being read as a single combined label.
        let interactive = !display.attachments.isEmpty || (bodyOverride == nil && (display.blocks.map(RichBlocksInfo.hasControls) ?? false))
        let sender = sender
        HStack(alignment: .top, spacing: 10) {
            PersonAvatar(person: sender)
            VStack(alignment: .leading, spacing: messageHeaderSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sender.name).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1)
                        .accessibilityIdentifier("message.author")
                    Text(display.time).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
                if let bodyOverride {
                    if !bodyOverride.isEmpty { MessageBody(text: bodyOverride, muted: true) }
                } else if !message.body.isEmpty {
                    if let blocks = display.blocks { RichBlocksView(blocks: blocks, workspace: workspace) } else { MessageBody(plain: message.body) }
                }
                if let workspace {
                    ForEach(display.attachments, id: \.storageObjectId) { attachment in
                        if attachment.textAttachment != nil {
                            SentTextAttachmentCard(message: message, attachment: attachment, workspace: workspace)
                        } else {
                            AttachmentView(attachment: attachment, workspace: workspace)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        #if os(macOS)
        // Desktop messages get room to breathe; the iPhone keeps its compact rows.
        .padding(.horizontal, 24).padding(.vertical, 14)
        #else
        .padding(.horizontal, 16).padding(.vertical, 8)
        #endif
        .accessibilityElement(children: interactive ? .contain : .combine)
        .accessibilityIdentifier("message")
    }
}

/// Message, comment or description text as the web renders it: Markdown with mentions (`@[Label](mention:type:npub)`)
/// as styled, tappable names. Plain text skips parsing.
struct MessageBody: View {
    private let blocks: [RenderBlock]?
    private let plain: String
    var muted = false
    var workspace: WorkspaceRecord?

    init(text: String, muted: Bool = false, workspace: WorkspaceRecord? = nil) {
        blocks = MessageText.cachedBlocks(text); plain = text
        self.muted = muted
        self.workspace = workspace
    }
    init(plain: String, muted: Bool = false) { blocks = nil; self.plain = plain; self.muted = muted }

    var body: some View {
        if let blocks {
            RichBlocksView(blocks: blocks, muted: muted, workspace: workspace)
        } else {
            Text(verbatim: plain).font(.amb(.body).weight(.regular)).foregroundStyle(muted ? Amb.mutedForeground : Amb.foreground)
                .textSelection(.enabled)
                .lineSpacing(ChatTypography.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: ChatTypography.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Initials only, for rows that know a name but not the person (task and document comments, mention suggestions).
struct Avatar: View {
    let name: String
    var body: some View { InitialsAvatar(initials: PersonInitials.of(name)) }
}

/// An unsent message, shown where it will appear, with its delivery state and the actions that apply to it.
struct OutboxRow: View {
    @Environment(AppModel.self) private var model
    let item: OutboxItem
    let people: PeopleDirectory

    private var status: (text: String, icon: String, tone: Color) {
        switch item.state {
        case .awaitingSignature:
            if case .unlocked = model.identity { return ("Sending…", "arrow.up.circle", Amb.mutedForeground) }
            return ("Waiting for unlock to sign and send", "lock", Amb.info)
        case .queued, .sending: return ("Sending…", "arrow.up.circle", Amb.mutedForeground)
        case .retrying: return (item.lastError ?? "Will retry automatically", "arrow.clockwise.circle", Amb.warning)
        case .failed: return ("Not sent. " + (item.lastError ?? "Tower rejected the message."), "exclamationmark.circle", Amb.destructive)
        }
    }

    var body: some View {
        let me = people.person(item.signerNpub)
        HStack(alignment: .top, spacing: 10) {
            PersonAvatar(person: me)
            VStack(alignment: .leading, spacing: 4) {
                Text(me.nameSource == .npub ? "You" : me.name).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground)
                if !item.body.isEmpty { MessageBody(text: item.body, muted: true) }
                if !item.attachments.isEmpty {
                    Label("\(item.attachments.count) \(item.attachments.count == 1 ? "photo" : "photos")" + (item.attachments.allSatisfy(\.complete) ? "" : " (uploading)"),
                          systemImage: "photo").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
                Label(status.text, systemImage: status.icon).font(.amb(.caption)).foregroundStyle(status.tone)
                    .accessibilityIdentifier("outbox.status")
                if item.state == .failed || item.state == .retrying {
                    HStack(spacing: 16) {
                        Button(item.state == .failed ? "Retry" : "Retry now") { retry() }.accessibilityIdentifier("outbox.retry")
                        if item.state == .failed {
                            Button("Edit") { Task { try? await model.outbox?.discard(item.id, restoreDraft: true) } }
                                .accessibilityIdentifier("outbox.edit")
                            Button("Discard", role: .destructive) { Task { try? await model.outbox?.discard(item.id, restoreDraft: false) } }
                        }
                    }
                    .font(.amb(.caption).weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
            SyncDot(state: item.state == .failed ? .failed : .pending).padding(.top, 4)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(item.state == .failed ? Amb.destructiveBackground.opacity(0.5) : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outbox.row")
    }

    private func retry() {
        guard let outbox = model.outbox, let connection = model.connection, connection.id == item.connectionId else { return }
        Task { try? await outbox.retry(item.id, connection: connection) }
    }
}

struct SyncNote: View {
    let text: String
    var tone: Notice.Tone = .info
    var body: some View { Notice(tone: tone, text: text).padding(.horizontal, 16).padding(.vertical, 6) }
}

enum ChatTime {
    nonisolated(unsafe) private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// Labels are memoised per calendar day (list rows ask for them on every layout pass).
    nonisolated(unsafe) private static var labels: [String: String] = [:]
    nonisolated(unsafe) private static var labelsDay = 0
    private static let lock = NSLock()

    static func dayStamp() -> Int { Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 / 86_400) }

    /// The instant of a Tower timestamp (with or without fractional seconds).
    static func date(_ iso: String) -> Date? { lock.withLock { parser.date(from: iso) ?? plain.date(from: iso) } }

    static func label(_ iso: String) -> String {
        let day = dayStamp()
        if let hit = lock.withLock({ () -> String? in
            if labelsDay != day { labels.removeAll(); labelsDay = day }
            return labels[iso]
        }) { return hit }
        let made = compute(iso)
        lock.withLock { if labels.count > 5000 { labels.removeAll() }; labels[iso] = made }
        return made
    }

    private static func compute(_ iso: String) -> String {
        guard let date = lock.withLock({ parser.date(from: iso) ?? plain.date(from: iso) }) else { return "" }
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

// MARK: Composer

/// Composer state for one target. Typing only changes in-memory text; the durable draft is written on a short
/// debounce through the store writer (off the main actor), and every write or send is chained so a late draft
/// save can never resurrect text that was just sent.
@MainActor
@Observable
final class ComposerModel {
    var text = "" { didSet { if text != oldValue { edited = true; changedAt = Date(); scheduleSave() } } }
    private(set) var mentions: [Mention] = []
    private(set) var persistenceFailure: String?
    @ObservationIgnored let target: ChatTarget
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private var edited = false
    /// Local edits, including clearing the field, take precedence over a draft read that started earlier.
    @ObservationIgnored private var changedAt = Date.distantPast
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// Set by `send`: a draft read before the send cleared it can still arrive from the store and must not put the sent
    /// text back. Only drafts written after the send (an Edit restore of a rejected message) are adopted.
    @ObservationIgnored private var sentAt: Date?

    init(target: ChatTarget, store: LocalStore) { self.target = target; self.store = store }

    func restore() async {
        guard let draft = try? await store.reader.draft(target), !edited else { return }
        mentions = draft.mentions
        text = draft.text
        attachments = draft.attachments
        edited = false
    }

    /// A draft written to the store by someone other than this composer (for example "Edit" on a message that was
    /// not sent) is adopted when the composer is empty, so the text appears where the user is looking.
    func adopt(_ draft: Draft?) {
        guard let draft, text.isEmpty, attachments.isEmpty, !draft.text.isEmpty || !draft.attachments.isEmpty else { return }
        // An empty field can be an intentional local edit. A delayed read of its previous saved text must
        // not resurrect that text. A genuinely newer external draft (Edit on a rejected send) still restores.
        if edited, (draft.updatedAt ?? .distantPast) <= changedAt.addingTimeInterval(0.001) { return }
        // Stored times are rounded to milliseconds, so anything within 1 ms of the send counts as before it.
        if let sentAt, (draft.updatedAt ?? .distantPast) <= sentAt.addingTimeInterval(0.001) { return }
        mentions = draft.mentions
        text = draft.text
        attachments = draft.attachments
        edited = false
    }

    /// What the field shows: the whole draft, including the Markdown of uploaded images and files where they were
    /// inserted, so it can be moved or edited like the web's composer (the thumbnails above are only a preview).
    var visibleText: String {
        get { text }
        set {
            // Backspace inside a picked name removes the whole name, as a pill is removed.
            let typed = MentionCodec.wholeMentionDeletion(old: text, new: newValue, mentions: mentions) ?? newValue
            if typed != text { text = typed }
        }
    }

    /// Picked people and agents still named in the text: shown as pills above the field.
    var presentMentions: [Mention] { MentionCodec.present(mentions, in: text) }

    func removeMention(_ mention: Mention) {
        text = MentionCodec.removing(mention, from: text)
        mentions.removeAll { $0 == mention }
    }

    func removeUploaded(_ objectId: String) { text = StorageMarkdown.removingInline(objectId: objectId, from: text) }

    func pick(_ mention: Mention) {
        if !mentions.contains(mention) { mentions.append(mention) }
        visibleText = MentionCodec.complete(visibleText, with: mention)
    }

    private func chain(_ operation: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task { await previous?.value; await operation() }
    }

    private func scheduleSave() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        debounce?.cancel()
        debounce = nil
        let draft = Draft(text: text, mentions: mentions.filter { text.contains($0.visible) }, attachments: attachments), target = target, store = store
        chain { [weak self] in
            do { try await store.writer.saveDraft(target, draft); await MainActor.run { self?.persistenceFailure = nil } }
            catch { await MainActor.run { self?.persistenceFailure = "This draft could not be saved on this device. Keep it open and retry before closing." } }
        }
    }

    /// Replace the draft metadata only after SQLite accepted it. The old staged bytes remain recoverable on failure.
    func commitAttachment(_ replacement: PendingAttachment) async throws {
        debounce?.cancel(); debounce = nil
        await tail?.value
        var next = attachments
        guard let index = next.firstIndex(where: { $0.id == replacement.id }) else { throw TextAttachmentError.missing }
        next[index] = replacement
        try await store.writer.saveDraft(target, Draft(text: text, mentions: mentions.filter { text.contains($0.visible) }, attachments: next))
        attachments = next
    }

    /// Photos and pasted text files chosen for the next message, already staged on the device. They are part of the
    /// durable draft, so they survive relaunch and a change of conversation.
    var attachments: [PendingAttachment] = [] { didSet { if attachments != oldValue { edited = true; changedAt = Date(); scheduleSave() } } }

    /// Hands the composed text to the outbox (which clears the stored draft in the same transaction).
    func send(with outbox: OutboxSender, connection: ConnectionRecord, workspace: WorkspaceRecord,
              onEnqueued: (@MainActor @Sendable (String) -> Void)? = nil) {
        debounce?.cancel()
        debounce = nil
        let text = text, mentions = mentions, target = target, attachments = attachments
        sentAt = Date()
        self.text = ""
        self.mentions = []
        self.attachments = []
        edited = false
        chain {
            do {
                if let item = try await outbox.send(text: text, mentions: mentions, target: target, connection: connection, workspace: workspace, attachments: attachments) {
                    await onEnqueued?(item.id)
                }
            }
            catch {
                // The outbox write failed (for example, storage full): put the text back rather than lose it.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.sentAt = nil
                    self.text = self.text.isEmpty ? text : text + "\n" + self.text
                    for mention in mentions where !self.mentions.contains(mention) { self.mentions.append(mention) }
                    for attachment in attachments where !self.attachments.contains(where: { $0.id == attachment.id }) { self.attachments.append(attachment) }
                    self.persistenceFailure = "The message could not be queued. Its text and attachments are back in this draft."
                    self.saveNow()
                }
            }
        }
    }
}

/// Pasted uploads finish into this composer while it shows their target (otherwise into the stored draft).
extension ComposerModel: UploadTokenHost {
    var uploadTarget: ChatTarget { target }
    var uploadText: String { text }

    func replaceUploadToken(_ token: String, with replacement: String) -> Bool {
        guard let next = ComposerText.replacing(token, with: replacement, in: text, selection: nil) else { return false }
        text = next.text   // saved on the usual debounce; the text view keeps the caret
        return true
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    let placeholder: String
    var onEnqueued: (@MainActor @Sendable (String) -> Void)? = nil
    @State private var composer: ComposerModel?
    @State private var members = LiveQuery<[MentionCandidate]>(initial: [])
    @State private var storedDraft = LiveQuery<Draft?>(initial: nil)
    @State private var photos: [PhotosPickerItem] = []
    /// Upload placeholders of picked photos, put in at the caret like a paste (then replaced by their Markdown).
    @State private var insertion: String?
    @State private var openAttachment: TextAttachmentSubject?
    @State private var pasteNotice: String?
    @State private var focused = false
    @State private var recordSuggestions: (query: MentionQuery, rows: [MentionSuggestion]) = (MentionQuery(""), [])
    /// What this person tagged most recently, for the bare `@` list.
    @State private var recentTags: [Mention] = []
    /// The row of the mention list that Return or Tab picks (Up and Down move it).
    @State private var highlighted = 0
    /// Escape closes the list for the text as it stands; typing more opens it again.
    @State private var dismissedAt: String?
    #if os(macOS)
    @State private var attachingFiles = false
    #endif

    /// The `@` lookahead as on the web: people and agents from the directory, and documents, tasks, conversations,
    /// channels and scopes from the local store, filtered by the name typed so far (a `doc:` style prefix narrows it).
    private var suggestions: [MentionSuggestion] {
        guard let composer, composer.visibleText != dismissedAt, let typed = activeQuery else { return [] }
        let query = MentionQuery(typed)
        let records = recordSuggestions.query == query ? recordSuggestions.rows : []
        return MentionRanking.merge(actors: members.value.map { (Mention(member: $0.member), $0.member.npub) }, records: records, query: query,
                                    recent: recentTags)
    }

    /// The `@` being typed, none once a name from the list has been picked (the list closes and stays closed as typing goes on).
    private var activeQuery: String? {
        guard let composer else { return nil }
        return MentionCodec.activeQuery(in: composer.visibleText, excluding: composer.mentions)
    }

    /// Records matching the active `@` query, read off the main actor as it changes.
    private func lookUpRecords(_ typed: String?) async {
        guard let typed, let store = model.store else { return }
        let query = MentionQuery(typed), workspaceId = target.workspaceId
        if typed.isEmpty, let me = model.identity.npub, let rows = try? await store.reader.recentMentions(workspaceId: workspaceId, senderNpub: me) {
            recentTags = rows
        }
        // A short pause lets fast typing settle before the store is read; a newer keystroke cancels this one.
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled, let rows = try? await store.reader.mentionSuggestions(workspaceId: workspaceId, query: query, limit: query.limit) else { return }
        let navigation = model.navigation.value
        // Channels carry the sidebar's name (direct messages are named after their participants), as the web labels them.
        let labelled = rows.map { row -> MentionSuggestion in
            guard row.mention.type == .channel, let channel = navigation.channel(row.mention.id) else { return row }
            return MentionSuggestion(mention: Mention(type: .channel, npub: row.mention.id, label: navigation.label(channel)),
                                     detail: row.detail, updatedAt: row.updatedAt)
        }
        recordSuggestions = (query, labelled)
    }

    /// Keys from the text field while the mention list is open. Returns whether the key was used.
    private func mentionKey(_ key: ComposerKey) -> Bool {
        let list = suggestions
        guard !list.isEmpty, let composer else { return false }
        let index = min(highlighted, list.count - 1)
        switch key {
        case .up: highlighted = (index - 1 + list.count) % list.count
        case .down: highlighted = (index + 1) % list.count
        case .enter, .tab: composer.pick(list[index].mention); highlighted = 0
        case .escape: dismissedAt = composer.visibleText
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            if !suggestions.isEmpty, let composer {
                MentionPicker(suggestions: suggestions, people: members.value, highlighted: min(highlighted, suggestions.count - 1)) { composer.pick($0.mention) }
            }
            Divider().overlay(Amb.border)
            if let composer {
                @Bindable var composer = composer
                ComposerAttachmentStrip(mentions: composer.presentMentions, people: members.value, removeMention: { composer.removeMention($0) },
                                        attachments: $composer.attachments, staging: model.staging, text: composer.text,
                                        workspace: workspace, removeUploaded: { composer.removeUploaded($0) })
                ComposerTextCards(attachments: $composer.attachments, staging: model.staging) { openAttachment = .draft($0) }
                if let left = TextAttachmentPolicy.remaining(codePoints: TextAttachmentPolicy.codePoints(composer.visibleText)) {
                    Text(left >= 0 ? "\(left) characters left" : "\(-left) characters over")
                        .font(.amb(.caption)).foregroundStyle(left > 100 ? Amb.mutedForeground : Amb.destructive)
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 14).padding(.top, 4)
                        .accessibilityIdentifier("composer.counter")
                }
                if let error = composer.persistenceFailure {
                    Text(error).font(.amb(.caption)).foregroundStyle(Amb.destructive).padding(.horizontal, 14).padding(.top, 4)
                        .accessibilityIdentifier("composer.persistence.error")
                    Button("Retry saving draft") { composer.saveNow() }.font(.amb(.caption))
                }
                if let pasteNotice {
                    Text(pasteNotice).font(.amb(.caption)).foregroundStyle(Amb.destructive).padding(.horizontal, 14).padding(.top, 4)
                        .accessibilityIdentifier("composer.paste.notice")
                }
                if let uploads = model.uploads {
                    ComposerPastedUploads(uploads: uploads, target: target, text: composer.text)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                // The tools stack in a column on the left so the text box gets the row's width; the box is at least as
                // tall as the column, so a long draft shows more lines rather than the column wasting the height.
                VStack(spacing: 0) { composerTools }
                ComposerTextView(text: Binding(get: { composer?.visibleText ?? "" }, set: { composer?.visibleText = $0; fixtureTyping() }),
                                 focused: $focused, placeholder: placeholder, plainKeyboard: model.fixture?.plainKeyboard == true,
                                 onPasteItems: pasteItems, onSubmit: send, onPickerKey: mentionKey, pickerOpen: !suggestions.isEmpty,
                                 mentionTokens: composer?.presentMentions.map(\.visible) ?? [], onPasteText: pasteText, limitsInline: true,
                                 insertion: $insertion)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Amb.muted)
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .onTapGesture { focused = true }
                        #if os(macOS)
                        ComposerBlankFocusTarget { focused = true }
                        #endif
                    }
                VStack(spacing: 0) {
                    // While typing the on-screen keyboard covers the section bar: this button puts it away. Its place above
                    // Send is kept when it is hidden: a composer that changed height as the keyboard appeared stopped the
                    // list following its newest message (measured: the newest row left the screen on focus and after Send).
                    Button { focused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down").font(.body.weight(.semibold)).frame(width: 34, height: 32)
                    }
                    .accessibilityLabel("Hide keyboard")
                    .accessibilityIdentifier("composer.hideKeyboard")
                    .iconButton()
                    .opacity(focused ? 1 : 0)
                    .disabled(!focused)
                    .accessibilityHidden(!focused)
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundStyle(canSend ? Amb.primary : Amb.border)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("composer.send")
                        .iconButton()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(Amb.card)
        // Reserve the compose controls and suggestion viewport before the history takes remaining space.
        .layoutPriority(1)
        .task(id: target) {
            if let previous = composer { model.uploads?.detach(previous); previous.saveNow() }
            let composerModel = ComposerModel(target: target, store: store)
            composer = composerModel
            await composerModel.restore()
            // After the draft is back: finished uploads land in it and interrupted ones can be retried.
            model.uploads?.attach(composerModel)
            let workspaceId = target.workspaceId
            members.start(store: store, matches: { ($0.table == .members && $0.workspaceId == workspaceId) || $0.table == .profiles }) {
                async let people = store.reader.people(workspaceId: workspaceId)
                let members = try await store.reader.directoryMembers(workspaceId: workspaceId)
                let directory = try await people
                return members.map { MentionCandidate(member: $0, person: directory.person($0.npub)) }
            }
            let target = target
            storedDraft.start(store: store, matches: { $0.table == .drafts && $0.workspaceId == workspaceId }) {
                try await store.reader.draft(target)
            }
        }
        .onChange(of: storedDraft.value) { _, draft in composer?.adopt(draft) }
        .textAttachmentModal(item: $openAttachment) { subject in
            TextAttachmentModal(subject: subject, workspace: workspace) { next in
                guard let composer else { throw TextAttachmentError.missing }; try await composer.commitAttachment(next)
            }
        }
        .onChange(of: activeQuery) { _, _ in highlighted = 0 }
        .task(id: activeQuery) { await lookUpRecords(activeQuery) }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            // Picked photos go in at the caret as their Markdown (as the web inserts them), so they can be moved
            // in the text; the upload strips location and camera metadata as for a paste.
            let tokens = pasteItems(items.map(PendingAttachment.provider))
            if !tokens.isEmpty {
                let text = composer?.text ?? ""
                let lead = text.isEmpty || text.last?.isNewline == true ? "" : "\n"
                insertion = lead + tokens.joined(separator: "\n") + "\n"
                focused = true
                return
            }
            // No upload service for this composer (not connected here): stage them for the message as before.
            guard let staging = model.staging else { return }
            Task {
                for item in items { if let staged = await PendingAttachment.fromPicker(item, staging: staging) { composer?.attachments.append(staged) } }
            }
        }
        .onDisappear {
            if let composer { model.uploads?.detach(composer); composer.saveNow() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { composer?.saveNow() } }
        .onChange(of: model.chatPath) { _, _ in composer?.saveNow() }
    }

    /// Sample-data mode only: the responsiveness check starts its sync storm on the first keystroke so the storm
    /// overlaps typing.
    private func fixtureTyping() {
        guard let fixture = model.fixture, let store = model.store else { return }
        fixture.startStormIfRequested(store: store, workspaceId: target.workspaceId)
    }

    /// Photos, files (Mac) and mention, one above the other.
    @ViewBuilder private var composerTools: some View {
        PhotosPicker(selection: $photos, maxSelectionCount: 4, matching: .images) {
            Image(systemName: "photo").font(.body.weight(.semibold)).frame(width: 34, height: 32)
        }
        .accessibilityLabel("Attach photos")
        .accessibilityIdentifier("composer.photo")
        .iconButton()
        #if os(macOS)
        Button { attachingFiles = true } label: {
            Image(systemName: "paperclip").font(.amb(.body).weight(.semibold)).frame(width: 34, height: 32)
        }
        .accessibilityLabel("Attach files")
        .accessibilityIdentifier("composer.files")
        .iconButton()
        .fileImporter(isPresented: $attachingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, let composer else { return }
            let tokens = pasteItems(MacFiles.providers(copying: urls))
            guard !tokens.isEmpty else { return }
            if !(composer.text.last.map { $0.isWhitespace } ?? true), !composer.text.isEmpty { composer.text += " " }
            composer.text += tokens.joined()
        }
        #endif
        Button {
            guard let composer else { return }
            if !(composer.visibleText.last.map { $0.isWhitespace } ?? true) { composer.visibleText += " " }
            composer.visibleText += "@"
            focused = true
            model.refreshDirectory(workspace)
        } label: { Image(systemName: "at").font(.amb(.body).weight(.semibold)).frame(width: 34, height: 32) }
            .accessibilityLabel("Mention someone")
            .accessibilityIdentifier("composer.mention")
            .iconButton()
    }

    private var canSend: Bool {
        guard let composer else { return false }
        // A pasted item still uploading (or failed) holds its placeholder in the text: nothing is sent until it is resolved.
        guard !UploadToken.contains(in: composer.text) else { return false }
        return !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composer.attachments.isEmpty
    }

    /// An explicit Paste of images or files: uploads start for this composer's own target and their placeholders go
    /// in at the caret. Nothing to upload (or no workspace connection) leaves it an ordinary text paste.
    private func pasteItems(_ providers: [NSItemProvider]) -> [String] {
        guard let uploads = model.uploads, model.connection?.id == target.connectionId, workspace.id == target.workspaceId else { return [] }
        return uploads.paste(providers, target: target, appNpub: workspace.appNpub, context: target.threadId == nil ? "message" : "thread")
    }

    /// A paste of text: over 2,500 characters, or enough to push the field past 10,000, becomes a `.txt` attachment with
    /// the complete bytes. The field's text and selection stay as they were. Anything shorter is an ordinary paste.
    private func pasteText(_ string: String, selection: NSRange) -> TextPasteResult? {
        guard let composer, let staging = model.staging, model.connection?.id == target.connectionId, workspace.id == target.workspaceId else { return nil }
        let current = composer.visibleText as NSString
        let remaining = selection.location != NSNotFound && NSMaxRange(selection) <= current.length
            ? current.replacingCharacters(in: selection, with: "") : current as String
        guard TextAttachmentPolicy.decide(paste: string, existingCodePoints: TextAttachmentPolicy.codePoints(remaining),
                                          existingUTF8Bytes: remaining.utf8.count) == .file else { return nil }
        pasteNotice = nil
        guard string.utf8.count <= ComposerUploads.maxBytes else {
            pasteNotice = "That text is over 100 MB and cannot be attached."
            return TextPasteResult(undo: {}, redo: {})
        }
        do {
            let attachment = try TextAttachmentStaging.stage(text: string, name: TextAttachmentStaging.nextName(among: composer.attachments),
                                                             source: .paste, in: staging)
            composer.attachments.append(attachment)
            composer.saveNow()
            return TextPasteResult(
                undo: { composer.attachments.removeAll { $0.id == attachment.id } },
                redo: { if !composer.attachments.contains(where: { $0.id == attachment.id }) { composer.attachments.append(attachment) } })
        } catch {
            pasteNotice = (error as? LocalizedError)?.errorDescription ?? "The pasted text could not be saved on this device."
            return TextPasteResult(undo: {}, redo: {})
        }
    }

    private func send() {
        guard canSend, let composer, let outbox = model.outbox, let connection = model.connection,
              connection.id == target.connectionId, workspace.id == target.workspaceId else { return }
        composer.send(with: outbox, connection: connection, workspace: workspace, onEnqueued: onEnqueued)
    }
}

/// A member offered in the mention picker: the directory entry (its `label` is the shown name) and how they look.
struct MentionCandidate: Identifiable, Equatable, Sendable {
    let member: MemberRecord
    let person: PersonDisplay
    var id: String { member.npub }
}

struct MentionPicker: View {
    let suggestions: [MentionSuggestion]
    /// Directory entries, for the avatars of people and agents.
    let people: [MentionCandidate]
    var highlighted = 0
    let pick: (MentionSuggestion) -> Void
    /// One row's height, growing with the text size so the cap below always shows whole rows.
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = 46

    /// The list shows at most this many rows and scrolls for the rest, so the composer and the message above it stay
    /// visible with the keyboard up (the iPhone's list had taken over the screen).
    static var visibleRows: Int {
        #if os(iOS)
        7
        #else
        8
        #endif
    }

    var body: some View {
        let current = suggestions[min(highlighted, suggestions.count - 1)].id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        let selected = suggestion.id == current
                        Button { pick(suggestion) } label: {
                            HStack(spacing: 10) {
                                MentionIcon(mention: suggestion.mention, people: people)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.mention.label).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1)
                                    Text(suggestion.detail).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: rowHeight)
                            .background(selected ? Amb.selectedFill : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(suggestion.id)
                        .accessibilityLabel("\(suggestion.mention.label), \(suggestion.detail)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("mention.\(suggestion.mention.label)")
                    }
                }
            }
            // Seven is a ceiling: yield vertical space to the composer/keyboard on short phones.
            .frame(idealHeight: min(CGFloat(suggestions.count), CGFloat(Self.visibleRows)) * rowHeight,
                   maxHeight: min(CGFloat(suggestions.count), CGFloat(Self.visibleRows)) * rowHeight)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: current) { _, id in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
        }
        .padding(.vertical, 4)
        .background(Amb.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mention.list")
    }
}

/// A person's or agent's avatar, or the record kind's symbol (document, task, conversation, channel, scope).
struct MentionIcon: View {
    let mention: Mention
    let people: [MentionCandidate]
    var size: CGFloat = 32

    static func symbol(_ type: MentionType) -> String {
        switch type {
        case .agent, .person: "person.crop.circle"
        case .doc: "doc.text"
        case .task: "checkmark.circle"
        case .chat: "bubble.left.and.text.bubble.right"
        case .channel: "number"
        case .scope: "square.stack.3d.up"
        }
    }

    var body: some View {
        if mention.type.isActor, let person = people.first(where: { $0.member.npub == mention.npub })?.person {
            PersonAvatar(person: person).scaleEffect(size / 32).frame(width: size, height: size)
        } else {
            Image(systemName: Self.symbol(mention.type))
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(Amb.primary)
                .frame(width: size, height: size)
                .background(Amb.muted, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

/// The sample-data label under the navigation bar of a pushed screen only (a root already shows the shell banner).
struct PushedFixtureLabel: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.fixtureLabel() } else { content }
    }
}

/// People, agents and records picked for this message, as pills in the composer's strip (as on the web). Each is removable here,
/// or with Backspace in the field. The visible `@Name` and the structured mention are kept together by the composer.
struct ComposerMentionPills: View {
    let mentions: [Mention]
    let people: [MentionCandidate]
    let remove: (Mention) -> Void

    var body: some View {
        ForEach(mentions, id: \.self) { mention in
            HStack(spacing: 2) {
                MentionIcon(mention: mention, people: people, size: 20)
                Text(mention.label).font(.amb(.footnote).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1)
                    .padding(.leading, 4)
                Button { remove(mention) } label: {
                    Image(systemName: "xmark").font(.amb(.caption2).weight(.bold)).foregroundStyle(Amb.mutedForeground)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(mention.label)")
                .accessibilityIdentifier("composer.mention.remove")
            }
            .padding(.leading, 6)
            .background(Amb.card, in: Capsule())
            .overlay(Capsule().stroke(Amb.border, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mentioning \(mention.label)")
            .accessibilityIdentifier("composer.mention.pill")
        }
    }
}
