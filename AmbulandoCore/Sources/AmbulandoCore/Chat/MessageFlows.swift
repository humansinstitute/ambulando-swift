import Foundation

/// The web's per-message actions that need more than a local write: opening an Autopilot session, turning a conversation
/// into a ready task ("Get it done", sol `chat-get-it-done.js`) and branching a thread from a message.
public enum AutopilotSessionLink {
    /// The Autopilot session a message came from: `metadata.source == "autopilot_session"` with a UUID `session_id`
    /// (sol `getAutopilotSessionId`).
    public static func sessionId(in raw: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let metadata = object["metadata"] as? [String: Any],
              (metadata["source"] as? String)?.trimmingCharacters(in: .whitespaces) == "autopilot_session",
              let id = (metadata["session_id"] as? String)?.trimmingCharacters(in: .whitespaces), UUID(uuidString: id) != nil else { return nil }
        return id.lowercased()
    }

    /// `<autopilot origin>/live/<session>` (sol `getAutopilotLiveSessionUrl`); only http(s) addresses.
    public static func url(sessionId: String, autopilot address: String) -> URL? {
        guard UUID(uuidString: sessionId) != nil, let base = URL(string: address.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(base.scheme?.lowercased() ?? ""), base.host != nil else { return nil }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.path = "/live/\(sessionId.lowercased())"; parts?.query = nil; parts?.fragment = nil
        return parts?.url
    }

    /// The address of the agent that wrote the message, from the personal agent launchers: only that agent's own address is
    /// ever used, so a session link never opens another agent's host.
    public static func address(forSender sender: String?, launchers: [PersonalAgentLauncher]) -> String? {
        guard let sender, !sender.isEmpty else { return nil }
        return launchers.first { $0.npub == sender && !$0.address.isEmpty }?.address
    }

    /// The workspace's Autopilot address from the workspace record's metadata (`wingman_harness_url` / `autopilot_url`).
    public static func address(inWorkspace raw: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
        let metadata = (object["metadata"] as? [String: Any]) ?? ((object["descriptor"] as? [String: Any])?["metadata"] as? [String: Any]) ?? [:]
        return [metadata["wingman_harness_url"], metadata["autopilot_url"]].compactMap { $0 as? String }.first { !$0.isEmpty }
    }
}

public enum GetItDone {
    public enum Output: String, CaseIterable, Sendable {
        case chatResponse = "chat_response", doc, task
        public var label: String { switch self { case .chatResponse: "Chat response"; case .doc: "Doc"; case .task: "Task" } }
        var instruction: String {
            switch self {
            case .chatResponse: "Post the final response back into the source chat thread."
            case .doc: "Create and attach the linked document deliverable."
            case .task: "Create the follow-up task needed to complete this work."
            }
        }
    }

    public static let excerptLimit = 256

    /// Newest first, `Sender: text`, cut at the limit (sol `buildChatGetItDoneExcerpt`).
    public static func excerpt(_ messages: [(sender: String, body: String)], limit: Int = excerptLimit) -> String {
        let joined = messages.reversed().map { "\($0.sender): \($0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "[no text]" : $0.body.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
        let max = Swift.max(32, limit)
        guard joined.count > max else { return joined }
        return String(joined.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The task description (sol `buildChatGetItDoneTaskDescription`); the source is a Flight Deck reference.
    public static func description(prompt: String, output: Output, extra: String, sourceReference: String,
                                   messages: [(sender: String, body: String)]) -> String {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines), cleanExtra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = excerpt(messages)
        return ["## Request", cleanPrompt.isEmpty ? "Get this chat thread done." : cleanPrompt, "",
                "## Source", sourceReference.isEmpty ? "Source chat thread link unavailable." : sourceReference, "",
                "## Output", output.instruction, "",
                "## Extra Instructions", cleanExtra.isEmpty ? "None." : cleanExtra, "",
                "## Latest Thread Excerpt", excerpt.isEmpty ? "No chat text available." : excerpt].joined(separator: "\n")
    }
}

extension WorkspaceSync {
    /// Starts a new thread from `branchPointMessageId` of `parentThreadId` (`POST …/threads/:t/branches`, as the web does) and
    /// stores it. The caller opens the returned thread.
    public func branchThread(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channelId: String, parentThreadId: String,
                             branchPointMessageId: String, recipientNpub: String?) async throws -> ThreadRecord {
        try await identity.requireReader(npub: connection.signerNpub)
        let api = api(origin: try TowerOrigin(connection.origin))
        var metadata: [String: Any] = ["source": "flightdeck_branch"]
        if let recipientNpub, !recipientNpub.isEmpty { metadata["inherited_agent_recipient_npub"] = recipientNpub }
        let body: [String: Any] = ["branch_point_message_id": branchPointMessageId, "client_request_id": "branch:\(UUID().uuidString.lowercased())",
                                   "metadata": metadata]
        let path = try TowerAPI.base(workspace.id) + "/channels/" + TowerAPI.uuid(channelId) + "/threads/" + TowerAPI.uuid(parentThreadId) + "/branches"
        let result = try await api.client.exchange(method: "POST", path: path, appNpub: workspace.appNpub,
                                                   jsonBody: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        guard (200..<300).contains(result.status) else { throw TowerError.malformed("branch (status \(result.status))") }
        guard let object = try JSONSerialization.jsonObject(with: result.body) as? [String: Any], let row = object["thread"] as? [String: Any] else {
            throw TowerError.malformed("branch")
        }
        let thread = try ThreadRecord(raw: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
        _ = try? await store.writer.upsertThreads(workspaceId: workspace.id, [thread])
        return thread
    }
}
