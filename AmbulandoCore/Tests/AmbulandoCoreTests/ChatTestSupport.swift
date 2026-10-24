import Foundation
import XCTest
@testable import AmbulandoCore

/// In-memory stand-in for Tower's chat routes with the server rules that matter to the client:
/// forward cursor paging (`created_at ASC, id ASC`), trimmed body, kind 33358 verification, NIP-98 payload hash,
/// and `client_request_id` replay / `idempotency_conflict`. Failures can be injected per POST.
final class FakeChatTower: @unchecked Sendable {
    enum Fault { case offline, dropResponseAfterCommit, status(Int, String) }

    struct Post { let request: URLRequest; let body: Data; let auth: NostrEvent }

    private let lock = NSLock()
    private(set) var messages: [[String: Any]] = []
    private var byRequest: [String: (hash: String, message: [String: Any])] = [:]
    private var threads: [String: [String: Any]] = [:]
    private var faults: [Fault] = []
    private var clock = 0
    private(set) var posts: [Post] = []
    private(set) var gets: [URLRequest] = []

    let workspaceId: String
    let channelIds: Set<String>
    let actorNpub: String

    init(workspaceId: String = Fixtures.workspaceId, channels: Set<String> = [Fixtures.channel1, Fixtures.channel2], actorNpub: String = TestKeys.npub) {
        self.workspaceId = workspaceId; self.channelIds = channels; self.actorNpub = actorNpub
    }

    func inject(_ fault: Fault) { lock.withLock { faults.append(fault) } }
    var recordedPosts: [Post] { lock.withLock { posts } }
    var recordedGets: [URLRequest] { lock.withLock { gets } }
    var messageCount: Int { lock.withLock { messages.count } }

    private func timestamp() -> String {
        clock += 1
        return String(format: "2026-10-24T09:%02d:%02d.%03dZ", (clock / 60_000) % 60, (clock / 1000) % 60, clock % 1000)
    }

    /// Seeds history directly (as if posted by someone earlier).
    @discardableResult
    func seed(channel: String, body: String, thread: String? = nil, sender: String = TestKeys.npub) -> [String: Any] {
        lock.withLock {
            let id = UUID().uuidString.lowercased()
            let threadId = thread ?? UUID().uuidString.lowercased()
            if thread == nil {
                threads[threadId] = ["id": threadId, "workspace_id": workspaceId, "channel_id": channel, "source_message_id": id, "title": body,
                                     "record_state": "active", "row_version": 1, "updated_at": "2026-10-24T00:00:00.000Z"]
            }
            let source = (threads[threadId]?["source_message_id"] as? String) ?? NSNull() as Any
            let row: [String: Any] = ["id": id, "workspace_id": workspaceId, "channel_id": channel, "thread_id": threadId,
                                      "thread_source_message_id": source, "body": body, "client_request_id": NSNull(),
                                      "record_state": "active", "row_version": 1, "sender_npub": sender, "created_by_actor_label": "Seed",
                                      "created_at": timestamp(), "updated_at": "2026-10-24T00:00:00.000Z"]
            messages.append(row)
            return row
        }
    }

    func delete(id: String) { lock.withLock { messages.removeAll { $0["id"] as? String == id } } }

    func handler() -> StubTransport.Handler {
        { [self] request in try self.route(request) }
    }

    private func cursor(_ index: Int) -> String { Data("idx:\(index)".utf8).base64EncodedString() }
    private func index(_ cursor: String?) -> Int? {
        guard let cursor else { return 0 }
        guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8), text.hasPrefix("idx:") else { return nil }
        return Int(text.dropFirst(4))
    }

    private func route(_ request: URLRequest) throws -> (Int, Any) {
        let url = request.url!, path = url.path
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Nostr "),
              let authData = Data(base64Encoded: String(header.dropFirst(6))),
              let auth = try? JSONDecoder().decode(NostrEvent.self, from: authData), SignatureVerifier.verify(auth),
              auth.kind == 27235, auth.tags.first == ["u", url.absoluteString] else { return (401, ["code": "unauthorized"]) }
        let base = "/api/v4/flightdeck-pg/workspaces/\(workspaceId)"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let parts = path.replacingOccurrences(of: base, with: "").split(separator: "/").map(String.init)
        if request.httpMethod == "GET" {
            lock.withLock { gets.append(request) }
            if parts.count == 3, parts[0] == "channels", parts[2] == "messages" {
                return lock.withLock {
                    let channel = parts[1]
                    guard let start = index(q("cursor")) else { return (400, ["code": "validation_error"]) }
                    let limit = min(200, Int(q("limit") ?? "50") ?? 50)
                    let all = messages.filter { $0["channel_id"] as? String == channel && (q("thread_id") == nil || $0["thread_id"] as? String == q("thread_id")) }
                        .sorted { (($0["created_at"] as! String), ($0["id"] as! String)) < (($1["created_at"] as! String), ($1["id"] as! String)) }
                    let page = Array(all.dropFirst(start).prefix(limit))
                    let more = start + page.count < all.count
                    return (200, ["messages": page, "next_cursor": more ? cursor(start + page.count) : NSNull() as Any, "channel_id": channel])
                }
            }
            if parts.count == 3, parts[0] == "channels", parts[2] == "threads" {
                return lock.withLock { (200, ["threads": threads.values.filter { $0["channel_id"] as? String == parts[1] }, "next_cursor": NSNull()]) }
            }
            if parts.count == 2, parts[0] == "threads" {
                return lock.withLock { threads[parts[1]].map { (200, ["thread": $0]) } ?? (404, ["code": "thread_not_found"]) }
            }
            return (404, ["code": "not_found"])
        }
        guard request.httpMethod == "POST", parts.count == 3, parts[0] == "channels", parts[2] == "messages" else { return (404, ["code": "not_found"]) }
        let bodyData = request.httpBody ?? Data()
        lock.withLock { posts.append(Post(request: request, body: bodyData, auth: auth)) }
        guard auth.tags.contains(["payload", SHA256Hex.of(bodyData)]) else { return (401, ["code": "payload_mismatch"]) }
        guard request.value(forHTTPHeaderField: "x-flightdeck-pg-app-npub") != nil else { return (400, ["code": "app_npub_required"]) }
        let fault: Fault? = lock.withLock { faults.isEmpty ? nil : faults.removeFirst() }
        if case .offline = fault { throw URLError(.notConnectedToInternet) }
        if case .status(let status, let code) = fault { return (status, ["code": code, "error": code, "status": status]) }
        let object = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
        let channel = parts[1]
        guard channelIds.contains(channel) else { return (404, ["code": "channel_not_found"]) }
        let body = (object["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let threadId = object["thread_id"] as? String
        let createThread = object["create_thread"] as? Bool == true
        // kind 33358 rules (flightdeck-pg-message-signatures.ts)
        guard let wrapper = object["message_signature"] as? [String: Any], wrapper["version"] as? Int == 1,
              let eventObject = wrapper["nostr_event"], let eventData = try? JSONSerialization.data(withJSONObject: eventObject),
              let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData), SignatureVerifier.verify(event),
              event.kind == 33358, event.content == body, event.pubkey == auth.pubkey,
              event.tags.contains(["protocol", "flightdeck_pg_message_instruction"]), event.tags.contains(["body_sha256", SHA256Hex.of(body)]),
              wrapper["body_sha256"] as? String == SHA256Hex.of(body), wrapper["signer_npub"] as? String == actorNpub,
              event.tags.contains(["workspace_id", workspaceId]), event.tags.contains(["channel_id", channel]),
              threadId == nil || event.tags.contains(["thread_id", threadId!]) else { return (400, ["code": "validation_error"]) }
        let requestId = object["client_request_id"] as? String
        let hash = SHA256Hex.of("\(channel)|\(threadId ?? "")|\(createThread)|\(body)")
        let result: (Int, Any) = lock.withLock {
            if let requestId, let prior = byRequest[requestId] {
                if prior.hash != hash { return (409, ["code": "idempotency_conflict"]) }
                return (200, ["message": prior.message, "created": false, "replayed": true])
            }
            if let threadId, threads[threadId]?["channel_id"] as? String != channel { return (404, ["code": "thread_not_found"]) }
            let id = UUID().uuidString.lowercased()
            var thread: [String: Any]?
            var tid = threadId
            if createThread {
                let newThread = UUID().uuidString.lowercased()
                tid = newThread
                thread = ["id": newThread, "workspace_id": workspaceId, "channel_id": channel, "source_message_id": id, "title": body,
                          "record_state": "active", "row_version": 1, "updated_at": "2026-10-24T00:00:00.000Z"]
                threads[newThread] = thread
            }
            // Like createFlightDeckPgMessage, the create reply omits thread_source_message_id.
            let row: [String: Any] = ["id": id, "workspace_id": workspaceId, "channel_id": channel, "thread_id": tid as Any,
                                      "body": body, "client_request_id": requestId as Any, "record_state": "active", "row_version": 1,
                                      "sender_npub": actorNpub, "created_at": timestamp(), "updated_at": "2026-10-24T00:00:00.000Z",
                                      "mentions": object["mentions"] ?? []]
            var stored = row
            stored["thread_source_message_id"] = (threads[tid ?? ""]?["source_message_id"]) ?? NSNull()
            messages.append(stored)
            if let requestId { byRequest[requestId] = (hash, row) }
            var reply: [String: Any] = ["message": row, "created": true, "replayed": false]
            if let thread { reply["thread"] = thread }
            return (201, reply)
        }
        if case .dropResponseAfterCommit = fault { throw URLError(.networkConnectionLost) }
        return result
    }
}

struct ChatHarness {
    let store: LocalStore
    let identity: IdentityService
    let tower: FakeChatTower
    let transport: StubTransport
    let engine: SyncEngine
    let connection: ConnectionRecord
    let workspace: WorkspaceRecord
    let directory: URL

    var sync: WorkspaceSync { WorkspaceSync(store: store, engine: engine, identity: identity, transport: transport) }
    var outbox: OutboxSender { OutboxSender(store: store, engine: engine, identity: identity, transport: transport) }

    func target(_ channel: String = Fixtures.channel1, thread: String? = nil) -> ChatTarget {
        ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: channel, threadId: thread)
    }

    static func make(directory: URL = temporaryDirectory(), tower: FakeChatTower = FakeChatTower(), unlocked: Bool = true) async throws -> ChatHarness {
        let identity = try await makeIdentity(unlocked: unlocked, directory: directory, secrets: SecretsRegistry.shared.store(for: directory))
        let store = try LocalStore(directory: directory.appendingPathComponent("Store"))
        let connection = try await store.writer.saveConnection(ConnectionRecord(origin: try TowerOrigin("https://tower.example"),
                                                                                signerNpub: TestKeys.npub, towerNpub: nil))
        let workspace = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId, label: "Studio")))
        try await store.writer.replaceWorkspaces(connectionId: connection.id, [workspace])
        return ChatHarness(store: store, identity: identity, tower: tower, transport: StubTransport(tower.handler()), engine: SyncEngine(),
                           connection: connection, workspace: workspace, directory: directory)
    }

    /// Simulates relaunch: a new store, engine and identity service over the same files.
    func relaunch(unlock: Bool) async throws -> ChatHarness {
        let identity = IdentityService(vaultURL: directory.appendingPathComponent("vault.json"), secrets: secretsCarrier)
        if unlock { try await identity.unlock(pin: TestKeys.pin) }
        let store = try LocalStore(directory: directory.appendingPathComponent("Store"))
        try await store.writer.resetInterruptedSends()
        return ChatHarness(store: store, identity: identity, tower: tower, transport: transport, engine: SyncEngine(),
                           connection: connection, workspace: workspace, directory: directory)
    }

    var secretsCarrier: VaultSecretStore { SecretsRegistry.shared.store(for: directory) }
}

/// Keeps each test directory's in-memory Keychain stand-in alive across a simulated relaunch.
final class SecretsRegistry: @unchecked Sendable {
    static let shared = SecretsRegistry()
    private let lock = NSLock()
    private var stores: [URL: MemorySecretStore] = [:]
    func store(for directory: URL) -> MemorySecretStore {
        lock.withLock {
            if let existing = stores[directory] { return existing }
            let created = MemorySecretStore()
            stores[directory] = created
            return created
        }
    }
}
