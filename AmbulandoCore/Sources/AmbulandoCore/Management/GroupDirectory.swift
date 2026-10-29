import Foundation

/// Local directory operations. No search term is sent to Tower or a public profile service.
public enum GroupDirectory {
    public static func search(_ rows: [AdministrationRow], query: String) -> [AdministrationRow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            term.isEmpty || [row.title, row.detail, row.id, row.fields["npub"] ?? ""].contains { $0.localizedCaseInsensitiveContains(term) }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public static func contains(_ group: AdministrationRow, npub: String) -> Bool {
        group.children.contains { $0.fields["npub"] == npub }
    }

    /// A stale graph is only a hint: Tower still checks the edge under its own authority.
    public static func attachmentState(parent: String, child: String, groups: [AdministrationRow]) -> String? {
        if parent == child { return "This group" }
        if groups.first(where: { $0.id == parent })?.childGroupIds.contains(child) == true { return "Already nested" }
        var visited = Set<String>(), pending = [child]
        while let id = pending.popLast() {
            if id == parent { return "Would create a cycle" }
            if visited.insert(id).inserted { pending += groups.first(where: { $0.id == id })?.childGroupIds ?? [] }
        }
        return nil
    }
}

extension ScopeChannelManager {
    /// Group membership is an idempotent edge. Refresh before an explicit retry, never replay creates blindly.
    /// This entry point only adds existing workspace members and therefore cannot change their role or type.
    public func addExistingGroupPerson(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, group: String, npub: String) async throws {
        _ = try AdministrationCommand.groupMember(group: group, npub: npub).request()
        try await refreshAdministration(connection, workspace, list: .members)
        try await refreshAdministration(connection, workspace, list: .groups)
        let members = try await store.reader.administrationRows(connection: connection.id, workspace: workspace.id, list: .members)
        let groups = try await store.reader.administrationRows(connection: connection.id, workspace: workspace.id, list: .groups)
        guard members.contains(where: { $0.fields["npub"] == npub }) else {
            throw ManagementError.invalid("This person is not in the workspace. Workspace enrolment is required before adding them to a group.")
        }
        guard let target = groups.first(where: { $0.id == group }) else { throw ManagementError.notFound("This group is no longer available.") }
        if GroupDirectory.contains(target, npub: npub) { return }
        try await administer(connection, workspace, command: .groupMember(group: group, npub: npub))
    }
}

extension ScopeChannelManager {
    /// Additive Tower contract: enrolment and group edge commit together, preserving any existing role/kind.
    /// Old servers refuse outsiders; deliberately no workspace-members POST fallback or automatic retry.
    public func enrolGroupPerson(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, group: String, npub: String, kind: String) async throws {
        _ = try AdministrationCommand.ensureGroupMember(group: group, npub: npub, kind: kind).request()
        try await refreshAdministration(connection, workspace, list: .groups)
        let groups = try await store.reader.administrationRows(connection: connection.id, workspace: workspace.id, list: .groups)
        guard let target = groups.first(where: { $0.id == group }) else { throw ManagementError.notFound("This group is no longer available.") }
        if GroupDirectory.contains(target, npub: npub) { return }
        do { try await administer(connection, workspace, command: .ensureGroupMember(group: group, npub: npub, kind: kind)) }
        catch ManagementError.notFound {
            throw ManagementError.notFound("Tower could not add this identity. This server may not support safe workspace enrolment yet, or the group changed. Refresh and check before trying again. Your draft is retained.")
        }
    }
}
