import Foundation

/// How an alert that arrives while the app is open is shown.
public enum PushForegroundPresentation: Sendable, Equatable {
    /// The person is already looking at what the alert is about: no second banner.
    case suppress
    /// Otherwise the OS alert channel shows it as it would in the background.
    case banner
}

public enum PushPresentation {
    /// - Parameter viewing: the resource currently on screen, if any (the app maps its navigation onto the same shape).
    public static func foreground(_ payload: PushPayload?, viewing: PushDestination?) -> PushForegroundPresentation {
        guard let payload, let viewing, let target = PushRouter.destination(for: payload) else { return .banner }
        return target == viewing ? .suppress : .banner
    }
}

/// A tap held until it can be acted on safely. It lives in memory only: it holds ids, never message text.
public struct PendingPushTap: Sendable, Equatable {
    public let payload: PushPayload
    public let receivedAt: Date

    public init(payload: PushPayload, receivedAt: Date) {
        self.payload = payload
        self.receivedAt = receivedAt
    }

    /// A held tap that sat for a day is dropped rather than navigating somewhere surprising.
    public func isFresh(now: Date) -> Bool { now.timeIntervalSince(receivedAt) < 24 * 3600 }
}
