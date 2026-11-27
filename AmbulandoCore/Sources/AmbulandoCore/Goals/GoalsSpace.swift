import Foundation

/// Where goals live: one dedicated channel per owner, found by `metadata.system_key = ambulando.goals` and
/// `metadata.goals.owner_npub`. Tower authorizes a channel only through grants on that channel (never by scope or
/// workspace role), so a channel created with no other grants is readable by its creator alone; agents are added by
/// explicit channel grants the owner chooses. Nothing here is an NStack endpoint: it is channel create, channel grants
/// and Files.
///
/// The client never trusts the channel's label. Before every use it reads the channel's grants and refuses the channel
/// if anyone other than the owner and workspace agents holds access, so a channel someone else shared with the owner
/// and dressed up as a Goals space is never written to.
public enum GoalsSpace {
    public static let systemKey = "ambulando.goals"
    public static let channelName = "Goals"
    public static let homeScope = "Home"

    public static func metadata(owner: String) -> [String: Any] {
        ["system_key": systemKey, "goals": ["schema_version": 1, "owner_npub": owner]]
    }

    private static func raw(_ channel: ChannelRecord) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: channel.raw) as? [String: Any]) ?? [:]
    }

    public static func isOwnedBy(_ channel: ChannelRecord, viewer: String) -> Bool {
        let o = raw(channel)
        guard channel.kind == "channel", o["record_state"] as? String != "deleted", o["archived_at"] as? String == nil, o["is_archived"] as? Bool != true,
              let meta = o["metadata"] as? [String: Any] else { return false }
        return meta["system_key"] as? String == systemKey && (meta["goals"] as? [String: Any])?["owner_npub"] as? String == viewer
    }

    static func usable(_ scope: ScopeRecord) -> Bool {
        let o = (try? JSONSerialization.jsonObject(with: scope.raw) as? [String: Any]) ?? [:]
        return scope.kind != "dm" && o["archived_at"] as? String == nil && o["record_state"] as? String != "deleted"
    }

    /// The one scope named Home, when exactly one exists. A name is only a suggestion: the owner confirms it.
    public static func suggestedScope(_ scopes: [ScopeRecord]) -> ScopeRecord? {
        let homes = scopes.filter { usable($0) && $0.name == homeScope }
        return homes.count == 1 ? homes[0] : nil
    }
}

/// One workspace agent and what it may do in the Goals channel (nil: nothing).
public struct GoalsAgent: Sendable, Equatable, Identifiable {
    public let member: MemberRecord
    public let access: String?
    public var id: String { member.actorId }
    public init(member: MemberRecord, access: String?) { self.member = member; self.access = access }
}

public enum GoalsSpaceState: Sendable, Equatable {
    case ready(channel: ChannelRecord, agents: [GoalsAgent])
    /// No goals channel exists yet. `scopes` are the places a channel could be created, `suggested` the one named Home.
    case needsSetup(scopes: [ScopeRecord], suggested: ScopeRecord?, agents: [MemberRecord])
    /// A channel claims to hold the owner's goals but is shared beyond the owner and agents, or cannot be checked.
    case unsafe(String)
}

public struct GoalsChannelGrant: Sendable, Equatable {
    public let actorId: String?
    public let npub: String?
    public let isGroup: Bool
    public let access: String?

    public init(actorId: String?, npub: String?, isGroup: Bool, access: String?) { self.actorId = actorId; self.npub = npub; self.isGroup = isGroup; self.access = access }

    public init(row: [String: Any]) {
        let principal = row["principal"] as? [String: Any]
        actorId = ((principal?["actor_id"] ?? principal?["id"] ?? row["principal_id"]) as? String)?.lowercased()
        npub = principal?["npub"] as? String
        isGroup = row["principal_type"] as? String == "group" || principal?["type"] as? String == "group"
        access = row["access_level"] as? String
    }
}

public enum GoalsSpaceResolver {
    /// Decides what a channel's grants allow. Pure, so the safety rule is tested without a network.
    public static func classify(channel: ChannelRecord, grants: [GoalsChannelGrant], members: [MemberRecord], viewer: String) -> GoalsSpaceState {
        let agents = members.filter { $0.kind == "agent" }
        let agentIds = Set(agents.map(\.actorId))
        let ownerActorId = members.first { $0.npub == viewer }?.actorId
        var owner = false
        var access: [String: String?] = [:]
        for g in grants {
            if g.isGroup { return .unsafe("This Goals space is shared with a group, so it was not used. Remove the group’s access to use it.") }
            else if g.npub == viewer || (g.actorId != nil && g.actorId == ownerActorId) { owner = true }
            else if let id = g.actorId, agentIds.contains(id) { access[id] = g.access }
            else { return .unsafe("This Goals space is shared with someone other than you and your agents, so it was not used.") }
        }
        guard owner else { return .unsafe("You do not manage this Goals space, so it was not used.") }
        return .ready(channel: channel, agents: agents.map { GoalsAgent(member: $0, access: access[$0.actorId] ?? nil) })
    }
}

extension TowerAPI {
    public func channelGrants(workspaceId: String, appNpub: String, channelId: String) async throws -> [GoalsChannelGrant] {
        let o = try object(try await client.request(path: Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/grants", appNpub: appNpub), "channel grants")
        guard let rows = o["grants"] as? [[String: Any]] else { throw TowerError.malformed("channel grants") }
        return rows.map(GoalsChannelGrant.init(row:))
    }

    /// Resolves where this viewer's goals are, without writing anything.
    public func goalsSpace(workspaceId: String, appNpub: String, viewer: String) async throws -> GoalsSpaceState {
        let scopes = try await self.scopes(workspaceId: workspaceId, appNpub: appNpub).filter { $0.workspaceId == workspaceId }
        var named: [ChannelRecord] = []
        for scope in scopes where GoalsSpace.usable(scope) {
            named += try await channels(workspaceId: workspaceId, scopeId: scope.id, appNpub: appNpub)
                .filter { $0.workspaceId == workspaceId && $0.scopeId == scope.id && GoalsSpace.isOwnedBy($0, viewer: viewer) }
        }
        named.sort { ($0.createdAtSort, $0.id) < ($1.createdAtSort, $1.id) }
        let members = try await self.members(workspaceId: workspaceId, appNpub: appNpub)
        guard let channel = named.first else {
            return .needsSetup(scopes: scopes.filter(GoalsSpace.usable), suggested: GoalsSpace.suggestedScope(scopes), agents: members.filter { $0.kind == "agent" })
        }
        let grants: [GoalsChannelGrant]
        do { grants = try await channelGrants(workspaceId: workspaceId, appNpub: appNpub, channelId: channel.id) }
        catch TowerError.http(let status, _, _) where status == 403 || status == 404 { return .unsafe("This Goals space is no longer available with its saved access.") }
        return GoalsSpaceResolver.classify(channel: channel, grants: grants, members: members, viewer: viewer)
    }

    /// Creates the owner's private Goals channel in `scopeId` with explicit contribute grants for `agentActorIds`. The
    /// creator keeps Tower's own creator bundle (it is never named here). Tower decides whether this identity may create
    /// channels there; a refusal surfaces as the Tower error and nothing is created.
    public func createGoalsSpace(workspaceId: String, appNpub: String, viewer: String, scopeId: String, agentActorIds: [String]) async throws -> ChannelRecord {
        let grants = try Array(Set(agentActorIds.map { $0.lowercased() })).sorted().map {
            ["principal_type": "actor", "principal_id": try Self.uuid($0), "access_level": "contribute"]
        }
        var lastError: Error?
        for name in [GoalsSpace.channelName, "My Goals", "Goals (\(viewer.suffix(6)))"] {
            var body: [String: Any] = ["name": name, "kind": "channel", "metadata": GoalsSpace.metadata(owner: viewer), "grants": grants,
                                       "description": "Private goals: visible only to you and agents you allow."]
            if grants.isEmpty { body["grants"] = [] }
            let reply = try await client.exchange(method: "POST", path: Self.base(workspaceId) + "/scopes/" + Self.uuid(scopeId) + "/channels", appNpub: appNpub, jsonBody: try rawJSON(body))
            let o = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
            if reply.status == 409 { lastError = TowerError.http(status: 409, code: o["code"] as? String, stage: nil); continue }   // name taken in this scope
            guard (200..<300).contains(reply.status) else { throw TowerError.http(status: reply.status, code: o["code"] as? String, stage: nil) }
            guard let row = o["channel"] as? [String: Any] else { throw TowerError.malformed("channel") }
            let channel = try ChannelRecord(raw: rawJSON(row))
            guard GoalsSpace.isOwnedBy(channel, viewer: viewer), channel.scopeId == scopeId.lowercased() else { throw TowerError.malformed("channel") }
            return channel
        }
        throw lastError ?? TowerError.malformed("channel")
    }

    /// Gives one workspace agent contribute access to the owner's Goals channel, or removes it. Only the owner can.
    public func setGoalsAgentAccess(workspaceId: String, appNpub: String, channelId: String, agent: MemberRecord, enabled: Bool) async throws {
        precondition(agent.kind == "agent")
        let base = try Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/grants"
        if enabled {
            _ = try await client.request(method: "POST", path: base, appNpub: appNpub,
                                         jsonBody: try rawJSON(["principal_type": "actor", "principal_id": agent.actorId, "access_level": "contribute"]))
        } else {
            _ = try await client.request(method: "DELETE", path: base + "/actor/" + agent.actorId, appNpub: appNpub)
        }
    }
}

private extension ChannelRecord {
    var createdAtSort: String { ((try? JSONSerialization.jsonObject(with: raw) as? [String: Any])?["created_at"] as? String) ?? "" }
}
