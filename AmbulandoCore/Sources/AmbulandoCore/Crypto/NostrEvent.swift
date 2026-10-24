import CryptoKit
import Foundation

/// A signed NIP-01 event. Field names match the wire format.
public struct NostrEvent: Codable, Sendable, Equatable {
    public let id: String
    public let pubkey: String
    public let created_at: Int
    public let kind: Int
    public let tags: [[String]]
    public let content: String
    public let sig: String

    public init(id: String, pubkey: String, created_at: Int, kind: Int, tags: [[String]], content: String, sig: String) {
        self.id = id; self.pubkey = pubkey; self.created_at = created_at
        self.kind = kind; self.tags = tags; self.content = content; self.sig = sig
    }

    /// JSON object for embedding in a request body, using the canonical field set.
    public var jsonObject: [String: Any] {
        ["id": id, "pubkey": pubkey, "created_at": created_at, "kind": kind, "tags": tags, "content": content, "sig": sig]
    }
}

public struct NostrEventTemplate: Sendable, Equatable {
    public var kind: Int
    public var tags: [[String]]
    public var content: String
    public var createdAt: Int

    public init(kind: Int, tags: [[String]], content: String, createdAt: Int = Int(Date().timeIntervalSince1970)) {
        self.kind = kind; self.tags = tags; self.content = content; self.createdAt = createdAt
    }
}

/// NIP-01 event serialization, written out explicitly so the id is byte-identical
/// to `JSON.stringify([0,pubkey,created_at,kind,tags,content])` used by nostr-tools.
public enum NostrSerialization {
    public static func commitment(pubkey: String, template: NostrEventTemplate) -> Data {
        var out = "[0,"
        out += quote(pubkey) + "," + String(template.createdAt) + "," + String(template.kind) + ",["
        out += template.tags.map { "[" + $0.map(quote).joined(separator: ",") + "]" }.joined(separator: ",")
        out += "]," + quote(template.content) + "]"
        return Data(out.utf8)
    }

    public static func eventId(pubkey: String, template: NostrEventTemplate) -> String {
        Data(SHA256.hash(data: commitment(pubkey: pubkey, template: template))).hex
    }

    /// JSON string escaping per ECMAScript JSON.stringify (which NIP-01 specifies).
    public static func quote(_ value: String) -> String {
        var out = "\""
        out.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

public enum SHA256Hex {
    public static func of(_ data: Data) -> String { Data(SHA256.hash(data: data)).hex }
    public static func of(_ string: String) -> String { of(Data(string.utf8)) }

    /// Streams a file through SHA-256 in 1 MB reads (large downloads are never loaded whole).
    public static func ofFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize()).hex
    }
}
