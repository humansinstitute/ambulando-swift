import AmbulandoCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A conversation opened in the focused thread view, like the web's thread modal: on iPad and Mac a large centred card over
/// the dimmed, inactive app; on the iPhone a full-height screen. It never joins a section's navigation path, so closing
/// returns to exactly the section, channel position, Deck card or board it was opened from.
///
/// It is a plain value in `AppModel.focusedThread`. Sync never replaces it, so a background update cannot dismiss or
/// recreate the open thread. A thread known only by id (a pin, a mention, a canvas naplet) resolves its channel itself.
struct ThreadFocus: Hashable, Identifiable, Codable {
    let workspaceId: String
    let channelId: String?
    let threadId: String

    var id: String { "\(workspaceId):\(threadId)" }

    init(workspaceId: String, channelId: String?, threadId: String) {
        self.workspaceId = workspaceId
        self.channelId = channelId
        self.threadId = threadId
    }

    init?(_ route: ChatRoute) {
        guard case .thread(let w, let c, let t) = route else { return nil }
        self.init(workspaceId: w, channelId: c, threadId: t)
    }

    init?(_ route: WorkRoute) {
        switch route {
        case .thread(let w, let c, let t): self.init(workspaceId: w, channelId: c, threadId: t)
        case .threadById(let w, let t): self.init(workspaceId: w, channelId: nil, threadId: t)
        default: return nil
        }
    }

    /// The Chat route kept for relaunch (only when the channel is known).
    var chatRoute: ChatRoute? { channelId.map { .thread(workspaceId: workspaceId, channelId: $0, threadId: threadId) } }
}

extension AppModel {
    /// Opens a conversation in the focused thread view over the current screen.
    func focusThread(_ focus: ThreadFocus) {
        guard focus.workspaceId == selectedWorkspace?.id ?? selectedWorkspaceId else { return }
        sidebarOpen = false
        focusedThread = focus
    }

    /// A section's navigation path with any conversation taken out and opened in the focused thread view instead: every
    /// push (a link, a Deck row, a mention, a canvas naplet) shows threads the same way.
    func absorbingThreads(_ path: [WorkRoute]) -> [WorkRoute] {
        guard let focus = path.lazy.compactMap(ThreadFocus.init).last else { return path }
        focusThread(focus)
        return path.filter { ThreadFocus($0) == nil }
    }
}

/// A link to a navigation route that opens conversations in the focused thread view and pushes anything else. A plain
/// `NavigationLink` cannot be used for conversations: the stack pushes it even when the model takes it out of the path.
struct ThreadRouteLink<Route: Hashable, Label: View>: View {
    @Environment(AppModel.self) private var model
    let route: Route
    let focus: ThreadFocus?
    let label: Label

    var body: some View {
        if let focus {
            Button { model.focusThread(focus) } label: { label.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: route) { label }
        }
    }
}

extension ThreadRouteLink where Route == WorkRoute {
    init(route: WorkRoute, @ViewBuilder label: () -> Label) {
        self.init(route: route, focus: ThreadFocus(route), label: label())
    }
}

extension ThreadRouteLink where Route == ChatRoute {
    init(route: ChatRoute, @ViewBuilder label: () -> Label) {
        self.init(route: route, focus: ThreadFocus(route), label: label())
    }
}

/// Opens a conversation in the focused thread view. Search's sheet overrides it on the iPhone and iPad so the thread is
/// presented once the sheet has gone.
struct FocusThreadAction: Sendable {
    let handler: @MainActor @Sendable (ThreadFocus) -> Void
    @MainActor func callAsFunction(_ focus: ThreadFocus) { handler(focus) }
}

extension EnvironmentValues {
    @Entry var focusThread: FocusThreadAction? = nil
}

/// The thread title as the open `ThreadView` reads it, for the focused view's header.
struct ThreadTitleKey: PreferenceKey {
    static let defaultValue = ""
    static func reduce(value: inout String, nextValue: () -> String) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

// MARK: Presentation

extension View {
    /// Presents `AppModel.focusedThread` over the workspace shell (applied once, around the platform shell).
    func threadFocusPresenter() -> some View { modifier(ThreadFocusPresenter()) }
}

private struct ThreadFocusPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let focused = model.focusedThread != nil
        #if os(iOS)
        content
            .fullScreenCover(isPresented: Binding(get: { model.focusedThread != nil }, set: { if !$0 { model.focusedThread = nil } })) {
                ThreadFocusContainer().environment(model)
            }
            .modifier(ThreadFocusLifecycle())
            .accessibilityHidden(focused)
        #else
        content
            // The app behind stays exactly as it is, only out of reach: no clicks, keyboard or VoiceOver.
            .allowsHitTesting(!focused)
            .accessibilityHidden(focused)
            .overlay { if focused { ThreadFocusContainer() } }
            .modifier(ThreadFocusLifecycle())
        #endif
    }
}

/// The open thread belongs to one workspace and identity: switching workspace or removing the identity closes it. Locking
/// replaces the whole shell, so the thread is hidden with it and comes back on unlock.
private struct ThreadFocusLifecycle: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content
            .onChange(of: model.selectedWorkspace?.id) { _, id in
                if let focus = model.focusedThread, focus.workspaceId != id { model.focusedThread = nil }
            }
            .onChange(of: model.identity) { _, identity in if identity == .none { model.focusedThread = nil } }
    }
}

/// The backdrop and the card (iPad, Mac) or the full-height screen (iPhone, narrow iPad windows).
private struct ThreadFocusContainer: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var card: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
        #else
        true
        #endif
    }

    var body: some View {
        Group {
            if let focus = model.focusedThread {
                if card {
                    GeometryReader { proxy in
                        ThreadFocusPanel(focus: focus)
                            .id(focus.id)
                            .frame(width: min(proxy.size.width - 96, 1120), height: max(proxy.size.height - 40, 320))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Amb.border, lineWidth: 1))
                            .shadow(color: .black.opacity(0.28), radius: 28, y: 10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    #if os(macOS)
                    .background(ThreadFocusBackdrop())
                    #endif
                } else {
                    ThreadFocusPanel(focus: focus).id(focus.id)
                }
            }
        }
        #if os(iOS)
        .presentationBackground { if card { ThreadFocusBackdrop() } else { Amb.background } }
        // Links open in-app browser tabs above the thread (the shell's own browser cover cannot present over this one).
        .fullScreenCover(isPresented: Binding(get: { model.browser.presented }, set: { model.browser.presented = $0 })) {
            BrowserView().environment(model)
        }
        #endif
    }
}

/// The dimmed, blurred app behind the card. It takes every tap so nothing behind can be used; it does not close the
/// thread, so a stray tap never loses the reader's place.
private struct ThreadFocusBackdrop: View {
    var body: some View {
        Rectangle().fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.32))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {}
            .accessibilityHidden(true)
    }
}

/// Header (title, pin, close) above the shared `ThreadView`, whose composer keeps mentions, paste, uploads, the outbox
/// and the stored draft exactly as in a pushed thread.
private struct ThreadFocusPanel: View {
    @Environment(AppModel.self) private var model
    let focus: ThreadFocus
    @State private var title = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Amb.background)
        .onPreferenceChange(ThreadTitleKey.self) { title = $0 }
        // A mentioned conversation replaces this one; any other record closes the thread and opens in its section.
        .environment(\.openMention, OpenMentionAction { [model] kind, id in
            if kind.lowercased() == "thread" {
                model.focusThread(ThreadFocus(workspaceId: focus.workspaceId, channelId: nil, threadId: id.lowercased()))
            } else {
                model.focusedThread = nil
                model.openRecord(kind: kind, id: id)
            }
        })
        // Typing must go to this thread, not to a composer left focused behind it.
        #if os(macOS)
        .onExitCommand { close() }
        .onAppear { NSApp.keyWindow?.makeFirstResponder(nil) }
        #else
        .onAppear { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("thread.focus")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(Amb.mutedForeground).accessibilityHidden(true)
            Text(title.isEmpty ? "Thread" : title)
                .font(.amb(.headline)).foregroundStyle(Amb.foreground).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("thread.focus.title")
            Spacer(minLength: 8)
            if let workspace = model.selectedWorkspace, workspace.id == focus.workspaceId {
                PinToggleButton(type: .thread, id: focus.threadId, workspace: workspace)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.amb(.body).weight(.semibold))
                    .frame(width: Amb.touchTarget, height: Amb.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Amb.foreground)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("thread.focus.close")
        }
        .padding(.leading, 18).padding(.trailing, 6).padding(.vertical, 4)
        .background(Amb.card)
    }

    @ViewBuilder private var content: some View {
        if let workspace = model.selectedWorkspace, workspace.id == focus.workspaceId, let store = model.store, let connection = model.connection {
            if let channelId = focus.channelId {
                ThreadView(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: channelId, threadId: focus.threadId),
                           workspace: workspace, store: store)
            } else {
                ThreadByIdView(threadId: focus.threadId, workspace: workspace, store: store, connectionId: connection.id)
            }
        } else {
            ContentUnavailableView("Not in this workspace", systemImage: "arrow.uturn.backward",
                                   description: Text("This conversation belongs to another workspace."))
        }
    }

    private func close() { model.focusedThread = nil }
}
