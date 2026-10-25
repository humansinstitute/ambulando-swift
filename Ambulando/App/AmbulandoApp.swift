import SwiftUI

@main
struct AmbulandoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() { Amb.applyControlAppearance() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .tint(Amb.primary)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
                .onAppear { delegate.model.markFirstFrame() }
                .task { await delegate.model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: delegate.model.sceneDidBecomeActive()
            case .background: delegate.model.sceneDidEnterBackground()
            default: break
            }
        }
    }
}
