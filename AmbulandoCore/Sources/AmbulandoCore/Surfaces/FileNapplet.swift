import Foundation
import CoreFoundation

/// File bridge v1 deliberately admits one reviewed format. It never accepts paths, URLs or signing intents.
public enum FileNappletError: Error, Sendable { case invalid, unavailable, conflict, forbidden }

public enum TrackerDocument {
    public static let maxBytes = 1024 * 1024
    static func exact(_ object: [String: Any], _ keys: Set<String>) -> Bool { Set(object.keys) == keys }
    static func number(_ value: Any?) -> NSNumber? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }; return n
    }
    static func boolean(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }; return n.boolValue
    }
    static func uuid(_ value: Any?) -> String? {
        guard let s = value as? String, UUID(uuidString: s) != nil else { return nil }; return s.lowercased()
    }
    public static func validate(_ data: Data, previous: Data? = nil) throws {
        guard data.count <= maxBytes, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              exact(root, ["format", "metrics", "days"]), root["format"] as? String == "daily-tracker-v1",
              let metrics = root["metrics"] as? [[String: Any]], metrics.count <= 200,
              let days = root["days"] as? [String: [String: Any]], days.count <= 36600 else { throw FileNappletError.invalid }
        var types: [String: String] = [:]
        for metric in metrics {
            guard exact(metric, ["id", "label", "type", "unit", "archived"]),
                  let id = metric["id"] as? String, uuid(id) != nil, types[id] == nil,
                  let label = metric["label"] as? String, (1...120).contains(label.utf16.count), !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasControls(label),
                  let type = metric["type"] as? String, ["boolean", "number"].contains(type),
                  let unit = metric["unit"] as? String, unit.utf16.count <= 24, !hasControls(unit), boolean(metric["archived"]) != nil else { throw FileNappletError.invalid }
            types[id] = type
        }
        for (date, entries) in days {
            guard validDate(date) else { throw FileNappletError.invalid }
            for (id, value) in entries {
                guard let type = types[id],
                      type == "boolean" ? boolean(value) != nil : number(value)?.doubleValue.isFinite == true else { throw FileNappletError.invalid }
            }
        }
        if let previous {
            try validate(previous)
            let old = try JSONSerialization.jsonObject(with: previous) as! [String: Any]
            let used = Set((old["days"] as! [String: [String: Any]]).values.flatMap { $0.keys })
            for metric in old["metrics"] as! [[String: Any]] {
                let id = metric["id"] as! String
                // Used definitions are archived, never deleted or changed to another type.
                if used.contains(id), types[id] != metric["type"] as? String { throw FileNappletError.invalid }
            }
        }
    }
    static func hasControls(_ value: String) -> Bool { value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    static func validDate(_ date: String) -> Bool {
        guard date.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}\\z", options: .regularExpression) != nil else { return false }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        let y = parts[0], m = parts[1], d = parts[2]
        guard y > 0, (1...12).contains(m) else { return false }
        let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
        return (1...([31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1])).contains(d)
    }
}

public struct FileNappletBinding: Codable, Sendable, Equatable {
    public let dataFileId: String
    public static func parse(html: String, metadata: Data) throws -> Self? {
        let meta = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] ?? [:]
        guard let raw = meta["napplet"] else { return nil }
        guard let n = raw as? [String: Any], TrackerDocument.exact(n, ["version", "app_id", "bindings"]),
              TrackerDocument.number(n["version"]) == 1, n["app_id"] as? String == "daily-tracker",
              let bindings = n["bindings"] as? [String: Any], Set(bindings.keys) == ["tracker"],
              let tracker = bindings["tracker"] as? [String: Any], Set(tracker.keys) == ["file_id"],
              let id = TrackerDocument.uuid(tracker["file_id"]) else { throw FileNappletError.invalid }
        // Parse script tags, rather than accepting a manifest-shaped substring elsewhere in the source.
        let regex = try NSRegularExpression(pattern: "<script\\b([^>]*)>([\\s\\S]*?)</script\\s*>", options: [.caseInsensitive])
        let text = html as NSString
        let candidates = regex.matches(in: html, range: NSRange(location: 0, length: text.length)).filter {
            text.substring(with: $0.range(at: 1)).range(of: "\\bid\\s*=\\s*([\"'])wingman-napplet-manifest\\1", options: [.regularExpression, .caseInsensitive]) != nil
        }
        guard candidates.count == 1, let match = candidates.first,
              text.substring(with: match.range(at: 1)).range(of: "\\btype\\s*=\\s*([\"'])application/json\\1", options: [.regularExpression, .caseInsensitive]) != nil,
              let manifest = try JSONSerialization.jsonObject(with: Data(text.substring(with: match.range(at: 2)).utf8)) as? [String: Any],
              TrackerDocument.exact(manifest, ["version", "app_id", "bindings"]), TrackerDocument.number(manifest["version"]) == 1,
              manifest["app_id"] as? String == "daily-tracker", let declared = manifest["bindings"] as? [String: Any], Set(declared.keys) == ["tracker"],
              let definition = declared["tracker"] as? [String: Any], TrackerDocument.exact(definition, ["format", "operations", "privacy"]),
              definition["format"] as? String == "daily-tracker-v1", definition["privacy"] as? String == "self",
              definition["operations"] as? [String] == ["read", "save"] else { throw FileNappletError.invalid }
        return Self(dataFileId: id)
    }
}

public struct FileNappletRequest: Sendable {
    public let id: String
    public let operation: String
    public let base: String?
    public let value: Data?
    public let dirty: Bool?
    public static func parse(_ data: Data, session: String) throws -> Self {
        guard data.count <= TrackerDocument.maxBytes + 1024,
              let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["type"] as? String == "wingman-napplet-data", TrackerDocument.number(o["version"]) == 1,
              o["session"] as? String == session, let id = o["requestId"] as? String,
              id.range(of: "^[a-zA-Z0-9_-]{1,64}\\z", options: .regularExpression) != nil,
              let operation = o["operation"] as? String else { throw FileNappletError.invalid }
        let common: Set<String> = ["type", "version", "session", "requestId", "operation"]
        var base: String?, value: Data?, dirty: Bool?
        if operation == "dirty" {
            guard TrackerDocument.exact(o, common.union(["dirty"])), let flag = TrackerDocument.boolean(o["dirty"]) else { throw FileNappletError.invalid }; dirty = flag
        } else {
            guard o["binding"] as? String == "tracker" else { throw FileNappletError.invalid }
            if operation == "read" { guard TrackerDocument.exact(o, common.union(["binding"])) else { throw FileNappletError.invalid } }
            else if operation == "save" {
                guard TrackerDocument.exact(o, common.union(["binding", "baseVersionId", "value"])), let version = TrackerDocument.uuid(o["baseVersionId"]), let object = o["value"] as? [String: Any] else { throw FileNappletError.invalid }
                base = version; value = try rawJSON(object); try TrackerDocument.validate(value!)
            } else { throw FileNappletError.invalid }
        }
        return Self(id: id, operation: operation, base: base, value: value, dirty: dirty)
    }
}

public struct FileNappletCode: Codable, Sendable, Equatable {
    public let channelIds: [String]
    public let html: String
    public let binding: FileNappletBinding?
    public let versionId: String
    public let sha256: String
    init(html: String, binding: FileNappletBinding?, versionId: String, sha256: String? = nil, channelIds: [String] = []) {
        self.html = html; self.binding = binding; self.versionId = versionId; self.channelIds = channelIds
        self.sha256 = sha256 ?? SHA256Hex.of(Data(html.utf8))
    }
}
public struct FileNappletData: Codable, Sendable {
    public let bytes: Data
    public let versionId: String
    public let canWrite: Bool
    public let channelId: String?
    public init(bytes: Data, versionId: String, canWrite: Bool, channelId: String? = nil) { self.bytes = bytes; self.versionId = versionId; self.canWrite = canWrite; self.channelId = channelId }
}

extension TowerAPI {
    func nappletFile(workspace: String, app: String, id: String, requireTopLevelWrite: Bool = false) async throws -> [String: Any] {
        let o = try object(try await client.request(path: try Self.base(workspace) + "/files/" + Self.uuid(id), appNpub: app), "napplet file")
        guard let row = o["file"] as? [String: Any], lowerUUID(row["id"] as? String) == id,
              lowerUUID(row["workspace_id"] as? String) == workspace,
              row["record_state"] as? String != "archived", row["deleted_at"] == nil || row["deleted_at"] is NSNull else { throw FileNappletError.unavailable }
        var result = row
        if requireTopLevelWrite {
            result.removeValue(forKey: "can_write")
            // Current servers may expose the explicit grant on File; a present top-level flag always wins.
            if let raw = o["can_write"] ?? row["can_write"] {
                guard let flag = TrackerDocument.boolean(raw) else { throw FileNappletError.invalid }
                result["can_write"] = flag
            }
            return result
        }
        if let raw = o["can_write"] {
            guard let canWrite = TrackerDocument.boolean(raw) else { throw FileNappletError.invalid }
            result["can_write"] = canWrite
        }
        return result
    }
    func nappletBytes(workspace: String, app: String, file: [String: Any], mime: String, limit: Int) async throws -> (Data, String) {
        guard let id = lowerUUID(file["id"] as? String) else { throw FileNappletError.invalid }
        let history = try object(try await client.request(path: try Self.base(workspace) + "/files/" + Self.uuid(id) + "/versions", query: [URLQueryItem(name: "limit", value: "1")], appNpub: app), "napplet versions")
        guard lowerUUID(history["file_id"] as? String) == id,
              let version = lowerUUID(history["current_version_id"] as? String),
              let rows = history["versions"] as? [[String: Any]], let head = rows.first, lowerUUID(head["id"] as? String) == version,
              head["content_type"] as? String == mime,
              let size = flexibleInt(head["size_bytes"]), size >= 0, size <= limit,
              let sha = head["sha256_hex"] as? String, sha.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw FileNappletError.invalid }
        let path = try Self.base(workspace) + "/files/" + Self.uuid(id) + "/versions/" + Self.uuid(version) + "/object"
        let request = try await client.signed(method: "GET", path: path, query: [], appNpub: app, jsonBody: nil)
        try Task.checkCancellation()
        let (bytes, response) = try await client.transport.send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw FileNappletError.unavailable }
        guard response.mimeType?.lowercased() == mime, bytes.count == size, SHA256Hex.of(bytes) == sha else { throw FileNappletError.invalid }
        return (bytes, version)
    }
    public func fileNappletCode(workspace: String, app: String, fileId: String) async throws -> FileNappletCode {
        let row = try await nappletFile(workspace: workspace, app: app, id: fileId)
        let metadata = row["metadata"] as? [String: Any] ?? [:]
        // Ordinary HTML keeps its original projection/asset path and never receives a bridge.
        guard metadata["napplet"] != nil else {
            let html = try await artefactHTML(workspaceId: workspace, appNpub: app, fileId: fileId)
            // A claimed v2 manifest cannot fall back to bridge-free ordinary HTML, even with missing metadata.
            guard try GenericNappletBinding.parse(html: html, metadata: rawJSON(metadata)) == nil else { throw FileNappletError.invalid }
            return FileNappletCode(html: html, binding: nil, versionId: "")
        }
        guard TrackerDocument.boolean(metadata["html_artifact"]) == true, metadata["artefact"] != nil,
              let file = try? FileRecord(raw: rawJSON(row)), ArtefactType.file(file) == .html else { throw FileNappletError.invalid }
        let (bytes, version) = try await nappletBytes(workspace: workspace, app: app, file: row, mime: "text/html", limit: 4 * 1024 * 1024)
        guard let html = String(data: bytes, encoding: .utf8) else { throw FileNappletError.invalid }
        return FileNappletCode(html: html, binding: try FileNappletBinding.parse(html: html, metadata: rawJSON(metadata)), versionId: version, sha256: SHA256Hex.of(bytes), channelIds: [file.channelId].compactMap { $0 })
    }
    func authorizeNappletData(workspace: String, app: String, viewer: String, codeFile: String, expected: FileNappletCode) async throws -> [String: Any] {
        guard let binding = expected.binding, try await fileNappletCode(workspace: workspace, app: app, fileId: codeFile) == expected else { throw FileNappletError.unavailable }
        let row = try await nappletFile(workspace: workspace, app: app, id: binding.dataFileId)
        guard let channel = lowerUUID(row["channel_id"] as? String) else { throw FileNappletError.unavailable }
        let result = try object(try await client.request(path: try Self.base(workspace) + "/channels/" + Self.uuid(channel), appNpub: app), "private channel")
        guard let c = result["channel"] as? [String: Any], lowerUUID(c["id"] as? String) == channel,
              lowerUUID(c["workspace_id"] as? String) == workspace, c["kind"] as? String == "dm",
              c["participant_npubs"] as? [String] == [viewer],
              c["archived_at"] == nil || c["archived_at"] is NSNull else { throw FileNappletError.unavailable }
        try Task.checkCancellation()
        return row
    }
    public func readFileNapplet(workspace: String, app: String, viewer: String, codeFile: String, expected: FileNappletCode) async throws -> FileNappletData {
        let row = try await authorizeNappletData(workspace: workspace, app: app, viewer: viewer, codeFile: codeFile, expected: expected)
        let (bytes, version) = try await nappletBytes(workspace: workspace, app: app, file: row, mime: "application/json", limit: TrackerDocument.maxBytes)
        try TrackerDocument.validate(bytes)
        return FileNappletData(bytes: bytes, versionId: version, canWrite: row["can_write"] as? Bool == true, channelId: row["channel_id"] as? String)
    }
    public func saveFileNapplet(workspace: String, app: String, viewer: String, codeFile: String, expected: FileNappletCode, base: String, bytes: Data) async throws -> FileNappletData {
        let current = try await readFileNapplet(workspace: workspace, app: app, viewer: viewer, codeFile: codeFile, expected: expected)
        guard current.canWrite else { throw FileNappletError.unavailable }
        guard current.versionId == base else { throw FileNappletError.conflict }
        try TrackerDocument.validate(bytes, previous: current.bytes)
        try Task.checkCancellation()
        let object = try await store(workspaceId: workspace, appNpub: app, bytes: bytes, contentType: "application/json", fileName: "daily-tracker.json", prepared: nil, onPrepared: { _ in })
        // Reauthorize after upload, before publishing; CAS still uses the frame's unchanged original base.
        _ = try await authorizeNappletData(workspace: workspace, app: app, viewer: viewer, codeFile: codeFile, expected: expected)
        try Task.checkCancellation()
        let body = try rawJSON(["base_version_id": Self.uuid(base), "storage_object_id": object, "client_mutation_id": UUID().uuidString.lowercased()])
        let committed: String
        do {
            let response = try self.object(try await client.request(method: "POST", path: try Self.base(workspace) + "/files/" + Self.uuid(expected.binding!.dataFileId) + "/versions", appNpub: app, jsonBody: body), "napplet save")
            guard let row = response["version"] as? [String: Any], let id = lowerUUID(row["id"] as? String) else { throw FileNappletError.unavailable }
            committed = id
        } catch {
            if case TowerError.http(let status, _, _) = error, status == 409 { throw FileNappletError.conflict }
            // An uncertain response is checked, never resubmitted against a different base.
            let reread = try await readFileNapplet(workspace: workspace, app: app, viewer: viewer, codeFile: codeFile, expected: expected)
            guard reread.versionId != base, reread.bytes == bytes else { throw error }; return reread
        }
        let saved = try await readFileNapplet(workspace: workspace, app: app, viewer: viewer, codeFile: codeFile, expected: expected)
        guard saved.versionId == committed, saved.versionId != base, saved.bytes == bytes else { throw FileNappletError.conflict }
        return saved
    }
}

/// Only the immutable original shipped template is eligible. Customized or unknown code is never replaced.
public enum DailyTrackerUpdate {
    public static let originalSHA256 = "192779e50335a83d90076fb17954059e466ccfecea25c5eb5b14d68e8dfa91cd"
    public static func recognizes(_ code: FileNappletCode) -> Bool {
        code.binding != nil && code.sha256 == originalSHA256 && Data(code.html.utf8).count == 14824
    }
}

extension TowerAPI {
    private func authorizeTrackerUpdate(workspace: String, app: String, viewer: String, codeFile: String, expected: FileNappletCode) async throws {
        guard DailyTrackerUpdate.recognizes(expected) else { throw FileNappletError.invalid }
        _ = try await readFileNapplet(workspace: workspace, app: app, viewer: viewer, codeFile: codeFile, expected: expected)
        let row = try await nappletFile(workspace: workspace, app: app, id: codeFile)
        guard TrackerDocument.boolean(row["can_write"]) == true,
              try await fileNappletCode(workspace: workspace, app: app, fileId: codeFile) == expected else { throw FileNappletError.unavailable }
        try Task.checkCancellation()
    }
    public func canUpdateDailyTracker(workspace: String, app: String, viewer: String, codeFile: String, expected: FileNappletCode) async throws -> Bool {
        guard DailyTrackerUpdate.recognizes(expected) else { return false }
        try await authorizeTrackerUpdate(workspace: workspace, app: app, viewer: viewer, codeFile: codeFile, expected: expected)
        return true
    }
    /// Host action only: one new HTML version on the same File. No metadata or JSON mutation.
    public func updateDailyTracker(workspace: String, app: String, viewer: String, codeFile: String, expected: FileNappletCode, template: Data) async throws -> FileNappletCode {
        guard let binding = expected.binding, let html = String(data: template, encoding: .utf8),
              SHA256Hex.of(template) != expected.sha256 else { throw FileNappletError.invalid }
        let metadata: [String: Any] = ["napplet": ["version": 1, "app_id": "daily-tracker", "bindings": ["tracker": ["file_id": binding.dataFileId]]]]
        guard try FileNappletBinding.parse(html: html, metadata: rawJSON(metadata)) == binding else { throw FileNappletError.invalid }
        try await authorizeTrackerUpdate(workspace: workspace, app: app, viewer: viewer, codeFile: codeFile, expected: expected)
        let object = try await store(workspaceId: workspace, appNpub: app, bytes: template, contentType: "text/html", fileName: "Daily tracker.html", prepared: nil, onPrepared: { _ in })
        try await authorizeTrackerUpdate(workspace: workspace, app: app, viewer: viewer, codeFile: codeFile, expected: expected)
        let body = try rawJSON(["base_version_id": Self.uuid(expected.versionId), "storage_object_id": object, "client_mutation_id": UUID().uuidString.lowercased()])
        let committed: String?
        do {
            let response = try self.object(try await client.request(method: "POST", path: try Self.base(workspace) + "/files/" + Self.uuid(codeFile) + "/versions", appNpub: app, jsonBody: body), "tracker update")
            guard let row = response["version"] as? [String: Any], let id = lowerUUID(row["id"] as? String) else { throw FileNappletError.unavailable }
            committed = id
        } catch {
            if case TowerError.http(let status, _, _) = error, status == 409 { throw FileNappletError.conflict }
            try Task.checkCancellation()
            // A lost acknowledgement permits only exact readback, never a retry or a new base.
            committed = nil
        }
        let saved = try await fileNappletCode(workspace: workspace, app: app, fileId: codeFile)
        guard saved.versionId != expected.versionId, committed == nil || saved.versionId == committed,
              saved.binding == binding, saved.sha256 == SHA256Hex.of(template), saved.html == html else { throw FileNappletError.conflict }
        _ = try await readFileNapplet(workspace: workspace, app: app, viewer: viewer, codeFile: codeFile, expected: saved)
        return saved
    }
}

extension WorkspaceSync {
    public func fileNappletCode(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String) async throws -> FileNappletCode {
        try await identity.requireReader(npub: c.signerNpub)
        return try await api(origin: TowerOrigin(c.origin)).fileNappletCode(workspace: w.id, app: w.appNpub, fileId: fileId)
    }
    public func readFileNapplet(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: FileNappletCode) async throws -> FileNappletData {
        try await identity.requireReader(npub: c.signerNpub)
        let epoch = try await store.reader.state("local-content.epoch") ?? ""
        do {
            let data = try await api(origin: TowerOrigin(c.origin)).readFileNapplet(workspace: w.id, app: w.appNpub, viewer: c.signerNpub, codeFile: fileId, expected: code)
            guard try await store.reader.state("local-content.epoch") ?? "" == epoch else { throw CancellationError() }
            await rememberFileNapplet(c, w, fileId: fileId, code: code, data: data, epoch: epoch)
            return data
        } catch { if CachedContentFailure.invalidates(error) { await forgetCachedFileNapplet(c, w, fileId: fileId) }; throw error }
    }
    public func canUpdateDailyTracker(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: FileNappletCode) async throws -> Bool {
        try await identity.requireReader(npub: c.signerNpub)
        return try await api(origin: TowerOrigin(c.origin)).canUpdateDailyTracker(workspace: w.id, app: w.appNpub, viewer: c.signerNpub, codeFile: fileId, expected: code)
    }
    public func updateDailyTracker(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: FileNappletCode, template: Data) async throws -> FileNappletCode {
        try await identity.requireSigner(npub: c.signerNpub)
        return try await api(origin: TowerOrigin(c.origin)).updateDailyTracker(workspace: w.id, app: w.appNpub, viewer: c.signerNpub, codeFile: fileId, expected: code, template: template)
    }
    public func saveFileNapplet(_ c: ConnectionRecord, _ w: WorkspaceRecord, fileId: String, code: FileNappletCode, base: String, bytes: Data) async throws -> FileNappletData {
        try await identity.requireSigner(npub: c.signerNpub)
        let epoch = try await store.reader.state("local-content.epoch") ?? ""
        do {
            let data = try await api(origin: TowerOrigin(c.origin)).saveFileNapplet(workspace: w.id, app: w.appNpub, viewer: c.signerNpub, codeFile: fileId, expected: code, base: base, bytes: bytes)
            await rememberFileNapplet(c, w, fileId: fileId, code: code, data: data, epoch: epoch)
            return data
        } catch { if CachedContentFailure.invalidates(error) { await forgetCachedFileNapplet(c, w, fileId: fileId) }; throw error }
    }
}

extension WorkspaceSync {
    /// Explicit user action only. Creates empty private Files; the bundled template is never the runtime data store.
    public func createDailyTracker(_ c: ConnectionRecord, _ w: WorkspaceRecord, template: Data) async throws -> FileRecord {
        try await identity.requireSigner(npub: c.signerNpub)
        let api = try api(origin: TowerOrigin(c.origin))
        let scopeRows = try await api.client.list(path: try TowerAPI.base(w.id) + "/scopes", appNpub: w.appNpub, key: "scopes")
        let scopes = try scopeRows.map(ScopeRecord.init(raw:))
        guard let dm = scopes.first(where: { $0.workspaceId == w.id && $0.kind == "dm" }) else { throw FileNappletError.unavailable }
        let channels = try await api.channels(workspaceId: w.id, scopeId: dm.id, appNpub: w.appNpub)
        var channel = DirectMessagePlanner.existing(in: channels, participants: [c.signerNpub])
        if channel == nil {
            let response = try api.object(try await api.client.request(method: "POST", path: try TowerAPI.base(w.id) + "/scopes/" + TowerAPI.uuid(dm.id) + "/channels", appNpub: w.appNpub,
                jsonBody: rawJSON(["kind": "dm", "participant_npubs": [c.signerNpub], "name": "Personal", "description": "dm:" + c.signerNpub])), "self DM")
            guard let row = response["channel"] as? [String: Any] else { throw FileNappletError.unavailable }
            let created = try ChannelRecord(raw: rawJSON(row))
            channel = DirectMessagePlanner.existing(in: [created], participants: [c.signerNpub])
        }
        guard let channel, channel.workspaceId == w.id else { throw FileNappletError.unavailable }
        try Task.checkCancellation()
        // Validate the reviewed template before creating either File. Binding UUID here is validation-only.
        let placeholder = UUID().uuidString.lowercased()
        let napplet: [String: Any] = ["version": 1, "app_id": "daily-tracker", "bindings": ["tracker": ["file_id": placeholder]]]
        guard let html = String(data: template, encoding: .utf8),
              try FileNappletBinding.parse(html: html, metadata: rawJSON(["napplet": napplet])) != nil else { throw FileNappletError.invalid }
        let empty = Data("{\"format\":\"daily-tracker-v1\",\"metrics\":[],\"days\":{}}".utf8)
        let data = try await api.createNappletFile(workspace: w.id, app: w.appNpub, channel: channel.id, name: "Daily tracker data.json", mime: "application/json", bytes: empty, metadata: [:])
        let metadata: [String: Any] = ["html_artifact": true,
            "artefact": ["schema_version": 1, "type": "html", "format_version": 1, "editor_id": "builtin.html"],
            "napplet": ["version": 1, "app_id": "daily-tracker", "bindings": ["tracker": ["file_id": data.id]]]]
        let code = try await api.createNappletFile(workspace: w.id, app: w.appNpub, channel: channel.id, name: "Daily tracker.html", mime: "text/html", bytes: template, metadata: metadata)
        _ = try await store.writer.upsertFiles(workspaceId: w.id, [code]) // No tracker values or data File bytes are cached.
        _ = try await store.writer.upsertChannels(workspaceId: w.id, scopeId: dm.id, [channel], complete: false)
        return code
    }
}

extension TowerAPI {
    func createNappletFile(workspace: String, app: String, channel: String, name: String, mime: String, bytes: Data, metadata: [String: Any]) async throws -> FileRecord {
        let object = try await store(workspaceId: workspace, appNpub: app, bytes: bytes, contentType: mime, fileName: name, prepared: nil, onPrepared: { _ in })
        try Task.checkCancellation()
        let response = try self.object(try await client.request(method: "POST", path: try Self.base(workspace) + "/channels/" + Self.uuid(channel) + "/files", appNpub: app,
            jsonBody: rawJSON(["storage_object_id": object, "display_name": name, "metadata": metadata])), "tracker file")
        guard let row = response["file"] as? [String: Any] else { throw FileNappletError.unavailable }
        let file = try FileRecord(raw: rawJSON(row))
        guard file.workspaceId == workspace, file.channelId == channel else { throw FileNappletError.unavailable }
        return file
    }
}


extension TowerAPI {
    /// Complete remote discovery only. Names and local caches are never instance identity.
    public func dailyTrackers(workspace: String, app: String, viewer: String) async throws -> [FileRecord] {
        let scopes = try await scopes(workspaceId: workspace, appNpub: app)
        guard scopes.allSatisfy({ $0.workspaceId == workspace }), scopes.contains(where: { $0.kind == "dm" }) else { throw FileNappletError.unavailable }
        var found: [FileRecord] = []
        for scope in scopes where scope.kind == "dm" {
            let channels = try await channels(workspaceId: workspace, scopeId: scope.id, appNpub: app)
            guard channels.allSatisfy({ $0.workspaceId == workspace && $0.scopeId == scope.id }) else { throw FileNappletError.unavailable }
            for channel in channels where DirectMessagePlanner.existing(in: [channel], participants: [viewer]) != nil {
                let rows = try await client.list(path: try Self.base(workspace) + "/channels/" + Self.uuid(channel.id) + "/files", appNpub: app, key: "files")
                for raw in rows {
                    let row = try object(raw, "tracker discovery")
                    let file = try FileRecord(raw: raw)
                    guard file.workspaceId == workspace, file.channelId == channel.id else { throw FileNappletError.unavailable }
                    if row["record_state"] as? String == "archived" || (row["deleted_at"] != nil && !(row["deleted_at"] is NSNull)) { continue }
                    let metadata = row["metadata"] as? [String: Any] ?? [:]
                    guard (metadata["napplet"] as? [String: Any])?["app_id"] as? String == "daily-tracker" else { continue }
                    let code = try await fileNappletCode(workspace: workspace, app: app, fileId: file.id)
                    guard code.binding != nil else { throw FileNappletError.invalid }
                    _ = try await readFileNapplet(workspace: workspace, app: app, viewer: viewer, codeFile: file.id, expected: code)
                    found.append(file)
                }
            }
        }
        guard Set(found.map(\.id)).count == found.count else { throw FileNappletError.invalid }
        return found.sorted { $0.id < $1.id }
    }
}

extension WorkspaceSync {
    public func dailyTrackers(_ c: ConnectionRecord, _ w: WorkspaceRecord) async throws -> [FileRecord] {
        try await identity.requireReader(npub: c.signerNpub)
        return try await api(origin: TowerOrigin(c.origin)).dailyTrackers(workspace: w.id, app: w.appNpub, viewer: c.signerNpub)
    }
}
