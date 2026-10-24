import Foundation

/// Chat catch-up, scheduled through `SyncEngine` like every other network read.
///
/// Channel history uses `GET …/channels/:c/messages`. It is ordered oldest first with an opaque forward cursor and
/// has no "newest first" mode. So each channel keeps the cursor that fetched its last page. The next catch-up re-reads
/// from there (≤ 200 rows) to the end and reconciles that range, so recent edits and deletions are picked up without
/// re-reading the whole channel. A forced refresh starts from the beginning and reconciles the whole channel.
/// Live deltas (`/sync` cursor, SSE) are the background/live-update work and are not used here.
extension WorkspaceSync {
    public static func messagesKey(_ workspaceId: String, _ channelId: String) -> String { "messages:\(workspaceId):\(channelId)" }
    public static func threadKey(_ workspaceId: String, _ threadId: String) -> String { "thread:\(workspaceId):\(threadId)" }
    public static func scopeOrderKey(_ workspaceId: String) -> String { "scope-order:\(workspaceId)" }
    public static func collapsedKey(connectionId: String, workspaceId: String) -> String { "scope-collapsed:\(connectionId):\(workspaceId)" }

    public func catchUpChannel(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channelId: String,
                               priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.messagesKey(workspace.id, channelId), priority: priority, force: force) {
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            try await sync.runChannelCatchUp(connection, workspace, channelId: channelId, fromStart: force)
        }
    }

    func runChannelCatchUp(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channelId: String, fromStart: Bool) async throws {
        let api = api(origin: try TowerOrigin(connection.origin))
        let stored = fromStart ? nil : try await store.reader.channelSync(workspaceId: workspace.id, channelId: channelId)
        let startAfter = stored.flatMap { s in s.resumeAfterId.flatMap { id in s.resumeAfterCreatedAt.map { MessageKey(createdAt: $0, id: id) } } }
        var cursor = startAfter == nil ? nil : stored?.resumeCursor
        let reconcileAfter = cursor == nil ? nil : startAfter
        var pageCursor = cursor, pageAfter = cursor == nil ? nil : startAfter
        var keep = Set<String>(), last: MessageKey?, seen = Set<String>()
        let started = ISO8601DateFormatter.tower.string(from: Date())
        while true {
            let page = try await api.messagesPage(workspaceId: workspace.id, appNpub: workspace.appNpub, channelId: channelId, cursor: cursor)
            try Task.checkCancellation()
            try await store.writer.upsertMessages(page.messages)
            for m in page.messages { keep.insert(m.id) }
            if let tail = page.messages.last { last = MessageKey(createdAt: tail.createdAt, id: tail.id) }
            guard let next = page.nextCursor else { break }
            guard seen.insert(next).inserted else { throw TowerError.malformed("messages cursor") }
            pageCursor = next; pageAfter = last; cursor = next
            // Progress survives interruption: a later run resumes here instead of restarting the channel.
            try await store.writer.saveChannelSync(workspaceId: workspace.id, channelId: channelId, resumeCursor: next, resumeAfter: last, complete: false)
        }
        let through = last ?? MessageKey(createdAt: started, id: "")
        try await store.writer.reconcileMessages(workspaceId: workspace.id, channelId: channelId, threadId: nil, after: reconcileAfter,
                                                 through: through, keep: keep)
        try await store.writer.saveChannelSync(workspaceId: workspace.id, channelId: channelId, resumeCursor: pageCursor,
                                               resumeAfter: pageAfter, complete: true)
        // Thread titles and archive state (one page; never used to delete).
        let threads = try await api.threads(workspaceId: workspace.id, appNpub: workspace.appNpub, channelId: channelId)
        try Task.checkCancellation()
        try await store.writer.upsertThreads(workspaceId: workspace.id, threads.threads)
    }

    /// Opening a thread fetches that thread's messages directly (user priority), independent of channel catch-up.
    public func refreshThread(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, channelId: String, threadId: String,
                              priority: SyncPriority = .user, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.threadKey(workspace.id, threadId), priority: priority, force: force) {
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            var cursor: String?, keep = Set<String>(), last: MessageKey?, seen = Set<String>()
            let started = ISO8601DateFormatter.tower.string(from: Date())
            repeat {
                let page = try await api.messagesPage(workspaceId: workspace.id, appNpub: workspace.appNpub, channelId: channelId,
                                                      threadId: threadId, cursor: cursor)
                try Task.checkCancellation()
                try await sync.store.writer.upsertMessages(page.messages)
                for m in page.messages { keep.insert(m.id) }
                if let tail = page.messages.last { last = MessageKey(createdAt: tail.createdAt, id: tail.id) }
                cursor = page.nextCursor
                if let cursor { guard seen.insert(cursor).inserted else { throw TowerError.malformed("messages cursor") } }
            } while cursor != nil
            try await sync.store.writer.reconcileMessages(workspaceId: workspace.id, channelId: channelId, threadId: threadId, after: nil,
                                                          through: last ?? MessageKey(createdAt: started, id: ""), keep: keep)
            let thread = try await api.thread(workspaceId: workspace.id, appNpub: workspace.appNpub, threadId: threadId)
            if thread.workspaceId == workspace.id, thread.channelId == channelId {
                try await sync.store.writer.upsertThreads(workspaceId: workspace.id, [thread])
            }
        }
    }

    /// Member directory (mention picker, sender names) and personal scope order.
    public func refreshDirectory(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, priority: SyncPriority = .background,
                                 force: Bool = false) async {
        let sync = self
        await engine.enqueue("directory:\(workspace.id)", priority: priority, force: force) {
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            let members = try await api.members(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            try await sync.store.writer.replaceMembers(workspaceId: workspace.id, members)
            let order = try await api.scopeOrder(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            let encoded = String(decoding: try JSONEncoder().encode(order), as: UTF8.self)
            if try await sync.store.reader.state(Self.scopeOrderKey(workspace.id)) != encoded {
                try await sync.store.writer.setState(Self.scopeOrderKey(workspace.id), encoded)
            }
        }
    }
}

public enum ScopeOrdering {
    /// Personal order first (as saved on Tower), then the remaining scopes in their default order.
    public static func apply<T>(_ items: [T], order: [String], id: (T) -> String) -> [T] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated().sorted { a, b in
            switch (rank[id(a.element)], rank[id(b.element)]) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    public static func decode(_ text: String?) -> [String] {
        text.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }
}

extension ISO8601DateFormatter {
    /// Tower serialises timestamps as `2026-10-24T00:01:55.789Z`.
    nonisolated(unsafe) static let tower: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
