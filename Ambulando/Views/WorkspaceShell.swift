import AmbulandoCore
import SwiftUI

/// Main native navigation, laid out like the web app on a phone: every section has its own navigation stack, and a
/// bottom section bar (sol `.mobile-section-switcher`) stays on every screen, so Chat is always one tap away and no
/// section covers another. Sections are created when first opened and kept, so switching back returns to the same
/// screen, scroll position, Canvas board position and composer draft. The sidebar context is shared by all of them.
struct WorkspaceShell: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("shell.tab") private var storedMode = AppMode.chat.rawValue
    @AppStorage(AppMode.agentsPreference) private var showAgents = false
    @AppStorage(AppMode.contextPreference) private var showContext = false
    @State private var showSettings = false
    @State private var showUnlock = false
    @State private var opened: Set<AppMode> = []

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(AppMode.allCases, id: \.self) { section in
                    if opened.contains(section) || section == model.mode {
                        // Hidden in UIKit (not just transparent): an inactive section keeps its state but is out of
                        // the accessibility tree and hit testing.
                        SectionHost(active: section == model.mode) {
                            sectionView(section)
                                .environment(model)
                                .environment(\.openMention, OpenMentionAction { kind, id in model.openRecord(kind: kind, id: id) })
                        }
                    }
                }
            }
            // A row of its own (not an inset), so no section's content can sit under it. The keyboard simply covers it
            // (the shell ignores the keyboard; each section's host moves its own content, such as the composer, above
            // it), so typing never re-lays-out the shell or the other sections.
            SectionBar(sections: AppMode.visible(agents: showAgents, context: showContext))
        }
        .ignoresSafeArea(.keyboard)
        .overlay {
            if model.sidebarOpen { SidebarDrawer().zIndex(1) }
        }
        // Record mentions in messages and documents open the record in its section and follow its context.
        .environment(\.openMention, OpenMentionAction { kind, id in model.openRecord(kind: kind, id: id) })
        .onAppear {
            let stored = AppMode(stored: storedMode)
            if model.mode != stored { model.mode = stored }
            opened.insert(model.mode)
        }
        .onChange(of: model.mode) { _, mode in
            opened.insert(mode)
            storedMode = mode.rawValue
        }
        // An optional section turned off in Settings while open: Deck takes its place, as on the web.
        .onChange(of: showAgents) { _, on in if !on && model.mode == .agents { model.mode = .deck } }
        .onChange(of: showContext) { _, on in if !on && model.mode == .context { model.mode = .deck } }
        // A new sidebar choice starts the context-bound sections at their root (an open record would belong to the old one).
        .onChange(of: model.contextSelections) { _, _ in model.resetContextSections() }
        // Scopes or channels changed (sync, deletion, lost access): keep the context to what is still visible.
        .onChange(of: model.navigation.value) { _, _ in model.validateContext() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showUnlock) {
            NavigationStack {
                Group {
                    if case .none = model.identity { ImportIdentityView() } else { UnlockView(embedded: true) }
                }
                .background(Amb.background)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showUnlock = false } } }
            }
        }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { showUnlock = false } }
    }

    @ViewBuilder private func sectionView(_ section: AppMode) -> some View {
        @Bindable var model = model
        switch section {
        case .chat:
            ChatStack(showSettings: $showSettings) { banners }
        case .deck:
            SectionStack(section: section, path: $model.deckPath, showSettings: $showSettings, banner: { banners }) {
                workspaceSurface { DeckView(workspace: $0, store: $1) }
            }
        case .tasks:
            SectionStack(section: section, path: $model.tasksPath, showSettings: $showSettings, banner: { banners }) {
                workspaceSurface { TasksView(workspace: $0, store: $1) }
            }
        case .docs:
            SectionStack(section: section, path: $model.docsPath, showSettings: $showSettings, banner: { banners }) {
                workspaceSurface { DocumentsView(workspace: $0, store: $1) }
            }
        case .files:
            SectionStack(section: section, path: $model.filesPath, showSettings: $showSettings, banner: { banners }) {
                workspaceSurface { FilesView(workspace: $0, store: $1) }
            }
        case .agents:
            SectionStack(section: section, path: $model.agentsPath, showSettings: $showSettings, banner: { banners }) {
                workspaceSurface { AgentsView(workspace: $0, store: $1) }
            }
        case .context:
            SectionStack(section: section, path: $model.contextPath, showSettings: $showSettings, banner: { banners }) {
                workspaceSurface { ContextTreeView(workspace: $0, store: $1) }
            }
        case .toolbox:
            SectionStack(section: section, path: $model.toolboxPath, showSettings: $showSettings, contextBar: false, banner: { banners }) {
                workspaceSurface { ToolboxView(workspace: $0, store: $1) }
            }
        }
    }

    @ViewBuilder private var banners: some View {
        FixtureBanner()
        IdentityBanner { showUnlock = true }
    }

    /// A section's root for the selected workspace; a fresh view (and observer) per workspace, so no rows cross over.
    @ViewBuilder private func workspaceSurface<Content: View>(@ViewBuilder _ content: @escaping (WorkspaceRecord, LocalStore) -> Content) -> some View {
        if let workspace = model.selectedWorkspace, let store = model.store {
            content(workspace, store).id(workspace.id)
        } else {
            ContentUnavailableView("No workspace", systemImage: "square.stack.3d.up.slash",
                                   description: Text(model.workspaces.loaded ? "No workspaces for this identity yet." : "Loading saved workspaces…"))
        }
    }
}

/// Hosts one section in its own UIKit view so an inactive section can be hidden without losing its SwiftUI state:
/// navigation stack, scroll positions, Deck card, open board, composer. The hosting view sits inside a plain container
/// and only that child is hidden: SwiftUI manages the representable's own view and does not keep `isHidden` on it, which
/// left inactive sections in the accessibility tree.
struct SectionHost<Content: View>: UIViewControllerRepresentable {
    let active: Bool
    @ViewBuilder let content: () -> Content

    final class Container: UIViewController {
        let host: UIHostingController<Content>
        init(_ root: Content) {
            host = UIHostingController(rootView: root)
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            addChild(host)
            host.view.backgroundColor = .clear
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }

        func show(_ active: Bool) {
            guard host.view.isHidden == active else { return }
            host.view.isHidden = !active
            host.view.accessibilityElementsHidden = !active
            view.isUserInteractionEnabled = active
        }
    }

    func makeUIViewController(context: Context) -> Container {
        let container = Container(content())
        container.loadViewIfNeeded()
        container.show(active)
        return container
    }

    /// Only visibility changes here. The root view is set once: the section observes the model itself, so rebuilding
    /// it on every shell update would re-render every open section (measured: typing stalls of 118–126 ms).
    func updateUIViewController(_ container: Container, context: Context) {
        container.show(active)
    }
}

/// A section's navigation stack. Records opened inside Deck, Agents, Context and Toolbox (and mentions inside them)
/// are pushed here, so Back returns to the same card, outline or board position; the record still follows its own
/// context only when opened from a workspace-wide list.
struct SectionStack<Root: View, Banner: View>: View {
    @Environment(AppModel.self) private var model
    let section: AppMode
    @Binding var path: [WorkRoute]
    @Binding var showSettings: Bool
    var contextBar = true
    @ViewBuilder let banner: () -> Banner
    @ViewBuilder let root: () -> Root

    var body: some View {
        WorkStack(showSettings: $showSettings, path: $path, contextBar: contextBar, banner: banner, root: root)
            .environment(\.pushRoute, PushRouteAction { path.append($0) })
            .modifier(LocalMentions(enabled: [.deck, .agents, .context, .toolbox].contains(section), path: $path))
    }
}

/// In the workspace sections, a mention opens on top of the current screen (Back returns), as the build 7 surfaces did.
private struct LocalMentions: ViewModifier {
    @Environment(AppModel.self) private var model
    let enabled: Bool
    @Binding var path: [WorkRoute]
    func body(content: Content) -> some View {
        if enabled {
            content.environment(\.openMention, OpenMentionAction { kind, id in
                guard let workspace = model.selectedWorkspace?.id else { return }
                let record = id.lowercased()
                switch kind.lowercased() {
                case "task": path.append(.task(workspaceId: workspace, taskId: record))
                case "doc", "document": path.append(.doc(workspaceId: workspace, docId: record))
                case "file": path.append(.file(workspaceId: workspace, fileId: record))
                case "thread": path.append(.threadById(workspaceId: workspace, threadId: record))
                case "channel": path.append(.channel(workspaceId: workspace, channelId: record))
                default: return
                }
            })
        } else {
            content
        }
    }
}

/// The bottom section bar (sol `.mobile-section-switcher`): the web's order and labels, scrolling sideways if the
/// sections do not fit. Tapping the current section returns it to its first screen.
struct SectionBar: View {
    @Environment(AppModel.self) private var model
    let sections: [AppMode]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { buttons(fill: true) }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 0) { buttons(fill: false) } }
        }
        .padding(.top, 2)
        .background(Amb.card.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Amb.border).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
        .accessibilityIdentifier("section.bar")
    }

    @ViewBuilder private func buttons(fill: Bool) -> some View {
        ForEach(sections, id: \.self) { section in
            let active = model.mode == section
            Button {
                if active { model.popToRoot(section) } else { model.show(section) }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: section.systemImage).font(.system(size: 18, weight: active ? .semibold : .regular))
                    Text(section.title).font(.system(size: 10, weight: active ? .semibold : .medium)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(active ? Amb.primary : Amb.mutedForeground)
                .frame(minWidth: 52, maxWidth: fill ? .infinity : nil, minHeight: 46)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(section.title)
            .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
            .accessibilityHint(active ? "Returns to the first screen of \(section.title)" : "")
            .accessibilityIdentifier("section.\(section.rawValue)")
        }
    }
}

private struct ShellToolbar: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    @State private var searching = false
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $searching) {
                if let workspace = model.selectedWorkspace, let store = model.store { SearchView(workspace: workspace, store: store) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SidebarButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        SyncIndicator()
                        Button { searching = true } label: { Image(systemName: "magnifyingglass") }
                            .accessibilityLabel("Search").accessibilityIdentifier("search")
                        // The profile menu (sol `.avatar-menu` button): the signed-in person's avatar or initials.
                        Button { showSettings = true } label: {
                            if let me = model.me.value?.person {
                                PersonAvatar(person: me, size: 28).overlay(Circle().stroke(Amb.border, lineWidth: 1))
                            } else {
                                Image(systemName: "person.crop.circle")
                            }
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityValue(model.me.value?.person.name ?? "")
                        .accessibilityIdentifier("settings")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    /// Sample-data label under the navigation bar of a pushed screen (no-op outside sample-data mode).
    func fixtureLabel() -> some View { safeAreaInset(edge: .top, spacing: 0) { FixtureBanner() } }

    func toolbarItems(showSettings: Binding<Bool>) -> some View { modifier(ShellToolbar(showSettings: showSettings)) }
}

/// Shown on every surface when the app runs on local sample data instead of a Tower.
struct FixtureBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let fixture = model.fixture {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sample data on this iPhone. Not connected to a Tower.").font(.caption.weight(.semibold))
                    .accessibilityIdentifier("fixture.banner")
                if let storm = fixture.stormStatus { Text(storm).font(.caption2.monospaced()).accessibilityIdentifier("fixture.storm") }
                if let launch = model.launchToCachedListMs { Text(String(format: "launch: firstFrameToCachedList=%.0fms", launch)).font(.caption2.monospaced()).accessibilityIdentifier("fixture.launch") }
                if let simulated = fixture.backgroundSimulation { Text(simulated).font(.caption2.monospaced()).accessibilityIdentifier("fixture.background") }
            }
            .foregroundStyle(Amb.warning)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Amb.warningBackground)
        }
    }
}

struct WorkspaceMenu: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Menu {
            ForEach(model.workspaces.value) { workspace in
                Button { model.selectWorkspace(workspace.id) } label: {
                    if workspace.id == model.selectedWorkspace?.id { Label(workspace.label, systemImage: "checkmark") } else { Text(workspace.label) }
                }
            }
            if model.workspaces.value.isEmpty { Text(model.workspaces.loaded ? "No workspaces yet" : "Loading…") }
        } label: {
            HStack(spacing: 8) {
                PassageMark(size: 28)
                Text(model.selectedWorkspace?.label ?? "Ambulando").font(.headline).foregroundStyle(Amb.foreground).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Amb.mutedForeground)
            }
        }
        .accessibilityLabel("Switch workspace")
    }
}

struct SyncIndicator: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if !model.syncStatus.running.isEmpty || !model.syncStatus.queued.isEmpty {
            ProgressView().controlSize(.small).accessibilityLabel("Syncing")
        } else if model.lastSyncError != nil {
            Image(systemName: "exclamationmark.icloud").foregroundStyle(Amb.warning).accessibilityLabel("Sync problem; see Settings")
        }
    }
}

struct IdentityBanner: View {
    @Environment(AppModel.self) private var model
    let action: () -> Void
    var body: some View {
        switch model.identity {
        case .unlocked: EmptyView()
        case .locked:
            Button(action: action) { Notice(tone: .info, text: "Locked — showing saved data. Tap to unlock and sync.") }
                .buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 8)
        case .unavailable:
            Notice(tone: .info, text: "Your identity can't be opened until this iPhone is unlocked. Saved data is shown.")
                .padding(.horizontal, 16).padding(.vertical, 8)
        case .none:
            Button(action: action) { Notice(tone: .warning, text: "No identity on this iPhone. Tap to import one and sync.") }
                .buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}
