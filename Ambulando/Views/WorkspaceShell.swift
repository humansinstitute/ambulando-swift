import AmbulandoCore
import SwiftUI

/// Main native navigation: workspace switcher + tab bar. Every list renders from the local store.
struct WorkspaceShell: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("shell.tab") private var tab = Tab.chat
    @State private var showSettings = false
    @State private var showUnlock = false

    enum Tab: String { case inbox, chat, tasks, docs, files }

    var body: some View {
        TabView(selection: $tab) {
            surface(.inbox) { PlannedSurfaceView(title: "Inbox", systemImage: "tray",
                                                 detail: "Mentions, assigned tasks and unread conversations will collect here, read from local storage.") }
                .tabItem { Label("Inbox", systemImage: "tray") }.tag(Tab.inbox)
            ChatStack(showSettings: $showSettings) { banners }
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag(Tab.chat)
            surface(.tasks) { PlannedSurfaceView(title: "Tasks", systemImage: "checklist",
                                                 detail: "Task lists, board columns, state changes and comments.") }
                .tabItem { Label("Tasks", systemImage: "checklist") }.tag(Tab.tasks)
            surface(.docs) { PlannedSurfaceView(title: "Documents", systemImage: "doc.text",
                                                detail: "Markdown reading, editing and comments.") }
                .tabItem { Label("Docs", systemImage: "doc.text") }.tag(Tab.docs)
            surface(.files) { PlannedSurfaceView(title: "Files", systemImage: "folder",
                                                 detail: "Folders, previews, downloads and uploads.") }
                .tabItem { Label("Files", systemImage: "folder") }.tag(Tab.files)
        }
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

    @ViewBuilder private var banners: some View {
        FixtureBanner()
        IdentityBanner { showUnlock = true }
    }

    private func surface<Content: View>(_ tab: Tab, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                banners
                content()
            }
            .background(Amb.background)
            .toolbarItems(showSettings: $showSettings)
        }
    }
}

private struct ShellToolbar: ViewModifier {
    @Binding var showSettings: Bool
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { WorkspaceMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        SyncIndicator()
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
        case .none:
            Button(action: action) { Notice(tone: .warning, text: "No identity on this iPhone. Tap to import one and sync.") }
                .buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

/// Honest placeholder for a surface that is not in this build yet (see docs/parity-matrix.md).
struct PlannedSurfaceView: View {
    let title: String
    let systemImage: String
    let detail: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text("\(title) is not available in this build yet. It is coming in a later update.\n\(detail)")
        }
        .foregroundStyle(Amb.mutedForeground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
