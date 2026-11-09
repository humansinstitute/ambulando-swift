import Foundation

/// Escaped, read-only semantic HTML for one continuous chat selection. No source HTML is trusted.
public enum ChatSelectionHTML {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    public static func blocks(_ blocks: [RenderBlock]) -> String { blocks.map(block).joined() }
    private static func block(_ value: RenderBlock) -> String {
        switch value {
        case .heading(let level, let r): let n = min(6, max(1, level)); return "<h\(n)>\(runs(r))</h\(n)>"
        case .paragraph(let r): return "<p>\(runs(r))</p>"
        case .code(let language, let text):
            return "<section class=code><div class=code-toolbar data-no-copy><span>\(escape(language.isEmpty ? "code" : language))</span><button type=button aria-label=\"Copy code\">Copy</button></div><pre><code>\(escape(text))</code></pre></section>"
        case .quote(let inner): return "<blockquote>\(blocks(inner))</blockquote>"
        case .list(let ordered, let start, let items):
            let tag = ordered ? "ol" : "ul"
            return "<\(tag) start=\"\(start)\">" + items.map { item in
                let check = item.checked.map { "<span role=img aria-label=\"\($0 ? "Done" : "Not done")\">\($0 ? "☑" : "☐") </span>" } ?? ""
                return "<li>\(check)\(blocks(item.blocks))</li>"
            }.joined() + "</\(tag)>"
        case .table(let rows):
            return "<div class=table-scroll tabindex=0 aria-label=\"Table, scroll horizontally for more columns\"><table>" + rows.enumerated().map { index, cells in
                let tag = index == 0 ? "th" : "td"
                return "<tr>" + cells.map { "<\(tag)\(index == 0 ? " scope=col" : "")>\(runs($0))</\(tag)>" }.joined() + "</tr>"
            }.joined() + "</table></div>"
        case .image(let alt, let source): return image(alt: alt, source: source)
        case .rule: return "<hr>"
        case .preserved(let type, let text): return "<p>\(escape(type)): \(escape(text))</p>"
        }
    }
    public static func runs(_ values: [InlineRun]) -> String {
        values.map { run in
            if let source = run.image { return image(alt: run.text, source: source) }
            var text = escape(run.text).replacingOccurrences(of: "\n", with: "<br>")
            if run.code { text = "<code>\(text)</code>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            if run.italic { text = "<em>\(text)</em>" }
            if run.strike { text = "<s>\(text)</s>" }
            if run.underline { text = "<u>\(text)</u>" }
            var href = run.link.flatMap(safeLink)
            if let kind = run.mentionKind, let id = run.mentionId {
                var c = URLComponents(); c.scheme = "ambulando-mention"; c.host = "open"
                c.queryItems = [.init(name: "kind", value: kind), .init(name: "id", value: id)]
                href = c.url?.absoluteString
            }
            if let wiki = run.wiki {
                var c = URLComponents(); c.scheme = "ambulando-wiki"; c.host = "open"
                c.queryItems = [.init(name: "id", value: wiki.documentId), .init(name: "title", value: wiki.title), .init(name: "n", value: String(wiki.occurrence)), .init(name: "count", value: String(wiki.count))]
                href = c.url?.absoluteString
            }
            if run.mention { text = "<mark>\(text)</mark>" }
            if let href { text = "<a href=\"\(escape(href))\">\(text)</a>" }
            return text
        }.joined()
    }
    private static func safeLink(_ text: String) -> String? {
        guard let u = URL(string: text), ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") || (u.scheme == nil && u.host == nil && u.path == "/canvas.html") else { return nil }
        return text
    }
    private static func image(alt: String, source: String) -> String {
        if source.lowercased().hasPrefix("storage://"), let id = UUID(uuidString: String(source.dropFirst(10))) {
            return "<a class=stored-image href=\"ambulando-image://\(id.uuidString.lowercased())\"><img data-object=\"\(id.uuidString.lowercased())\" alt=\"\(escape(alt))\"><span data-no-copy>Loading image…</span></a>"
        }
        guard let href = safeLink(source) else { return "<p>Image: \(escape(alt))</p>" }
        return "<a href=\"\(escape(href))\">\(escape(alt.isEmpty ? "Web image (not loaded)" : alt + " — web image (not loaded)"))</a>"
    }
}
