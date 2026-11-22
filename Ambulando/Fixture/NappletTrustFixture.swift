import AmbulandoCore
import Foundation

/// Opt-in synthetic boundary for the production File host. Never reads or writes a human backend.
final class NappletTrustFixture: @unchecked Sendable {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureNappletTrust") }
    static let codeId = "f1c70000-0000-4000-8000-00000000aa10"
    static let dataId = "f1c70000-0000-4000-8000-00000000aa11"
    static let channelId = "f1c70000-0000-4000-8000-00000000aa12"
    static let version = "f1c70000-0000-4000-8000-00000000aa13"
    private let lock = NSLock()
    private var bytes = Data("{\"format\":\"daily-tracker-v1\",\"metrics\":[],\"days\":{}}".utf8)
    private var scenario = ""
    private var updatedHTML: Data?
    private var uploaded: Data?
    private var completed = false
    private var codeRevision = NappletTrustFixture.version
    private let objectId = "f1c70000-0000-4000-8000-00000000aa15"
    private var updateMode: Bool { ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureTrackerUpdate") }
    var snapshot: (Data, String, String) { lock.withLock { (bytes, dataId, codeRevision) } }
    init() {
        if updateMode {
            bytes = Data("{\"format\":\"daily-tracker-v1\",\"metrics\":[{\"id\":\"f1c70000-0000-4000-8000-00000000aa20\",\"label\":\"Synthetic archived answer\",\"type\":\"boolean\",\"unit\":\"\",\"archived\":true},{\"id\":\"f1c70000-0000-4000-8000-00000000aa21\",\"label\":\"Synthetic number\",\"type\":\"number\",\"unit\":\"kg\",\"archived\":false}],\"days\":{\"2024-02-29\":{\"f1c70000-0000-4000-8000-00000000aa20\":false,\"f1c70000-0000-4000-8000-00000000aa21\":0}}}".utf8)
        }
    }
    func change(_ scenario: String) {
        lock.withLock {
            self.scenario = scenario
            if scenario == "data" { bytes = Data("{\"format\":\"daily-tracker-v1\",\"metrics\":[],\"days\":{\"2024-02-29\":{}}}".utf8) }
        }
    }
    var dataId: String { scenario == "binding" || ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureTrustBindingChanged") ? "f1c70000-0000-4000-8000-00000000aa99" : Self.dataId }
    var writable: Bool { scenario != "access" && !ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureTrustReadOnly") }
    var html: Data {
        if let updatedHTML { return updatedHTML }
        let name = updateMode ? "daily-tracker-original-v1" : "daily-tracker-v1"
        let template = (try? Data(contentsOf: Bundle.main.url(forResource: name, withExtension: "html")!)) ?? Data()
        return template + ((scenario == "code" || ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureTrustCodeChanged")) ? Data("<!-- changed synthetic code -->".utf8) : Data())
    }
    var metadata: [String: Any] {
        ["html_artifact": true, "artefact": ["schema_version": 1, "type": "html", "format_version": 1, "editor_id": "builtin.html"],
         "napplet": ["version": 1, "app_id": "daily-tracker", "bindings": ["tracker": ["file_id": dataId]]]]
    }
    func handle(_ request: URLRequest, actor: String) throws -> (Int, Any)? {
        let path = request.url!.path
        let base = "/api/v4/flightdeck-pg/workspaces/" + FixtureTower.studio
        guard path.hasPrefix(base) || (updateMode && path.hasPrefix("/api/v4/storage")) else { return nil }
        return try lock.withLock {
            let method = request.httpMethod ?? "GET"
            if updateMode, path.hasSuffix("/storage/prepare") { uploaded = nil; completed = false; return (200, ["object_id": objectId, "upload_url": "https://fixture.ambulando.invalid/api/v4/storage/" + objectId]) }
            if updateMode, path.hasSuffix("/storage/" + objectId), method == "PUT" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                uploaded = Data(base64Encoded: body["base64_data"] as! String); return (200, [:])
            }
            if updateMode, path.hasSuffix("/storage/" + objectId + "/complete") { completed = true; return (200, ["completed_at": "now"]) }
            if updateMode, path.hasSuffix("/storage/" + objectId) {
                var row: [String: Any] = ["id": objectId, "is_public": false, "size_bytes": uploaded?.count ?? 0, "sha256_hex": SHA256Hex.of(uploaded ?? Data())]
                if completed { row["completed_at"] = "now" }; return (200, row)
            }
            if path == base + "/scopes/" + FixtureTower.scopeDMs + "/channels" {
                return (200, ["channels": [["id": Self.channelId, "workspace_id": FixtureTower.studio, "scope_id": FixtureTower.scopeDMs, "kind": "dm", "name": "Synthetic self", "participant_npubs": [actor]]]])
            }
            if path == base + "/channels/" + Self.channelId {
                return (200, ["channel": ["id": Self.channelId, "workspace_id": FixtureTower.studio, "scope_id": FixtureTower.scopeDMs, "kind": "dm", "participant_npubs": [actor]]])
            }
            if path == base + "/channels/" + Self.channelId + "/files" {
                return (200, ["files": [["id": Self.codeId, "workspace_id": FixtureTower.studio, "channel_id": Self.channelId, "display_name": "Synthetic tracker.html", "metadata": metadata]]])
            }
            guard path.contains("/files/" + Self.codeId) || path.contains("/files/" + dataId) else { return nil }
            if scenario == "denied" || ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureTrustDenied") { return (403, ["code": "denied"]) }
            let code = path.contains(Self.codeId), id = code ? Self.codeId : dataId
            let value = code ? html : bytes
            let head = code ? codeRevision : scenario == "data" ? "f1c70000-0000-4000-8000-00000000aa14" : Self.version
            if path.hasSuffix("/files/" + id) {
                return (200, ["file": ["id": id, "workspace_id": FixtureTower.studio, "channel_id": Self.channelId, "can_write": writable, "metadata": code ? metadata : [:]]])
            }
            if path.hasSuffix("/versions"), method == "POST", code, updateMode {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                guard body["base_version_id"] as? String == codeRevision, let uploaded else { return (409, ["code": "stale_base_version"]) }
                updatedHTML = uploaded; codeRevision = "f1c70000-0000-4000-8000-00000000aa16"
                return (200, ["version": ["id": codeRevision]])
            }
            if path.hasSuffix("/versions") {
                return (200, ["file_id": id, "current_version_id": head, "versions": [["id": head, "content_type": code ? "text/html" : "application/json", "size_bytes": value.count, "sha256_hex": SHA256Hex.of(value)]]])
            }
            if path.hasSuffix("/object") { return (200, value) }
            return nil
        }
    }
}
