import AmbulandoCore
import SwiftUI

struct ScopeSection: Sendable, Equatable, Identifiable {
    let scope: ScopeRecord
    let channels: [ChannelRecord]
    var id: String { scope.id }
}

/// Scope → channel navigation for the selected workspace, rendered from the local store.
struct ChannelNavigatorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let workspace = model.selectedWorkspace, let store = model.store {
            ChannelList(workspace: workspace, store: store)
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
    let store: LocalStore
    @State private var sections = LiveQuery<[ScopeSection]>(initial: [])

    var body: some View {
        List {
            ForEach(sections.value) { section in
                Section {
                    if section.channels.isEmpty {
                        Text("No channels visible").font(.footnote).foregroundStyle(Amb.mutedForeground)
                    }
                    ForEach(section.channels) { channel in
                        NavigationLink(value: channel) {
                            Label {
                                Text(channel.name).foregroundStyle(Amb.foreground)
                            } icon: {
                                Image(systemName: channel.kind == "dm" ? "person.2" : "number").foregroundStyle(Amb.mutedForeground)
                            }
                        }
                    }
                } header: {
                    Text(section.scope.name).font(.subheadline.weight(.semibold)).foregroundStyle(Amb.itemHeading).textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if sections.loaded && sections.value.isEmpty {
                ContentUnavailableView("No scopes yet", systemImage: "square.grid.2x2",
                                       description: Text(model.lastSyncError ?? "Pull to refresh once your identity is unlocked."))
            }
        }
        .refreshable { model.refresh(force: true) }
        .navigationDestination(for: ChannelRecord.self) { ChannelView(channel: $0, workspace: workspace) }
        .task {
            let id = workspace.id
            sections.start(store: store, matches: { ($0.table == .scopes || $0.table == .channels) && $0.workspaceId == id }) {
                async let scopes = store.reader.scopes(workspaceId: id)
                async let channels = store.reader.channels(workspaceId: id)
                let byScope = Dictionary(grouping: try await channels, by: \.scopeId)
                return try await scopes.map { ScopeSection(scope: $0, channels: byScope[$0.id] ?? []) }
            }
        }
    }
}

extension ChannelRecord: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(workspaceId); hasher.combine(id) }
}

/// Channel destination. History, threads and sending are WP3; this screen states that plainly.
struct ChannelView: View {
    let channel: ChannelRecord
    let workspace: WorkspaceRecord

    var body: some View {
        ContentUnavailableView {
            Label(channel.name, systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Native chat history, threads and signed sending arrive in WP3.\nThis channel was loaded from \(workspace.label) and is stored on this iPhone.")
        }
        .background(Amb.background)
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
