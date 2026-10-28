import Foundation

/// What a wiki reference points at. `documentId` is the stable binding (`[Title](wiki:<document-id>)` or an
/// `fdWikiLink` node with `documentId`); a title-only reference (`[[Title]]`) has none until a target is chosen or created.
public struct WikiTarget: Sendable, Equatable {
    public var documentId: String?
    public var title: String
    /// For a title-only reference: which of the document's same-title title-only references this is, in reading order. It lets
    /// "create this page" or "choose this page" change exactly the reference that was opened. Zero for a bound link.
    public var occurrence: Int
    public init(documentId: String? = nil, title: String, occurrence: Int = 0) { self.documentId = documentId; self.title = title; self.occurrence = occurrence }
}

/// How a reference resolves against the documents saved on this device.
public enum WikiResolution: Sendable, Equatable {
    /// A readable document: opens at once from the cache, whichever scope or channel it is in now.
    case available(DocRecord)
    /// A bound id that is not among the readable documents saved here. It is still opened by id (the server decides
    /// access), and it is never replaced by a title match or a newly created page.
    case unavailable(documentId: String)
    /// A title-only reference with no match in the source channel: offered for creation.
    case unresolved(title: String)
    /// A title-only reference several pages answer to: the person picks one, nothing is chosen silently.
    case ambiguous(title: String, matches: [DocRecord])
}

public enum WikiLinks {
    // MARK: Syntax

    /// `[[Title]]` outside code, as the web editor's picker plugin reads it.
    private static let literal = try! NSRegularExpression(pattern: "\\[\\[([^\\]\\n]+)\\]\\]")

    /// The document id of a canonical wiki href (`wiki:<percent-encoded id>`), or nil for anything else.
    public static func documentId(fromHref href: String) -> String? {
        guard href.lowercased().hasPrefix("wiki:") else { return nil }
        let raw = String(href.dropFirst("wiki:".count))
        let decoded = raw.removingPercentEncoding ?? raw
        let id = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// Splits literal `[[Title]]` out of plain text runs. Code, links, mentions and objects are left exactly as they are,
    /// and runs that already carry a wiki target are not touched again.
    public static func expandLiterals(_ runs: [InlineRun]) -> [InlineRun] {
        var out: [InlineRun] = []
        for run in runs {
            guard run.wiki == nil, !run.code, run.link == nil, !run.mention, !run.object, run.image == nil, run.text.contains("[[") else {
                out.append(run); continue
            }
            let ns = run.text as NSString
            var cursor = 0
            for match in literal.matches(in: run.text, range: NSRange(location: 0, length: ns.length)) {
                let title = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { continue }
                if match.range.location > cursor {
                    var before = run; before.text = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)); out.append(before)
                }
                var link = run
                link.text = title
                link.wiki = WikiTarget(title: title)
                out.append(link)
                cursor = match.range.location + match.range.length
            }
            if cursor == 0 { out.append(run); continue }
            if cursor < ns.length { var after = run; after.text = ns.substring(from: cursor); out.append(after) }
        }
        return out
    }

    // MARK: Reading order and current titles

    /// Numbers each title-only reference among the same-title title-only references in reading order, and returns the blocks.
    static func numbered(_ blocks: [RenderBlock]) -> [RenderBlock] {
        var counts: [String: Int] = [:]
        func runs(_ list: [InlineRun]) -> [InlineRun] {
            list.map { run in
                guard var wiki = run.wiki, wiki.documentId == nil else { return run }
                let key = normalized(wiki.title)
                wiki.occurrence = counts[key, default: 0]
                counts[key, default: 0] += 1
                var next = run; next.wiki = wiki; return next
            }
        }
        func walk(_ blocks: [RenderBlock]) -> [RenderBlock] {
            blocks.map { block in
                switch block {
                case .heading(let level, let r): .heading(level: level, runs: runs(r))
                case .paragraph(let r): .paragraph(runs: runs(r))
                case .quote(let inner): .quote(walk(inner))
                case .list(let ordered, let start, let items):
                    .list(ordered: ordered, start: start, items: items.map { RenderBlock.ListItem(checked: $0.checked, blocks: walk($0.blocks)) })
                case .table(let rows): .table(rows: rows.map { $0.map(runs) })
                default: block
                }
            }
        }
        return walk(blocks)
    }

    /// Shows each bound link under its page's current title (after a rename), leaving the stored text alone. A link whose page
    /// is not among `docs` keeps the title it was written with.
    public static func retitled(_ blocks: [RenderBlock], docs: [DocRecord]) -> [RenderBlock] {
        let titles = Dictionary(docs.filter { !$0.archived }.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        func runs(_ list: [InlineRun]) -> [InlineRun] {
            list.map { run in
                guard let id = run.wiki?.documentId, let current = titles[id], current != run.text else { return run }
                var next = run; next.text = current; return next
            }
        }
        func walk(_ blocks: [RenderBlock]) -> [RenderBlock] {
            blocks.map { block in
                switch block {
                case .heading(let level, let r): .heading(level: level, runs: runs(r))
                case .paragraph(let r): .paragraph(runs: runs(r))
                case .quote(let inner): .quote(walk(inner))
                case .list(let ordered, let start, let items):
                    .list(ordered: ordered, start: start, items: items.map { RenderBlock.ListItem(checked: $0.checked, blocks: walk($0.blocks)) })
                case .table(let rows): .table(rows: rows.map { $0.map(runs) })
                default: block
                }
            }
        }
        return walk(blocks)
    }

    // MARK: Resolution

    public static func normalized(_ title: String) -> String { title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Resolves one reference. Ids are looked up by id alone, whatever channel or scope the document is in now; a title
    /// is matched only among the source channel's pages (default local matching).
    public static func resolve(_ target: WikiTarget, in docs: [DocRecord], sourceChannelId: String?) -> WikiResolution {
        if let id = target.documentId {
            if let found = docs.first(where: { $0.id == id && !$0.archived }) { return .available(found) }
            return .unavailable(documentId: id)
        }
        let wanted = normalized(target.title)
        let local = docs.filter { !$0.archived && $0.channelId == sourceChannelId && normalized($0.title) == wanted }
        switch local.count {
        case 0: return .unresolved(title: target.title)
        case 1: return .available(local[0])
        default: return .ambiguous(title: target.title, matches: local)
        }
    }

    /// Picker search over readable documents saved here. By default only the source channel's pages; `everywhere` adds the
    /// other channels and scopes. Same-title pages are all returned so the person chooses; the current document is not offered.
    public static func search(_ query: String, in docs: [DocRecord], sourceChannelId: String?, excluding: String? = nil,
                              everywhere: Bool, limit: Int = 30) -> [DocRecord] {
        let q = normalized(query)
        let pool = docs.filter { doc in
            !doc.archived && doc.id != excluding && (everywhere || doc.channelId == sourceChannelId)
                && (q.isEmpty || doc.title.lowercased().contains(q))
        }
        let ranked = pool.sorted { a, b in
            let aLocal = a.channelId == sourceChannelId, bLocal = b.channelId == sourceChannelId
            if aLocal != bLocal { return aLocal }
            let aExact = normalized(a.title) == q, bExact = normalized(b.title) == q
            if aExact != bExact { return aExact }
            if a.title.localizedCaseInsensitiveCompare(b.title) != .orderedSame { return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
            return a.id < b.id
        }
        return Array(ranked.prefix(limit))
    }

    // MARK: Backlinks

    /// The documents whose saved text links to `target`: by id wherever the source lives, and by title only when the title
    /// is unique among readable pages (a shared title is never guessed). `examined` counts the sources whose text is
    /// saved on this device; the rest could not be checked here, which the screen says.
    public struct Backlinks: Sendable, Equatable {
        public var sources: [DocRecord]
        public var examined: Int
        public var total: Int
        public var isComplete: Bool { examined >= total }
    }

    public static func backlinks(to target: DocRecord, docs: [DocRecord], bodies: [String: DocumentBody]) -> Backlinks {
        let others = docs.filter { !$0.archived && $0.id != target.id }
        // Title-only references resolve inside their own channel (as the web does), so they count only for sources in the
        // target's channel and only while the title is unique among that channel's pages. Bound ids count from anywhere.
        let titleIsUnique = docs.filter { !$0.archived && $0.channelId == target.channelId && normalized($0.title) == normalized(target.title) }.count == 1
        var found: [DocRecord] = []
        var examined = 0
        for doc in others {
            guard let body = bodies[doc.id] else { continue }
            examined += 1
            let sameChannel = doc.channelId == target.channelId
            let refs = references(in: body)
            if refs.contains(where: { $0.documentId == target.id
                || ($0.documentId == nil && sameChannel && titleIsUnique && normalized($0.title) == normalized(target.title)) }) {
                found.append(doc)
            }
        }
        found.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return Backlinks(sources: found, examined: examined, total: others.count)
    }

    /// Every wiki reference in a body: rich nodes, canonical Markdown links and literal `[[Title]]`, never from code.
    public static func references(in body: DocumentBody) -> [WikiTarget] {
        var out: [WikiTarget] = []
        func collect(_ blocks: [RenderBlock]) {
            func runs(_ list: [InlineRun]) { for run in list { if let wiki = run.wiki { out.append(wiki) } } }
            for block in blocks {
                switch block {
                case .heading(_, let r), .paragraph(let r): runs(r)
                case .quote(let inner): collect(inner)
                case .list(_, _, let items): for item in items { collect(item.blocks) }
                case .table(let rows): for row in rows { for cell in row { runs(cell) } }
                default: break
                }
            }
        }
        collect(DocumentRender.blocks(body))
        return out
    }

    // MARK: Binding a created page into its source

    /// Binds unresolved references titled `title` in a rich document to `documentId`. Nothing else changes; code, bound
    /// links and other titles are left untouched. `occurrence` limits the change to the Nth matching reference in document
    /// order (the one that was opened); nil binds every match. Returns nil when nothing needed binding.
    public static func binding(_ title: String, to documentId: String, inEditorState state: JSONValue, occurrence: Int? = nil) -> JSONValue? {
        let wanted = normalized(title)
        var changed = false
        var seen = 0
        func wants() -> Bool { defer { seen += 1 }; return occurrence == nil || occurrence == seen }
        let plainMarks: Set<String> = ["bold", "italic", "strike", "underline"]
        /// A text node holding literal `[[Title]]` becomes text, a bound node, text; its marks carry onto the text parts.
        func expand(_ node: JSONValue) -> [JSONValue] {
            guard node["type"]?.stringValue == "text", let text = node["text"]?.stringValue, text.contains("[["),
                  (node["marks"]?.arrayValue ?? []).allSatisfy({ plainMarks.contains($0["type"]?.stringValue ?? "") }) else { return [node] }
            let ns = text as NSString
            var parts: [JSONValue] = [], cursor = 0
            for range in literalRanges(in: text, mask: []) {
                let name = ns.substring(with: NSRange(location: range.location + 2, length: range.length - 4)).trimmingCharacters(in: .whitespaces)
                guard normalized(name) == wanted, wants() else { continue }
                if range.location > cursor { parts.append(node.setting("text", .string(ns.substring(with: NSRange(location: cursor, length: range.location - cursor))))) }
                parts.append(.object([("type", .string("fdWikiLink")), ("attrs", .object([("documentId", .string(documentId)), ("title", .string(name))]))]))
                cursor = range.location + range.length
                changed = true
            }
            guard cursor > 0 else { return [node] }
            if cursor < ns.length { parts.append(node.setting("text", .string(ns.substring(from: cursor)))) }
            return parts
        }
        func visit(_ node: JSONValue, inCode: Bool) -> JSONValue {
            let type = node["type"]?.stringValue
            if type == "fdWikiLink", node["attrs"]?["documentId"]?.stringValue?.isEmpty != false, normalized(node["attrs"]?["title"]?.stringValue ?? "") == wanted {
                guard wants() else { return node }
                changed = true
                return node.setting("attrs", (node["attrs"] ?? .object([])).setting("documentId", .string(documentId)))
            }
            guard let content = node["content"]?.arrayValue else { return node }
            let code = inCode || type == "codeBlock"
            let next = code ? content : content.flatMap { child in expand(visit(child, inCode: code)) }
            return next == content ? node : node.setting("content", .array(next))
        }
        let result = visit(state, inCode: false)
        return changed ? result : nil
    }

    /// Markdown equivalent: `[[Title]]` outside code becomes `[Title](wiki:<id>)`; bound links stay as they are. `occurrence`
    /// as for rich documents.
    public static func binding(_ title: String, to documentId: String, inMarkdown text: String, occurrence: Int? = nil) -> String? {
        let wanted = normalized(title)
        let ns = text as NSString
        var out = "", cursor = 0, seen = 0
        for range in literalRanges(in: text, mask: markdownCodeRanges(text)) {
            let name = ns.substring(with: NSRange(location: range.location + 2, length: range.length - 4)).trimmingCharacters(in: .whitespaces)
            guard normalized(name) == wanted else { continue }
            defer { seen += 1 }
            guard occurrence == nil || occurrence == seen else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            out += ProseMirrorMarkdown.wikiSource(.object([("title", .string(name)), ("documentId", .string(documentId))]))
            cursor = range.location + range.length
        }
        guard cursor > 0 else { return nil }
        return out + ns.substring(from: cursor)
    }

    /// `[[Title]]` ranges outside `mask`, skipping an escaped `\[[` and a match that is itself link text (`[[X]](…)`).
    static func literalRanges(in text: String, mask: [NSRange]) -> [NSRange] {
        let ns = text as NSString
        return literal.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range).filter { range in
            if mask.contains(where: { NSIntersectionRange($0, range).length > 0 }) { return false }
            if range.location > 0, ns.character(at: range.location - 1) == 0x5C { return false }
            let end = range.location + range.length
            if end + 1 < ns.length, ns.substring(with: NSRange(location: end, length: 2)) == "](" { return false }
            return true
        }
    }

    /// Where Markdown treats text as code: fenced blocks (any fence length, backtick or tilde, closed only by a fence at
    /// least as long and of the same kind, or the end of the text), lines indented four columns or more, and inline code
    /// spans (a backtick run closed by a run of the same length). Indented lines are skipped even inside list continuations,
    /// which errs on the safe side: such a reference stays literal rather than risk rewriting code.
    static func markdownCodeRanges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var inlineSpans: [(start: Int, end: Int)] = []   // regions scanned for inline code
        var fence: (char: unichar, length: Int, start: Int)?
        var location = 0
        while location <= ns.length {
            var lineEnd = ns.length
            let search = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location))
            if search.location != NSNotFound { lineEnd = search.location }
            let line = ns.substring(with: NSRange(location: location, length: lineEnd - location))
            let next = min(lineEnd + 1, ns.length + 1)
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            if let open = fence {
                let run = body.prefix { $0 == Character(UnicodeScalar(open.char)!) }.count
                if indent <= 3, run >= open.length, body.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    ranges.append(NSRange(location: open.start, length: min(next, ns.length) - open.start))
                    fence = nil
                }
            } else if indent <= 3, let first = body.first, first == "`" || first == "~" {
                let run = body.prefix { $0 == first }.count
                let info = body.dropFirst(run)
                if run >= 3, first == "~" || !info.contains("`") {
                    fence = (first.asciiValue.map { unichar($0) } ?? 0, run, location)
                } else { inlineSpans.append((location, lineEnd)) }
            } else if indent >= 4 || line.hasPrefix("\t") {
                ranges.append(NSRange(location: location, length: lineEnd - location))
            } else {
                inlineSpans.append((location, lineEnd))
            }
            if lineEnd >= ns.length { break }
            location = next
        }
        if let open = fence { ranges.append(NSRange(location: open.start, length: ns.length - open.start)) }
        // Inline code spans may continue across lines of one paragraph, so scan each run of consecutive prose lines together.
        var merged: [(start: Int, end: Int)] = []
        for span in inlineSpans {
            if let last = merged.last, last.end + 1 == span.start { merged[merged.count - 1].end = span.end } else { merged.append(span) }
        }
        for region in merged {
            var i = region.start
            while i < region.end {
                guard ns.character(at: i) == 0x60 else { i += 1; continue }
                if i > region.start, ns.character(at: i - 1) == 0x5C { i += 1; continue }
                var run = 0
                while i + run < region.end, ns.character(at: i + run) == 0x60 { run += 1 }
                var j = i + run, close: Int?
                while j < region.end {
                    guard ns.character(at: j) == 0x60 else { j += 1; continue }
                    var n = 0
                    while j + n < region.end, ns.character(at: j + n) == 0x60 { n += 1 }
                    if n == run { close = j + n; break }
                    j += n
                }
                if let close { ranges.append(NSRange(location: i, length: close - i)); i = close } else { i += run }
            }
        }
        return ranges
    }
}
