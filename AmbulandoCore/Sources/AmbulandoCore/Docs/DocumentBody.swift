import Foundation

/// A document body as stored in Tower (`GET /docs/:d/body`), decoded the way the web client reads it
/// (`sol/src/docs/stored-content.js` with legacy models allowed, plus raw Markdown bodies), and re-encoded in the
/// **same representation** it came from. Nothing outside the fields a native edit touches is rewritten.
public struct DocumentBody: Sendable, Equatable {
    public static let envelopeFormat = "document_content_v1"
    public static let envelopeContentType = "application/vnd.wingman.flightdeck.document-content+json"

    public enum Representation: Sendable, Equatable {
        /// `{format: "document_content_v1", content_model: {...}}` (current web format).
        case envelope
        /// `{content_model: {...}}` without a format discriminator (legacy).
        case legacyWrapped
        /// The content model itself at the root (legacy).
        case legacyModel
        /// Plain Markdown bytes.
        case rawMarkdown
    }

    public enum Editing: Sendable, Equatable {
        /// ProseMirror `editor_state` is authoritative; edits change it in place.
        case proseMirror
        /// A content model with Markdown `content` only (no editor state).
        case markdownModel
        /// Raw Markdown bytes.
        case markdown
        /// Not a format this app can edit without loss; shown read-only.
        case readOnly(String)
    }

    public let representation: Representation?
    public let contentType: String
    /// Parsed root (JSON representations only).
    public let root: JSONValue?
    /// Raw Markdown text (raw representation only).
    public let markdownText: String?
    public let editing: Editing

    // MARK: Decode

    static func isModel(_ value: JSONValue?) -> Bool {
        guard let value, value.isObject else { return false }
        return value["content"]?.stringValue != nil || value["editor_state"]?["type"]?.stringValue == "doc"
    }

    public init(bytes: Data, contentType: String?) {
        let type = (contentType ?? "").lowercased()
        if let parsed = try? JSONValue.parse(bytes) {
            if parsed["format"]?.stringValue == Self.envelopeFormat, Self.isModel(parsed["content_model"]) {
                self.init(json: parsed, representation: .envelope, contentType: contentType); return
            }
            if parsed.isObject, parsed["format"] == nil, Self.isModel(parsed["content_model"]) {
                self.init(json: parsed, representation: .legacyWrapped, contentType: contentType); return
            }
            if Self.isModel(parsed) {
                self.init(json: parsed, representation: .legacyModel, contentType: contentType); return
            }
        }
        if type.contains("markdown") || type.hasPrefix("text/plain"), let text = String(data: bytes, encoding: .utf8) {
            self.init(representation: .rawMarkdown, contentType: contentType ?? "", root: nil, markdownText: text, editing: .markdown)
            return
        }
        self.init(representation: nil, contentType: contentType ?? "", root: nil, markdownText: nil,
                  editing: .readOnly(type.isEmpty ? "This document's stored format is not recognised."
                                     : "This document is stored as \(type), which this app can only show, not edit."))
    }

    private init(json root: JSONValue, representation: Representation, contentType: String?) {
        let model = representation == .legacyModel ? root : root["content_model"]
        let editing: Editing = if model?["editor_state"]?["type"]?.stringValue == "doc" { .proseMirror }
            else if model?["content"]?.stringValue != nil { .markdownModel }
            else { .readOnly("This document's content model is not recognised.") }
        self.init(representation: representation, contentType: contentType ?? "", root: root, markdownText: nil, editing: editing)
    }

    private init(representation: Representation?, contentType: String, root: JSONValue?, markdownText: String?, editing: Editing) {
        self.representation = representation; self.contentType = contentType; self.root = root
        self.markdownText = markdownText; self.editing = editing
    }

    /// Content model object (JSON representations).
    public var contentModel: JSONValue? {
        guard let root else { return nil }
        return representation == .legacyModel ? root : root["content_model"]
    }

    /// The ProseMirror document, when it is authoritative.
    public var editorState: JSONValue? {
        guard editing == .proseMirror else { return nil }
        return contentModel?["editor_state"]
    }

    /// Markdown text for display, search and Markdown editing.
    public var markdown: String {
        if let markdownText { return markdownText }
        if let state = editorState { return ProseMirrorMarkdown.markdown(state) }
        return contentModel?["content"]?.stringValue ?? ""
    }

    public var isEditable: Bool { if case .readOnly = editing { false } else { true } }

    // MARK: Encode (same representation)

    /// Bytes for a body whose ProseMirror document became `state`. Derived fields are regenerated with the web
    /// serializer; unknown model and envelope keys keep their positions and values.
    public func encoded(editorState state: JSONValue) throws -> (bytes: Data, contentType: String) {
        guard editing == .proseMirror, let model = contentModel else { throw DocumentEditError.unsupported }
        var next = model
        for (key, value) in ProseMirrorMarkdown.contentModelFields(state) { next = next.setting(key, value) }
        return (replacingModel(next).serialized(), outgoingContentType)
    }

    /// Bytes for a Markdown edit (Markdown model or raw Markdown).
    public func encoded(markdown text: String) throws -> (bytes: Data, contentType: String) {
        switch editing {
        case .markdown:
            return (Data(text.utf8), contentType.isEmpty ? "text/markdown" : contentType)
        case .markdownModel:
            guard let model = contentModel else { throw DocumentEditError.unsupported }
            var next = model.setting("content", .string(text))
            // Blocks derived from the previous Markdown would describe text that no longer exists. The web client
            // re-derives them from `content` when it opens a model without an editor state.
            if next["content_blocks"] != nil { next = next.setting("content_blocks", .array([])) }
            return (replacingModel(next).serialized(), outgoingContentType)
        default:
            throw DocumentEditError.unsupported
        }
    }

    private var outgoingContentType: String {
        representation == .envelope ? Self.envelopeContentType : (contentType.isEmpty ? Self.envelopeContentType : contentType)
    }

    private func replacingModel(_ model: JSONValue) -> JSONValue {
        guard let root else { return model }
        return representation == .legacyModel ? model : root.setting("content_model", model)
    }

    /// A new document body in the current web format, built from plain paragraphs.
    public static func newDocument(text: String) -> (bytes: Data, contentType: String) {
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        let nodes: [JSONValue] = paragraphs.map { DocumentEditor.paragraph(text: $0, topLevel: true) }
        let state = JSONValue.object([("type", .string("doc")), ("content", .array(nodes.isEmpty ? [DocumentEditor.paragraph(text: "", topLevel: true)] : nodes))])
        let model = JSONValue.object(ProseMirrorMarkdown.contentModelFields(state))
        let root = JSONValue.object([("format", .string(envelopeFormat)), ("content_model", model)])
        return (root.serialized(), envelopeContentType)
    }
}

public enum DocumentEditError: LocalizedError, Equatable, Sendable {
    case unsupported, invalidPath
    public var errorDescription: String? {
        switch self {
        case .unsupported: "This document cannot be edited in this app without losing content."
        case .invalidPath: "That part of the document changed; reopen the editor."
        }
    }
}

/// One editable text block (paragraph, heading or code block) anywhere in the ProseMirror tree.
public struct EditableBlock: Sendable, Equatable, Identifiable {
    /// Indices through `content` arrays from the document root.
    public let path: [Int]
    public let type: String
    public let level: Int?
    /// Nearest container kind (list item, task item, quote, table cell) for display.
    public let container: String?
    public let taskChecked: Bool?
    /// Inline content as text: hard breaks are `\n`; other inline nodes (images, wiki links, files) are U+FFFC.
    public let text: String
    /// True when the block has formatting or inline objects that the plain-text field shows only approximately.
    public let rich: Bool
    public var id: String { path.map(String.init).joined(separator: ".") }
}

/// Structural edits on a ProseMirror document. Every operation rebuilds only the touched node; marks, attributes
/// (including block ids that comment anchors use) and nodes the app does not understand are carried unchanged.
public enum DocumentEditor {
    public static let objectReplacement: Character = "\u{FFFC}"
    static let textBlockTypes: Set<String> = ["paragraph", "heading", "codeBlock"]

    public static func paragraph(text: String, topLevel: Bool) -> JSONValue {
        var pairs: [(String, JSONValue)] = [("type", .string("paragraph"))]
        if topLevel { pairs.append(("attrs", .object([("fdBlockId", .string(ProseMirrorMarkdown.newBlockId()))]))) }
        let inline = inlineNodes(forInserted: text, marks: [], code: false)
        if !inline.isEmpty { pairs.append(("content", .array(inline))) }
        return .object(pairs)
    }

    /// Editable text blocks in document order.
    public static func blocks(_ state: JSONValue) -> [EditableBlock] {
        var out: [EditableBlock] = []
        func walk(_ node: JSONValue, path: [Int], container: String?, checked: Bool?) {
            let type = node["type"]?.stringValue ?? ""
            if textBlockTypes.contains(type) {
                let content = node["content"]?.arrayValue ?? []
                let rich = content.contains { child in
                    let t = child["type"]?.stringValue
                    return (t == "text" && !(child["marks"]?.arrayValue ?? []).isEmpty) || (t != "text" && t != "hardBreak")
                }
                out.append(EditableBlock(path: path, type: type, level: type == "heading" ? node["attrs"]?["level"]?.intValue ?? 1 : nil,
                                         container: container, taskChecked: checked, text: plainText(content, code: type == "codeBlock"), rich: rich))
                return
            }
            let nextContainer: String? = switch type {
            case "listItem": "listItem"
            case "taskItem": "taskItem"
            case "blockquote": "blockquote"
            case "tableCell", "tableHeader": "tableCell"
            default: container
            }
            let nextChecked = type == "taskItem" ? ProseMirrorMarkdown.truthy(node["attrs"]?["checked"]) : checked
            for (index, child) in (node["content"]?.arrayValue ?? []).enumerated() {
                walk(child, path: path + [index], container: nextContainer, checked: nextChecked)
            }
        }
        for (index, child) in (state["content"]?.arrayValue ?? []).enumerated() { walk(child, path: [index], container: nil, checked: nil) }
        return out
    }

    static func plainText(_ content: [JSONValue], code: Bool) -> String {
        content.map { node -> String in
            switch node["type"]?.stringValue {
            case "text": node["text"]?.stringValue ?? ""
            case "hardBreak": "\n"
            default: String(objectReplacement)
            }
        }.joined()
    }

    // MARK: Path access

    static func node(_ root: JSONValue, at path: [Int]) -> JSONValue? {
        var current = root
        for index in path {
            guard let children = current["content"]?.arrayValue, children.indices.contains(index) else { return nil }
            current = children[index]
        }
        return current
    }

    static func replacing(_ root: JSONValue, at path: [Int], with transform: (JSONValue) throws -> [JSONValue]) throws -> JSONValue {
        guard let first = path.first else { throw DocumentEditError.invalidPath }
        guard var children = root["content"]?.arrayValue, children.indices.contains(first) else { throw DocumentEditError.invalidPath }
        if path.count == 1 {
            children.replaceSubrange(first...first, with: try transform(children[first]))
        } else {
            children[first] = try replacing(children[first], at: Array(path.dropFirst()), with: transform)
        }
        return root.setting("content", .array(children))
    }

    // MARK: Text edits

    /// Replaces the text of the block at `path`. Only the changed span is rebuilt: text before and after keeps its
    /// marks; inserted text takes the marks of the text it follows (links and mentions are not extended past their end).
    public static func setText(_ state: JSONValue, path: [Int], text newText: String) throws -> JSONValue {
        try replacing(state, at: path) { node in
            let type = node["type"]?.stringValue ?? ""
            guard textBlockTypes.contains(type) else { throw DocumentEditError.invalidPath }
            let content = node["content"]?.arrayValue ?? []
            let rebuilt = edit(content, to: newText, code: type == "codeBlock")
            return [node.setting("content", rebuilt.isEmpty ? nil : .array(rebuilt))]
        }
    }

    struct Segment { var node: JSONValue; var scalars: [Unicode.Scalar]; var isText: Bool }

    static func segments(_ content: [JSONValue], code: Bool) -> [Segment] {
        content.map { node in
            switch node["type"]?.stringValue {
            case "text": Segment(node: node, scalars: Array((node["text"]?.stringValue ?? "").unicodeScalars), isText: true)
            case "hardBreak": Segment(node: node, scalars: ["\n"], isText: false)
            default: Segment(node: node, scalars: Array(String(objectReplacement).unicodeScalars), isText: false)
            }
        }
    }

    static func edit(_ content: [JSONValue], to newText: String, code: Bool) -> [JSONValue] {
        let segs = segments(content, code: code)
        let old = segs.flatMap(\.scalars)
        let new = Array(newText.unicodeScalars)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let deleteEnd = old.count - suffix
        let inserted = String(String.UnicodeScalarView(new[prefix..<(new.count - suffix)]))
        if prefix == old.count && suffix == 0 && inserted.isEmpty { return content }

        // Locate the segment holding a scalar index in the old text.
        var bounds: [(start: Int, end: Int)] = []
        var offset = 0
        for seg in segs { bounds.append((offset, offset + seg.scalars.count)); offset += seg.scalars.count }
        func segment(at index: Int) -> Int? { bounds.firstIndex { $0.start <= index && index < $0.end } }

        // Marks for inserted text, as a rich editor would choose them: replacement text takes the marks of what it
        // replaces; otherwise it continues the text before it (not extending a link or mention past its end);
        // otherwise it takes the text after it (minus link and mention).
        let unextendable: Set<String> = ["link", "fdMention"]
        func marks(_ i: Int) -> [JSONValue] { segs[i].node["marks"]?.arrayValue ?? [] }
        var inherited: [JSONValue] = []
        if deleteEnd > prefix, let i = segment(at: prefix), segs[i].isText {
            inherited = marks(i)
        } else if prefix > 0, let i = segment(at: prefix - 1), segs[i].isText {
            inherited = marks(i)
            if bounds[i].end == prefix { inherited.removeAll { unextendable.contains($0["type"]?.stringValue ?? "") } }
        } else if let i = segment(at: deleteEnd), segs[i].isText {
            inherited = marks(i).filter { !unextendable.contains($0["type"]?.stringValue ?? "") }
        }

        var before: [JSONValue] = [], after: [JSONValue] = []
        for (i, seg) in segs.enumerated() {
            let (start, end) = bounds[i]
            if end <= prefix { before.append(seg.node); continue }
            if start >= deleteEnd { after.append(seg.node); continue }
            // Overlaps the edited span. An object or hard break is one scalar wide, so it lies wholly inside the
            // span and is removed; a text node keeps the parts outside it, with its marks.
            guard seg.isText else { continue }
            if start < prefix { before.append(seg.node.setting("text", .string(String(String.UnicodeScalarView(seg.scalars[0..<(prefix - start)]))))) }
            if end > deleteEnd { after.append(seg.node.setting("text", .string(String(String.UnicodeScalarView(seg.scalars[(deleteEnd - start)...]))))) }
        }
        let middle = inlineNodes(forInserted: inserted, marks: inherited, code: code)
        return merged(before + middle + after)
    }

    /// Inline nodes for typed text: newlines become hard breaks (literal in code blocks); U+FFFC cannot create an
    /// object and is dropped.
    static func inlineNodes(forInserted text: String, marks: [JSONValue], code: Bool) -> [JSONValue] {
        let cleaned = text.replacingOccurrences(of: String(objectReplacement), with: "")
        func textNode(_ s: String) -> JSONValue {
            var pairs: [(String, JSONValue)] = [("type", .string("text")), ("text", .string(s))]
            if !marks.isEmpty { pairs.append(("marks", .array(marks))) }
            return .object(pairs)
        }
        if code { return cleaned.isEmpty ? [] : [textNode(cleaned)] }
        var out: [JSONValue] = []
        for (index, line) in cleaned.components(separatedBy: "\n").enumerated() {
            if index > 0 { out.append(.object([("type", .string("hardBreak"))])) }
            if !line.isEmpty { out.append(textNode(line)) }
        }
        return out
    }

    /// Joins adjacent text nodes with identical marks and drops empty ones, as ProseMirror normalises.
    static func merged(_ nodes: [JSONValue]) -> [JSONValue] {
        var out: [JSONValue] = []
        for node in nodes {
            if node["type"]?.stringValue == "text" {
                let text = node["text"]?.stringValue ?? ""
                if text.isEmpty { continue }
                if let last = out.last, last["type"]?.stringValue == "text",
                   (last["marks"]?.arrayValue ?? []) == (node["marks"]?.arrayValue ?? []) {
                    out[out.count - 1] = last.setting("text", .string((last["text"]?.stringValue ?? "") + text))
                    continue
                }
            }
            out.append(node)
        }
        return out
    }

    // MARK: Structure edits

    /// Inserts an empty (or given) paragraph after the block at `path`, in the same container.
    public static func insertParagraph(_ state: JSONValue, after path: [Int], text: String = "") throws -> JSONValue {
        try replacing(state, at: path) { node in [node, paragraph(text: text, topLevel: path.count == 1)] }
    }

    /// Appends a top-level paragraph at the end of the document.
    public static func appendParagraph(_ state: JSONValue, text: String = "") -> JSONValue {
        var children = state["content"]?.arrayValue ?? []
        children.append(paragraph(text: text, topLevel: true))
        return state.setting("content", .array(children))
    }

    /// Removes a block. A container left with no blocks is removed with it, so the result stays schema-valid.
    public static func removeBlock(_ state: JSONValue, path: [Int]) throws -> JSONValue {
        guard node(state, at: path) != nil else { throw DocumentEditError.invalidPath }
        var result = try replacing(state, at: path) { _ in [] }
        var parentPath = Array(path.dropLast())
        while !parentPath.isEmpty, let parent = node(result, at: parentPath), (parent["content"]?.arrayValue ?? []).isEmpty {
            result = try replacing(result, at: parentPath) { _ in [] }
            parentPath.removeLast()
        }
        if (result["content"]?.arrayValue ?? []).isEmpty { result = appendParagraph(result) }
        return result
    }

    /// Toggles the `checked` attribute of the task item that contains `path`.
    public static func toggleTask(_ state: JSONValue, containing path: [Int]) throws -> JSONValue {
        for length in stride(from: path.count, through: 1, by: -1) {
            let candidate = Array(path.prefix(length))
            if let item = node(state, at: candidate), item["type"]?.stringValue == "taskItem" {
                return try replacing(state, at: candidate) { item in
                    let attrs = item["attrs"]?.isObject == true ? item["attrs"]! : .object([])
                    return [item.setting("attrs", attrs.setting("checked", .bool(!ProseMirrorMarkdown.truthy(attrs["checked"]))))]
                }
            }
        }
        throw DocumentEditError.invalidPath
    }
}
