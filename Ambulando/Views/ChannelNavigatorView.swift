import AmbulandoCore
import SwiftUI

struct ScopeSection: Sendable, Equatable, Identifiable {
    let scope: ScopeRecord
    let channels: [ChannelRecord]
    var id: String { scope.id }
}

struct NavigatorState: Sendable, Equatable {
    var sections: [ScopeSection] = []
    var collapsed: Set<String> = []
}

/// The Chat tab: its own navigation stack whose path is persisted per workspace, so the open channel or thread
/// survives tab switches and relaunch. Every screen renders from the local store.
struct ChatStack<Banner: View>: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    @ViewBuilder let banner: () -> Banner

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.chatPath) {
            VStack(spacing: 0) {
                banner()
                ChannelNavigatorView()
            }
            .background(Amb.background)
            .toolbarItems(showSettings: $showSettings)
            .navigationDestination(for: ChatRoute.self) { route in
                if let workspace = model.selectedWorkspace, route.workspaceId == workspace.id, let store = model.store, let connection = model.connection {
                    switch route {
                    case .channel(_, let channelId):
                        ChannelView(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: channelId),
                                    workspace: workspace, store: store)
                    case .thread(_, let channelId, let threadId):
                        ThreadView(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: channelId, threadId: threadId),
                                   workspace: workspace, store: store)
                    }
                } else {
                    ContentUnavailableView("Not in this workspace", systemImage: "arrow.uturn.backward",
                                           description: Text("This conversation belongs to another workspace."))
                }
            }
        }
    }
}

/// Scope → channel navigation for the selected workspace, rendered from the local store.
struct ChannelNavigatorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let workspace = model.selectedWorkspace, let store = model.store, let connection = model.connection {
            ChannelList(workspace: workspace, connection: connection, store: store)
                .id(workspace.id)   // a workspace switch gets a fresh observer: no cross-workspace rows
        } else {
            ContentUnavailableView {
                Label("No workspace", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text(model.workspaces.loaded ? "Discovery found no workspaces for this identity yet. Pull to refresh or check Settings." : "Loading saved workspaces…")
            }
            .refreshable { model.refresh(force: true) }
        }
    }
}

private struct ChannelList: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    let store: LocalStore
    @State private var state = LiveQuery<NavigatorState>(initial: NavigatorState())
    @State private var collapsedOverride: Set<String>?

    private var collapsedKey: String { WorkspaceSync.collapsedKey(connectionId: connection.id, workspaceId: workspace.id) }

    var body: some View {
        List {
            ForEach(state.value.sections) { section in
                let collapsed = (collapsedOverride ?? state.value.collapsed).contains(section.id)
                Section {
                    if !collapsed {
                        if section.channels.isEmpty {
                            Text("No channels visible").font(.footnote).foregroundStyle(Amb.mutedForeground)
                        }
                        ForEach(section.channels) { channel in
                            NavigationLink(value: ChatRoute.channel(workspaceId: workspace.id, channelId: channel.id)) {
                                Label {
                                    Text(channel.name).foregroundStyle(Amb.foreground)
                                } icon: {
                                    Image(systemName: channel.kind == "dm" ? "person.2" : "number").foregroundStyle(Amb.mutedForeground)
                                }
                            }
                            .accessibilityIdentifier("channel.\(channel.name)")
                        }
                    }
                } header: {
                    Button { toggle(section.id) } label: {
                        HStack {
                            Text(section.scope.name).font(.subheadline.weight(.semibold)).foregroundStyle(Amb.itemHeading).textCase(nil)
                            Spacer()
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Amb.mutedForeground)
                                .rotationEffect(.degrees(collapsed ? -90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(section.scope.name), \(collapsed ? "collapsed" : "expanded")")
                    .accessibilityIdentifier("scope.\(section.scope.name)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if state.loaded && state.value.sections.isEmpty {
                ContentUnavailableView("No scopes yet", systemImage: "square.grid.2x2",
                                       description: Text(model.lastSyncError ?? "Pull to refresh once your identity is unlocked."))
            }
        }
        .refreshable { model.refresh(force: true) }
        .task {
            let id = workspace.id, orderKey = WorkspaceSync.scopeOrderKey(id), collapsedKey = collapsedKey
            state.start(store: store, matches: { ($0.table == .scopes || $0.table == .channels) && $0.workspaceId == id || $0.table == .appState }) {
                async let scopes = store.reader.scopes(workspaceId: id)
                async let channels = store.reader.channels(workspaceId: id)
                async let order = store.reader.state(orderKey)
                async let collapsed = store.reader.state(collapsedKey)
                let byScope = Dictionary(grouping: try await channels, by: \.scopeId)
                let ordered = ScopeOrdering.apply(try await scopes, order: ScopeOrdering.decode(try await order), id: \.id)
                return NavigatorState(sections: ordered.map { ScopeSection(scope: $0, channels: byScope[$0.id] ?? []) },
                                      collapsed: Set(ScopeOrdering.decode(try await collapsed)))
            }
        }
    }

    /// Collapse is a personal preference stored on this iPhone only; it applies immediately and persists for relaunch.
    private func toggle(_ scopeId: String) {
        var collapsed = collapsedOverride ?? state.value.collapsed
        if collapsed.contains(scopeId) { collapsed.remove(scopeId) } else { collapsed.insert(scopeId) }
        let encoded = String(decoding: (try? JSONEncoder().encode(collapsed.sorted())) ?? Data("[]".utf8), as: UTF8.self)
        let key = collapsedKey
        withAnimation(.snappy) { collapsedOverride = collapsed }
        Task { try? await store.writer.setState(key, encoded) }
    }
}
