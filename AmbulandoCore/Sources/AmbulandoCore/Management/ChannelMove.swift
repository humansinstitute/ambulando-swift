import Foundation

/// A viewer-bound preview. Retain this exact value for a retry after an interrupted response.
public struct ChannelMovePreview: Sendable {
    public let channelId: String
    public let sourceScopeId: String
    public let destinationScopeId: String
    public let confirmationToken: String
    public let mutationId: String
    public let accessSummary: String
    public let warnings: [String]

    init(_ object: [String: Any], channelId: String, destination: String) throws {
        guard let p = object["preview"] as? [String: Any],
              lowerUUID(p["channel_id"] as? String) == channelId,
              let source = lowerUUID(p["source_scope_id"] as? String),
              lowerUUID(p["destination_scope_id"] as? String) == destination,
              let token = p["confirmation_token"] as? String, !token.isEmpty,
              let access = p["access_changes"] as? [String: Any],
              access["gained"] is [[String: Any]], access["lost"] is [[String: Any]],
              access["retained"] is [[String: Any]],
              access["source_scope_access"] is [[String: Any]], access["destination_scope_access"] is [[String: Any]],
              flexibleInt(access["direct_grant_count"]) != nil,
              access["direct_grants_preserved"] as? Bool == true,
              let warningRows = p["warnings"] as? [String] else {
            throw ManagementError.unexpected("Tower did not return a complete move preview. Refresh before trying again.")
        }
        self.channelId = channelId; sourceScopeId = source; destinationScopeId = destination
        confirmationToken = token; mutationId = UUID().uuidString.lowercased()
        // Render known human-facing access details; additive server metadata is tolerated.
        accessSummary = Self.accessDescription(access)
        warnings = warningRows
    }

    private static func accessDescription(_ access: [String: Any]) -> String {
        var lines: [String] = []
        for (key, label) in [("gained", "Gained channel access"), ("lost", "Lost channel access"), ("retained", "Retained channel access")] {
            let rows = access[key] as? [[String: Any]] ?? []
            lines.append(label + ": " + (rows.isEmpty ? "None" : rows.map { row in
                let name = row["label"] as? String ?? row["npub"] as? String ?? "Unidentified member"
                let permissions = (row["permissions"] as? [String] ?? []).map { $0.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
                return name + (permissions.isEmpty ? "" : " (" + permissions + ")")
            }.joined(separator: "\n")))
        }
        if let preserved = access["direct_grants_preserved"] as? Bool {
            lines.append(preserved ? "Direct channel grants: unchanged" : "Direct channel grants: review changes below")
        }
        if let count = flexibleInt(access["direct_grant_count"]) {
            lines.append("Unchanged direct grants: \(count)")
        }
        for (key, label) in [("source_scope_access", "Source scope discovery and management"),
                             ("destination_scope_access", "Destination scope discovery and management")] {
            if let rows = access[key] as? [[String: Any]] {
                lines.append(label + ": " + (rows.isEmpty ? "None" : rows.map { row in
                    let name = row["label"] as? String ?? "Workspace member"
                    let permissions = (row["permissions"] as? [String] ?? []).map { $0.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
                    return name + (permissions.isEmpty ? "" : " (" + permissions + ")")
                }.joined(separator: "\n")))
            }
        }
        return lines.joined(separator: "\n\n")
    }

}

extension ScopeChannelManager {
    public func previewChannelMove(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord,
                                   channelId: String, destinationScopeId: String) async throws -> ChannelMovePreview {
        let channel = try TowerAPI.uuid(channelId), destination = try TowerAPI.uuid(destinationScopeId)
        let object = try await send(connection, workspace, method: "POST",
                                    path: try TowerAPI.base(workspace.id) + "/channels/\(channel)/move-preview",
                                    body: ["destination_scope_id": destination], operation: .relocateChannel)
        return try ChannelMovePreview(object, channelId: channel, destination: destination)
    }

    /// Never updates scope optimistically. Identical retries use the same token and mutation ID.
    public func confirmChannelMove(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord,
                                   preview: ChannelMovePreview) async throws -> ChannelRecord {
        let object = try await send(connection, workspace, method: "POST",
                                    path: try TowerAPI.base(workspace.id) + "/channels/\(TowerAPI.uuid(preview.channelId))/move",
                                    body: ["destination_scope_id": preview.destinationScopeId,
                                           "confirmation_token": preview.confirmationToken, "mutation_id": preview.mutationId], operation: .relocateChannel)
        guard let row = object["channel"] as? [String: Any] else {
            throw ManagementError.unexpected("Tower's move response was incomplete. Retry this exact confirmation to check the saved result.")
        }
        let channel = try ChannelRecord(raw: JSONSerialization.data(withJSONObject: row))
        guard channel.workspaceId == workspace.id, channel.id == preview.channelId, channel.scopeId == preview.destinationScopeId else {
            throw ManagementError.unexpected("Tower's move response did not match this channel and destination. Refresh before continuing.")
        }
        try await store.writer.upsertChannels(workspaceId: workspace.id, scopeId: channel.scopeId, [channel], complete: false)
        return channel
    }
}

/// Directory hints only. Tower checks all permissions and lifecycle restrictions again at preview/commit.
public enum ChannelMoveEligibility {
    public static func supports(_ scope: ScopeRecord) -> Bool {
        let object = (try? JSONSerialization.jsonObject(with: scope.raw)) as? [String: Any] ?? [:]
        return !["dm", "system", "archive", "archived"].contains(scope.kind?.lowercased() ?? "")
            && (object["archived_at"] == nil || object["archived_at"] is NSNull)
    }
    public static func supports(_ channel: ChannelRecord, source: ScopeRecord?) -> Bool {
        guard channel.kind == nil || channel.kind == "channel", let source, supports(source), source.defaultChannelId != channel.id else { return false }
        return !SidebarNavigation.isDirectMessageChannel(channel)
    }
    public static func destination(_ scope: ScopeRecord, channel: ChannelRecord, membership: WorkspaceMembership?) -> Bool {
        scope.workspaceId == channel.workspaceId && scope.id != channel.scopeId && supports(scope)
            && (scope.canManage != false || membership?.isAdmin == true)
    }
}
