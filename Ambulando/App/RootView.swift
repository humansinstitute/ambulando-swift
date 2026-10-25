import SwiftUI

/// Startup, lock, import and connect screens, then the platform's workspace shell (iPhone: bottom sections and a
/// drawer; Mac: a sidebar window).
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
                switch model.identity {
                case .locked:
                    // Whenever an existing identity is locked: a full-screen unlock instead of a workspace that cannot
                    // sync. The selected workspace, navigation, drafts and unsent messages are kept for when it opens.
                    LockScreen().onboardingWidth()
                case .unavailable:
                    // An identity exists but cannot be read yet (started while the device was locked). Never an import.
                    IdentityUnavailableView().onboardingWidth()
                case .unlocked:
                    if model.connection != nil { Shell() } else { ConnectView().onboardingWidth() }
                case .none:
                    if model.connection != nil { Shell() } else { ImportIdentityView().onboardingWidth() }
                }
            }
        }
    }
}

private extension View {
    /// Identity and connection screens: a readable column in a Mac window; the full width on the iPhone.
    func onboardingWidth() -> some View {
        #if os(iOS)
        tabletReadingWidth(620)
        #else
        frame(maxWidth: 620).frame(maxWidth: .infinity)
        #endif
    }
}

#if os(iOS)
private typealias Shell = WorkspaceShell
#else
private typealias Shell = MacWorkspaceShell
#endif
