import Foundation

/// Web Kanban actions. State changes use /state; assignment and scheduling use the existing task PATCH.
public enum TaskBoardAction: String, Sendable, CaseIterable {
    case archive, done, blocked, ready, today
    public var label: String {
        switch self {
        case .archive: "Archive selected"
        case .done: "Mark selected done"
        case .blocked: "Mark selected blocked"
        case .ready: "Mark selected ready"
        case .today: "Move selected to today"
        }
    }

    public func intent(for task: TaskRecord, agent: String? = nil, date: Date = Date()) -> WriteIntent? {
        if self == .ready && (agent == nil || !NostrKeys.isValidNpub(agent!)) { return nil }
        var payload: [String: any Sendable] = ["action": rawValue, "task_title": task.title, "base_state": task.state,
            "base_assignee": task.assignedToNpub ?? "", "base_schedule": task.boardScheduledFor ?? ""]
        if self == .today {
            let formatter = ISO8601DateFormatter()
            payload["scheduled_for"] = String(formatter.string(from: date).prefix(10))
        } else { payload["state"] = rawValue }
        if self == .ready { payload["assignee"] = agent! }
        if self == .done || self == .archive { payload["assignee"] = "" }
        return WriteIntent(kind: .taskBoardChange, targetId: task.id, payload: payload)
    }
}

extension TaskRecord {
    public var boardMetadata: [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        return object?["metadata"] as? [String: Any] ?? [:]
    }
    public var boardScheduledFor: String? { boardMetadata["scheduled_for"] as? String }
}

/// A drag is bound to the exact account/connection/workspace. Ordinary text and cross-workspace drops are refused.
public struct TaskBoardDrag: Codable, Sendable {
    public let signer: String
    public let connection: String
    public let workspace: String
    public let app: String
    public let task: String
    public init(signer: String, connection: String, workspace: String, app: String, task: String) {
        self.signer = signer; self.connection = connection; self.workspace = workspace; self.app = app; self.task = task
    }
    public var text: String { "ambulando-task:" + String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
    public static func taskId(from text: String, signer: String, connection: String, workspace: String, app: String) -> String? {
        guard text.hasPrefix("ambulando-task:"), let value = try? JSONDecoder().decode(Self.self, from: Data(text.dropFirst(15).utf8)),
              value.signer == signer, value.connection == connection, value.workspace == workspace, value.app == app,
              UUID(uuidString: value.task) != nil else { return nil }
        return value.task
    }
}

public enum TaskBoardSelection {
    public static func togglingColumn(_ selected: Set<String>, ids: Set<String>) -> Set<String> {
        ids.isSubset(of: selected) ? selected.subtracting(ids) : selected.union(ids)
    }
}
