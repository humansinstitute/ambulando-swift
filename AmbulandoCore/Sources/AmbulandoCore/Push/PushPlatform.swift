import Foundation

/// What the OS says about showing alerts. `denied` can only be changed in system Settings.
public enum PushPermission: String, Sendable, Codable, Equatable {
    case notDetermined, denied, authorized
}

/// The two OS facilities the coordinator needs, so tests can fake them: the notification centre's permission and
/// the remote-notification registration that eventually produces a device token (delivered through the app delegate).
public protocol PushPlatform: Sendable {
    func permission() async -> PushPermission
    /// Shows the system prompt (alert, sound, badge). Only ever called from an explicit "Enable Notifications" action.
    func requestPermission() async -> PushPermission
    /// Asks the OS for a device token; the result arrives through `PushCoordinator.tokenReceived` / `registrationFailed`.
    func registerForRemoteNotifications() async
    func unregisterForRemoteNotifications() async
}

/// The APNs environment this build is signed for. Xcode device builds carry `aps-environment=development` in their
/// provisioning profile; distribution builds (TestFlight, App Store) have none embedded and are production.
public extension PushEnvironment {
    /// - Parameter embeddedProfile: the bytes of `embedded.mobileprovision`, if the bundle has one.
    static func resolve(embeddedProfile: Data?) -> PushEnvironment {
        guard let embeddedProfile else { return .production }
        // The profile is CMS-wrapped; its plist payload is plain XML inside, so a bounded text scan is enough.
        let text = String(decoding: embeddedProfile, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>") else { return .production }
        let tail = text[key.upperBound...].prefix(120)
        return tail.contains("<string>development</string>") ? .sandbox : .production
    }
}
