#if os(iOS)
import AmbulandoCore
import UIKit
import UserNotifications

/// The real OS side of `PushPlatform`. The permission prompt is requested only when the coordinator is asked to enable
/// notifications; the device token comes back through `AppDelegate`.
struct SystemPushPlatform: PushPlatform {
    func permission() async -> PushPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .denied
        }
    }

    func requestPermission() async -> PushPermission {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return await permission()
    }

    func registerForRemoteNotifications() async { await MainActor.run { UIApplication.shared.registerForRemoteNotifications() } }
    func unregisterForRemoteNotifications() async { await MainActor.run { UIApplication.shared.unregisterForRemoteNotifications() } }
}
#endif
