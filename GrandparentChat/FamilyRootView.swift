import AmbulandoCore
import SwiftUI

/// Sign-in and connection reuse Ambulando's own screens (identity import, PIN lock, Tower connection). After that the app
/// shows one of three things only: setup (choose the family conversation), the conversation, or a plain explanation of
/// why the chosen conversation cannot be used right now. There is no navigation to anything else.
struct FamilyRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(FamilyChatModel.self) private var family

    var body: some View {
        ZStack {
            Amb.background.ignoresSafeArea()
            switch app.phase {
            case .starting:
                ProgressView().controlSize(.large)
            case .failed(let message):
                VStack(spacing: 16) {
                    BrandHeader()
                    FamilyNotice(tone: .error, text: "Local storage could not be opened: \(message)")
                }.padding(24)
            case .ready:
                content
            }
        }
        .fixtureLabel()
        .imageLightboxHost()
        .task(id: "\(app.identity.npub ?? "")-\(app.phase == .ready)") { await family.loadBinding() }
    }

    @ViewBuilder private var content: some View {
        switch app.identity {
        case .locked: LockScreen().readingColumn()
        case .unavailable: IdentityUnavailableView().readingColumn()
        case .none: ImportIdentityView().readingColumn()
        case .unlocked:
            if app.connection == nil { ConnectView().readingColumn() } else { signedIn }
        }
    }

    @ViewBuilder private var signedIn: some View {
        if !family.bindingLoaded {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Opening your family chat…").font(.amb(.title3)).foregroundStyle(Amb.mutedForeground)
            }
        } else if let binding = family.binding {
            BoundChatView(binding: binding)
        } else {
            FamilySetupView().readingColumn()
        }
    }
}

/// The bound conversation, or the reason it cannot be shown. Re-evaluated whenever anything it depends on changes.
private struct BoundChatView: View {
    @Environment(AppModel.self) private var app
    @Environment(FamilyChatModel.self) private var family
    @Environment(\.scenePhase) private var scenePhase
    let binding: FamilyBinding

    var body: some View {
        Group {
            if family.access.canShowConversation {
                FamilyConversationView(binding: binding)
            } else {
                FamilyBlockedView(binding: binding, access: family.access)
            }
        }
        .task(id: trigger) {
            family.activateBoundWorkspace()
            await family.resolvePendingCreation()
            await family.refreshAccess()
        }
        // A live look at Tower when the app comes forward and once the connection is usable, so a removed member,
        // archived or deleted conversation is noticed before anyone writes.
        .task(id: "\(scenePhase == .active)-\(app.canRead)-\(app.selectedWorkspaceId ?? "")") {
            guard scenePhase == .active, app.canRead else { return }
            try? await Task.sleep(for: .milliseconds(600))
            await family.verifyNow()
        }
        .alert("Family Chat", isPresented: Binding(get: { family.notice != nil }, set: { if !$0 { family.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(family.notice ?? "") }
    }

    private var trigger: String {
        [app.identity.npub ?? "", app.connection?.id ?? "", app.selectedWorkspaceId ?? "", String(app.workspaceEntries.count),
         String(app.workspaceEntries.first { $0.workspace.id == binding.workspaceId }?.navigation.loaded ?? false),
         binding.threadId ?? "creating"].joined(separator: "|")
    }
}

/// Why the chosen conversation cannot be shown, in plain words, with only safe ways forward. Nothing is deleted here.
struct FamilyBlockedView: View {
    @Environment(AppModel.self) private var app
    @Environment(FamilyChatModel.self) private var family
    let binding: FamilyBinding
    let access: FamilyAccess
    @State private var confirmChange = false
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: icon).font(.system(size: 56)).foregroundStyle(Amb.warning).accessibilityHidden(true)
                Text(title).font(.amb(.title).weight(.bold)).multilineTextAlignment(.center).foregroundStyle(Amb.foreground)
                Text(message).font(.amb(.title3)).multilineTextAlignment(.center).foregroundStyle(Amb.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 12) {
                    if access != .differentAccount {
                        Button { retry() } label: { Text("Try again") }.buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("family.blocked.retry")
                    }
                    Button { confirmChange = true } label: { Text("Choose a different family chat") }
                        .buttonStyle(.bordered).controlSize(.large).frame(minHeight: Amb.touchTarget)
                        .accessibilityIdentifier("family.blocked.change")
                    Button { showSettings = true } label: { Text("Settings") }
                        .buttonStyle(.bordered).controlSize(.large).frame(minHeight: Amb.touchTarget)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .readingColumn()
        .confirmationDialog("Choose a different family chat?", isPresented: $confirmChange, titleVisibility: .visible) {
            Button("Choose again") { Task { await family.forgetChoice() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Messages and drafts already on this device stay where they are.") }
        .sheet(isPresented: $showSettings) { FamilySettingsView(binding: binding) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("family.blocked")
    }

    private var icon: String {
        switch access {
        case .differentAccount, .differentTower: "person.crop.circle.badge.exclamationmark"
        default: "exclamationmark.bubble"
        }
    }

    private var title: String {
        switch access {
        case .differentAccount: "This is a different account"
        case .differentTower: "This is a different Tower"
        case .workspaceUnavailable: "You can no longer open \(binding.workspaceLabel)"
        case .channelUnavailable: "The \(binding.channelName) channel is not available"
        case .conversationUnavailable: "This family chat is gone"
        default: "Your family chat is not available"
        }
    }

    private var message: String {
        switch access {
        case .differentAccount: "Grandparent Chat was set up with another account. Nothing was changed. Sign in with that account, or choose a family chat for this one."
        case .differentTower: "Your family chat was set up on a different Tower. Nothing was changed."
        case .workspaceUnavailable: "Your account no longer has access to this space. Ask whoever runs it to add you again, or choose a different family chat."
        case .channelUnavailable: "This channel was removed or you no longer have access to it. Ask whoever runs it, or choose a different family chat."
        case .conversationUnavailable: "This conversation was deleted or moved. The app will not pick another one for you. Choose the family chat again to continue."
        default: "Try again in a moment. Your messages are safe on this device."
        }
    }

    private func retry() {
        app.retryConnection()
        Task { await family.verifyNow(); await family.refreshAccess() }
    }
}

extension View {
    /// Identity, setup and explanation screens: a readable column on iPad, the full width on iPhone.
    func readingColumn() -> some View { tabletReadingWidth(620) }
}
