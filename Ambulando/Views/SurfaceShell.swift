import AmbulandoCore
import SwiftUI

/// A workspace surface over the tabs: its own navigation stack (records opened from it are pushed here, so going back
/// returns to the same board position or outline), the shared toolbar, sidebar and Scope | Channel context.
struct SurfaceStack: View {
    @Environment(AppModel.self) private var model
    let surface: Surface
    @Binding var showSettings: Bool
    @State private var path: [WorkRoute] = []

    var body: some View {
        WorkStack(showSettings: $showSettings, path: $path, contextBar: surface != .canvas, banner: { FixtureBanner() }) {
            Group {
                if let workspace = model.selectedWorkspace, let store = model.store {
                    root(workspace, store).id(workspace.id)
                } else {
                    EmptyNote(title: "No workspace", systemImage: "square.stack.3d.up.slash", detail: "Choose a workspace in the sidebar.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.closeSurface() } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("Close \(surface.title)").accessibilityIdentifier("surface.close")
                }
            }
        }
        // Mentions and board items inside surface content open their record inside this stack.
        .environment(\.openMention, OpenMentionAction { kind, id in open(kind: kind, id: id) })
        .environment(\.pushRoute, PushRouteAction { path.append($0) })
        .onChange(of: model.selectedWorkspace?.id) { _, _ in path = [] }
        .onChange(of: model.contextSelections) { _, _ in if surface != .canvas { path = [] } }
        .background(Amb.background)
    }

    @ViewBuilder private func root(_ workspace: WorkspaceRecord, _ store: LocalStore) -> some View {
        switch surface {
        case .canvas: CanvasListView(workspace: workspace, store: store)
        case .context: ContextTreeView(workspace: workspace, store: store)
        case .agents: AgentsView(workspace: workspace, store: store)
        case .toolbox: ToolboxView(workspace: workspace, store: store)
        }
    }

    private func open(kind: String, id: String) {
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
    }
}

/// Pushes a route onto the enclosing surface's navigation stack (a canvas opening one of its naplets).
struct PushRouteAction: Sendable {
    let handler: @MainActor @Sendable (WorkRoute) -> Void
    @MainActor func callAsFunction(_ route: WorkRoute) { handler(route) }
}

extension EnvironmentValues {
    @Entry var pushRoute = PushRouteAction { _ in }
}

/// Sidebar "Pinned" section (sol `pinned-threads.js`): the viewer's pins in Tower's order. A pin whose record is not on
/// this iPhone is still listed, labelled, and can be unpinned.
struct SidebarPinnedSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openMention) private var openMention

    var body: some View {
        let snapshot = model.pins.value
        let items = snapshot.items.filter { snapshot.isPinned($0.pin.resourceType, $0.pin.resourceId) }
        if !items.isEmpty {
            Text("Pinned").font(.footnote.weight(.heavy)).foregroundStyle(Amb.mutedForeground)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(items) { item in
                Button { open(item) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(item.pin.resourceType)).font(.caption).foregroundStyle(Amb.mutedForeground).frame(width: 16)
                        Text(item.title ?? unavailable(item.pin.resourceType))
                            .font(.subheadline).foregroundStyle(item.title == nil ? Amb.mutedForeground : Amb.foreground).lineLimit(1)
                        Spacer(minLength: 0)
                        if snapshot.pending[PinsSnapshot.key(item.pin.resourceType, item.pin.resourceId)]?.isPending == true {
                            ProgressView().controlSize(.mini).accessibilityLabel("Saving pin")
                        }
                    }
                    .padding(.leading, 10).padding(.trailing, 10).frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let workspace = model.selectedWorkspace {
                        Button(role: .destructive) { model.setPinned(false, type: item.pin.resourceType, id: item.pin.resourceId, in: workspace) } label: {
                            Label("Unpin", systemImage: "pin.slash")
                        }
                    }
                }
                .accessibilityLabel("Pinned: \(item.title ?? unavailable(item.pin.resourceType))")
                .accessibilityIdentifier("sidebar.pin.\(item.title ?? item.pin.resourceId)")
            }
            .padding(.bottom, 6)
        }
    }

    private func open(_ item: PinnedItem) {
        model.sidebarOpen = false
        model.closeSurface()
        switch item.pin.resourceType {
        case .channel:
            if let scope = item.scopeId { model.selectContext(WorkContext(scopeId: scope, channelId: item.pin.resourceId)); model.mode = .chat }
        case .thread: openMention(kind: "thread", id: item.pin.resourceId)
        case .task: openMention(kind: "task", id: item.pin.resourceId)
        case .document: openMention(kind: "doc", id: item.pin.resourceId)
        }
    }

    private func icon(_ type: PinRecord.ResourceType) -> String {
        switch type {
        case .thread: "bubble.left"
        case .task: "checklist"
        case .document: "doc.text"
        case .channel: "number"
        }
    }

    private func unavailable(_ type: PinRecord.ResourceType) -> String {
        switch type {
        case .thread: "Conversation not on this iPhone"
        case .task: "Task not on this iPhone"
        case .document: "Document not on this iPhone"
        case .channel: "Channel not available"
        }
    }
}

/// Sidebar "Workspace" section: the surfaces beyond the five tabs (sol's Canvas deck column, Context, Agents, Toolbox).
struct SidebarWorkspaceSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Text("Workspace").font(.footnote.weight(.heavy)).foregroundStyle(Amb.mutedForeground)
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
        ForEach(Surface.allCases) { surface in
            Button { model.openSurface(surface) } label: {
                HStack(spacing: 8) {
                    Image(systemName: surface.systemImage).font(.subheadline).foregroundStyle(Amb.primary).frame(width: 20)
                    Text(surface.title).font(.subheadline.weight(model.surface == surface ? .semibold : .regular)).foregroundStyle(Amb.foreground)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(minHeight: 36)
                .background(model.surface == surface ? Amb.accent : Color.clear, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.surface == surface ? .isSelected : [])
            .accessibilityIdentifier("sidebar.surface.\(surface.rawValue)")
        }
        .padding(.bottom, 8)
    }
}

/// Pin / unpin toolbar button for a record screen. Shows the user's latest intent while the write is queued, and a
/// failed pin (for example a record the viewer can no longer read) with Retry and Discard.
struct PinToolbarModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let type: PinRecord.ResourceType
    let id: String
    let workspace: WorkspaceRecord
    @State private var showFailure = false

    func body(content: Content) -> some View {
        let snapshot = model.pins.value
        let pinned = snapshot.isPinned(type, id)
        let failure = snapshot.failure(type, id)
        content.toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if failure != nil { showFailure = true } else { model.setPinned(!pinned, type: type, id: id, in: workspace) }
                } label: {
                    Image(systemName: failure != nil ? "pin.slash.fill" : pinned ? "pin.fill" : "pin")
                        .foregroundStyle(failure != nil ? Amb.warning : Amb.primary)
                }
                .accessibilityLabel(failure != nil ? "Pin not saved" : pinned ? "Unpin" : "Pin")
                .accessibilityIdentifier("pin.toggle")
            }
        }
        .confirmationDialog(failure?.lastError ?? "Pin not saved", isPresented: $showFailure, titleVisibility: .visible) {
            if let failure, let store = model.store {
                Button("Retry") { Task { try? await store.writer.retryWrite(id: failure.id, force: true); model.kickOutbox(force: true) } }
                Button("Discard", role: .destructive) { Task { try? await store.writer.discardWrite(id: failure.id) } }
            }
        }
    }
}

extension View {
    func pinToolbar(_ type: PinRecord.ResourceType, id: String, workspace: WorkspaceRecord) -> some View {
        modifier(PinToolbarModifier(type: type, id: id, workspace: workspace))
    }
}

/// A route's thread opened by id: shows the conversation once its channel is known (fetching the thread first when it is
/// not stored), or says why it cannot be opened.
struct ThreadByIdView: View {
    @Environment(AppModel.self) private var model
    let threadId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    let connectionId: String
    @State private var thread = LiveQuery<ThreadRecord?>(initial: nil)

    var body: some View {
        Group {
            if let thread = thread.value {
                ThreadView(target: ChatTarget(connectionId: connectionId, workspaceId: workspace.id, channelId: thread.channelId, threadId: thread.id),
                           workspace: workspace, store: store)
            } else if let error = model.syncError(forKey: WorkspaceSync.threadRecordKey(workspace.id, threadId)) {
                EmptyNote(title: "Conversation unavailable", systemImage: "lock", detail: error)
            } else if !model.canRead {
                EmptyNote(title: "Conversation not on this iPhone", systemImage: "lock", detail: "Unlock to load it.")
            } else {
                ProgressView("Loading conversation…")
            }
        }
        .task {
            let w = workspace.id, id = threadId, store = store
            thread.start(store: store, matches: { $0.workspaceId == w && [.threads, .channels].contains($0.table) }) {
                guard let t = try await store.reader.thread(workspaceId: w, id: id), try await store.reader.channel(workspaceId: w, id: t.channelId) != nil else { return nil }
                return t
            }
            if (try? await store.reader.thread(workspaceId: w, id: id)) == nil { model.ensureThread(id, in: workspace) }
        }
    }
}
