import AmbulandoCore
import PhotosUI
import SwiftUI

struct FamilySnapshot: Sendable, Equatable {
    var messages: [MessageRecord] = []
    var hasEarlier = false
    var pending: [OutboxItem] = []
    var people = PeopleDirectory()
    var dayStarts: [String: ChatDay] = [:]
    var lastDay: ChatDay?
}

/// The one conversation: a chronological list of messages with names and photos, and a large composer. It reads only
/// the bound thread from the local store; sync, drafts and the outbox are the same ones Ambulando uses, so the same
/// messages and replies appear in both apps.
struct FamilyConversationView: View {
    @Environment(AppModel.self) private var app
    @Environment(FamilyChatModel.self) private var family
    @Environment(\.scenePhase) private var scenePhase
    let binding: FamilyBinding
    @State private var snapshot = LiveQuery<FamilySnapshot>(initial: FamilySnapshot())
    @State private var limit = 100
    @State private var showSettings = false

    private var creating: Bool { binding.threadId == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            statusBanners
            if let store = family.boundStore, let workspace = family.boundEntry?.workspace {
                messageList(workspace: workspace)
                if creating {
                    EmptyView()
                } else if family.access.canSend || family.access == .checking, let target = binding.target {
                    FamilyComposer(target: target, workspace: workspace, store: store)
                } else if family.access == .conversationArchived {
                    FamilyNotice(tone: .warning, text: "This conversation was archived in Ambulando, so it is read-only here. You can still read it.").padding(12)
                }
            } else {
                Spacer()
                ProgressView("Opening your conversation…").font(.amb(.title3))
                Spacer()
            }
        }
        .tabletReadingWidth(900)
        .background(Amb.background)
        .sheet(isPresented: $showSettings) { FamilySettingsView(binding: binding) }
        .task(id: loadKey) { start() }
        .task(id: "\(loadKey)-sync-\(scenePhase == .active)") { await openForSync() }
        .task(id: creating ? binding.pendingCreation?.requestId : nil) {
            // Waiting for Tower to confirm a new conversation: look again until it is there.
            while creating, !Task.isCancelled {
                await family.resolvePendingCreation()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("family.conversation")
    }

    private var loadKey: String { "\(binding.threadId ?? "creating")-\(family.boundStore != nil)-\(limit)" }

    // MARK: Header and status

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(binding.conversationTitle.isEmpty ? "Family chat" : binding.conversationTitle)
                    .font(.amb(.title2).weight(.bold)).foregroundStyle(Amb.foreground).lineLimit(2)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("family.title")
                Text("\(binding.workspaceLabel) · \(binding.channelName)").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 24)).frame(width: 52, height: 52)
            }
            .accessibilityLabel("Settings").accessibilityIdentifier("family.settings")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Amb.card)
        .overlay(alignment: .bottom) { Divider().overlay(Amb.border) }
    }

    @ViewBuilder private var statusBanners: some View {
        if app.identity.npub != nil, !app.isUnlocked {
            FamilyNotice(tone: .info, text: "Locked. Unlock to send and to see new messages.").padding(.horizontal, 12).padding(.top, 8)
        }
        switch app.connectionStatus {
        case .connected: EmptyView()
        case .reconnecting:
            FamilyNotice(tone: .warning, text: "Reconnecting… What you write is kept and sent when the connection is back.").padding(.horizontal, 12).padding(.top, 8)
        case .lost:
            VStack(alignment: .leading, spacing: 6) {
                FamilyNotice(tone: .warning, text: "You are offline. What you write is saved on this device and sent when the connection is back.")
                Button("Try again now") { app.retryConnection() }.font(.amb(.body).weight(.semibold)).frame(minHeight: Amb.touchTarget)
            }
            .padding(.horizontal, 12).padding(.top, 8)
        }
    }

    // MARK: Messages

    private func messageList(workspace: WorkspaceRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if snapshot.value.hasEarlier {
                    Button { limit += 100 } label: { Text("Show earlier messages").font(.amb(.title3).weight(.semibold)).frame(maxWidth: .infinity, minHeight: 56) }
                        .accessibilityIdentifier("family.earlier")
                }
                if snapshot.loaded && snapshot.value.messages.isEmpty && snapshot.value.pending.isEmpty {
                    Text(creating ? "Starting your family chat…" : "No messages yet. Say hello!").font(.amb(.title3)).foregroundStyle(Amb.mutedForeground)
                        .frame(maxWidth: .infinity).padding(32)
                }
                ForEach(snapshot.value.messages, id: \.id) { message in
                    VStack(spacing: 0) {
                        if let day = snapshot.value.dayStarts[message.id] { DaySeparator(day: day) }
                        MessageRow(message: message, people: snapshot.value.people, workspace: workspace)
                    }
                }
                ForEach(snapshot.value.pending) { item in
                    VStack(spacing: 0) {
                        if item.id == snapshot.value.pending.first?.id, !snapshot.value.messages.isEmpty, snapshot.value.lastDay != ChatDay.today { DaySeparator(day: .today) }
                        OutboxRow(item: item, people: snapshot.value.people)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await refresh() }
    }

    private func start() {
        guard let store = family.boundStore else { return }
        let binding = binding, limit = limit
        let target = binding.target ?? binding.creationTarget
        snapshot.start(store: store, keepingValue: true, matches: { key in
            (key.workspaceId == binding.workspaceId || key.workspaceId == nil)
                && [.messages, .outbox, .members, .agents, .threads, .profiles, .access].contains(key.table)
                && (binding.threadId.map { key.affectsThread(workspaceId: binding.workspaceId, channelId: binding.channelId, threadId: $0) } ?? true)
        }) {
            async let pending = store.reader.outbox(target: target)
            async let directory = store.reader.people(connectionId: target.connectionId, workspaceId: target.workspaceId)
            var rows: [MessageRecord] = []
            if let threadId = binding.threadId {
                rows = try await store.reader.threadMessages(workspaceId: binding.workspaceId, threadId: threadId, limit: limit + 1)
            }
            let hasEarlier = rows.count > limit
            let shown = Array(rows.suffix(limit))
            MessageDisplayCache.shared.prepare(shown)
            let days = ChatDay.breaks(shown, id: \.id, time: \.createdAt)
            return FamilySnapshot(messages: shown, hasEarlier: hasEarlier, pending: try await pending, people: try await directory,
                                  dayStarts: days.starts, lastDay: days.last)
        }
    }

    /// Reads only the bound conversation from Tower (its thread, and the channel feed for live updates).
    private func openForSync() async {
        guard scenePhase == .active, let workspace = family.boundEntry?.workspace, let threadId = binding.threadId,
              app.selectedWorkspaceId == binding.workspaceId else { return }
        app.openChannel(binding.channelId, in: workspace)
        app.openThread(threadId, channelId: binding.channelId, in: workspace)
        app.markViewed(.thread, threadId, in: workspace)
    }

    private func refresh() async {
        guard let workspace = family.boundEntry?.workspace, let threadId = binding.threadId else { return }
        app.retryConnection()
        app.openThread(threadId, channelId: binding.channelId, in: workspace)
        await family.verifyNow()
        try? await Task.sleep(for: .milliseconds(700))
    }
}

/// A large Send, a Photo button and a roomy text box. The draft is saved as it is typed and survives a relaunch.
struct FamilyComposer: View {
    @Environment(AppModel.self) private var app
    @Environment(FamilyChatModel.self) private var family
    @Environment(\.scenePhase) private var scenePhase
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var composer: ComposerModel?
    @State private var storedDraft = LiveQuery<Draft?>(initial: nil)
    @State private var photos: [PhotosPickerItem] = []
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var canSend: Bool {
        guard let composer, !sending else { return false }
        return !OutboxRequest.normalizedBody(composer.text).isEmpty || !composer.attachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Amb.border)
            if let composer {
                @Bindable var composer = composer
                ComposerAttachmentStrip(mentions: [], people: [], removeMention: { _ in }, attachments: $composer.attachments, staging: app.staging,
                                        text: "", workspace: workspace, removeUploaded: { _ in })
                if let failure = composer.persistenceFailure {
                    FamilyNotice(tone: .error, text: failure).padding(.horizontal, 12).padding(.top, 6)
                }
                if let problem { FamilyNotice(tone: .warning, text: problem).padding(.horizontal, 12).padding(.top, 6).accessibilityIdentifier("family.send.problem") }
                HStack(alignment: .bottom, spacing: 10) {
                    PhotosPicker(selection: $photos, maxSelectionCount: 4, matching: .images) {
                        VStack(spacing: 2) {
                            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 26))
                            Text("Photo").font(.amb(.caption).weight(.semibold))
                        }
                        .frame(width: 64, height: 60)
                    }
                    .accessibilityLabel("Add a photo").accessibilityIdentifier("family.photo")
                    TextField("Write a message", text: $composer.text, axis: .vertical)
                        .lineLimit(1...5).font(.amb(.title3)).focused($focused)
                        .padding(.horizontal, 14).padding(.vertical, 14)
                        .frame(minHeight: 60)
                        .background(Amb.muted, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityIdentifier("family.field")
                    Button { send(composer) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "paperplane.fill").font(.system(size: 24))
                            Text("Send").font(.amb(.headline))
                        }
                        .foregroundStyle(canSend ? Amb.primaryForeground : Amb.mutedForeground)
                        .frame(minWidth: 84, minHeight: 60)
                        .background(canSend ? Amb.primary : Amb.muted, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send").accessibilityIdentifier("family.send")
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .background(Amb.card)
        .layoutPriority(1)
        .task(id: target) {
            composer?.saveNow()
            let next = ComposerModel(target: target, store: store)
            composer = next
            await next.restore()
            let target = target, workspaceId = target.workspaceId
            storedDraft.start(store: store, matches: { $0.table == .drafts && $0.workspaceId == workspaceId }) { try await store.reader.draft(target) }
        }
        .onChange(of: storedDraft.value) { _, draft in composer?.adopt(draft) }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            guard let staging = app.staging else { return }
            Task { for item in items { if let staged = await PendingAttachment.fromPicker(item, staging: staging) { composer?.attachments.append(staged) } } }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { composer?.saveNow() } }
        .onDisappear { composer?.saveNow() }
    }

    private func send(_ composer: ComposerModel) {
        sending = true; problem = nil
        Task {
            defer { sending = false }
            // The bound target is checked with Tower first; offline, the cached target must look right and the message is queued.
            guard await family.prepareToSend() else {
                problem = "This message was not sent: the family chat is not available any more. Your text is kept here."
                return
            }
            guard let outbox = app.outbox, let connection = app.connection, connection.id == target.connectionId, workspace.id == target.workspaceId else {
                problem = "Not connected yet. Your text is kept here."
                return
            }
            composer.send(with: outbox, connection: connection, workspace: workspace)
        }
    }
}

/// `Notice` at a size people can read.
struct FamilyNotice: View {
    let tone: Notice.Tone
    let text: String
    var body: some View {
        let (fg, bg, icon): (Color, Color, String) = switch tone {
        case .info: (Amb.info, Amb.infoBackground, "info.circle")
        case .warning: (Amb.warning, Amb.warningBackground, "exclamationmark.triangle")
        case .error: (Amb.destructive, Amb.destructiveBackground, "xmark.octagon")
        case .success: (Amb.success, Amb.successBackground, "checkmark.circle")
        }
        Label(text, systemImage: icon).font(.amb(.callout)).foregroundStyle(fg).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
