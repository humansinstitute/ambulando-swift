import AmbulandoCore
import Foundation
import Observation

/// Deterministic local sample data for UI automation and demos, enabled only in Debug builds with the
/// `-AmbulandoUITestFixture` launch argument. Every app code path (identity vault, signing, store, sync engine,
/// outbox) runs for real; only the network transport is replaced by an in-process stand-in for Tower, so nothing
/// leaves the device. The identity is a throwaway key generated on first fixture launch, never a user's key.
/// The UI labels this mode on every screen; it is not evidence of live Tower behaviour.
@MainActor
@Observable
final class FixtureEnvironment {
    nonisolated static let origin = "https://fixture.ambulando.invalid"
    nonisolated static let pin = "135790"
    let studioWorkspaceId = FixtureTower.studio
    let directory: URL
    let tower: FixtureTower
    let secrets: VaultSecretStore
    private let startLocked: Bool
    private let storm: Bool
    /// Control run for the storm check: same typing and probe window, no database writes.
    private let stormControl: Bool
    private(set) var stormStatus: String?

    var offline: Bool {
        get { access(keyPath: \.offline); return tower.offline }
        set { withMutation(keyPath: \.offline) { tower.offline = newValue } }
    }
    var rejectNextSend: Bool {
        get { access(keyPath: \.rejectNextSend); return tower.rejectNext }
        set { withMutation(keyPath: \.rejectNextSend) { tower.rejectNext = newValue } }
    }

    private init(directory: URL, startLocked: Bool, storm: Bool, stormControl: Bool, offline: Bool) {
        self.directory = directory
        self.startLocked = startLocked
        self.storm = storm || stormControl
        self.stormControl = stormControl
        tower = FixtureTower(file: directory.appendingPathComponent("fixture-tower.json"))
        tower.offline = offline
        secrets = KeychainVaultSecretStore(service: "studio.otherstuff.ambulando.native.fixture-vault.v1")
    }

    static func fromLaunchArguments() -> FixtureEnvironment? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-AmbulandoUITestFixture") else { return nil }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AmbulandoFixture", isDirectory: true)
        if args.contains("-AmbulandoFixtureReset") { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FixtureEnvironment(directory: directory, startLocked: args.contains("-AmbulandoFixtureLocked"),
                                  storm: args.contains("-AmbulandoFixtureStorm"), stormControl: args.contains("-AmbulandoFixtureStormControl"),
                                  offline: args.contains("-AmbulandoFixtureOffline"))
        #else
        return nil
        #endif
    }

    /// First launch: create the throwaway identity and connect through the normal descriptor/discovery path.
    func prepare(identity: IdentityService, sync: WorkspaceSync, store: LocalStore) async throws {
        if case .none = await identity.state {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { throw IdentityError.keychainUnavailable }
            try await identity.importIdentity(nsec: Bech32.encode(hrp: "nsec", data: Data(bytes)), pin: Self.pin)
            await identity.lock()
        }
        if !startLocked { try await identity.unlock(pin: Self.pin) }
        if let npub = await identity.state.npub { tower.actorNpub = npub }
        if try await store.reader.connections().isEmpty, case .unlocked = await identity.state {
            let connection = try await sync.connect(origin: try TowerOrigin(Self.origin))
            try await store.writer.setState("selected.connection", connection.id)
            try await store.writer.setState("selected.workspace:\(connection.id)", FixtureTower.studio)
            await sync.discover(connection, priority: .visible, force: true)
            await sync.engine.waitUntilIdle()
        }
    }

    /// Sync storm for the responsiveness check: 20,000 messages materialised into another channel of the visible
    /// workspace in 500-row transactions (as catch-up would), while the main-actor probe samples latency.
    func startStormIfRequested(store: LocalStore, workspaceId: String) {
        guard storm, stormStatus == nil else { return }
        stormStatus = "storm: running"
        Task { [weak self] in
            let text = await Self.runStorm(store: store, workspaceId: workspaceId, writes: !(self?.stormControl ?? false))
            self?.stormStatus = text
        }
    }

    nonisolated private static func runStorm(store: LocalStore, workspaceId: String, writes: Bool) async -> String {
        await Task.detached(priority: .utility) {
            // The probe covers exactly the storm window (which overlaps typing), not launch or navigation.
            let done = StormFlag()
            async let report = MainActorProbe.measure { await done.value }
            let clock = ContinuousClock(), start = clock.now
            for batch in 0..<40 {
                let rows = (0..<500).map { i -> MessageRecord in
                    let n = batch * 500 + i
                    return MessageRecord(workspaceId: workspaceId, id: UUID().uuidString.lowercased(), channelId: FixtureTower.designChannel,
                                         threadId: nil, body: "Storm message \(n) " + String(repeating: "lorem ipsum ", count: 12),
                                         senderNpub: FixtureTower.ana,
                                         createdAt: String(format: "2026-10-01T%02d:%02d:%02d.%03dZ", (n / 3600) % 24, (n / 60) % 60, n % 60, n % 1000))
                }
                if writes { _ = try? await store.writer.upsertMessages(rows) }
                try? await Task.sleep(for: .milliseconds(50))   // paced like network pages, so the storm lasts while typing
            }
            let elapsed = clock.now - start
            await done.set()
            let probe = await report
            return String(format: "storm: done rows=%d window=%.0fms probe n=%d p99=%.2fms max=%.2fms", writes ? 20000 : 0,
                          Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
                          probe.count, probe.percentile(99), probe.max)
        }.value
    }
}

actor StormFlag {
    var value = false
    func set() { value = true }
}

/// In-process stand-in for the Tower chat routes used by this app, persisted to the fixture directory.
/// It follows the route contracts (forward cursor paging, `create_thread`, `client_request_id` replay,
/// kind 33358 content/tag checks) closely enough for UI automation; it is not Tower.
final class FixtureTower: HTTPTransport, @unchecked Sendable {
    static let studio = "f1c70000-0000-4000-8000-000000000001"
    static let lab = "f1c70000-0000-4000-8000-000000000002"
    static let scopeAmbulando = "f1c70000-0000-4000-8000-0000000000a1"
    static let scopeOps = "f1c70000-0000-4000-8000-0000000000a2"
    static let scopeResearch = "f1c70000-0000-4000-8000-0000000000a3"
    static let generalChannel = "f1c70000-0000-4000-8000-0000000000c1"
    static let designChannel = "f1c70000-0000-4000-8000-0000000000c2"
    static let deploysChannel = "f1c70000-0000-4000-8000-0000000000c3"
    static let notesChannel = "f1c70000-0000-4000-8000-0000000000c4"
    static let ana = Bech32.encode(hrp: "npub", data: Data(repeating: 0xA1, count: 32))
    static let rick = Bech32.encode(hrp: "npub", data: Data(repeating: 0xB2, count: 32))
    static let appNpub = Bech32.encode(hrp: "npub", data: Data(repeating: 0xC3, count: 32))

    private let lock = NSLock()
    private let file: URL
    private var posted: [[String: Any]] = []
    private var requests: [String: [String: Any]] = [:]
    private var _offline = false, _rejectNext = false
    private var _actor = ""

    var offline: Bool { get { lock.withLock { _offline } } set { lock.withLock { _offline = newValue } } }
    var rejectNext: Bool { get { lock.withLock { _rejectNext } } set { lock.withLock { _rejectNext = newValue } } }
    var actorNpub: String { get { lock.withLock { _actor } } set { lock.withLock { _actor = newValue } } }

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            posted = rows
            for row in rows { if let id = row["client_request_id"] as? String { requests[id] = row } }
        }
    }

    private func persist() {
        if let data = try? JSONSerialization.data(withJSONObject: posted) { try? data.write(to: file, options: .atomic) }
    }

    private static func uuid(_ n: Int, _ prefix: String) -> String { String(format: "\(prefix)-0000-4000-8000-%012d", n) }
    private static func time(_ n: Int) -> String { String(format: "2026-10-23T%02d:%02d:00.000Z", 8 + n / 60, n % 60) }

    /// Seeded history: general has 40 conversations (one with replies), design/deploys/notes a few each.
    private var seeded: [[String: Any]] {
        var rows: [[String: Any]] = []
        func add(_ n: Int, _ workspace: String, _ channel: String, _ body: String, sender: String, label: String, thread: String? = nil) {
            let id = Self.uuid(n, "f1c7aaaa")
            let threadId = thread ?? Self.uuid(n, "f1c7bbbb")
            let source = thread == nil ? id : Self.uuid(Int(thread!.suffix(12))!, "f1c7aaaa")
            rows.append(["id": id, "workspace_id": workspace, "channel_id": channel, "thread_id": threadId, "thread_source_message_id": source,
                         "body": body, "client_request_id": NSNull(), "record_state": "active", "row_version": 1, "sender_npub": sender,
                         "created_by_actor_label": label, "created_at": Self.time(n), "updated_at": Self.time(n)])
        }
        let topics = ["Walkthrough notes for the passage screens", "Theme tokens are synced with the web app", "Who owns the deploy checklist?",
                      "Draft agenda for Thursday", "Sync storm results look good", "Native chat review", "Docs index needs a refresh",
                      "Files upload uses storage prepare", "Inbox counts mentions and tasks", "Release notes for build 2"]
        for n in 1...40 {
            let ana = n % 3 != 0
            var body = "\(topics[(n - 1) % topics.count]) (#\(n))"
            if n == 38 { body = "@[Rick](mention:agent:\(Self.rick)) can you check the outbox retry states?" }
            add(n, Self.studio, Self.generalChannel, body, sender: ana ? Self.ana : Self.rick, label: ana ? "Ana" : "Rick")
        }
        let thread = Self.uuid(39, "f1c7bbbb")
        for (i, text) in ["Looks right on my phone", "Retry kept the same request id", "Ship it"].enumerated() {
            add(100 + i, Self.studio, Self.generalChannel, text, sender: i % 2 == 0 ? Self.rick : Self.ana, label: i % 2 == 0 ? "Rick" : "Ana", thread: thread)
        }
        add(200, Self.studio, Self.designChannel, "Passage mark stays on its white backing", sender: Self.ana, label: "Ana")
        add(201, Self.studio, Self.deploysChannel, "Staging is green", sender: Self.rick, label: "Rick")
        add(300, Self.lab, Self.notesChannel, "Lab workspace notes live here", sender: Self.ana, label: "Ana")
        return rows
    }

    private func allMessages() -> [[String: Any]] {
        (seeded + posted).sorted { (($0["created_at"] as! String), ($0["id"] as! String)) < (($1["created_at"] as! String), ($1["id"] as! String)) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .milliseconds(40))   // a little latency so states are observable
        let (status, body) = try route(request)
        let data = try JSONSerialization.data(withJSONObject: body)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    private func route(_ request: URLRequest) throws -> (Int, Any) {
        let path = request.url!.path
        if path == "/.well-known/nstack.json" {
            return (200, ["schema": "org.wingman.nstack.services", "schema_version": 1, "stack": ["tower_npub": Self.appNpub],
                          "services": [["id": "tower", "kind": "tower", "endpoint": FixtureEnvironment.origin, "protocols": ["https", "nip-98"],
                                        "availability": ["status": "available (local fixture)"]]]])
        }
        guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Nostr ") == true else { return (401, ["code": "unauthorized"]) }
        if offline { throw URLError(.notConnectedToInternet) }
        let base = "/api/v4/flightdeck-pg/workspaces"
        if path == base {
            return (200, ["workspaces": [workspace(Self.studio, "Studio (sample)"), workspace(Self.lab, "Lab (sample)")], "next_cursor": NSNull()])
        }
        let parts = path.replacingOccurrences(of: base + "/", with: "").split(separator: "/").map(String.init)
        guard let w = parts.first, [Self.studio, Self.lab].contains(w) else { return (404, ["code": "not_found"]) }
        let rest = Array(parts.dropFirst())
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch (request.httpMethod ?? "GET", rest.count, rest.first) {
        case ("GET", 1, "scopes"):
            let scopes = w == Self.studio ? [scope(Self.scopeAmbulando, w, "Ambulando"), scope(Self.scopeOps, w, "Operations")]
                                          : [scope(Self.scopeResearch, w, "Research")]
            return (200, ["scopes": scopes, "next_cursor": NSNull()])
        case ("GET", 3, "scopes"):
            let channels: [[String: Any]] = switch rest[1] {
            case Self.scopeAmbulando: [channel(Self.generalChannel, w, rest[1], "general", 1), channel(Self.designChannel, w, rest[1], "design", 2)]
            case Self.scopeOps: [channel(Self.deploysChannel, w, rest[1], "deploys", 1)]
            case Self.scopeResearch: [channel(Self.notesChannel, w, rest[1], "notes", 1)]
            default: []
            }
            return (200, ["channels": channels, "next_cursor": NSNull()])
        case ("GET", 1, "members"):
            let me = actorNpub
            return (200, ["members": [member(me, "You (sample identity)", "human"), member(Self.ana, "Ana", "human"), member(Self.rick, "Rick", "agent")],
                          "next_cursor": NSNull()])
        case ("GET", 2, "me"):
            return (200, ["scope_order": ["scope_ids": w == Self.studio ? [Self.scopeOps, Self.scopeAmbulando] : [], "row_version": 1]])
        case ("GET", 3, "channels") where rest[2] == "messages":
            return lock.withLock {
                let all = allMessages().filter { $0["workspace_id"] as? String == w && $0["channel_id"] as? String == rest[1]
                    && (q("thread_id") == nil || $0["thread_id"] as? String == q("thread_id")) }
                let start = q("cursor").flatMap { Int(String(decoding: Data(base64Encoded: $0) ?? Data(), as: UTF8.self)) } ?? 0
                let limit = min(200, Int(q("limit") ?? "50") ?? 50)
                let page = Array(all.dropFirst(start).prefix(limit))
                let next: Any = start + page.count < all.count ? Data(String(start + page.count).utf8).base64EncodedString() : NSNull()
                return (200, ["messages": page, "next_cursor": next])
            }
        case ("GET", 3, "channels") where rest[2] == "threads":
            return lock.withLock {
                let roots = allMessages().filter { $0["channel_id"] as? String == rest[1] && $0["id"] as? String == $0["thread_source_message_id"] as? String }
                return (200, ["threads": roots.map { thread(for: $0) }, "next_cursor": NSNull()])
            }
        case ("GET", 2, "threads"):
            return lock.withLock {
                guard let root = allMessages().first(where: { $0["thread_id"] as? String == rest[1] && $0["id"] as? String == $0["thread_source_message_id"] as? String })
                else { return (404, ["code": "thread_not_found"]) }
                return (200, ["thread": thread(for: root)])
            }
        case ("POST", 3, "channels") where rest[2] == "messages":
            return try post(request, workspace: w, channel: rest[1])
        default:
            return (404, ["code": "not_found"])
        }
    }

    private func post(_ request: URLRequest, workspace w: String, channel c: String) throws -> (Int, Any) {
        let object = (try JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let body = (object["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let event = ((object["message_signature"] as? [String: Any])?["nostr_event"] as? [String: Any]) ?? [:]
        guard event["kind"] as? Int == 33358, event["content"] as? String == body else {
            return (400, ["code": "validation_error", "details": ["fields": [["message": "message_signature does not match body"]]]])
        }
        return lock.withLock {
            if _rejectNext {
                _rejectNext = false
                return (400, ["code": "validation_error", "details": ["fields": [["message": "sample rejection requested in Settings"]]]])
            }
            let requestId = object["client_request_id"] as? String
            if let requestId, let prior = requests[requestId] { return (200, ["message": prior, "replayed": true, "created": false]) }
            let id = UUID().uuidString.lowercased()
            let threadId = (object["thread_id"] as? String) ?? UUID().uuidString.lowercased()
            let source: Any = object["thread_id"] == nil ? id
                : (allMessages().first { $0["thread_id"] as? String == threadId && $0["id"] as? String == $0["thread_source_message_id"] as? String }?["id"] ?? NSNull())
            let now = ISO8601DateFormatter.fixture.string(from: Date())
            let row: [String: Any] = ["id": id, "workspace_id": w, "channel_id": c, "thread_id": threadId, "thread_source_message_id": source,
                                      "body": body, "client_request_id": requestId ?? NSNull(), "record_state": "active", "row_version": 1,
                                      "sender_npub": _actor, "created_by_actor_label": "You (sample identity)", "created_at": now, "updated_at": now]
            posted.append(row)
            if let requestId { requests[requestId] = row }
            persist()
            var reply = row
            reply["thread_source_message_id"] = nil   // like Tower's create reply
            return (201, ["message": reply, "created": true, "replayed": false])
        }
    }

    private func workspace(_ id: String, _ label: String) -> [String: Any] {
        ["identity": ["workspace_id": id, "app_npub": Self.appNpub, "workspace_owner_npub": Self.ana], "label": label, "slug": label.lowercased(),
         "tower_base_url": FixtureEnvironment.origin, "membership": ["role": "member"]]
    }
    private func scope(_ id: String, _ w: String, _ name: String) -> [String: Any] {
        ["id": id, "workspace_id": w, "name": name, "kind": "project", "row_version": 1, "updated_at": "2026-10-01T00:00:00.000Z"]
    }
    private func channel(_ id: String, _ w: String, _ s: String, _ name: String, _ position: Double) -> [String: Any] {
        ["id": id, "workspace_id": w, "scope_id": s, "name": name, "kind": "channel", "position": position, "row_version": 1, "updated_at": "2026-10-01T00:00:00.000Z"]
    }
    private func member(_ npub: String, _ name: String, _ kind: String) -> [String: Any] {
        ["actor": ["actor_id": UUID().uuidString.lowercased(), "npub": npub, "kind": kind, "display_name": name]]
    }
    private func thread(for root: [String: Any]) -> [String: Any] {
        ["id": root["thread_id"]!, "workspace_id": root["workspace_id"]!, "channel_id": root["channel_id"]!, "source_message_id": root["id"]!,
         "title": MentionCodec.plain(root["body"] as? String ?? ""), "record_state": "active", "row_version": 1, "updated_at": root["updated_at"]!]
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fixture: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
