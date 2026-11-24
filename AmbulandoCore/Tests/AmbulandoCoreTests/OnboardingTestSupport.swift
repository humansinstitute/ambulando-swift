import Foundation
@testable import AmbulandoCore

/// In-memory stand-in for NStack's `/api/v4/onboarding` (tower src/routes/onboarding.ts, src/services/onboarding.ts). It mirrors the
/// real server's rules that the client depends on: strict NIP-98 (exact URL, method, payload hash on every mutation, valid
/// signature), owner scoping with a neutral 404, per-identity invite seats, revisioned options, idempotent create/checkout, and
/// funding that only a server-side "webhook" (`fund`) can establish. Synthetic identities only; no network is touched.
final class FakeOnboardingTower: HTTPTransport, @unchecked Sendable {
    struct Seen { let method: String; let path: String; let body: [String: Any]; let signer: String?; let url: URL }
    struct Intent {
        var id = UUID().uuidString.lowercased(); var owner: String; var key: String; var digest: String
        var status = "open"; var revision = 1; var name: String; var funding: Int; var offerId: String?; var cap: Int?
        var funded = false; var reversed = false; var steps: [String] = []; var lastError: String?; var workspaceId: String?
    }
    struct Offer { let id: String; let cap: Int; let max: Int }

    let origin: String
    let lock = NSLock()
    private(set) var seen: [Seen] = []
    var intents: [Intent] = []
    var offers: [Offer] = []
    var rolloutEnabled = true
    var inviteCodes: [String: Int] = [:]          // code -> max admissions
    var seats: [String: Set<String>] = [:]        // code -> owner npubs
    var accounts: Set<String> = []
    var checkoutURL = "https://checkout.stripe.com/c/pay/cs_test_fixture"
    var checkoutMode = "test"
    var checkoutAmountOffset = 0
    var checkoutOrders: [String: String] = [:]    // idempotency key -> order id
    var failures: [String: [Error]] = [:]         // "METHOD path-suffix" -> queued transport errors (before the server acts)
    var dropResponses: [String: Int] = [:]        // server acts, then the answer is lost
    var provisionFailures = 0
    var onboardingRouteMounted = true
    var descriptorOrigin: String?
    var provisionDelay: TimeInterval = 0

    init(origin: String = "https://tower.example") { self.origin = origin }

    var requests: [Seen] { lock.withLock { seen } }
    func count(_ method: String, suffix: String) -> Int { requests.filter { $0.method == method && $0.path.hasSuffix(suffix) }.count }

    func fund(_ intentId: String) { lock.withLock {
        guard let i = intents.firstIndex(where: { $0.id == intentId }) else { return }
        intents[i].funded = true; intents[i].status = "funded"; intents[i].revision += 1
    } }
    func bumpRevision(_ intentId: String) { lock.withLock { if let i = intents.firstIndex(where: { $0.id == intentId }) { intents[i].revision += 1 } } }

    func view(_ i: Intent) -> [String: Any] {
        var agent: Any = NSNull()
        if let id = i.offerId, let o = offers.first(where: { $0.id == id }) {
            agent = ["id": id, "template": "assistant", "model_ref": "fixture-model", "rate_version": "v1",
                     "default_daily_cap_cents": o.cap, "max_daily_cap_cents": o.max, "daily_cap_cents": i.cap ?? o.cap]
        }
        let steps = Dictionary(uniqueKeysWithValues: i.steps.map { ($0, ["completed_at": "2026-11-24T00:00:00.000Z"]) })
        return ["version": 1, "id": i.id, "account_id": "acct-" + i.owner.suffix(6), "status": i.status, "revision": i.revision,
                "workspace_name": i.name, "agent": agent, "agent_state": i.offerId == nil ? "none" : (i.steps.contains("agent") ? "provisioned" : "selected_not_provisioned"),
                "funding_cents": i.funding, "return_state": NSNull(), "funded": i.funded, "funded_at": i.funded ? "2026-11-24T00:00:00.000Z" : NSNull(),
                "funding_reversed": i.reversed, "steps": steps, "last_error": i.lastError as Any? ?? NSNull(),
                "workspace_id": i.workspaceId as Any? ?? NSNull(), "provisioned_at": i.status == "provisioned" ? "2026-11-24T00:00:00.000Z" : NSNull(),
                "intro_ends_at": NSNull(), "created_at": "2026-11-24T00:00:00.000Z", "updated_at": "2026-11-24T00:00:00.000Z"]
    }

    private func reply(_ status: Int, _ body: Any) -> (Data, HTTPURLResponse, Bool) { (try! JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: URL(string: origin)!, statusCode: status, httpVersion: nil, headerFields: nil)!, false) }
    private func error(_ status: Int, _ code: String) -> (Data, HTTPURLResponse, Bool) { reply(status, ["code": code, "error": code]) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let path = url.path
        if path == "/.well-known/nstack.json" {
            var d = Fixtures.descriptor(origin: descriptorOrigin ?? origin)
            d["stack"] = ["tower_npub": TestKeys.npub, "name": NSNull()]
            lock.withLock { seen.append(Seen(method: method, path: path, body: [:], signer: nil, url: url)) }
            return (try JSONSerialization.data(withJSONObject: d), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let rawBody = request.httpBody ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any] ?? [:]
        // Strict NIP-98, as the server's verifyStrictNip98Mutation: u, method, payload (all mutations), valid signature.
        var signer: String?
        if let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Nostr "),
           let event = try? decodeAuthorization(request), SignatureVerifier.verify(event), event.kind == 27235,
           event.tags.contains(["u", url.absoluteString]), event.tags.contains(["method", method]) {
            let payload = event.tags.first { $0.first == "payload" }?[1]
            if method == "GET" || payload == SHA256Hex.of(rawBody) { signer = NostrKeys.npub(publicKeyHex: event.pubkey) }
        }
        lock.withLock { seen.append(Seen(method: method, path: path, body: body, signer: signer, url: url)) }
        let key = "\(method) \(path)"
        if let queued = lock.withLock({ () -> Error? in
            guard let hit = failures.first(where: { key.hasSuffix($0.key) && !$0.value.isEmpty }) else { return nil }
            return failures[hit.key]!.removeFirst()
        }) { throw queued }
        guard onboardingRouteMounted else { return (Data("404 Not Found".utf8), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        guard let owner = signer else { let (d, r, _) = error(401, "nip98_payload_mismatch"); return (d, r) }
        let (data, response, _) = lock.withLock { route(method, path, body, owner) }
        if lock.withLock({ () -> Bool in if let n = dropResponses.first(where: { key.hasSuffix($0.key) && $0.value > 0 }) { dropResponses[n.key] = n.value - 1; return true }; return false }) {
            throw URLError(.networkConnectionLost)
        }
        if provisionDelay > 0, path.hasSuffix("/provision") { try await Task.sleep(for: .seconds(provisionDelay)) }
        return (data, response)
    }

    private func route(_ method: String, _ path: String, _ body: [String: Any], _ owner: String) -> (Data, HTTPURLResponse, Bool) {
        let base = "/api/v4/onboarding"
        guard path.hasPrefix(base) else { return error(404, "not_found") }
        let rest = String(path.dropFirst(base.count))
        let mutating = method != "GET"
        if method == "POST", rest == "/account" { accounts.insert(owner); return reply(200, ["account": account(owner)]) }
        if method == "GET", rest == "/account" { return reply(200, ["account": accounts.contains(owner) ? account(owner) as Any : NSNull(), "funding": NSNull()]) }
        if method == "GET", rest == "/agent-offers" {
            return reply(200, ["offers": offers.map { ["id": $0.id, "template": "assistant", "model_ref": "fixture-model", "rate_version": "v1", "default_daily_cap_cents": $0.cap, "max_daily_cap_cents": $0.max] as [String: Any] }])
        }
        if method == "GET", rest == "/intents" { return reply(200, ["intents": intents.filter { $0.owner == owner }.reversed().map(view)]) }
        if method == "POST", rest == "/intents" {
            guard rolloutEnabled else { return error(503, "onboarding_rollout_disabled") }
            let keys = Set(body.keys)
            guard keys.isSubset(of: ["client_request_key", "invite_code", "workspace_name", "funding_cents", "agent_offer_id", "agent_daily_cap_cents", "return_state"]),
                  let k = body["client_request_key"] as? String, let code = body["invite_code"] as? String, let name = body["workspace_name"] as? String,
                  let funding = body["funding_cents"] as? Int, name == name.trimmingCharacters(in: .whitespaces), (1...80).contains(name.count), (2100...1_000_000).contains(funding) else { return error(400, "invalid_body") }
            let digest = SHA256Hex.of("\(code)|\(name)|\(funding)|\(body["agent_offer_id"] as? String ?? "-")|\(body["agent_daily_cap_cents"] as? Int ?? -1)")
            if let prior = intents.first(where: { $0.owner == owner && $0.key == k }) {
                return prior.digest == digest ? reply(200, ["intent": view(prior), "replayed": true]) : error(409, "idempotency_conflict")
            }
            guard let max = inviteCodes[code] else { return error(404, "invite_not_found") }
            if intents.contains(where: { $0.owner == owner && ["open", "funded", "provisioning"].contains($0.status) && $0.name.lowercased() == name.lowercased() }) { return error(409, "workspace_name_taken") }
            var offer: String?; var cap: Int?
            if let o = body["agent_offer_id"] as? String {
                guard let found = offers.first(where: { $0.id == o }) else { return error(409, "agent_offer_unavailable") }
                offer = o; cap = body["agent_daily_cap_cents"] as? Int ?? found.cap
            }
            if !(seats[code] ?? []).contains(owner) {
                if (seats[code] ?? []).count >= max { return error(409, "invite_full") }
                seats[code, default: []].insert(owner)
            }
            accounts.insert(owner)
            let intent = Intent(owner: owner, key: k, digest: digest, name: name, funding: funding, offerId: offer, cap: cap)
            intents.append(intent)
            return reply(201, ["intent": view(intent), "replayed": false])
        }
        let parts = rest.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "intents" else { return error(404, "not_found") }
        guard let index = intents.firstIndex(where: { $0.id == parts[1] && $0.owner == owner }) else { return error(404, "intent_not_found") }
        if mutating, !rolloutEnabled { return error(503, "onboarding_rollout_disabled") }
        if parts.count == 2, method == "GET" { return reply(200, ["intent": view(intents[index])]) }
        switch (method, parts.count > 2 ? parts[2] : "") {
        case ("POST", "options"):
            guard intents[index].revision == body["expected_revision"] as? Int else { return error(409, "stale_revision") }
            guard ["open", "funded"].contains(intents[index].status) else { return error(409, "intent_not_editable") }
            if let n = body["workspace_name"] as? String { intents[index].name = n }
            if let f = body["funding_cents"] as? Int { if intents[index].status != "open" { return error(409, "funding_locked") }; intents[index].funding = f }
            if body.keys.contains("agent_offer_id") {
                if let o = body["agent_offer_id"] as? String {
                    guard let found = offers.first(where: { $0.id == o }) else { return error(409, "agent_offer_unavailable") }
                    intents[index].offerId = o; intents[index].cap = body["agent_daily_cap_cents"] as? Int ?? found.cap
                } else { intents[index].offerId = nil; intents[index].cap = nil }
            }
            intents[index].revision += 1
            return reply(200, ["intent": view(intents[index])])
        case ("POST", "checkout"):
            guard Set(body.keys) == ["idempotency_key", "return_url"], let k = body["idempotency_key"] as? String, intents[index].status == "open" else { return error(409, "intent_not_open") }
            let order = checkoutOrders[k] ?? UUID().uuidString.lowercased(); checkoutOrders[k] = order
            return reply(201, ["order_id": order, "checkout_url": checkoutURL, "mode": checkoutMode, "amount_cents": intents[index].funding + checkoutAmountOffset])
        case ("POST", "cancel"):
            if intents[index].status == "cancelled" { return reply(200, ["intent": view(intents[index])]) }
            guard intents[index].status == "open" else { return error(409, "intent_not_cancellable") }
            intents[index].status = "cancelled"; intents[index].revision += 1
            return reply(200, ["intent": view(intents[index])])
        case ("POST", "provision"):
            if intents[index].status == "provisioned" { return reply(200, ["intent": view(intents[index])]) }
            guard intents[index].status != "open" else { return error(402, "funding_required") }
            guard intents[index].funded, !intents[index].reversed else { return error(402, "funding_reversed") }
            if provisionFailures > 0 {
                provisionFailures -= 1
                if !intents[index].steps.contains("workspace") { intents[index].steps.append("workspace"); intents[index].workspaceId = UUID().uuidString.lowercased() }
                intents[index].status = "provisioning"; intents[index].lastError = "billing_link:billing_owner_conflict"
                return error(502, "provisioning_step_failed")
            }
            if !intents[index].steps.contains("workspace") { intents[index].steps.append("workspace"); intents[index].workspaceId = UUID().uuidString.lowercased() }
            if !intents[index].steps.contains("billing_link") { intents[index].steps.append("billing_link") }
            intents[index].status = "provisioned"; intents[index].lastError = nil; intents[index].revision += 1
            return reply(200, ["intent": view(intents[index])])
        default: return error(404, "not_found")
        }
    }

    private func account(_ owner: String) -> [String: Any] {
        ["account_id": "acct-" + owner.suffix(6), "currency": "USD", "balance_units": "0", "balance_usd": "0.00", "paid_usd": "0.00", "promo_usd": "0.00", "created_at": "2026-11-24T00:00:00.000Z"]
    }
}

enum OnboardingFixture {
    static let invite = "inv_fixtureCodeOnlyForTests0123456789abc"
    static let returnURL = URL(string: "https://tower.example/billing/return")!

    /// Deterministic operation keys so tests can compare "same key after relaunch".
    static func keys() -> @Sendable () -> String {
        let counter = Counter()
        return { "ob_test_key_\(counter.next())" }
    }
    final class Counter: @unchecked Sendable { private let l = NSLock(); private var n = 0; func next() -> Int { l.withLock { n += 1; return n } } }

    static func controller(_ tower: FakeOnboardingTower, signer: IdentityService, store: OnboardingDraftStore, returnURL: URL? = returnURL,
                           keys: (@Sendable () -> String)? = nil) async throws -> OnboardingController {
        let npub = NostrKeys.npub(publicKeyHex: try await signer.publicKeyHex())!
        return OnboardingController(origin: try TowerOrigin(tower.origin), signerNpub: npub, signer: signer, transport: tower, store: store,
                                    returnURL: returnURL, makeKey: keys ?? Self.keys())
    }

    static func otherIdentity() async throws -> IdentityService {
        let s = IdentityService(vaultURL: temporaryDirectory().appendingPathComponent("vault.json"), secrets: MemorySecretStore())
        try await s.importIdentity(nsec: TestKeys.otherNsec(), pin: TestKeys.pin)
        return s
    }
}
