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
        var identityOrigin = "existing"
    }
    /// Hosted identity backup row, as tower docs/contract/hosted-identity-backup-v1.md describes it.
    struct HostedRow { var owner: String; var ncryptsec: String; var revision: Int }
    struct Offer { let id: String; let cap: Int; let max: Int }

    let origin: String
    let lock = NSLock()
    private(set) var seen: [Seen] = []
    var intents: [Intent] = []
    var offers: [Offer] = []
    var rolloutEnabled = true
    var deploymentConfig: [String: Any]?
    var lightningServing = true
    var inviteCodes: [String: Int] = [:]          // code -> max admissions
    var seats: [String: Set<String>] = [:]        // code -> owner npubs
    var accounts: Set<String> = []
    var checkoutURL = "https://checkout.stripe.com/c/pay/cs_test_fixture"
    var checkoutMode = "test"
    var checkoutAmountOffset = 0
    var checkoutRefusal: String?
    var checkoutOrders: [String: String] = [:]    // idempotency key -> order id
    var failures: [String: [Error]] = [:]         // "METHOD path-suffix" -> queued transport errors (before the server acts)
    var dropResponses: [String: Int] = [:]        // server acts, then the answer is lost
    var provisionFailures = 0
    var onboardingRouteMounted = true
    var descriptorOrigin: String?
    var provisionDelay: TimeInterval = 0
    var hook: (@Sendable (Seen) -> Void)?
    /// Awaited after the server has acted and before the answer is returned: lets a test hold one response while other calls are made.
    var responseGate: (@Sendable (Seen) async -> Void)?
    /// Lightning quote as `quoteView` reports it. `evidence` is test-only server state (what the fixture provider would observe).
    struct Quote { var id = UUID().uuidString.lowercased(); var owner: String; var intentId: String?; var key: String; var cents: Int; var state = "open"
                   var sats: Int; var invoice: String; var hash: String; var expires: String }
    struct TopupOrder { var id: String; var owner: String; var cents: Int; var returnURL: String; var open = true }
    struct Credit { var id = UUID().uuidString.lowercased(); var cents: Int; var method: String }
    var quotes: [Quote] = []
    var quoteTTL: TimeInterval = 600
    var satsPerCent = 25
    var invoiceAmountOffset = 0                    // makes the invoice name a different amount than the quote (a hostile or buggy provider)
    var quoteAmountOffset = 0
    var provisionedOwners: Set<String> = []
    var topupOrders: [String: TopupOrder] = [:]    // idempotency key -> order
    var pendingCheckoutComplete: Bool? = true
    var hiddenPendingCheckoutOrderIds: Set<String> = []
    var topupCredits: [String: [Credit]] = [:]     // owner -> credits
    var accountFunding: Any?
    var accountLifecycle: Any?
    var hosted: [String: HostedRow] = [:]
    var hostedMounted = true
    /// The server's accepted scrypt cost range; the real contract is 16...18, tests lower it to keep debug builds fast.
    var hostedLogN: ClosedRange<UInt8> = 16...18
    var hostedTamperReadback = false

    init(origin: String = "https://tower.example") { self.origin = origin }

    var requests: [Seen] { lock.withLock { seen } }
    func count(_ method: String, suffix: String) -> Int { requests.filter { $0.method == method && $0.path.hasSuffix(suffix) }.count }

    func fund(_ intentId: String) { lock.withLock {
        guard let i = intents.firstIndex(where: { $0.id == intentId }) else { return }
        intents[i].funded = true; intents[i].status = "funded"; intents[i].revision += 1
    } }
    /// The provider-verified outcome of a quote (what the server's own refresh poll would learn). Funds the intent / credits the account on settle.
    func resolveQuote(_ id: String, to state: String) { lock.withLock {
        guard let q = quotes.firstIndex(where: { $0.id == id }) else { return }
        quotes[q].state = state
        guard state == "settled" else { return }
        if let intent = quotes[q].intentId, let i = intents.firstIndex(where: { $0.id == intent }) {
            intents[i].funded = true; intents[i].status = "funded"; intents[i].revision += 1
        } else { topupCredits[quotes[q].owner, default: []].append(Credit(cents: quotes[q].cents, method: "lightning")) }
    } }
    func settleTopupOrder(_ key: String) { lock.withLock {
        guard var o = topupOrders[key] else { return }
        o.open = false; topupOrders[key] = o; topupCredits[o.owner, default: []].append(Credit(cents: o.cents, method: "stripe"))
    } }
    func expireTopupOrder(_ key: String) { lock.withLock { topupOrders[key]?.open = false } }
    func provision(_ owner: String) { lock.withLock { provisionedOwners.insert(owner) } }

    private func quoteJSON(_ q: Quote) -> [String: Any] {
        ["id": q.id, "intent_id": q.intentId as Any? ?? NSNull(), "state": q.state, "amount_cents": q.cents + quoteAmountOffset, "amount_sats": q.sats, "invoice": q.invoice, "payment_hash": q.hash,
         "expires_at": q.expires, "rate": ["source": "fixture-fx", "quoted_at": "2026-11-24T00:00:00.000Z"]]
    }
    private func makeQuote(owner: String, intent: String?, key: String, cents: Int) -> Quote {
        let sats = cents * satsPerCent
        let named = (sats + invoiceAmountOffset) * 10
        let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let tail = String((0..<50).map { charset[($0 * 7 + sats) % charset.count] })
        let hash = SHA256Hex.of("fixture-hash-\(key)-\(cents)")
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(quoteTTL))
        return Quote(owner: owner, intentId: intent, key: key, cents: cents, sats: sats, invoice: "lnbc\(named)n1" + tail, hash: hash, expires: expires)
    }
    private func topupRoute(_ method: String, _ rest: String, _ body: [String: Any], _ owner: String) -> (Data, HTTPURLResponse, Bool) {
        if !accounts.contains(owner) { return error(404, "account_not_found") }
        if !provisionedOwners.contains(owner) { return error(409, "account_not_provisioned") }
        if method != "GET", !rolloutEnabled { return error(503, "onboarding_rollout_disabled") }
        let keyOK = { (v: Any?) -> String? in (v as? String).flatMap { $0.range(of: "^[a-zA-Z0-9_-]{8,100}$", options: .regularExpression) != nil ? $0 : nil } }
        switch (method, rest) {
        case ("GET", "/topups"):
            let credited = (topupCredits[owner] ?? []).map { ["settlement_id": $0.id, "method": $0.method, "amount_cents": $0.cents, "amount_usd": String(format: "%d.%02d", $0.cents / 100, $0.cents % 100), "settled_at": "2026-11-24T00:00:00.000Z"] as [String: Any] }
            let pendingQuotes = quotes.filter { $0.owner == owner && $0.intentId == nil && ["open", "late_payment", "mismatch"].contains($0.state) }
                .map { ["quote_id": $0.id, "state": $0.state, "amount_cents": $0.cents, "amount_sats": $0.sats, "invoice": $0.invoice, "payment_hash": $0.hash, "expires_at": $0.expires] as [String: Any] }
            let orders = topupOrders.values.filter { $0.owner == owner && $0.open && !hiddenPendingCheckoutOrderIds.contains($0.id) }.map { ["order_id": $0.id, "amount_cents": $0.cents, "created_at": "2026-11-24T00:00:00.000Z"] as [String: Any] }
            var result: [String: Any] = ["credited": credited, "pending_lightning": pendingQuotes, "pending_checkout": orders]
            if let complete = pendingCheckoutComplete { result["pending_checkout_complete"] = complete }
            return reply(200, result)
        case ("POST", "/topups/checkout"):
            guard Set(body.keys) == ["idempotency_key", "return_url", "amount_cents"], let k = keyOK(body["idempotency_key"]), let url = body["return_url"] as? String,
                  let cents = body["amount_cents"] as? Int, (2100...1_000_000).contains(cents) else { return error(400, "invalid_checkout") }
            if let prior = topupOrders[k] {
                guard prior.cents == cents, prior.returnURL == url else { return error(409, "idempotency_conflict") }
                return reply(201, ["order_id": prior.id, "checkout_url": checkoutURL, "mode": checkoutMode, "amount_cents": prior.cents])
            }
            let order = TopupOrder(id: UUID().uuidString.lowercased(), owner: owner, cents: cents, returnURL: url)
            topupOrders[k] = order
            return reply(201, ["order_id": order.id, "checkout_url": checkoutURL, "mode": checkoutMode, "amount_cents": cents + checkoutAmountOffset])
        case ("POST", "/topups/lightning/quote"):
            guard lightningServing else { return error(503, "lightning_unavailable") }
            guard Set(body.keys) == ["idempotency_key", "amount_cents"], let k = keyOK(body["idempotency_key"]), let cents = body["amount_cents"] as? Int, (2100...1_000_000).contains(cents) else { return error(400, "invalid_quote_request") }
            if let prior = quotes.first(where: { $0.owner == owner && $0.key == k }) {
                return prior.intentId == nil && prior.cents == cents ? reply(201, ["quote": quoteJSON(prior)]) : error(409, "idempotency_conflict")
            }
            if quotes.filter({ $0.owner == owner && $0.intentId == nil && $0.state == "open" }).count >= 5 { return error(429, "too_many_open_topup_quotes") }
            let q = makeQuote(owner: owner, intent: nil, key: k, cents: cents); quotes.append(q)
            return reply(201, ["quote": quoteJSON(q)])
        default:
            let parts = rest.split(separator: "/").map(String.init)
            if method == "POST", parts.count == 5, parts[1] == "lightning", parts[2] == "quotes", parts[4] == "refresh" {
                guard let q = quotes.first(where: { $0.id == parts[3] && $0.owner == owner && $0.intentId == nil }) else { return error(404, "quote_not_found") }
                return reply(200, ["quote": quoteJSON(q)])
            }
            return error(404, "not_found")
        }
    }
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
        let record = Seen(method: method, path: path, body: body, signer: signer, url: url)
        lock.withLock { seen.append(record) }
        hook?(record)
        let key = "\(method) \(path)"
        if let queued = lock.withLock({ () -> Error? in
            guard let hit = failures.first(where: { key.hasSuffix($0.key) && !$0.value.isEmpty }) else { return nil }
            return failures[hit.key]!.removeFirst()
        }) { throw queued }
        if path.hasPrefix(HostedBackupAPI.base) {
            let (d, r) = lock.withLock { hostedRoute(method, path, rawBody, body, signer) }
            if lock.withLock({ () -> Bool in if let n = dropResponses.first(where: { key.hasSuffix($0.key) && $0.value > 0 }) { dropResponses[n.key] = n.value - 1; return true }; return false }) {
                throw URLError(.networkConnectionLost)
            }
            return (d, r)
        }
        guard onboardingRouteMounted else { return (Data("404 Not Found".utf8), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        guard let owner = signer else { let (d, r, _) = error(401, "nip98_payload_mismatch"); return (d, r) }
        let (data, response, _) = lock.withLock { route(method, path, body, owner) }
        if lock.withLock({ () -> Bool in if let n = dropResponses.first(where: { key.hasSuffix($0.key) && $0.value > 0 }) { dropResponses[n.key] = n.value - 1; return true }; return false }) {
            throw URLError(.networkConnectionLost)
        }
        if let gate = responseGate { await gate(record) }
        if provisionDelay > 0, path.hasSuffix("/provision") { try await Task.sleep(for: .seconds(provisionDelay)) }
        return (data, response)
    }

    private func route(_ method: String, _ path: String, _ body: [String: Any], _ owner: String) -> (Data, HTTPURLResponse, Bool) {
        let base = "/api/v4/onboarding"
        guard path.hasPrefix(base) else { return error(404, "not_found") }
        let rest = String(path.dropFirst(base.count))
        let mutating = method != "GET"
        if method == "GET", rest == "/config" {
            return deploymentConfig.map { reply(200, $0) } ?? error(404, "not_found")
        }
        if method == "POST", rest == "/account" { accounts.insert(owner); return reply(200, ["account": account(owner)]) }
        if method == "GET", rest == "/account" {
            return reply(200, ["account": accounts.contains(owner) ? account(owner) as Any : NSNull(), "funding": accountFunding ?? NSNull(), "lifecycle": accountLifecycle ?? NSNull()])
        }
        if rest.hasPrefix("/topups") { return topupRoute(method, rest, body, owner) }
        if method == "GET", rest == "/agent-offers" {
            return reply(200, ["offers": offers.map { ["id": $0.id, "template": "assistant", "model_ref": "fixture-model", "rate_version": "v1", "default_daily_cap_cents": $0.cap, "max_daily_cap_cents": $0.max] as [String: Any] }])
        }
        if method == "GET", rest == "/intents" { return reply(200, ["intents": intents.filter { $0.owner == owner }.reversed().map(view)]) }
        if method == "POST", rest == "/intents" {
            guard rolloutEnabled else { return error(503, "onboarding_rollout_disabled") }
            let keys = Set(body.keys)
            guard keys.isSubset(of: ["client_request_key", "invite_code", "workspace_name", "funding_cents", "agent_offer_id", "agent_daily_cap_cents", "return_state", "identity_origin"]),
                  ["new", "existing", nil].contains(body["identity_origin"] as? String),
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
            var intent = Intent(owner: owner, key: k, digest: digest, name: name, funding: funding, offerId: offer, cap: cap)
            intent.identityOrigin = body["identity_origin"] as? String ?? "existing"
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
            if let code = checkoutRefusal { return error(400, code) }
            guard Set(body.keys) == ["idempotency_key", "return_url"], let k = body["idempotency_key"] as? String, intents[index].status == "open" else { return error(409, "intent_not_open") }
            if intents[index].identityOrigin == "new", !hosted.values.contains(where: { $0.owner == owner }) { return error(409, "identity_backup_required") }
            let order = checkoutOrders[k] ?? UUID().uuidString.lowercased(); checkoutOrders[k] = order
            return reply(201, ["order_id": order, "checkout_url": checkoutURL, "mode": checkoutMode, "amount_cents": intents[index].funding + checkoutAmountOffset])
        case ("POST", "lightning"):
            let sub = parts.count > 3 ? parts[3] : ""
            if sub == "quote" {
                guard lightningServing else { return error(503, "lightning_unavailable") }
                guard Set(body.keys) == ["idempotency_key"], let k = (body["idempotency_key"] as? String).flatMap({ $0.range(of: "^[a-zA-Z0-9_-]{8,100}$", options: .regularExpression) != nil ? $0 : nil }) else { return error(400, "invalid_quote_request") }
                if let prior = quotes.first(where: { $0.owner == owner && $0.key == k }) { return prior.intentId == intents[index].id ? reply(201, ["quote": quoteJSON(prior)]) : error(409, "idempotency_conflict") }
                guard intents[index].status == "open" else { return error(409, "intent_not_open") }
                if intents[index].identityOrigin == "new", !hosted.values.contains(where: { $0.owner == owner }) { return error(409, "identity_backup_required") }
                let q = makeQuote(owner: owner, intent: intents[index].id, key: k, cents: intents[index].funding); quotes.append(q)
                return reply(201, ["quote": quoteJSON(q)])
            }
            if sub == "quotes", parts.count == 6, parts[5] == "refresh" {
                guard let q = quotes.first(where: { $0.id == parts[4] && $0.intentId == intents[index].id && $0.owner == owner }) else { return error(404, "quote_not_found") }
                return reply(200, ["quote": quoteJSON(q), "intent": view(intents[index])])
            }
            return error(404, "not_found")
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

    private func hostedRoute(_ method: String, _ path: String, _ raw: Data, _ body: [String: Any], _ signer: String?) -> (Data, HTTPURLResponse) {
        func out(_ status: Int, _ value: Any) -> (Data, HTTPURLResponse) {
            let (d, r, _) = reply(status, value); return (d, r)
        }
        func fail(_ status: Int, _ code: String) -> (Data, HTTPURLResponse) { out(status, ["code": code, "error": code]) }
        guard hostedMounted else { return (Data("404 Not Found".utf8), HTTPURLResponse(url: URL(string: origin)!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        let name = String(path.dropFirst(HostedBackupAPI.base.count + 1))
        if method == "GET", name == "me" {
            guard let owner = signer else { return fail(401, "nip98_payload_mismatch") }
            guard let row = hosted.first(where: { $0.value.owner == owner }) else { return fail(404, "backup_not_found") }
            return out(200, ["username": row.key, "revision": String(row.value.revision), "updated_at": "2026-11-24T00:00:00.000Z"])
        }
        guard HostedBackupUsername.normalized(name) == name else { return fail(400, "invalid_username") }
        if method == "GET" {
            guard let row = hosted[name] else { return fail(404, "backup_not_found") }
            var text = row.ncryptsec
            if hostedTamperReadback { text = String(text.dropLast()) + (text.last == "q" ? "p" : "q") }
            return out(200, ["username": name, "ncryptsec": text, "revision": String(row.revision), "updated_at": "2026-11-24T00:00:00.000Z"])
        }
        guard method == "PUT" else { return fail(405, "method_not_allowed") }
        guard let owner = signer else { return fail(401, "nip98_payload_mismatch") }
        guard Set(body.keys) == ["ncryptsec", "expected_revision"], let text = body["ncryptsec"] as? String, let expected = body["expected_revision"] as? String else { return fail(400, "invalid_json") }
        guard text.count == 162, text == text.lowercased(), let decoded = Bech32.decode(text, maxLength: 162), decoded.hrp == "ncryptsec", decoded.data.count == 91,
              Array(decoded.data)[0] == 2, hostedLogN.contains(Array(decoded.data)[1]), Array(decoded.data)[42] <= 2 else { return fail(400, "invalid_backup") }
        if let row = hosted[name] {
            if expected == "0" { return fail(409, "username_unavailable") }   // create on an existing name, whoever owns it
            guard row.owner == owner else { return fail(403, "backup_owner_mismatch") }
            if row.ncryptsec == text, expected == String(row.revision - 1) { return out(200, ["username": name, "revision": String(row.revision), "created": false]) }
            guard expected == String(row.revision) else { return out(409, ["code": "revision_conflict", "error": "revision_conflict", "current_revision": String(row.revision)]) }
            hosted[name]!.ncryptsec = text; hosted[name]!.revision += 1
            return out(200, ["username": name, "revision": String(hosted[name]!.revision), "created": false])
        }
        guard expected == "0" else { return fail(409, "revision_conflict") }
        if hosted.values.contains(where: { $0.owner == owner }) { return fail(409, "identity_already_backed_up") }
        hosted[name] = HostedRow(owner: owner, ncryptsec: text, revision: 1)
        return out(201, ["username": name, "revision": "1", "created": true])
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


/// A store whose writes fail while `shouldFail` says so (disk full, protection unavailable).
final class FlakyDraftStore: OnboardingDraftStore, @unchecked Sendable {
    struct Disk: Error {}
    let inner = MemoryOnboardingDraftStore()
    private let lock = NSLock()
    private var rule: @Sendable (OnboardingDraft) -> Bool
    init(failWhen rule: @escaping @Sendable (OnboardingDraft) -> Bool = { _ in true }) { self.rule = rule }
    func breakAll() { lock.withLock { rule = { _ in true } } }
    func heal() { lock.withLock { rule = { _ in false } } }
    func load(origin: String, signerNpub: String) -> OnboardingDraft? { inner.load(origin: origin, signerNpub: signerNpub) }
    func save(_ draft: OnboardingDraft) throws {
        if lock.withLock({ rule(draft) }) { throw Disk() }
        try inner.save(draft)
    }
    func clear(origin: String, signerNpub: String) { inner.clear(origin: origin, signerNpub: signerNpub) }
}

/// Identity that can be swapped under a running controller (lock/remove/import of another key during an await).
final class SwappableSigner: EventSigner, @unchecked Sendable {
    private let lock = NSLock()
    private var current: IdentityService
    init(_ first: IdentityService) { current = first }
    func swap(to next: IdentityService) { lock.withLock { current = next } }
    private var now: IdentityService { lock.withLock { current } }
    func sign(_ template: NostrEventTemplate) async throws -> NostrEvent { try await now.sign(template) }
    func publicKeyHex() async throws -> String { try await now.publicKeyHex() }
}
