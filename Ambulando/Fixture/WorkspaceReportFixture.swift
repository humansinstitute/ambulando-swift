import AmbulandoCore
import Foundation

/// Synthetic aggregates only, opt-in test host. No live service or human data.
enum WorkspaceReportFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureWorkspaceReport") }
    static var identity: [String: String] { ["workspace_id": FixtureTower.studio, "app_npub": FixtureTower.appNpub,
        "tower_service_npub": FixtureTower.appNpub, "workspace_service_npub": FixtureTower.appNpub, "workspace_owner_npub": FixtureTower.ana] }
    static func report(range: String = "30d") -> [String: Any] {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let end = formatter.date(from: "2026-11-23T00:00:00.000Z")!
        let days = ["7d": 7, "30d": 30, "90d": 90][range]
        return ["identity": identity, "format": "workspace-report-v1", "workspace_id": FixtureTower.studio, "range": range,
                "from": days.map { formatter.string(from: end.addingTimeInterval(-Double($0) * 86400)) as Any } ?? NSNull(),
                "to": formatter.string(from: end), "as_of": formatter.string(from: end), "timezone": "UTC", "complete": true,
                "channel_policy": "active-project-channels", "activity": ["messages": 123, "conversations": 17],
                "inventory": ["channels": 2, "conversations": 23, "documents": 4, "files": 9, "tasks": ["total": 12, "open": 7, "completed": 3, "archived": 2,
                    "by_state": ["new": 2, "ready": 1, "in_progress": 2, "review": 1, "done": 3, "archive": 1, "backlog": 0, "blocked": 1, "archived": 1]]],
                "channels": [["channel_id": FixtureTower.generalChannel, "scope_id": FixtureTower.scopeAmbulando, "name": "General", "scope_name": "Product", "messages": 100, "conversations": 12],
                             ["channel_id": FixtureTower.designChannel, "scope_id": FixtureTower.scopeAmbulando, "name": "Design", "scope_name": "Product", "messages": 23, "conversations": 5]],
                "ranking": ["total_channels": 2, "returned_channels": 2, "has_more": false, "other_messages": 0, "other_conversations": 0],
                "coverage": ["tasks_channels": 1, "documents_channels": 2, "files_channels": 2]]
    }
}
