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
        #if os(macOS)
        // On the Mac a canvas just pushed opens in its own window instead, so it can sit beside the app (or full screen).
        if case .canvas(let workspace, let canvas)? = path.last {
            canvasWindowRequest = CanvasWindowRoute(workspaceId: workspace, canvasId: canvas)
            return absorbingThreads(Array(path.dropLast()))
        }
        #endif
        guard let focus = path.lazy.compactMap(ThreadFocus.init).last else { return path }
        focusThread(focus)
        return path.filter { ThreadFocus($0) == nil }
    }
}

/// A canvas shown in a Mac window of its own (the window's value, restored with the window).
struct CanvasWindowRoute: Hashable, Codable {
    let workspaceId: String
    let canvasId: String
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

/// A link to a canvas: pushed on the iPhone and iPad; on the Mac it opens the canvas in its own window (a pushed
/// `NavigationLink` would show it in the section even though the model takes it out of the path).
struct CanvasRouteLink<Label: View>: View {
    @Environment(AppModel.self) private var model
    let workspaceId: String
    let canvasId: String
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if os(macOS)
        Button { model.canvasWindowRequest = CanvasWindowRoute(workspaceId: workspaceId, canvasId: canvasId) } label: { label() }
        #else
        NavigationLink(value: WorkRoute.canvas(workspaceId: workspaceId, canvasId: canvasId)) { label() }
        #endif
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
    /// The view is behind the focused thread on the Mac. AppKit views (the composer) read it to leave accessibility too,
    /// since SwiftUI's `accessibilityHidden` does not reach into them.
    @Entry var behindModal = false
}

/// The thread title as the open `ThreadView` reads it, for the focused view's header.
struct ThreadTitleKey: PreferenceKey {
    static let defaultValue = ""
    static func reduce(value: inout String, nextValue: () -> String) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

/// The open `ThreadView`'s root, reference and Autopilot source, for the focused view's header menu.
struct ThreadMenuKey: PreferenceKey {
    static let defaultValue: ThreadMenuContext? = nil
    static func reduce(value: inout ThreadMenuContext?, nextValue: () -> ThreadMenuContext?) {
        if let next = nextValue() { value = next }
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
        let focused = model.focusedThread != nil || model.composingThread
        #if os(iOS)
        content
            .background(BackgroundAccessibility(hidden: focused))
            .fullScreenCover(isPresented: Binding(get: { model.focusedThread != nil }, set: { if !$0 { model.focusedThread = nil } })) {
                ThreadFocusContainer().environment(model)
            }
            .modifier(ThreadFocusLifecycle())
        #else
        content
            .environment(\.behindModal, focused)
            // The app behind stays exactly as it is, only out of reach: no clicks, keyboard or VoiceOver.
            .allowsHitTesting(!focused)
            .accessibilityHidden(focused)
            .overlay {
                // `focused` also includes composingThread: use the actual thread to choose the panel.
                // Otherwise + disables the shell but renders an empty ThreadFocusContainer, trapping input.
                if model.focusedThread != nil { ThreadFocusContainer() }
                else if model.composingThread { NewThreadContainer() }
            }
            .modifier(ThreadFocusLifecycle())
        #endif
    }
}

#if os(iOS)
/// Takes the whole app behind the cover (the window's root view) out of VoiceOver while the thread is open. SwiftUI's
/// `accessibilityHidden` stops at UIKit containers (navigation stacks, split views, text and web views), so it would
/// leave most of the app behind reachable.
private struct BackgroundAccessibility: UIViewRepresentable {
    let hidden: Bool

    final class Coordinator { weak var root: UIView? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let hidden = hidden, coordinator = context.coordinator
        // The probe has a window only once it is on screen.
        DispatchQueue.main.async {
            guard let root = view.window?.rootViewController?.view ?? coordinator.root else { return }
            coordinator.root = root
            if root.accessibilityElementsHidden != hidden { root.accessibilityElementsHidden = hidden }
        }
    }

    /// Locking replaces the shell with the thread still open: give the app back to VoiceOver.
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.root?.accessibilityElementsHidden = false
    }
}
#endif

/// The open thread belongs to one workspace and identity: switching workspace or removing the identity closes it. Locking
/// replaces the whole shell, so the thread is hidden with it and comes back on unlock.
private struct ThreadFocusLifecycle: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content
            .onChange(of: model.selectedWorkspace?.id) { _, id in
                if let focus = model.focusedThread, focus.workspaceId != id { model.focusedThread = nil }
            }
            .onChange(of: model.identity) { _, identity in
                if identity == .none { model.focusedThread = nil; ReadingPositions.shared.removeAll() }
            }
    }
}

/// The backdrop and the card (iPad, Mac) or the full-height screen (iPhone, narrow iPad windows).
private struct ThreadFocusContainer: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    /// Desktop and iPad: the card fills the window (edge to edge, no rounded card) until restored.
    @State private var expanded = false

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
                    ModalCard(expanded: expanded) {
                        ThreadFocusPanel(focus: focus, expanded: $expanded).id(focus.id)
                    }
                    #if os(macOS)
                    .background(ThreadFocusBackdrop { model.focusedThread = nil })
                    #endif
                } else {
                    ThreadFocusPanel(focus: focus, expanded: .constant(false)).id(focus.id)
                }
            }
        }
        #if os(iOS)
        .presentationBackground { if card { ThreadFocusBackdrop { model.focusedThread = nil } } else { Amb.background } }
        // Links open in-app browser tabs above the thread (the shell's own browser cover cannot present over this one).
        .fullScreenCover(isPresented: Binding(get: { model.browser.presented }, set: { model.browser.presented = $0 })) {
            BrowserView().environment(model)
        }
        #endif
    }
}

/// The card (or, expanded, the whole window) both desktop modals share: this thread view and the new thread composer.
struct ModalCard<Content: View>: View {
    let expanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let radius: CGFloat = expanded ? 0 : 14
            content()
                .frame(width: expanded ? proxy.size.width : min(proxy.size.width - 96, 1120),
                       height: expanded ? proxy.size.height : max(proxy.size.height - 40, 320))
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(Amb.border, lineWidth: expanded ? 0 : 1))
                .shadow(color: .black.opacity(expanded ? 0 : 0.28), radius: 28, y: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.18), value: expanded)
        }
    }
}

#if os(macOS)
/// The New thread composer as a window-filling modal (same card, backdrop, expand and outside-click close as a thread).
private struct NewThreadContainer: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        Group {
            if let workspace = model.selectedWorkspace, let store = model.store {
                ModalCard(expanded: expanded) {
                    DeckThreadComposer(workspace: workspace, store: store, expanded: $expanded, onCreated: { focus in
                        model.composingThread = false
                        model.focusThread(focus)
                    })
                }
            }
        }
        .background(ThreadFocusBackdrop { model.composingThread = false })
    }
}
#endif

/// A light dim over the screen the thread was opened from, which stays visible through it. Clicking or tapping outside the
/// card closes the thread; the reader's place in it is kept and the section underneath is untouched.
private struct ThreadFocusBackdrop: View {
    let dismiss: () -> Void
    var body: some View {
        Color.black.opacity(0.22)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: dismiss)
            .accessibilityLabel("Close thread")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("thread.focus.backdrop")
    }
}

/// Header (title, pin, thread menu, full screen, close) above the shared `ThreadView`, whose composer keeps mentions,
/// paste, uploads, the outbox and the stored draft exactly as in a pushed thread.
private struct ThreadFocusPanel: View {
    @Environment(AppModel.self) private var model
    let focus: ThreadFocus
    @Binding var expanded: Bool
    @State private var title = ""
    @State private var menu: ThreadMenuContext?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Amb.background)
        .onPreferenceChange(ThreadTitleKey.self) { title = $0 }
        .onPreferenceChange(ThreadMenuKey.self) { menu = $0 }
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
                // Only this thread's own targets: a context left by another thread is never acted on.
                ThreadHeaderMenu(context: menu?.threadId == focus.threadId ? menu : nil, workspace: workspace)
            }
            #if os(macOS)
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.amb(.body).weight(.semibold))
                    .frame(width: Amb.touchTarget, height: Amb.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Amb.mutedForeground)
            .help(expanded ? "Restore size" : "Full screen")
            .accessibilityLabel(expanded ? "Restore size" : "Expand to full screen")
            .accessibilityIdentifier("thread.focus.expand")
            #endif
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

/// The web's thread menu (sol `.thread-title-menu`) beside pin, full screen and close: Get it done and Copy message for
/// the first message, the thread's Autopilot Link and FD Ref, and Delete message for its author, with the same rules as
/// the message menu. Renaming and archiving a thread stay on the web (the app has no write for them).
private struct ThreadHeaderMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let context: ThreadMenuContext?
    let workspace: WorkspaceRecord
    @State private var gettingItDone: MessageRecord?
    @State private var deleting: MessageRecord?

    private var root: MessageRecord? { context?.root }
    private var liveRoot: MessageRecord? { root.flatMap { $0.deleted ? nil : $0 } }
    private var mine: Bool { liveRoot?.senderNpub != nil && liveRoot?.senderNpub == model.identity.npub }

    private struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        var destructive = false
        let perform: () -> Void
    }

    private var items: [Item] {
        var items: [Item] = []
        if let liveRoot { items.append(Item(id: "getitdone", title: "Get it done", symbol: "checkmark.circle") { gettingItDone = liveRoot }) }
        if let root { items.append(Item(id: "copy", title: "Copy message", symbol: "doc.on.doc") { Pasteboard.copy(MentionCodec.plain(root.body)) }) }
        if let source = context?.autopilotSource {
            items.append(Item(id: "autopilot", title: "Autopilot Link", symbol: "arrow.up.forward.app") { Task { await openAutopilot(source) } })
        }
        if let reference = context?.flightDeckReference {
            items.append(Item(id: "ref", title: "FD Ref", symbol: "link") { Pasteboard.copy(reference) })
        }
        if mine, let liveRoot {
            items.append(Item(id: "delete", title: "Delete message", symbol: "trash", destructive: true) { deleting = liveRoot })
        }
        return items
    }

    var body: some View {
        let items = items
        menuButton(items)
            .disabled(items.isEmpty)
            .help("Thread menu")
            .sheet(item: $gettingItDone) { GetItDoneSheet(message: $0, workspace: workspace) }
            .confirmationDialog("Delete this message for everyone?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { message in
                Button("Delete", role: .destructive) {
                    model.submit(WriteIntent(kind: .messageDelete, targetId: message.id, payload: ["row_version": message.rowVersion]), in: workspace)
                }
            }
    }

    @ViewBuilder private func menuButton(_ items: [Item]) -> some View {
        #if os(macOS)
        // The message menu's stable AppKit button: the menu is built only when opened, never on every sync.
        NativeMessageActions(items: items.map { item in NativeMessageAction(item.title, item.symbol, perform: item.perform) },
                             identifier: "thread.focus.actions", label: "Thread menu", help: "Opens the thread menu")
            .frame(width: Amb.touchTarget, height: Amb.touchTarget)
        #else
        Menu {
            ForEach(items) { item in
                Button(role: item.destructive ? .destructive : nil, action: item.perform) { Label(item.title, systemImage: item.symbol) }
                    .accessibilityIdentifier("thread.menu.\(item.id)")
            }
        } label: {
            Image(systemName: "ellipsis").font(.amb(.body).weight(.semibold))
                .frame(width: Amb.touchTarget, height: Amb.touchTarget)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Amb.mutedForeground)
        .accessibilityLabel("Thread menu")
        .accessibilityIdentifier("thread.focus.actions")
        #endif
    }

    private func openAutopilot(_ message: MessageRecord) async {
        guard let url = await model.autopilotURL(for: message, in: workspace) else {
            model.notice = "This workspace has no Autopilot address to open this session."
            return
        }
        openURL(url)
    }
}
