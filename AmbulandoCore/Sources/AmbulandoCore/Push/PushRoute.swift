import Foundation

/// Where a notification tap leads. The app maps each case onto its own `WorkRoute`; every case keeps its workspace.
public enum PushDestination: Sendable, Hashable {
    case task(workspaceId: String, taskId: String)
    case doc(workspaceId: String, docId: String)
    case thread(workspaceId: String, channelId: String, threadId: String)
    /// A thread whose channel the payload omitted; the app resolves it as it does for pins.
    case threadById(workspaceId: String, threadId: String)
    case channel(workspaceId: String, channelId: String)
}

public enum PushRefusal: Sendable, Equatable {
    case foreignOrigin
    case unknownWorkspace
    case noTarget
}

public enum PushTapDecision: Sendable, Equatable {
    case open(PushDestination)
    /// The identity is locked: keep the destination in memory only and decide again after unlock.
    case holdUntilUnlock(PushDestination)
    /// Show a neutral notice and do not navigate.
    case refuse(PushRefusal)
}

public enum PushRouter {
    /// The most specific record wins: a task or doc before its conversation, a thread before its channel.
    public static func destination(for payload: PushPayload) -> PushDestination? {
        let w = payload.workspaceId
        if let task = payload.taskId { return .task(workspaceId: w, taskId: task) }
        if let doc = payload.docId { return .doc(workspaceId: w, docId: doc) }
        if let thread = payload.threadId {
            if let channel = payload.channelId { return .thread(workspaceId: w, channelId: channel, threadId: thread) }
            return .threadById(workspaceId: w, threadId: thread)
        }
        if let channel = payload.channelId { return .channel(workspaceId: w, channelId: channel) }
        return nil
    }

    /// Refuses a payload from another Tower origin or for a workspace this connection does not hold. Access to the
    /// record itself is still checked by Tower when the app loads it; a refusal there is shown neutrally too.
    public static func decide(_ payload: PushPayload, connectedOrigin: TowerOrigin?, workspaceIds: Set<String>,
                              isLocked: Bool) -> PushTapDecision {
        guard let connectedOrigin, connectedOrigin == payload.origin else { return .refuse(.foreignOrigin) }
        guard workspaceIds.contains(where: { $0.lowercased() == payload.workspaceId }) else { return .refuse(.unknownWorkspace) }
        guard let destination = destination(for: payload) else { return .refuse(.noTarget) }
        return isLocked ? .holdUntilUnlock(destination) : .open(destination)
    }
}
