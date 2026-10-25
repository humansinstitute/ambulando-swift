import Foundation

/// Canonical Excalidraw board scenes, as sol `canvas/board-scene.js` and `canvas/board-comments.js` define them. A board
/// is a Tower File whose immutable versions hold this JSON. The working scene keeps every element verbatim (unknown
/// fields included, `isDeleted` tombstones, `version`/`versionNonce`), embedded image files by id and the board's
/// discussion (`wingman.comments`), so a save from this device never drops what another client wrote.
///
/// Scenes are plain JSON objects (`[String: Any]`). They are parsed and handled off the main actor only (inside
/// `BoardController`), and cross actor boundaries as encoded bytes.
public enum BoardScene {
    public typealias Object = [String: Any]

    public static let contentType = "application/vnd.excalidraw+json"
    public static let fileExtension = ".excalidraw"
    public static let source = "wingman-ambulando"
    public static let maxBytes = 24 * 1024 * 1024
    public static let maxElements = 20_000
    public static let maxFiles = 200
    public static let maxFileBytes = 6 * 1024 * 1024
    public static let maxSummary = 280
    public static let maxTitle = 200
    public static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/svg+xml"]
    /// Board-level appState that belongs to the drawing; values equal to Excalidraw's defaults are omitted.
    static var appStateDefaults: [(String, Any)] { [("viewBackgroundColor", "#ffffff"), ("gridSize", 20), ("gridStep", 5), ("gridModeEnabled", false)] }

    public enum SceneError: LocalizedError, Equatable {
        case invalid(String), tooLarge(String)
        public var errorDescription: String? {
            switch self {
            case .invalid(let detail): "This board could not be read (\(detail))."
            case .tooLarge(let detail): detail
            }
        }
    }

    public static func empty() -> Object { ["type": "excalidraw", "version": 2, "source": source, "elements": [Any](), "appState": Object(), "files": Object()] }

    // MARK: Parse and normalise

    public static func parse(_ bytes: Data) throws -> Object {
        guard bytes.count <= maxBytes else { throw SceneError.tooLarge("This board is larger than the 24 MB limit.") }
        guard let value = try? JSONSerialization.jsonObject(with: bytes) else { throw SceneError.invalid("not JSON") }
        return try normalize(value)
    }

    /// Accepts a standard `.excalidraw` document, a bare `{elements, files}` scene or the `{scene: {...}}` wrapper.
    public static func normalize(_ input: Any) throws -> Object {
        guard var value = input as? Object else { throw SceneError.invalid("not an object") }
        if let inner = value["scene"] as? Object, inner["elements"] is [Any] {
            var merged = inner
            merged["wingman"] = value["wingman"] ?? inner["wingman"]
            value = merged
        }
        guard let rawElements = value["elements"] as? [Any] else { throw SceneError.invalid("no elements array") }
        if let type = value["type"], type as? String != "excalidraw" { throw SceneError.invalid("type is not excalidraw") }
        guard rawElements.count <= maxElements else { throw SceneError.tooLarge("This board has too many elements.") }
        var seen = Set<String>()
        let elements = try rawElements.map { try validateElement($0, &seen) }
        let rawFiles = value["files"] as? Object ?? [:]
        guard rawFiles.count <= maxFiles else { throw SceneError.tooLarge("This board has too many images.") }
        var files = Object()
        for (id, file) in rawFiles { files[id] = try validateFile(id, file) }
        var scene: Object = ["type": "excalidraw", "version": 2, "source": text(value["source"]).isEmpty ? source : text(value["source"]),
                             "elements": elements, "appState": pickAppState(value["appState"]), "files": files]
        if let wingman = value["wingman"] as? Object {
            var metadata = try pickWingman(wingman)
            if let comments = metadata["comments"] as? [Object] { metadata["comments"] = followCommentAnchors(comments, elements) }
            scene["wingman"] = metadata
        }
        return scene
    }

    static func validateElement(_ value: Any, _ seen: inout Set<String>) throws -> Object {
        guard let element = value as? Object else { throw SceneError.invalid("element is not an object") }
        let id = text(element["id"])
        guard !id.isEmpty, id.count <= 128 else { throw SceneError.invalid("element id") }
        guard seen.insert(id).inserted else { throw SceneError.invalid("duplicate element \(id)") }
        guard !text(element["type"]).isEmpty else { throw SceneError.invalid("element \(id) has no type") }
        guard let version = safeInt(element["version"]), version >= 1 else { throw SceneError.invalid("element \(id) version") }
        _ = version
        if let nonce = element["versionNonce"], !(nonce is NSNull), safeInt(nonce) == nil { throw SceneError.invalid("element \(id) versionNonce") }
        if let deleted = element["isDeleted"], !isBool(deleted) { throw SceneError.invalid("element \(id) isDeleted") }
        return element   // every field verbatim: unknown Excalidraw fields survive a save
    }

    static func validateFile(_ id: String, _ value: Any) throws -> Object {
        guard var file = value as? Object else { throw SceneError.invalid("file \(id)") }
        if !text(file["id"]).isEmpty, text(file["id"]) != id { throw SceneError.invalid("file \(id) id mismatch") }
        let mime = text(file["mimeType"]).lowercased()
        guard imageTypes.contains(mime) else { throw SceneError.invalid("file \(id) type") }
        let dataURL = (file["dataURL"] as? String) ?? ""
        guard dataURL.lowercased().hasPrefix("data:\(mime)") else { throw SceneError.invalid("file \(id) is not an embedded \(mime)") }
        guard dataURL.utf8.count <= (maxFileBytes * 4 + 2) / 3 + 128 else { throw SceneError.tooLarge("An image on this board is too large.") }
        file["id"] = id; file["mimeType"] = mime; file["dataURL"] = dataURL
        return file
    }

    static func pickAppState(_ value: Any?) -> Object {
        guard let state = value as? Object else { return [:] }
        var out = Object()
        for (key, fallback) in appStateDefaults {
            guard let v = state[key], !(v is NSNull) else { continue }
            if !(v as AnyObject).isEqual(fallback) { out[key] = v }
        }
        return out
    }

    static func pickWingman(_ value: Object) throws -> Object {
        var out = Object()
        let summary = String(text(value["summary"]).prefix(maxSummary))
        if !summary.isEmpty { out["summary"] = summary }
        if !text(value["base_version_id"]).isEmpty { out["base_version_id"] = text(value["base_version_id"]) }
        if let comments = value["comments"] { out["comments"] = try normalizeComments(comments) }
        return out
    }

    // MARK: Serialise and compare

    /// Images referenced by any element, deleted ones included (needed to undelete or reconcile).
    static func referencedFileIds(_ elements: [Object]) -> Set<String> { Set(elements.map { text($0["fileId"]) }.filter { !$0.isEmpty }) }

    public static func elements(_ scene: Object) -> [Object] { scene["elements"] as? [Object] ?? [] }

    /// Canonical bytes of one immutable version. Unreferenced images are pruned; deleted elements and their images kept.
    public static func serialize(_ scene: Object, summary: String = "", baseVersionId: String = "") throws -> Data {
        let normalized = try normalize(scene)
        let elements = elements(normalized)
        let referenced = referencedFileIds(elements)
        let files = (normalized["files"] as? Object ?? [:]).filter { referenced.contains($0.key) }
        var wingman = Object()
        let trimmed = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxSummary))
        if !trimmed.isEmpty { wingman["summary"] = trimmed }
        if !baseVersionId.isEmpty { wingman["base_version_id"] = baseVersionId }
        if (normalized["wingman"] as? Object)?["comments"] != nil { wingman["comments"] = followCommentAnchors(comments(normalized), elements) }
        var document: Object = ["type": "excalidraw", "version": 2, "source": source, "elements": elements, "appState": normalized["appState"] ?? Object(), "files": files]
        if !wingman.isEmpty { document["wingman"] = wingman }
        let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= maxBytes else { throw SceneError.tooLarge("This board is larger than the 24 MB limit. Remove or shrink some images.") }
        return bytes
    }

    /// Change identity for dirty detection: element stamps, referenced images, board appState and discussion.
    /// Selection, zoom and scroll never change it.
    public static func fingerprint(_ scene: Object) -> String {
        let elements = elements(scene)
        let stamps = elements.map { "\(text($0["id"])):\(stamp($0)):\(($0["isDeleted"] as? Bool) == true ? 1 : 0)" }.sorted()
        let referenced = referencedFileIds(elements)
        let files = (scene["files"] as? Object ?? [:]).keys.filter { referenced.contains($0) }.sorted()
        let parts: [Any] = [stamps, files, pickAppState(scene["appState"]), comments(scene)]
        let data = (try? JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys])) ?? Data()
        return SHA256Hex.of(data)
    }

    static func stamp(_ element: Object?) -> String {
        guard let element else { return "" }
        return "\(safeInt(element["version"]) ?? 0):\(safeInt(element["versionNonce"]) ?? 0)"
    }

    /// Three-way rebase of a draft onto a newer saved version by element id (sol `rebaseBoardScene`). Elements the draft
    /// changed since `base` win; otherwise the newer version wins. Elements changed on both sides are counted as
    /// conflicts and resolved toward the draft, so no local edit is dropped.
    public static func rebase(base: Object, draft: Object, latest: Object) -> (scene: Object, conflicts: Int) {
        let before = index(elements(base)), mine = index(elements(draft)), theirs = index(elements(latest))
        var conflicts = 0
        var order = elements(latest).map { text($0["id"]) }
        for element in elements(draft) where theirs[text(element["id"])] == nil { order.append(text(element["id"])) }
        let merged: [Object] = order.compactMap { id in
            let b = before[id], m = mine[id], t = theirs[id]
            let mineChanged = m != nil && stamp(m) != stamp(b)
            let theirsChanged = t != nil && stamp(t) != stamp(b)
            if mineChanged && theirsChanged && stamp(m) != stamp(t) { conflicts += 1 }
            if mineChanged { return m }
            return t ?? m
        }
        let draftAppChanged = !NSDictionary(dictionary: pickAppState(draft["appState"])).isEqual(to: pickAppState(base["appState"]))
        let files = (latest["files"] as? Object ?? [:]).merging(draft["files"] as? Object ?? [:]) { _, d in d }
        let discussion = mergeComments(base: base, draft: draft, latest: latest)
        conflicts += discussion.conflicts
        let scene: Object = ["type": "excalidraw", "version": 2, "source": source, "elements": merged,
                             "appState": draftAppChanged ? pickAppState(draft["appState"]) : pickAppState(latest["appState"]), "files": files,
                             "wingman": ["comments": followCommentAnchors(discussion.comments, merged)]]
        return (scene, conflicts)
    }

    /// An older version as a draft on top of `latest` (sol `restoreBoardScene`): every element is re-stamped above the
    /// newest known version, and elements only in `latest` become tombstones. Later discussion is kept.
    public static func restore(target: Object, latest: Object) -> Object {
        let latestById = index(elements(latest))
        let targetIds = Set(elements(target).map { text($0["id"]) })
        let now = Int(Date().timeIntervalSince1970 * 1000)
        func restamp(_ element: Object, _ previous: Object?) -> Object {
            var out = element
            out["version"] = max(safeInt(element["version"]) ?? 1, safeInt(previous?["version"]) ?? 0) + 1
            out["versionNonce"] = Int.random(in: 0...Int(Int32.max))
            out["updated"] = now
            return out
        }
        var restored = elements(target).map { restamp($0, latestById[text($0["id"])]) }
        for element in elements(latest) where !targetIds.contains(text(element["id"])) {
            if (element["isDeleted"] as? Bool) == true { restored.append(element) } else { var t = restamp(element, element); t["isDeleted"] = true; restored.append(t) }
        }
        let discussion = mergeComments(base: [:], draft: latest, latest: target)
        let files = (latest["files"] as? Object ?? [:]).merging(target["files"] as? Object ?? [:]) { _, t in t }
        return ["type": "excalidraw", "version": 2, "source": source, "elements": restored, "appState": pickAppState(target["appState"]), "files": files,
                "wingman": ["comments": followCommentAnchors(discussion.comments, restored)]]
    }

    private static func index(_ elements: [Object]) -> [String: Object] {
        Dictionary(elements.map { (text($0["id"]), $0) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: Discussion (sol board-comments.js)

    public static let maxThreads = 1000, maxMessages = 2000, maxCommentBody = 12_000

    public static func comments(_ scene: Object) -> [Object] { (scene["wingman"] as? Object)?["comments"] as? [Object] ?? [] }

    public static func withComments(_ scene: Object, _ comments: [Object]) throws -> Object {
        var out = scene
        var wingman = scene["wingman"] as? Object ?? [:]
        wingman["comments"] = try normalizeComments(comments)
        out["wingman"] = wingman
        return out
    }

    static func commentId(_ value: Any?) -> Bool {
        guard let s = value as? String, (1...128).contains(s.count) else { return false }
        return s.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" || $0 == "-" }
    }

    static func finite(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        return d.isFinite && abs(d) < 1e9 ? d : nil
    }

    static func isNpub(_ value: Any?) -> Bool {
        guard let s = value as? String, s.hasPrefix("npub1"), (6...105).contains(s.count) else { return false }
        return s.dropFirst(5).allSatisfy { ($0.isLetter || $0.isNumber || $0 == "_") && $0.isASCII }
    }

    public static func normalizeComments(_ value: Any) throws -> [Object] {
        guard let threads = value as? [Any], threads.count <= maxThreads else { throw SceneError.invalid("comment threads") }
        var ids = Set<String>()
        return try threads.map { raw in
            guard let thread = raw as? Object, commentId(thread["id"]), let id = thread["id"] as? String, ids.insert(id).inserted else {
                throw SceneError.invalid("comment id")
            }
            guard let a = thread["anchor"] as? Object, let x = finite(a["x"]), let y = finite(a["y"]) else { throw SceneError.invalid("comment anchor") }
            var anchor: Object = ["x": x, "y": y]
            if let element = a["element_id"], !(element is NSNull) {
                guard commentId(element), let u = finite(a["u"]), let v = finite(a["v"]) else { throw SceneError.invalid("comment anchor") }
                anchor["element_id"] = element; anchor["u"] = u; anchor["v"] = v
            }
            guard let resolved = thread["resolved"], isBool(resolved), let messages = thread["messages"] as? [Any], !messages.isEmpty,
                  messages.count <= maxMessages else { throw SceneError.invalid("comment thread") }
            let normalized: [Object] = try messages.map { rawMessage in
                guard let m = rawMessage as? Object, commentId(m["id"]), let mid = m["id"] as? String, !ids.contains(mid),
                      let body = m["body"] as? String, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= maxCommentBody,
                      isNpub(m["author_npub"]), let created = m["created_at"] as? String, BoardScene.date(created) != nil
                else { throw SceneError.invalid("comment message") }
                ids.insert(mid)
                return ["id": mid, "body": body, "author_npub": m["author_npub"]!, "created_at": created]
            }
            return ["id": id, "anchor": anchor, "resolved": resolved, "messages": normalized]
        }
    }

    static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: value) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)
    }

    static func rotate(_ x: Double, _ y: Double, _ angle: Double) -> (Double, Double) {
        (x * cos(angle) - y * sin(angle), x * sin(angle) + y * cos(angle))
    }

    static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

    /// Pins follow their shape: fallback coordinates are updated even when the shape has just become a tombstone.
    static func followCommentAnchors(_ comments: [Object], _ elements: [Object]) -> [Object] {
        let byId = index(elements)
        return comments.map { thread in
            guard var anchor = thread["anchor"] as? Object, let element = byId[text(anchor["element_id"])] else { return thread }
            let (px, py) = rotate((num(anchor["u"]) - 0.5) * num(element["width"]), (num(anchor["v"]) - 0.5) * num(element["height"]), num(element["angle"]))
            anchor["x"] = num(element["x"]) + num(element["width"]) / 2 + px
            anchor["y"] = num(element["y"]) + num(element["height"]) / 2 + py
            var out = thread
            out["anchor"] = anchor
            return out
        }
    }

    /// One discussion change from the editor, attributed to the signed-in viewer (the file version authenticates the
    /// publisher; the author label inside the JSON is attribution).
    public static func applyCommentOperation(_ scene: Object, _ operation: Object, author: String, now: Date = Date(),
                                             newId: () -> String = { UUID().uuidString.lowercased() }) throws -> Object {
        guard isNpub(author) else { throw SceneError.invalid("an authenticated board author is required") }
        var threads = try normalizeComments(comments(scene))
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func message() -> Object { ["id": newId(), "body": text(operation["body"]), "author_npub": author, "created_at": f.string(from: now)] }
        switch operation["type"] as? String {
        case "create":
            let id = commentId(operation["id"]) ? operation["id"] as! String : newId()
            threads.append(["id": id, "anchor": operation["anchor"] ?? Object(), "resolved": false, "messages": [message()]])
        case "reply":
            guard let i = threads.firstIndex(where: { $0["id"] as? String == operation["thread_id"] as? String }) else { throw SceneError.invalid("comment thread is unavailable") }
            threads[i]["messages"] = (threads[i]["messages"] as? [Object] ?? []) + [message()]
        case "resolve":
            guard let i = threads.firstIndex(where: { $0["id"] as? String == operation["thread_id"] as? String }),
                  let resolved = operation["resolved"], isBool(resolved) else { throw SceneError.invalid("comment operation") }
            threads[i]["resolved"] = resolved
        default:
            throw SceneError.invalid("comment operation")
        }
        return try withComments(scene, threads)
    }

    /// Three-way merge of the discussion: messages union by id, `resolved`/`anchor` changes from the draft win.
    static func mergeComments(base: Object, draft: Object, latest: Object) -> (comments: [Object], conflicts: Int) {
        let before = Dictionary(comments(base).map { (text($0["id"]), $0) }, uniquingKeysWith: { a, _ in a })
        let mine = Dictionary(comments(draft).map { (text($0["id"]), $0) }, uniquingKeysWith: { a, _ in a })
        let theirsList = comments(latest)
        let theirs = Dictionary(theirsList.map { (text($0["id"]), $0) }, uniquingKeysWith: { a, _ in a })
        var order = theirsList.map { text($0["id"]) }
        for t in comments(draft) where theirs[text(t["id"])] == nil { order.append(text(t["id"])) }
        var conflicts = 0
        func same(_ a: Any?, _ b: Any?) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case (let x?, let y?): (x as AnyObject).isEqual(y)
            default: false
            }
        }
        let merged: [Object] = order.compactMap { id in
            let a = before[id], b = mine[id], c = theirs[id]
            guard let b, let c else { return b ?? c }
            var messages = (c["messages"] as? [Object] ?? [])
            var known = Dictionary(messages.enumerated().map { (text($0.element["id"]), $0.offset) }, uniquingKeysWith: { x, _ in x })
            for message in b["messages"] as? [Object] ?? [] {
                let mid = text(message["id"])
                if let at = known[mid] { if !same(messages[at], message) { conflicts += 1 }; continue }
                known[mid] = messages.count
                messages.append(message)
            }
            var out = c
            out["messages"] = messages
            for field in ["resolved", "anchor"] where !same(b[field], a?[field]) {
                if !same(c[field], a?[field]) && !same(c[field], b[field]) { conflicts += 1 }
                out[field] = b[field]
            }
            return out
        }
        return ((try? normalizeComments(merged)) ?? merged, conflicts)
    }

    // MARK: Names

    public static func fileName(_ title: String) -> String {
        let printable = String(title.trimmingCharacters(in: .whitespacesAndNewlines).map { $0.asciiValue.map { $0 < 32 } == true ? " " : $0 })
        var base = printable.replacingOccurrences(of: #"[\\/:*?"<>|]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        base = String(base.prefix(120))
        if base.isEmpty { base = "Board" }
        return base.lowercased().hasSuffix(fileExtension) ? base : base + fileExtension
    }

    // MARK: Values

    static func text(_ value: Any?) -> String { ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    static func isBool(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return value is Bool }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func safeInt(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) <= 9_007_199_254_740_991 else { return nil }
        return Int(d)
    }
}
