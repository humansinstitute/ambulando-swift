import Foundation

/// Where a person was when they asked for something that needs a moment (storing their text, creating a page): the account,
/// the workspace, whether the source screen is showing, and a counter that changes every time that screen is left.
public struct WikiVisit: Equatable, Sendable {
    public var connectionId: String?
    public var actorId: String?
    public var contextEpoch: Int
    public var workspaceId: String
    public var visible: Bool
    public var epoch: Int
    public init(connectionId: String?, workspaceId: String, visible: Bool, epoch: Int, actorId: String? = nil, contextEpoch: Int = 0) {
        self.actorId = actorId; self.contextEpoch = contextEpoch
        self.connectionId = connectionId; self.workspaceId = workspaceId; self.visible = visible; self.epoch = epoch
    }
}

public enum WikiNavigation {
    public enum Result: Equatable, Sendable {
        case opened
        /// The text could not be stored on the device, so the screen was not left.
        case draftNotStored
        /// During the wait the person left the screen, switched workspace or account, or came back to a new visit: nothing opens.
        case leftTheScreen
    }

    /// Stores the person's text, then opens a page, but only if they are still where they asked. The check is made after the
    /// wait, so a slow store can never carry someone to a page they have since walked away from.
    @MainActor
    public static func open(_ documentId: String, from start: WikiVisit, now: @MainActor () -> WikiVisit,
                            checkpoint: @MainActor () async -> Bool, navigate: @MainActor (String) -> Void) async -> Result {
        guard await checkpoint() else { return .draftNotStored }
        let current = now()
        guard current.visible, current == start else { return .leftTheScreen }
        navigate(documentId)
        return .opened
    }
}

/// How a page-level binding ends. A link only counts as recorded once the text that holds it is durable: every outcome that
/// leaves the source unchanged still checks that nothing the earlier attempt put there is waiting unstored, so a retry after a
/// failed store can never retire the creation write with the link only in memory.
public enum WikiEditorBinding: Equatable, Sendable {
    case bound
    case nothingToBind
    case noLongerRequested
    case failed

    /// `pageCount`: how many references the page bound (-1: they changed since the request, none bound); `stored`: whether the
    /// text that holds them is durable.
    public static func outcome(pageCount: Int, stored: Bool) -> WikiEditorBinding {
        guard stored else { return .failed }
        if pageCount < 0 { return .noLongerRequested }
        return pageCount == 0 ? .nothingToBind : .bound
    }

    /// The same, asking the editor to store its text first, whatever the page reported.
    @MainActor
    public static func outcome(pageCount: Int, checkpoint: @MainActor () async -> Bool) async -> WikiEditorBinding {
        outcome(pageCount: pageCount, stored: await checkpoint())
    }
}
