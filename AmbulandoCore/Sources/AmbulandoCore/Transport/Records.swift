import Foundation

/// Typed views over Tower Flight Deck PG serializers (tower/src/services/flightdeck-pg-api.ts).
/// Each keeps the canonical JSON (`raw`) so unknown fields survive local storage.

public struct WorkspaceRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let appNpub: String
    public let label: String
    public let slug: String?
    public let towerBaseURL: String?
    public let role: String?
    public let ownerNpub: String?
    public let raw: Data

    struct DTO: Decodable {
        struct Identity: Decodable { let workspace_id: String?; let app_npub: String?; let workspace_owner_npub: String? }
        struct Membership: Decodable { let role: String? }
        let identity: Identity
        let label: String?
        let slug: String?
        let tower_base_url: String?
        let membership: Membership?
    }

    public init(raw: Data) throws {
        let dto = try JSONDecoder().decode(DTO.self, from: raw)
        guard let id = dto.identity.workspace_id, UUID(uuidString: id) != nil,
              let app = dto.identity.app_npub, NostrKeys.isValidNpub(app) else { throw TowerError.malformed("workspace") }
        self.id = id.lowercased()
        appNpub = app
        label = dto.label ?? "Workspace"
        slug = dto.slug
        towerBaseURL = dto.tower_base_url
        role = dto.membership?.role
        ownerNpub = dto.identity.workspace_owner_npub
        self.raw = raw
    }

    public init(id: String, appNpub: String, label: String, slug: String?, towerBaseURL: String?, role: String?, ownerNpub: String?, raw: Data) {
        self.id = id; self.appNpub = appNpub; self.label = label; self.slug = slug
        self.towerBaseURL = towerBaseURL; self.role = role; self.ownerNpub = ownerNpub; self.raw = raw
    }
}

public struct ScopeRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let name: String
    public let kind: String?
    public let description: String?
    public let defaultChannelId: String?
    public let rowVersion: Int
    public let updatedAt: String
    public let raw: Data

    struct DTO: Decodable {
        let id: String; let workspace_id: String; let name: String?; let kind: String?; let description: String?
        let default_channel_id: String?; let row_version: Int?; let updated_at: String?
    }

    public init(raw: Data) throws {
        let dto = try JSONDecoder().decode(DTO.self, from: raw)
        guard UUID(uuidString: dto.id) != nil else { throw TowerError.malformed("scope") }
        workspaceId = dto.workspace_id.lowercased(); id = dto.id.lowercased(); name = dto.name ?? "Untitled scope"
        kind = dto.kind; description = dto.description; defaultChannelId = dto.default_channel_id?.lowercased()
        rowVersion = dto.row_version ?? 0; updatedAt = dto.updated_at ?? ""; self.raw = raw
    }

    public init(workspaceId: String, id: String, name: String, kind: String? = nil, description: String? = nil,
                defaultChannelId: String? = nil, rowVersion: Int = 1, updatedAt: String, raw: Data = Data("{}".utf8)) {
        self.workspaceId = workspaceId; self.id = id; self.name = name; self.kind = kind; self.description = description
        self.defaultChannelId = defaultChannelId; self.rowVersion = rowVersion; self.updatedAt = updatedAt; self.raw = raw
    }
}

public struct ChannelRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let scopeId: String
    public let name: String
    public let kind: String?
    public let position: Double?
    public let rowVersion: Int
    public let updatedAt: String
    public let raw: Data

    struct DTO: Decodable {
        let id: String; let workspace_id: String; let scope_id: String; let name: String?; let kind: String?
        let position: Double?; let row_version: Int?; let updated_at: String?
    }

    public init(raw: Data) throws {
        let dto = try JSONDecoder().decode(DTO.self, from: raw)
        guard UUID(uuidString: dto.id) != nil, UUID(uuidString: dto.scope_id) != nil else { throw TowerError.malformed("channel") }
        workspaceId = dto.workspace_id.lowercased(); id = dto.id.lowercased(); scopeId = dto.scope_id.lowercased()
        name = dto.name ?? "Untitled channel"; kind = dto.kind; position = dto.position
        rowVersion = dto.row_version ?? 0; updatedAt = dto.updated_at ?? ""; self.raw = raw
    }

    public init(workspaceId: String, id: String, scopeId: String, name: String, kind: String? = nil, position: Double? = nil,
                rowVersion: Int = 1, updatedAt: String, raw: Data = Data("{}".utf8)) {
        self.workspaceId = workspaceId; self.id = id; self.scopeId = scopeId; self.name = name; self.kind = kind
        self.position = position; self.rowVersion = rowVersion; self.updatedAt = updatedAt; self.raw = raw
    }
}

public struct MessageRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let channelId: String
    public let threadId: String?
    /// The message that started `threadId`. A message is a channel-level post when it is its thread's source.
    public let threadSourceId: String?
    public let body: String
    public let senderNpub: String?
    public let senderLabel: String?
    public let clientRequestId: String?
    public let createdAt: String
    public let updatedAt: String
    public let rowVersion: Int
    public let deleted: Bool
    public let raw: Data

    /// Channel-level post (thread root), as the web client maps it: `thread_source_message_id == id`, or no thread.
    public var isThreadRoot: Bool { threadId == nil || threadSourceId == id }

    struct DTO: Decodable {
        let id: String; let workspace_id: String; let channel_id: String; let thread_id: String?; let thread_source_message_id: String?
        let body: String?; let sender_npub: String?; let created_by_actor_label: String?; let client_request_id: String?
        let created_at: String?; let updated_at: String?; let row_version: Int?; let record_state: String?
    }

    public init(raw: Data) throws {
        let dto = try JSONDecoder().decode(DTO.self, from: raw)
        guard UUID(uuidString: dto.id) != nil, UUID(uuidString: dto.channel_id) != nil else { throw TowerError.malformed("message") }
        workspaceId = dto.workspace_id.lowercased(); id = dto.id.lowercased(); channelId = dto.channel_id.lowercased()
        threadId = dto.thread_id?.lowercased(); threadSourceId = dto.thread_source_message_id?.lowercased()
        body = dto.body ?? ""; senderNpub = dto.sender_npub; senderLabel = dto.created_by_actor_label; clientRequestId = dto.client_request_id
        createdAt = dto.created_at ?? ""; updatedAt = dto.updated_at ?? createdAt; rowVersion = dto.row_version ?? 0
        deleted = dto.record_state == "deleted"; self.raw = raw
    }

    public init(workspaceId: String, id: String, channelId: String, threadId: String? = nil, threadSourceId: String? = nil, body: String,
                senderNpub: String? = nil, senderLabel: String? = nil, clientRequestId: String? = nil,
                createdAt: String, updatedAt: String? = nil, rowVersion: Int = 1, deleted: Bool = false, raw: Data = Data("{}".utf8)) {
        self.workspaceId = workspaceId; self.id = id; self.channelId = channelId; self.threadId = threadId; self.threadSourceId = threadSourceId
        self.body = body; self.senderNpub = senderNpub; self.senderLabel = senderLabel; self.clientRequestId = clientRequestId
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.rowVersion = rowVersion; self.deleted = deleted; self.raw = raw
    }
}

public struct ThreadRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let channelId: String
    public let sourceMessageId: String?
    public let title: String?
    public let latest: String?
    public let archived: Bool
    public let deleted: Bool
    public let rowVersion: Int
    public let updatedAt: String
    public let raw: Data

    struct DTO: Decodable {
        let id: String; let workspace_id: String; let channel_id: String; let source_message_id: String?; let title: String?
        let latest: String?; let record_state: String?; let row_version: Int?; let updated_at: String?
    }

    /// The agent a branched thread keeps talking to (`metadata.inherited_agent_recipient_npub`).
    public var inheritedAgentRecipient: String? {
        let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        let npub = ((object?["metadata"] as? [String: Any])?["inherited_agent_recipient_npub"] as? String)?.trimmingCharacters(in: .whitespaces)
        return npub?.isEmpty == false ? npub : nil
    }

    public init(raw: Data) throws {
        let dto = try JSONDecoder().decode(DTO.self, from: raw)
        guard UUID(uuidString: dto.id) != nil, UUID(uuidString: dto.channel_id) != nil else { throw TowerError.malformed("thread") }
        workspaceId = dto.workspace_id.lowercased(); id = dto.id.lowercased(); channelId = dto.channel_id.lowercased()
        sourceMessageId = dto.source_message_id?.lowercased(); title = dto.title; latest = dto.latest
        archived = dto.record_state == "archived"; deleted = dto.record_state == "deleted"
        rowVersion = dto.row_version ?? 0; updatedAt = dto.updated_at ?? ""; self.raw = raw
    }

    public init(workspaceId: String, id: String, channelId: String, sourceMessageId: String?, title: String?, latest: String? = nil,
                archived: Bool = false, deleted: Bool = false, rowVersion: Int = 1, updatedAt: String, raw: Data = Data("{}".utf8)) {
        self.workspaceId = workspaceId; self.id = id; self.channelId = channelId; self.sourceMessageId = sourceMessageId; self.title = title
        self.latest = latest; self.archived = archived; self.deleted = deleted; self.rowVersion = rowVersion; self.updatedAt = updatedAt; self.raw = raw
    }
}

/// Slim workspace directory entry (`GET /workspaces/:w/members`, `serializeFlightDeckPgActor`).
public struct MemberRecord: Sendable, Equatable, Identifiable, Hashable {
    public let workspaceId: String
    public let actorId: String
    public let npub: String
    public let kind: String?
    public let displayName: String?
    public var id: String { npub }

    /// Mention type used on the wire: agents are `agent`, everyone else `person` (sol agent-direct-chat.js).
    public var mentionType: MentionType { kind == "agent" ? .agent : .person }
    public var label: String { (displayName?.isEmpty == false ? displayName! : shortLabel(npub)) }

    struct DTO: Decodable {
        struct Actor: Decodable { let actor_id: String?; let id: String?; let npub: String; let kind: String?; let display_name: String? }
        let actor: Actor
    }

    public init(workspaceId: String, raw: Data) throws {
        let dto = try JSONDecoder().decode(DTO.self, from: raw)
        guard NostrKeys.isValidNpub(dto.actor.npub), let actor = dto.actor.actor_id ?? dto.actor.id else { throw TowerError.malformed("member") }
        self.workspaceId = workspaceId; actorId = actor.lowercased(); npub = dto.actor.npub; kind = dto.actor.kind; displayName = dto.actor.display_name
    }

    public init(workspaceId: String, actorId: String, npub: String, kind: String?, displayName: String?) {
        self.workspaceId = workspaceId; self.actorId = actorId; self.npub = npub; self.kind = kind; self.displayName = displayName
    }
}

func shortLabel(_ npub: String) -> String { npub.count > 16 ? "\(npub.prefix(10))…\(npub.suffix(4))" : npub }
