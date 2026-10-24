import Foundation

/// Markdown → display blocks for chat messages and Markdown document bodies, following what the web client renders
/// with `marked` (`sol/src/markdown.js`: GFM, `breaks: true`): ATX and setext headings, paragraphs whose single newlines
/// are line breaks, fenced and indented code, nested block quotes, nested ordered/unordered/task lists, pipe tables,
/// rules and images. Inline styles come from Foundation's Markdown parser; mention tokens
/// (`@[Label](mention:type:id)`) and `storage://` references become typed runs so they keep their identity and route.
///
/// Pure and `Sendable`: screens run it off the main actor and cache the result. It only reads the text; stored bodies
/// are never rewritten from these blocks.
public enum MarkdownBlocks {
    /// Nesting beyond this (quotes in lists in quotes …) is shown as text rather than recursing further.
    static let maxDepth = 16

    public static func parse(_ text: String) -> [RenderBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return blocks(normalized.components(separatedBy: "\n").map(expandLeadingTabs), depth: 0)
    }

    /// True when a message body has nothing Markdown, a mention or a link could change, so it can be shown verbatim.
    public static func isPlainText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar {
            case "*", "_", "`", "#", ">", "|", "[", "]", "~", "!", "<", "\\", "@": return false
            default: continue
            }
        }
        if text.contains("://") || text.contains("mailto:") { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("    ") || line.hasPrefix("\t") { return false }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("+ ") || trimmed == "-" || trimmed.hasPrefix("---") || trimmed.hasPrefix("===") { return false }
            let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, digits.count <= 9, let next = trimmed.dropFirst(digits.count).first, next == "." || next == ")" { return false }
        }
        return true
    }

    // MARK: Blocks

    static func blocks(_ lines: [String], depth: Int) -> [RenderBlock] {
        if depth > maxDepth {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.paragraph(runs: [InlineRun(text: text)])]
        }
        var out: [RenderBlock] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            out.append(contentsOf: paragraphBlocks(paragraph))
            paragraph = []
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { flush(); i += 1; continue }
            let indent = indentation(line)

            if indent >= 4 {
                if !paragraph.isEmpty { paragraph.append(trimLeading(line)); i += 1; continue }   // lazy continuation
                var code: [String] = []
                while i < lines.count, isBlank(lines[i]) || indentation(lines[i]) >= 4 {
                    code.append(stripIndent(lines[i], 4)); i += 1
                }
                while let last = code.last, isBlank(last) { code.removeLast() }
                out.append(.code(language: "", text: code.joined(separator: "\n")))
                continue
            }
            if let fence = fenceOpen(line) {
                flush()
                i += 1
                var code: [String] = []
                while i < lines.count {
                    if isFenceClose(lines[i], fence) { i += 1; break }
                    code.append(stripIndent(lines[i], fence.indent)); i += 1
                }
                out.append(.code(language: fence.info, text: code.joined(separator: "\n")))
                continue
            }
            if let heading = atxHeading(line) {
                flush()
                out.append(.heading(level: heading.level, runs: inline(heading.text)))
                i += 1; continue
            }
            if !paragraph.isEmpty, let level = setextLevel(line) {
                out.append(.heading(level: level, runs: inline(paragraph.joined(separator: "\n"))))
                paragraph = []
                i += 1; continue
            }
            if isRule(line) { flush(); out.append(.rule); i += 1; continue }
            if quoteContent(line) != nil {
                flush()
                var inner: [String] = []
                while i < lines.count {
                    if let content = quoteContent(lines[i]) { inner.append(content); i += 1; continue }
                    // Lazy continuation of a quoted paragraph.
                    if !isBlank(lines[i]), let last = inner.last, !isBlank(last), !startsBlock(lines[i]) { inner.append(lines[i]); i += 1; continue }
                    break
                }
                out.append(.quote(blocks(inner, depth: depth + 1)))
                continue
            }
            if i + 1 < lines.count, let table = table(lines, at: i) {
                flush()
                out.append(.table(rows: table.rows))
                i = table.next
                continue
            }
            if let marker = listMarker(line), paragraph.isEmpty || (!marker.content.isEmpty && (!marker.ordered || marker.start == 1)) {
                flush()
                let list = self.list(lines, at: i, first: marker, depth: depth)
                out.append(list.block)
                i = list.next
                continue
            }
            paragraph.append(trimLeading(line))
            i += 1
        }
        flush()
        return out
    }

    /// A paragraph; a paragraph made only of images becomes image blocks (as the web shows them full width).
    static func paragraphBlocks(_ lines: [String]) -> [RenderBlock] {
        let text = lines.map { trimTrailing($0) }.joined(separator: "\n")
        let runs = inline(text)
        let images = runs.filter { $0.image != nil }
        if !images.isEmpty, runs.allSatisfy({ $0.image != nil || $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return images.map { .image(alt: $0.text, source: $0.image ?? "") }
        }
        return [.paragraph(runs: runs)]
    }

    // MARK: Lists

    struct ListMarker: Equatable {
        let ordered: Bool
        /// `-`, `*`, `+` for bullets; `.` or `)` for ordered lists. A different character starts a new list.
        let delimiter: Character
        let start: Int
        let contentIndent: Int
        let content: String
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let rest = Substring(line).dropFirst(indent)
        guard let first = rest.first else { return nil }
        var ordered = false, delimiter: Character = first, start = 1, markerWidth = 1
        if first == "-" || first == "*" || first == "+" {
            // nothing more
        } else if first.isASCII, first.isNumber {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9, let d = rest.dropFirst(digits.count).first, d == "." || d == ")" else { return nil }
            ordered = true; delimiter = d; start = Int(digits) ?? 1; markerWidth = digits.count + 1
        } else { return nil }
        let after = rest.dropFirst(markerWidth)
        if after.isEmpty || after.allSatisfy({ $0 == " " }) {
            return ListMarker(ordered: ordered, delimiter: delimiter, start: start, contentIndent: indent + markerWidth + 1, content: "")
        }
        let spaces = after.prefix { $0 == " " }.count
        guard spaces >= 1 else { return nil }
        // Five or more spaces: the content is indented code; the item content starts after one space.
        let used = spaces >= 5 ? 1 : spaces
        return ListMarker(ordered: ordered, delimiter: delimiter, start: start, contentIndent: indent + markerWidth + used,
                          content: String(after.dropFirst(used)))
    }

    static func list(_ lines: [String], at index: Int, first: ListMarker, depth: Int) -> (block: RenderBlock, next: Int) {
        var items: [RenderBlock.ListItem] = []
        var marker = first
        var itemLines: [String] = [first.content]
        var i = index + 1
        func finish() {
            var content = itemLines
            var checked: Bool?
            if let head = content.first, let task = taskPrefix(head) {
                checked = task.checked
                content[0] = task.rest
            }
            items.append(RenderBlock.ListItem(checked: checked, blocks: blocks(content, depth: depth + 1)))
        }
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { itemLines.append(""); i += 1; continue }
            let indent = indentation(line)
            if indent >= marker.contentIndent { itemLines.append(stripIndent(line, marker.contentIndent)); i += 1; continue }
            if let next = listMarker(line), next.ordered == first.ordered, next.delimiter == first.delimiter, !isRule(line) {
                finish()
                marker = next
                itemLines = [next.content]
                i += 1
                continue
            }
            if let last = itemLines.last, !isBlank(last), !startsBlock(line) { itemLines.append(trimLeading(line)); i += 1; continue }
            break
        }
        finish()
        return (.list(ordered: first.ordered, start: first.start, items: items), i)
    }

    static func taskPrefix(_ line: String) -> (checked: Bool, rest: String)? {
        for (prefix, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            guard rest.isEmpty || rest.first == " " else { return nil }
            return (checked, String(rest.dropFirst()))
        }
        return nil
    }

    // MARK: Tables

    static func table(_ lines: [String], at index: Int) -> (rows: [[[InlineRun]]], next: Int)? {
        let header = lines[index]
        guard header.contains("|"), indentation(header) <= 3, isAlignmentRow(lines[index + 1]) else { return nil }
        let headerCells = cells(header)
        guard headerCells.count == cells(lines[index + 1]).count else { return nil }
        let width = headerCells.count
        func normalized(_ row: [String]) -> [[InlineRun]] {
            var row = Array(row.prefix(width))
            while row.count < width { row.append("") }
            return row.map { inline($0) }
        }
        var rows = [normalized(headerCells)]
        var i = index + 2
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|"),
              quoteContent(lines[i]) == nil, fenceOpen(lines[i]) == nil, atxHeading(lines[i]) == nil {
            rows.append(normalized(cells(lines[i])))
            i += 1
        }
        return (rows, i)
    }

    static func isAlignmentRow(_ line: String) -> Bool {
        let parts = cells(line)
        guard !parts.isEmpty, line.contains("-"), line.contains("|") || parts.count > 1 else { return false }
        return parts.allSatisfy { part in
            var cell = Substring(part)
            if cell.hasPrefix(":") { cell = cell.dropFirst() }
            if cell.hasSuffix(":") { cell = cell.dropLast() }
            return !cell.isEmpty && cell.allSatisfy { $0 == "-" }
        }
    }

    /// Cells of a pipe-table row; `\|` and pipes inside code spans stay in the cell.
    static func cells(_ line: String) -> [String] {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|") { text = text.dropFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text = text.dropLast() }
        var out: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in text {
            if escaped {
                current.append(ch == "|" ? "|" : "\\\(ch)")
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { out.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        if escaped { current.append("\\") }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }

    // MARK: Line kinds

    struct Fence { let character: Character; let count: Int; let indent: Int; let info: String }

    static func fenceOpen(_ line: String) -> Fence? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let rest = Substring(line).dropFirst(indent)
        guard let ch = rest.first, ch == "`" || ch == "~" else { return nil }
        let count = rest.prefix { $0 == ch }.count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if ch == "`" && info.contains("`") { return nil }
        return Fence(character: ch, count: count, indent: indent, info: String(info.split(separator: " ").first ?? ""))
    }

    static func isFenceClose(_ line: String, _ fence: Fence) -> Bool {
        let indent = indentation(line)
        guard indent <= 3 else { return false }
        let rest = Substring(line).dropFirst(indent)
        let count = rest.prefix { $0 == fence.character }.count
        return count >= fence.count && rest.dropFirst(count).allSatisfy { $0 == " " }
    }

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let rest = Substring(line).dropFirst(indent)
        let hashes = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let after = rest.dropFirst(hashes)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: " ###".
        if let range = text.range(of: "(^|\\s)#+$", options: .regularExpression) { text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return (hashes, text)
    }

    static func setextLevel(_ line: String) -> Int? {
        guard indentation(line) <= 3 else { return nil }
        let text = line.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, text.allSatisfy({ $0 == "=" }) { return 1 }
        if text.count >= 2, text.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    static func isRule(_ line: String) -> Bool {
        guard indentation(line) <= 3 else { return false }
        let chars = line.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let first = chars.first, first == "-" || first == "*" || first == "_" else { return false }
        return chars.allSatisfy { $0 == first }
    }

    static func quoteContent(_ line: String) -> String? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let rest = Substring(line).dropFirst(indent)
        guard rest.first == ">" else { return nil }
        let after = rest.dropFirst()
        return String(after.first == " " ? after.dropFirst() : after)
    }

    /// Lines that end a paragraph (or a lazy continuation) by starting another block.
    static func startsBlock(_ line: String) -> Bool {
        if isBlank(line) || fenceOpen(line) != nil || atxHeading(line) != nil || isRule(line) || quoteContent(line) != nil { return true }
        if let marker = listMarker(line), !marker.content.isEmpty, !marker.ordered || marker.start == 1 { return true }
        return false
    }

    static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    static func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    static func stripIndent(_ line: String, _ count: Int) -> String {
        String(line.dropFirst(min(count, indentation(line))))
    }

    static func trimLeading(_ line: String) -> String { String(line.drop { $0 == " " || $0 == "\t" }) }

    static func trimTrailing(_ line: String) -> String {
        var s = Substring(line)
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return String(s)
    }

    /// Tabs in leading whitespace count as four columns; tabs elsewhere (including inside code) are kept.
    static func expandLeadingTabs(_ line: String) -> String {
        guard line.first == "\t" || (line.first == " " && line.contains("\t")) else { return line }
        var out = ""
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            if line[index] == "\t" { out += String(repeating: " ", count: 4 - out.count % 4) } else { out.append(" ") }
            index = line.index(after: index)
        }
        return out + line[index...]
    }

    // MARK: Inline

    private static let breakTag = try! NSRegularExpression(pattern: "<br\\s*/?\\s*>", options: [.caseInsensitive])
    private static let bareURL = try! NSRegularExpression(pattern: "https?://[^\\s<>]+[^\\s<>.,;:!?\"')\\]]")

    /// Inline runs. Line breaks are kept (the web renders single newlines as breaks). Mentions keep their kind and id;
    /// `storage://` links and images keep their object reference; bare web addresses become links.
    public static func inline(_ text: String) -> [InlineRun] {
        let ns = text as NSString
        let source = breakTag.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "\n")
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attributed = try? AttributedString(markdown: source, options: options) else { return [InlineRun(text: source)] }
        var out: [InlineRun] = []
        for run in attributed.runs {
            var item = InlineRun(text: String(attributed[run.range].characters))
            if let intent = run.inlinePresentationIntent {
                item.bold = intent.contains(.stronglyEmphasized)
                item.italic = intent.contains(.emphasized)
                item.code = intent.contains(.code)
                item.strike = intent.contains(.strikethrough)
            }
            if let image = run.imageURL {
                item.image = image.absoluteString
                item.object = true
            } else if let link = run.link?.absoluteString {
                if link.lowercased().hasPrefix("mention:") {
                    let parts = link.dropFirst("mention:".count).split(separator: ":", maxSplits: 1).map(String.init)
                    item.mention = true
                    item.mentionKind = parts.first ?? "unknown"
                    item.mentionId = parts.count > 1 ? parts[1] : ""
                    // `@[Label](mention:…)`: the `@` belongs to the mention, shown on people and agents only.
                    let hadAt = out.last.map { !$0.code && $0.mentionId == nil && $0.text.hasSuffix("@") } ?? false
                    if hadAt, var previous = out.popLast() {
                        previous.text.removeLast()
                        if !previous.text.isEmpty { out.append(previous) }
                    }
                    let continuing = out.last.map { $0.mentionId == item.mentionId && $0.mentionKind == item.mentionKind } ?? false
                    if !continuing, item.mentionKind == "person" || item.mentionKind == "agent" { item.text = "@" + item.text }
                } else if link.lowercased().hasPrefix("storage://") {
                    item.object = true
                    item.link = link
                } else {
                    item.link = link
                }
            }
            out.append(item)
        }
        return autolinked(out)
    }

    /// Splits plain runs around bare http(s) addresses (GFM autolinks).
    static func autolinked(_ runs: [InlineRun]) -> [InlineRun] {
        var out: [InlineRun] = []
        for run in runs {
            guard run.link == nil, !run.code, !run.mention, run.image == nil, run.text.contains("://") else { out.append(run); continue }
            let ns = run.text as NSString
            var cursor = 0
            for match in bareURL.matches(in: run.text, range: NSRange(location: 0, length: ns.length)) {
                if match.range.location > cursor {
                    var before = run; before.text = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)); out.append(before)
                }
                var link = run
                link.text = ns.substring(with: match.range)
                link.link = link.text
                out.append(link)
                cursor = match.range.location + match.range.length
            }
            if cursor == 0 { out.append(run); continue }
            if cursor < ns.length { var after = run; after.text = ns.substring(from: cursor); out.append(after) }
        }
        return out
    }
}
