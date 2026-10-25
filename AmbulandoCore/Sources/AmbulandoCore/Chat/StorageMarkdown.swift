import Foundation

/// Storage Markdown as the web client writes and reads it (sol `createStorageMarkdown`, `createStorageFileMarkdown`,
/// `storageAttachmentsFromMarkdown` in `chat-attachments.js`).
public enum StorageMarkdown {
    /// `![alt](storage://id)`: brackets dropped from the alt text, "Image" when nothing is left.
    public static func image(objectId: String, alt: String) -> String {
        let safe = alt.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "![\(safe.isEmpty ? "Image" : safe)](storage://\(objectId))"
    }

    /// `[name](storage://id)`: backslashes and brackets escaped, "Uploaded file" when the name is empty.
    public static func file(objectId: String, name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(escaped.isEmpty ? "Uploaded file" : escaped)](storage://\(objectId))"
    }

    /// sol's `STORAGE_MARKDOWN_PATTERN`, also accepting the backslash escapes `file(objectId:name:)` writes.
    private static let reference = try! NSRegularExpression(pattern: #"(!?)\[((?:\\.|[^\]\n\\])*)\]\(storage://([A-Za-z0-9-]+)(?:\s+"[^"]*")?\)"#)
    private static let escape = try! NSRegularExpression(pattern: #"\\(.)"#)

    /// Storage references in a body, first occurrence of each object only (kind from the `!` prefix).
    public static func references(in body: String) -> [MessageAttachment] {
        var seen = Set<String>(), found: [MessageAttachment] = []
        let ns = body as NSString
        for match in reference.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, seen.insert(id.lowercased()).inserted else { continue }
            let raw = ns.substring(with: match.range(at: 2))
            let label = escape.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: "$1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(MessageAttachment(kind: ns.substring(with: match.range(at: 1)) == "!" ? "image" : "file", storageObjectId: id,
                                           filename: label.isEmpty ? "Attachment" : label, mimeType: nil, sizeBytes: nil))
        }
        return found
    }

    /// Attachments plus the body's storage references not already among them (sol `mergeChatStorageAttachments`).
    public static func merged(_ attachments: [MessageAttachment], body: String) -> [MessageAttachment] {
        var seen = Set(attachments.map { $0.storageObjectId.lowercased() })
        return attachments + references(in: body).filter { seen.insert($0.storageObjectId.lowercased()).inserted }
    }

    /// Attachments not already shown inline by a storage link in the body (sol `standaloneChatFileAttachments`).
    public static func standalone(_ attachments: [MessageAttachment], body: String) -> [MessageAttachment] {
        guard !attachments.isEmpty, body.contains("storage://") else { return attachments }
        let linked = Set(references(in: body).map { $0.storageObjectId.lowercased() })
        return attachments.filter { !linked.contains($0.storageObjectId.lowercased()) }
    }
}

/// The placeholder a pasted image or file holds in the composer until its upload resolves.
public enum UploadToken {
    public enum Kind: String, Sendable, Codable { case image, file }

    public static func make(_ kind: Kind, id: String) -> String { "[ Uploading \(kind.rawValue) \(id)... ]" }

    /// Any upload placeholder, including the web's numbered and plain forms (sol `containsInlineImageUploadToken`).
    private static let any = try! NSRegularExpression(pattern: #"\[ Uploading (?:image|file)(?: [A-Za-z0-9-]+)?(?:\.\.\.|…) \]"#)
    private static let identified = try! NSRegularExpression(pattern: #"\[ Uploading (image|file) ([A-Za-z0-9-]+)(?:\.\.\.|…) \]"#)

    public static func contains(in text: String) -> Bool {
        any.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    public static func contains(token: String, in text: String) -> Bool {
        text.contains(token) || text.contains(token.replacingOccurrences(of: "...", with: "…"))
    }

    /// Upload ids of the placeholders in `text`, in order.
    public static func ids(in text: String) -> [(kind: Kind, id: String)] {
        let ns = text as NSString
        return identified.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            Kind(rawValue: ns.substring(with: m.range(at: 1))).map { ($0, ns.substring(with: m.range(at: 2))) }
        }
    }
}

/// Text edits for the composer, in UTF-16 offsets (the text view's selection units).
public enum ComposerText {
    /// Replaces the first occurrence of `token`; the selection keeps its place relative to the surrounding text
    /// (inside the token it moves to the end of the replacement). Nil when the token is not there.
    public static func replacing(_ token: String, with replacement: String, in text: String, selection: NSRange?) -> (text: String, selection: NSRange?)? {
        let ns = text as NSString
        var found = ns.range(of: token)
        if found.location == NSNotFound, UploadToken.contains(in: token) {
            found = ns.range(of: token.replacingOccurrences(of: "...", with: "…"))
        }
        guard found.location != NSNotFound else { return nil }
        let next = ns.replacingCharacters(in: found, with: replacement)
        let delta = (replacement as NSString).length - found.length
        func remap(_ offset: Int) -> Int {
            if offset <= found.location { return offset }
            if offset < NSMaxRange(found) { return found.location + (replacement as NSString).length }
            return offset + delta
        }
        let moved = selection.map { s -> NSRange in
            let start = remap(s.location), end = remap(NSMaxRange(s))
            return NSRange(location: start, length: max(0, end - start))
        }
        return (next, moved)
    }

    /// Where the selection belongs after `old` became `new` through one contiguous edit (a mention completion, a
    /// replaced placeholder): offsets before the edit stay, offsets after it shift, offsets inside it go to its end.
    public static func remap(_ selection: NSRange, from old: String, to new: String) -> NSRange {
        let a = Array((old as NSString).utf16Units), b = Array((new as NSString).utf16Units)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let oldEnd = a.count - suffix, newEnd = b.count - suffix
        func map(_ offset: Int) -> Int {
            // Before the edit (an insertion exactly at the caret moves the caret after it).
            if offset < prefix || (offset == prefix && prefix < oldEnd) { return min(offset, b.count) }
            if offset >= oldEnd { return offset - oldEnd + newEnd }
            return newEnd
        }
        let start = map(selection.location), end = map(NSMaxRange(selection))
        return NSRange(location: start, length: max(0, end - start))
    }
}

private extension NSString {
    var utf16Units: [unichar] { (0..<length).map { character(at: $0) } }
}
