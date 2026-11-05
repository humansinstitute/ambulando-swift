import Foundation

/// A bounded render page over the thread's already-loaded history. Anchors are message identities, so new replies
/// cannot shift an older page. Deleted anchors fall forward to a surviving row rather than jumping to the newest.
public struct ThreadMessageWindow: Sendable, Equatable {
    public let messages: [MessageRecord]
    public let order: [String]
    public let start: Int
    public var hasEarlier: Bool { start > 0 }
    public var hasNewer: Bool { start + messages.count < order.count }

    public init(_ history: [MessageRecord], anchor: String? = nil, fallback: [String] = [], fallbackStart: Int = 0, size: Int = 50) {
        let size = max(1, size)
        let ids = history.map(\.id)
        order = ids
        start = Self.start(in: ids, anchor: anchor, fallback: fallback, fallbackStart: fallbackStart, size: size)
        messages = Array(history.dropFirst(start).prefix(size))
    }
    public init(messages: [MessageRecord], order: [String], start: Int) {
        self.messages = messages; self.order = order; self.start = start
    }

    static func start(in ids: [String], anchor: String?, fallback: [String], fallbackStart: Int, size: Int) -> Int {
        if let anchor {
            return ids.firstIndex(of: anchor) ?? fallback.lazy.compactMap { ids.firstIndex(of: $0) }.first
                ?? min(max(0, fallbackStart), max(0, ids.count - 1))
        }
        return max(0, ids.count - max(1, size))
    }
}
