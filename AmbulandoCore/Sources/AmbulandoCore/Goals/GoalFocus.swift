import Foundation

/// Something ordered by focus: a goal and the identity of the File that holds it.
public protocol GoalFocusItem {
    var id: String { get }
    var goal: Goal { get }
}

extension GoalDocument: GoalFocusItem {}

/// Focus order: which goals Home shows first. A goal may carry `focus_rank`, a fractional-index key of 1–64 characters
/// from `digits` (ASCII order) not ending in the lowest digit. Keys compare by code unit, and a key exists strictly between
/// any two distinct keys, so a move usually rewrites only the moved goal. It writes more when unranked goals above the
/// destination must first be ranked, or when a rebalance is needed (see `planMove`); every write is the ordinary
/// expectation-checked edit on one goal, saved with `GoalEditor.move`.
/// The field stays in the unknown-field area (`Goal.extra`), so clients that predate it keep it byte for byte. Anything
/// else in `focus_rank` (wrong type, bad character, too long) reads as unranked and is kept untouched until a valid rank
/// replaces it. Same functions as `scripts/goals-lib.mjs` and Android; `docs/fixtures/goals/focus-order-v1.json` pins them.
public enum GoalFocus {
    public static let field = "focus_rank"
    public static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    public static let maxLength = 64

    public static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...maxLength).contains(bytes.count), bytes.last != digits[0] else { return false }
        return bytes.allSatisfy { digits.contains($0) }
    }

    /// A key strictly between `a` and `b` (`nil` = no bound). Port of the midpoint of David Greenspan's "Implementing
    /// Fractional Indexing" (MIT `fractional-indexing`), without its integer header so every key is a plain fraction.
    public static func key(between a: String?, and b: String?) throws -> String {
        let lo = a ?? ""
        if !lo.isEmpty && !isValid(lo) { throw GoalError.invalid("A focus rank is invalid.") }
        if let b, !isValid(b) { throw GoalError.invalid("A focus rank is invalid.") }
        if let b, !(Array(lo.utf8).lexicographicallyPrecedes(Array(b.utf8))) { throw GoalError.invalid("Focus ranks are out of order.") }
        return String(decoding: midpoint(Array(lo.utf8), b.map { Array($0.utf8) }), as: UTF8.self)
    }

    private static func midpoint(_ a: [UInt8], _ b: [UInt8]?) -> [UInt8] {
        if let b {
            var n = 0
            while n < b.count && (n < a.count ? a[n] : digits[0]) == b[n] { n += 1 }
            if n > 0 { return Array(b[..<n]) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n))) }
        }
        let da = a.first.flatMap { digits.firstIndex(of: $0) } ?? 0
        let db = b.flatMap { $0.first }.flatMap { digits.firstIndex(of: $0) } ?? digits.count
        if db - da > 1 { return [digits[(da + db + 1) / 2]] }
        if let b, b.count > 1 { return [b[0]] }
        return [digits[da]] + midpoint(Array(a.dropFirst()), nil)
    }

    /// `n` evenly spaced short keys, in order: the rebalance used when no key fits (ties, or a key over `maxLength`).
    public static func evenKeys(_ n: Int) -> [String] {
        let base = digits.count
        var width = 1, span = base
        while span - 1 < n { width += 1; span *= base }
        return (0..<n).map { j in
            var v = (j + 1) * span / (n + 1), key: [UInt8] = []
            for _ in 0..<width { key.insert(digits[v % base], at: 0); v /= base }
            while key.last == digits[0] { key.removeLast() }
            return String(decoding: key, as: UTF8.self)
        }
    }

    /// The valid rank of `goal`, or `nil` (unranked).
    public static func rank(_ goal: Goal) -> String? {
        guard let value = goal.extra[field]?.stringValue, isValid(value) else { return nil }
        return value
    }

    /// `goal` with `value` as its rank (`nil` removes the field). An existing field keeps its position.
    static func setting(_ goal: Goal, _ value: String?) -> Goal {
        var pairs = goal.extra.objectValue ?? []
        if let value {
            if let index = pairs.firstIndex(where: { $0.0 == field }) { pairs[index].1 = .string(value) } else { pairs.append((field, .string(value))) }
        } else {
            pairs.removeAll { $0.0 == field }
        }
        var out = goal; out.extra = .object(pairs)
        return out
    }

    /// The one goal order on every client: status (active, completed, archived); then ranked goals by rank, before
    /// unranked ones; unranked by target date (none last), then name with only A–Z folded; equal keys by file id.
    /// Every comparison is by UTF-16 code unit, so Swift, Kotlin and JS agree.
    public static func precedes(_ a: some GoalFocusItem, _ b: some GoalFocusItem) -> Bool {
        compare(a, b) < 0
    }

    public static func order<T: GoalFocusItem>(_ items: [T]) -> [T] { items.sorted { precedes($0, $1) } }

    static func compare(_ a: some GoalFocusItem, _ b: some GoalFocusItem) -> Int {
        let ra = rank(a.goal), rb = rank(b.goal)
        if a.goal.status.rank != b.goal.status.rank { return a.goal.status.rank < b.goal.status.rank ? -1 : 1 }
        if (ra == nil) != (rb == nil) { return ra == nil ? 1 : -1 }
        if let ra, let rb, ra != rb { return units(ra, rb) }
        if ra == nil {
            let ta = a.goal.targetDate ?? "9999-12-31", tb = b.goal.targetDate ?? "9999-12-31"
            if ta != tb { return units(ta, tb) }
            let na = asciiFold(a.goal.name), nb = asciiFold(b.goal.name)
            if na != nb { return units(na, nb) }
        }
        return a.id == b.id ? 0 : units(a.id, b.id)
    }

    private static func units(_ x: String, _ y: String) -> Int {
        Array(x.utf16).lexicographicallyPrecedes(Array(y.utf16)) ? -1 : (x == y ? 0 : 1)
    }

    private static func asciiFold(_ s: String) -> String {
        String(decoding: s.utf16.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF16.self)
    }

    public struct Write: Equatable, Sendable {
        public let id: String
        public let expected: String?
        public let value: String
        public var edit: GoalEdit { .setFocusRank(expected: expected, value: value) }
    }

    /// The rank writes that move goal `id` to `toIndex` in `items` (one status group, already in focus order), top first.
    /// - Usually one write: a key between the new neighbours.
    /// - Ranked goals sort before unranked ones, so placing a goal below an unranked goal first ranks the unranked goals
    ///   above it, in their current order.
    /// - Neighbours with equal keys (two devices picked the same key) or a key over `maxLength` rebalance: every goal from
    ///   the top through the last ranked one (or the moved goal) gets `evenKeys`, writing only the keys that change.
    public static func planMove(_ items: [some GoalFocusItem], id: String, toIndex: Int) throws -> [Write] {
        guard let movingIndex = items.firstIndex(where: { $0.id == id }) else { throw GoalError.conflict("That goal was removed elsewhere.") }
        var next: [any GoalFocusItem] = items
        let moving = next.remove(at: movingIndex)
        let at = min(max(toIndex, 0), next.count)
        next.insert(moving, at: at)
        if next.map(\.id) == items.map(\.id) { return [] }
        let ranks = next.map { rank($0.goal) }
        var writes: [Write] = [], lo: String?, fits = true
        for n in 0...at {
            if n < at, let r = ranks[n] { lo = r; continue }
            let hi = n == at && n + 1 < next.count ? ranks[n + 1] : nil
            if let hi, let lo, !Array(lo.utf8).lexicographicallyPrecedes(Array(hi.utf8)) { fits = false; break }
            let key = try key(between: lo, and: hi)
            if key.utf8.count > maxLength { fits = false; break }
            writes.append(Write(id: next[n].id, expected: ranks[n], value: key))
            lo = key
        }
        if fits { return writes }
        let last = max(at, ranks.lastIndex { $0 != nil } ?? -1)
        let keys = evenKeys(last + 1)
        return (0...last).compactMap { n in ranks[n] == keys[n] ? nil : Write(id: next[n].id, expected: ranks[n], value: keys[n]) }
    }
}
