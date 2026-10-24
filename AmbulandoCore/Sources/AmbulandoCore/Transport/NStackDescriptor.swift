import Foundation

/// Public nStack service descriptor (`GET /.well-known/nstack.json`, schema
/// `org.wingman.nstack.services` v1; tower/docs/nstack-services.md). It is metadata only, never an authority grant.
public struct NStackDescriptor: Sendable, Equatable, Decodable {
    public struct Service: Sendable, Equatable, Decodable {
        public struct Availability: Sendable, Equatable, Decodable { public let status: String? }
        public let id: String
        public let kind: String
        public let endpoint: String?
        public let version: String?
        public let protocols: [String]?
        public let capabilities: [String]?
        public let availability: Availability?
    }
    public struct Stack: Sendable, Equatable, Decodable { public let tower_npub: String?; public let name: String? }

    public let schema: String
    public let schema_version: Int
    public let stack: Stack?
    public let services: [Service]

    public var tower: Service? { services.first { $0.kind == "tower" } }

    /// True when the descriptor advertises any FIPS service. Native cannot use it (HTTPS only).
    public var advertisesFIPS: Bool {
        services.contains { $0.kind.lowercased().contains("fips") || ($0.endpoint ?? "").lowercased().contains(".fips") }
    }

    /// Validates the schema and that the advertised Tower endpoint is the same HTTPS origin the user chose.
    public static func parse(_ data: Data, expectedOrigin: TowerOrigin) throws -> NStackDescriptor {
        let descriptor: NStackDescriptor
        do { descriptor = try JSONDecoder().decode(NStackDescriptor.self, from: data) } catch { throw TowerError.descriptor("unreadable JSON") }
        guard descriptor.schema == "org.wingman.nstack.services", descriptor.schema_version == 1 else {
            throw TowerError.descriptor("unsupported schema \(descriptor.schema) v\(descriptor.schema_version)")
        }
        guard let tower = descriptor.tower, let endpoint = tower.endpoint else { throw TowerError.descriptor("no Tower service") }
        let advertised: TowerOrigin
        do { advertised = try TowerOrigin(endpoint) } catch { throw TowerError.descriptor("Tower endpoint is not an HTTPS origin") }
        guard advertised == expectedOrigin else { throw TowerError.descriptor("Tower endpoint \(advertised) differs from \(expectedOrigin)") }
        guard tower.protocols?.contains("nip-98") == true else { throw TowerError.descriptor("Tower does not advertise NIP-98") }
        return descriptor
    }
}

/// Typed Tower reads used by the sync engine. Paths are built only from validated UUIDs.
public struct TowerAPI: Sendable {
    public let client: TowerClient
    /// Background transfers for presigned object-store URLs; nil means in-process transfers.
    public let transfers: BackgroundTransfers?
    public init(client: TowerClient, transfers: BackgroundTransfers? = nil) { self.client = client; self.transfers = transfers }

    static func base(_ workspaceId: String) throws -> String {
        guard UUID(uuidString: workspaceId) != nil else { throw TowerError.unsafePath }
        return "/api/v4/flightdeck-pg/workspaces/" + workspaceId
    }

    public func descriptor() async throws -> NStackDescriptor {
        try NStackDescriptor.parse(try await client.getPublic(path: "/.well-known/nstack.json"), expectedOrigin: client.origin)
    }

    public func workspaces() async throws -> [WorkspaceRecord] {
        try await client.list(path: "/api/v4/flightdeck-pg/workspaces", appNpub: nil, key: "workspaces").map(WorkspaceRecord.init(raw:))
    }

    public func scopes(workspaceId: String, appNpub: String) async throws -> [ScopeRecord] {
        try await client.list(path: try Self.base(workspaceId) + "/scopes", appNpub: appNpub, key: "scopes").map(ScopeRecord.init(raw:))
    }

    public func channels(workspaceId: String, scopeId: String, appNpub: String) async throws -> [ChannelRecord] {
        guard UUID(uuidString: scopeId) != nil else { throw TowerError.unsafePath }
        return try await client.list(path: try Self.base(workspaceId) + "/scopes/" + scopeId + "/channels", appNpub: appNpub, key: "channels")
            .map(ChannelRecord.init(raw:))
    }
}
