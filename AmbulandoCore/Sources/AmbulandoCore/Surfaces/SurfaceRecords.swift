import Foundation

// Typed views over the Tower serializers behind the Context Tree, Canvas, agents, Toolbox and personal pins, read from
// `tower/src/services/flightdeck-pg-context-tree.ts`, `flightdeck-pg-canvases.ts`, `flightdeck-pg-autopilot-connections.ts`,
// `serializeFlightDeckPgAgentActivity`, `serializeFlightDeckPgPersonalWapp` and the `personal_pin` record family
// (`thread-pins.ts`). Each keeps its canonical JSON in `raw`; ids are lower-cased UUIDs or the record is refused.

private func object(_ raw: Data, _ what: String) throws -> [String: Any] {
    guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw TowerError.malformed(what) }
    return o
}

private func nonEmpty(_ value: Any?) -> String? {
    guard let s = value as? String else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

private func number(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}

// MARK: Context Tree

/// One node of a scope's Context Tree (`flightdeck_pg_context_components`).
public struct ContextComponentRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let scopeId: String
    public let id: String
    public let parentId: String?
    public let title: String
    public let sortOrder: Int
    public let rowVersion: Int
    public let updatedAt: String
    public let raw: Data

    public init(raw: Data) throws {
        let o = try object(raw, "context component")
        guard let id = lowerUUID(o["id"] as? String), let w = lowerUUID(o["workspace_id"] as? String),
              let s = lowerUUID(o["scope_id"] as? String) else { throw TowerError.malformed("context component") }
        self.id = id; workspaceId = w; scopeId = s
        parentId = lowerUUID(o["parent_id"] as? String)
        title = nonEmpty(o["title"]) ?? "Untitled"
        sortOrder = flexibleInt(o["sort_order"]) ?? 0
        rowVersion = flexibleInt(o["row_version"]) ?? 0
        updatedAt = (o["updated_at"] as? String) ?? (o["created_at"] as? String) ?? ""
        self.raw = raw
    }
}

/// A follow-latest Artifact WApp page. Its access authority is the Artifact WApp itself; Tower never fetches it.
public struct ArtifactTarget: Sendable, Equatable, Hashable {
    public let origin: String
    public let project: String
    public let artifact: String

    /// Same rules as Tower `normalizeContextTarget` and sol `canonicalContextArtifact`.
    init?(_ o: [String: Any]?) {
        let segment = /^[A-Za-z0-9_-]{1,128}$/
        guard let o, let originText = o["origin"] as? String, let url = URL(string: originText), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let host = url.host, !host.isEmpty,
              let project = o["project"] as? String, (try? segment.wholeMatch(in: project)) != nil,
              let artifact = o["artifact"] as? String, (try? segment.wholeMatch(in: artifact)) != nil,
              o["page"] as? String == "index.html", o["version_policy"] as? String == "latest" else { return nil }
        origin = "\(scheme)://\(host.lowercased())" + (url.port.map { ":\($0)" } ?? "")
        self.project = project; self.artifact = artifact
    }

    /// `origin/artifacts/<project>/<artifact>/` (sol `contextArtifactLatestUrl`).
    public var latestURL: URL? { URL(string: "\(origin)/artifacts/\(project)/\(artifact)/") }
    public var isHTTPS: Bool { origin.hasPrefix("https://") }
}

/// A component's typed link to a task, document, file or artifact, with Tower's per-viewer resolution.
public struct ContextReferenceRecord: Sendable, Equatable, Identifiable {
    public enum TargetType: String, Sendable { case task, doc, file, artifact }
    public enum Resolution: String, Sendable { case available, unavailable, external }

    public let workspaceId: String
    public let scopeId: String
    public let componentId: String
    public let id: String
    public let targetType: TargetType?
    /// Raw `target_type`, kept when the type is one this client does not know.
    public let targetTypeName: String
    public let targetRecordId: String?
    public let artifact: ArtifactTarget?
    public let resolution: Resolution
    /// Title Tower resolved for this viewer (only when available).
    public let resolvedTitle: String?
    public let sortOrder: Int
    public let rowVersion: Int
    public let updatedAt: String
    public let raw: Data

    public init(raw: Data) throws {
        let o = try object(raw, "context reference")
        guard let id = lowerUUID(o["id"] as? String), let w = lowerUUID(o["workspace_id"] as? String),
              let s = lowerUUID(o["scope_id"] as? String), let c = lowerUUID(o["component_id"] as? String) else { throw TowerError.malformed("context reference") }
        self.id = id; workspaceId = w; scopeId = s; componentId = c
        targetTypeName = (o["target_type"] as? String) ?? ""
        targetType = TargetType(rawValue: targetTypeName)
        let target = o["target"] as? [String: Any]
        targetRecordId = targetType == .artifact ? nil : lowerUUID(target?["record_id"] as? String)
        artifact = targetType == .artifact ? ArtifactTarget(target) : nil
        let resolution = o["resolution"] as? [String: Any]
        // Missing or unknown resolution is treated as unavailable: access is never assumed.
        self.resolution = Resolution(rawValue: (resolution?["status"] as? String) ?? "") ?? .unavailable
        resolvedTitle = self.resolution == .available ? nonEmpty(resolution?["title"]) : nil
        sortOrder = flexibleInt(o["sort_order"]) ?? 0
        rowVersion = flexibleInt(o["row_version"]) ?? 0
        updatedAt = (o["updated_at"] as? String) ?? ""
        self.raw = raw
    }
}

// MARK: Canvas

public struct CanvasViewport: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var scale: Double
    public init(x: Double = 0, y: Double = 0, scale: Double = 1) { self.x = x; self.y = y; self.scale = scale }
}

/// A canvas definition (`serializeFlightDeckPgCanvas`). The list route has no per-row workspace id, so the route's
/// workspace is bound in.
public struct CanvasRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let title: String
    public let position: Int
    public let visibilityMode: String
    /// The saved viewport (Tower clamps scale to 0.2…3).
    public let viewport: CanvasViewport
    public let canManage: Bool
    public let rowVersion: Int
    public let updatedAt: String
    public let raw: Data

    public init(raw: Data, workspaceId: String) throws {
        let o = try object(raw, "canvas")
        guard let id = lowerUUID(o["id"] as? String ?? o["canvas_id"] as? String), let w = lowerUUID(workspaceId) else { throw TowerError.malformed("canvas") }
        self.id = id; self.workspaceId = w
        title = nonEmpty(o["title"]) ?? "Untitled canvas"
        position = flexibleInt(o["position"]) ?? 0
        visibilityMode = ((o["visibility"] as? [String: Any])?["mode"] as? String) ?? "workspace"
        let v = o["viewport"] as? [String: Any]
        viewport = CanvasViewport(x: number(v?["x"]) ?? 0, y: number(v?["y"]) ?? 0, scale: min(3, max(0.2, number(v?["scale"]) ?? 1)))
        canManage = o["can_manage"] as? Bool == true
        rowVersion = flexibleInt(o["row_version"]) ?? 0
        updatedAt = (o["updated_at"] as? String) ?? ""
        self.raw = raw
    }
}

/// The stored snapshot response for one canvas: naplets (already resolved and authorized by Tower for this viewer)
/// and native elements. Kept as Tower sent them; parsed into a `CanvasScene` off the main actor when shown.
public struct CanvasSnapshotRecord: Sendable, Equatable {
    public let workspaceId: String
    public let canvasId: String
    public let canvasRowVersion: Int
    /// `{"naplets": [...], "elements": [...]}` exactly as returned (keys sorted).
    public let bytes: Data
    public let fetchedAt: String
    public init(workspaceId: String, canvasId: String, canvasRowVersion: Int, bytes: Data, fetchedAt: String) {
        self.workspaceId = workspaceId; self.canvasId = canvasId; self.canvasRowVersion = canvasRowVersion; self.bytes = bytes; self.fetchedAt = fetchedAt
    }
}

/// Verified bytes of one Excalidraw board version (a Flight Deck File whose current version holds the scene).
public struct BoardSceneRecord: Sendable, Equatable {
    public let workspaceId: String
    public let fileId: String
    public let versionId: String
    public let sha256: String
    public let bytes: Data
    public let fetchedAt: String
    public init(workspaceId: String, fileId: String, versionId: String, sha256: String, bytes: Data, fetchedAt: String) {
        self.workspaceId = workspaceId; self.fileId = fileId; self.versionId = versionId; self.sha256 = sha256; self.bytes = bytes; self.fetchedAt = fetchedAt
    }
}

// MARK: Agents

/// An agent installed in the workspace from an Autopilot connection (`serializeWorkspaceAgent`). Connection and FIPS
/// endpoint details are not used: this client reaches agents only through Tower records.
public struct WorkspaceAgentRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let agentNpub: String
    public let displayName: String
    public let avatarURL: String?
    public let capabilities: [String]
    public let sortOrder: Int
    public let isVisible: Bool
    public let archived: Bool
    public let rowVersion: Int
    public let updatedAt: String
    public let raw: Data

    public init(raw: Data) throws {
        let o = try object(raw, "workspace agent")
        guard let id = lowerUUID(o["id"] as? String), let w = lowerUUID(o["workspace_id"] as? String),
              let npub = nonEmpty(o["agent_npub"]), npub.hasPrefix("npub1") else { throw TowerError.malformed("workspace agent") }
        self.id = id; workspaceId = w; agentNpub = npub
        displayName = nonEmpty(o["display_name"]) ?? "Agent"
        avatarURL = nonEmpty(o["avatar_url"])
        capabilities = (o["capabilities"] as? [Any])?.compactMap { $0 as? String } ?? []
        sortOrder = flexibleInt(o["sort_order"]) ?? 0
        isVisible = (o["is_visible"] as? Bool) ?? true
        archived = !(o["archived_at"] is NSNull || o["archived_at"] == nil)
        rowVersion = flexibleInt(o["row_version"]) ?? 0
        updatedAt = (o["updated_at"] as? String) ?? ""
        self.raw = raw
    }
}

/// One user-visible agent activity Tower materialised for a conversation (`serializeFlightDeckPgAgentActivity`).
public struct AgentActivityRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let activityId: String
    public let scopeId: String?
    public let channelId: String
    public let threadId: String?
    public let agentNpub: String
    public let state: String
    public let label: String?
    public let summary: String?
    public let body: String?
    public let sequence: Int
    /// `live` or `stale` (Tower: lease expired without a terminal state).
    public let leaseHealth: String
    public let queuePosition: Int?
    public let terminalAt: String?
    public let createdAt: String
    public let updatedAt: String
    public let raw: Data

    public static let terminalStates: Set<String> = ["completed", "failed", "cancelled"]
    public var isTerminal: Bool { Self.terminalStates.contains(state) || terminalAt != nil }

    public init(raw: Data) throws {
        let o = try object(raw, "agent activity")
        // Same acceptance as sol `mapPgAgentActivity`: only user-visible rows with an activity id and a sequence.
        guard let id = lowerUUID(o["id"] as? String), let w = lowerUUID(o["workspace_id"] as? String),
              let c = lowerUUID(o["channel_id"] as? String), let activity = nonEmpty(o["activity_id"]),
              o["visibility"] as? String == "user_visible", let sequence = flexibleInt(o["sequence"]), sequence >= 0 else { throw TowerError.malformed("agent activity") }
        self.id = id; workspaceId = w; channelId = c; activityId = activity; self.sequence = sequence
        scopeId = lowerUUID(o["scope_id"] as? String); threadId = lowerUUID(o["thread_id"] as? String)
        agentNpub = nonEmpty(o["agent_npub"]) ?? ""
        state = (nonEmpty(o["state"]) ?? "working").lowercased()
        label = nonEmpty(o["label"]); summary = nonEmpty(o["summary"]); body = nonEmpty(o["body"])
        leaseHealth = (nonEmpty(o["lease_health"]) ?? "live").lowercased()
        queuePosition = flexibleInt(o["queue_position"]).flatMap { $0 > 0 ? $0 : nil }
        terminalAt = nonEmpty(o["terminal_at"])
        createdAt = (o["created_at"] as? String) ?? ""
        updatedAt = (o["updated_at"] as? String) ?? createdAt
        self.raw = raw
    }
}

// MARK: Toolbox

/// A personal WApp in the viewer's Toolbox (`serializeFlightDeckPgPersonalWapp`). Its UI is a web document its
/// publisher owns; only an HTTPS `launch_url` is ever opened.
public struct PersonalWappRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let title: String
    public let description: String?
    public let launchURL: String?
    public let iconURL: String?
    public let scopeId: String?
    public let channelId: String?
    public let sortOrder: Int
    public let status: String
    public let ownerNpub: String?
    public let rowVersion: Int
    public let updatedAt: String
    public let raw: Data

    public init(raw: Data) throws {
        let o = try object(raw, "personal WApp")
        guard let id = lowerUUID(o["id"] as? String ?? o["record_id"] as? String), let w = lowerUUID(o["workspace_id"] as? String) else {
            throw TowerError.malformed("personal WApp")
        }
        self.id = id; workspaceId = w
        title = nonEmpty(o["title"]) ?? "WApp"
        description = nonEmpty(o["description"])
        launchURL = nonEmpty(o["launch_url"]); iconURL = nonEmpty(o["icon_url"])
        scopeId = lowerUUID(o["scope_id"] as? String); channelId = lowerUUID(o["channel_id"] as? String)
        sortOrder = flexibleInt(o["sort_order"]) ?? 0
        status = (nonEmpty(o["status"]) ?? "active").lowercased()
        ownerNpub = nonEmpty(o["owner_npub"]) ?? nonEmpty(o["owner_actor_npub"])
        rowVersion = flexibleInt(o["row_version"]) ?? 0
        updatedAt = (o["updated_at"] as? String) ?? ""
        self.raw = raw
    }

    /// The launch URL if it is an HTTPS URL without credentials; anything else is never opened.
    public var safeLaunchURL: URL? { WebContentPolicy.launchURL(launchURL) }

    /// Where the launcher logo may come from, best first (sol `getPersonalWappIconUrl`): `icon_url`, the metadata's
    /// manifest icon, icon and favicon, then `/favicon.ico` at the launch origin. Only `storage://<uuid>` objects and
    /// HTTPS addresses on public hosts are kept; the caller shows initials when none loads.
    public var logoCandidates: [LauncherLogoSource] {
        let metadata = ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])?["metadata"] as? [String: Any] ?? [:]
        var texts = [iconURL] + ["manifest_icon_url", "icon_url", "favicon_url"].map { nonEmpty(metadata[$0]) }
        if let launch = safeLaunchURL, let origin = WebContentPolicy.origin(of: launch) { texts.append(origin + "/favicon.ico") }
        var seen = Set<LauncherLogoSource>()
        return texts.compactMap { $0.flatMap(LauncherLogoSource.init) }.filter { seen.insert($0).inserted }
    }
}

/// A launcher logo address the app is willing to load: a Tower storage object (signed download into the file cache)
/// or a public HTTPS image (the credential-free avatar cache).
public enum LauncherLogoSource: Sendable, Hashable {
    case storage(objectId: String)
    case web(URL)

    public init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("storage://") {
            let id = String(value.dropFirst("storage://".count))
            guard UUID(uuidString: id) != nil else { return nil }
            self = .storage(objectId: id.lowercased())
        } else if let url = AvatarURLPolicy.validate(value) {
            self = .web(url)
        } else {
            return nil
        }
    }
}

/// Origin rules for publisher-owned web content (WApps, artifacts). HTTPS only, no embedded credentials, and the
/// content is confined to the origin it was opened for.
public enum WebContentPolicy {
    public static func launchURL(_ text: String?) -> URL? {
        guard let text, let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, !host.lowercased().hasSuffix(".fips"), let url = components.url else { return nil }
        return url
    }

    /// `scheme://host[:port]` of a URL, lower-cased.
    public static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// Whether a navigation may stay inside the labelled view opened for `origin`.
    public static func allows(_ url: URL, within origin: String) -> Bool {
        if url.scheme == "about" { return url.absoluteString == "about:blank" }
        return Self.origin(of: url) == origin
    }

    public enum Decision: Equatable, Sendable {
        /// Load inside the labelled view.
        case allow
        /// Not loaded. `offerExternal` is the HTTPS URL the user may choose to open in Safari (outside the app).
        case refuse(offerExternal: URL?)
    }

    /// The single navigation rule for publisher web content. It is applied to every navigation, including server
    /// redirects (a redirect is a new navigation to its target) and links asking for a new window, which never open a
    /// second view: a same-origin target loads in place, anything else is refused and only offered to Safari if HTTPS.
    public static func decide(_ url: URL?, within origin: String, newWindow: Bool) -> Decision {
        guard let url else { return .refuse(offerExternal: nil) }
        if allows(url, within: origin) { return .allow }
        return .refuse(offerExternal: launchURL(url.absoluteString))
    }
}

// MARK: Personal pins

/// One of the viewer's personal pins (`flightdeck_pg_thread_pins` row, record family `personal_pin`). An unpinned row is a
/// tombstone that Tower keeps; it is stored so a stale device can never resurrect the pin.
public struct PinRecord: Sendable, Equatable, Identifiable {
    public enum ResourceType: String, Sendable, CaseIterable { case thread, task, document, channel }

    public let workspaceId: String
    public let id: String
    public let resourceType: ResourceType
    public let resourceId: String
    public let channelId: String?
    public let scopeId: String?
    public let pinned: Bool
    public let orderPosition: Int?
    public let pinnedAt: String?
    public let rowVersion: Int
    public let updatedAt: String
    public let raw: Data

    public init(raw: Data) throws {
        let o = try object(raw, "personal pin")
        guard let id = lowerUUID(o["id"] as? String), let w = lowerUUID(o["workspace_id"] as? String),
              let type = ResourceType(rawValue: (o["resource_type"] as? String) ?? (o["thread_id"] is String ? "thread" : "")),
              let resource = lowerUUID(o["resource_id"] as? String ?? o["thread_id"] as? String) else { throw TowerError.malformed("personal pin") }
        self.id = id; workspaceId = w; resourceType = type; resourceId = resource
        channelId = lowerUUID(o["channel_id"] as? String); scopeId = lowerUUID(o["scope_id"] as? String)
        pinned = o["pinned"] as? Bool == true
        orderPosition = flexibleInt(o["order_position"])
        pinnedAt = nonEmpty(o["pinned_at"])
        rowVersion = flexibleInt(o["row_version"]) ?? 0
        updatedAt = (o["updated_at"] as? String) ?? ""
        self.raw = raw
    }

    /// Tower's display order (`movePersonalPin`): positioned rows after unpositioned ones, which are newest first.
    public static func displayOrder(_ a: PinRecord, _ b: PinRecord) -> Bool {
        switch (a.orderPosition, b.orderPosition) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(x), .some(y)) where x != y: return x < y
        case (nil, nil) where a.pinnedAt != b.pinnedAt: return (a.pinnedAt ?? "") > (b.pinnedAt ?? "")
        default: return (a.resourceType.rawValue, a.resourceId) < (b.resourceType.rawValue, b.resourceId)
        }
    }
}
