import Foundation

extension TowerAPI {
    /// Normal File ACL for code; private resource authority is verified separately below.
    public func genericNappletCode(workspace: String, app: String, fileId: String) async throws -> GenericNappletCode {
        guard GenericJSON.uuid(fileId) else { throw FileNappletError.invalid }
        let row = try await nappletFile(workspace: workspace, app: app, id: fileId, requireTopLevelWrite: true)
        try await genericChannel(workspace: workspace, app: app, file: row, viewer: nil)
        guard let meta = row["metadata"] as? [String: Any], TrackerDocument.boolean(meta["html_artifact"]) == true,
              let file = try? FileRecord(raw: rawJSON(row)), ArtefactType.file(file) == .html else { throw FileNappletError.invalid }
        let (bytes, version) = try await nappletBytes(workspace: workspace, app: app, file: row, mime: "text/html", limit: 4 * 1024 * 1024)
        guard let html = String(data: bytes, encoding: .utf8), let binding = try GenericNappletBinding.parse(html: html, metadata: rawJSON(meta)) else { throw FileNappletError.invalid }
        if binding.capability == "workspace-aggregate", binding.resourceId != workspace { throw FileNappletError.invalid }
        return GenericNappletCode(html: html, binding: binding, versionId: version, sha256: SHA256Hex.of(bytes))
    }
    private func genericChannel(workspace: String, app: String, file: [String: Any], viewer: String?) async throws {
        guard let channel = file["channel_id"] as? String, GenericJSON.uuid(channel) else { throw FileNappletError.unavailable }
        let result = try object(try await client.request(path: try Self.base(workspace) + "/channels/" + Self.uuid(channel), appNpub: app), "napplet channel")
        guard let c = result["channel"] as? [String: Any], c["id"] as? String == channel, c["workspace_id"] as? String == workspace,
              c["archived_at"] == nil || c["archived_at"] is NSNull,
              c["deleted_at"] == nil || c["deleted_at"] is NSNull, c["record_state"] as? String != "archived" else { throw FileNappletError.unavailable }
        if let viewer { guard c["kind"] as? String == "dm", c["participant_npubs"] as? [String] == [viewer] else { throw FileNappletError.unavailable } }
    }
    public func authorizeGenericNapplet(workspace: String, app: String, viewer: String, fileId: String, expected: GenericNappletCode) async throws -> Bool {
        guard try await genericNappletCode(workspace: workspace, app: app, fileId: fileId) == expected else { throw FileNappletError.unavailable }
        if expected.binding.capability == "private-json-file" {
            let row = try await nappletFile(workspace: workspace, app: app, id: expected.binding.resourceId, requireTopLevelWrite: true)
            try await genericChannel(workspace: workspace, app: app, file: row, viewer: viewer)
            return TrackerDocument.boolean(row["can_write"]) == true && expected.binding.allowsSave
        }
        guard expected.binding.resourceId == workspace else { throw FileNappletError.invalid }
        let me = try object(try await client.request(path: try Self.base(workspace) + "/me", appNpub: app), "napplet membership")
        guard let i = me["identity"] as? [String: String], i["workspace_id"] == workspace, i["app_npub"] == app else { throw FileNappletError.unavailable }
        return false
    }
    public func readGenericJSON(workspace: String, app: String, viewer: String, fileId: String, expected: GenericNappletCode) async throws -> FileNappletData {
        guard expected.binding.capability == "private-json-file" else { throw FileNappletError.invalid }
        let canWrite = try await authorizeGenericNapplet(workspace: workspace, app: app, viewer: viewer, fileId: fileId, expected: expected)
        let row = try await nappletFile(workspace: workspace, app: app, id: expected.binding.resourceId, requireTopLevelWrite: true)
        let (bytes, version) = try await nappletBytes(workspace: workspace, app: app, file: row, mime: "application/json", limit: GenericJSON.maxBytes)
        _ = try GenericJSON.canonicalData(bytes)
        let after = try await authorizeGenericNapplet(workspace: workspace, app: app, viewer: viewer, fileId: fileId, expected: expected)
        guard canWrite == after else { throw FileNappletError.unavailable }
        return FileNappletData(bytes: bytes, versionId: version, canWrite: after)
    }
    public func saveGenericJSON(workspace: String, app: String, viewer: String, fileId: String, expected: GenericNappletCode, base: String, bytes: Data) async throws -> FileNappletData {
        guard expected.binding.allowsSave, GenericJSON.uuid(base) else { throw FileNappletError.invalid }
        let canonical = try GenericJSON.canonicalData(bytes)
        let current = try await readGenericJSON(workspace: workspace, app: app, viewer: viewer, fileId: fileId, expected: expected)
        guard current.canWrite else { throw FileNappletError.unavailable }
        guard current.versionId == base else { throw FileNappletError.conflict }
        let stored = try await store(workspaceId: workspace, appNpub: app, bytes: canonical, contentType: "application/json", fileName: "napplet-data.json", prepared: nil, onPrepared: { _ in })
        guard try await authorizeGenericNapplet(workspace: workspace, app: app, viewer: viewer, fileId: fileId, expected: expected) else { throw FileNappletError.unavailable }
        try Task.checkCancellation()
        let body = try rawJSON(["base_version_id":base, "storage_object_id":stored, "client_mutation_id":UUID().uuidString.lowercased()])
        let committed: String?
        do {
            let result = try object(try await client.request(method: "POST", path: try Self.base(workspace) + "/files/" + Self.uuid(expected.binding.resourceId) + "/versions", appNpub: app, jsonBody: body), "generic JSON save")
            guard let row = result["version"] as? [String: Any], let id = row["id"] as? String, GenericJSON.uuid(id) else { throw FileNappletError.unavailable }; committed = id
        } catch {
            if case TowerError.http(let status, _, _) = error, status == 409 { throw FileNappletError.conflict }
            try Task.checkCancellation(); committed = nil // exact readback only; never retry a mutation
        }
        let saved = try await readGenericJSON(workspace: workspace, app: app, viewer: viewer, fileId: fileId, expected: expected)
        guard saved.versionId != base, committed == nil || saved.versionId == committed, saved.bytes == canonical else { throw FileNappletError.unavailable }
        return saved
    }
    public func readGenericAggregate(workspace: String, app: String, viewer: String, fileId: String, expected: GenericNappletCode, range: String, identity: [String: String]) async throws -> Data {
        guard expected.binding.capability == "workspace-aggregate", WorkspaceReportRequest.ranges.contains(range) else { throw FileNappletError.invalid }
        _ = try await authorizeGenericNapplet(workspace: workspace, app: app, viewer: viewer, fileId: fileId, expected: expected)
        let bytes = try await client.request(path: try Self.base(workspace) + "/workspace-report", query: [URLQueryItem(name: "range", value: range), URLQueryItem(name: "top_n", value: "10")], appNpub: app)
        let value = try WorkspaceReportDocument.validate(bytes, workspace: workspace, range: range, identity: identity)
        _ = try await authorizeGenericNapplet(workspace: workspace, app: app, viewer: viewer, fileId: fileId, expected: expected)
        return value
    }
}

extension WorkspaceSync {
    public func genericNappletCode(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String) async throws -> GenericNappletCode {
        try await identity.requireReader(npub: c.signerNpub)
        return try await api(origin: TowerOrigin(c.origin)).genericNappletCode(workspace: w.id, app: w.appNpub, fileId: fileId)
    }
    public func authorizeGenericNapplet(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: GenericNappletCode) async throws -> Bool {
        try await identity.requireReader(npub: c.signerNpub)
        return try await api(origin: TowerOrigin(c.origin)).authorizeGenericNapplet(workspace: w.id, app: w.appNpub, viewer: c.signerNpub, fileId: fileId, expected: code)
    }
    public func readGenericJSON(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: GenericNappletCode) async throws -> FileNappletData {
        try await identity.requireReader(npub: c.signerNpub)
        return try await api(origin: TowerOrigin(c.origin)).readGenericJSON(workspace: w.id, app: w.appNpub, viewer: c.signerNpub, fileId: fileId, expected: code)
    }
    public func saveGenericJSON(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: GenericNappletCode, base: String, bytes: Data) async throws -> FileNappletData {
        try await identity.requireSigner(npub: c.signerNpub)
        return try await api(origin: TowerOrigin(c.origin)).saveGenericJSON(workspace: w.id, app: w.appNpub, viewer: c.signerNpub, fileId: fileId, expected: code, base: base, bytes: bytes)
    }
    public func readGenericAggregate(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: GenericNappletCode, range: String) async throws -> Data {
        try await identity.requireReader(npub: c.signerNpub)
        guard let root = try JSONSerialization.jsonObject(with: w.raw) as? [String: Any], let expected = root["identity"] as? [String: String], expected["workspace_id"] == w.id, expected["app_npub"] == w.appNpub, expected["tower_service_npub"] == c.towerNpub else { throw FileNappletError.unavailable }
        return try await api(origin: TowerOrigin(c.origin)).readGenericAggregate(workspace: w.id, app: w.appNpub, viewer: c.signerNpub, fileId: fileId, expected: code, range: range, identity: expected)
    }
    /// Re-fetch a selected existing File. Installation never creates code or data.
    public func genericNappletFile(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String) async throws -> FileRecord {
        try await identity.requireReader(npub: c.signerNpub)
        let api = try api(origin: TowerOrigin(c.origin))
        _ = try await api.genericNappletCode(workspace: w.id, app: w.appNpub, fileId: fileId)
        let row = try await api.nappletFile(workspace: w.id, app: w.appNpub, id: fileId, requireTopLevelWrite: true)
        let file = try FileRecord(raw: rawJSON(row))
        _ = try await store.writer.upsertFiles(workspaceId: w.id, [file]); return file
    }
}
