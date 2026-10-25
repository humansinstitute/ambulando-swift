import AmbulandoCore
import SwiftUI

/// The Mac's main window: a sidebar with the sections and the shared Workspace → Scope → Channel navigation (the same
/// content as the iPhone's drawer), and the current section beside it. Each section keeps its navigation path in the
/// model, so switching sections returns to the same record; only the visible section is drawn, so its toolbar is the
/// window's toolbar.
struct MacWorkspaceShell: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUI.self) private var ui
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("shell.tab") private var storedMode = AppMode.chat.rawValue
    @AppStorage(AppMode.agentsPreference) private var showAgents = false
    @AppStorage(AppMode.contextPreference) private var showContext = false

    var body: some View {
        @Bindable var ui = ui
        // Keep split-view membership and the detail hosting view stable while the sidebar is hidden.
        // Removing/reinserting a child during a resize churns AppKit's constraint hierarchy and the live naplets.
        HSplitView {
            MacSidebar()
                .frame(minWidth: ui.sidebarVisible ? 240 : 0,
                       idealWidth: ui.sidebarVisible ? 280 : 0,
                       maxWidth: ui.sidebarVisible ? 380 : 0)
                .clipped()
                .opacity(ui.sidebarVisible ? 1 : 0)
                .allowsHitTesting(ui.sidebarVisible)
                .accessibilityHidden(!ui.sidebarVisible)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button { ui.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.plain).padding(10)
                        .accessibilityLabel(ui.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                        .accessibilityIdentifier("sidebar.toggle")
                    MacSectionBar(sections: AppMode.visible(agents: showAgents, context: showContext))
                }.background(Amb.card)
                Divider()
                sectionView(model.mode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.openMention, OpenMentionAction { kind, id in model.openRecord(kind: kind, id: id) })
        }
        // HTTPS links open as tabs in the browser window; record mentions open the record in its section.
        .environment(\.openURL, OpenURLAction { model.browser.handleLink($0) })
        .environment(\.openMention, OpenMentionAction { kind, id in model.openRecord(kind: kind, id: id) })
        .onChange(of: model.browser.presented) { _, shown in if shown { openWindow(id: MacWindow.browser) } }
        // The context bar's "open navigation" on the Mac reveals the sidebar column.
        .onChange(of: model.sidebarOpen) { _, open in
            guard open else { return }
            ui.sidebarVisible = true
            model.sidebarOpen = false
        }
        .onAppear {
            let stored = AppMode(stored: storedMode)
            if model.mode != stored { model.mode = stored }
        }
        .onChange(of: model.mode) { _, mode in storedMode = mode.rawValue }
        .onChange(of: showAgents) { _, on in if !on && model.mode == .agents { model.mode = .deck } }
        .onChange(of: showContext) { _, on in if !on && model.mode == .context { model.mode = .deck } }
        .onChange(of: model.contextSelections) { _, _ in model.resetContextSections() }
        .onChange(of: model.navigation.value) { _, _ in model.validateContext() }
        .sheet(isPresented: $ui.showSettings) {
            // No taller minimum than the smallest window: the form scrolls inside the sheet.
            SettingsView().frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 760)
        }
        .sheet(isPresented: $ui.showSearch) {
            if let workspace = model.selectedWorkspace, let store = model.store {
                SearchView(workspace: workspace, store: store).frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 680)
            }
        }
        .sheet(isPresented: $ui.showUnlock) {
            NavigationStack {
                Group {
                    if case .none = model.identity { ImportIdentityView() } else { UnlockView(embedded: true) }
                }
                .background(Amb.background)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { ui.showUnlock = false } } }
            }
            .frame(minWidth: 480, minHeight: 420)
        }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { ui.showUnlock = false } }
    }

    @ViewBuilder private func sectionView(_ section: AppMode) -> some View {
        @Bindable var model = model
        @Bindable var ui = ui
        switch section {
        case .chat:
            ChatStack(showSettings: $ui.showSettings) { banners }
        case .deck:
            SectionStack(section: section, path: $model.deckPath, showSettings: $ui.showSettings, banner: { banners }) {
                workspaceSurface { DeckView(workspace: $0, store: $1) }
            }
        case .tasks:
            SectionStack(section: section, path: $model.tasksPath, showSettings: $ui.showSettings, banner: { banners }) {
                workspaceSurface { TasksView(workspace: $0, store: $1) }
            }
        case .docs:
            SectionStack(section: section, path: $model.docsPath, showSettings: $ui.showSettings, banner: { banners }) {
                workspaceSurface { DocumentsView(workspace: $0, store: $1) }
            }
        case .files:
            SectionStack(section: section, path: $model.filesPath, showSettings: $ui.showSettings, banner: { banners }) {
                workspaceSurface { FilesView(workspace: $0, store: $1) }
            }
        case .agents:
            SectionStack(section: section, path: $model.agentsPath, showSettings: $ui.showSettings, banner: { banners }) {
                workspaceSurface { AgentsView(workspace: $0, store: $1) }
            }
        case .context:
            SectionStack(section: section, path: $model.contextPath, showSettings: $ui.showSettings, banner: { banners }) {
                workspaceSurface { ContextTreeView(workspace: $0, store: $1) }
            }
        case .toolbox:
            SectionStack(section: section, path: $model.toolboxPath, showSettings: $ui.showSettings, contextBar: false, banner: { banners }) {
                workspaceSurface { ToolboxView(workspace: $0, store: $1) }
            }
        }
    }

    @ViewBuilder private var banners: some View {
        FixtureBanner()
        IdentityBanner { ui.showUnlock = true }
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

/// Workspace navigation stays in the sidebar; product sections sit above every detail surface.
struct MacSidebar: View {
    var body: some View { SidebarContent().background(Amb.card) }
}

/// The section bar is a plain row, not a horizontal `ScrollView`: on macOS that scroll view swallowed real mouse clicks
/// on its plain buttons (accessibility presses still worked), so the bar looked dead. When the labelled row does not
/// fit, the same buttons show icons only (with the name as tooltip and accessibility label).
struct MacSectionBar: View {
    @Environment(AppModel.self) private var model
    let sections: [AppMode]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(labelled: true)
            row(labelled: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading).background(Amb.card)
        .accessibilityElement(children: .contain).accessibilityLabel("Sections").accessibilityIdentifier("section.bar")
    }

    private func row(labelled: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(sections, id: \.self) { section in
                let selected = model.mode == section
                Button {
                    if selected { model.popToRoot(section) } else { model.show(section) }
                } label: {
                    Group {
                        if labelled { Label(section.title, systemImage: section.systemImage) } else { Image(systemName: section.systemImage) }
                    }
                    .font(.amb(.subheadline).weight(selected ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(selected ? Amb.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    // The whole pill is clickable, not only the glyphs.
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(section.title)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier("section.\(section.rawValue)")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(8)
    }
}
