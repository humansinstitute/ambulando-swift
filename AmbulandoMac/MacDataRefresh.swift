import AmbulandoCore
import SwiftUI

/// One explicit refresh shared by every Mac window. It schedules the existing scoped reads, never reopens a view,
/// saves a composer, changes navigation, or touches a WKWebView. Automatic live updates remain independent.
@MainActor @Observable
final class MacDataRefresh {
    private(set) var running = false
    private(set) var message: String?
    private(set) var failed = false
    private(set) var attempts = 0
    @ObservationIgnored private(set) var operation: Task<Void, Never>?

    func available(_ model: AppModel) -> Bool {
        guard model.phase == .ready, model.canRead, !running,
              let boundary = model.selectedWorkspaceBoundary,
              let entry = model.enabledWorkspaceEntries.first(where: { $0.boundary == boundary }),
              let runtime = entry.runtime else { return false }
        return runtime.validated && runtime.activity.isEnabled
    }

    func start(_ model: AppModel) {
        guard available(model), let boundary = model.selectedWorkspaceBoundary,
              let entry = model.enabledWorkspaceEntries.first(where: { $0.boundary == boundary }),
              let runtime = entry.runtime, runtime.validated, let lease = try? runtime.activity.lease() else { return }
        running = true; failed = false; message = nil; attempts += 1
        let workspace = entry.workspace, connection = entry.connection, sync = runtime.sync
        let context = model.context, mode = model.mode
        let focus = model.focusedThread.flatMap { $0.workspaceId == workspace.id ? $0 : nil }
        let route = AppModel.pathKey(mode).flatMap { model[keyPath: $0].last }
        operation = Task { [weak self, weak model] in
            guard let self, let model else { return }
            defer { running = false; operation = nil }
            do {
                try await runtime.activity.withLease(lease) {
                    var keys: Set<String> = ["scopes:\(workspace.id)", "directory:\(workspace.id)",
                        WorkspaceSync.pinsKey(workspace.id), WorkspaceSync.inboxKey(workspace.id),
                        WorkspaceSync.notificationsKey(workspace.id),
                        WorkspaceSync.attentionTypesKey(workspace.id), WorkspaceSync.eventsKey(workspace.id)]
                    await sync.refreshWorkspace(connection, workspace, priority: .visible, force: true, includeDirectory: false)
                    await sync.refreshDirectory(connection, workspace, priority: .visible, force: true)
                    await sync.refreshPins(connection, workspace, priority: .visible, force: true)
                    await sync.refreshNotifications(connection, workspace, priority: .visible, force: true)
                    // Explicit reconciliation deliberately bypasses build 98's navigation-only baseline reuse.
                    await sync.refreshInbox(connection, workspace, priority: .visible, force: true)
                    await sync.catchUpEvents(connection, workspace, priority: .visible, force: true)
                    if let channel = focus?.channelId ?? context.channelId {
                        keys.insert(WorkspaceSync.messagesKey(workspace.id, channel))
                        await sync.catchUpChannel(connection, workspace, channelId: channel, priority: .visible, force: true)
                    }
                    if let focus, focus.workspaceId == workspace.id {
                        var channel = focus.channelId
                        if channel == nil {
                            let key = WorkspaceSync.threadRecordKey(workspace.id, focus.threadId)
                            await sync.ensureThread(connection, workspace, threadId: focus.threadId)
                            try await Self.wait(sync.engine, keys: [key], activity: runtime.activity, lease: lease)
                            channel = try await sync.store.reader.thread(workspaceId: workspace.id, id: focus.threadId)?.channelId
                        }
                        guard let channel else { throw RefreshFailure() }
                        keys.insert(WorkspaceSync.threadKey(workspace.id, focus.threadId))
                        await sync.refreshThread(connection, workspace, channelId: channel, threadId: focus.threadId, force: true)
                    }
                    if let route, route.workspaceId == workspace.id {
                        switch route {
                        case .doc(_, let id):
                            keys.insert(WorkspaceSync.docKey(workspace.id, id))
                            await sync.refreshDoc(connection, workspace, docId: id, force: true)
                        case .task(_, let id):
                            keys.insert(WorkspaceSync.taskKey(workspace.id, id))
                            await sync.refreshTask(connection, workspace, taskId: id, force: true)
                        case .thread(_, let channel, let id):
                            keys.insert(WorkspaceSync.threadKey(workspace.id, id))
                            await sync.refreshThread(connection, workspace, channelId: channel, threadId: id, force: true)
                        case .canvas(_, let id), .board(_, let id, _):
                            keys.insert(WorkspaceSync.canvasKey(workspace.id, id))
                            await sync.refreshCanvas(connection, workspace, canvasId: id, force: true)
                        case .contextComponent(_, let scope, let id):
                            keys.insert(WorkspaceSync.contextReferencesKey(workspace.id, id))
                            await sync.refreshContextReferences(connection, workspace, scopeId: scope, componentId: id, force: true)
                        default: break
                        }
                    } else if focus == nil {
                        let channels = try await sync.store.reader.channels(workspaceId: workspace.id).filter { context.scopeId == nil || $0.scopeId == context.scopeId }
                        switch mode {
                        case .tasks:
                            keys.formUnion(channels.map { WorkspaceSync.tasksKey(workspace.id, $0.id) })
                            await sync.refreshTasks(connection, workspace, scopeId: context.scopeId, force: true)
                        case .docs:
                            keys.formUnion(channels.map { WorkspaceSync.docsKey(workspace.id, $0.id) })
                            await sync.refreshDocs(connection, workspace, scopeId: context.scopeId, force: true)
                            keys.formUnion(channels.map { WorkspaceSync.filesKey(workspace.id, $0.id) })
                            await sync.refreshFiles(connection, workspace, scopeId: context.scopeId, force: true)
                        case .files:
                            keys.formUnion(channels.map { WorkspaceSync.filesKey(workspace.id, $0.id) })
                            await sync.refreshFiles(connection, workspace, scopeId: context.scopeId, force: true)
                        case .deck:
                            keys.insert(WorkspaceSync.runtimeAppsKey(workspace.id))
                            await sync.scheduleRuntimeApps(connection, workspace, force: true)
                            keys.insert(WorkspaceSync.canvasesKey(workspace.id))
                            await sync.refreshCanvases(connection, workspace, force: true)
                        case .agents:
                            keys.insert(WorkspaceSync.agentsKey(workspace.id))
                            await sync.refreshAgents(connection, workspace, channelIds: channels.map(\.id), force: true)
                        case .context:
                            if let scope = context.scopeId {
                                keys.insert(WorkspaceSync.contextTreeKey(workspace.id, scope))
                                await sync.refreshContextTree(connection, workspace, scopeId: scope, force: true)
                            }
                        case .toolbox:
                            keys.insert(WorkspaceSync.runtimeAppsKey(workspace.id))
                            await sync.scheduleRuntimeApps(connection, workspace, force: true)
                            keys.insert(WorkspaceSync.toolboxKey(workspace.id))
                            await sync.refreshToolbox(connection, workspace, force: true)
                        default: break
                        }
                    }
                    try await Self.wait(sync.engine, keys: keys, activity: runtime.activity, lease: lease)
                }
                // A result from an old selection must never report success for the newly selected workspace.
                guard model.selectedWorkspaceBoundary == boundary, model.canRead else {
                    message = "Refresh ended for the previous workspace. Your current location is unchanged."; return
                }
                message = "Data refreshed."
            } catch {
                failed = true
                message = error is CancellationError
                    ? "Refresh stopped because account or workspace access changed. Saved work is kept."
                    : "Some data could not refresh. Saved data and drafts are kept. Check your connection and try again."
            }
        }
    }

    /// Observe only this operation's keys, not every background job or the lifetime of the event stream.
    private nonisolated static func wait(_ engine: SyncEngine, keys: Set<String>, activity: WorkspaceActivity, lease: UInt64) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while true {
            try Task.checkCancellation(); try activity.check(lease)
            let snapshot = await engine.snapshot
            if keys.isDisjoint(with: snapshot.running.union(snapshot.queued)) {
                if !keys.isDisjoint(with: snapshot.connectionFailures) || snapshot.errors.keys.contains(where: keys.contains) {
                    throw RefreshFailure()
                }
                if keys.isDisjoint(with: snapshot.scheduled) { return }
            }
            guard ContinuousClock.now < deadline else { throw RefreshFailure() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private struct RefreshFailure: Error {}
}

/// Compact at the main, conversation and browser bars, including when the window is narrow.
struct MacRefreshDataButton: View {
    @Environment(AppModel.self) private var model
    @State private var showingResult = false
    var body: some View {
        HStack(spacing: 4) {
            Button { model.dataRefresh.start(model) } label: {
                if model.dataRefresh.running { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
                else { Image(systemName: "arrow.clockwise").frame(width: 18, height: 18) }
            }
            .buttonStyle(.plain).padding(8)
            .disabled(!model.dataRefresh.available(model))
            .accessibilityLabel(model.dataRefresh.running ? "Refreshing data" : "Refresh data")
            .accessibilityIdentifier("data.refresh")
            .help("Refresh Ambulando data. Keeps your location and unsaved work; does not reload web pages.")
            if let message = model.dataRefresh.message {
                Button { showingResult.toggle() } label: {
                    Image(systemName: model.dataRefresh.failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(model.dataRefresh.failed ? Amb.warning : Amb.mutedForeground)
                }
                .buttonStyle(.plain).padding(4)
                .accessibilityLabel(message).accessibilityIdentifier("data.refresh.result")
                .help(message)
                .popover(isPresented: $showingResult) { Text(message).padding().frame(maxWidth: 300) }
            }
        }
    }
}
