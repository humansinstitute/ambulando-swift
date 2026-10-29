import AmbulandoCore
import SwiftUI

/// Pushes a route onto the enclosing section's navigation stack (a canvas opening one of its naplets).
struct PushRouteAction: Sendable {
    let handler: @MainActor @Sendable (WorkRoute) -> Void
    @MainActor func callAsFunction(_ route: WorkRoute) { handler(route) }
}

extension EnvironmentValues {
    @Entry var pushRoute = PushRouteAction { _ in }
}

struct ToolbarPin: Equatable {
    let type: PinRecord.ResourceType
    let id: String
    let workspace: WorkspaceRecord
}

extension ToolbarPin {
    static func work(_ route: WorkRoute?, workspace: WorkspaceRecord?) -> ToolbarPin? {
        guard let route, let workspace, route.workspaceId == workspace.id else { return nil }
        switch route {
        case .task(_, let id): return ToolbarPin(type: .task, id: id, workspace: workspace)
        case .doc(_, let id): return ToolbarPin(type: .document, id: id, workspace: workspace)
        case .channel(_, let id): return ToolbarPin(type: .channel, id: id, workspace: workspace)
        case .thread(_, _, let id), .threadById(_, let id): return ToolbarPin(type: .thread, id: id, workspace: workspace)
        default: return nil
        }
    }
    static func chat(_ route: ChatRoute?, channel: String?, workspace: WorkspaceRecord?) -> ToolbarPin? {
        guard let workspace else { return nil }
        if let route {
            guard route.workspaceId == workspace.id else { return nil }
            switch route {
            case .channel(_, let id): return ToolbarPin(type: .channel, id: id, workspace: workspace)
            case .thread(_, _, let id): return ToolbarPin(type: .thread, id: id, workspace: workspace)
            }
        }
        return channel.map { ToolbarPin(type: .channel, id: $0, workspace: workspace) }
    }
}

/// Pin / unpin button. Shows the user's latest intent while the write is queued, and a failed pin (for example a record
/// the viewer can no longer read) with Retry and Discard.
struct PinToggleButton: View {
    @Environment(AppModel.self) private var model
    let type: PinRecord.ResourceType
    let id: String
    let workspace: WorkspaceRecord
    @State private var showFailure = false

    var body: some View {
        let snapshot = model.pins.value
        let pinned = snapshot.isPinned(type, id)
        let failure = snapshot.failure(type, id)
        Button {
            if failure != nil { showFailure = true } else { model.setPinned(!pinned, type: type, id: id, in: workspace) }
        } label: {
            Image(systemName: failure != nil ? "pin.slash.fill" : pinned ? "pin.fill" : "pin")
                .foregroundStyle(failure != nil ? Amb.warning : Amb.primary)
        }
        .accessibilityLabel(failure != nil ? "Pin not saved" : pinned ? "Unpin" : "Pin")
        .accessibilityIdentifier("pin.toggle")
        .confirmationDialog(failure?.lastError ?? "Pin not saved", isPresented: $showFailure, titleVisibility: .visible) {
            if let failure, let store = model.store {
                Button("Retry") { Task { try? await store.writer.retryWrite(id: failure.id, force: true); model.kickOutbox(force: true) } }
                Button("Discard", role: .destructive) { Task { try? await store.writer.discardWrite(id: failure.id) } }
            }
        }
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
                EmptyNote(title: "Conversation not on this \(Device.name)", systemImage: "lock", detail: "Unlock to load it.")
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
