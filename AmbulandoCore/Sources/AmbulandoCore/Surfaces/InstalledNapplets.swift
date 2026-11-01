import Foundation
import CoreFoundation

/// Workspace-installed code is a different authority from a personal HTTPS WApp or a canvas HTML File.
public struct InstalledNapplet: Codable, Sendable, Equatable, Identifiable {
    public let key: String
    public let version: Int
    public let revision: Int
    public let bridgeVersion: Int
    public let title: String
    public let capabilities: [String]
    public let sha256: String
    public var id: String { key }
    enum CodingKeys: String, CodingKey { case key, version, revision, title, capabilities, sha256; case bridgeVersion = "bridge_version" }
}

public struct NappletSnapshot: Sendable {
    public let installations: [InstalledNapplet]
    public let html: [String: String]
    public let projection: Data
    /// Values/revisions deliberately excluded: ordinary updates must not discard unsaved forms. Permissions,
    /// declared fields, reference visibility, identities and installation changes must discard them.
    public let authority: Data

    static func integer(_ x: Any?) -> Int? {
        guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.intValue), n.intValue > 0 else { return nil }
        return n.intValue
    }
    static func boolean(_ x: Any?) -> Bool? {
        guard let n = x as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }; return n.boolValue
    }
    public static func validKey(_ x: String) -> Bool { x.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil }

    public static func parse(_ data: Data, workspace: WorkspaceRecord, connection: ConnectionRecord, catalogue: Bool) throws -> Self {
        func fail() -> TowerError { .malformed("installed napplet authority") }
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["workspace_id"] as? String == workspace.id,
              let identity = o["identity"] as? [String: Any],
              identity["workspace_id"] as? String == workspace.id,
              identity["app_npub"] as? String == workspace.appNpub,
              let owner = identity["workspace_owner_npub"] as? String, NostrKeys.isValidNpub(owner),
              workspace.ownerNpub == nil || workspace.ownerNpub == owner,
              let tower = identity["tower_service_npub"] as? String, NostrKeys.isValidNpub(tower),
              connection.towerNpub == nil || connection.towerNpub == tower,
              let service = identity["workspace_service_npub"] as? String, NostrKeys.isValidNpub(service),
              catalogue || o["complete"] as? Bool == true,
              let rows = o["installations"] as? [[String: Any]], rows.count <= 200,
              let types = o["types"] as? [[String: Any]], types.count <= 200,
              let caps = o["capabilities"] as? [String: Any] else { throw fail() }
        if let raw = try? JSONSerialization.jsonObject(with: workspace.raw) as? [String: Any],
           let expected = (raw["identity"] as? [String: Any])?["workspace_service_npub"] as? String, expected != service { throw fail() }
        var seen = Set<String>(), installations: [InstalledNapplet] = [], html: [String: String] = [:]
        let allowed = Set(["org_data.read", "org_data.write", "org_data.schema", "profile.open", "dm.open"])
        for b in rows {
            guard let key = b["key"] as? String, validKey(key), seen.insert(key).inserted,
                  let version = integer(b["version"]), let revision = integer(b["revision"]), integer(b["bridge_version"]) == 1,
                  let title = b["title"] as? String, title.count <= 500,
                  let capabilities = b["capabilities"] as? [String], Set(capabilities).isSubset(of: allowed),
                  let digest = b["sha256"] as? String, digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let code = b["html"] as? String, code.utf8.count <= 524288, SHA256Hex.of(Data(code.utf8)) == digest else { throw fail() }
            installations.append(InstalledNapplet(key: key, version: version, revision: revision, bridgeVersion: 1, title: title, capabilities: capabilities, sha256: digest))
            html[key] = code
        }
        var projectedTypes: [[String: Any]] = [], records: [String: [[String: Any]]] = [:], authorityRecords: [String: [[String: Any]]] = [:]
        var fieldsByType: [String: [[String: Any]]] = [:]
        for t in types {
            guard let key = t["key"] as? String, validKey(key), fieldsByType[key] == nil,
                  let fields = t["fields"] as? [[String: Any]], fields.count <= 200,
                  let revision = integer(t["revision"]), let label = t["label"] as? String else { throw fail() }
            var normalizedFields: [[String: Any]] = [], fieldKeys = Set<String>()
            for field in fields {
                guard let fieldKey = field["key"] as? String, validKey(fieldKey), fieldKeys.insert(fieldKey).inserted,
                      let fieldLabel = field["label"] as? String, let kind = field["type"] as? String else { throw fail() }
                var normalized: [String: Any] = ["key": fieldKey, "label": fieldLabel, "type": kind, "required": field["required"] as? Bool == true]
                if let target = field["target_type"] as? String { guard validKey(target) else { throw fail() }; normalized["target_type"] = target }
                normalizedFields.append(normalized)
            }
            fieldsByType[key] = normalizedFields
            projectedTypes.append(["key": key, "label": label, "fields": normalizedFields, "revision": revision,
                                   "access": t["access"] ?? [:], "capabilities": t["capabilities"] ?? [:]])
            records[key] = []; authorityRecords[key] = []
        }
        let rawRecords = catalogue ? [] : o["records"] as? [[String: Any]]
        guard let rawRecords, rawRecords.count <= 10000 else { throw fail() }
        var ids = Set<String>()
        for r in rawRecords {
            guard let id = r["id"] as? String, UUID(uuidString: id) != nil, ids.insert(id).inserted,
                  let key = r["type_key"] as? String, let fields = fieldsByType[key], let revision = integer(r["revision"]),
                  let rawValues = r["values"] as? [String: Any] else { throw fail() }
            var values: [String: Any] = [:], refs: [String: Any] = [:]
            for f in fields {
                guard let k = f["key"] as? String, validKey(k), let kind = f["type"] as? String else { throw fail() }
                if let v = rawValues[k] {
                    guard v is NSNull || v is String || v is NSNumber else { throw fail() }
                    values[k] = v
                    if kind.hasSuffix("_ref") { refs[k] = v }
                }
            }
            records[key, default: []].append(["id": id, "type_key": key, "revision": revision, "values": values])
            // Include all IDs, matching the web authority signature, to detect narrowed record access.
            authorityRecords[key, default: []].append(["id": id, "references": refs])
        }
        let identities = o["identities"] as? [String: String] ?? [:]
        guard identities.allSatisfy({ UUID(uuidString: $0.key) != nil && NostrKeys.isValidNpub($0.value) }) else { throw fail() }
        let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(installations))
        let projection: [String: Any] = ["types": projectedTypes, "records": records, "capabilities": caps, "identities": identities,
                                       "installations": metadata, "bundles": [], "changes": []]
        let authority: [String: Any] = ["types": projectedTypes, "records": authorityRecords, "capabilities": caps, "identities": identities, "installations": metadata]
        return Self(installations: installations, html: html, projection: try JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys]),
                    authority: try JSONSerialization.data(withJSONObject: authority, options: [.sortedKeys]))
    }
}

/// Exact bridge-v1 message validation. WK host additionally binds message.webView, main frame and a random session.
public enum NappletIntent: Sendable, Equatable {
    case ready, refresh, close, dirty(Bool), write(path: String, method: String, body: Data)
    public static func parse(_ data: Data, session: String, capabilities: [String]) throws -> Self {
        let fail = TowerError.malformed("napplet bridge request")
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              NappletSnapshot.integer(d["version"]) == 1, d["session"] as? String == session, let type = d["type"] as? String else { throw fail }
        let keys = Set(d.keys), basic: Set<String> = ["version", "session", "type"]
        switch type {
        case "ready", "refresh", "close":
            guard keys == basic else { throw fail }; return type == "ready" ? .ready : type == "refresh" ? .refresh : .close
        case "dirty":
            guard keys == basic.union(["dirty"]), let dirty = NappletSnapshot.boolean(d["dirty"]) else { throw fail }; return .dirty(dirty)
        case "write":
            guard keys == basic.union(["path", "method", "body"]), let path = d["path"] as? String, let method = d["method"] as? String,
                  ["POST", "PATCH", "DELETE"].contains(method), let body = d["body"] as? [String: Any] else { throw fail }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let schema = path == "bootstrap" || parts == ["types"] || (parts.count == 2 && parts[0] == "types" && NappletSnapshot.validKey(parts[1]))
            guard capabilities.contains(schema ? "org_data.schema" : "org_data.write") else { throw fail }
            if schema {
                guard path == "bootstrap" && method == "POST" || parts == ["types"] && method == "POST" || parts.count == 2 && method == "PATCH" else { throw fail }
            } else {
                guard parts.count == 3 && method == "POST" || parts.count == 4 && ["PATCH", "DELETE"].contains(method),
                      parts[0] == "types", NappletSnapshot.validKey(parts[1]), parts[2] == "records",
                      parts.count != 4 || UUID(uuidString: parts[3]) != nil else { throw fail }
                if parts.count == 4 { guard NappletSnapshot.integer(body["expected_revision"]) != nil else { throw fail } }
            }
            let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            guard bytes.count <= 131072 else { throw fail }
            return .write(path: path, method: method, body: bytes)
        default: throw fail // no publication/install, URL, SQL, signing or workspace selection intent
        }
    }
}

extension TowerAPI {
    public func installedNapplets(workspace: WorkspaceRecord, connection: ConnectionRecord, catalogue: Bool) async throws -> NappletSnapshot {
        let data = try await client.request(path: try Self.base(workspace.id) + "/org-data/" + (catalogue ? "catalogue" : "snapshot"), appNpub: workspace.appNpub)
        return try NappletSnapshot.parse(data, workspace: workspace, connection: connection, catalogue: catalogue)
    }
    public func writeNapplet(workspace: WorkspaceRecord, path: String, method: String, body: Data) async throws {
        _ = try await client.request(method: method, path: try Self.base(workspace.id) + "/org-data/" + path, appNpub: workspace.appNpub, jsonBody: body)
    }
}

extension WorkspaceSync {
    public static let nappletDiscoveryRun = UUID().uuidString
    public static func nappletsKey(_ c: String, _ w: String) -> String { "installed-napplets:\(c):\(w)" }
    public func readNapplets(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, catalogue: Bool = false) async throws -> NappletSnapshot {
        try await identity.requireReader(npub: connection.signerNpub)
        do {
            let result = try await api(origin: TowerOrigin(connection.origin)).installedNapplets(workspace: workspace, connection: connection, catalogue: catalogue)
            try Task.checkCancellation()
            return result
        } catch {
            if !Task.isCancelled { try? await store.writer.setState(Self.nappletsKey(connection.id, workspace.id), nil) }
            throw error
        }
    }
    public func writeNapplet(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, path: String, method: String, body: Data) async throws {
        // Background read credentials must never acquire write authority through a published bundle.
        guard case .unlocked(let npub) = await identity.state, npub == connection.signerNpub else { throw IdentityError.locked }
        try await api(origin: TowerOrigin(connection.origin)).writeNapplet(workspace: workspace, path: path, method: method, body: body)
        try Task.checkCancellation()
    }
    public func refreshInstalledNapplets(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self, key = Self.nappletsKey(connection.id, workspace.id)
        await engine.enqueue(key, priority: priority, force: force) {
            do {
                let snapshot = try await sync.readNapplets(connection, workspace, catalogue: true)
                let list = try String(decoding: JSONEncoder().encode(snapshot.installations), as: UTF8.self)
                try await sync.store.writer.setState(key, Self.nappletDiscoveryRun + "\n" + UUID().uuidString + "\n" + list)
            } catch {
                if !Task.isCancelled { try await sync.store.writer.setState(key, nil) }
                throw error
            }
        }
    }
}

extension StoreReader {
    public func installedNapplets(connectionId: String, workspaceId: String) throws -> [InstalledNapplet] {
        guard let value = try state(WorkspaceSync.nappletsKey(connectionId, workspaceId)), value.hasPrefix(WorkspaceSync.nappletDiscoveryRun + "\n"),
              let data = value.split(separator: "\n", maxSplits: 2).last?.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([InstalledNapplet].self, from: data)
    }
}
