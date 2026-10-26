import Foundation

/// Whom a device token currently speaks for. A change of any part (another Tower, another signer, a different set of
/// workspaces) means the token must not stay registered under the old binding.
public struct PushBinding: Sendable, Codable, Equatable {
    public let origin: String
    public let signerNpub: String
    /// Workspace id (lowercase) → the app npub Tower scopes that workspace's requests with.
    public let appNpubs: [String: String]

    public var workspaceIds: [String] { appNpubs.keys.sorted() }

    public init(origin: TowerOrigin, signerNpub: String, workspaces: [String: String]) {
        self.origin = origin.description
        self.signerNpub = signerNpub
        appNpubs = Dictionary(workspaces.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Everything persisted about this installation's alerts. The device token is private to this record: it appears in
/// the registration body only and is never logged, shown or copied into diagnostics.
public struct PushInstallationState: Sendable, Codable, Equatable {
    /// Created once per installation and kept across disconnects, so Tower sees one stable device.
    /// Rotated whenever the signer changes or the registration is withdrawn: Tower binds an installation id to the actor
    /// that first used it (`409 installation_owned`), so a new person on this device must not reuse it. Revocations still
    /// owed keep the id they were registered under.
    public internal(set) var installationId: String
    /// True after the person pressed Enable Notifications; false after Disable.
    public var enabled = false
    public var tokenHex: String?
    public var tokenEnvironment: PushEnvironment?
    /// Whom the registered rows belong to; nil when nothing is registered.
    public var binding: PushBinding?
    /// Lease expiry per workspace for rows Tower has acknowledged under `binding`.
    public var enrolled: [String: Date] = [:]
    public var pendingRevocations: [PendingPushRevocation] = []
    /// Tower's last statement about whether it can deliver (nil: not told yet, or an older Tower without the field).
    public var deliveryReady: Bool?
    public var deliveryReason: String?
    /// Last visible problem, already worded for the person (never contains the token).
    public var lastProblem: String?
    /// Tower answered that it cannot deliver alerts (no APNs route or provider); retried no sooner than `unavailableRetry`.
    public var providerUnavailableAt: Date?

    public init(installationId: String = UUID().uuidString.lowercased()) { self.installationId = installationId }
}

/// Where the state lives (the app store's key/value table; fakes in tests).
public protocol PushPersistence: Sendable {
    func load() async -> PushInstallationState?
    func save(_ state: PushInstallationState) async
}

public struct PushStatePersistence: PushPersistence {
    public static let key = "push.installation.v1"
    private let store: LocalStore

    public init(store: LocalStore) { self.store = store }

    public func load() async -> PushInstallationState? {
        guard let text = try? await store.reader.state(Self.key), let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PushInstallationState.self, from: data)
    }

    public func save(_ state: PushInstallationState) async {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state), let text = String(data: data, encoding: .utf8) else { return }
        try? await store.writer.setState(Self.key, text)
    }
}
