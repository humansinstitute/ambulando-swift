import Foundation
import CryptoKit

struct IndexValue: Decodable, Sendable {
    let string: String?, int: Int?, bool: Bool?, object: [String: IndexValue]?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        string = try? c.decode(String.self); int = try? c.decode(Int.self)
        bool = try? c.decode(Bool.self); object = try? c.decode([String: IndexValue].self)
    }
}

/// A relay locator is only a hint. Full fresh Tower membership is checked before exposing its origin.
public struct WorkspaceIndexLocator: Sendable, Equatable {
    public let origin: String, workspaceId: String, tower: String, service: String, owner: String, app: String
    init(_ value: [String: IndexValue]) throws {
        let fields = value["identity"]?.object ?? value
        guard value["type"]?.string == "wingman_workspace_locator", value["version"]?.int == 1,
              let origin = value["tower_base_url"]?.string,
              let wid = fields["workspace_id"]?.string, UUID(uuidString: wid) != nil else { throw TowerError.malformed("workspace index") }
        self.origin = try TowerOrigin(origin).description
        workspaceId = wid.lowercased()
        tower = fields["tower_service_npub"]?.string ?? ""
        service = fields["workspace_service_npub"]?.string ?? ""
        owner = fields["workspace_owner_npub"]?.string ?? ""
        app = fields["app_npub"]?.string ?? ""
        guard [tower,service,owner,app].allSatisfy(NostrKeys.isValidNpub) else { throw TowerError.malformed("workspace index identity") }
    }
    func matches(_ identity: [String: IndexValue]) -> Bool {
        identity["workspace_id"]?.string?.lowercased() == workspaceId && identity["tower_service_npub"]?.string == tower
        && identity["workspace_service_npub"]?.string == service && identity["workspace_owner_npub"]?.string == owner && identity["app_npub"]?.string == app
    }
}

public enum WorkspaceIndex {
    /// Public-only hash-to-point namespace; not a user signer, APK certificate or locator app.
    public static let appPubkey = "5494fba97efec3d5d9c66047b17d2172bc6a8bd02e6d539b93d9353d7dcaf553"
    public static let appNpub = "npub12j20h2t7lmpatkwxvprmzlfpw27x4z7s9ek48xunmy6n6lw274fs40dp7t"
    public static func verifyPublication(_ event: NostrEvent, acknowledged: Bool, readback: [NostrEvent]) throws {
        guard acknowledged, SignatureVerifier.verify(event), readback.contains(where: { $0 == event && SignatureVerifier.verify($0) })
        else { throw TowerError.malformed("index ACK or exact readback missing") }
    }
    public static let relays = ["wss://relay.primal.net", "wss://relay.damus.io"]
    public static func latest(_ events: [NostrEvent], user: String, now: Int = Int(Date().timeIntervalSince1970)) -> [NostrEvent] {
        var seen = Set<String>()
        return events.sorted { $0.created_at == $1.created_at ? $0.id < $1.id : $0.created_at > $1.created_at }.filter { e in
            let tags = e.tags.filter { $0.first == "d" }
            guard e.kind == 33356, e.pubkey == user, e.created_at <= now + 300, SignatureVerifier.verify(e), !tags.isEmpty, tags[0].count >= 2 else { return false }
            return seen.insert(tags[0][1]).inserted
        }
    }
    public static func decode(_ e: NostrEvent, user: String, plaintext: Data) throws -> (locator: WorkspaceIndexLocator, deleted: Bool) {
        func tag(_ key: String) throws -> String {
            let tags = e.tags.filter { $0.first == key }
            guard tags.count == 1, tags[0].count == 2 else { throw TowerError.malformed("index tags") }
            return tags[0][1]
        }
        guard e.kind == 33356, e.pubkey == user, SignatureVerifier.verify(e), try tag("p") == user,
              try tag("protocol") == "workspace-self-index", try tag("v") == "1",
              e.created_at <= Int(Date().timeIntervalSince1970) + 300 else { throw TowerError.malformed("index event") }
        let p = try JSONDecoder().decode([String: IndexValue].self, from: plaintext)
        let app = try tag("app_pub")
        guard let appNpub = NostrKeys.npub(publicKeyHex: app) else { throw TowerError.malformed("index app key") }
        guard p["type"]?.string == "flightdeck_workspace_self_index", p["version"]?.int == 1,
              p["user_npub"]?.string == NostrKeys.npub(publicKeyHex: user),
              p["app"]?.object?["namespace"]?.string == "flightdeck_pg",
              p["app"]?.object?["app_pubkey"]?.string == app,
              p["app"]?.object?["app_npub"]?.string == appNpub,
              let deleted = p["state"]?.object?["deleted"]?.bool,
              let workspace = p["workspace"]?.object else { throw TowerError.malformed("index payload") }
        let locator = try WorkspaceIndexLocator(workspace)
        let address = "fd-self:" + SHA256.hash(data: Data("v1:\(user):\(app):\(locator.tower):\(locator.workspaceId)".utf8)).map { String(format:"%02x",$0) }.joined()
        guard try tag("d") == address else { throw TowerError.malformed("index address") }
        return (locator,deleted)
    }
}

/// Bounded secure relay querying; no app_pub filter, contact access, persistence or Tower authority.
public actor WorkspaceIndexRelay {
    public init() {}
    func receive(_ task: URLSessionWebSocketTask) async throws -> [Any] {
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                switch try await task.receive() {
                case .data(let d): return d
                case .string(let s): return Data(s.utf8)
                @unknown default: throw TowerError.malformed("relay frame")
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                task.cancel(with: .goingAway, reason: nil)
                throw TowerError.malformed("relay timeout")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard data.count <= 200_000, let frame = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw TowerError.malformed("relay frame") }
        return frame
    }
    public func query(_ relay: String, user: String, eventId: String? = nil) async throws -> [NostrEvent] {
        guard let url = URL(string: relay), url.scheme == "wss", url.host != nil, url.user == nil, url.password == nil else { throw TowerError.unsafeOrigin }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let sub = UUID().uuidString
        let filter: [String: Any] = eventId.map { ["ids":[$0],"limit":1] } ?? ["kinds":[33356],"authors":[user],"#p":[user],"limit":1000]
        let request = try JSONSerialization.data(withJSONObject: ["REQ",sub,filter])
        try await task.send(.string(String(decoding:request,as:UTF8.self)))
        var result = [NostrEvent]()
        let deadline = Date().addingTimeInterval(25)
        for _ in 0..<2000 {
            guard Date() < deadline, result.count < 1000 else { throw TowerError.malformed("incomplete relay query") }
            let frame = try await receive(task)
            if frame.count >= 2, frame[0] as? String == "EOSE", frame[1] as? String == sub { return result }
            if frame.first as? String == "CLOSED" { throw TowerError.malformed("relay refused discovery") }
            if frame.count == 3, frame[0] as? String == "EVENT", frame[1] as? String == sub,
               let event = try? JSONDecoder().decode(NostrEvent.self, from: JSONSerialization.data(withJSONObject:frame[2])) { result.append(event) }
        }
        throw TowerError.malformed("incomplete relay query")
    }
    public func publish(_ event: NostrEvent, to relay: String) async throws {
        guard SignatureVerifier.verify(event), event.kind == 33356,
              let url = URL(string: relay), url.scheme == "wss", url.host != nil, url.user == nil, url.password == nil else { throw TowerError.unsafeOrigin }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let bytes = try JSONSerialization.data(withJSONObject:["EVENT",event.jsonObject])
        try await task.send(.string(String(decoding:bytes,as:UTF8.self)))
        var accepted = false
        let deadline = Date().addingTimeInterval(25)
        for _ in 0..<100 {
            guard Date() < deadline else { break }
            let frame = try await receive(task)
            if frame.count >= 3, frame[0] as? String == "OK", frame[1] as? String == event.id {
                guard frame[2] as? Bool == true else { throw TowerError.malformed("relay rejected index") }
                accepted = true; break
            }
        }
        guard accepted else { throw TowerError.malformed("index ACK missing") }
        let returned = try await query(relay,user:event.pubkey,eventId:event.id)
        try WorkspaceIndex.verifyPublication(event,acknowledged:accepted,readback:returned)
    }

}

extension WorkspaceSync {
    /// Authenticates each independent candidate without replacing a connection or any workspace data.
    public func discoverTowerIndexes() async throws -> [String] {
        guard case .unlocked = await identity.state else { throw IdentityError.locked }
        let user = try await identity.publicKeyHex()
        var events = [NostrEvent](), answered = false
        for relay in WorkspaceIndex.relays {
            if let received = try? await WorkspaceIndexRelay().query(relay,user:user) { events += received; answered = true }
        }
        guard answered else { throw TowerError.malformed("relay discovery; retry or enter your Tower address") }
        return try await verifiedTowerIndexes(events: events)
    }
    public func verifiedTowerIndexes(events: [NostrEvent]) async throws -> [String] {
        guard case .unlocked = await identity.state else { throw IdentityError.locked }
        let user = try await identity.publicKeyHex()
        let latest = WorkspaceIndex.latest(events,user:user)
        guard latest.count <= 100 else { throw TowerError.malformed("index candidate limit") }
        var origins = Set<String>()
        for event in latest {
            do {
                let decoded = try WorkspaceIndex.decode(event,user:user,plaintext:await identity.decryptWorkspaceIndex(event.content))
                if decoded.deleted { continue }
                let loc = decoded.locator
                let client = TowerClient(origin:try TowerOrigin(loc.origin),transport:transport,signer:identity)
                let bytes = try await client.request(path:"/api/v4/flightdeck-pg/workspaces/\(loc.workspaceId)/me",appNpub:loc.app)
                let me = try JSONDecoder().decode([String:IndexValue].self,from:bytes)
                guard let returned = me["identity"]?.object, loc.matches(returned) else { continue }
                origins.insert(loc.origin)
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        try await identity.requireSigner(npub: NostrKeys.npub(publicKeyHex:user)!)
        return origins.sorted()
    }
}

extension WorkspaceSync {
    /// Build only after re-verifying all locator fields against fresh authenticated membership.
    public func workspaceIndexEvent(connection: ConnectionRecord, workspace: WorkspaceRecord) async throws -> NostrEvent {
        try await identity.requireSigner(npub:connection.signerNpub)
        let user = try await identity.publicKeyHex()
        let raw = try JSONDecoder().decode([String:IndexValue].self,from:workspace.raw)
        let fields = raw["identity"]?.object ?? raw
        let candidate: [String:Any] = ["type":"wingman_workspace_locator","version":1,
            "tower_base_url":connection.origin,"label":workspace.label,
            "workspace_id":workspace.id,"app_npub":workspace.appNpub,
            "tower_service_npub":fields["tower_service_npub"]?.string ?? "",
            "workspace_service_npub":fields["workspace_service_npub"]?.string ?? "",
            "workspace_owner_npub":fields["workspace_owner_npub"]?.string ?? ""]
        let encoded = try JSONSerialization.data(withJSONObject:candidate)
        let loc = try WorkspaceIndexLocator(JSONDecoder().decode([String:IndexValue].self,from:encoded))
        let client = TowerClient(origin:try TowerOrigin(connection.origin),transport:transport,signer:identity)
        let response = try await client.request(path:"/api/v4/flightdeck-pg/workspaces/\(loc.workspaceId)/me",appNpub:loc.app)
        let me = try JSONDecoder().decode([String:IndexValue].self,from:response)
        guard let returned = me["identity"]?.object, loc.matches(returned) else { throw TowerError.malformed("index membership identity") }
        let time = ISO8601DateFormatter().string(from:Date())
        let payload: [String:Any] = ["type":"flightdeck_workspace_self_index","version":1,
            "user_npub":connection.signerNpub,"issued_at":time,"updated_at":time,
            "app":["app_npub":WorkspaceIndex.appNpub,"app_pubkey":WorkspaceIndex.appPubkey,"namespace":"flightdeck_pg"],
            "workspace":candidate,"state":["deleted":false]]
        let address = "fd-self:" + SHA256.hash(data:Data("v1:\(user):\(WorkspaceIndex.appPubkey):\(loc.tower):\(loc.workspaceId)".utf8)).map{String(format:"%02x",$0)}.joined()
        let ciphertext = try await identity.encryptWorkspaceIndex(JSONSerialization.data(withJSONObject:payload))
        try await identity.requireSigner(npub:connection.signerNpub)
        return try await identity.sign(NostrEventTemplate(kind:33356,tags:[["d",address],["p",user],["app_pub",WorkspaceIndex.appPubkey],["protocol","workspace-self-index"],["v","1"]],content:ciphertext,createdAt:Int(Date().timeIntervalSince1970)))
    }
    public func publishWorkspaceIndex(connection: ConnectionRecord, workspace: WorkspaceRecord) async throws {
        let event = try await workspaceIndexEvent(connection:connection,workspace:workspace)
        var completed = false
        for relay in WorkspaceIndex.relays {
            do {
                try await WorkspaceIndexRelay().publish(event,to:relay)
                _ = try WorkspaceIndex.decode(event,user:event.pubkey,plaintext:await identity.decryptWorkspaceIndex(event.content))
                completed = true
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        guard completed else { throw TowerError.malformed("index publication pending; connection retained") }
    }
}
