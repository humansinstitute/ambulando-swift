import AmbulandoCore
import SwiftUI

/// The Chat mode. Its root follows the shared context: a channel's conversation when a channel is selected in the
/// sidebar, otherwise the channels of the selected scope (or of every scope at Home). Threads push on top; the path is
/// persisted per workspace, so the open thread survives mode switches and relaunch.
struct ChatStack<Banner: View>: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    @ViewBuilder let banner: () -> Banner

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.chatPath) {
            VStack(spacing: 0) {
                banner()
                ContextBar()
                ChatContextRoot()
            }
            .background(Amb.background)
            .toolbarItems(showSettings: $showSettings, pin: ToolbarPin.chat(nil, channel: model.context.channelId, workspace: model.selectedWorkspace))
            .navigationDestination(for: ChatRoute.self) { route in
                Group {
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
                .toolbarItems(showSettings: $showSettings, pin: ToolbarPin.chat(route, channel: nil, workspace: model.selectedWorkspace), showsSidebar: false)
            }
        }
    }
}

/// Chat's root for the current context.
struct ChatContextRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let workspace = model.selectedWorkspace, let store = model.store, let connection = model.connection {
            Group {
                if let channelId = model.context.channelId {
                    ChannelView(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: channelId),
                                workspace: workspace, store: store, pushed: false)

                        .id("\(workspace.id):\(channelId)")   // a fresh observer per channel: no rows cross over
                } else {
                    ChannelDirectoryView()
                }
            }
            .id(workspace.id)
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
