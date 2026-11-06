import SwiftUI

@main
struct GrandparentChatApp: App {
    @UIApplicationDelegateAdaptor(GrandparentAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FamilyTextSize.defaultsKey) private var textSize = FamilyTextSize.device.rawValue

    init() { Amb.applyControlAppearance() }

    var body: some Scene {
        WindowGroup {
            FamilyRootView()
                .environment(delegate.model)
                .environment(delegate.family)
                .tint(Amb.primary)
                .dynamicTypeSize(FamilyTextSize(rawValue: textSize)?.range ?? FamilyTextSize.device.range)
                .onAppear { delegate.model.markFirstFrame() }
                .task { await delegate.model.start() }
                // The app has no links of its own. Anything that arrives as a URL is ignored: it can never open another place.
                .onOpenURL { _ in }
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
