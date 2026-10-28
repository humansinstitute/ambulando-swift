import Foundation

extension WorkspaceSync {
    /// A push is an untrusted hint. Only stored connection/workspace credentials are used. This path never opens a
    /// route, marks anything read, or sends the outbox. Work uses the same event/notification keys as foreground sync.
    public func refreshAfterPush(_ payload: PushPayload, connection: ConnectionRecord) async throws -> Bool {
        try Task.checkCancellation()
        try await identity.requireReader(npub: connection.signerNpub)
        let workspaces = try await store.reader.workspaces(connectionId: connection.id)
        let decision = PushRouter.decide(payload, connectedOrigin: try TowerOrigin(connection.origin),
                                         connectedTowerNpub: connection.towerNpub, workspaceIds: Set(workspaces.map(\.id)), isLocked: false)
        guard case .open = decision, let workspace = workspaces.first(where: { $0.id.lowercased() == payload.workspaceId }) else { return false }
        let sync = self
        let tables: Set<StoreTable> = [.messages, .threads, .tasks, .comments, .docs, .docBodies, .notifications, .access]
        let before = store.changes.revisions.value(of: tables)
        var targeted = false
        if let thread = payload.threadId, let channel = payload.channelId, payload.taskId == nil, payload.docId == nil {
            try await engine.perform(Self.threadKey(workspace.id, thread), priority: .background) {
                try await sync.runThreadRefresh(connection, workspace, channelId: channel, threadId: thread)
            }
            targeted = store.changes.revisions.value(of: tables) != before
        } else if let channel = payload.channelId, payload.taskId == nil, payload.docId == nil {
            try await engine.perform(Self.messagesKey(workspace.id, channel), priority: .background) {
                try await sync.runChannelCatchUp(connection, workspace, channelId: channel, fromStart: false)
            }
            targeted = store.changes.revisions.value(of: tables) != before
        }
        try Task.checkCancellation()
        let changed = try await engine.perform(Self.eventsKey(workspace.id), priority: .background) {
            try Task.checkCancellation()
            try await sync.identity.requireReader(npub: connection.signerNpub)
            // A synthetic hint uses the ordinary materialiser and ACL checks, even without a valid event cursor.
            // The payload sequence is never adopted as local progress.
            let type = payload.taskId != nil ? "task" : "doc"
            if let id = payload.taskId ?? payload.docId {
                let hint = TowerEvent(rowVersion: 0, cursor: "", workspaceId: workspace.id, entityType: type,
                                      entityId: id, operation: "updated", channelId: payload.channelId)
                try await sync.applyEvents([hint], connection, workspace)
            }
            try Task.checkCancellation()
            let result = try await sync.pollEvents(connection, workspace, pages: Self.backgroundPageBudget, incrementalOnly: true)
            let after = sync.store.changes.revisions.value(of: tables)
            return result.events > 0 || after != before
        }
        try Task.checkCancellation()
        let notifications = try await engine.perform(Self.notificationsKey(workspace.id), priority: .background) {
            try await sync.runNotifications(connection, workspace, listBudget: 5, continueListing: false)
        }
        try Task.checkCancellation()
        return targeted || changed || notifications.listed > 0 || notifications.replayed > 0
    }
}
