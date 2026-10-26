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
        if let anchor {
            start = ids.firstIndex(of: anchor) ?? fallback.lazy.compactMap { ids.firstIndex(of: $0) }.first
                ?? min(max(0, fallbackStart), max(0, history.count - 1))
        } else { start = max(0, history.count - size) }
        messages = Array(history.dropFirst(start).prefix(size))
    }
}
