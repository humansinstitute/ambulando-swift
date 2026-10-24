import Foundation
@testable import AmbulandoCore

/// Public NIP-19 specification test key. Never a real user identity.
enum TestKeys {
    static let nsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
    static let secretHex = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"
    static let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
    static let pubkeyHex = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
    static let pin = "246810"

    static func otherNsec() -> String { Bech32.encode(hrp: "nsec", data: Data(repeating: 0x11, count: 32)) }
}

final class MemorySecretStore: VaultSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private(set) var writes = 0
    func read() throws -> Data? { lock.withLock { value } }
    func write(_ data: Data) throws { lock.withLock { value = data; writes += 1 } }
}

func temporaryDirectory(_ name: String = #function) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ambulando-tests", isDirectory: true)
        .appendingPathComponent(name.filter { $0.isLetter || $0.isNumber } + "-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeIdentity(unlocked: Bool = true, directory: URL = temporaryDirectory()) async throws -> IdentityService {
    let service = IdentityService(vaultURL: directory.appendingPathComponent("vault.json"), secrets: MemorySecretStore())
    try await service.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
    if !unlocked { await service.lock() }
    return service
}

/// Records requests and answers from a routing closure. No network is touched.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Any)
    private let lock = NSLock()
    private var handler: Handler
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    func setHandler(_ handler: @escaping Handler) { lock.withLock { self.handler = handler } }
    var recorded: [URLRequest] { lock.withLock { requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let current = lock.withLock { requests.append(request); return handler }
        let (status, body) = try current(request)
        let data = try (body as? Data) ?? JSONSerialization.data(withJSONObject: body)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

func decodeAuthorization(_ request: URLRequest) throws -> NostrEvent {
    let header = try XCTUnwrapValue(request.value(forHTTPHeaderField: "Authorization"))
    guard header.hasPrefix("Nostr "), let data = Data(base64Encoded: String(header.dropFirst(6))) else { throw TowerError.malformed("auth") }
    return try JSONDecoder().decode(NostrEvent.self, from: data)
}

func XCTUnwrapValue<T>(_ value: T?) throws -> T {
    guard let value else { throw TowerError.malformed("nil") }
    return value
}

enum Fixtures {
    static let workspaceId = "2e5caefd-0000-4000-8000-000000000001"
    static let workspaceId2 = "2e5caefd-0000-4000-8000-000000000002"
    static let appNpub = TestKeys.npub
    static let scopeA = "76d518f7-0000-4000-8000-00000000000a"
    static let scopeB = "76d518f7-0000-4000-8000-00000000000b"
    static let channel1 = "0617d526-0000-4000-8000-000000000001"
    static let channel2 = "0617d526-0000-4000-8000-000000000002"

    static func descriptor(origin: String, fips: Bool = false, protocols: [String] = ["https", "nip-98"]) -> [String: Any] {
        var services: [[String: Any]] = [[
            "id": "tower", "kind": "tower", "endpoint": origin, "version": "0.1.0", "protocols": protocols,
            "capabilities": ["workspace.authenticated_discovery", "flightdeck.pg"], "availability": ["status": "available"],
        ]]
        if fips { services.append(["id": "fips", "kind": "fips", "endpoint": "http://npub1x.fips:8080"]) }
        return ["schema": "org.wingman.nstack.services", "schema_version": 1, "stack": ["tower_npub": TestKeys.npub, "name": NSNull()], "services": services]
    }

    static func workspace(_ id: String, label: String) -> [String: Any] {
        ["identity": ["workspace_id": id, "app_npub": appNpub, "workspace_owner_npub": TestKeys.npub],
         "label": label, "slug": label.lowercased(), "tower_base_url": "https://tower.example", "membership": ["role": "member"]]
    }

    static func scope(_ id: String, workspace: String = workspaceId, name: String, updated: String = "2026-10-01T00:00:00.000Z") -> [String: Any] {
        ["id": id, "workspace_id": workspace, "name": name, "description": NSNull(), "kind": "project", "owner_actor_id": NSNull(),
         "owner_group_id": NSNull(), "default_channel_id": NSNull(), "row_version": 1, "created_at": updated, "updated_at": updated]
    }

    static func channel(_ id: String, scope: String, workspace: String = workspaceId, name: String, position: Double? = nil,
                        updated: String = "2026-10-01T00:00:00.000Z") -> [String: Any] {
        ["id": id, "workspace_id": workspace, "scope_id": scope, "name": name, "description": NSNull(), "metadata": [:],
         "kind": "channel", "position": position.map { $0 as Any } ?? NSNull(), "participant_npubs": NSNull(),
         "row_version": 1, "created_at": updated, "updated_at": updated]
    }

    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
}
