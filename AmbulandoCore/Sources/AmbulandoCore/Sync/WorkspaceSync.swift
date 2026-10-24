import Foundation

/// The WP2 read path: nStack descriptor → workspace discovery → scopes → channels, materialised into
/// the local store. All work is scheduled through `SyncEngine`; views only read the store.
public struct WorkspaceSync: Sendable {
    public let store: LocalStore
    public let engine: SyncEngine
    public let identity: IdentityService
    public let transport: HTTPTransport

    public init(store: LocalStore, engine: SyncEngine, identity: IdentityService, transport: HTTPTransport) {
        self.store = store; self.engine = engine; self.identity = identity; self.transport = transport
    }

    func api(origin: TowerOrigin, signed: Bool = true) -> TowerAPI {
        TowerAPI(client: TowerClient(origin: origin, transport: transport, signer: signed ? identity : nil))
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
        await engine.enqueue("discover:\(connection.id)", priority: priority, force: force) {
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            let origin = try TowerOrigin(connection.origin)
            let workspaces = try await sync.api(origin: origin).workspaces()
            try Task.checkCancellation()
            try await sync.store.writer.replaceWorkspaces(connectionId: connection.id, workspaces)
            for workspace in workspaces { await sync.refreshWorkspace(connection, workspace, priority: .background) }
        }
    }

    /// Scopes job for one workspace; on success schedules one channel job per scope.
    public func refreshWorkspace(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, priority: SyncPriority = .visible, force: Bool = false) async {
        let sync = self
        await engine.enqueue("scopes:\(workspace.id)", priority: priority, force: force) {
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            let scopes = try await api.scopes(workspaceId: workspace.id, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            try await sync.store.writer.upsertScopes(workspaceId: workspace.id, scopes, complete: true)
            for scope in scopes {
                await sync.engine.enqueue("channels:\(workspace.id):\(scope.id)", priority: priority) {
                    try await sync.identity.requireSigner(npub: connection.signerNpub)
                    let channels = try await api.channels(workspaceId: workspace.id, scopeId: scope.id, appNpub: workspace.appNpub)
                    try Task.checkCancellation()
                    try await sync.store.writer.upsertChannels(workspaceId: workspace.id, scopeId: scope.id, channels, complete: true)
                }
            }
        }
    }
}
