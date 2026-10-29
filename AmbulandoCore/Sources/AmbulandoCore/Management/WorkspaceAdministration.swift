import Foundation

/// Persisted projections, not authority. Raw bytes preserve new server fields without putting decoding on the UI actor.
public struct AdministrationRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let fields: [String: String]
    public let children: [AdministrationRow]
    public let raw: Data
    public let childGroupIds: [String]
    public let filters: [String: [String]]

    public var channelPermissions: [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return [] }
        return (object["permissions"] as? [String] ?? [object["permission"] as? String ?? ""]).filter { !$0.isEmpty }.sorted()
    }

    init(_ source: [String: Any]) {
        var object = source
        if let principal = source["principal"] as? [String: Any] {
            // Display metadata belongs to the recipient, while grant identity and resource remain top-level.
            for key in ["display_name", "name", "npub", "kind"] where object[key] == nil { object[key] = principal[key] }
            if object["principal_id"] == nil { object["principal_id"] = principal["actor_id"] ?? principal["id"] }
        }
        if object["principal_type"] as? String == "person" { object["principal_type"] = "actor" }
        if let actor = source["actor"] as? [String: Any] { object = source.merging(actor) { _, actorValue in actorValue } }
        if let membership = source["membership"] as? [String: Any], let role = membership["role"] { object["role"] = role }
        if let grant = source["grant"] as? [String: Any] { object = (source["installation"] as? [String: Any] ?? [:]).merging(grant) { _, value in value } }
        filters = (object["filters"] as? [String: Any] ?? [:]).reduce(into: [:]) { result, item in if let values = item.value as? [String] { result[item.key] = values } }
        raw = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        childGroupIds = object["child_group_ids"] as? [String] ?? []
        fields = object.reduce(into: [:]) { result, item in
            if let value = item.value as? String { result[item.key] = value }
        }
        id = fields["wapp_installation_id"] ?? fields["actor_id"] ?? fields["group_id"] ?? fields["principal_id"] ?? fields["id"] ?? fields["npub"] ?? "unavailable:" + SHA256Hex.of(raw)
        title = fields["display_name"] ?? fields["label"] ?? fields["name"] ?? fields["title"] ?? fields["npub"] ?? fields["delegate_actor_id"] ?? id
        detail = [fields["role"], fields["kind"], fields["status"], fields["lifecycle_status"], fields["publishing_status"], fields["access_level"], fields["expires_at"], fields["revoked_at"].map { "Revoked: \($0)" }].compactMap { $0 }.joined(separator: " · ")
        children = ((object["members"] as? [[String: Any]]) ?? []).map(AdministrationRow.init)
    }
}

public enum AdministrationList: String, CaseIterable, Sendable {
    case members, groups, delegations, installations, intents, publishing
    var route: String {
        switch self {
        case .members, .groups: "/\(rawValue)"
        case .delegations: "/wapp-delegations"
        case .installations: "/wapp-installations"
        case .intents: "/wapp-install-intents"
        case .publishing: "/wapp-publishing-grants"
        }
    }
    public func key(connection: String, workspace: String) -> String { "admin.v1:\(connection):\(workspace):\(rawValue)" }
}

public struct AdministrationDestination: Codable, Equatable, Sendable {
    public let scope: String
    public let channel: String
    public init(scope: String, channel: String) { self.scope = scope; self.channel = channel }
}

public enum AdministrationCommand: Sendable {
    case profile(name: String, description: String, avatarURL: String, slug: String? = nil)
    case addMember(npub: String, kind: String)
    case memberProfile(actor: String, name: String)
    case deleteWorkspace(confirmation: String)
    case createGroup(name: String)
    case groupMember(group: String, npub: String)
    case ensureGroupMember(group: String, npub: String, kind: String)
    case removeGroupMember(group: String, actor: String)
    case childGroup(parent: String, child: String, remove: Bool)
    case channelGrant(channel: String, principalType: String, principal: String, access: String, update: Bool)
    case revokeChannelGrant(channel: String, principalType: String, principal: String)
    case delegation(actor: String, expires: String, app: String, scope: String, channel: String)
    case revokeDelegation(id: String)
    case installation(id: String, revoke: Bool)
    case publishing(id: String, app: String, publisher: String, owner: String, name: String, destinations: [AdministrationDestination], origins: [String])
    case disablePublishing(id: String)
    case revokePublishing(id: String)
    case rotatePublisher(id: String, current: String, replacement: String)

    func request() throws -> (String, String, Data?) {
        func uuid(_ value: String) throws -> String { try TowerAPI.uuid(value) }
        func npub(_ value: String) throws -> String {
            guard NostrKeys.isValidNpub(value) else { throw ManagementError.invalid("Enter a valid full npub.") }; return value
        }
        func principal(_ type: String, _ id: String) throws -> String {
            guard ["actor", "group"].contains(type) else { throw ManagementError.invalid("Choose a person or group.") }
            return try uuid(id)
        }
        let method: String, path: String, body: [String: Any]?
        switch self {
        case let .profile(name, description, avatar, slug):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ManagementError.invalid("Workspace name is required.") }
            if avatar.hasPrefix("storage://") {
                _ = try uuid(String(avatar.dropFirst(10)))
            } else if !avatar.isEmpty {
                guard let url = URL(string: avatar), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ManagementError.invalid("Use an HTTPS avatar URL without credentials.") }
            }
            method = "PATCH"; path = ""
            var fields: [String: Any] = ["name": name.trimmingCharacters(in: .whitespacesAndNewlines), "description": description, "avatar_url": avatar.isEmpty ? NSNull() : avatar as Any]
            if let slug {
                guard !slug.isEmpty, slug.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) else { throw ManagementError.invalid("Use a lowercase slug containing letters, numbers and hyphens.") }
                fields["slug"] = slug
            }
            body = fields
        case let .addMember(member, kind):
            guard ["human", "agent"].contains(kind) else { throw ManagementError.invalid("Choose a person or agent.") }
            method = "POST"; path = "/members"; body = ["member_npub": try npub(member), "role": "member", "kind": kind]
        case let .memberProfile(actor, name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ManagementError.invalid("Display name is required.") }
            method = "PATCH"; path = try "/members/\(uuid(actor))/profile"; body = ["display_name": name.trimmingCharacters(in: .whitespacesAndNewlines)]
        case let .deleteWorkspace(confirmation):
            method = "DELETE"; path = ""; body = ["confirmation": try uuid(confirmation)]
        case let .createGroup(name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ManagementError.invalid("Group name is required.") }
            method = "POST"; path = "/groups"; body = ["name": name.trimmingCharacters(in: .whitespacesAndNewlines), "kind": "custom"]
        case let .groupMember(group, member):
            method = "POST"; path = try "/groups/\(uuid(group))/members"; body = ["member_npub": try npub(member)]
        case let .ensureGroupMember(group, member, kind):
            guard ["human", "agent"].contains(kind) else { throw ManagementError.invalid("Choose a person or agent.") }
            method = "POST"; path = try "/groups/\(uuid(group))/members"
            body = ["member_npub": try npub(member), "ensure_workspace_member": true, "kind": kind]
        case let .removeGroupMember(group, actor):
            method = "DELETE"; path = try "/groups/\(uuid(group))/members/\(uuid(actor))"; body = nil
        case let .childGroup(parent, child, remove):
            method = remove ? "DELETE" : "POST"
            path = try "/groups/\(uuid(parent))/child-groups" + (remove ? "/\(uuid(child))" : "")
            body = remove ? nil : ["child_group_id": try uuid(child)]
        case let .channelGrant(channel, type, id, access, update):
            guard ["view", "contribute", "manage"].contains(access) else { throw ManagementError.invalid("Choose an access level.") }
            let target = try principal(type, id)
            method = update ? "PUT" : "POST"
            path = try "/channels/\(uuid(channel))/grants" + (update ? "/\(type)/\(target)" : "")
            body = update ? ["access_level": access] : ["principal_type": type, "principal_id": target, "access_level": access]
        case let .revokeChannelGrant(channel, type, id):
            let target = try principal(type, id)
            method = "DELETE"; path = try "/channels/\(uuid(channel))/grants/\(type)/\(target)"; body = nil
        case let .delegation(actor, expires, app, scope, channel):
            guard ISO8601DateFormatter().date(from: expires).map({ $0 > Date() }) == true, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ManagementError.invalid("Choose an app and a future expiry.") }
            method = "POST"; path = "/wapp-delegations"
            body = ["delegate_actor_id": try uuid(actor), "expires_at": expires,
                    "filters": ["app_ids": [app], "scope_ids": [try uuid(scope)], "channel_ids": [try uuid(channel)], "capabilities": ["activity.publish"], "open_origins": [], "autopilot_origins": [], "installation_ids": []]]
        case let .revokeDelegation(id):
            method = "POST"; path = try "/wapp-delegations/\(uuid(id))/revoke"; body = [:]
        case let .publishing(id, app, publisher, owner, name, destinations, origins):
            guard !app.isEmpty, !name.isEmpty, !destinations.isEmpty else { throw ManagementError.invalid("App identifier and display name are required.") }
            for origin in origins { _ = try TowerOrigin(origin) }
            method = "PUT"; path = try "/wapp-publishing-grants/\(uuid(id))"
            body = ["app_id": app, "publisher_npub": try npub(publisher), "owner_npub": try npub(owner), "display_name": name,
                    "capabilities": ["activity.publish"], "destinations": try destinations.map { ["scope_id": try uuid($0.scope), "channel_id": try uuid($0.channel)] }, "registered_open_origins": origins]
        case let .disablePublishing(id):
            method = "POST"; path = try "/wapp-publishing-grants/\(uuid(id))/disable"; body = ["disabled": true, "reason": "Disabled in Ambulando"]
        case let .revokePublishing(id):
            method = "POST"; path = try "/wapp-publishing-grants/\(uuid(id))/revoke"; body = ["disable_open_links": true, "reason": "Revoked in Ambulando"]
        case let .rotatePublisher(id, current, replacement):
            method = "POST"; path = try "/wapp-publishing-grants/\(uuid(id))/rotate"
            body = ["current_publisher_npub": try npub(current), "new_publisher_npub": try npub(replacement), "nonce": UUID().uuidString.lowercased(), "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))]
        case let .installation(id, revoke):
            method = "POST"; path = try "/wapp-installations/\(uuid(id))/\(revoke ? "revoke" : "reconcile")"; body = [:]
        }
        return (method, path, try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) })
    }
}

extension ScopeChannelManager {
    /// Refresh lists individually: an unavailable app API never obscures cached people or groups.
    public func refreshAdministration(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, list: AdministrationList) async throws {
        try await identity.requireSigner(npub: connection.signerNpub)
        let client = TowerClient(origin: try TowerOrigin(connection.origin), transport: transport, signer: identity)
        let pages = try await client.list(path: try TowerAPI.base(workspace.id) + list.route, appNpub: workspace.appNpub, key: list == .publishing ? "grants" : list.rawValue)
        let rows = try pages.map { raw -> AdministrationRow in
            guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw TowerError.malformed("administration row") }
            if let id = object["workspace_id"] as? String, id.lowercased() != workspace.id { throw TowerError.malformed("cross-workspace administration row") }
            return AdministrationRow(object)
        }
        try await store.writer.setState(list.key(connection: connection.id, workspace: workspace.id), String(decoding: JSONEncoder().encode(rows), as: UTF8.self))
    }

    public func channelGrants(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channel: String) async throws -> [AdministrationRow] {
        let object = try await send(connection, workspace, method: "GET", path: try TowerAPI.base(workspace.id) + "/channels/" + TowerAPI.uuid(channel) + "/grants", operation: .readPermissions)
        let rows = ((object["grants"] as? [[String: Any]]) ?? []).map(AdministrationRow.init)
        try await store.writer.setState("admin.channel-grants.v1:\(connection.id):\(workspace.id):\(channel)", String(decoding: JSONEncoder().encode(rows), as: UTF8.self))
        return rows
    }

    /// Every write rechecks /me. No stale screen capability authorizes a request. Exact resource authority remains on Tower.
    /// Broader native entry points are conservatively restricted to workspace admins until resource capability projections exist.
    public func administer(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, command: AdministrationCommand) async throws {
        let request = try command.request()
        let fresh = try await membership(connection, workspace)
        if !fresh.isAdmin {
            switch command {
            case .channelGrant(let channel, _, _, _, _), .revokeChannelGrant(let channel, _, _):
                let grants = try await channelGrants(connection, workspace, channel: channel)
                // Group directory is admin-only on Tower; a direct channel manager must not need it.
                let groups = try await store.reader.administrationRows(connection: connection.id, workspace: workspace.id, list: .groups)
                guard AdministrationAuthority.canManageChannelGrants(membership: fresh, grants: grants, groups: groups, npub: connection.signerNpub) else { throw ManagementError.forbidden("Channel grant management permission is required for this channel.") }
            case .installation(let id, _):
                let result = try await send(connection, workspace, method: "GET", path: try TowerAPI.base(workspace.id) + "/wapp-delegations", operation: .readPermissions)
                let delegations = ((result["delegations"] as? [[String: Any]]) ?? []).map(AdministrationRow.init)
                try await refreshAdministration(connection, workspace, list: .installations)
                let installations = try await store.reader.administrationRows(connection: connection.id, workspace: workspace.id, list: .installations)
                guard AdministrationAuthority.hasInstallationDelegation(actor: fresh.actorId ?? "", installation: id, delegations: delegations, installationData: installations.first { $0.id == id }) else { throw ManagementError.forbidden("An active delegation for this exact installation is required.") }
            default: throw ManagementError.forbidden("Workspace administrator access is required for this control. Your draft is retained.")
            }
        }
        let body = try request.2.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        let result = try await send(connection, workspace, method: request.0, path: try TowerAPI.base(workspace.id) + request.1, body: body, operation: .readPermissions)
        if case .profile = command {
            try await store.writer.confirmAdministrationProfile(connection: connection.id, workspace: workspace.id, submitted: request.2 ?? Data(), returned: JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
        }
    }
}

extension StoreReader {
    public func administrationRows(connection: String, workspace: String, list: AdministrationList) throws -> [AdministrationRow] {
        guard let value = try state(list.key(connection: connection, workspace: workspace)) else { return [] }
        return try JSONDecoder().decode([AdministrationRow].self, from: Data(value.utf8))
    }
}

public struct ScopeAdministrationAccess: Codable, Equatable, Sendable {
    public let revision: Int
    public let canManage: Bool
    public let grants: [AdministrationRow]
    public let actors: [AdministrationRow]
    public let groups: [AdministrationRow]
    init(_ object: [String: Any]) throws {
        guard let revision = flexibleInt(object["revision"]) else { throw ManagementError.unexpected("Tower did not return the scope access revision.") }
        self.revision = revision
        canManage = object["can_manage"] as? Bool == true
        grants = ((object["grants"] as? [[String: Any]]) ?? []).map(AdministrationRow.init)
        let principals = object["principals"] as? [String: Any] ?? [:]
        actors = ((principals["actors"] as? [[String: Any]]) ?? []).map(AdministrationRow.init)
        groups = ((principals["groups"] as? [[String: Any]]) ?? []).map(AdministrationRow.init)
    }
    public static func key(connection: String, workspace: String, scope: String) -> String { "admin.scope-access.v1:\(connection):\(workspace):\(scope)" }
}

extension ScopeChannelManager {
    public func scopeAccess(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scope: String) async throws -> ScopeAdministrationAccess {
        let object = try await send(connection, workspace, method: "GET", path: try TowerAPI.base(workspace.id) + "/scopes/" + TowerAPI.uuid(scope) + "/grants", operation: .manageScope)
        let value = try ScopeAdministrationAccess(object)
        try await store.writer.setState(ScopeAdministrationAccess.key(connection: connection.id, workspace: workspace.id, scope: scope), String(decoding: JSONEncoder().encode(value), as: UTF8.self))
        return value
    }

    /// Uses the scope's own can_manage projection and revision; delegated scope managers do not need workspace admin.
    /// A fresh read verifies authority but never silently rebases an editor over someone else's grant change.
    public func saveScopeAccess(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scope: String, principalType: String, principal: String, role: String, revoke: Bool, expectedRevision: Int) async throws {
        guard ["actor", "group"].contains(principalType), ["context_editor", "scope_manager"].contains(role) else { throw ManagementError.invalid("Choose a principal and scope role.") }
        let scopeId = try TowerAPI.uuid(scope), principalId = try TowerAPI.uuid(principal)
        let fresh = try await scopeAccess(connection, workspace, scope: scopeId)
        guard fresh.canManage else { throw ManagementError.forbidden("Scope manager permission is required to change access.") }
        guard fresh.revision == expectedRevision else { throw ManagementError.conflict("Scope access changed elsewhere. Refresh and review it before saving your retained draft.") }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin(connection.origin), transport: transport, signer: identity))
        let lease = try await api.acquireLease(workspaceId: workspace.id, appNpub: workspace.appNpub, entityType: "scope", entityId: scopeId)
        do {
            var body: [String: Any] = ["principal_type": principalType, "principal_id": principalId, "expected_revision": expectedRevision, "lease_token": lease.token]
            if revoke { body["revoke"] = true } else { body["role"] = role }
            let object = try await send(connection, workspace, method: "PUT", path: try TowerAPI.base(workspace.id) + "/scopes/\(scopeId)/grants", body: body, operation: .manageScope)
            let saved = try ScopeAdministrationAccess(object)
            try await store.writer.setState(ScopeAdministrationAccess.key(connection: connection.id, workspace: workspace.id, scope: scopeId), String(decoding: JSONEncoder().encode(saved), as: UTF8.self))
        } catch {
            try? await api.releaseLease(workspaceId: workspace.id, appNpub: workspace.appNpub, lease: lease)
            throw error
        }
        try? await api.releaseLease(workspaceId: workspace.id, appNpub: workspace.appNpub, lease: lease)
    }
}

extension StoreReader {
    public func scopeAdministrationAccess(connection: String, workspace: String, scope: String) throws -> ScopeAdministrationAccess? {
        guard let value = try state(ScopeAdministrationAccess.key(connection: connection, workspace: workspace, scope: scope)) else { return nil }
        return try JSONDecoder().decode(ScopeAdministrationAccess.self, from: Data(value.utf8))
    }
}

public struct AdministrationActivationApp: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let version: String
    public let title: String
    public let launchURL: String
    public let origin: String
    public let autopilotNpub: String
    public let viewOrigin: String
    init(_ row: [String: Any]) throws {
        guard let id = row["app_id"] as? String, let version = row["app_version"] as? String,
              let launch = row["launch_url"] as? String, let origin = row["autopilot_origin"] as? String,
              let npub = row["autopilot_npub"] as? String, NostrKeys.isValidNpub(npub) else { throw ManagementError.unexpected("Activation catalog entry is incomplete.") }
        self.id = id; self.version = version; title = row["title"] as? String ?? id
        launchURL = launch; self.origin = try TowerOrigin(origin).description; autopilotNpub = npub
        viewOrigin = try TowerOrigin(row["view_origin"] as? String ?? origin).description
    }
}

extension ScopeChannelManager {
    /// Called only after explicit confirmation of the user-configured origin. Nothing from Tower metadata selects this host.
    public func activationCatalog(_ connection: ConnectionRecord, origin: String) async throws -> [AdministrationActivationApp] {
        try await identity.requireSigner(npub: connection.signerNpub)
        let client = TowerClient(origin: try TowerOrigin(origin), transport: transport, signer: identity)
        let data = try await client.request(path: "/api/wapps/activation-catalog")
        let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return try ((object["apps"] as? [[String: Any]]) ?? []).map(AdministrationActivationApp.init)
    }

    /// One intent creation, followed by an explicit separate claim. The caller persists the returned intent id before
    /// claiming; a failure may retry processing that exact intent and must never blindly create another installation.
    public func createActivationIntent(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, app: AdministrationActivationApp, origin: String, scope: String, channel: String, installation: String, requestId: String, delegation: String?) async throws -> String {
        guard try TowerOrigin(origin).description == app.origin else { throw ManagementError.invalid("The catalog app belongs to a different Autopilot origin.") }
        let fresh = try await membership(connection, workspace)
        guard fresh.isAdmin || (delegation != nil && fresh.actorId != nil) else { throw ManagementError.forbidden("Administrator or explicit delegated app management is required.") }
        var body: [String: Any] = ["client_request_id": try TowerAPI.uuid(requestId), "app_id": app.id, "app_version": app.version,
                                  "wapp_installation_id": try TowerAPI.uuid(installation), "title": app.title, "launch_url": app.launchURL,
                                  "autopilot_origin": app.origin, "autopilot_npub": app.autopilotNpub, "registered_open_origins": [app.viewOrigin],
                                  "capabilities": ["activity.publish"], "destinations": [["scope_id": try TowerAPI.uuid(scope), "channel_id": try TowerAPI.uuid(channel)]]]
        if let delegation { body["delegation_id"] = try TowerAPI.uuid(delegation) }
        let result = try await send(connection, workspace, method: "POST", path: try TowerAPI.base(workspace.id) + "/wapp-install-intents", body: body, operation: .readPermissions)
        guard let intent = result["intent"] as? [String: Any], let id = intent["id"] as? String else { throw ManagementError.unexpected("Tower did not return an activation intent. Check the intent list before retrying.") }
        return try TowerAPI.uuid(id)
    }

    public func processActivationIntent(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, origin: String, intent: String) async throws {
        try await identity.requireSigner(npub: connection.signerNpub)
        let client = TowerClient(origin: try TowerOrigin(origin), transport: transport, signer: identity)
        _ = try await client.request(method: "POST", path: "/api/wapps/install-intents/process", jsonBody: JSONSerialization.data(withJSONObject: ["workspace_id": workspace.id, "intent_id": try TowerAPI.uuid(intent)], options: [.sortedKeys]))
    }
}

public enum AdministrationAuthority {
    public static func canManageChannelGrants(membership: WorkspaceMembership, grants: [AdministrationRow], groups: [AdministrationRow], npub: String) -> Bool {
        if membership.isAdmin { return true }
        return grants.contains { row in
            guard let object = (try? JSONSerialization.jsonObject(with: row.raw)) as? [String: Any] else { return false }
            let permissions = object["permissions"] as? [String] ?? [object["permission"] as? String ?? ""]
            guard permissions.contains("channel.grants.manage") || (permissions.allSatisfy { $0.isEmpty } && row.fields["access_level"] == "manage") else { return false }
            if row.fields["principal_type"] == "actor" { return row.fields["principal_id"] == membership.actorId }
            guard row.fields["principal_type"] == "group", let group = groups.first(where: { $0.id == row.fields["principal_id"] }),
                  let object = (try? JSONSerialization.jsonObject(with: group.raw)) as? [String: Any] else { return false }
            return ((object["effective_member_npubs"] as? [String] ?? []) + (object["member_npubs"] as? [String] ?? []) + group.children.compactMap { $0.fields["npub"] }).contains(npub)
        }
    }

    /// Conservative exact-installation delegation. Additional app/destination filters are enforced by Tower.
    /// Listing an installation is never enough to enable management.
    public static func hasInstallationDelegation(actor: String, installation: String, delegations: [AdministrationRow], installationData: AdministrationRow? = nil, now: Date = Date()) -> Bool {
        delegations.contains { row in
            guard row.fields["delegate_actor_id"] == actor, row.fields["revoked_at"] == nil,
                  let expires = row.fields["expires_at"].flatMap({ ISO8601DateFormatter().date(from: $0) }), expires > now,
                  let object = (try? JSONSerialization.jsonObject(with: row.raw)) as? [String: Any], let filters = object["filters"] as? [String: Any] else { return false }
            let ids = filters["installation_ids"] as? [String] ?? [], apps = filters["app_ids"] as? [String] ?? []
            if !ids.isEmpty && !ids.contains(installation) { return false }
            if !apps.isEmpty, let app = installationData?.fields["app_id"], !apps.contains(app) { return false }
            if ids.contains(installation) { return true }
            guard let data = installationData, let app = data.fields["app_id"], apps.contains(app),
                  let object = (try? JSONSerialization.jsonObject(with: data.raw)) as? [String: Any] else { return false }
            let destinations = object["destinations"] as? [[String: Any]] ?? []
            let scopes = filters["scope_ids"] as? [String] ?? [], channels = filters["channel_ids"] as? [String] ?? []
            if (!scopes.isEmpty || !channels.isEmpty) && destinations.isEmpty { return false }
            return destinations.allSatisfy { destination in
                (scopes.isEmpty || scopes.contains(destination["scope_id"] as? String ?? "")) && (channels.isEmpty || channels.contains(destination["channel_id"] as? String ?? ""))
            }
        }
    }
}

extension StoreWriter {
    /// Updates only the acknowledged workspace. Never replaces discovery, removes other workspaces or resets cursors.
    func confirmAdministrationProfile(connection: String, workspace: String, submitted: Data, returned: Data) async throws {
        let query = try db.prepare("SELECT raw FROM workspaces WHERE connection_id = ? AND workspace_id = ?")
        try query.bind([.text(connection), .text(workspace)])
        guard try query.step() else { return }
        let raw = query.blob(0)
        guard var object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let sent = try JSONSerialization.jsonObject(with: submitted) as? [String: Any], let reply = try JSONSerialization.jsonObject(with: returned) as? [String: Any] else { return }
        let confirmed = reply["workspace"] as? [String: Any] ?? reply
        for key in ["name", "description", "avatar_url", "slug"] { if let value = confirmed[key] ?? sent[key] { object[key] = value } }
        if let name = object["name"] as? String { object["label"] = name }
        let record = try WorkspaceRecord(raw: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        try db.prepare("UPDATE workspaces SET label = ?, slug = ?, raw = ? WHERE connection_id = ? AND workspace_id = ?")
            .run([.text(record.label), record.slug.sql, .blob(record.raw), .text(connection), .text(workspace)])
        await emit([ChangeKey(.workspaces, workspace)])
    }
}

extension ScopeChannelManager {
    /// Uses the web workspace-avatar public-storage contract, separate from ordinary private workspace attachments.
    /// Call only after explicit consent that the selected avatar becomes public. Signs as the current user, never the owner.
    public func uploadWorkspaceAvatar(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, png: Data) async throws -> String {
        guard png.count <= 8 * 1024 * 1024, let owner = workspace.ownerNpub, NostrKeys.isValidNpub(owner) else { throw ManagementError.invalid("Choose an image smaller than 8 MB for a workspace with a known owner.") }
        let fresh = try await membership(connection, workspace)
        guard fresh.isAdmin else { throw ManagementError.forbidden("Workspace administrator access is required to upload a public avatar.") }
        let object = try await send(connection, workspace, method: "POST", path: "/api/v4/storage/prepare", body: ["owner_npub": owner, "content_type": "image/png", "size_bytes": png.count, "file_name": "workspace-avatar.png", "is_public": true,
                                                                                                              "metadata": ["purpose": "workspace-profile/avatar", "visibility": "public", "workspace_id": workspace.id]], operation: .readPermissions)
        guard let id = object["object_id"] as? String, let upload = object["upload_url"] as? String,
              object["is_public"] as? Bool == true else { throw ManagementError.unexpected("Tower did not confirm a public avatar upload.") }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin(connection.origin), transport: transport, signer: identity))
        let prepared = PreparedObject(objectId: try TowerAPI.uuid(id), uploadURL: upload)
        try await api.upload(prepared, bytes: png, contentType: "image/png")
        try await api.completeStorage(objectId: id, sizeBytes: png.count, sha256: SHA256Hex.of(png))
        return "storage://" + id
    }
}

extension ScopeChannelManager {
    public func setupChannelNames(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scope: String) async throws -> Set<String> {
        let client = TowerClient(origin: try TowerOrigin(connection.origin), transport: transport, signer: identity)
        let channels = try await TowerAPI(client: client).channels(workspaceId: workspace.id, scopeId: scope, appNpub: workspace.appNpub)
        try await store.writer.upsertChannels(workspaceId: workspace.id, scopeId: scope, channels, complete: true)
        return Set(channels.map { $0.name.lowercased() })
    }
}

extension ScopeChannelManager {
    public func scopeSetupCandidate(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, name: String) async throws -> ScopeRecord? {
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin(connection.origin), transport: transport, signer: identity))
        let scopes = try await api.scopes(workspaceId: workspace.id, appNpub: workspace.appNpub)
        try await store.writer.upsertScopes(workspaceId: workspace.id, scopes, complete: true)
        return scopes.first { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
    }
}
