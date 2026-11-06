import AmbulandoCore
import BackgroundTasks
import UIKit
import UserNotifications

/// Owns the shared `AppModel` and the family chat state on it. Only the iOS entry points the app uses are kept:
/// background refresh (so queued messages and new replies keep moving), background transfer events, and a notification
/// delegate whose every tap and banner is filtered through the bound conversation.
final class GrandparentAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor let model = AppModel()
    @MainActor lazy var family = FamilyChatModel(app: model)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let model = model
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Product.refreshTaskIdentifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in Self.run(refresh, model: model) }
        }
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// The bound conversation is the only screen, so an alert that arrives while the app is open is never shown on top of it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isDefaultTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let payload = try? PushPayload.parse(userInfo: response.notification.request.content.userInfo)
        nonisolated(unsafe) let complete = completionHandler
        Task { @MainActor in
            complete()
            // Never AppModel's own tap handling: it can open any record. The family model only recognises its conversation.
            if isDefaultTap { await model.start(); family.handleTap(payload) }
        }
    }

    @MainActor
    private static func run(_ task: BGAppRefreshTask, model: AppModel) {
        model.scheduleBackgroundRefresh()
        let work = Task { @MainActor in
            await model.start()
            let report = await model.runBackgroundRefresh(budget: .seconds(25))
            task.setTaskCompleted(success: report.result == .completed || report.result == .skippedLocked)
        }
        task.expirationHandler = { work.cancel() }
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            await model.start()
            model.transferBackend?.setEventsCompletion(completionHandler)
        }
    }
}
