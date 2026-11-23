import Foundation
import CoreFoundation

/// v2 is independent of the legacy tracker model and receipt namespace.
public enum GenericJSON {
    public static let maxBytes = 1_048_576
    public static func matches(_ s:String,_ pattern:String) -> Bool { s.range(of:pattern + "\\z",options:.regularExpression) != nil }
    public static func uuid(_ s:String) -> Bool { matches(s,"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}") }
    static func exact(_ o:[String:Any],_ keys:Set<String>) -> Bool { Set(o.keys) == keys }
    /// Object members use scalar-exact UTF-8 identities, avoiding Swift String's canonical-equivalence key merging.
    indirect enum Node {
        case object([(String,Node)]), array([Node]), string(String), number(Double), bool(Bool), null
        func member(_ key:String) -> Node? {
            guard case .object(let pairs) = self else { return nil }
            return pairs.first(where:{ Array($0.0.utf8) == Array(key.utf8) })?.1
        }
        var isObject: Bool { if case .object = self { return true }; return false }
        var encoded: String {
            switch self {
            case .object(let pairs): return "{" + pairs.sorted { $0.0.unicodeScalars.lexicographicallyPrecedes($1.0.unicodeScalars) }.map { quote($0.0) + ":" + $0.1.encoded }.joined(separator:",") + "}"
            case .array(let values): return "[" + values.map(\.encoded).joined(separator:",") + "]"
            case .string(let s): return quote(s)
            case .number(let n): return GenericJSON.number(n)
            case .bool(let b): return b ? "true" : "false"
            case .null: return "null"
            }
        }
    }
    static func tree(_ data:Data,envelope:Bool = false, byteLimit:Int? = nil) throws -> Node {
        guard data.count <= (byteLimit ?? (maxBytes + (envelope ? 1024 : 0))), let s = String(data:data,encoding:.utf8), !s.hasPrefix("\u{feff}") else { throw FileNappletError.invalid }
        var scanner = Scanner(bytes:Array(s.utf8),depthLimit:envelope ? 33 : 32,nodeLimit:envelope ? 50010 : 50000)
        let node = try scanner.value(1); scanner.space()
        guard scanner.i == scanner.bytes.count else { throw FileNappletError.invalid }; return node
    }
    public static func canonicalData(_ data:Data) throws -> Data {
        let node = try tree(data); guard node.isObject else { throw FileNappletError.invalid }
        let result = Data(node.encoded.utf8); guard result.count <= maxBytes else { throw FileNappletError.invalid }; return result
    }
    public static func decode(_ data:Data) throws -> [String:Any] {
        _ = try canonicalData(data)
        guard let result = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw FileNappletError.invalid }; return result
    }
    public static func canonical(_ value:Any) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.withoutEscapingSlashes])
        let result = Data(try tree(data,byteLimit:8 * maxBytes).encoded.utf8)
        guard result.count <= maxBytes else { throw FileNappletError.invalid }; return result
    }
    struct Scanner {
        let bytes:[UInt8]; let depthLimit:Int; let nodeLimit:Int; var i = 0; var nodes = 0
        mutating func space() { while i < bytes.count && [9,10,13,32].contains(bytes[i]) { i += 1 } }
        mutating func take(_ b:UInt8) throws { guard i < bytes.count, bytes[i] == b else { throw FileNappletError.invalid }; i += 1 }
        mutating func string() throws -> String {
            let start = i; try take(34)
            while i < bytes.count {
                let c = bytes[i]; i += 1
                if c == 34 {
                    guard let s = try JSONSerialization.jsonObject(with:Data(bytes[start..<i]),options:.fragmentsAllowed) as? String, s.utf8.count <= 65536 else { throw FileNappletError.invalid }; return s
                }
                if c == 92 { guard i < bytes.count else { throw FileNappletError.invalid }; i += 1 }
            }; throw FileNappletError.invalid
        }
        mutating func value(_ depth:Int) throws -> Node {
            nodes += 1; guard depth <= depthLimit, nodes <= nodeLimit else { throw FileNappletError.invalid }; space()
            guard i < bytes.count else { throw FileNappletError.invalid }
            let c = bytes[i]
            if c == 123 || c == 91 {
                i += 1; space(); let end:UInt8 = c == 123 ? 125 : 93
                var pairs:[(String,Node)] = [], values:[Node] = [], keys = Set<Data>()
                if i < bytes.count, bytes[i] == end { i += 1; return c == 123 ? .object(pairs) : .array(values) }
                while i < bytes.count {
                    if c == 123 {
                        let key = try string()
                        guard keys.insert(Data(key.utf8)).inserted, !["__proto__","prototype","constructor"].contains(key) else { throw FileNappletError.invalid }
                        space(); try take(58); pairs.append((key,try value(depth + 1)))
                    } else { values.append(try value(depth + 1)) }
                    space(); guard i < bytes.count else { throw FileNappletError.invalid }
                    if bytes[i] == end { i += 1; return c == 123 ? .object(pairs) : .array(values) }; try take(44); space()
                }; throw FileNappletError.invalid
            }
            if c == 34 { return .string(try string()) }
            let start = i
            while i < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[i]) { i += 1 }
            let token = String(decoding:bytes[start..<i],as:UTF8.self)
            if token == "true" { return .bool(true) }; if token == "false" { return .bool(false) }; if token == "null" { return .null }
            guard GenericJSON.matches(token,"^-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"), let n = Double(token), n.isFinite, abs(n) <= 9007199254740991, !(n == 0 && n.sign == .minus) else { throw FileNappletError.invalid }; return .number(n)
        }
    }
    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c.value {
            case 34: out += "\\\""
            case 92: out += "\\\\"
            case 8: out += "\\b"
            case 9: out += "\\t"
            case 10: out += "\\n"
            case 12: out += "\\f"
            case 13: out += "\\r"
            case 0..<32: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(c)
            }
        }; return out + "\""
    }
    static func number(_ n: Double) -> String {
        if n == 0 { return "0" }
        let s = String(n).lowercased(), parts = s.split(separator: "e")
        if parts.count == 1 { return s.hasSuffix(".0") ? String(s.dropLast(2)) : s }
        let exponent = Int(parts[1])!, sign = n < 0 ? "-" : ""
        let mantissa = parts[0].replacingOccurrences(of: "-", with: "")
        var digits = mantissa.replacingOccurrences(of: ".", with: "")
        if digits.hasSuffix("0"), mantissa.hasSuffix(".0") { digits.removeLast() }
        if exponent >= -6 && exponent < 21 {
            let point = exponent + 1
            if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
            if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) }
            let at = digits.index(digits.startIndex, offsetBy: point); return sign + digits[..<at] + "." + digits[at...]
        }
        let m = mantissa.hasSuffix(".0") ? String(mantissa.dropLast(2)) : mantissa
        return sign + m + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
    }
}

public struct GenericNappletBinding: Sendable, Equatable {
    public let manifest: Data
    public let resources: Data
    public let name: String
    public let capability: String
    public let appId: String
    public let title: String
    public let icon: String
    public let resourceId: String
    public let capabilityVersion: Int
    public var includesWorkspaceStorage: Bool { capability == "workspace-aggregate" && capabilityVersion == 2 }
    public let allowsSave: Bool
    public static func parse(html: String, metadata: Data) throws -> Self? {
        let meta = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] ?? [:]
        let n = meta["napplet"] as? [String: Any]
        let re = try NSRegularExpression(pattern: #"<script\b((?:[^>"']|"[^"]*"|'[^']*')*)>([\s\S]*?)</script\s*>"#, options: .caseInsensitive)
        let attributes = try NSRegularExpression(pattern: #"(?:^|\s)([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)
        let text = html as NSString
        let matches = re.matches(in:html,range:NSRange(location:0,length:text.length)).filter { tag in
            let raw = text.substring(with:tag.range(at:1)) as NSString
            let attrs = attributes.matches(in:raw as String,range:NSRange(location:0,length:raw.length))
            return attrs.contains { attr in
                guard raw.substring(with:attr.range(at:1)).lowercased() == "id" else { return false }
                // Only a quoted, exact actual id attribute selects the manifest, matching the portable parser.
                return [2,3].contains { attr.range(at:$0).location != NSNotFound && raw.substring(with:attr.range(at:$0)).lowercased() == "wingman-napplet-manifest" }
            }
        }
        guard matches.count <= 1 else { throw FileNappletError.invalid }
        var m: [String: Any]?
        if matches.count == 1 { m = try GenericJSON.decode(Data(text.substring(with: matches[0].range(at: 2)).utf8)) }
        guard TrackerDocument.number(m?["version"]) == 2 || TrackerDocument.number(n?["version"]) == 2 else { return nil }
        guard let m, let n, GenericJSON.exact(m, ["version","app_id","title","icon","bindings"]), TrackerDocument.number(m["version"]) == 2,
              let app = m["app_id"] as? String, GenericJSON.matches(app, "^[a-z][a-z0-9-]{0,63}"),
              let title = m["title"] as? String, (1...80).contains(title.unicodeScalars.count),
              let icon = m["icon"] as? String, (1...8).contains(icon.unicodeScalars.count), !icon.contains(where: { "<>:/\\".contains($0) }),
              ![title, icon].contains(where: { $0.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) } }),
              let bindings = m["bindings"] as? [String: Any], bindings.count == 1, let name = bindings.keys.first, GenericJSON.matches(name, "^[a-z][a-z0-9_]{0,31}"),
              let b = bindings[name] as? [String: Any], GenericJSON.exact(b, ["capability","version","operations"]), let version = TrackerDocument.number(b["version"]),
              let cap = b["capability"] as? String, let ops = b["operations"] as? [String],
              (cap == "private-json-file" && version == 1 && (ops == ["read"] || ops == ["read","save"])) || (cap == "workspace-aggregate" && (version == 1 || version == 2) && ops == ["read"]),
              GenericJSON.exact(n, ["version","app_id","bindings"]), TrackerDocument.number(n["version"]) == 2, n["app_id"] as? String == app,
              let resources = n["bindings"] as? [String: Any], GenericJSON.exact(resources, [name]), let r = resources[name] as? [String: Any],
              GenericJSON.exact(r, [cap == "private-json-file" ? "file_id" : "workspace_id"]), let id = r.values.first as? String, GenericJSON.uuid(id) else { throw FileNappletError.invalid }
        return Self(manifest: try GenericJSON.canonical(m), resources: try GenericJSON.canonical(resources), name: name, capability: cap, appId: app, title: title, icon: icon, resourceId: id, capabilityVersion: version.intValue, allowsSave: ops.contains("save"))
    }
}
/// Launcher labels may reuse verified metadata only for an unchanged immutable File version.
/// This key never grants runtime authority; opening an app still verifies its current ACL and code.
public struct GenericAppDescriptorKey: Hashable, Sendable {
    public let fileId: String
    public let versionId: String
    public let sha256: String
    private let metadataDigest: String
    public init?(file: FileRecord) {
        guard let row = try? JSONSerialization.jsonObject(with: file.raw) as? [String: Any],
              let version = lowerUUID((row["current_version_id"] as? String) ?? (row["current_version"] as? [String: Any])?["id"] as? String),
              let sha = file.sha256, sha.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        fileId = file.id; versionId = version; sha256 = sha; metadataDigest = SHA256Hex.of(file.raw)
    }
    public func matches(_ code: GenericNappletCode) -> Bool { versionId == code.versionId && sha256 == code.sha256 }
}

public struct GenericNappletCode: Equatable, Sendable {
    public init(html: String, binding: GenericNappletBinding, versionId: String, sha256: String) {
        self.html = html; self.binding = binding; self.versionId = versionId; self.sha256 = sha256
    }
    public let html: String
    public let binding: GenericNappletBinding
    public let versionId: String
    public let sha256: String
}
public struct GenericNappletRequest: Sendable {
    public let id: String
    public let operation: String
    public let base: String?
    public let value: Data?
    public let dirty: Bool?
    public let range: String?
    public static func parse(_ data: Data, session: String, binding: GenericNappletBinding) throws -> Self {
        let tree = try GenericJSON.tree(data,envelope:true)
        guard tree.isObject, let o = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw FileNappletError.invalid }
        guard GenericJSON.matches(session, "^[a-f0-9]{32}"), o["session"] as? String == session, o["type"] as? String == "wingman-napplet-data", TrackerDocument.number(o["version"]) == 2,
              let id = o["requestId"] as? String, GenericJSON.matches(id, "^[A-Za-z0-9_-]{1,64}"), let op = o["operation"] as? String else { throw FileNappletError.invalid }
        let common: Set<String> = ["type","version","session","requestId","operation"]
        var base: String?, value: Data?, dirty: Bool?, range: String?
        if op == "dirty" { guard GenericJSON.exact(o, common.union(["dirty"])), let flag = TrackerDocument.boolean(o["dirty"]) else { throw FileNappletError.invalid }; dirty = flag }
        else {
            guard o["binding"] as? String == binding.name else { throw FileNappletError.invalid }
            if binding.capability == "workspace-aggregate" {
                guard op == "read", GenericJSON.exact(o, common.union(["binding","range"])), let r = o["range"] as? String, WorkspaceReportRequest.ranges.contains(r) else { throw FileNappletError.invalid }; range = r
            } else if op == "read" { guard GenericJSON.exact(o, common.union(["binding"])) else { throw FileNappletError.invalid } }
            else {
                guard binding.allowsSave, op == "save", GenericJSON.exact(o, common.union(["binding","baseVersionId","value"])), let b = o["baseVersionId"] as? String, GenericJSON.uuid(b), let v = tree.member("value"), v.isObject else { throw FileNappletError.invalid }
                base = b; value = try GenericJSON.canonicalData(Data(v.encoded.utf8))
            }
        }
        return Self(id: id, operation: op, base: base, value: value, dirty: dirty, range: range)
    }
}

public struct GenericNappletReceipt: Sendable, Equatable {
    public let key: String
    public let fingerprint: String
    public init(baseURL: String, tower: String = "", service: String = "", app: String, workspace: String, viewer: String, file: String, digest: String, binding: GenericNappletBinding, canWrite: Bool) throws {
        guard var url = URLComponents(string: baseURL), ["http","https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil,
              !app.isEmpty, !workspace.isEmpty, !viewer.isEmpty, GenericJSON.uuid(file), GenericJSON.matches(digest, "^[a-f0-9]{64}") else { throw FileNappletError.invalid }
        url.scheme = url.scheme?.lowercased(); url.host = url.host?.lowercased()
        if (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) { url.port = nil }
        if url.path.isEmpty { url.path = "/" }
        guard var backend = url.string else { throw FileNappletError.invalid }; if backend.hasSuffix("/") { backend.removeLast() }
        let identity = [backend, tower, service, app, workspace, viewer]
        key = "napplet-approval-v2:" + SHA256Hex.of(try GenericJSON.canonical(identity + [file]))
        fingerprint = SHA256Hex.of(try GenericJSON.canonical(["version":2, "identity":identity, "codeFileId":file, "digest":digest, "manifest":GenericJSON.decode(binding.manifest), "resources":GenericJSON.decode(binding.resources), "canWrite":canWrite && binding.allowsSave]))
    }
}

public struct GenericNappletTrustStore: Sendable {
    public let directory: URL
    public init(directory: URL = FileNappletTrustStore.local.directory.appendingPathComponent("v2", isDirectory: true)) { self.directory = directory }
    func url(_ r: GenericNappletReceipt) -> URL { directory.appendingPathComponent(r.key + ".json") }
    public func contains(_ r: GenericNappletReceipt) -> Bool {
        guard let data = try? Data(contentsOf: url(r)), data.count < 1024, let o = try? GenericJSON.decode(data) else { return false }
        return GenericJSON.exact(o, ["version","fingerprint"]) && TrackerDocument.number(o["version"]) == 2 && o["fingerprint"] as? String == r.fingerprint
    }
    public func remember(_ r: GenericNappletReceipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        var dir = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try dir.setResourceValues(values)
        do {
            try GenericJSON.canonical(["version":2,"fingerprint":r.fingerprint]).write(to: url(r), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: url(r).path)
            var file = url(r); try file.setResourceValues(values)
            guard contains(r) else { throw FileNappletError.unavailable }
        } catch { try? forget(r); throw error }
    }
    public func forget(_ r: GenericNappletReceipt) throws {
        do { try FileManager.default.removeItem(at: url(r)) }
        catch let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile {}
    }
}

/// Accept navigation references, never an arbitrary fetch URL. Only the extracted File ID reaches sync.
public enum GenericNappletFileLink {
    public static func parse(_ input: String, origin: String, workspace: String) throws -> String {
        let value = input.trimmingCharacters(in:.whitespacesAndNewlines)
        if GenericJSON.uuid(value) { return value }
        guard let url = URLComponents(string:value), let base = URLComponents(string:origin),
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil else { throw FileNappletError.invalid }
        let query = url.queryItems ?? []
        func item(_ name:String) -> String? { let values = query.filter { $0.name == name }; return values.count == 1 ? values[0].value : nil }
        if url.path == "/flight-deck", url.fragment == nil, item("workspaceid") == workspace, let id = item("nappletFile"), GenericJSON.uuid(id) { return id }
        let parts = url.path.split(separator:"/").map(String.init)
        if parts.count == 7, Array(parts.prefix(4)) == ["api","v4","flightdeck-pg","workspaces"], parts[4] == workspace, parts[5] == "files", GenericJSON.uuid(parts[6]), url.query == nil, url.fragment == nil { return parts[6] }
        throw FileNappletError.invalid
    }
}
