import SwiftUI

@main
struct AmbulandoApp: App {
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Amb.primary)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground resume refreshes from the local cursor-less read path; background work is WP5.
            if phase == .active { model.refresh(force: false) }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Amb.background.ignoresSafeArea()
            switch model.phase {
            case .starting:
                ProgressView().controlSize(.large)
            case .failed(let message):
                VStack(spacing: 16) {
                    BrandHeader()
                    Notice(tone: .error, text: "Local storage could not be opened: \(message)")
                }.padding(24)
            case .ready:
                if model.connection != nil {
                    WorkspaceShell()
                } else {
                    switch model.identity {
                    case .none: ImportIdentityView()
                    case .locked: UnlockView()
                    case .unlocked: ConnectView()
                    }
                }
            }
        }
    }
}
