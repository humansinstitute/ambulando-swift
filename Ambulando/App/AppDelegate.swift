import AmbulandoCore
import BackgroundTasks
import UIKit
import UserNotifications

/// Owns the one `AppModel` and the iOS entry points SwiftUI does not cover: BackgroundTasks registration (which must
/// happen before launch finishes) and background `URLSession` event delivery.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshTaskIdentifier = "studio.otherstuff.ambulando.native.refresh"

    @MainActor let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let model = model
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in Self.run(refresh, model: model) }
        }
        // The delegate must be set before launch finishes so a tap that cold-started the app is delivered to it.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // The fixed window starts before storage/credential startup, so a cold push cannot spend 25 seconds twice.

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let payload = try? PushPayload.parse(userInfo: userInfo) else { completionHandler(.noData); return }
        let target = payload.taskId ?? payload.docId ?? payload.threadId ?? payload.channelId ?? payload.notificationId ?? "workspace"
        let key = "\(payload.origin.url.absoluteString):\(payload.workspaceId):\(target)"
        var allowance = UIBackgroundTaskIdentifier.invalid
        allowance = application.beginBackgroundTask(withName: "ambulando.push-refresh") { [model] in
            model.pushRefreshWindow.cancel()
        }
        model.pushRefreshWindow.submit(key: key, event: payload.outboxEventId ?? payload.changeSeq.map(String.init), work: { [model] in
            await model.refreshFromPush(payload)
        }, completion: { result in
            if allowance != .invalid { application.endBackgroundTask(allowance); allowance = .invalid }
            switch result {
            case .newData: completionHandler(.newData)
            case .noData: completionHandler(.noData)
            case .failed: completionHandler(.failed)
            }
        })
    }

    // MARK: Alerts (APNs)

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await model.pushTokenReceived(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in await model.pushRegistrationFailed(error) }
    }

    /// An alert arriving while the app is open: no second banner for the resource already on screen; anything else is
    /// shown by the OS alert channel exactly as it would be in the background.
    ///
    /// Both callbacks use the completion-handler form and call it on the main actor. The `async` form completes UIKit's
    /// callback (a state-restoration snapshot) from wherever the method returns, and off the main thread that aborts the
    /// app: build 29 crashed on every notification tap that way. Only Sendable values (the parsed ids) leave this method.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let payload = try? PushPayload.parse(userInfo: notification.request.content.userInfo)
        nonisolated(unsafe) let complete = completionHandler
        Task { @MainActor in
            let suppress = PushPresentation.foreground(payload, viewing: model.viewedPushDestination) == .suppress
            complete(suppress ? [] : [.banner, .list, .sound])
        }
    }

    /// A tap, from a cold start or while running. Only the parsed ids are used; the item is fetched again after unlock.
    /// The system's completion is called at once (on the main actor); the tap is resolved afterwards.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isDefaultTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let payload = try? PushPayload.parse(userInfo: response.notification.request.content.userInfo)
        nonisolated(unsafe) let complete = completionHandler
        Task { @MainActor in
            complete()
            if isDefaultTap { await model.handlePushTap(payload) }
        }
    }

    /// One opportunistic refresh window: the next one is requested first, the work runs the normal sync pipeline, and
    /// the OS expiration handler cancels it. `setTaskCompleted` is called exactly once.
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
