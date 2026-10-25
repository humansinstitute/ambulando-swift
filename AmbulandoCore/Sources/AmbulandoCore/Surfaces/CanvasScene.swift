import Foundation

// Parsed, display-ready forms of a stored canvas snapshot and of an Excalidraw board scene. Both are pure value types
// built from stored bytes on a background executor (the store reader or a LiveQuery load), never on the main actor, and
// never written back: rendering a board does not mutate it.

/// Naplet or element bounds in canvas world coordinates, exactly as saved (`normalizeFlightDeckPgCanvasLayout`).
public struct CanvasLayout: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public var z: Int
    public init(x: Double, y: Double, width: Double, height: Double, z: Int) { self.x = x; self.y = y; self.width = width; self.height = height; self.z = z }

    init(_ value: Any?, minimum: (Double, Double) = (8, 8)) {
        let o = value as? [String: Any] ?? [:]
        func n(_ key: String, _ fallback: Double) -> Double {
            if let v = o[key] as? NSNumber, v.doubleValue.isFinite { return v.doubleValue }
            return fallback
        }
        x = n("x", 0); y = n("y", 0)
        width = max(minimum.0, n("width", 360)); height = max(minimum.1, n("height", 280))
        z = (o["z"] as? NSNumber)?.intValue ?? 1
    }
}

/// Reference to an Excalidraw board's current version, as projected by Tower for a ready naplet.
public struct BoardReference: Sendable, Equatable, Hashable {
    public let fileId: String
    public let versionId: String
    public let versionNumber: Int
    public let sha256: String
    public let sizeBytes: Int
    public let updatedAt: String?
}

public struct CanvasNaplet: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        /// A document: its title and a short plain-text excerpt of the body Tower included.
        case document(docId: String, excerpt: String)
        case taskList(channelId: String, tasks: [TaskSummary])
        case taskTree(channelId: String, channelTitle: String?)
        case chatThread(threadId: String, messages: [MessageSummary])
        /// An HTML artefact: web content, opened in a labelled view.
        case html(fileId: String, versionId: String?)
        case excalidraw(BoardReference)
        case canvas(canvasId: String)
        /// A source type this build does not know; shown, not dropped.
        case unknown(type: String)
        /// Tower did not authorize the source for this viewer (or it no longer exists); only the frame is shown.
        case denied
    }

    public struct TaskSummary: Sendable, Equatable, Identifiable {
        public let id: String, title: String, state: String
    }

    public struct MessageSummary: Sendable, Equatable, Identifiable {
        public let id: String, author: String, body: String, createdAt: String
    }

    public let id: String
    public let layout: CanvasLayout
    public let title: String
    public let sourceType: String
    public let content: Content
    public let rowVersion: Int
    /// The saved layout object as Tower sent it (JSON), including keys this build does not draw (such as `task_tree`). A
    /// move or resize patches it, so those keys are kept, as sol merges `{ ...naplet.layout, ...change }`.
    public let savedLayout: Data

    public var isReady: Bool { if case .denied = content { false } else { true } }
}

/// Native Canvas drawing elements (`flightdeck_pg_canvas_elements`): text, rectangle, diamond, ellipse, arrow, line, draw, frame.
public struct CanvasElement: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case text, rectangle, diamond, ellipse, arrow, line, draw, frame }
    public let id: String
    public let kind: Kind?
    public let kindName: String
    public let layout: CanvasLayout
    public let text: String?
    public let fontSize: Double
    /// Arrow/line endpoints and optional quadratic control point, relative to the layout origin (sol `arrowPoints`).
    public let start: [Double]
    public let end: [Double]
    public let curve: [Double]?
    public let lineStyle: String
    public let startArrowhead: String
    public let endArrowhead: String
    /// Freehand points relative to the layout origin.
    public let points: [[Double]]
    /// A frame used only to group items (`data.role == "group"`) has no visible outline.
    public let isGroup: Bool
}

public struct CanvasScene: Sendable, Equatable {
    public var naplets: [CanvasNaplet] = []
    public var elements: [CanvasElement] = []
    /// Elements of kinds this build does not draw (listed on the board).
    public var unsupportedElements: [String: Int] = [:]
    public init() {}

    /// World-space bounds of everything on the board.
    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        let layouts = naplets.map(\.layout) + elements.map(\.layout)
        guard let first = layouts.first else { return nil }
        return layouts.dropFirst().reduce((first.x, first.y, first.x + first.width, first.y + first.height)) { r, l in
            (min(r.0, l.x), min(r.1, l.y), max(r.2, l.x + l.width), max(r.3, l.y + l.height))
        }
    }

    /// Every board reference on the canvas (for fetching their scenes).
    public var boards: [BoardReference] {
        naplets.compactMap { if case .excalidraw(let ref) = $0.content { ref } else { nil } }
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case invalid, tooLarge(String)
        public var errorDescription: String? {
            switch self {
            case .invalid: "This canvas could not be read."
            case .tooLarge(let what): "This canvas is too large to show on iPhone (\(what))."
            }
        }
    }

    /// Client-side bounds for one stored snapshot. Tower sets no explicit limit; these keep parsing and drawing bounded,
    /// and a snapshot beyond them is refused with a visible error instead of being shown partly.
    public static let maxBytes = 32 * 1024 * 1024
    public static let maxNaplets = 2_000
    public static let maxElements = 20_000

    /// Parses on the caller's (background) executor and stops with `CancellationError` when its task is cancelled.
    public static func parse(_ bytes: Data) throws -> CanvasScene {
        guard bytes.count <= maxBytes else { throw ParseError.tooLarge("more than 32 MB") }
        guard let o = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let napletRows = o["naplets"] as? [[String: Any]], let elementRows = o["elements"] as? [[String: Any]] else { throw ParseError.invalid }
        guard napletRows.count <= maxNaplets else { throw ParseError.tooLarge("more than \(maxNaplets) items") }
        guard elementRows.count <= maxElements else { throw ParseError.tooLarge("more than \(maxElements) drawing elements") }
        var scene = CanvasScene()
        for (index, row) in napletRows.enumerated() {
            if index % 128 == 0 { try Task.checkCancellation() }
            if let n = naplet(row) { scene.naplets.append(n) }
        }
        for (index, row) in elementRows.enumerated() {
            if index % 512 == 0 { try Task.checkCancellation() }
            guard let e = element(row) else { continue }
            if e.kind == nil { scene.unsupportedElements[e.kindName, default: 0] += 1 } else { scene.elements.append(e) }
        }
        // Tower orders by z then creation; keep that order for equal z.
        scene.naplets = scene.naplets.enumerated().sorted { ($0.element.layout.z, $0.offset) < ($1.element.layout.z, $1.offset) }.map(\.element)
        scene.elements = scene.elements.enumerated().sorted { ($0.element.layout.z, $0.offset) < ($1.element.layout.z, $1.offset) }.map(\.element)
        return scene
    }

    static func naplet(_ row: [String: Any]) -> CanvasNaplet? {
        guard let id = lowerUUID(row["id"] as? String) else { return nil }
        let layout = CanvasLayout(row["layout"], minimum: (220, 160))
        let version = flexibleInt(row["row_version"]) ?? 0
        let saved = (row["layout"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data("{}".utf8)
        guard row["access"] as? String == "ready", let source = row["source"] as? [String: Any], let type = source["type"] as? String else {
            return CanvasNaplet(id: id, layout: layout, title: "Not available to you", sourceType: "", content: .denied, rowVersion: version, savedLayout: saved)
        }
        let sourceId = lowerUUID(source["id"] as? String)
        let content = row["content"] as? [String: Any] ?? [:]
        let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let parsed: CanvasNaplet.Content
        switch type {
        case "document":
            guard let sourceId else { return nil }
            let body = (content["body"] as? String) ?? ""
            parsed = .document(docId: sourceId, excerpt: excerpt(body))
        case "task_list":
            guard let sourceId else { return nil }
            let tasks = ((content["tasks"] as? [[String: Any]]) ?? []).prefix(200).compactMap { t -> CanvasNaplet.TaskSummary? in
                guard let tid = lowerUUID(t["id"] as? String) else { return nil }
                return .init(id: tid, title: (t["title"] as? String) ?? "Untitled task", state: (t["state"] as? String) ?? "new")
            }
            parsed = .taskList(channelId: sourceId, tasks: Array(tasks))
        case "task_tree":
            guard let channel = lowerUUID(content["channel_id"] as? String) ?? sourceId else { return nil }
            parsed = .taskTree(channelId: channel, channelTitle: content["channel_title"] as? String)
        case "chat_thread":
            guard let sourceId else { return nil }
            let messages = ((content["messages"] as? [[String: Any]]) ?? []).suffix(50).compactMap { m -> CanvasNaplet.MessageSummary? in
                guard let mid = lowerUUID(m["id"] as? String) else { return nil }
                return .init(id: mid, author: (m["author"] as? String) ?? "", body: excerpt((m["body"] as? String) ?? "", limit: 400),
                             createdAt: (m["created_at"] as? String) ?? "")
            }
            parsed = .chatThread(threadId: sourceId, messages: Array(messages))
        case "html":
            guard let sourceId else { return nil }
            parsed = .html(fileId: sourceId, versionId: lowerUUID(source["version_id"] as? String))
        case "excalidraw":
            guard let file = lowerUUID(content["file_id"] as? String) ?? sourceId, let versionId = lowerUUID(content["current_version_id"] as? String),
                  let sha = (content["sha256"] as? String)?.lowercased(), sha.count == 64 else {
                return CanvasNaplet(id: id, layout: layout, title: title, sourceType: type, content: .unknown(type: "excalidraw (incomplete metadata)"), rowVersion: version, savedLayout: saved)
            }
            parsed = .excalidraw(BoardReference(fileId: file, versionId: versionId, versionNumber: flexibleInt(content["current_version_number"]) ?? 0,
                                                sha256: sha, sizeBytes: flexibleInt(content["size_bytes"]) ?? 0, updatedAt: content["updated_at"] as? String))
        case "canvas":
            guard let sourceId else { return nil }
            parsed = .canvas(canvasId: sourceId)
        default:
            parsed = .unknown(type: type)
        }
        return CanvasNaplet(id: id, layout: layout, title: title, sourceType: type, content: parsed, rowVersion: version, savedLayout: saved)
    }

    static func element(_ row: [String: Any]) -> CanvasElement? {
        guard let id = (row["id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        let kindName = (row["kind"] as? String) ?? ""
        let kind = CanvasElement.Kind(rawValue: kindName)
        let layout = CanvasLayout(row["layout"])
        let d = row["data"] as? [String: Any] ?? [:]
        func pair(_ value: Any?) -> [Double]? {
            guard let a = value as? [Any], a.count == 2, let x = (a[0] as? NSNumber)?.doubleValue, let y = (a[1] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite else { return nil }
            return [x, y]
        }
        let size = (d["fontSize"] as? NSNumber)?.doubleValue ?? 16
        let points = ((d["points"] as? [Any]) ?? []).prefix(5000).compactMap(pair)
        return CanvasElement(id: id, kind: kind, kindName: kindName, layout: layout, text: d["text"] as? String,
                             fontSize: (12...144).contains(size) ? size : 16,
                             start: pair(d["start"]) ?? [0, layout.height], end: pair(d["end"]) ?? [layout.width, 0], curve: pair(d["curve"]),
                             lineStyle: (d["lineStyle"] as? String) ?? "solid",
                             startArrowhead: (d["startArrowhead"] as? String) ?? "none",
                             endArrowhead: (d["endArrowhead"] as? String) ?? (kind == .arrow ? "triangle" : "none"),
                             points: points, isGroup: kind == .frame && d["role"] as? String == "group")
    }

    /// Short plain text from a body that may be Markdown or a stored document envelope.
    static func excerpt(_ body: String, limit: Int = 600) -> String {
        // Stored envelopes and content models are recognised first; anything else is Markdown text.
        let text = DocumentBody(bytes: Data(body.prefix(64 * 1024).utf8), contentType: "text/markdown").markdown
        let collapsed = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}

// MARK: Excalidraw

/// The supported native subset of a standard `.excalidraw` scene (sol `board-scene.js` canonical form).
///
/// Drawn: rectangle, ellipse, diamond, line, arrow (with arrowheads), freedraw, text (including text bound to a
/// container), embedded raster images (PNG, JPEG, GIF, WebP, AVIF data URLs) and frames (outline and name).
/// Approximated, and stated on the board: hand-drawn roughness (clean strokes), hachure/cross-hatch fills (a light tint
/// of the fill colour), fonts (system fonts) and frame clipping (not applied).
/// Not drawn and listed with counts: embeddable, iframe, magicframe, SVG images, images whose file is missing, and any
/// other type. Deleted elements (`isDeleted`) are skipped as Excalidraw does.
public struct ExcalidrawScene: Sendable, Equatable {
    public enum Kind: String, Sendable { case rectangle, ellipse, diamond, line, arrow, freedraw, text, image, frame }

    public struct Element: Sendable, Equatable, Identifiable {
        public let id: String
        public let kind: Kind
        public let x: Double, y: Double, width: Double, height: Double
        /// Rotation in radians around the element centre.
        public let angle: Double
        public let strokeColor: String
        public let backgroundColor: String
        public let fillStyle: String
        public let strokeWidth: Double
        public let strokeStyle: String
        /// 0…1.
        public let opacity: Double
        public let rounded: Bool
        /// Line/arrow/freedraw points relative to (x, y).
        public let points: [[Double]]
        public let startArrowhead: String?
        public let endArrowhead: String?
        public let text: String?
        public let fontSize: Double
        public let textAlign: String
        public let verticalAlign: String
        public let fileId: String?
        public let name: String?
    }

    public struct Image: Sendable, Equatable {
        public let mimeType: String
        public let data: Data
    }

    public var elements: [Element] = []
    /// Element types that are not drawn, with counts (shown on the board, never silently dropped).
    public var unsupported: [String: Int] = [:]
    public var deletedCount = 0
    public var images: [String: Image] = [:]
    public var viewBackgroundColor: String?
    /// Approximations used for this particular scene.
    public var approximations: [String] = []
    public var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0

    public init() {}

    public enum ParseError: Error, Equatable { case invalid(String), tooLarge }

    /// Same limits as sol `BOARD_LIMITS`: scene bytes, elements, embedded images and bytes per image.
    public static let maxBytes = 24 * 1024 * 1024
    public static let maxElements = 20_000
    public static let maxImages = 200
    public static let maxImageBytes = 6 * 1024 * 1024
    static let rasterTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]

    /// Parses on the caller's executor (never the main actor) and stops with `CancellationError` when its task is
    /// cancelled, for example when the board is closed while a large scene is still being read.
    public static func parse(_ bytes: Data) throws -> ExcalidrawScene {
        guard bytes.count <= maxBytes else { throw ParseError.tooLarge }
        guard var o = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { throw ParseError.invalid("Board is not valid JSON") }
        if let wrapped = o["scene"] as? [String: Any], wrapped["elements"] is [Any] { o = wrapped }
        if let type = o["type"] as? String, type != "excalidraw" { throw ParseError.invalid("Board scene type must be \"excalidraw\"") }
        guard let rows = o["elements"] as? [Any] else { throw ParseError.invalid("Board scene must contain an elements array") }
        guard rows.count <= maxElements else { throw ParseError.tooLarge }
        var scene = ExcalidrawScene()
        scene.viewBackgroundColor = (o["appState"] as? [String: Any])?["viewBackgroundColor"] as? String
        let files = o["files"] as? [String: Any] ?? [:]
        var notes = Set<String>()
        var first = true
        for (index, value) in rows.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard let e = value as? [String: Any], let id = e["id"] as? String, !id.isEmpty, let typeName = e["type"] as? String else {
                scene.unsupported["malformed", default: 0] += 1; continue
            }
            if e["isDeleted"] as? Bool == true { scene.deletedCount += 1; continue }
            guard let kind = Kind(rawValue: typeName) else { scene.unsupported[typeName, default: 0] += 1; continue }
            func n(_ k: String, _ f: Double = 0) -> Double { ((e[k] as? NSNumber)?.doubleValue).flatMap { $0.isFinite ? $0 : nil } ?? f }
            var fileId: String?
            if kind == .image {
                guard let fid = e["fileId"] as? String, let file = files[fid] as? [String: Any] else { scene.unsupported["image (file missing)", default: 0] += 1; continue }
                let mime = ((file["mimeType"] as? String) ?? "").lowercased()
                guard rasterTypes.contains(mime) else { scene.unsupported["image (\(mime.isEmpty ? "unknown type" : mime))", default: 0] += 1; continue }
                if scene.images[fid] == nil {
                    guard scene.images.count < maxImages else { scene.unsupported["image (over \(maxImages) images)", default: 0] += 1; continue }
                    guard let url = file["dataURL"] as? String, let comma = url.firstIndex(of: ","), url[..<comma].lowercased().hasPrefix("data:\(mime)"),
                          url[..<comma].lowercased().hasSuffix(";base64"), let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else {
                        scene.unsupported["image (unreadable data)", default: 0] += 1; continue
                    }
                    guard data.count <= maxImageBytes else { scene.unsupported["image (larger than 6 MB)", default: 0] += 1; continue }
                    scene.images[fid] = Image(mimeType: mime, data: data)
                }
                fileId = fid
            }
            let points = ((e["points"] as? [Any]) ?? []).prefix(20_000).compactMap { p -> [Double]? in
                guard let a = p as? [Any], a.count >= 2, let x = (a[0] as? NSNumber)?.doubleValue, let y = (a[1] as? NSNumber)?.doubleValue, x.isFinite, y.isFinite else { return nil }
                return [x, y]
            }
            let roughness = n("roughness", 1)
            let fill = (e["fillStyle"] as? String) ?? "solid"
            let background = (e["backgroundColor"] as? String) ?? "transparent"
            if roughness > 0, kind != .text, kind != .image { notes.insert("Hand-drawn strokes are drawn as clean lines.") }
            if ["hachure", "cross-hatch", "zigzag"].contains(fill), background != "transparent" { notes.insert("Hatched fills are shown as a light tint.") }
            if kind == .text { notes.insert("Text uses system fonts.") }
            if kind == .frame { notes.insert("Frames are outlined; their contents are not clipped.") }
            let element = Element(id: id, kind: kind, x: n("x"), y: n("y"), width: n("width"), height: n("height"), angle: n("angle"),
                                  strokeColor: (e["strokeColor"] as? String) ?? "#1e1e1e", backgroundColor: background, fillStyle: fill,
                                  strokeWidth: max(0.5, n("strokeWidth", 2)), strokeStyle: (e["strokeStyle"] as? String) ?? "solid",
                                  opacity: min(1, max(0, n("opacity", 100) / 100)), rounded: !(e["roundness"] is NSNull || e["roundness"] == nil),
                                  points: points, startArrowhead: e["startArrowhead"] as? String, endArrowhead: e["endArrowhead"] as? String,
                                  text: e["text"] as? String, fontSize: max(4, n("fontSize", 20)), textAlign: (e["textAlign"] as? String) ?? "left",
                                  verticalAlign: (e["verticalAlign"] as? String) ?? "top", fileId: fileId, name: e["name"] as? String)
            scene.elements.append(element)
            // Bounds include line points, which may extend beyond width/height.
            var xs = [element.x, element.x + element.width], ys = [element.y, element.y + element.height]
            for p in points { xs.append(element.x + p[0]); ys.append(element.y + p[1]) }
            let lo = (xs.min()!, ys.min()!), hi = (xs.max()!, ys.max()!)
            if first { scene.minX = lo.0; scene.minY = lo.1; scene.maxX = hi.0; scene.maxY = hi.1; first = false }
            else { scene.minX = min(scene.minX, lo.0); scene.minY = min(scene.minY, lo.1); scene.maxX = max(scene.maxX, hi.0); scene.maxY = max(scene.maxY, hi.1) }
        }
        scene.approximations = notes.sorted()
        return scene
    }

    /// One readable line per unsupported type, for the board's notice.
    public var unsupportedSummary: [String] {
        unsupported.sorted { $0.key < $1.key }.map { "\($0.value) × \($0.key)" }
    }
}
