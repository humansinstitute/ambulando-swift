import AmbulandoCore
import SwiftUI

/// The web's message menu actions that go beyond a local write: Get it done, Branch from here, Autopilot Link.
extension AppModel {
    /// Starts a thread from `message` (Tower `…/threads/:t/branches`) and opens it over the current screen.
    func branch(from message: MessageRecord, in workspace: WorkspaceRecord, recipient: String?, effectiveThreadId: String? = nil) {
        guard let sync, let connection, let parent = effectiveThreadId ?? message.threadId, workspace.id == selectedWorkspace?.id else {
            notice = "Open this message from a conversation to branch it."
            return
        }
        notice = "Branching…"
        Task { @MainActor in
            do {
                let thread = try await sync.branchThread(connection, workspace, channelId: message.channelId, parentThreadId: parent,
                                                         branchPointMessageId: message.id, recipientNpub: recipient)
                notice = nil
                focusThread(ThreadFocus(workspaceId: workspace.id, channelId: thread.channelId, threadId: thread.id))
            } catch {
                notice = "Could not branch this thread: \(error.localizedDescription)"
            }
        }
    }

    /// Renames a conversation through Tower (`PATCH …/threads/:t`). Throws what the rename sheet shows: a refusal, a conflict
    /// with another rename, being offline or locked. On success the stored thread follows, so the header, the channel's
    /// thread rows and Deck show the new title without a refresh.
    func renameThread(_ threadId: String, to title: String, in workspace: WorkspaceRecord, originalTitle: String?, rowVersion: Int?) async throws {
        guard let sync, let connection, store != nil, workspace.id == selectedWorkspace?.id else {
            throw ManagementError.unexpected("Open this thread from its own workspace to rename it.")
        }
        _ = try await sync.renameThread(connection, workspace, threadId: threadId, title: title, rowVersion: rowVersion, originalTitle: originalTitle)
    }

    /// The Autopilot live-session address for a message that came from an Autopilot session.
    func autopilotURL(for message: MessageRecord, in workspace: WorkspaceRecord) async -> URL? {
        guard let session = AutopilotSessionLink.sessionId(in: message.raw) else { return nil }
        if let address = AutopilotSessionLink.address(inWorkspace: workspace.raw), let url = AutopilotSessionLink.url(sessionId: session, autopilot: address) { return url }
        // Otherwise the address of the agent that wrote the message (never another agent's).
        guard let store, let connection else { return nil }
        let saved = try? await store.reader.state(WorkspaceSync.personalAgentsKey(connection.id, workspace.id))
        let launchers = saved.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([PersonalAgentLauncher].self, from: $0) } ?? []
        guard let address = AutopilotSessionLink.address(forSender: message.senderNpub, launchers: launchers) else { return nil }
        return AutopilotSessionLink.url(sessionId: session, autopilot: address)
    }
}

/// "Get it done": turns the conversation into a ready task with its source, output type and instructions.
struct GetItDoneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: MessageRecord
    let workspace: WorkspaceRecord
    @State private var title = ""
    @State private var instructions = ""
    @State private var output = GetItDone.Output.chatResponse
    @State private var assignee: String?
    @State private var members: [MemberRecord] = []
    @State private var thread: [(sender: String, body: String)] = []
    @State private var failure: String?

    private var rootId: String { message.threadSourceId ?? message.threadId ?? message.id }
    private var source: String { "@[Chat thread](mention:chat:\(message.channelId)#\(rootId))" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("What should happen?", text: $title, axis: .vertical).accessibilityIdentifier("getitdone.title")
                    Picker("Output", selection: $output) {
                        ForEach(GetItDone.Output.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Assignee", selection: $assignee) {
                        Text("Unassigned").tag(Optional<String>.none)
                        ForEach(members) { Text($0.label + ($0.mentionType == .agent ? " (agent)" : "")).tag(Optional($0.npub)) }
                    }
                    TextField("Extra instructions (optional)", text: $instructions, axis: .vertical)
                }
                Section("From this conversation") {
                    Text(GetItDone.excerpt(thread)).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                }
                if let failure { Text(failure).foregroundStyle(Amb.destructive).font(.amb(.footnote)) }
            }
            .navigationTitle("Get it done")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create task") { create() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("getitdone.create")
                }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private func load() async {
        guard let store = model.store else { return }
        let people = try? await store.reader.people(workspaceId: workspace.id)
        members = (try? await store.reader.directoryMembers(workspaceId: workspace.id)) ?? []
        var rows = [message]
        if let threadId = message.threadId, let stored = try? await store.reader.threadMessages(workspaceId: workspace.id, threadId: threadId, limit: 6), !stored.isEmpty { rows = stored }
        thread = rows.suffix(6).map { (people?.name($0.senderNpub, senderLabel: $0.senderLabel) ?? $0.senderLabel ?? "Someone", MentionCodec.plain($0.body)) }
        // The person or agent being talked with, unless that is you.
        if assignee == nil, let sender = message.senderNpub, sender != model.identity.npub, members.contains(where: { $0.npub == sender }) { assignee = sender }
    }

    private func create() {
        let prompt = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = GetItDone.description(prompt: prompt, output: output, extra: instructions, sourceReference: source, messages: thread)
        var metadata: [String: any Sendable] = ["source_links": [["type": "chat", "id": "\(message.channelId)#\(rootId)"]]]
        var payload: [String: any Sendable] = ["channel_id": message.channelId, "title": String(prompt.prefix(200)), "description": description,
                                               "state": "ready", "priority": "sand"]
        if let thread = message.threadId { payload["thread_id"] = thread }
        if let assignee { payload["assigned_to_npub"] = assignee; metadata["assigned_to_npub"] = assignee }
        payload["metadata"] = metadata
        if model.submit(WriteIntent(kind: .taskCreate, targetId: nil, payload: payload), in: workspace) {
            model.notice = "Task queued: it is created in this channel and sent to Tower."
            dismiss()
        } else {
            failure = "Could not queue the task. Check the connection and try again."
        }
    }
}

extension AppModel {
    func showReminders() {
        guard let workspace = selectedWorkspace, selectedWorkspaceBoundary != nil else {
            notice = "Select a workspace to open Reminders."; return
        }
        if fileNappletNavigation?({ self.showReminders() }) == true { return }
        lockedView = nil
        focusedThread = nil
        selectContext(.home)
        tasksPath = [.reminders(workspaceId: workspace.id)]
        show(.tasks)
    }
}

/// Success and Open task are offered only after the server returns the persisted task.
struct ReminderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: MessageRecord
    let workspace: WorkspaceRecord
    var title: String? = nil
    @State private var saving = false
    @State private var saved: TaskRecord?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(saved == nil ? "Remind me" : "Saved to Reminders").font(.headline)
            Text(saved?.title ?? Reminders.title(title, body: message.body))
            Text("A Ready task assigned to you in your private Notes to Self board.").font(.caption)
            if let failure { Text(failure).foregroundStyle(Amb.destructive) }
            HStack {
                Button(saved == nil ? "Cancel" : "Close") { dismiss() }.disabled(saving)
                Spacer()
                if let saved {
                    Button("Open task") {
                        guard model.selectedWorkspace?.id == workspace.id else { return }
                        dismiss()
                        model.openRecord(kind: "task", id: saved.id)
                    }
                } else {
                    Button(saving ? "Saving…" : "Save reminder") { save() }.disabled(saving)
                        .accessibilityIdentifier("reminder.save")
                }
            }
        }
        .padding(24)
        .frame(minWidth: 340, idealWidth: 460)
        .task { if saved == nil { save() } }
    }

    private func save() {
        guard !saving, let sync = model.sync, let connection = model.connection,
              model.selectedWorkspace?.id == workspace.id, model.isUnlocked, model.identity.npub == connection.signerNpub else {
            failure = "Unlock and open this message in its own workspace to save a reminder."
            return
        }
        let key = "\(connection.id):\(workspace.id):\(message.id)"
        guard model.savingReminders.insert(key).inserted else { failure = "This message is already being saved."; return }
        let boundary = model.selectedWorkspaceBoundary
        saving = true; failure = nil
        Task { @MainActor in
            defer { saving = false; model.savingReminders.remove(key) }
            do {
                let task = try await sync.saveReminder(connection, workspace, message: message, title: title)
                guard boundary == model.selectedWorkspaceBoundary else { return }
                _ = try await model.store?.writer.upsertTasks(workspaceId: workspace.id, [task])
                saved = task
            } catch {
                guard boundary == model.selectedWorkspaceBoundary else { return }
                failure = "Could not confirm the reminder. Try again to check the same save: " + error.localizedDescription
            }
        }
    }
}
