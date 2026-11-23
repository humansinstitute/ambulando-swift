import Foundation
import CoreFoundation

/// Built-in renderers for channel artefacts. Documents retain their existing Doc identity;
/// rich content uses the original File identity and immutable File versions.
public enum ArtefactType: String, Sendable, CaseIterable, Identifiable {
    case document, whiteboard, html
    public var id: String { rawValue }
    public var label: String {
        switch self { case .document: "Documents"; case .whiteboard: "Whiteboards"; case .html: "HTML" }
    }
    public var icon: String {
        switch self { case .document: "doc.text"; case .whiteboard: "scribble.variable"; case .html: "chevron.left.forwardslash.chevron.right" }
    }
    public static let registryVersion = 1
    public static func file(_ file: FileRecord) -> Self? {
        if let row = try? JSONSerialization.jsonObject(with: file.raw) as? [String: Any] {
            let metadata = row["metadata"] as? [String: Any]
            if let value = metadata?["artefact"] {
                guard let descriptor = value as? [String: Any],
                      let schema = descriptor["schema_version"] as? NSNumber, schema == 1,
                      CFGetTypeID(schema) != CFBooleanGetTypeID(),
                      let format = descriptor["format_version"] as? NSNumber, format == 1,
                      CFGetTypeID(format) != CFBooleanGetTypeID(),
                      let kind = descriptor["type"] as? String,
                      descriptor["editor_id"] as? String == "builtin.\(kind)" else { return nil }
                switch kind {
                case "excalidraw": return .whiteboard
                case "html": return .html
                default: return nil
                }
            }
            let kind = row["artefact_type"] as? String
            if kind == "excalidraw" { return .whiteboard }
            if kind == "html" { return .html }
        }
        let mime = (file.contentType ?? "").lowercased().split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = file.displayName.lowercased()
        if mime == BoardScene.contentType || name.hasSuffix(".excalidraw") { return .whiteboard }
        if ["text/html", "application/xhtml+xml"].contains(mime) || name.hasSuffix(".html") || name.hasSuffix(".htm") || name.hasSuffix(".xhtml") { return .html }
        return nil
    }
}

extension TowerAPI {
    public func artefactBoard(workspaceId: String, appNpub: String, fileId: String) async throws -> BoardReference {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/files/" + Self.uuid(fileId), appNpub: appNpub), "artefact")
        guard let row = o["file"] as? [String: Any], let f = try? FileRecord(raw: rawJSON(row)),
              f.id == fileId, f.workspaceId == workspaceId, ArtefactType.file(f) == .whiteboard else { throw TowerError.malformed("whiteboard") }
        let history = try await boardVersions(workspaceId: workspaceId, appNpub: appNpub, fileId: fileId)
        guard let v = history.versions.first(where: { $0.id == history.currentVersionId }) else { throw TowerError.malformed("whiteboard version") }
        return BoardReference(fileId: fileId, versionId: v.id, versionNumber: v.number, sha256: v.sha256,
                              sizeBytes: f.sizeBytes ?? 0, updatedAt: f.updatedAt, canWrite: row["can_write"] as? Bool == true)
    }
    public func artefactHTML(workspaceId: String, appNpub: String, fileId: String) async throws -> String {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/html", appNpub: appNpub), "HTML artefact")
        guard o["workspace_id"] as? String == workspaceId,
              let source = o["source"] as? [String: Any], source["id"] as? String == fileId,
              source["type"] as? String == "html",
              let content = o["content"] as? [String: Any], let html = content["html"] as? String else { throw TowerError.malformed("HTML artefact") }
        return try await hydratedArtefactHTML(html, content: content, workspaceId: workspaceId, appNpub: appNpub)
    }
}

extension WorkspaceSync {
    public func artefactBoard(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, fileId: String) async throws -> BoardReference {
        try await identity.requireReader(npub: connection.signerNpub)
        return try await api(origin: try TowerOrigin(connection.origin)).artefactBoard(workspaceId: workspace.id, appNpub: workspace.appNpub, fileId: fileId)
    }
    public func artefactHTML(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, fileId: String) async throws -> String {
        try await identity.requireReader(npub: connection.signerNpub)
        return try await api(origin: try TowerOrigin(connection.origin)).artefactHTML(workspaceId: workspace.id, appNpub: workspace.appNpub, fileId: fileId)
    }
}

extension WorkspaceSync {
    public func htmlHistory(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, fileId: String) async throws -> (currentVersionId: String?, versions: [BoardVersion]) {
        try await identity.requireReader(npub: connection.signerNpub)
        return try await api(origin: try TowerOrigin(connection.origin)).boardVersions(workspaceId: workspace.id, appNpub: workspace.appNpub, fileId: fileId)
    }
    public func htmlSource(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, fileId: String, version: BoardVersion) async throws -> String {
        try await identity.requireReader(npub: connection.signerNpub)
        let bytes = try await api(origin: try TowerOrigin(connection.origin)).boardVersionBytes(workspaceId: workspace.id, appNpub: workspace.appNpub, fileId: fileId, versionId: version.id, sha256: version.sha256)
        guard let text = String(data: bytes, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
            throw BoardEditError.failed("This HTML package can be viewed here. Edit its manifest and assets through the authoring tools.")
        }
        return text
    }
    public func saveHTML(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, fileId: String, base: String, source: String, title: String) async throws {
        try await identity.requireSigner(npub: connection.signerNpub)
        let api = try api(origin: TowerOrigin(connection.origin))
        let objectId = try await api.store(workspaceId: workspace.id, appNpub: workspace.appNpub, bytes: Data(source.utf8), contentType: "text/html", fileName: title, prepared: nil, onPrepared: { _ in })
        let body: [String: Any] = ["base_version_id": base, "storage_object_id": objectId, "client_mutation_id": UUID().uuidString.lowercased()]
        _ = try await api.client.request(method: "POST", path: try TowerAPI.base(workspace.id) + "/files/" + TowerAPI.uuid(fileId) + "/versions", appNpub: workspace.appNpub, jsonBody: rawJSON(body))
    }
}

extension WorkspaceSync {
    /// Hydrates a direct chat/pin File reference through the normal bounded sync queue.
    public func refreshArtefactFile(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, fileId: String) async {
        let sync = self
        await engine.enqueue("artefact-file:\(workspace.id):\(fileId)", priority: .user) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let api = try sync.api(origin: TowerOrigin(connection.origin))
            let o = try api.object(try await api.client.request(path: try TowerAPI.base(workspace.id) + "/files/" + TowerAPI.uuid(fileId), appNpub: workspace.appNpub), "file")
            guard let row = o["file"] as? [String: Any] else { throw TowerError.malformed("file") }
            let file = try FileRecord(raw: rawJSON(row))
            guard file.workspaceId == workspace.id, file.id == fileId else { throw TowerError.malformed("file") }
            try Task.checkCancellation()
            _ = try await sync.store.writer.upsertFiles(workspaceId: workspace.id, [file])
        }
    }
}

extension TowerAPI {
    /// Deliver only bounded, digest-checked image assets authorized by this projection.
    /// The sandbox receives inert data URLs, never credentials or a host message bridge.
    func hydratedArtefactHTML(_ html: String, content: [String: Any], workspaceId: String, appNpub: String) async throws -> String {
        let assets = (content["assets"] as? [[String: Any]]) ?? []
        var urls: [String: String] = [:], total = 0
        let types: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/svg+xml"]
        for asset in assets.prefix(64) {
            guard asset["status"] as? String == "ready", let name = asset["name"] as? String,
                  name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil,
                  let file = lowerUUID(asset["file_id"] as? String), let version = lowerUUID(asset["version_id"] as? String),
                  let sha = asset["sha256"] as? String, sha.count == 64,
                  let mime = asset["content_type"] as? String, types.contains(mime),
                  let size = flexibleInt(asset["size_bytes"]), size >= 0, size <= 8 * 1024 * 1024, total + size <= 32 * 1024 * 1024 else { continue }
            try Task.checkCancellation()
            guard let bytes = try? await boardVersionBytes(workspaceId: workspaceId, appNpub: appNpub, fileId: file, versionId: version, sha256: sha), bytes.count == size else { continue }
            total += size
            urls[name] = "data:\(mime);base64,\(bytes.base64EncodedString())"
        }
        guard !assets.isEmpty else { return html }
        let json = String(data: try rawJSON(urls), encoding: .utf8) ?? "{}"
        let bootstrap = "<script>(()=>{const urls=\(json);Object.defineProperty(window,'wingmanAssets',{value:Object.freeze({url:n=>Object.hasOwn(urls,String(n))?urls[String(n)]:null,names:()=>Object.keys(urls)})});const apply=()=>{document.querySelectorAll('[data-asset],[data-asset-background]').forEach(el=>{const n=el.getAttribute('data-asset'),b=el.getAttribute('data-asset-background');if(n){const u=urls[n];if(u){if(el.namespaceURI==='http://www.w3.org/2000/svg')el.setAttribute('href',u);else el.setAttribute('src',u)}el.setAttribute('data-asset-state',u?'ready':'missing')}if(b){const u=urls[b];if(u)el.style.backgroundImage='url(\"'+u+'\")';el.setAttribute('data-asset-state',u?'ready':'missing')}})};apply();new MutationObserver(apply).observe(document.documentElement,{childList:true,subtree:true});addEventListener('DOMContentLoaded',()=>document.dispatchEvent(new CustomEvent('wingman:assets-ready',{detail:{names:Object.keys(urls)}})),{once:true})})();</script>"
        return ArtefactHTMLDocument.insertingHeadContent(bootstrap, into: html)
    }
}

/// Inserts trusted host markup without moving a document's doctype into its body.
/// Fragments receive a standards-mode document; existing documents retain their original markup.
public enum ArtefactHTMLDocument {
    public static func insertingHeadContent(_ content: String, into html: String) -> String {
        let pattern = #"\A(\x{FEFF}?\s*(?:<!--[\s\S]*?-->\s*)*(?:<!doctype\s[^>]*>\s*)?)(<html\b[^>]*>\s*)?(<head\b[^>]*>)?"#
        let expression = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..., in: html)
        guard let match = expression.firstMatch(in: html, range: range),
              let prefix = Range(match.range, in: html) else { return html }
        let before = String(html[..<prefix.upperBound]), rest = String(html[prefix.upperBound...])
        let doctype = before.range(of: "<!doctype", options: .caseInsensitive) == nil ? "<!doctype html>" : ""
        if match.range(at: 3).location != NSNotFound { return doctype + before + content + rest }
        if match.range(at: 2).location != NSNotFound { return doctype + before + "<head>" + content + "</head>" + rest }
        return doctype + before + "<html><head>" + content + "</head><body>" + rest + "</body></html>"
    }
}
