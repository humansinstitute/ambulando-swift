import Foundation

/// The workspace read path: nStack descriptor → workspace discovery → scopes → channels, materialised into
/// the local store. All work is scheduled through `SyncEngine`; views only read the store.
public struct WorkspaceSync: Sendable {
    public let store: LocalStore
    public let engine: SyncEngine
    public let identity: IdentityService
    public let transport: HTTPTransport
    /// Live-update state per workspace (event stream batches, poll requests, diagnostics).
    public let live: LiveRegistry
    /// Background `URLSession` transfers for presigned object-store URLs, when the app provides them.
    public let transfers: BackgroundTransfers?

    public init(store: LocalStore, engine: SyncEngine, identity: IdentityService, transport: HTTPTransport,
                live: LiveRegistry = LiveRegistry(), transfers: BackgroundTransfers? = nil) {
        self.store = store; self.engine = engine; self.identity = identity; self.transport = transport
        self.live = live; self.transfers = transfers
    }

    func api(origin: TowerOrigin, signed: Bool = true) -> TowerAPI {
        TowerAPI(client: TowerClient(origin: origin, transport: transport, signer: signed ? identity : nil), transfers: transfers)
    }

    /// Reads the public descriptor for an origin the user typed. No identity is used.
    public func checkDescriptor(origin: TowerOrigin) async throws -> NStackDescriptor {
        try await api(origin: origin, signed: false).descriptor()
    }

    /// Validates the descriptor, binds the origin to the unlocked identity, and persists the connection.
    public func connect(origin: TowerOrigin) async throws -> ConnectionRecord {
        guard case .unlocked(let npub) = await identity.state else { throw IdentityError.locked }
        let descriptor = try await checkDescriptor(origin: origin)
        return try await store.writer.saveConnection(ConnectionRecord(origin: origin, signerNpub: npub, towerNpub: descriptor.stack?.tower_npub))
    }

    /// Discovery job: authoritative workspace list for the connection, then each workspace's scopes.
    public func discover(_ connection: ConnectionRecord, priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self
        await engine.enqueue("discover:\(connection.id)", priority: priority, force: force, retries: SyncBackoff.readRetries) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let origin = try TowerOrigin(connection.origin)
            let workspaces = try await sync.api(origin: origin).workspaces()
            try Task.checkCancellation()
            try await sync.store.writer.replaceWorkspaces(connectionId: connection.id, workspaces)
            // Keeps an enabled background credential pinned to exactly the workspaces this identity can see.
            try? await sync.identity.updateBackgroundWorkspaces(origin: origin, workspaceIds: workspaces.map(\.id))
            for workspace in workspaces { await sync.refreshWorkspace(connection, workspace, priority: .background) }
        }
    }

    /// Scopes job for one workspace; on success schedules one channel job per scope.
    public func refreshWorkspace(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self
        await engine.enqueue("scopes:\(workspace.id)", priority: priority, force: force, retries: SyncBackoff.readRetries) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            let scopes = try await api.scopes(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            try await sync.store.writer.upsertScopes(workspaceId: workspace.id, scopes, complete: true)
            await sync.refreshDirectory(connection, workspace, priority: .background)
            for scope in scopes {
                await sync.engine.enqueue("channels:\(workspace.id):\(scope.id)", priority: priority) {
                    try await sync.identity.requireReader(npub: connection.signerNpub)
                    let channels = try await api.channels(workspaceId: workspace.id, scopeId: scope.id, appNpub: workspace.appNpub)
                    try Task.checkCancellation()
                    try await sync.store.writer.upsertChannels(workspaceId: workspace.id, scopeId: scope.id, channels, complete: true)
                    // Every channel's history is fetched in the background, not only the ones opened on this phone, so
                    // conversations are there before they are opened (bounded by the engine's background slots).
                    for channel in channels {
                        if try await sync.store.reader.channelSync(workspaceId: workspace.id, channelId: channel.id)?.complete != true {
                            await sync.catchUpChannel(connection, workspace, channelId: channel.id, priority: .background)
                        }
                    }
                }
            }
        }
    }
}
