import Foundation

/// NIP-98 HTTP auth, matching `buildHttpAuthEvent` in sol/src/auth/nostr.js:
/// tags `u` (exact absolute URL), `method`, and `payload` = SHA-256 of the exact body bytes sent.
public enum NIP98 {
    public static let kind = 27235

    public static func tags(url: URL, method: String, body: Data?) -> [[String]] {
        var tags = [["u", url.absoluteString], ["method", method.uppercased()]]
        if let body { tags.append(["payload", SHA256Hex.of(body)]) }
        return tags
    }

    public static func authorization(url: URL, method: String, body: Data?, signer: EventSigner) async throws -> String {
        let event = try await signer.sign(NostrEventTemplate(kind: kind, tags: tags(url: url, method: method, body: body), content: ""))
        return "Nostr " + (try JSONEncoder().encode(event)).base64EncodedString()
    }
}

/// Signed chat instruction (`kind 33358`), matching sol/src/message-instruction-signatures.js.
public enum MessageInstructionSignature {
    public static let kind = 33358
    public static let protocolName = "flightdeck_pg_message_instruction"

    public static func tags(body: String, workspaceId: String, channelId: String, threadId: String? = nil,
                            messageId: String? = nil, revision: Int? = nil) -> [[String]] {
        var tags = [["protocol", protocolName], ["body_sha256", SHA256Hex.of(body)]]
        if !workspaceId.isEmpty { tags.append(["workspace_id", workspaceId]) }
        if !channelId.isEmpty { tags.append(["channel_id", channelId]) }
        if let threadId, !threadId.isEmpty { tags.append(["thread_id", threadId]) }
        if let messageId, !messageId.isEmpty { tags.append(["message_id", messageId]) }
        if let revision, revision > 0 { tags.append(["revision", String(revision)]) }
        return tags
    }

    public struct Signed: Sendable, Equatable {
        public let event: NostrEvent
        public let signerNpub: String
        public let bodySha256: String

        /// `message_signature` object for the message request body.
        public var requestObject: [String: Any] {
            ["version": 1, "signer_npub": signerNpub, "body_sha256": bodySha256, "nostr_event": event.jsonObject]
        }
    }

    public static func sign(body: String, workspaceId: String, channelId: String, threadId: String? = nil,
                            signer: EventSigner) async throws -> Signed {
        let tags = tags(body: body, workspaceId: workspaceId, channelId: channelId, threadId: threadId)
        let event = try await signer.sign(NostrEventTemplate(kind: kind, tags: tags, content: body))
        guard let npub = NostrKeys.npub(publicKeyHex: event.pubkey) else { throw IdentityError.invalidVault }
        return Signed(event: event, signerNpub: npub, bodySha256: SHA256Hex.of(body))
    }
}
