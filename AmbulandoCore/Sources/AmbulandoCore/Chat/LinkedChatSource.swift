import Foundation

extension WorkspaceSync {
    /// Resolves a cold native message reference through the existing message ACL route.
    public func linkedChatMessage(_ c: ConnectionRecord, _ w: WorkspaceRecord, messageId: String, channelId: String?) async throws -> MessageRecord {
        try await identity.requireSigner(npub: c.signerNpub)
        let api = api(origin: try TowerOrigin(c.origin))
        guard let message = try await api.message(workspaceId: w.id, appNpub: w.appNpub, messageId: messageId),
              message.id == messageId, !message.deleted,
              channelId == nil || message.channelId == channelId else {
            throw ManagementError.unexpected("The original message is no longer available through this reference.")
        }
        try await identity.requireSigner(npub: c.signerNpub)
        _ = try await store.writer.upsertMessages([message])
        return message
    }
}
