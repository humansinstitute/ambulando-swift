import AmbulandoCore
import SwiftUI

/// Main native navigation: workspace switcher + tab bar. Every list renders from the local store.
struct WorkspaceShell: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("shell.tab") private var storedMode = AppMode.chat
    @State private var showSettings = false
    @State private var showUnlock = false
    @State private var inboxPath: [WorkRoute] = []
    @State private var tasksPath: [WorkRoute] = []
    @State private var docsPath: [WorkRoute] = []
    @State private var filesPath: [WorkRoute] = []

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.mode) {
            // Inbox spans the workspace on purpose; each item says where it is and opening it follows its context.
            WorkStack(showSettings: $showSettings, path: $inboxPath, contextBar: false, banner: { banners }) {
                workspaceSurface { InboxView(workspace: $0, store: $1) }
            }
            .tabItem { Label("Inbox", systemImage: "tray") }.tag(AppMode.inbox)
            ChatStack(showSettings: $showSettings) { banners }
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag(AppMode.chat)
            WorkStack(showSettings: $showSettings, path: $tasksPath, banner: { banners }) {
                workspaceSurface { TasksView(workspace: $0, store: $1) }
            }
            .tabItem { Label("Tasks", systemImage: "checklist") }.tag(AppMode.tasks)
            WorkStack(showSettings: $showSettings, path: $docsPath, banner: { banners }) {
                workspaceSurface { DocumentsView(workspace: $0, store: $1) }
            }
            .tabItem { Label("Docs", systemImage: "doc.text") }.tag(AppMode.docs)
            WorkStack(showSettings: $showSettings, path: $filesPath, banner: { banners }) {
                workspaceSurface { FilesView(workspace: $0, store: $1) }
            }
            .tabItem { Label("Files", systemImage: "folder") }.tag(AppMode.files)
        }
        .overlay {
            if model.sidebarOpen { SidebarDrawer().zIndex(1) }
        }
        // Record mentions in messages and documents open the record in its mode and follow its context.
        .environment(\.openMention, OpenMentionAction { kind, id in openRecord(kind: kind, id: id) })
        .onAppear { if model.mode != storedMode { model.mode = storedMode } }
        .onChange(of: model.mode) { _, mode in storedMode = mode }
        // A workspace switch starts every work tab at its root (routes carry their workspace anyway).
        .onChange(of: model.selectedWorkspace?.id) { _, _ in inboxPath = []; tasksPath = []; docsPath = []; filesPath = [] }
        // A new context starts the context-bound modes at their root (an open record would belong to the old one).
        .onChange(of: model.contextSelections) { _, _ in tasksPath = []; docsPath = []; filesPath = [] }
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

    /// Opens a mentioned record. People and agents have no native profile screen yet, so their mentions stay styled text.
    private func openRecord(kind: String, id: String) {
        guard let workspace = model.selectedWorkspace?.id else { return }
        let record = id.lowercased()
        switch kind.lowercased() {
        case "task":
            model.mode = .tasks; tasksPath.append(.task(workspaceId: workspace, taskId: record))
        case "doc", "document":
            model.mode = .docs; docsPath.append(.doc(workspaceId: workspace, docId: record))
        case "file":
            model.mode = .files; filesPath.append(.file(workspaceId: workspace, fileId: record))
        case "channel":
            model.adoptContext(for: .channel(workspaceId: workspace, channelId: record)); model.mode = .chat
        case "thread":
            model.openThreadMention(record)
        default:
            return
        }
        if ["task", "doc", "document", "file"].contains(kind.lowercased()) {
            model.adoptContext(for: kind.lowercased() == "task" ? .task(workspaceId: workspace, taskId: record)
                               : kind.lowercased() == "file" ? .file(workspaceId: workspace, fileId: record) : .doc(workspaceId: workspace, docId: record))
        }
    }

    @ViewBuilder private var banners: some View {
        FixtureBanner()
        IdentityBanner { showUnlock = true }
    }

    /// A tab's root for the selected workspace; a fresh view (and observer) per workspace, so no rows cross over.
    @ViewBuilder private func workspaceSurface<Content: View>(@ViewBuilder _ content: @escaping (WorkspaceRecord, LocalStore) -> Content) -> some View {
        if let workspace = model.selectedWorkspace, let store = model.store {
            content(workspace, store).id(workspace.id)
        } else {
            ContentUnavailableView("No workspace", systemImage: "square.stack.3d.up.slash",
                                   description: Text(model.workspaces.loaded ? "No workspaces for this identity yet." : "Loading saved workspaces…"))
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
                        Button { showSettings = true } label: { Image(systemName: "person.crop.circle") }
                            .accessibilityLabel("Settings")
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
