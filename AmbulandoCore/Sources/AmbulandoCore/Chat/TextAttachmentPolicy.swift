import Foundation

/// When pasted text becomes a `.txt` attachment, how those files are named, and what a card shows of them.
///
/// Lengths count Unicode code points (scalars), not UTF-16 units or grapheme clusters, so an emoji or a combining
/// sequence counts the same on every client. Text is never normalised: LF, CRLF and lone CR reach the file untouched.
public enum TextAttachmentPolicy {
    /// A paste longer than this many code points becomes a file.
    public static let pasteFileThreshold = 2500
    /// The composer's inline text may not grow past this many code points.
    public static let inlineLimit = 10_000
    /// Hard byte guard for inline text (UTF-8), whatever the code-point count.
    public static let inlineByteLimit = 40_000
    /// A counter shows once the text is within this many code points of the limit.
    public static let counterWindow = 500
    /// Longest first-line preview a card shows, in code points.
    public static let previewLimit = 140
    public static let mimeType = "text/plain"
    public static let baseName = "Pasted text"

    public static func codePoints(_ text: String) -> Int { text.unicodeScalars.count }

    public enum PasteDecision: Equatable, Sendable {
        /// Insert as ordinary text.
        case inline
        /// Store the complete text as a file.
        case file
    }

    /// A paste becomes a file when it is over the threshold, or would push the composer past the inline limit.
    /// `existingCodePoints` is the composer text that stays after the paste (the selection being replaced is excluded).
    public static func decide(paste: String, existingCodePoints: Int, existingUTF8Bytes: Int = 0) -> PasteDecision {
        let count = codePoints(paste)
        if count > pasteFileThreshold { return .file }
        if existingCodePoints + count > inlineLimit { return .file }
        if existingUTF8Bytes + paste.utf8.count > inlineByteLimit { return .file }
        return .inline
    }

    /// Code points still available for typing, or nil when the counter is hidden.
    public static func remaining(codePoints used: Int) -> Int? {
        let left = inlineLimit - used
        return left <= counterWindow ? left : nil
    }

    /// Whether directly typed or IME-committed `insert` still fits; the caller keeps the composer text otherwise.
    public static func typingFits(insert: String, replacing: String, existingCodePoints: Int, existingUTF8Bytes: Int) -> Bool {
        existingCodePoints - codePoints(replacing) + codePoints(insert) <= inlineLimit
            && existingUTF8Bytes - replacing.utf8.count + insert.utf8.count <= inlineByteLimit
    }

    /// `Pasted text.txt`, `Pasted text 2.txt`, … the first number not in `taken` (case-insensitive).
    public static func nextName(taken: some Sequence<String>) -> String {
        let used = Set(taken.map { $0.lowercased() })
        var n = 1
        while true {
            let name = n == 1 ? "\(baseName).txt" : "\(baseName) \(n).txt"
            if !used.contains(name.lowercased()) { return name }
            n += 1
        }
    }

    /// A user-entered file name made safe: no path separators or control characters, `.txt` kept, never empty.
    public static func sanitizedName(_ raw: String) -> String {
        var name = String(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && $0 != "/" && $0 != "\\" && $0 != ":" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = baseName }
        if name.unicodeScalars.count > 120 { name = String(String.UnicodeScalarView(name.unicodeScalars.prefix(120))) }
        return (name as NSString).pathExtension.isEmpty ? name + ".txt" : name
    }

    /// The first non-blank line, cut to `previewLimit` code points on a scalar boundary, for a compact card.
    /// Scans only the head of the text, so it stays cheap for multi-megabyte content.
    public static func preview(_ text: String) -> String {
        var line = String.UnicodeScalarView()
        var started = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                if started { break } else { continue }
            }
            if !started, scalar == " " || scalar == "\t" { continue }
            started = true
            line.append(scalar)
            if line.count >= previewLimit { break }
        }
        return String(line)
    }

    /// Lines as an editor counts them: LF, CRLF and CR each end one; a trailing terminator adds no empty line.
    public static func lineCount(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        var lines = 1, previous: UInt8 = 0
        for byte in data {
            if byte == 10 { lines += 1 }          // LF, or the LF of a CRLF
            else if previous == 13 { lines += 1 } // a lone CR ended the previous line
            previous = byte
        }
        // A terminator at the very end opened no new line.
        if previous == 10 || previous == 13 { lines -= 1 }
        return lines
    }

    /// The exact bytes of a pasted text: UTF-8 with nothing normalised or added.
    public static func fileBytes(_ text: String) -> Data { Data(text.utf8) }
}
