import AmbulandoCore
import SwiftUI

/// Discussion routing and recovery belong to this exact account/workspace/goal. A failed response never retries POST.
struct GoalDiscussionControls: View {
    @Environment(AppModel.self) private var model
    let goals: GoalsModel
    let document: GoalDocument
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var choices = LiveQuery<ScopeChoice>(initial: ScopeChoice())
    @State private var picker: ChannelPick?
    @State private var expectedDefault: String?
    @State private var busy = false
    @State private var error: String?
    @State private var pending: String?
    @State private var receiptLoaded = false
    @State private var lookupFinished = false
    @State private var confirmSeparate = false
    private enum ChannelPick: String, Identifiable { case discussion, defaultChannel; var id: String { rawValue } }
    private var valid: Bool { model.isUnlocked && model.selectedWorkspaceBoundary == goals.boundary }
    private var editable: Bool { valid && document.goal.status != .archived }
    private var defaultLabel: String {
        guard let id = document.goal.defaultChannelId else { return "Choose a channel each time" }
        return choices.value.channelName(id).map { "#" + $0 } ?? "Saved channel is unavailable"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Discuss goal", systemImage: "bubble.left.and.bubble.right") { begin() }
                    .buttonStyle(.borderedProminent).disabled(!editable || busy || !receiptLoaded || pending != nil)
                    .accessibilityIdentifier("goal.discuss")
                if busy { ProgressView().controlSize(.small) }
            }
            HStack {
                Text("New discussions: \(defaultLabel)").font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground)
                Button("Change") { expectedDefault = document.goal.defaultChannelId; picker = .defaultChannel }.disabled(!editable || busy)
                    .accessibilityLabel("Change default discussion channel").accessibilityIdentifier("goal.defaultChannel")
            }
            if pending != nil {
                Text("A discussion may already have started. Find it before starting another.").font(.amb(.subheadline))
                Button("Find discussion") { find() }.disabled(!valid || busy).accessibilityIdentifier("goal.findDiscussion")
                if lookupFinished {
                    Button("Start a separate discussion…") { confirmSeparate = true }.disabled(!editable || busy)
                        .accessibilityIdentifier("goal.separateDiscussion")
                }
            }
            if let error { Text(error).font(.amb(.footnote)).foregroundStyle(Amb.destructive).accessibilityIdentifier("goal.discussion.error") }
        }
        .task(id: goals.boundary.id + ":" + document.id) { startChoices(); await loadReceipt() }
        .onDisappear { choices.stop() }
        .sheet(item: $picker) { mode in
            GoalDiscussionChannelPicker(choice: choices.value, allowsUnset: mode == .defaultChannel) { channel in
                if mode == .defaultChannel {
                    try await goals.setDefaultDiscussionChannel(goalFileId: document.id, expected: expectedDefault, channel: channel)
                } else if let channel { await create(channel) }
                picker = nil
            }
        }
        .confirmationDialog("Start a separate discussion?", isPresented: $confirmSeparate, titleVisibility: .visible) {
            Button("Start separate discussion", role: .destructive) {
                Task {
                    do {
                        guard valid else { throw CancellationError() }
                        try await store.writer.setState(try receiptKey(), nil)
                        pending = nil; lookupFinished = false; error = nil; begin()
                    } catch { self.error = GoalsModel.message(error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The earlier discussion could still exist, especially if access or the connection changed. This explicitly starts a different discussion; it does not delete the earlier one.") }
    }

    private func receiptKey() throws -> String {
        guard let connection = model.connection, valid else { throw CancellationError() }
        return try GoalDiscussionReceipt.key(connectionId: connection.id, workspaceId: workspace.id, goalFileId: document.id)
    }
    private func startChoices() {
        let w = workspace.id, store = store
        choices.start(store: store, matches: { $0.table == .access || ($0.workspaceId == w && [.channels, .scopes, .members].contains($0.table)) }) {
            try await scopeChoice(store, w)
        }
    }
    private func loadReceipt() async {
        do {
            let raw = try await store.reader.state(try receiptKey())
            guard valid else { return }
            pending = raw; receiptLoaded = true
        } catch { self.error = GoalsModel.message(error) }
    }
    private func begin() {
        guard editable, !busy, pending == nil else { return }
        error = nil
        if let id = document.goal.defaultChannelId {
            guard let channel = choices.value.channels.first(where: { $0.id == id }) else {
                error = "The saved default channel is unavailable. Change it explicitly before starting a discussion."
                return
            }
            Task { await create(channel) }
        } else { picker = .discussion }
    }
    private func create(_ channel: ChannelRecord) async {
        guard editable, !busy, let connection = model.connection, let sync = model.sync else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let receipt = try GoalDiscussionReceipt(workspaceId: workspace.id, goalFileId: document.id, channelId: channel.id, requestId: UUID().uuidString.lowercased())
            let key = try receiptKey(), store = store, boundary = goals.boundary, expectedDefault = document.goal.defaultChannelId
            let thread = try await goals.createDiscussion(goalFileId: document.id, channelId: channel.id, scopeId: channel.scopeId,
                expectedDefault: expectedDefault, requestId: receipt.requestId, beforeCreate: {
                    try await sync.identity.requireSigner(npub: connection.signerNpub)
                    guard await MainActor.run(body: { model.isUnlocked && model.selectedWorkspaceBoundary == boundary && model.connection?.id == connection.id }) else { throw CancellationError() }
                    try await store.writer.setState(key, receipt.encode())
                })
            guard valid else { return }
            try await open(thread, key: key)
        } catch {
            guard valid else { return }
            await loadReceipt()
            self.error = pending == nil ? GoalsModel.message(error) : "The result could not be confirmed. Find the discussion before trying another start. \(GoalsModel.message(error))"
        }
    }
    private func find() {
        guard valid, !busy, let pending else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let receipt = try GoalDiscussionReceipt.parse(pending, workspaceId: workspace.id, goalFileId: document.id)
                guard let thread = try await goals.findDiscussion(receipt) else {
                    guard valid else { return }
                    lookupFinished = true; error = "No accessible matching discussion was found. The saved request is kept; no new discussion was started."
                    return
                }
                try await open(thread, key: receiptKey())
            } catch {
                guard valid else { return }
                lookupFinished = true; self.error = "Could not find the earlier discussion. The saved request is kept. \(GoalsModel.message(error))"
            }
        }
    }
    private func open(_ thread: ThreadRecord, key: String) async throws {
        guard valid, thread.workspaceId == workspace.id else { throw CancellationError() }
        guard let channel = try await store.reader.channel(workspaceId: workspace.id, id: thread.channelId) else {
            throw GoalError.invalid("The discussion is saved, but its channel is not available on this device yet. Refresh and find it again.")
        }
        _ = try await store.writer.upsertThreads(workspaceId: workspace.id, [thread])
        guard valid else { throw CancellationError() }
        try await store.writer.setState(key, nil)
        pending = nil; lookupFinished = false
        // Route only to the authoritative thread's channel, never a current/global selection fallback.
        model.selectContext(WorkContext(scopeId: channel.scopeId, channelId: thread.channelId))
        model.openInChat(channelId: thread.channelId, threadId: thread.id)
    }
}

private struct GoalDiscussionChannelPicker: View {
    let choice: ScopeChoice
    let allowsUnset: Bool
    let choose: (ChannelRecord?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(allowsUnset ? "Default discussion channel" : "Choose a discussion channel").font(.title2)
            Text("Only channels available to this account are shown. Starting a discussion checks current access.").foregroundStyle(.secondary)
            List {
                if allowsUnset { Button("Ask each time") { select(nil) }.accessibilityIdentifier("goal.channel.unset") }
                ForEach(choice.channels) { channel in
                    Button("\(choice.scopeName(channel.scopeId) ?? "Scope") / #\(choice.channelName(channel.id) ?? channel.name)") { select(channel) }
                        .accessibilityIdentifier("goal.channel.\(channel.id)")
                }
            }.disabled(busy)
            if choice.channels.isEmpty { Text("No accessible channels are available. Refresh the workspace and try again.").foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(Amb.destructive) }
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button("Cancel") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction) }
        }.padding(20)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }
    private func select(_ channel: ChannelRecord?) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { try await choose(channel) } catch { self.error = GoalsModel.message(error) } }
    }
}

extension AppModel {
    /// Capture references before enqueue. The durable intent keeps its original goal/channel on retries.
    func goalCreationMetadata(source: ChatTarget?, workspace: WorkspaceRecord, channelId: String) async throws -> [String: any Sendable] {
        guard let source else { return [:] }
        guard let connection, let sync, isUnlocked, selectedWorkspace?.id == workspace.id,
              selectedWorkspace?.appNpub == workspace.appNpub, source.connectionId == connection.id,
              source.workspaceId == workspace.id, source.channelId == channelId, let threadId = source.threadId,
              let boundary = selectedWorkspaceBoundary else { throw GoalError.invalid("The discussion channel or account changed. Reopen the creation form.") }
        try await sync.identity.requireSigner(npub: connection.signerNpub)
        let api = try sync.goals(connection, workspace).api
        let metadata = try await api.threadGoalMetadata(workspaceId: workspace.id, appNpub: workspace.appNpub, threadId: threadId, expectedChannelId: channelId)
        guard isUnlocked, selectedWorkspaceBoundary == boundary, self.connection?.id == connection.id else { throw CancellationError() }
        var result: [String: any Sendable] = ["source_thread_id": threadId]
        if let goalId = try GoalAssociation.read(metadata) { result["ambulando_goal"] = ["version": 1, "goal_file_id": goalId] as [String: any Sendable] }
        return result
    }
}
