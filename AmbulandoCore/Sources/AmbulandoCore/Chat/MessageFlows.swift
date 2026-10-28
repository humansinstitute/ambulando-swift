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

/// Renaming a conversation (web `saveThreadTitle`, `updateTowerPgThreadTitleFromLocal`): `PATCH …/threads/:t` with the
/// new `title` and the stored `row_version`. A confirmed online request, not queued: Tower decides who may rename, and the
/// person sees the result or the reason. A stale version is refreshed from Tower once and tried again, as the web does; a
/// second stale answer is reported as a conflict rather than overwritten blindly.
public enum ThreadTitle {
    public static let maxLength = 120

    /// The title the web sends: whitespace collapsed and trimmed. Throws the message shown beside the field.
    public static func normalized(_ value: String) throws -> String {
        let title = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !title.isEmpty else { throw ManagementError.invalid("Enter a thread title.") }
        guard title.count <= maxLength else { throw ManagementError.invalid("Thread titles can be up to \(maxLength) characters.") }
        return title
    }
}

extension WorkspaceSync {
    /// Renames `threadId` and stores Tower's answer, so the header, list rows and cached title follow at once.
    public func renameThread(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, threadId: String, title rawTitle: String,
                             rowVersion: Int?, originalTitle: String?) async throws -> ThreadRecord {
        let title = try ThreadTitle.normalized(rawTitle)
        guard let rowVersion, rowVersion > 0 else {
            throw ManagementError.conflict("The original thread version is unavailable. Your draft is kept; reopen the editor to load it.")
        }
        do { try await identity.requireSigner(npub: connection.signerNpub) } catch { throw ManagementError.locked }
        let api = api(origin: try TowerOrigin(connection.origin))
        let path = try TowerAPI.base(workspace.id) + "/threads/" + TowerAPI.uuid(threadId)

        func exchange(_ method: String, _ body: [String: Any]?) async throws -> (status: Int, object: [String: Any]) {
            let json = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            do {
                let result = try await api.client.exchange(method: method, path: path, appNpub: workspace.appNpub, jsonBody: json)
                return (result.status, ((try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any]) ?? [:])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ManagementError.offline(error.localizedDescription)
            }
        }
        func isStale(_ reply: (status: Int, object: [String: Any])) -> Bool {
            reply.status == 409 && ((reply.object["code"] as? String) ?? (reply.object["error"] as? String)) == "stale_row_version"
        }
        func patch(_ version: Int?) async throws -> (status: Int, object: [String: Any]) {
            var body: [String: Any] = ["title": title]
            if let version, version > 0 { body["row_version"] = version }
            return try await exchange("PATCH", body)
        }

        var reply = try await patch(rowVersion)
        if isStale(reply) {
            let fresh = try await exchange("GET", nil)
            guard (200..<300).contains(fresh.status) else {
                throw ManagementError.classify(status: fresh.status, object: fresh.object, operation: .renameThread)
            }
            guard let row = fresh.object["thread"] as? [String: Any], let version = row["row_version"] as? Int, version > 0 else {
                throw ManagementError.unexpected("Tower did not return the thread's current version. Nothing was changed.")
            }
            let current = try ThreadRecord(raw: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            _ = try await store.writer.upsertThreads(workspaceId: workspace.id, [current])
            guard current.title == originalTitle else {
                throw ManagementError.conflict("This thread was renamed elsewhere. Current title: “\(current.title ?? "Untitled")”. Your draft is kept. Cancel and reopen to edit the current title.")
            }
            // Only unrelated row-version churn may retry against the fresh version.
            reply = try await patch(version)
            if isStale(reply) { throw ManagementError.conflict("This thread was renamed elsewhere while you were saving. Reopen it and try again.") }
        }
        guard (200..<300).contains(reply.status) else {
            throw ManagementError.classify(status: reply.status, object: reply.object, operation: .renameThread)
        }
        guard let row = reply.object["thread"] as? [String: Any] else { throw ManagementError.unexpected("Tower's answer had no thread.") }
        let thread = try ThreadRecord(raw: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
        _ = try await store.writer.upsertThreads(workspaceId: workspace.id, [thread])
        return thread
    }
}
