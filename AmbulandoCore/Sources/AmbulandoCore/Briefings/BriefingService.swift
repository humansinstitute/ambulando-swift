import Foundation

public struct BriefingSnapshot: Sendable, Equatable {
    public let journal: DailyBriefing
    public let fileId: String
    public let channelId: String
    public let versionId: String
    public let authorLabel: String
    public let verifiedAt: Date
}

/// One selected workspace/account. Discovery and exact-version reads stay in the existing sync owner.
public struct BriefingService: Sendable {
    let api: TowerAPI
    let workspace: String
    let app: String
    let viewer: String
    var engine: SyncEngine?
    var cache: LocalContentSnapshot?
    private let slot = "daily-briefing.v1"
    private struct Saved: Codable {
        let bytes: Data; let file: String; let channel: String; let version: String; let author: String; let label: String; let verified: Date
    }

    public func cacheRevision() async -> String? { try? await cache?.epoch() }
    public func cached() async -> BriefingSnapshot? {
        let epoch = try? await cache?.epoch()
        guard let bytes = try? await cache?.read(slot), let saved = try? JSONDecoder().decode(Saved.self, from: bytes),
              let journal = try? DailyBriefing.parse(saved.bytes, workspace: workspace, owner: viewer, author: saved.author), epoch == (try? await cache?.epoch()) else { return nil }
        return BriefingSnapshot(journal: journal, fileId: saved.file, channelId: saved.channel, versionId: saved.version, authorLabel: saved.label, verifiedAt: saved.verified)
    }
    public func forget() async { await cache?.remove(slot) }

    private func grants(_ channel: String) async throws -> [BriefingGrant] {
        let o = try api.object(try await api.client.request(path: try TowerAPI.base(workspace) + "/channels/" + TowerAPI.uuid(channel) + "/grants", appNpub: app), "briefing grants")
        guard o["has_more"] as? Bool != true, o["partial"] as? Bool != true, o["next_cursor"] as? String == nil,
              let rows = o["grants"] as? [[String: Any]] else { throw BriefingError.unsafe }
        return try rows.map(BriefingGrant.init(row:))
    }

    public func load() async throws -> BriefingSnapshot {
        if let engine {
            return try await engine.perform("daily-briefing:\(workspace):\(viewer)", priority: .visible) { try await self.readVerified() }
        }
        return try await readVerified()
    }

    private func readVerified() async throws -> BriefingSnapshot {
        let epoch = try await cache?.epoch()
        let me = try api.object(try await api.client.request(path: try TowerAPI.base(workspace) + "/me", appNpub: app), "briefing owner")
        guard let identity = me["identity"] as? [String: Any], identity["workspace_owner_npub"] as? String == viewer,
              identity["workspace_id"] as? String == workspace, identity["app_npub"] as? String == app else { throw BriefingError.unsafe }
        let scopes = try await api.scopes(workspaceId: workspace, appNpub: app)
        guard scopes.allSatisfy({ $0.workspaceId == workspace }) else { throw BriefingError.invalid }
        var matches: [ChannelRecord] = []
        for scope in scopes where GoalsSpace.usable(scope) && BriefingAccess.active(scope.raw) {
            let channels = try await api.channels(workspaceId: workspace, scopeId: scope.id, appNpub: app)
            guard channels.allSatisfy({ $0.workspaceId == workspace && $0.scopeId == scope.id }) else { throw BriefingError.invalid }
            matches += channels.filter { BriefingAccess.isChannel($0, owner: viewer) }
        }
        guard matches.count <= 1 else { throw BriefingError.ambiguous }
        guard let channel = matches.first, let author = BriefingAccess.metadata(channel.raw, owner: viewer) else { throw BriefingError.unavailable }
        let memberRows = try await api.client.list(path: try TowerAPI.base(workspace) + "/members", appNpub: app, key: "members")
        let members = try memberRows.map { try MemberRecord(workspaceId: workspace, raw: $0) }
        guard members.allSatisfy({ $0.workspaceId == workspace }) else { throw BriefingError.invalid }
        try BriefingAccess.verify(grants: try await grants(channel.id), members: members, owner: viewer, author: author)
        let fileRows = try await api.client.list(path: try TowerAPI.base(workspace) + "/channels/" + TowerAPI.uuid(channel.id) + "/files", appNpub: app, key: "files")
        let listed = try fileRows.map(FileRecord.init(raw:))
        guard listed.allSatisfy({ $0.workspaceId == workspace && $0.channelId == channel.id }) else { throw BriefingError.invalid }
        let files = listed.filter { !$0.archived && BriefingAccess.active($0.raw) && BriefingAccess.matchesMIME($0.contentType) && BriefingAccess.metadata($0.raw, owner: viewer) == author }
        guard files.count <= 1 else { throw BriefingError.ambiguous }
        guard let candidate = files.first else { throw BriefingError.unavailable }
        let base = try TowerAPI.base(workspace) + "/files/" + TowerAPI.uuid(candidate.id)
        let o = try api.object(try await api.client.request(path: base, appNpub: app), "briefing file")
        guard let row = o["file"] as? [String: Any] else { throw BriefingError.invalid }
        let file = try FileRecord(raw: rawJSON(row))
        guard let storage = (row["object"] as? [String: Any])?["storage_object"] as? [String: Any],
              storage["is_public"] as? Bool == false else { throw BriefingError.unsafe }
        guard file.workspaceId == workspace, file.id == candidate.id, file.channelId == channel.id, !file.archived,
              BriefingAccess.active(file.raw), BriefingAccess.matchesMIME(file.contentType), BriefingAccess.metadata(file.raw, owner: viewer) == author,
              let version = lowerUUID(row["current_version_id"] as? String), let hash = file.sha256, hash.count == 64,
              let size = file.sizeBytes, size > 0, size <= 4 * 1024 * 1024 else { throw BriefingError.invalid }
        let bytes = try await api.client.request(path: base + "/versions/" + version + "/object", appNpub: app)
        guard bytes.count == size, SHA256Hex.of(bytes) == hash else { throw BriefingError.invalid }
        let journal = try DailyBriefing.parse(bytes, workspace: workspace, owner: viewer, author: author)
        // Revalidate access after reading; a grant change during a refresh must not publish a newly unsafe snapshot.
        try BriefingAccess.verify(grants: try await grants(channel.id), members: members, owner: viewer, author: author)
        let label = members.first { $0.npub == author }?.label ?? "Briefing author", verified = Date()
        if let epoch, try await cache?.epoch() != epoch { throw CancellationError() }
        if let cache {
            let saved = Saved(bytes: bytes, file: file.id, channel: channel.id, version: version, author: author, label: label, verified: verified)
            try? await cache.save(slot, JSONEncoder().encode(saved), dependencies: [file.id, channel.id], expectedEpoch: epoch)
        }
        if let epoch, try await cache?.epoch() != epoch { throw CancellationError() }
        return BriefingSnapshot(journal: journal, fileId: file.id, channelId: channel.id, versionId: version, authorLabel: label, verifiedAt: verified)
    }
}

extension WorkspaceSync {
    public func briefings(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord) throws -> BriefingService {
        guard workspace.ownerNpub == connection.signerNpub else { throw BriefingError.unsafe }
        var service = BriefingService(api: api(origin: try TowerOrigin(connection.origin)), workspace: workspace.id, app: workspace.appNpub, viewer: connection.signerNpub)
        service.engine = engine
        service.cache = LocalContentSnapshot(store: store, identity: identity, boundary: try WorkspaceBoundary(connection: connection, workspace: workspace))
        return service
    }
}
