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
                    if model.connection != nil { workspaceShell } else { ConnectView().onboardingWidth() }
                case .none:
                    if model.connection != nil { workspaceShell } else { ImportIdentityView().onboardingWidth() }
                }
            }
        }
        // Images open large over the window (the web's image modal) on the Mac.
        .overlay {
            #if DEBUG
            if model.fixture != nil, ProcessInfo.processInfo.arguments.contains("-AmbulandoRichMessageLayoutFixture") {
                RichMessageLayoutFixture()
            }
            #endif
        }
        .imageLightboxHost()
        .pushTapOutcomeAlert()
    }

    private var workspaceShell: some View {
        // Keep the shell (and its selection-sheet presenter) mounted when the last workspace pauses.
        // Removing a presenter during its checkbox action can tear down UIKit's sheet hierarchy mid-transition.
        Shell().threadFocusPresenter()
            .overlay {
                if !model.workspaceEntries.isEmpty && model.enabledWorkspaceEntries.isEmpty {
                    WorkspaceSelectionEmptyState()
                        .accessibilityAddTraits(.isModal)
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

private extension View {
    /// Why a tapped alert opened nothing, shown over whichever screen is up (workspace, lock or connect).
    func pushTapOutcomeAlert() -> some View { modifier(PushTapOutcomeAlert()) }
}

private struct PushTapOutcomeAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.alert("Notification", isPresented: Binding(get: { model.pushTapOutcome != nil }, set: { if !$0 { model.pushTapOutcome = nil } }),
                      presenting: model.pushTapOutcome) { _ in
            Button("OK", role: .cancel) {}
        } message: { outcome in
            Text(outcome.message)
        }
    }
}
