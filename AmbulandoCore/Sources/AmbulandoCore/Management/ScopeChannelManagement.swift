import Foundation

/// Scope and channel management through the Tower routes the web app uses (sol `channels-manager.js`, `scopes-manager.js`):
///
/// - `POST /scopes/:s/channels` (create, `channel.create` on the scope; DMs need workspace membership)
/// - `PATCH /channels/:c` (rename, context prompt; `channel.manage`), `POST /channels/:c/reorder` (1-based position),
///   `DELETE /channels/:c` (archive)
/// - `POST /scopes` (`scope.create`), `PATCH /scopes/:s` and `DELETE /scopes/:s` (`scope.manage`)
/// - `PUT /me/scope-order` with the stored `expected_row_version` (personal order; conflicts are reported, never replayed)
///
/// These are confirmed online requests, as on the web: the user sees the result or the reason it failed. They are not
/// queued for later, because Tower's create routes carry no idempotency key and a blind replay could create a second
/// channel. Every success is written to the local store from Tower's answer (or a fresh list read), so the sidebar
/// follows without waiting for the event stream.
public struct ScopeChannelManager: Sendable {
    let store: LocalStore
    let identity: IdentityService
    let transport: HTTPTransport

    public init(store: LocalStore, identity: IdentityService, transport: HTTPTransport) {
        self.store = store; self.identity = identity; self.transport = transport
    }

    private func client(_ connection: ConnectionRecord) throws -> TowerClient {
        TowerClient(origin: try TowerOrigin(connection.origin), transport: transport, signer: identity)
    }

    private func base(_ workspace: WorkspaceRecord) throws -> String { try TowerAPI.base(workspace.id) }

    /// Runs one signed request and classifies a refusal for the screen.
    private func send(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, method: String, path: String,
                      body: [String: Any]? = nil, operation: ManagementOperation) async throws -> [String: Any] {
        do {
            try await identity.requireSigner(npub: connection.signerNpub)
        } catch {
            throw ManagementError.locked
        }
        let json = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let result: (status: Int, body: Data)
        do {
            result = try await client(connection).exchange(method: method, path: path, appNpub: workspace.appNpub, jsonBody: json)
        } catch let error as URLError {
            throw ManagementError.offline(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ManagementError.offline(error.localizedDescription)
        }
        let object = ((try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any]) ?? [:]
        guard (200..<300).contains(result.status) else {
            throw ManagementError.classify(status: result.status, object: object, operation: operation)
        }
        return object
    }

    // MARK: Permissions

    /// The member's role and granted permission names (`GET /me`), used to decide which controls to show. Tower still
    /// decides every write; a refusal is shown as such.
    public func membership(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord) async throws -> WorkspaceMembership {
        let object = try await send(connection, workspace, method: "GET", path: try base(workspace) + "/me", operation: .readPermissions)
        return WorkspaceMembership(object)
    }

    // MARK: Channels

    /// Creates a named channel in `scopeId` (optional description and channel context prompt, as the web form).
    public func createChannel(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scopeId: String, name: String,
                              description: String?, contextPrompt: String?) async throws -> ChannelRecord {
        guard !UploadToken.contains(in: description ?? "") else { throw ComposerUploadError.unresolved }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ManagementError.invalid("Channel name is required.") }
        guard !UploadToken.contains(in: contextPrompt ?? "") else { throw ComposerUploadError.unresolved }
        var body: [String: Any] = ["name": trimmed, "kind": "channel",
                                   "metadata": AgentChatConfig.write([:], contextPrompt: contextPrompt ?? "")]
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty { body["description"] = description }
        let object = try await send(connection, workspace, method: "POST", path: try base(workspace) + "/scopes/" + TowerAPI.uuid(scopeId) + "/channels",
                                    body: body, operation: .createChannel)
        return try await storeChannel(object, workspace)
    }

    /// Opens a direct message with another member in a DM scope, named and described as the web names it
    /// (`DM: <npub>`, `dm:<sorted participants>`). The caller opens an existing DM with the member instead of creating one.
    public func createDirectMessage(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scopeId: String,
                                    participantNpub: String) async throws -> ChannelRecord {
        guard NostrKeys.isValidNpub(participantNpub) else { throw ManagementError.invalid("Choose a member to message.") }
        let participants = Array(Set([connection.signerNpub, participantNpub])).sorted()
        let body: [String: Any] = ["name": "DM: \(participantNpub)", "description": "dm:" + participants.joined(separator: "|"),
                                   "kind": "dm", "participant_npubs": participants]
        let object = try await send(connection, workspace, method: "POST", path: try base(workspace) + "/scopes/" + TowerAPI.uuid(scopeId) + "/channels",
                                    body: body, operation: .createChannel)
        return try await storeChannel(object, workspace)
    }

    /// Renames a channel. Tower's PATCH has no version check: the newest rename wins, as on the web.
    public func renameChannel(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channelId: String, name: String) async throws -> ChannelRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ManagementError.invalid("Channel name is required.") }
        let object = try await send(connection, workspace, method: "PATCH", path: try base(workspace) + "/channels/" + TowerAPI.uuid(channelId),
                                    body: ["name": trimmed], operation: .manageChannel)
        return try await storeChannel(object, workspace)
    }

    /// Saves the channel context prompt in the channel's `agent_chat` metadata, keeping every other metadata key.
    public func saveContextPrompt(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channel: ChannelRecord, prompt: String) async throws -> ChannelRecord {
        guard !UploadToken.contains(in: prompt) else { throw ComposerUploadError.unresolved }
        let metadata = AgentChatConfig.write(channel.metadata, contextPrompt: prompt)
        let object = try await send(connection, workspace, method: "PATCH", path: try base(workspace) + "/channels/" + TowerAPI.uuid(channel.id),
                                    body: ["metadata": metadata], operation: .manageChannel)
        return try await storeChannel(object, workspace)
    }

    /// Moves a channel to a 1-based position among its scope's channels, then reads the scope's channels again (every
    /// sibling's position may have changed).
    public func moveChannel(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channel: ChannelRecord, position: Int) async throws {
        guard position >= 1 else { throw ManagementError.invalid("Position must be 1 or more.") }
        _ = try await send(connection, workspace, method: "POST", path: try base(workspace) + "/channels/" + TowerAPI.uuid(channel.id) + "/reorder",
                           body: ["position": position], operation: .manageChannel)
        try await reloadChannels(connection, workspace, scopeId: channel.scopeId)
    }

    /// Archives a channel (Tower keeps its records; nobody can open it afterwards). The scope's channel list is read
    /// again, which removes the channel and its local copies.
    public func archiveChannel(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channel: ChannelRecord) async throws {
        _ = try await send(connection, workspace, method: "DELETE", path: try base(workspace) + "/channels/" + TowerAPI.uuid(channel.id),
                           operation: .manageChannel)
        try await reloadChannels(connection, workspace, scopeId: channel.scopeId)
    }

    private func storeChannel(_ object: [String: Any], _ workspace: WorkspaceRecord) async throws -> ChannelRecord {
        guard let row = object["channel"] as? [String: Any] else { throw ManagementError.unexpected("Tower did not return the channel.") }
        let record = try ChannelRecord(raw: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
        guard record.workspaceId == workspace.id else { throw ManagementError.unexpected("Tower returned a channel from another workspace.") }
        try await store.writer.upsertChannels(workspaceId: workspace.id, scopeId: record.scopeId, [record], complete: false)
        return record
    }

    private func reloadChannels(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scopeId: String) async throws {
        let api = TowerAPI(client: try client(connection))
        do {
            let channels = try await api.channels(workspaceId: workspace.id, scopeId: scopeId, appNpub: workspace.appNpub)
            try await store.writer.upsertChannels(workspaceId: workspace.id, scopeId: scopeId, channels, complete: true)
        } catch {
            // The change is saved on Tower; the sidebar catches up on the next refresh or live event.
            throw ManagementError.savedButNotRefreshed(error.localizedDescription)
        }
    }

    // MARK: Scopes

    /// Creates a scope. The web scope form always creates kind `project`; the creator gets read, manage and
    /// channel-create on it.
    public func createScope(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, name: String,
                            description: String?) async throws -> ScopeRecord {
        guard !UploadToken.contains(in: description ?? "") else { throw ComposerUploadError.unresolved }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ManagementError.invalid("Scope name is required.") }
        var body: [String: Any] = ["name": trimmed, "kind": "project"]
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty { body["description"] = description }
        let object = try await send(connection, workspace, method: "POST", path: try base(workspace) + "/scopes", body: body, operation: .createScope)
        let record = try scopeRecord(object)
        try await reloadScopes(connection, workspace, fallback: record)
        return record
    }

    /// Renames a scope or changes its description.
    public func updateScope(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scopeId: String, name: String, description: String?) async throws {
        guard !UploadToken.contains(in: description ?? "") else { throw ComposerUploadError.unresolved }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ManagementError.invalid("Scope name is required.") }
        let body: [String: Any] = ["name": trimmed, "description": description.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? NSNull()]
        let object = try await send(connection, workspace, method: "PATCH", path: try base(workspace) + "/scopes/" + TowerAPI.uuid(scopeId),
                                    body: body, operation: .manageScope)
        try await reloadScopes(connection, workspace, fallback: try scopeRecord(object))
    }

    /// Archives a scope and all its channels (records stay on Tower; nobody can open them afterwards).
    public func archiveScope(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scopeId: String) async throws {
        _ = try await send(connection, workspace, method: "DELETE", path: try base(workspace) + "/scopes/" + TowerAPI.uuid(scopeId), operation: .manageScope)
        try await reloadScopes(connection, workspace, fallback: nil)
    }

    private func scopeRecord(_ object: [String: Any]) throws -> ScopeRecord {
        guard let row = object["scope"] as? [String: Any] else { throw ManagementError.unexpected("Tower did not return the scope.") }
        return try ScopeRecord(raw: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
    }

    /// Reads the scope list again (it carries `can_manage`); if that read fails, the saved scope is stored on its own.
    private func reloadScopes(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, fallback: ScopeRecord?) async throws {
        let api = TowerAPI(client: try client(connection))
        do {
            let scopes = try await api.scopes(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try await store.writer.upsertScopes(workspaceId: workspace.id, scopes, complete: true)
            // A new scope's channels (Tower may add a default one) are read now rather than on the next refresh.
            let known = Set(try await store.reader.channels(workspaceId: workspace.id).map(\.scopeId))
            for scope in scopes where !known.contains(scope.id) {
                let channels = try await api.channels(workspaceId: workspace.id, scopeId: scope.id, appNpub: workspace.appNpub)
                try await store.writer.upsertChannels(workspaceId: workspace.id, scopeId: scope.id, channels, complete: true)
            }
        } catch {
            if let fallback, fallback.workspaceId == workspace.id { _ = try? await store.writer.upsertScopes(workspaceId: workspace.id, [fallback], complete: false) }
            throw ManagementError.savedButNotRefreshed(error.localizedDescription)
        }
    }

    /// Saves the member's personal scope order. The current `row_version` is read from Tower first (the stored order
    /// may lag another device); if another session saved in between, Tower answers `scope_order_conflict`, the newer
    /// order is stored and the user is asked to make the move again. Nothing is replayed over the other edit.
    public func saveScopeOrder(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, scopeIds: [String]) async throws {
        let path = try base(workspace) + "/me/scope-order"
        let current = try await send(connection, workspace, method: "GET", path: path, operation: .scopeOrder)
        let version = (current["scope_order"] as? [String: Any]).flatMap { flexibleInt($0["row_version"]) } ?? 0
        let ids = scopeIds.filter { UUID(uuidString: $0) != nil }.map { $0.lowercased() }
        do {
            let saved = try await send(connection, workspace, method: "PUT", path: path,
                                       body: ["scope_ids": ids, "expected_row_version": version, "mutation_id": UUID().uuidString.lowercased()],
                                       operation: .scopeOrder)
            try await storeScopeOrder(saved, workspace)
        } catch ManagementError.conflict(let message) {
            if let fresh = try? await send(connection, workspace, method: "GET", path: path, operation: .scopeOrder) { try? await storeScopeOrder(fresh, workspace) }
            throw ManagementError.conflict(message)
        }
    }

    private func storeScopeOrder(_ object: [String: Any], _ workspace: WorkspaceRecord) async throws {
        guard let order = object["scope_order"] as? [String: Any] else { throw ManagementError.unexpected("Tower did not confirm the scope order.") }
        let ids = ((order["scope_ids"] as? [String]) ?? []).filter { UUID(uuidString: $0) != nil }.map { $0.lowercased() }
        try await store.writer.setState(WorkspaceSync.scopeOrderKey(workspace.id), String(decoding: try JSONEncoder().encode(ids), as: UTF8.self))
    }
}

/// What a management screen needs to know about the member (`GET /me`).
public struct WorkspaceMembership: Sendable, Equatable {
    public var role: String?
    public var permissions: Set<String>
    public var actorId: String?

    public init(role: String? = nil, permissions: Set<String> = [], actorId: String? = nil) {
        self.role = role; self.permissions = permissions; self.actorId = actorId
    }

    init(_ object: [String: Any]) {
        role = (object["membership"] as? [String: Any])?["role"] as? String
        permissions = Set(((object["permissions"] as? [Any]) ?? []).compactMap { $0 as? String })
        actorId = (object["actor"] as? [String: Any])?["actor_id"] as? String
    }

    /// Workspace owners and admins (the web's `canAdminWorkspace`).
    public var isAdmin: Bool { ["owner", "admin"].contains(role?.lowercased() ?? "") }
}

/// The web's visibility rules for management controls (sol `canCreateChannelInScope`, `canManageChannel`,
/// `canManageScope`, `canAccessScopeSettings`). They only decide what is offered; Tower decides the write.
public enum ManagementPermissions {
    public static func isDirectMessageScope(_ scope: ScopeRecord) -> Bool { scope.kind?.lowercased() == "dm" }

    public static func canCreateChannel(in scope: ScopeRecord, membership: WorkspaceMembership?) -> Bool {
        if isDirectMessageScope(scope) { return true }
        if membership?.isAdmin == true || scope.canManage == true { return true }
        if scope.canManage == false { return false }
        guard let membership else { return false }
        return membership.permissions.contains("channel.create")
    }

    /// System and direct-message channels are never managed here (as on the web).
    public static func canManage(_ channel: ChannelRecord, membership: WorkspaceMembership?) -> Bool {
        guard !SidebarNavigation.isDirectMessageChannel(channel), channel.kind?.lowercased() != "system" else { return false }
        guard let membership else { return false }
        return membership.isAdmin || membership.permissions.contains("channel.manage")
    }

    public static func canManage(_ scope: ScopeRecord, membership: WorkspaceMembership?) -> Bool {
        if let canManage = scope.canManage { return canManage }
        return membership?.isAdmin == true
    }

    public static func canCreateScope(_ membership: WorkspaceMembership?) -> Bool {
        guard let membership else { return false }
        return membership.isAdmin || membership.permissions.contains("scope.create")
    }

    /// Scopes that take part in the personal order (not DM or system scopes).
    public static func isPersonallyOrdered(_ scope: ScopeRecord) -> Bool {
        !isDirectMessageScope(scope) && scope.kind?.lowercased() != "system"
    }
}

public enum ManagementOperation: Sendable {
    case readPermissions, createChannel, manageChannel, createScope, manageScope, scopeOrder, renameThread

    var permissionSentence: String {
        switch self {
        case .readPermissions: "You don't have access to this workspace."
        case .createChannel: "You don't have permission to create channels in this scope."
        case .manageChannel: "You need Manage access on this channel."
        case .createScope: "You don't have permission to create scopes in this workspace."
        case .manageScope: "You need Manage access on this scope."
        case .scopeOrder: "Your scope order couldn't be saved for this workspace."
        case .renameThread: "You don't have permission to rename this thread."
        }
    }
}

public enum ManagementError: LocalizedError, Equatable, Sendable {
    case locked
    case offline(String)
    case forbidden(String)
    case duplicate(String)
    case conflict(String)
    case notFound(String)
    case invalid(String)
    case unexpected(String)
    /// Tower saved the change, but reading the list back failed.
    case savedButNotRefreshed(String)

    public var errorDescription: String? {
        switch self {
        case .locked: "Unlock to make changes."
        case .offline(let detail): "Couldn't reach Tower, nothing was changed. \(detail)"
        case .forbidden(let message), .duplicate(let message), .conflict(let message), .notFound(let message), .invalid(let message),
             .unexpected(let message): message
        case .savedButNotRefreshed(let detail): "Saved on Tower, but the list couldn't be refreshed yet (\(detail)). It will update on the next refresh."
        }
    }

    /// Whether trying the same request again can help (shown as Retry).
    public var retryable: Bool {
        switch self {
        case .offline, .unexpected, .savedButNotRefreshed: true
        default: false
        }
    }

    static func classify(status: Int, object: [String: Any], operation: ManagementOperation) -> ManagementError {
        let code = (object["code"] as? String) ?? (object["error"] as? String) ?? ""
        switch (status, code) {
        case (403, _): return .forbidden(operation.permissionSentence)
        case (404, _): return .notFound(operation == .createChannel ? "This scope is no longer available." : "This item is no longer available. Refresh and try again.")
        case (409, "duplicate_channel"): return .duplicate("A channel with this name already exists in this scope.")
        case (409, "duplicate_scope"): return .duplicate("A scope with this name already exists in this workspace.")
        case (409, "scope_order_conflict"): return .conflict("Your scope order changed in another session. Try your move again.")
        case (409, _): return .conflict("This changed elsewhere. Refresh and try again.")
        case (400, _), (422, _):
            let fields = ((object["details"] as? [String: Any])?["fields"] as? [[String: Any]])?.compactMap { $0["message"] as? String } ?? []
            return .invalid(fields.isEmpty ? (object["message"] as? String ?? "Tower refused the request (\(code.isEmpty ? "HTTP \(status)" : code)).")
                                           : fields.joined(separator: " "))
        default:
            return .unexpected("Tower returned HTTP \(status)\(code.isEmpty ? "" : " (\(code))"). Nothing was changed.")
        }
    }
}

/// Channel context prompt in `metadata.agent_chat` (sol `agent-direct-chat.js`): legacy `basePrompt`/`contextPrompt`
/// are read and replaced by the canonical key; other metadata keys are kept.
public enum AgentChatConfig {
    public static let activation = "mention_then_continue"

    public static func contextPrompt(_ metadata: [String: Any]) -> String {
        let canonical = metadata["agent_chat"] as? [String: Any] ?? [:]
        return (canonical["context_prompt"] as? String) ?? (metadata["basePrompt"] as? String) ?? (metadata["contextPrompt"] as? String) ?? ""
    }

    public static func write(_ metadata: [String: Any], contextPrompt: String) -> [String: Any] {
        var next = metadata
        next.removeValue(forKey: "basePrompt")
        next.removeValue(forKey: "contextPrompt")
        var chat = next["agent_chat"] as? [String: Any] ?? [:]
        chat["enabled"] = true
        chat["context_prompt"] = contextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        chat["activation"] = activation
        next["agent_chat"] = chat
        return next
    }
}

extension ChannelRecord {
    /// The channel's metadata object from Tower's projection (empty when absent).
    public var metadata: [String: Any] {
        ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])?["metadata"] as? [String: Any] ?? [:]
    }
    public var contextPrompt: String { AgentChatConfig.contextPrompt(metadata) }
    public var channelDescription: String? {
        ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])?["description"] as? String
    }
}

extension ScopeRecord {
    /// Tower's `can_manage` from the scope list (nil when the row came from another route).
    public var canManage: Bool? {
        ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])?["can_manage"] as? Bool
    }
}
