import Foundation

/// Styled run of inline text for native rendering.
public struct InlineRun: Sendable, Equatable {
    public var text: String
    public var bold = false, italic = false, code = false, strike = false, underline = false
    public var link: String?
    public var mention = false
    /// Mention or record reference identity (`mention:<kind>:<id>`), kept so the reader can route to it.
    public var mentionKind: String?
    public var mentionId: String?
    /// Inline image source (`storage://<object id>` or a web address, which is never fetched).
    public var image: String?
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
        case "paragraph":
            let inline = runs(content)
            // A paragraph holding only one image shows it as an image block, as the web does.
            if inline.count == 1, let image = inline[0].image { return .image(alt: inline[0].text, source: image) }
            return .paragraph(runs: inline)
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
            return .image(alt: attrs?["alt"]?.stringValue ?? "", source: imageSource(attrs))
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
                    case "fdMention":
                        run.mention = true
                        run.mentionKind = mark["attrs"]?["mentionType"]?.stringValue
                        run.mentionId = mark["attrs"]?["mentionId"]?.stringValue
                    default: break
                    }
                }
                return run
            case "hardBreak": return InlineRun(text: "\n")
            case "fdWikiLink":
                var run = InlineRun(text: node["attrs"]?["title"]?.stringValue ?? "Linked document"); run.object = true; return run
            case "fdStorageImage", "image":
                let attrs = node["attrs"]
                var run = InlineRun(text: attrs?["alt"]?.stringValue ?? "")
                run.image = imageSource(attrs)
                run.object = true
                return run
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

    /// `storage://<objectId>` for stored images (matching the web serializer), else the node's `src`.
    static func imageSource(_ attrs: JSONValue?) -> String {
        attrs?["objectId"]?.stringValue.map { "storage://\($0)" } ?? attrs?["src"]?.stringValue ?? ""
    }

    // MARK: Markdown bodies

    /// Blocks for a Markdown body or message (see `MarkdownBlocks`).
    public static func markdownBlocks(_ text: String) -> [RenderBlock] { MarkdownBlocks.parse(text) }

    static func inline(_ text: String) -> [InlineRun] { MarkdownBlocks.inline(text) }
}
