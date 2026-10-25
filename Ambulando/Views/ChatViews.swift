import AmbulandoCore
import PhotosUI
import SwiftUI

// MARK: Snapshots (plain values read off the main actor)

struct ChannelSnapshot: Sendable, Equatable {
    var title = ""
    var posts: [FeedPost] = []
    var pending: [OutboxItem] = []
    var names: [String: String] = [:]
    var historyComplete = false
    var extras = MessageExtras()
    /// Tower thread titles by thread id, shown on thread roots whose title differs from their text.
    var threadTitles: [String: String] = [:]
}

struct ThreadSnapshot: Sendable, Equatable {
    var title = ""
    var messages: [MessageRecord] = []
    var pending: [OutboxItem] = []
    var names: [String: String] = [:]
    var archived = false
    var extras = MessageExtras()
}

/// Reactions and unsent edits/deletes for the messages on screen.
struct MessageExtras: Sendable, Equatable {
    var reactions: [String: [ReactionRecord]] = [:]
    var writes: [String: [WriteItem]] = [:]
}

private func messageExtras(_ store: LocalStore, _ workspaceId: String, connectionId: String, ids: [String]) async throws -> MessageExtras {
    async let reactions = store.reader.reactions(workspaceId: workspaceId, targetIds: ids)
    async let writes = store.reader.writes(connectionId: connectionId, workspaceId: workspaceId)
    let wanted = Set(ids)
    let relevant = try await writes.filter { [.messageEdit, .messageDelete, .reactionAdd, .reactionRemove].contains($0.kind) && wanted.contains($0.targetId ?? "") }
    return MessageExtras(reactions: Dictionary(grouping: try await reactions, by: \.targetId), writes: Dictionary(grouping: relevant) { $0.targetId ?? "" })
}

private func names(_ store: LocalStore, _ workspaceId: String) async throws -> [String: String] {
    Dictionary(try await store.reader.members(workspaceId: workspaceId).map { ($0.npub, $0.label) }, uniquingKeysWith: { a, _ in a })
}

private func chatMatches(_ workspaceId: String) -> @Sendable (ChangeKey) -> Bool {
    { key in
        key.workspaceId == workspaceId && [.messages, .outbox, .members, .threads, .channels, .reactions, .writes].contains(key.table)
            || (key.table == .outbox && key.workspaceId == nil)
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

/// Keeps the newest message in view when the user sends one, or when one arrives while they are already at the
/// bottom. Reading older messages is never interrupted.
private struct FollowLatest: ViewModifier {
    let lastId: String?
    let pendingCount: Int
    /// Whether the end of the list is on screen, reported by `NewestSentinel` (scroll geometry is unreliable here:
    /// LazyVStack revises its size estimates while the newest rows stay visible).
    let nearBottom: Bool
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var lastPending = 0
    @State private var positioned = false
    /// The list was at the newest message when the keyboard started to hide (for example a context menu took focus).
    @State private var restoreOnKeyboard = false

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                restoreOnKeyboard = nearBottom
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                // The keyboard came back (menu closed, composer refocused): return to the newest message if the user was
                // there, instead of leaving it hidden behind the composer.
                guard restoreOnKeyboard || nearBottom else { return }
                restoreOnKeyboard = false
                Task { @MainActor in withAnimation(.snappy) { position.scrollTo(edge: .bottom) } }
            }
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
        Task { @MainActor in position.scrollTo(edge: .bottom) }
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
    /// Messages (the channel's conversation) or Threads (its conversations with replies, by latest activity).
    @SceneStorage("channel.pane") private var pane = ChannelPane.messages

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $pane) {
                Text("Messages").tag(ChannelPane.messages)
                Text("Threads").tag(ChannelPane.threads)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .accessibilityIdentifier("channel.pane")
            if pane == .threads {
                ChannelThreadsView(target: target, workspace: workspace, store: store)
            } else {
                messages
            }
        }
        .background(Amb.background)
        .modifier(PushedFixtureLabel(enabled: pushed))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
                        .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                if snapshot.loaded {
                    ChannelSyncNote(key: WorkspaceSync.messagesKey(workspace.id, target.channelId), historyComplete: snapshot.value.historyComplete)
                }
                ForEach(snapshot.value.posts) { post in
                    PostRow(post: post, names: snapshot.value.names, workspace: workspace, extras: snapshot.value.extras,
                            threadTitle: post.message.threadId.flatMap { snapshot.value.threadTitles[$0] })
                }
                ForEach(snapshot.value.pending) { item in
                    OutboxRow(item: item, names: snapshot.value.names)
                }
                if snapshot.loaded && snapshot.value.posts.isEmpty && snapshot.value.pending.isEmpty && snapshot.value.historyComplete {
                    Text("No messages yet. Start a conversation below.")
                        .font(.footnote).foregroundStyle(Amb.mutedForeground).frame(maxWidth: .infinity).padding(.vertical, 40)
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
            async let directory = names(store, target.workspaceId)
            async let titles = store.reader.threadTitles(workspaceId: target.workspaceId, channelId: target.channelId)
            let rows = try await posts
            MessageDisplayCache.shared.prepare(rows.map(\.message))
            let extras = try await messageExtras(store, target.workspaceId, connectionId: target.connectionId, ids: rows.map(\.id))
            return ChannelSnapshot(title: try await channel?.name ?? "", posts: rows, pending: try await pending,
                                   names: try await directory, historyComplete: try await sync?.complete ?? false, extras: extras,
                                   threadTitles: try await titles)
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

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let threadId = target.threadId { SyncErrorNote(key: WorkspaceSync.threadKey(workspace.id, threadId)) }
                if snapshot.value.archived { SyncNote(text: "This thread is archived. Replying reopens it.") }
                ForEach(Array(snapshot.value.messages.enumerated()), id: \.element.id) { index, message in
                    MessageCell(message: message, names: snapshot.value.names, workspace: workspace, extras: snapshot.value.extras)
                    if index == 0 && snapshot.value.messages.count > 1 {
                        Text("\(snapshot.value.messages.count - 1) \(snapshot.value.messages.count == 2 ? "reply" : "replies")")
                            .font(.caption.weight(.semibold)).foregroundStyle(Amb.mutedForeground)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Amb.muted.opacity(0.5))
                    }
                }
                ForEach(snapshot.value.pending) { item in OutboxRow(item: item, names: snapshot.value.names) }
                if snapshot.loaded && snapshot.value.messages.isEmpty {
                    SyncNote(text: isUnlocked ? "Loading thread…" : "This thread is not saved on this iPhone yet. Unlock to load it.")
                }
            }
            .padding(.bottom, 8)
            NewestSentinel(visible: $atNewest)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .modifier(FollowLatest(lastId: snapshot.value.pending.last?.id ?? snapshot.value.messages.last?.id,
                               pendingCount: snapshot.value.pending.count, nearBottom: atNewest))
        .scrollDismissesKeyboard(.interactively)
        .refreshable { if let thread = target.threadId { model.openThread(thread, channelId: target.channelId, in: workspace) } }
            Composer(target: target, workspace: workspace, store: store, placeholder: "Reply")
        }
        .background(Amb.background)
        .fixtureLabel()
        .navigationTitle(snapshot.value.title.isEmpty ? "Thread" : snapshot.value.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { start() }
        .onAppear {
            if let thread = target.threadId {
                model.openThread(thread, channelId: target.channelId, in: workspace)
                model.markViewed(.thread, thread, in: workspace)
            }
        }
        .onChange(of: snapshot.value.messages.map(\.id)) { _, ids in
            if let thread = target.threadId { model.refreshReactions(workspace, scope: thread, messageIds: ids) }
        }
    }

    private var isUnlocked: Bool { if case .unlocked = model.identity { true } else { false } }

    private func start() {
        guard let threadId = target.threadId else { return }
        let target = target, store = store
        snapshot.start(store: store, matches: chatMatches(target.workspaceId)) {
            async let thread = store.reader.thread(workspaceId: target.workspaceId, id: threadId)
            async let messages = store.reader.threadMessages(workspaceId: target.workspaceId, threadId: threadId, limit: 500)
            async let pending = store.reader.outbox(target: target)
            async let directory = names(store, target.workspaceId)
            let rows = try await messages
            MessageDisplayCache.shared.prepare(rows)
            let record = try await thread
            let title = record?.title.map(MentionCodec.plain) ?? rows.first.map { MentionCodec.plain($0.body) } ?? ""
            let extras = try await messageExtras(store, target.workspaceId, connectionId: target.connectionId, ids: rows.map(\.id))
            return ThreadSnapshot(title: String(title.prefix(60)), messages: rows, pending: try await pending,
                                  names: try await directory, archived: record?.archived ?? false, extras: extras)
        }
    }
}

// MARK: Rows

struct PostRow: View {
    let post: FeedPost
    let names: [String: String]
    let workspace: WorkspaceRecord
    let extras: MessageExtras
    var threadTitle: String? = nil

    var body: some View {
        if let thread = post.message.threadId {
            // Only the message opens the thread; reactions and status lines below it stay separately tappable.
            MessageCell(message: post.message, names: names, workspace: workspace, extras: extras,
                        route: ChatRoute.thread(workspaceId: workspace.id, channelId: post.message.channelId, threadId: thread),
                        replyCount: post.replyCount, lastReplyAt: post.lastReplyAt, threadTitle: threadTitle)
        } else {
            MessageCell(message: post.message, names: names, workspace: workspace, extras: extras)
        }
    }
}

struct MessageRow: View {
    let message: MessageRecord
    let names: [String: String]
    var bodyOverride: String?
    var workspace: WorkspaceRecord?

    private var sender: String {
        message.senderNpub.flatMap { names[$0] } ?? message.senderLabel ?? message.senderNpub.map(shortNpub) ?? "Unknown"
    }

    var body: some View {
        let display = MessageDisplayCache.shared.display(message)
        // Code, tables and images keep their own controls (copy, scroll, open), so such rows contain elements instead
        // of being read as a single combined label.
        let interactive = bodyOverride == nil && (display.blocks.map(RichBlocksInfo.hasControls) ?? false)
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: sender)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sender).font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground)
                    Text(display.time).font(.caption).foregroundStyle(Amb.mutedForeground)
                }
                if let bodyOverride {
                    if !bodyOverride.isEmpty { MessageBody(text: bodyOverride, muted: true) }
                } else if !message.body.isEmpty {
                    if let blocks = display.blocks { RichBlocksView(blocks: blocks, workspace: workspace) } else { MessageBody(plain: message.body) }
                }
                if let workspace {
                    ForEach(display.attachments, id: \.storageObjectId) { AttachmentView(attachment: $0, workspace: workspace) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
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
            Text(verbatim: plain).font(.body).foregroundStyle(muted ? Amb.mutedForeground : Amb.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Avatar: View {
    let name: String
    var body: some View {
        Text(String(name.first(where: { $0.isLetter || $0.isNumber }) ?? "?").uppercased())
            .font(.subheadline.weight(.semibold)).foregroundStyle(Amb.accentForeground)
            .frame(width: 34, height: 34)
            .background(Amb.accent, in: Circle())
            .accessibilityHidden(true)
    }
}

/// An unsent message, shown where it will appear, with its delivery state and the actions that apply to it.
struct OutboxRow: View {
    @Environment(AppModel.self) private var model
    let item: OutboxItem
    let names: [String: String]

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
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: names[item.signerNpub] ?? "You")
            VStack(alignment: .leading, spacing: 4) {
                Text(names[item.signerNpub] ?? "You").font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground)
                if !item.body.isEmpty { MessageBody(text: item.body, muted: true) }
                if !item.attachments.isEmpty {
                    Label("\(item.attachments.count) \(item.attachments.count == 1 ? "photo" : "photos")" + (item.attachments.allSatisfy(\.complete) ? "" : " (uploading)"),
                          systemImage: "photo").font(.caption).foregroundStyle(Amb.mutedForeground)
                }
                Label(status.text, systemImage: status.icon).font(.caption).foregroundStyle(status.tone)
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
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
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
    var text = "" { didSet { if text != oldValue { edited = true; scheduleSave() } } }
    private(set) var mentions: [Mention] = []
    @ObservationIgnored let target: ChatTarget
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private var edited = false
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
        edited = false
    }

    /// A draft written to the store by someone other than this composer (for example "Edit" on a message that was
    /// not sent) is adopted when the composer is empty, so the text appears where the user is looking.
    func adopt(_ draft: Draft?) {
        guard let draft, text.isEmpty, !draft.text.isEmpty else { return }
        // Stored times are rounded to milliseconds, so anything within 1 ms of the send counts as before it.
        if let sentAt, (draft.updatedAt ?? .distantPast) <= sentAt.addingTimeInterval(0.001) { return }
        mentions = draft.mentions
        text = draft.text
        edited = false
    }

    func pick(_ mention: Mention) {
        if !mentions.contains(mention) { mentions.append(mention) }
        text = MentionCodec.complete(text, with: mention)
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
        let draft = Draft(text: text, mentions: mentions.filter { text.contains($0.visible) }), target = target, store = store
        chain { try? await store.writer.saveDraft(target, draft) }
    }

    /// Photos chosen for the next message (already stripped and staged on the device).
    var attachments: [PendingAttachment] = []

    /// Hands the composed text to the outbox (which clears the stored draft in the same transaction).
    func send(with outbox: OutboxSender, connection: ConnectionRecord, workspace: WorkspaceRecord) {
        debounce?.cancel()
        debounce = nil
        let text = text, mentions = mentions, target = target, attachments = attachments
        sentAt = Date()
        self.text = ""
        self.mentions = []
        self.attachments = []
        edited = false
        chain {
            do { try await outbox.send(text: text, mentions: mentions, target: target, connection: connection, workspace: workspace, attachments: attachments) }
            catch {
                // The outbox write failed (for example, storage full): put the text back rather than lose it.
                await MainActor.run { [weak self] in if self?.text.isEmpty == true { self?.mentions = mentions; self?.text = text } }
            }
        }
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    let placeholder: String
    @State private var composer: ComposerModel?
    @State private var members = LiveQuery<[MemberRecord]>(initial: [])
    @State private var storedDraft = LiveQuery<Draft?>(initial: nil)
    @State private var photos: [PhotosPickerItem] = []
    @FocusState private var focused: Bool

    private var suggestions: [MemberRecord] {
        guard let composer, let query = MentionCodec.activeQuery(in: composer.text) else { return [] }
        let q = query.lowercased()
        return Array(members.value.filter { q.isEmpty || $0.label.lowercased().contains(q) }.prefix(6))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !suggestions.isEmpty, let composer {
                MentionPicker(members: suggestions) { composer.pick(Mention(member: $0)) }
            }
            Divider().overlay(Amb.border)
            if let composer {
                @Bindable var composer = composer
                ComposerAttachments(attachments: $composer.attachments, staging: model.staging)
            }
            HStack(alignment: .bottom, spacing: 8) {
                // While typing the keyboard covers the section bar: this slot puts the keyboard away (same frame, so the row
                // does not re-lay-out on focus). Photos can be attached again once it is down.
                if focused {
                    Button { focused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Hide keyboard")
                    .accessibilityIdentifier("composer.hideKeyboard")
                } else {
                    PhotosPicker(selection: $photos, maxSelectionCount: 4, matching: .images) {
                        Image(systemName: "photo").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Attach photos")
                    .accessibilityIdentifier("composer.photo")
                }
                Button {
                    guard let composer else { return }
                    if !(composer.text.last.map { $0.isWhitespace } ?? true) { composer.text += " " }
                    composer.text += "@"
                    focused = true
                    model.refreshDirectory(workspace)
                } label: { Image(systemName: "at").font(.body.weight(.semibold)).frame(width: 36, height: 36) }
                    .accessibilityLabel("Mention someone")
                    .accessibilityIdentifier("composer.mention")
                TextField(placeholder, text: Binding(get: { composer?.text ?? "" }, set: { composer?.text = $0; fixtureTyping() }), axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Amb.muted, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityIdentifier("composer.field")
                    .autocorrectionDisabled(model.fixture?.plainKeyboard == true)
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundStyle(canSend ? Amb.primary : Amb.border)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("composer.send")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(.bar)
        .task(id: target) {
            let model = ComposerModel(target: target, store: store)
            composer = model
            await model.restore()
            let workspaceId = target.workspaceId
            members.start(store: store, matches: { $0.table == .members && $0.workspaceId == workspaceId }) {
                try await store.reader.members(workspaceId: workspaceId)
            }
            let target = target
            storedDraft.start(store: store, matches: { $0.table == .drafts && $0.workspaceId == workspaceId }) {
                try await store.reader.draft(target)
            }
        }
        .onChange(of: storedDraft.value) { _, draft in composer?.adopt(draft) }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty, let staging = model.staging else { return }
            photos = []
            Task {
                for item in items { if let staged = await PendingAttachment.fromPicker(item, staging: staging) { composer?.attachments.append(staged) } }
            }
        }
        .onDisappear { composer?.saveNow() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { composer?.saveNow() } }
        .onChange(of: model.chatPath) { _, _ in composer?.saveNow() }
    }

    /// Sample-data mode only: the responsiveness check starts its sync storm on the first keystroke so the storm
    /// overlaps typing.
    private func fixtureTyping() {
        guard let fixture = model.fixture, let store = model.store else { return }
        fixture.startStormIfRequested(store: store, workspaceId: target.workspaceId)
    }

    private var canSend: Bool {
        guard let composer else { return false }
        return !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composer.attachments.isEmpty
    }

    private func send() {
        guard canSend, let composer, let outbox = model.outbox, let connection = model.connection,
              connection.id == target.connectionId, workspace.id == target.workspaceId else { return }
        composer.send(with: outbox, connection: connection, workspace: workspace)
    }
}

struct MentionPicker: View {
    let members: [MemberRecord]
    let pick: (MemberRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(members) { member in
                Button { pick(member) } label: {
                    HStack(spacing: 10) {
                        Avatar(name: member.label)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.label).font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground)
                            Text(member.mentionType == .agent ? "Agent" : "Person").font(.caption).foregroundStyle(Amb.mutedForeground)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mention.\(member.label)")
            }
        }
        .padding(.vertical, 4)
        .background(Amb.card)
    }
}

// MARK: Threads of a channel

enum ChannelPane: String { case messages, threads }

/// A channel's conversations with replies, newest activity first: title (or the root's text), who started it, the
/// latest reply and how many replies. Opening one pushes the thread on the Chat stack with the channel behind it.
struct ChannelThreadsView: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var snapshot = LiveQuery<ChannelThreadsSnapshot>(initial: ChannelThreadsSnapshot())

    var body: some View {
        List {
            ForEach(snapshot.value.threads) { thread in
                NavigationLink(value: ChatRoute.thread(workspaceId: workspace.id, channelId: target.channelId, threadId: thread.id)) {
                    ThreadSummaryRow(thread: thread, names: snapshot.value.names, unread: snapshot.value.unread.contains(thread.id))
                }
                .accessibilityIdentifier("threadlist.item")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if snapshot.loaded && snapshot.value.threads.isEmpty {
                EmptyNote(title: "No threads yet", systemImage: "bubble.left.and.text.bubble.right",
                          detail: "Replies to a message in this channel start a thread. Threads appear here by latest activity.")
                    .accessibilityIdentifier("threadlist.empty")
            }
        }
        .refreshable { model.openChannel(target.channelId, in: workspace, force: true) }
        .task {
            let w = workspace.id, c = target.channelId, store = store
            snapshot.start(store: store, matches: { $0.workspaceId == w && [.messages, .threads, .members, .viewStates].contains($0.table) }) {
                async let threads = store.reader.channelThreads(workspaceId: w, channelId: c)
                async let directory = names(store, w)
                async let states = store.reader.viewStates(workspaceId: w)
                let unread = Set(try await states.filter { $0.resourceType == .thread && ($0.unread || $0.needsAttention) }.map(\.resourceId))
                return ChannelThreadsSnapshot(threads: try await threads, names: try await directory, unread: unread)
            }
        }
    }
}

struct ChannelThreadsSnapshot: Sendable, Equatable {
    var threads: [ThreadSummary] = []
    var names: [String: String] = [:]
    var unread: Set<String> = []
}

struct ThreadSummaryRow: View {
    let thread: ThreadSummary
    let names: [String: String]
    let unread: Bool

    private func person(_ npub: String?) -> String { npub.flatMap { names[$0] } ?? npub.map(shortNpub) ?? "Someone" }

    var body: some View {
        let root = MentionCodec.plain(thread.rootBody).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = thread.title.map(MentionCodec.plain)?.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if unread { Circle().fill(Amb.brandOrange).frame(width: 7, height: 7).accessibilityLabel("Unread") }
                Text(title?.isEmpty == false ? title! : String(root.prefix(120)))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(2)
                Spacer(minLength: 4)
                Text(ChatTime.label(thread.lastActivityAt)).font(.caption).foregroundStyle(Amb.mutedForeground)
            }
            if let title, !title.isEmpty, !root.hasPrefix(title) {
                Text(root).font(.footnote).foregroundStyle(Amb.mutedForeground).lineLimit(2)
            }
            HStack(spacing: 6) {
                Label("\(thread.replyCount) \(thread.replyCount == 1 ? "reply" : "replies")", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(Amb.primary)
                Text("·").font(.caption).foregroundStyle(Amb.mutedForeground)
                Text("\(person(thread.latestSender)): \(MentionCodec.plain(thread.latestBody))")
                    .font(.caption).foregroundStyle(Amb.mutedForeground).lineLimit(1)
            }
            if thread.archived { Text("Archived").font(.caption2.weight(.semibold)).foregroundStyle(Amb.mutedForeground) }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The sample-data label under the navigation bar of a pushed screen only (a root already shows the shell banner).
struct PushedFixtureLabel: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.fixtureLabel() } else { content }
    }
}
