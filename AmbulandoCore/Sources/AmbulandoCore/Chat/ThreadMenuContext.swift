import Foundation

/// What the focused thread's header menu acts on, read the way the web's thread menu reads it (sol `index.html`
/// `.thread-title-menu`: `getThreadParentMessage`, `buildChatMessageFlightDeckReferenceId`, `getThreadAutopilotSessionId`).
public struct ThreadMenuContext: Sendable, Equatable {
    public let channelId: String
    public let threadId: String
    /// The message that started the thread, when it is stored (Copy message, Get it done, Delete message act on it).
    public let root: MessageRecord?
    /// The root's id, known from the thread record or any reply even when the root itself is not stored.
    public let rootMessageId: String?
    /// The newest message in the thread that came from an Autopilot session (the thread's "Autopilot Link").
    public let autopilotSource: MessageRecord?

    /// - Parameters:
    ///   - history: the thread's stored messages, oldest first (deleted messages are not stored).
    ///   - historyComplete: `history` holds the whole thread, so its first message is the root even without a source id.
    public init(threadId: String, channelId: String, record: ThreadRecord?, history: [MessageRecord], historyComplete: Bool) {
        let source = record?.sourceMessageId ?? history.lazy.compactMap(\.threadSourceId).first
        let root = source.flatMap { id in history.first { $0.id == id } }
            ?? history.first { $0.isThreadRoot }
            ?? (source == nil && historyComplete ? history.first : nil)
        self.threadId = threadId
        self.channelId = record?.channelId ?? root?.channelId ?? channelId
        self.root = root
        self.rootMessageId = source ?? root?.id
        self.autopilotSource = Self.latestAutopilotMessage(in: history)
    }

    /// The web's thread "FD Ref": `@[Chat thread](mention:chat:<channel>#<root message>)`, the form `openRecord` and the
    /// web's `openLinkedThread` open.
    public var flightDeckReference: String? {
        guard let rootMessageId, !channelId.isEmpty else { return nil }
        return "@[Chat thread](mention:chat:\(channelId)#\(rootMessageId))"
    }

    /// The latest by `updated_at` (ties: the later stored row), as sol `sortMessagesByUpdatedAt(...).at(-1)`.
    private static func latestAutopilotMessage(in history: [MessageRecord]) -> MessageRecord? {
        let marker = Data("autopilot_session".utf8)
        var latest: MessageRecord?
        for message in history where !message.deleted && message.raw.range(of: marker) != nil
            && AutopilotSessionLink.sessionId(in: message.raw) != nil {
            if latest.map({ message.updatedAt >= $0.updatedAt }) ?? true { latest = message }
        }
        return latest
    }
}
