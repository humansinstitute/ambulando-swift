import Foundation

/// Persistence of the binding in the connection catalog's `app_state`. One binding per signing identity, so signing out
/// and in as someone else never reads or overwrites it, and signing back in restores it. Nothing here deletes drafts,
/// unsent messages or cached messages: those live in the workspace partition under the conversation's own key.
extension StoreReader {
    public static func familyBindingKey(signerNpub: String) -> String { "family.binding.v1:\(signerNpub)" }

    public func familyBinding(signerNpub: String) throws -> FamilyBinding? {
        guard let text = try state(Self.familyBindingKey(signerNpub: signerNpub)),
              let binding = try? JSONDecoder().decode(FamilyBinding.self, from: Data(text.utf8)),
              binding.isWellFormed, binding.signerNpub == signerNpub else { return nil }
        return binding
    }

    /// The conversation a first message with this `client_request_id` created, once Tower has accepted it.
    public func familyCreatedThread(workspaceId: String, requestId: String) throws -> (threadId: String, body: String)? {
        let s = try db.prepare("""
        SELECT thread_id, body FROM messages WHERE workspace_id = ? AND client_request_id = ? AND thread_id IS NOT NULL AND deleted = 0 LIMIT 1
        """)
        try s.bind([.text(workspaceId), .text(requestId.lowercased())])
        return try s.step() ? (s.text(0) ?? "", s.text(1) ?? "") : nil
    }
}

extension StoreWriter {
    public func setFamilyBinding(_ binding: FamilyBinding) async throws {
        guard binding.isWellFormed else { throw FamilyBindingError.malformed }
        let text = String(decoding: try JSONEncoder().encode(binding), as: UTF8.self)
        try await setState(StoreReader.familyBindingKey(signerNpub: binding.signerNpub), text)
    }

    /// Forgets the choice only. The deliberate "change family chat" action; cached messages and drafts stay on the device.
    public func clearFamilyBinding(signerNpub: String) async throws {
        try await setState(StoreReader.familyBindingKey(signerNpub: signerNpub), nil)
    }
}

public enum FamilyBindingError: LocalizedError, Equatable, Sendable {
    case malformed
    public var errorDescription: String? { "That family chat choice is incomplete and was not saved." }
}

/// A live look at Tower before anything is sent. The result is authoritative; the cache is not.
public enum FamilyVerification: Equatable, Sendable {
    case confirmed(ThreadRecord)
    case workspaceLost
    case channelOrThreadLost
    case archived(ThreadRecord)
    /// Tower could not be reached or answered unexpectedly: the person is told, the message stays in the outbox.
    case unreachable(String)

    public var allowsSend: Bool { if case .confirmed = self { true } else { false } }

    /// Checks workspace access, then the bound thread: it must exist in the bound channel and workspace and not be
    /// deleted. Never substitutes another thread.
    public static func verify(_ binding: FamilyBinding, api: TowerAPI) async -> FamilyVerification {
        guard let threadId = binding.threadId else { return .channelOrThreadLost }
        let workspaces: [WorkspaceRecord]
        do { workspaces = try await api.workspaces() }
        catch TowerError.http(let status, _, _) where status == 403 { return .workspaceLost }
        catch { return .unreachable(unreachableText(error)) }
        guard workspaces.contains(where: { $0.id == binding.workspaceId && $0.appNpub == binding.appNpub }) else { return .workspaceLost }
        do {
            let thread = try await api.thread(workspaceId: binding.workspaceId, appNpub: binding.appNpub, threadId: threadId)
            guard thread.id == threadId, thread.channelId == binding.channelId, thread.workspaceId == binding.workspaceId, !thread.deleted else {
                return .channelOrThreadLost
            }
            return thread.archived ? .archived(thread) : .confirmed(thread)
        } catch TowerError.http(let status, _, _) where status == 403 || status == 404 {
            return .channelOrThreadLost
        } catch {
            return .unreachable(unreachableText(error))
        }
    }

    private static func unreachableText(_ error: Error) -> String {
        error is CancellationError ? "Cancelled" : error.localizedDescription
    }
}
