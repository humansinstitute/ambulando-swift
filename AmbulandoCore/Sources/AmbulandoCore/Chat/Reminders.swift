import Foundation

/// Save-for-later uses the existing self DM and ordinary tasks. Labels confer no ownership.
public enum Reminders {
    public static func personalBoard(_ channels: [ChannelRecord], workspace: String, viewer: String) -> ChannelRecord? {
        let matches = channels.filter { channel in
            guard channel.workspaceId == workspace, channel.kind == "dm",
                  let row = try? JSONSerialization.jsonObject(with: channel.raw) as? [String: Any],
                  row["archived_at"] as? String == nil, row["deleted_at"] as? String == nil,
                  row["is_archived"] as? Bool != true,
                  !["deleted", "archived"].contains(row["record_state"] as? String ?? "") else { return false }
            return row["participant_npubs"] as? [String] == [viewer]
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func title(_ title: String?, body: String) -> String {
        let text = MentionCodec.plain(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = MentionCodec.plain(body).trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? "Saved conversation"
        return String((text.isEmpty ? (fallback.isEmpty ? "Saved conversation" : fallback) : text).prefix(200))
    }

    public static func description(body: String, channel: String, message: String) -> String {
        body + "\n\nSource: @[Original message](mention:chat:\(channel)#\(message))"
    }
}

extension WorkspaceSync {
    /// Fresh signed reads: never create a channel or infer ownership from its display name.
    public func remindersBoard(_ c: ConnectionRecord, _ w: WorkspaceRecord) async throws -> ChannelRecord {
        try await identity.requireSigner(npub: c.signerNpub)
        let api = api(origin: try TowerOrigin(c.origin))
        let members = try await api.members(workspaceId: w.id, appNpub: w.appNpub)
        guard members.contains(where: { $0.npub == c.signerNpub && $0.kind == "human" }) else {
            throw ManagementError.unexpected("Reminders requires your signed-in human identity.")
        }
        let scopes = try await api.scopes(workspaceId: w.id, appNpub: w.appNpub)
        var channels: [ChannelRecord] = []
        for scope in scopes where scope.workspaceId == w.id {
            channels += try await api.channels(workspaceId: w.id, scopeId: scope.id, appNpub: w.appNpub)
        }
        guard let board = Reminders.personalBoard(channels, workspace: w.id, viewer: c.signerNpub) else {
            throw ManagementError.unexpected("Your existing private Notes to Self board could not be identified. Open or create your self conversation first.")
        }
        return board
    }

    /// The frozen request survives ambiguous network failures/relaunch. Repeated saves of the same source reuse it.
    /// No foreign thread_id is attached to a task in the self channel; provenance remains a native source link.
    public func saveReminder(_ c: ConnectionRecord, _ w: WorkspaceRecord, message: MessageRecord, title: String?) async throws -> TaskRecord {
        let board = try await remindersBoard(c, w)
        let api = api(origin: try TowerOrigin(c.origin))
        guard message.workspaceId == w.id,
              let source = try await api.message(workspaceId: w.id, appNpub: w.appNpub, messageId: message.id),
              !source.deleted, source.channelId == message.channelId else {
            throw ManagementError.unexpected("The original message is no longer accessible.")
        }
        let snapshots = LocalContentSnapshot(store: store, identity: identity, boundary: try WorkspaceBoundary(connection: c, workspace: w))
        let key = "reminder-request:\(c.id):\(w.id):\(w.appNpub):\(c.signerNpub):\(message.channelId):\(message.id)"
        let body: Data
        if let data = try await snapshots.read(key) {
            let snapshot = try JSONDecoder().decode(ReminderRequest.self, from: data)
            guard snapshot.channel == board.id else {
                throw ManagementError.unexpected("The Notes to Self board changed during this save. The original request was retained; no task was created in the replacement board.")
            }
            body = snapshot.body
        } else {
            var chatTitle = title
            if let thread = source.threadId {
                chatTitle = try await api.thread(workspaceId: w.id, appNpub: w.appNpub, threadId: thread).title
            }
            var provenance: [String: Any] = ["version": 1, "message_id": source.id, "channel_id": source.channelId, "message_row_version": source.rowVersion]
            if let thread = source.threadId { provenance["thread_id"] = thread }
            body = try JSONSerialization.data(withJSONObject: [
                "client_request_id": UUID().uuidString.lowercased(), "title": Reminders.title(chatTitle, body: source.body),
                "description": Reminders.description(body: source.body, channel: source.channelId, message: source.id),
                "state": "ready", "priority": "sand", "assigned_to_npub": c.signerNpub,
                "metadata": ["ambulando_reminder": provenance]
            ], options: [.sortedKeys])
            let frozen = try JSONEncoder().encode(ReminderRequest(channel: board.id, body: body))
            try await snapshots.save(key, frozen)
            guard try await snapshots.read(key) == frozen else {
                throw ManagementError.unexpected("The reminder request could not be retained safely. Nothing was sent.")
            }
        }
        try await identity.requireSigner(npub: c.signerNpub)
        let data = try await api.client.request(method: "POST", path: try TowerAPI.base(w.id) + "/channels/" + TowerAPI.uuid(board.id) + "/tasks", appNpub: w.appNpub, jsonBody: body)
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = row["task"] as? [String: Any] else { throw TowerError.malformed("reminder task") }
        let task = try TaskRecord(raw: JSONSerialization.data(withJSONObject: raw))
        guard task.workspaceId == w.id, task.channelId == board.id, task.assignedToNpub == c.signerNpub else { throw TowerError.malformed("reminder task") }
        return task
    }
}

private struct ReminderRequest: Codable {
    let channel: String
    let body: Data
}
