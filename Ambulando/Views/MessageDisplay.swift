import AmbulandoCore
import Foundation
import SwiftUI

/// Display values of a message that are costly to derive (mention styling, attachment JSON, time label). They are
/// prepared off the main actor when a screen's snapshot loads and cached by message version, so row bodies, which
/// SwiftUI may evaluate many times while scrolling or sizing a list, only look them up.
struct MessageDisplay: Sendable {
    /// nil for plain text (no Markdown, mentions or links): rendered as verbatim `Text`, which skips Markdown parsing
    /// and attributed-string resolution, the dominant per-row cost when a channel opens.
    let blocks: [RenderBlock]?
    let time: String
    let attachments: [MessageAttachment]
}

/// Bounded, thread-safe memo shared by all chat screens.
final class MessageDisplayCache: @unchecked Sendable {
    static let shared = MessageDisplayCache()

    private struct Key: Hashable { let workspace: String; let id: String; let rowVersion: Int; let updatedAt: String; let day: Int }
    private let lock = NSLock()
    private var entries: [Key: MessageDisplay] = [:]
    private let limit = 3000

    private func key(_ m: MessageRecord) -> Key {
        Key(workspace: m.workspaceId, id: m.id, rowVersion: m.rowVersion, updatedAt: m.updatedAt, day: ChatTime.dayStamp())
    }

    func display(_ message: MessageRecord) -> MessageDisplay {
        let k = key(message)
        if let hit = lock.withLock({ entries[k] }) { return hit }
        let made = Self.make(message)
        store(k, made)
        return made
    }

    /// Called from snapshot loads (reader side, off the main actor).
    func prepare(_ messages: [MessageRecord]) {
        let missing = lock.withLock { messages.filter { entries[key($0)] == nil } }
        for m in missing { store(key(m), Self.make(m)) }
    }

    private func store(_ k: Key, _ v: MessageDisplay) {
        lock.withLock {
            if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
            entries[k] = v
        }
    }

    static func make(_ m: MessageRecord) -> MessageDisplay {
        MessageDisplay(blocks: MessageText.blocks(m.body), time: ChatTime.label(m.createdAt), attachments: MessageAttachment.from(messageRaw: m.raw))
    }
}

/// Message bodies as the web renders them: Markdown with line breaks, mentions and record references as typed runs.
enum MessageText {
    static func isPlain(_ body: String) -> Bool { MarkdownBlocks.isPlainText(body) }

    /// Display blocks, or nil when the body can be shown verbatim.
    static func blocks(_ body: String) -> [RenderBlock]? {
        isPlain(body) ? nil : MarkdownBlocks.parse(body)
    }

    private final class Entry { let blocks: [RenderBlock]?; init(_ blocks: [RenderBlock]?) { self.blocks = blocks } }
    nonisolated(unsafe) private static let memo: NSCache<NSString, Entry> = { let c = NSCache<NSString, Entry>(); c.countLimit = 500; return c }()

    /// `blocks(_:)` memoised by text, for views that render a body directly (task descriptions, comments, outbox rows).
    static func cachedBlocks(_ body: String) -> [RenderBlock]? {
        if let hit = memo.object(forKey: body as NSString) { return hit.blocks }
        let made = blocks(body)
        memo.setObject(Entry(made), forKey: body as NSString)
        return made
    }
}
