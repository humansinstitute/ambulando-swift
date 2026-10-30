import AmbulandoCore
import Foundation
import Observation

/// One exact account/workspace/application boundary, including its independently owned sync lifecycle.
@MainActor @Observable
final class EnabledWorkspaceEntry: Identifiable {
    nonisolated let boundary: WorkspaceBoundary
    let connection: ConnectionRecord
    var workspace: WorkspaceRecord
    var enabled = false
    var collapsed = false
    var colour: WorkspaceColour = .blue
    nonisolated var id: String { boundary.id }
    var navigation: NavigationSnapshot { query.value }
    @ObservationIgnored let query = LiveQuery<NavigationSnapshot>(initial: NavigationSnapshot())
    @ObservationIgnored var runtime: NativeWorkspaceRuntime?

    init(connection: ConnectionRecord, workspace: WorkspaceRecord) throws {
        boundary = try WorkspaceBoundary(connection: connection, workspace: workspace)
        self.connection = connection; self.workspace = workspace
    }

    func observe(_ store: LocalStore) {
        let workspaceId = workspace.id, connection = connection
        query.start(store: store, matches: { key in
            [.scopes, .channels, .viewStates, .members, .appState, .access, .workspaces].contains(key.table)
        }) {
            guard try await store.reader.workspaces(connectionId: connection.id).contains(where: { $0.id == workspaceId }) else {
                return NavigationSnapshot(workspaceId: workspaceId, loaded: true, accessLost: true)
            }
            let scopes = try await store.reader.scopes(workspaceId: workspaceId)
            let channels = try await store.reader.channels(workspaceId: workspaceId)
            let order = try await store.reader.state(WorkspaceSync.scopeOrderKey(workspaceId))
            let collapsed = try await store.reader.state(WorkspaceSync.collapsedKey(connectionId: connection.id, workspaceId: workspaceId))
            let members = try await store.reader.directoryMembers(workspaceId: workspaceId)
            let names = Dictionary(members.map { ($0.npub, $0.label) }, uniquingKeysWith: { a, _ in a })
            let groups = SidebarNavigation.groups(scopes: scopes, channels: channels, personalOrder: ScopeOrdering.decode(order))
            var labels: [String: String] = [:]
            for channel in channels { labels[channel.id] = SidebarNavigation.label(channel, viewerNpub: connection.signerNpub, names: names) }
            return NavigationSnapshot(workspaceId: workspaceId, groups: groups, collapsed: Set(ScopeOrdering.decode(collapsed)),
                                      unread: try await store.reader.unreadChannelIds(workspaceId: workspaceId), labels: labels, loaded: true)
        }
    }
}

@MainActor
final class NativeWorkspaceRuntime {
    let store: LocalStore
    let sync: WorkspaceSync
    let engine: SyncEngine
    let activity: WorkspaceActivity
    let writeActivity: WorkspaceActivity
    let stream: LiveStream
    let outbox: OutboxSender
    let writes: WriteSender
    let saver: DocumentSaver
    let manager: ScopeChannelManager
    let uploads: ComposerUploads
    let fileCache: FileCache
    var validated = false
    var starting: Task<Void, Never>?
    var startRevision = UUID()

    init(entry: EnabledWorkspaceEntry, store: LocalStore, shared: SyncEngine, identity: IdentityService,
         transport: HTTPTransport, events: EventStreamTransport, staging: URL, cacheRoot: URL,
         afterWikiCreate: @escaping @Sendable (ConnectionRecord, WriteItem, DocRecord, LocalStore, DocumentSaver, WorkspaceRecord) async throws -> Void) {
        self.store = store
        activity = WorkspaceActivity(enabled: false)
        writeActivity = WorkspaceActivity(enabled: false)
        engine = SyncEngine(parent: shared, namespace: entry.id, connectionNamespace: entry.boundary.connectionNamespace, activity: activity)
        let guarded = WorkspaceHTTPTransport(base: transport, activity: activity)
        // Per-workspace cancellable transfers use the bounded foreground scheduler. They never enter a shared,
        // workspace-unqualified system transfer registry.
        sync = WorkspaceSync(store: store, engine: engine, identity: identity, transport: guarded, boundary: entry.boundary)
        stream = LiveStream(sync: sync, transport: WorkspaceEventStreamTransport(base: events, activity: activity))
        let writeTransport = WorkspaceHTTPTransport(base: guarded, activity: writeActivity)
        outbox = OutboxSender(store: store, engine: engine, identity: identity, transport: writeTransport, staging: staging)
        let sync = sync, workspace = entry.workspace
        saver = DocumentSaver(store: store, identity: identity, transport: writeTransport)
        let saver = saver
        writes = WriteSender(store: store, engine: engine, identity: identity, transport: writeTransport, staging: staging,
                             afterNotificationWrite: { connection, workspaceId in
            guard workspaceId == workspace.id else { return }
            await sync.refreshNotifications(connection, workspace, priority: .background)
        }, afterWikiCreate: { connection, item, created in
            try await afterWikiCreate(connection, item, created, store, saver, workspace)
        })
        manager = ScopeChannelManager(store: store, identity: identity, transport: writeTransport)
        let pasted = ComposerUploadTransfer(engine: engine, identity: identity, transport: writeTransport)
        let connection = entry.connection
        uploads = ComposerUploads(store: store, staging: staging, appNpub: entry.boundary.appNpub) { job in try await pasted.upload(job, connection: connection) }
        fileCache = FileCache(root: cacheRoot.appendingPathComponent(entry.id, isDirectory: true))
    }

    func pause() async {
        writeActivity.pause()
        activity.pause() // synchronous gate precedes all actor hops
        validated = false
        startRevision = UUID()
        starting?.cancel(); starting = nil
        await engine.pause()
        await stream.stop()
        await saver.forgetAll()
    }
}

struct NativeWorkspaceListing: Equatable, Sendable {
    var connection: ConnectionRecord
    var workspace: WorkspaceRecord
}
