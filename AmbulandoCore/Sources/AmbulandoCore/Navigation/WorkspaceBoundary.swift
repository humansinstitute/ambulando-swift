import Foundation

/// Local resource identity. Server UUIDs are meaningful only within this complete boundary.
public struct WorkspaceBoundary: Hashable, Codable, Sendable, Identifiable {
    public let origin: String
    public let signerNpub: String
    public let workspaceId: String
    public let appNpub: String

    public init(connection: ConnectionRecord, workspace: WorkspaceRecord) throws {
        origin = try TowerOrigin(connection.origin).description
        signerNpub = connection.signerNpub
        workspaceId = workspace.id
        appNpub = workspace.appNpub
    }

    public var id: String { Self.digest([origin, signerNpub, appNpub, workspaceId]) }
    public var connectionNamespace: String { Self.digest([origin, signerNpub]) }

    /// Length-delimited fields avoid delimiter collisions; namespace versions make future changes explicit.
    public static func digest(_ fields: [String]) -> String {
        SHA256Hex.of(Data(("ambulando.boundary.v1|" + fields.map { "\($0.utf8.count):\($0)" }.joined()).utf8))
    }
}

/// A route from shared navigation always carries its exact account and application boundary.
public struct WorkspaceNavigationTarget: Hashable, Codable, Sendable {
    public var boundary: WorkspaceBoundary
    public var scopeId: String?
    public var channelId: String?

    public init(boundary: WorkspaceBoundary, scopeId: String? = nil, channelId: String? = nil) {
        self.boundary = boundary; self.scopeId = scopeId; self.channelId = channelId
    }
}

/// Durable local preferences. Empty enabled lists are intentional, rather than an instruction to select a default.
public struct WorkspacePreferences: Codable, Sendable, Equatable {
    public var enabled: [String]
    public var order: [String]
    public var collapsed: Set<String>
    public var colours: [String: WorkspaceColour]

    public init(enabled: [String] = [], order: [String] = [], collapsed: Set<String> = [], colours: [String: WorkspaceColour] = [:]) {
        self.enabled = enabled; self.order = order; self.collapsed = collapsed; self.colours = colours
    }

    public mutating func setEnabled(_ id: String, _ value: Bool) {
        enabled.removeAll { $0 == id }
        if value { enabled.append(id) }
        if !order.contains(id) { order.append(id) }
    }

    public func sorted(_ ids: [String]) -> [String] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.sorted { (rank[$0] ?? Int.max, $0) < (rank[$1] ?? Int.max, $1) }
    }
}

/// Dark swatches have white text contrast above WCAG AA. Names accompany colour everywhere.
public enum WorkspaceColour: String, Codable, Sendable, CaseIterable {
    case blue, green, purple, red, slate
    public var rgb: UInt32 {
        switch self {
        case .blue: 0x174EA6
        case .green: 0x146C43
        case .purple: 0x63339A
        case .red: 0xA52834
        case .slate: 0x394956
        }
    }
}

/// Explicit local user preference; editor drafts never supply this value.
public enum DocumentOpeningMode: String, CaseIterable, Sendable {
    case view, edit

    public static func key(userNpub: String) -> String {
        "native.document-opening-mode.v1:" + WorkspaceBoundary.digest([userNpub])
    }

    public static func load(store: LocalStore, userNpub: String) async throws -> Self {
        guard !userNpub.isEmpty else { return .view }
        return Self(rawValue: try await store.reader.state(key(userNpub: userNpub)) ?? "") ?? .view
    }

    public func save(store: LocalStore, userNpub: String) async throws {
        guard !userNpub.isEmpty else { return }
        try await store.writer.setState(Self.key(userNpub: userNpub), rawValue)
    }
}
