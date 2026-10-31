import Foundation

/// Exact local copies, scoped by the existing connection/workspace/document draft key.
/// Review history is local recovery, never a claim that Tower published a version.
public struct PreservedDocumentSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var bytes: Data
    public var contentType: String
    public var rowVersion: Int
    public var sha256: String
    public var storageObjectId: String
    public init(title: String, bytes: Data, contentType: String, rowVersion: Int, sha256: String, storageObjectId: String) {
        id = UUID().uuidString.lowercased(); self.title = title; self.bytes = bytes; self.contentType = contentType
        self.rowVersion = rowVersion; self.sha256 = sha256; self.storageObjectId = storageObjectId
    }
    public var document: DocumentBody { DocumentBody(bytes: bytes, contentType: contentType) }
    public func matches(_ body: DocBodyRecord) -> Bool {
        rowVersion == body.docRowVersion && sha256 == body.sha256 && storageObjectId == body.storageObjectId
    }
}

public struct PreservedMergePreview: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID().uuidString.lowercased()
    public var title: String
    public var text: String
    public var head: PreservedDocumentSnapshot
    public init(title: String, text: String, head: PreservedDocumentSnapshot) { self.title = title; self.text = text; self.head = head }
}

public struct DocumentReviewJournal: Codable, Sendable, Equatable {
    public var pendingMergedSave = false
    public var base: PreservedDocumentSnapshot?
    public var retained: [PreservedDocumentSnapshot] = []
    public var savedBases: [PreservedDocumentSnapshot] = []
    public var reviewOriginal: PreservedDocumentSnapshot?
    public var mergeBase: PreservedDocumentSnapshot?
    public var mergeLocal: PreservedDocumentSnapshot?
    public var mergeLatest: PreservedDocumentSnapshot?
    public var choices: [String: String] = [:]
    public var previewText: String?
    public var previewTitle: String?
    public var previousPreviews: [PreservedMergePreview] = []
    public init() {}
    public mutating func retainBase(_ snapshot: PreservedDocumentSnapshot) {
        if let old = base, !savedBases.contains(where: { $0.rowVersion == old.rowVersion && $0.sha256 == old.sha256 && $0.storageObjectId == old.storageObjectId }) {
            savedBases.append(old)
        }
        base = snapshot
    }
    public func commonBase(for snapshot: PreservedDocumentSnapshot) -> PreservedDocumentSnapshot? {
        ([base].compactMap { $0 } + savedBases).first {
            $0.rowVersion == snapshot.rowVersion && $0.sha256 == snapshot.sha256 && $0.storageObjectId == snapshot.storageObjectId
                && SHA256Hex.of($0.bytes) == $0.sha256
        }
    }
    public mutating func preserve(_ snapshot: PreservedDocumentSnapshot) {
        if !retained.contains(where: { $0.bytes == snapshot.bytes && $0.title == snapshot.title && $0.rowVersion == snapshot.rowVersion }) {
            retained.append(snapshot)
        }
    }
}

extension StoreReader {
    public func documentReview(key: String) throws -> DocumentReviewJournal {
        guard let text = try state("doc.review.v1:" + key) else { return DocumentReviewJournal() }
        return try JSONDecoder().decode(DocumentReviewJournal.self, from: Data(text.utf8))
    }
}
extension StoreWriter {
    public func saveDocumentReview(_ journal: DocumentReviewJournal, key: String) async throws {
        try await setState("doc.review.v1:" + key, String(decoding: JSONEncoder().encode(journal), as: UTF8.self))
    }
}

/// Conservative structural three-way merge. Rich state, marks, attributes and unknown envelope fields are retained;
/// derived Markdown is regenerated only after merging authoritative rich state. Ambiguous changes require a choice.
public enum DocumentMerge {
    public enum Choice: String, Sendable { case local, latest }
    public struct Conflict: Sendable, Identifiable {
        public let id: String
        public let label: String
        public let local: String
        public let latest: String
    }
    public struct Result: Sendable {
        public let title: String
        public let bytes: Data
        public let contentType: String
        public let conflicts: [Conflict]
    }
    public static func merge(base: PreservedDocumentSnapshot, local: PreservedDocumentSnapshot, latest: PreservedDocumentSnapshot,
                             choices: [String: Choice] = [:]) throws -> Result {
        guard SHA256Hex.of(base.bytes) == base.sha256 else { throw DocumentEditError.integrity }
        let b = base.document, l = local.document, r = latest.document
        guard b.isEditable, l.isEditable, r.isEditable, b.representation == l.representation, b.representation == r.representation,
              b.editing == l.editing, b.editing == r.editing else { throw DocumentEditError.unsupported }
        var conflicts: [Conflict] = []
        func conflict(_ path: String, _ local: JSONValue?, _ remote: JSONValue?) -> JSONValue? {
            if choices[path] == nil { conflicts.append(Conflict(id: path, label: path == "/title" ? "Title" : path.contains("/marks") ? "Text formatting" : path.contains("/attrs") ? "Document formatting" : "Overlapping passage", local: readable(local), latest: readable(remote))) }
            return choices[path] == .latest ? remote : local
        }
        func mergeValue(_ base: JSONValue?, _ local: JSONValue?, _ remote: JSONValue?, _ path: String) -> JSONValue? {
            if local == remote { return local }
            if local == base { return remote }
            if remote == base { return local }
            if case .object(let bs) = base, case .object(let ls) = local, case .object(let rs) = remote,
               Set(bs.map(\.0)).count == bs.count, Set(ls.map(\.0)).count == ls.count, Set(rs.map(\.0)).count == rs.count {
                let keys = (bs + ls + rs).map(\.0).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                return .object(keys.compactMap { key in
                    let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                    return mergeValue(base?[key], local?[key], remote?[key], path + "/" + escaped).map { (key, $0) }
                })
            }
            if case .array(let bs) = base, case .array(let ls) = local, case .array(let rs) = remote {
                // Align unchanged nodes before recursive merging, so insertions/deletions do not shift identities.
                if let combined = combine(bs, ls, rs) { return .array(combined) }
                if bs.count == ls.count && bs.count == rs.count {
                    return .array(bs.indices.compactMap { mergeValue(bs[$0], ls[$0], rs[$0], path + "/\($0)") })
                }
            }
            if case .string(let bs) = base, case .string(let ls) = local, case .string(let rs) = remote {
                if let lines = combine(bs.components(separatedBy: "\n"), ls.components(separatedBy: "\n"), rs.components(separatedBy: "\n")) {
                    return .string(lines.joined(separator: "\n"))
                }
                if let merged = combine(Array(bs), Array(ls), Array(rs)) { return .string(String(merged)) }
            }
            return conflict(path, local, remote)
        }
        let title = mergeValue(.string(base.title), .string(local.title), .string(latest.title), "/title")?.stringValue ?? local.title
        func normalized(_ doc: DocumentBody) -> JSONValue? {
            guard var root = doc.root else { return nil }
            if doc.editing == .proseMirror || doc.editing == .markdownModel {
                var model = doc.contentModel!
                let derived = doc.editing == .proseMirror
                    ? ["content", "content_blocks", "content_format", "editor_state_format", "editor_state_version"] : ["content_blocks"]
                for key in derived { model = model.setting(key, nil) }
                root = doc.representation == .legacyModel ? model : root.setting("content_model", model)
            }
            return root
        }
        let bytes: Data
        if b.representation == .rawMarkdown {
            let merged = mergeValue(.string(b.markdown), .string(l.markdown), .string(r.markdown), "/body")?.stringValue ?? l.markdown
            bytes = Data(merged.utf8)
        } else {
            guard let root = mergeValue(normalized(b), normalized(l), normalized(r), "/body") else { throw DocumentEditError.integrity }
            let merged = DocumentBody(bytes: root.serialized(), contentType: latest.contentType)
            if let state = merged.editorState {
                try DocumentBody.checkEdited(state, original: state)
                bytes = try merged.encoded(editorState: state).bytes
            } else { bytes = try merged.encoded(markdown: merged.markdown).bytes }
        }
        return Result(title: title, bytes: bytes, contentType: latest.contentType, conflicts: conflicts)
    }

    private static func readable(_ value: JSONValue?) -> String {
        guard let value else { return "Deleted" }
        if let text = value.stringValue { return text }
        if let nodes = value.arrayValue { return nodes.isEmpty ? "Deleted" : nodes.map { readable($0) }.joined(separator: "\n\n") }
        if value["type"]?.stringValue == "doc" { return ProseMirrorMarkdown.markdown(value) }
        if value["text"]?.stringValue != nil { return value["text"]!.stringValue! }
        if value["type"]?.stringValue != nil {
            let text = ProseMirrorMarkdown.blockMarkdown(value)
            return text.isEmpty ? "Formatting or embedded content changed" : text
        }
        return "Document details changed"
    }

    private struct Edit<T> { let range: Range<Int>; let replacement: [T] }
    /// Bounded LCS. Excessively large or overlapping edits become explicit conflicts, never guessed merges.
    private static func edits<T: Equatable>(_ base: [T], _ next: [T]) -> [Edit<T>]? {
        guard base.count <= 4000, next.count <= 4000, (base.count + 1) * (next.count + 1) <= 1_000_000 else { return nil }
        let width = next.count + 1
        var table = [Int32](repeating: 0, count: (base.count + 1) * width)
        if !base.isEmpty && !next.isEmpty {
            for i in stride(from: base.count - 1, through: 0, by: -1) {
                for j in stride(from: next.count - 1, through: 0, by: -1) {
                    table[i * width + j] = base[i] == next[j] ? 1 + table[(i + 1) * width + j + 1]
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }
        var i = 0, j = 0, result: [Edit<T>] = []
        while i < base.count || j < next.count {
            if i < base.count && j < next.count && base[i] == next[j] { i += 1; j += 1; continue }
            let start = i
            var replacement: [T] = []
            while i < base.count || j < next.count {
                if i < base.count && j < next.count && base[i] == next[j] { break }
                if j < next.count && (i == base.count || table[i * width + j + 1] >= table[(i + 1) * width + j]) {
                    replacement.append(next[j]); j += 1
                } else { i += 1 }
            }
            result.append(Edit(range: start..<i, replacement: replacement))
        }
        return result
    }
    private static func combine<T: Equatable>(_ base: [T], _ local: [T], _ remote: [T]) -> [T]? {
        guard let left = edits(base, local), let right = edits(base, remote) else { return nil }
        var all = left
        for r in right {
            if all.contains(where: { $0.range == r.range && $0.replacement == r.replacement }) { continue }
            for l in left {
                let overlap = l.range.overlaps(r.range)
                    || (l.range.isEmpty && r.range.isEmpty && l.range.lowerBound == r.range.lowerBound)
                    || (l.range.isEmpty && r.range.lowerBound < l.range.lowerBound && l.range.lowerBound < r.range.upperBound)
                    || (r.range.isEmpty && l.range.lowerBound < r.range.lowerBound && r.range.lowerBound < l.range.upperBound)
                if overlap { return nil }
            }
            all.append(r)
        }
        var result = base
        for edit in all.sorted(by: {
            $0.range.lowerBound == $1.range.lowerBound ? $0.range.count > $1.range.count : $0.range.lowerBound > $1.range.lowerBound
        }) { result.replaceSubrange(edit.range, with: edit.replacement) }
        return result
    }
}

/// Readable two-way line diff, explicitly distinct from the common-base merge engine.
public enum DocumentReviewDiff {
    public struct Line: Sendable, Identifiable {
        public let id: Int
        public let prefix: String
        public let text: String
    }
    public static func lines(local: String, latest: String) -> [Line] {
        let a = local.components(separatedBy: "\n"), b = latest.components(separatedBy: "\n")
        // Avoid unbounded diff work on large documents; the two labelled full versions remain available.
        guard a.count + b.count <= 10000 else { return [] }
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var i = 0, j = 0, result: [Line] = []
        func append(_ prefix: String, _ text: String) { result.append(Line(id: result.count, prefix: prefix, text: text)) }
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { append("−", a[i]); i += 1 }
            else if j < b.count, inserted.contains(j) { append("+", b[j]); j += 1 }
            else if i < a.count, j < b.count { append(" ", a[i]); i += 1; j += 1 }
            else { break }
        }
        return result
    }
}
