import Foundation

/// `metadata.attachments[].text_attachment` of the shared text attachment contract v1. It carries counts only, never text.
public struct TextAttachmentInfo: Sendable, Equatable, Codable, Hashable {
    public enum Source: String, Sendable, Codable { case paste, edit }
    public let v: Int
    public let source: Source
    /// Unicode code points of the complete text.
    public let chars: Int
    public let lines: Int

    public init(source: Source, chars: Int, lines: Int) { v = 1; self.source = source; self.chars = chars; self.lines = lines }

    public var requestObject: [String: Any] { ["v": v, "source": source.rawValue, "chars": chars, "lines": lines] }

    static func from(_ object: Any?) -> TextAttachmentInfo? {
        guard let o = object as? [String: Any], let source = (o["source"] as? String).flatMap(Source.init(rawValue:)) else { return nil }
        return TextAttachmentInfo(source: source, chars: flexibleInt(o["chars"]) ?? 0, lines: flexibleInt(o["lines"]) ?? 0)
    }
}

/// Text split into pages of bounded size, so a multi-megabyte file is shown and edited one page at a time. Pages are
/// exact substrings: joining them returns the original bytes (LF, CRLF, lone CR, BOM and every scalar untouched).
public struct TextPages: Sendable, Equatable {
    /// Target code points per page; a page ends at a line break when one is near, else at the target.
    public static let pageScalars = 12_000
    static let lookahead = 2_000

    public private(set) var pages: [String]
    private var bytes: [Int]
    private var scalars: [Int]

    public init(text: String) {
        var out: [String] = [], utf8: [Int] = [], count: [Int] = []
        let all = text.unicodeScalars
        var start = all.startIndex
        while start < all.endIndex {
            var end = all.index(start, offsetBy: Self.pageScalars, limitedBy: all.endIndex) ?? all.endIndex
            if end < all.endIndex {
                let limit = all.index(end, offsetBy: Self.lookahead, limitedBy: all.endIndex) ?? all.endIndex
                var probe = end
                while probe < limit {
                    let previous = all[all.index(before: probe)]
                    if previous == "\n" || previous == "\r" { end = probe; break }
                    all.formIndex(after: &probe)
                }
                if all[all.index(before: end)] == "\r", all[end] == "\n" { all.formIndex(after: &end) }
            }
            let page = String(all[start..<end])
            out.append(page); utf8.append(page.utf8.count); count.append(page.unicodeScalars.count)
            start = end
        }
        if out.isEmpty { out = [""]; utf8 = [0]; count = [0] }
        pages = out; bytes = utf8; scalars = count
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.bytes == rhs.bytes, lhs.scalars == rhs.scalars, lhs.pages.count == rhs.pages.count else { return false }
        return zip(lhs.pages, rhs.pages).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    /// nil when the bytes are not valid UTF-8 (such a file can be downloaded and copied but not edited as text).
    public init?(data: Data) {
        guard let text = TextAttachmentPolicy.exactUTF8(data) else { return nil }
        self.init(text: text)
    }

    public var pageCount: Int { pages.count }
    public var byteCount: Int { bytes.reduce(0, +) }
    public var codePoints: Int { scalars.reduce(0, +) }
    public func page(_ index: Int) -> String { pages[index] }

    public mutating func replace(page index: Int, with text: String) {
        guard pages.indices.contains(index), !pages[index].utf8.elementsEqual(text.utf8) else { return }
        if text.unicodeScalars.count <= Self.pageScalars + Self.lookahead + 1 {
            pages[index] = text; bytes[index] = text.utf8.count; scalars[index] = text.unicodeScalars.count
            return
        }
        let replacement = TextPages(text: text)
        pages.replaceSubrange(index...index, with: replacement.pages)
        bytes.replaceSubrange(index...index, with: replacement.bytes)
        scalars.replaceSubrange(index...index, with: replacement.scalars)
    }

    public var data: Data {
        var out = Data(capacity: byteCount)
        for page in pages { out.append(contentsOf: page.utf8) }
        return out
    }

    /// The page holding code point offset `offset`, for jumping to a line or search hit.
    public func page(containing offset: Int) -> Int {
        var remaining = offset
        for (i, n) in scalars.enumerated() { if remaining < n { return i }; remaining -= n }
        return pages.count - 1
    }
}

public enum TextAttachmentError: LocalizedError, Equatable, Sendable {
    case tooLarge, notText, missing, integrity
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "Text over 100 MB cannot be attached from this app."
        case .notText: "This file is not UTF-8 text, so it can be downloaded but not edited."
        case .missing: "The text is no longer on this device."
        case .integrity: "The staged text does not match its checksum."
        }
    }
}

/// The complete content type of a text attachment (contract v1).
public let textAttachmentContentType = "text/plain; charset=utf-8"

public enum TextAttachmentStaging {
    /// Stages complete UTF-8 bytes in the staging directory (protected until first unlock) and describes them as a
    /// pending attachment. The name is made safe; the bytes are never altered.
    public static func stage(data: Data, name: String, source: TextAttachmentInfo.Source, in staging: URL,
                             id: String = UUID().uuidString.lowercased()) throws -> PendingAttachment {
        guard data.count <= 100 * 1024 * 1024 else { throw TextAttachmentError.tooLarge }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let file = "text-\(id)-\(UUID().uuidString.prefix(8).lowercased()).txt"
        #if os(iOS)
        try data.write(to: staging.appendingPathComponent(file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: staging.appendingPathComponent(file), options: [.atomic])
        #endif
        var attachment = PendingAttachment(id: id, filename: TextAttachmentPolicy.sanitizedName(name), mimeType: textAttachmentContentType,
                                           sizeBytes: data.count, sha256: SHA256Hex.of(data), staged: file)
        attachment.text = TextAttachmentInfo(source: source, chars: scalarCount(data), lines: TextAttachmentPolicy.lineCount(data))
        return attachment
    }

    public static func stage(text: String, name: String, source: TextAttachmentInfo.Source, in staging: URL) throws -> PendingAttachment {
        try stage(data: TextAttachmentPolicy.fileBytes(text), name: name, source: source, in: staging)
    }

    /// The staged bytes, checked against the recorded checksum.
    public static func read(_ attachment: PendingAttachment, in staging: URL) throws -> Data {
        guard let data = try? Data(contentsOf: staging.appendingPathComponent(attachment.staged)) else { throw TextAttachmentError.missing }
        guard SHA256Hex.of(data) == attachment.sha256 else { throw TextAttachmentError.integrity }
        return data
    }

    /// First bytes only, for a card preview that stays cheap for large files.
    public static func head(_ attachment: PendingAttachment, in staging: URL, bytes: Int = 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: staging.appendingPathComponent(attachment.staged)) else { return nil }
        defer { try? handle.close() }
        guard var chunk = try? handle.read(upToCount: bytes) else { return nil }
        // A cut inside a multi-byte scalar would not decode: drop up to 3 trailing bytes until it does.
        for _ in 0..<4 { if let s = String(data: chunk, encoding: .utf8) { return TextAttachmentPolicy.preview(s) }; chunk = chunk.dropLast() }
        return nil
    }

    /// Replaces an attachment's content and name with an edit: a new staged file. The previous bytes remain until garbage collection after a durable metadata transition. The id (and so
    /// its place in the draft) is kept.
    public static func replacing(_ attachment: PendingAttachment, data: Data, name: String, in staging: URL) throws -> PendingAttachment {
        var next = try stage(data: data, name: name, source: attachment.text?.source ?? .paste, in: staging, id: attachment.id)
        next.objectId = nil; next.uploadURL = nil; next.complete = false
        return next
    }

    static func scalarCount(_ data: Data) -> Int {
        // Every UTF-8 byte that is not a continuation byte starts one scalar.
        data.reduce(0) { $0 + (($1 & 0xC0) == 0x80 ? 0 : 1) }
    }

    /// `Pasted text N.txt` not used by the composer's text attachments.
    public static func nextName(among attachments: [PendingAttachment]) -> String {
        TextAttachmentPolicy.nextName(taken: attachments.map(\.filename))
    }
}

extension Schema {
    /// Drafts keep their staged attachments (pasted text files, photos) across relaunch and context changes.
    static func migrateV6(_ db: SQLiteConnection) throws {
        // Idempotent: a store rewound to an older version for an upgrade test already has the column.
        let info = try db.prepare("SELECT 1 FROM pragma_table_info('drafts') WHERE name = 'attachments'")
        guard try !info.step() else { return }
        try db.execute("ALTER TABLE drafts ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]';")
    }
}
