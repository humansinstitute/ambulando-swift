import Foundation

/// Port of `sol/src/docs/editor/prosemirror-to-flightdeck.js`: derives the Markdown `content` and the
/// compatibility `content_blocks` from a ProseMirror `editor_state`, exactly as the web editor does on save.
/// The ProseMirror JSON stays authoritative; this only regenerates the derived fields after a native edit.
/// Strings are handled as Unicode scalars, matching JavaScript's code-point regular expressions.
public enum ProseMirrorMarkdown {
    public static let contentFormat = "flightdeck_prosemirror_v1"
    public static let editorStateFormat = "prosemirror_json_v1"
    public static let editorStateVersion = 1

    static let escapable: Set<Unicode.Scalar> = Set("\\`*_{}[]()#+-.!|>&".unicodeScalars)

    static func escapeText(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if escapable.contains(scalar) { out.append("\\") }
            out.append(scalar)
        }
        return String(out)
    }

    /// JavaScript `\s`.
    static func isJSWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    /// `\p{L}` or `\p{N}`.
    static func isLetterOrNumber(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    static func reference(_ s: Unicode.Scalar) -> String { "&#\(s.value);" }

    static func trimEndJS(_ value: String) -> String {
        var scalars = Array(value.unicodeScalars)
        while let last = scalars.last, isJSWhitespace(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    static func trimJS(_ value: String) -> String {
        var scalars = Array(value.unicodeScalars)
        while let last = scalars.last, isJSWhitespace(last) { scalars.removeLast() }
        while let first = scalars.first, isJSWhitespace(first) { scalars.removeFirst() }
        return String(String.UnicodeScalarView(scalars))
    }

    struct MarkTextOptions { var atStart = false, atEnd = false, encodeFirst = false, encodeLast = false }

    static func markText(_ text: String, marks: [JSONValue], _ o: MarkTextOptions) -> String {
        var scalars: [Unicode.Scalar] = []
        // escapeText, then tab/CR/LF as character references.
        var escaped = ""
        for scalar in escapeText(text).unicodeScalars {
            if scalar == "\t" || scalar == "\r" || scalar == "\n" { escaped += reference(scalar) } else { escaped.unicodeScalars.append(scalar) }
        }
        scalars = Array(escaped.unicodeScalars)
        func rebuild() -> String { String(String.UnicodeScalarView(scalars)) }
        if o.encodeFirst, let first = scalars.first, isLetterOrNumber(first) {
            scalars = Array(reference(first).unicodeScalars) + scalars.dropFirst()
        }
        if o.encodeLast, let last = scalars.last, isLetterOrNumber(last) {
            scalars = Array(scalars.dropLast()) + Array(reference(last).unicodeScalars)
        }
        if !marks.isEmpty || o.atStart {
            var lead = 0
            while lead < scalars.count, isJSWhitespace(scalars[lead]) { lead += 1 }
            if lead > 0 { scalars = scalars[0..<lead].flatMap { Array(reference($0).unicodeScalars) } + scalars[lead...] }
        }
        if !marks.isEmpty || o.atEnd {
            var tail = scalars.count
            while tail > 0, isJSWhitespace(scalars[tail - 1]) { tail -= 1 }
            if tail < scalars.count { scalars = Array(scalars[0..<tail]) + scalars[tail...].flatMap { Array(reference($0).unicodeScalars) } }
        }
        var out = rebuild()
        for mark in marks {
            let attrs = mark["attrs"]
            switch mark["type"]?.stringValue {
            case "bold": out = "**\(out)**"
            case "italic": out = "_\(out)_"
            case "strike": out = "~~\(out)~~"
            case "underline": out = "<u>\(out)</u>"
            case "code": out = "`" + text.replacingOccurrences(of: "`", with: "\\`") + "`"
            case "link": out = "[\(out)](\(attrs?["href"]?.stringValue ?? ""))"
            case "fdMention":
                let label = nonEmpty(attrs?["label"]) ?? text
                out = "@[\(label)](mention:\(nonEmpty(attrs?["mentionType"]) ?? "record"):\(nonEmpty(attrs?["mentionId"]) ?? ""))"
            default: break
            }
        }
        return out
    }

    /// JavaScript truthiness for an optional string attribute (`attrs?.x || fallback`).
    static func nonEmpty(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let s): return s.isEmpty ? nil : s
        case .number(let n): return Double(n) == 0 ? nil : n
        case .bool(let b): return b ? "true" : nil
        case .null: return nil
        default: return value.serializedString()
        }
    }

    static func truthy(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return (Double(n) ?? 0) != 0
        case .string(let s): return !s.isEmpty
        default: return true
        }
    }

    static let markOrder = ["code", "bold", "italic", "strike", "link", "fdMention", "underline"]

    static func sortedMarks(_ marks: [JSONValue]) -> [JSONValue] {
        // Stable sort by rank; unknown marks rank -1 (first), as `indexOf` does.
        let rank = { (m: JSONValue) in markOrder.firstIndex(of: m["type"]?.stringValue ?? "") ?? -1 }
        return marks.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    static func marksKey(_ marks: [JSONValue]) -> String { JSONValue.array(marks).serializedString() }

    struct Run { var node: JSONValue; var type: String; var text: String; var marks: [JSONValue] }

    static func inlineMarkdown(_ nodes: [JSONValue]) -> String {
        var runs: [Run] = []
        for source in nodes {
            let type = source["type"]?.stringValue ?? ""
            let marks = source["marks"]?.arrayValue ?? []
            let node = Run(node: source, type: type, text: source["text"]?.stringValue ?? "", marks: type == "text" ? sortedMarks(marks) : marks)
            if type == "text", let previous = runs.last, previous.type == "text", marksKey(previous.marks) == marksKey(node.marks) {
                runs[runs.count - 1].text += node.text
            } else {
                runs.append(node)
            }
        }
        var rendered: [String] = runs.enumerated().map { index, run in
            switch run.type {
            case "text":
                return markText(run.text, marks: run.marks, MarkTextOptions(
                    atStart: index == 0 || runs[index - 1].type == "hardBreak",
                    atEnd: index == runs.count - 1 || runs[index + 1].type == "hardBreak",
                    encodeFirst: index > 0 && !runs[index - 1].marks.isEmpty,
                    encodeLast: index < runs.count - 1 && !runs[index + 1].marks.isEmpty))
            case "fdWikiLink": return wikiSource(run.node["attrs"])
            case "hardBreak": return "<br>"
            case "fdStorageImage", "image":
                let attrs = run.node["attrs"]
                let objectId = nonEmpty(attrs?["objectId"])
                let src = run.type == "fdStorageImage" && objectId != nil ? "storage://\(objectId!)"
                    : nonEmpty(attrs?["src"]) ?? (objectId.map { "storage://\($0)" } ?? "")
                return "![\(escapeText(nonEmpty(attrs?["alt"]) ?? ""))](\(src))"
            case "fdStorageFile":
                let attrs = run.node["attrs"]
                let src = nonEmpty(attrs?["src"]) ?? ""
                let label = nonEmpty(attrs?["label"]) ?? nonEmpty(attrs?["title"]) ?? (src.isEmpty ? nil : src) ?? "File"
                return "[\(escapeText(label))](\(src))"
            default: return inlineMarkdown(run.node["content"]?.arrayValue ?? [])
            }
        }
        // Shared outer marks stay open across adjacent runs.
        let delimiters: [String: (String, String)] = ["bold": ("**", "**"), "italic": ("_", "_"), "strike": ("~~", "~~"), "underline": ("<u>", "</u>")]
        if runs.count > 1 {
            for index in 1..<runs.count {
                guard runs[index - 1].type == "text", runs[index].type == "text" else { continue }
                let left = Array(runs[index - 1].marks.reversed()), right = Array(runs[index].marks.reversed())
                var opening = "", closing = ""
                for m in 0..<min(left.count, right.count) {
                    guard let pair = delimiters[left[m]["type"]?.stringValue ?? ""], left[m] == right[m] else { break }
                    opening += pair.0
                    closing = pair.1 + closing
                }
                if !opening.isEmpty {
                    // Delimiters are ASCII: trim scalars, never grapheme clusters (a combining mark may follow).
                    rendered[index - 1] = String(String.UnicodeScalarView(rendered[index - 1].unicodeScalars.dropLast(closing.unicodeScalars.count)))
                    rendered[index] = String(String.UnicodeScalarView(rendered[index].unicodeScalars.dropFirst(opening.unicodeScalars.count)))
                }
            }
        }
        return rendered.joined()
    }

    /// `encodeURIComponent`.
    static func encodeURIComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// `wikiSource` from sol/src/docs/wiki-links.js.
    static func wikiSource(_ attrs: JSONValue?) -> String {
        let label = nonEmpty(attrs?["title"]) ?? "Untitled document"
        if let documentId = nonEmpty(attrs?["documentId"]) {
            return "[\(escapeText(label))](wiki:\(encodeURIComponent(documentId)))"
        }
        return "[[\(label)]]"
    }

    static func indent(_ value: String, _ spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value.components(separatedBy: "\n").map { prefix + $0 }.joined(separator: "\n")
    }

    static func listMarkdown(_ node: JSONValue, ordered: Bool) -> String {
        let type = node["type"]?.stringValue
        let start = node["attrs"]?["start"].flatMap { truthy($0) ? $0.intValue : nil } ?? 1
        return (node["content"]?.arrayValue ?? []).enumerated().map { index, item in
            let marker = type == "taskList" ? "- [\(truthy(item["attrs"]?["checked"]) ? "x" : " ")]"
                : ordered ? "\(index + start)." : "-"
            let width = type == "taskList" ? 2 : marker.count + 1
            let body = blockNodesMarkdown(item["content"]?.arrayValue ?? [])
            let lines = body.components(separatedBy: "\n")
            let first = lines.first ?? "", rest = Array(lines.dropFirst())
            return "\(marker) \(first)" + (rest.isEmpty ? "" : "\n" + indent(rest.joined(separator: "\n"), width))
        }.joined(separator: "\n")
    }

    static func tableMarkdown(_ node: JSONValue) -> String {
        let rows = node["content"]?.arrayValue ?? []
        guard !rows.isEmpty else { return "" }
        let cells = rows.map { row in (row["content"]?.arrayValue ?? []).map { cell in
            inlineMarkdown(cell["content"]?.arrayValue?.first?["content"]?.arrayValue ?? [])
        } }
        let width = max(cells.map(\.count).max() ?? 1, 1)
        func normalize(_ row: [String]) -> [String] { (0..<width).map { $0 < row.count ? row[$0] : "" } }
        let header = normalize(cells[0])
        var lines = ["| \(header.joined(separator: " | ")) |", "| \(header.map { _ in "---" }.joined(separator: " | ")) |"]
        for row in cells.dropFirst() { lines.append("| \(normalize(row).joined(separator: " | ")) |") }
        return lines.joined(separator: "\n")
    }

    public static func blockMarkdown(_ node: JSONValue) -> String {
        let content = node["content"]?.arrayValue ?? []
        switch node["type"]?.stringValue {
        case "heading":
            let level = node["attrs"]?["level"].flatMap { truthy($0) ? $0.intValue : nil } ?? 1
            return trimEndJS("\(String(repeating: "#", count: max(level, 0))) \(inlineMarkdown(content))")
        case "paragraph": return inlineMarkdown(content)
        case "codeBlock":
            let language = nonEmpty(node["attrs"]?["language"]) ?? ""
            let text = content.map { $0["text"]?.stringValue ?? "" }.joined()
            return "```\(language)\n\(text)\n```"
        case "blockquote":
            return blockNodesMarkdown(content).components(separatedBy: "\n").map { trimEndJS("> \($0)") }.joined(separator: "\n")
        case "horizontalRule": return "---"
        case "bulletList", "taskList": return listMarkdown(node, ordered: false)
        case "orderedList": return listMarkdown(node, ordered: true)
        case "table": return tableMarkdown(node)
        case "fdStorageImage", "image", "fdStorageFile": return inlineMarkdown([node])
        case "fdUploadPlaceholder": return ""
        default: return inlineMarkdown(content)
        }
    }

    static func blockNodesMarkdown(_ nodes: [JSONValue]) -> String {
        nodes.map(blockMarkdown).filter { !trimJS($0).isEmpty }.joined(separator: "\n\n")
    }

    static func compatibilityBlockType(_ node: JSONValue) -> String {
        switch node["type"]?.stringValue {
        case "heading": "heading"
        case "paragraph": "paragraph"
        case "codeBlock": "code"
        case "bulletList", "orderedList", "taskList": "list"
        case let other?: other.isEmpty ? "markdown" : other
        case nil: "markdown"
        }
    }

    public static func newBlockId() -> String { "pm_" + UUID().uuidString.lowercased() }

    static func blockId(_ node: JSONValue) -> String {
        let attrs = node["attrs"]
        let raw = nonEmpty(attrs?["fdBlockId"]) ?? nonEmpty(attrs?["id"]) ?? ""
        let trimmed = trimJS(raw)
        return trimmed.isEmpty ? newBlockId() : trimmed
    }

    /// Markdown for the whole document.
    public static func markdown(_ state: JSONValue) -> String {
        blockNodesMarkdown(state["content"]?.arrayValue ?? [])
    }

    /// The six content-model fields the web editor writes, in its key order.
    public static func contentModelFields(_ editorState: JSONValue) -> [(String, JSONValue)] {
        let state = editorState["type"]?.stringValue == "doc" ? editorState : .object([("type", .string("doc")), ("content", .array([]))])
        let nodes = state["content"]?.arrayValue ?? []
        let blocks: [JSONValue] = nodes.compactMap { node in
            let id = blockId(node)
            let raw = blockMarkdown(node)
            guard !trimJS(raw).isEmpty else { return nil }
            var attrs = node["attrs"]?.isObject == true ? node["attrs"]! : .object([])
            attrs = attrs.setting("pmNodeId", .string(id))
            return .object([("id", .string(id)), ("type", .string(compatibilityBlockType(node))), ("text", .string(raw)), ("attrs", attrs)])
        }
        return [
            ("content", .string(blockNodesMarkdown(nodes))),
            ("content_format", .string(contentFormat)),
            ("content_blocks", .array(blocks)),
            ("editor_state", state),
            ("editor_state_format", .string(editorStateFormat)),
            ("editor_state_version", .int(editorStateVersion)),
        ]
    }
}
