import AmbulandoCore
import BackgroundTasks
import UIKit

/// Owns the one `AppModel` and the iOS entry points SwiftUI does not cover: BackgroundTasks registration (which must
/// happen before launch finishes) and background `URLSession` event delivery.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTaskIdentifier = "studio.otherstuff.ambulando.native.refresh"

    @MainActor let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let model = model
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in Self.run(refresh, model: model) }
        }
        return true
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
