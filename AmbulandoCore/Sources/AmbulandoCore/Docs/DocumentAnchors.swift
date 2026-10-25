import Foundation

/// Web-compatible selection coordinates. Positions count UTF-16 units and ProseMirror node boundaries,
/// never rendered Markdown characters. Extra version metadata is advisory; quote verification is mandatory.
public struct DocumentAnchor: Sendable, Equatable {
    public let quote: String
    public let from: Int
    public let to: Int
    public let version: Int?
    public let line: Int?
    public let blockId: String?
    public init(quote: String, from: Int, to: Int, version: Int? = nil, line: Int? = nil, blockId: String? = nil) {
        self.quote = quote; self.from = from; self.to = to; self.version = version; self.line = line; self.blockId = blockId
    }
    public init?(metadata: [String: Any]) {
        guard let quote = metadata["anchor_quote"] as? String, !quote.isEmpty else { return nil }
        if let from = metadata["anchor_start_offset"] as? Int, let to = metadata["anchor_end_offset"] as? Int, from >= 0, to > from {
            self.init(quote: quote, from: from, to: to, version: metadata["anchor_doc_row_version"] as? Int, blockId: metadata["anchor_block_id"] as? String)
        } else if let line = metadata["anchor_line_number"] as? Int, line > 0 {
            self.init(quote: quote, from: 0, to: quote.utf16.count, version: metadata["anchor_doc_row_version"] as? Int, line: line)
        } else { return nil }
    }
    public var metadata: [String: any Sendable] {
        var result: [String: any Sendable] = ["anchor_quote": quote, "anchor_start_offset": from, "anchor_end_offset": to]
        if let line {
            result.removeValue(forKey: "anchor_start_offset"); result.removeValue(forKey: "anchor_end_offset")
            result["anchor_line_number"] = line; result["anchor_end_line_number"] = line
        }
        if let version { result["anchor_doc_row_version"] = version }
        if let blockId { result["anchor_block_id"] = blockId }
        return result
    }
}

public struct DocumentTextSpan: Sendable, Equatable {
    public let path: [Int]
    public let start: Int
    public let text: String
    public var line: Int? = nil
    public var blockId: String? = nil
    public func anchor(_ range: NSRange, version: Int?) -> DocumentAnchor? {
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= (text as NSString).length else { return nil }
        let quote = (text as NSString).substring(with: range)
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return DocumentAnchor(quote: quote, from: start + range.location, to: start + NSMaxRange(range), version: version, line: line, blockId: blockId)
    }
}

public enum DocumentAnchors {
    /// ProseMirror textBetween for a passage spanning text blocks (UTF-16 positions).
    public static func selectedText(_ anchor: DocumentAnchor, in state: JSONValue) -> String? {
        guard anchor.line == nil, anchor.from >= 0, anchor.to > anchor.from else { return nil }
        let parts = spans(state).compactMap { span -> String? in
            let start = max(anchor.from, span.start), end = min(anchor.to, span.start + span.text.utf16.count)
            guard end > start else { return nil }
            return (span.text as NSString).substring(with: NSRange(location: start - span.start, length: end - start))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    public static func spans(_ state: JSONValue) -> [DocumentTextSpan] {
        var out: [DocumentTextSpan] = []
        func size(_ node: JSONValue) -> Int {
            if node["type"]?.stringValue == "text" { return (node["text"]?.stringValue ?? "").utf16.count }
            guard let children = node["content"]?.arrayValue else { return 1 }
            return children.reduce(2) { $0 + size($1) }
        }
        func walk(_ node: JSONValue, _ position: Int, _ path: [Int]) {
            let children = node["content"]?.arrayValue ?? []
            if ["paragraph", "heading", "codeBlock"].contains(node["type"]?.stringValue ?? "") {
                // Inline atoms take one PM position. U+FFFC occupies that position in the native text bridge.
                let text = children.map { child -> String in
                    if child["type"]?.stringValue == "text" { return child["text"]?.stringValue ?? "" }
                    return child["type"]?.stringValue == "hardBreak" ? "\n" : "\u{FFFC}"
                }.joined()
                let rootBlock = path.first.flatMap { index in state["content"]?.arrayValue.flatMap { $0.indices.contains(index) ? $0[index] : nil } }
                let blockId = rootBlock?["attrs"]?["fdBlockId"]?.stringValue ?? rootBlock?["attrs"]?["id"]?.stringValue
                out.append(DocumentTextSpan(path: path, start: position + 1, text: text, blockId: blockId))
            }
            var offset = node["type"]?.stringValue == "doc" ? 0 : position + 1
            for (i, child) in children.enumerated() { walk(child, offset, path + [i]); offset += size(child) }
        }
        walk(state, 0, [])
        return out
    }

    /// Markdown readers use the web's line/quote contract, never pretend Markdown offsets are PM positions.
    public static func markdownSpans(_ markdown: String, blocks: [RenderBlock]) -> [DocumentTextSpan] {
        let lines = markdown.components(separatedBy: "\n")
        var cursor = 0
        var out: [DocumentTextSpan] = []
        func add(_ text: String, _ path: [Int]) {
            guard !text.isEmpty else { return }
            // Resolve a rendered block to its source line, including inline formatting. If uncertain, keep it selectable
            // through the ordinary renderer without manufacturing a source coordinate.
            let candidates = lines.indices.filter { $0 >= cursor && (lines[$0].contains(text) || DocumentRender.markdownBlocks(lines[$0]).contains { block in
                switch block { case .paragraph(let runs), .heading(_, let runs): return runs.map(\.text).joined() == text; default: return false }
            }) }
            guard let line = candidates.first else { return }
            cursor = line + 1
            out.append(DocumentTextSpan(path: path, start: 0, text: text, line: line + 1))
        }
        func walk(_ block: RenderBlock, _ path: [Int]) {
            switch block {
            case .paragraph(let runs), .heading(_, let runs): if !runs.contains(where: { $0.image != nil }) { add(runs.map(\.text).joined(), path) }
            case .quote(let blocks): for (i, block) in blocks.enumerated() { walk(block, path + [i]) }
            case .list(_, _, let items): for (i, item) in items.enumerated() { for (j, block) in item.blocks.enumerated() { walk(block, path + [i, j]) } }
            default: break
            }
        }
        for (i, block) in blocks.enumerated() { walk(block, [i]) }
        return out
    }

    /// As in the web: exact offsets first, then a unique quote relocation; ambiguous/deleted text stays orphaned.
    public static func resolve(_ anchor: DocumentAnchor, in spans: [DocumentTextSpan]) -> (span: DocumentTextSpan, range: NSRange)? {
        for span in spans where anchor.line == nil || anchor.line == span.line {
            let range = NSRange(location: anchor.from - span.start, length: anchor.to - anchor.from)
            if anchor.line == nil, range.location >= 0, NSMaxRange(range) <= span.text.utf16.count,
               (span.text as NSString).substring(with: range) == anchor.quote { return (span, range) }
        }
        var matches: [(DocumentTextSpan, NSRange)] = []
        for span in spans where anchor.line == nil || anchor.line == span.line {
            let text = span.text as NSString
            var search = NSRange(location: 0, length: text.length)
            while search.length > 0 {
                let found = text.range(of: anchor.quote, options: [], range: search)
                if found.location == NSNotFound { break }
                matches.append((span, found))
                if matches.count > 1 { return nil }
                search = NSRange(location: found.location + 1, length: text.length - found.location - 1)
            }
        }
        return matches.first
    }
}

extension CommentRecord {
    public var documentAnchor: DocumentAnchor? {
        guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let metadata = object["metadata"] as? [String: Any] else { return nil }
        return DocumentAnchor(metadata: metadata)
    }
    public var anchorQuote: String? {
        let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        return (object?["metadata"] as? [String: Any])?["anchor_quote"] as? String
    }
}
