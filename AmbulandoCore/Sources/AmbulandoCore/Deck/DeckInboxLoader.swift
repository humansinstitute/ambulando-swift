import Foundation

public struct DeckInboxSnapshot: Sendable, Equatable {
    public var items: [DeckActivity.Item] = []
    public var viewStates: [String: ViewStateRecord] = [:]
    public var channelLabels: [String: String] = [:]
    public init(items: [DeckActivity.Item] = [], viewStates: [String: ViewStateRecord] = [:], channelLabels: [String: String] = [:]) {
        self.items = items; self.viewStates = viewStates; self.channelLabels = channelLabels
    }
}

/// The Deck Inbox read for one workspace and context, shared by the platforms' Deck cards.
public enum DeckInboxLoader {
    public static func load(store: LocalStore, workspaceId w: String, context: WorkContext,
                            viewer: String?, origin: String?) async throws -> DeckInboxSnapshot {
        var sources = DeckActivity.Sources()
        // The channel filter is read from the store on every load. A filter captured when the query started would be
        // empty for a context restored before its workspace's channels synced, and no later change could correct it.
        let channelRows = try await store.reader.channels(workspaceId: w)
        let channelIds = scopedChannelIds(context, channels: channelRows)
        async let threads = store.reader.deckThreads(workspaceId: w, channelIds: channelIds)
        async let tasks = store.reader.tasks(workspaceId: w, scopeId: context.scopeId, channelId: context.channelId)
        async let docs = store.reader.docs(workspaceId: w, scopeId: context.scopeId)
        async let files = store.reader.files(workspaceId: w, channelId: context.channelId)
        async let states = store.reader.viewStates(workspaceId: w)
        async let taskComments = store.reader.deckCommentActivity(workspaceId: w, parent: .task, viewerNpub: viewer)
        async let docComments = store.reader.deckCommentActivity(workspaceId: w, parent: .doc, viewerNpub: viewer)
        async let activities = store.reader.agentActivities(workspaceId: w, channelIds: channelIds)
        let names = try await store.reader.people(workspaceId: w).names
        sources.channelScopes = Dictionary(channelRows.map { ($0.id, $0.scopeId) }, uniquingKeysWith: { a, _ in a })
        sources.threads = try await threads
        sources.tasks = try await tasks
        sources.docs = try await docs
        sources.files = try await files
        sources.viewStates = try await states
        sources.taskComments = try await taskComments
        sources.docComments = try await docComments
        sources.activities = try await activities
        sources.now = ServerClock.shared.now(origin: origin)
        let types = try await store.reader.attentionTypes(workspaceId: w)
        return DeckInboxSnapshot(items: types.deck(DeckActivity.inbox(sources, context: context)),
                                 viewStates: Dictionary(sources.viewStates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                                 channelLabels: Dictionary(channelRows.map { ($0.id, SidebarNavigation.label($0, viewerNpub: viewer, names: names)) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Channels whose activity the context shows; nil is every channel (Home). A named channel needs no list at all.
    public static func scopedChannelIds(_ context: WorkContext, channels: [ChannelRecord]) -> [String]? {
        guard let scopeId = context.scopeId else { return nil }
        if let channelId = context.channelId { return [channelId] }
        return channels.filter { $0.scopeId == scopeId }.map(\.id)
    }
}
