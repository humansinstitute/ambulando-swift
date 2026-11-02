import Foundation

extension WriteSender {
    /// One durable row owns both steps. A failed second step remains visible and retries without repeating state.
    /// Tower currently ignores row_version on these routes; compare observed fields locally and preserve unrelated
    /// metadata, matching the existing edit guard. This cannot provide an atomic compare-and-set on an older Tower.
    func sendTaskBoardChange(_ item: WriteItem, api: TowerAPI, client: TowerClient) async throws -> WriteOutcome {
        let p = item.payloadObject
        guard let id = item.targetId, let actionString = p["action"] as? String,
              let action = TaskBoardAction(rawValue: actionString) else {
            return .permanent(status: nil, code: nil, message: "Missing board action.")
        }
        let path = try "/api/v4/flightdeck-pg/workspaces/" + TowerAPI.uuid(item.workspaceId) + "/tasks/" + TowerAPI.uuid(id)
        var current = try await api.task(workspaceId: item.workspaceId, appNpub: item.appNpub, taskId: id)
        let state = p["state"] as? String
        let assignee = p["assignee"] as? String
        let schedule = p["scheduled_for"] as? String
        guard (action == .today && state == nil && schedule != nil && assignee == nil)
                || (action != .today && state == action.rawValue && schedule == nil),
              action != .ready || (assignee.map(NostrKeys.isValidNpub) == true) else {
            return .permanent(status: nil, code: nil, message: "Invalid board action.")
        }
        if p["force"] as? Bool != true {
            if let state, current.state != state && current.state != p["base_state"] as? String {
                return .conflict(message: "Someone else moved this task. Review its status before applying the board action.")
            }
            if let assignee, (current.assignedToNpub ?? "") != assignee && (current.assignedToNpub ?? "") != p["base_assignee"] as? String {
                return .conflict(message: "Someone else reassigned this task. The board action is kept.")
            }
            if let schedule, (current.boardScheduledFor ?? "") != schedule && (current.boardScheduledFor ?? "") != p["base_schedule"] as? String {
                return .conflict(message: "Someone else rescheduled this task. The board action is kept.")
            }
        }
        func send(_ method: String, _ suffix: String, _ body: [String: Any]) async throws -> (status: Int, body: Data) {
            try await client.exchange(method: method, path: path + suffix, appNpub: item.appNpub,
                                      jsonBody: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        }
        func task(_ data: Data) throws -> TaskRecord {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = object["task"] else { throw TowerError.malformed("task") }
            let value = try TaskRecord(raw: JSONSerialization.data(withJSONObject: raw))
            guard value.workspaceId == item.workspaceId, value.id == id else { throw TowerError.malformed("task") }
            return value
        }
        if let state, current.state != state {
            let response = try await send("POST", "/state", ["state": state, "row_version": current.rowVersion])
            guard (200..<300).contains(response.status) else {
                return Self.classify(status: response.status, body: response.body, attempts: item.attempts + 1, what: "move this task")
            }
            current = try task(response.body)
            // Preserve accepted state even if the following assignment PATCH is refused or interrupted.
            _ = try await store.writer.upsertTasks(workspaceId: item.workspaceId, [current])
        }
        var body: [String: Any] = ["row_version": current.rowVersion]
        if let assignee, (current.assignedToNpub ?? "") != assignee { body["assigned_to_npub"] = assignee.isEmpty ? NSNull() : assignee as Any }
        if let schedule, current.boardScheduledFor != schedule {
            var metadata = current.boardMetadata
            metadata["scheduled_for"] = schedule
            body["metadata"] = metadata
        }
        if body.count > 1 {
            let response = try await send("PATCH", "", body)
            guard (200..<300).contains(response.status) else {
                return Self.classify(status: response.status, body: response.body, attempts: item.attempts + 1,
                                     what: "finish this board action (its status may already have changed)")
            }
            current = try task(response.body)
        }
        var ack = WriteAcknowledgement(); ack.tasks = [current]
        return .done(ack)
    }
}
