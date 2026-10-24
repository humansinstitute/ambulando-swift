import Foundation

/// Styled run of inline text for native rendering.
public struct InlineRun: Sendable, Equatable {
    public var text: String
    public var bold = false, italic = false, code = false, strike = false, underline = false
    public var link: String?
    public var mention = false
    /// An inline object shown as a label (wiki link, image, file).
    public var object = false

    public init(text: String) { self.text = text }
}

/// A display block. Read-only rendering never alters the stored body; nodes this app does not render natively are
/// listed as `preserved` so the reader says so instead of dropping them.
public indirect enum RenderBlock: Sendable, Equatable {
    case heading(level: Int, runs: [InlineRun])
    case paragraph(runs: [InlineRun])
    case code(language: String, text: String)
    case quote([RenderBlock])
    case list(ordered: Bool, start: Int, items: [ListItem])
    case table(rows: [[[InlineRun]]])
    case image(alt: String, source: String)
    case rule
    case preserved(type: String, text: String)

    public struct ListItem: Sendable, Equatable {
        public let checked: Bool?
        public let blocks: [RenderBlock]
    }
}

public enum DocumentRender {
    /// Blocks for any decoded body.
    public static func blocks(_ body: DocumentBody) -> [RenderBlock] {
        if let state = body.editorState { return (state["content"]?.arrayValue ?? []).map(block) }
        return markdownBlocks(body.markdown)
    }

    // MARK: ProseMirror

    static func block(_ node: JSONValue) -> RenderBlock {
        let content = node["content"]?.arrayValue ?? []
        switch node["type"]?.stringValue ?? "" {
        case "heading": return .heading(level: node["attrs"]?["level"]?.intValue ?? 1, runs: runs(content))
        case "paragraph": return .paragraph(runs: runs(content))
        case "codeBlock": return .code(language: node["attrs"]?["language"]?.stringValue ?? "", text: content.map { $0["text"]?.stringValue ?? "" }.joined())
        case "blockquote": return .quote(content.map(block))
        case "bulletList", "orderedList", "taskList":
            let type = node["type"]?.stringValue
            return .list(ordered: type == "orderedList", start: node["attrs"]?["start"]?.intValue ?? 1, items: content.map { item in
                RenderBlock.ListItem(checked: type == "taskList" ? ProseMirrorMarkdown.truthy(item["attrs"]?["checked"]) : nil,
                                     blocks: (item["content"]?.arrayValue ?? []).map(block))
            })
        case "table":
            return .table(rows: content.map { row in (row["content"]?.arrayValue ?? []).map { cell in
                (cell["content"]?.arrayValue ?? []).flatMap { runs($0["content"]?.arrayValue ?? []) }
            } })
        case "horizontalRule": return .rule
        case "image", "fdStorageImage":
            let attrs = node["attrs"]
            return .image(alt: attrs?["alt"]?.stringValue ?? "", source: attrs?["objectId"]?.stringValue.map { "storage://\($0)" } ?? attrs?["src"]?.stringValue ?? "")
        case let other:
            return .preserved(type: other.isEmpty ? "unknown" : other, text: ProseMirrorMarkdown.inlineMarkdown(content))
        }
    }

    static func runs(_ nodes: [JSONValue]) -> [InlineRun] {
        nodes.map { node in
            switch node["type"]?.stringValue {
            case "text":
                var run = InlineRun(text: node["text"]?.stringValue ?? "")
                for mark in node["marks"]?.arrayValue ?? [] {
                    switch mark["type"]?.stringValue {
                    case "bold": run.bold = true
                    case "italic": run.italic = true
                    case "code": run.code = true
                    case "strike": run.strike = true
                    case "underline": run.underline = true
                    case "link": run.link = mark["attrs"]?["href"]?.stringValue
                    case "fdMention": run.mention = true
                    default: break
                    }
                }
                return run
            case "hardBreak": return InlineRun(text: "\n")
            case "fdWikiLink":
                var run = InlineRun(text: node["attrs"]?["title"]?.stringValue ?? "Linked document"); run.object = true; return run
            case "fdStorageImage", "image":
                var run = InlineRun(text: "Image" + (node["attrs"]?["alt"]?.stringValue.map { ": \($0)" } ?? "")); run.object = true; return run
            case "fdStorageFile":
                var run = InlineRun(text: node["attrs"]?["label"]?.stringValue ?? "File"); run.object = true; return run
            default:
                var run = InlineRun(text: ProseMirrorMarkdown.inlineMarkdown(node["content"]?.arrayValue ?? []))
                if run.text.isEmpty { run.text = node["type"]?.stringValue ?? "" }
                run.object = true
                return run
            }
        }
    }

    // MARK: Markdown bodies

    /// A small block reader for Markdown bodies (headings, lists, task items, quotes, fences, rules, paragraphs);
    /// inline styles come from Foundation's Markdown parser.
    public static func markdownBlocks(_ text: String) -> [RenderBlock] {
        var out: [RenderBlock] = []
        var paragraph: [String] = []
        var items: [RenderBlock.ListItem] = [], ordered = false
        var fence: (language: String, lines: [String])?
        func flushParagraph() { if !paragraph.isEmpty { out.append(.paragraph(runs: inline(paragraph.joined(separator: "\n")))); paragraph = [] } }
        func flushList() { if !items.isEmpty { out.append(.list(ordered: ordered, start: 1, items: items)); items = [] } }
        for line in text.components(separatedBy: "\n") {
            if var f = fence {
                if line.hasPrefix("```") { out.append(.code(language: f.language, text: f.lines.joined(separator: "\n"))); fence = nil }
                else { f.lines.append(line); fence = f }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { flushParagraph(); flushList(); fence = (String(trimmed.dropFirst(3)), []); continue }
            if trimmed.isEmpty { flushParagraph(); flushList(); continue }
            if let level = headingLevel(trimmed) {
                flushParagraph(); flushList()
                out.append(.heading(level: level, runs: inline(String(trimmed.drop(while: { $0 == "#" }).drop(while: { $0 == " " })))))
                continue
            }
            if trimmed == "---" || trimmed == "***" { flushParagraph(); flushList(); out.append(.rule); continue }
            if trimmed.hasPrefix(">") { flushParagraph(); flushList(); out.append(.quote([.paragraph(runs: inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))])); continue }
            if let item = listItem(trimmed) {
                flushParagraph()
                if items.isEmpty { ordered = item.ordered }
                items.append(RenderBlock.ListItem(checked: item.checked, blocks: [.paragraph(runs: inline(item.text))]))
                continue
            }
            flushList()
            paragraph.append(trimmed)
        }
        if let f = fence { out.append(.code(language: f.language, text: f.lines.joined(separator: "\n"))) }
        flushParagraph(); flushList()
        return out
    }

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " || line.count == hashes else { return nil }
        return hashes
    }

    static func listItem(_ line: String) -> (ordered: Bool, checked: Bool?, text: String)? {
        for bullet in ["- [ ] ", "* [ ] "] where line.hasPrefix(bullet) { return (false, false, String(line.dropFirst(bullet.count))) }
        for bullet in ["- [x] ", "- [X] ", "* [x] "] where line.hasPrefix(bullet) { return (false, true, String(line.dropFirst(bullet.count))) }
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) { return (false, nil, String(line.dropFirst(2))) }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return (true, nil, String(line.dropFirst(digits.count + 2))) }
        return nil
    }

    static func inline(_ text: String) -> [InlineRun] {
        guard let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return [InlineRun(text: text)]
        }
        return attributed.runs.map { run in
            var out = InlineRun(text: String(attributed[run.range].characters))
            if let intent = run.inlinePresentationIntent {
                out.bold = intent.contains(.stronglyEmphasized)
                out.italic = intent.contains(.emphasized)
                out.code = intent.contains(.code)
                out.strike = intent.contains(.strikethrough)
            }
            out.link = run.link?.absoluteString
            return out
        }
    }
}
