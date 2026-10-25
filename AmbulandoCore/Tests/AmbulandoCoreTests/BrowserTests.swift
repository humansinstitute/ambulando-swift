import Foundation
import XCTest
@testable import AmbulandoCore

// The in-app browser's address rules and the native side of `window.nostr`: per-origin permission, one approval per
// signature, document binding, cancellation and lock. Synthetic key only; no network, no web view.

final class BrowserURLPolicyTests: XCTestCase {
    func testPagesAreHTTPSOnlyAndOtherAppsNeedAHandOff() {
        func decide(_ s: String, main: Bool = true) -> BrowserURLPolicy.Decision { BrowserURLPolicy.decide(URL(string: s)!, mainFrame: main) }
        XCTAssertEqual(decide("https://example.com/a?b=1"), .load)
        XCTAssertEqual(decide("about:blank"), .load, "window.open() starts here")
        if case .refuse = decide("http://example.com") {} else { XCTFail("plain HTTP pages are refused") }
        if case .refuse = decide("https://user:pw@example.com") {} else { XCTFail("credentials in the URL are refused") }
        if case .refuse = decide("https://node.fips/") {} else { XCTFail(".fips is refused") }
        if case .refuse = decide("javascript:alert(1)") {} else { XCTFail("javascript: is refused") }
        if case .refuse = decide("file:///etc/hosts") {} else { XCTFail("file: is refused") }
        if case .refuse = decide("data:text/html,hi") {} else { XCTFail("data: is not a page") }
        XCTAssertEqual(decide("data:text/html,hi", main: false), .load, "frames may use data:")
        XCTAssertEqual(decide("blob:https://example.com/1", main: false), .load)
        XCTAssertEqual(decide("mailto:a@example.com"), .external(URL(string: "mailto:a@example.com")!))
        XCTAssertEqual(decide("lightning:lnbc1"), .external(URL(string: "lightning:lnbc1")!))
        XCTAssertEqual(decide("nostr:npub1abc"), .external(URL(string: "nostr:npub1abc")!))
    }

    func testOriginsAndTypedAddresses() {
        XCTAssertEqual(BrowserURLPolicy.origin(of: URL(string: "https://Example.com/x")), "https://example.com")
        XCTAssertEqual(BrowserURLPolicy.origin(of: URL(string: "https://example.com:8443/x")), "https://example.com:8443")
        XCTAssertEqual(BrowserURLPolicy.origin(of: URL(string: "https://example.com:443/x")), "https://example.com")
        XCTAssertNil(BrowserURLPolicy.origin(of: URL(string: "http://example.com")))
        XCTAssertEqual(BrowserURLPolicy.origin(scheme: "https", host: "Example.com", port: 0), "https://example.com")
        XCTAssertEqual(BrowserURLPolicy.typedAddress("example.com/path")?.absoluteString, "https://example.com/path")
        XCTAssertEqual(BrowserURLPolicy.typedAddress(" https://example.com ")?.absoluteString, "https://example.com")
        XCTAssertEqual(BrowserURLPolicy.typedAddress("example.com:8443/x")?.absoluteString, "https://example.com:8443/x")
        XCTAssertNil(BrowserURLPolicy.typedAddress("http://example.com"))
        XCTAssertNil(BrowserURLPolicy.typedAddress("javascript:alert(1)"))
        XCTAssertNil(BrowserURLPolicy.typedAddress("not an address"))
        XCTAssertNil(BrowserURLPolicy.typedAddress("localhost"))
    }
}

final class NIP07RequestTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEventsAreParsedAndBounded() {
        guard case .success(.signEvent(let t, let pk)) = NIP07Method.parse(method: "signEvent", params: [
            "kind": 1, "content": "hi", "tags": [["t", "x"]], "created_at": 1_799_999_000] as [String: Any], now: now) else { return XCTFail() }
        XCTAssertEqual(t, NostrEventTemplate(kind: 1, tags: [["t", "x"]], content: "hi", createdAt: 1_799_999_000))
        XCTAssertNil(pk)
        guard case .success(.signEvent(let d, _)) = NIP07Method.parse(method: "signEvent", params: ["kind": 27235] as [String: Any], now: now)
        else { return XCTFail() }
        XCTAssertEqual(d.createdAt, 1_800_000_000, "created_at defaults to now")
        XCTAssertEqual(d.content, "")
        let bad: [[String: Any]] = [
            [:], ["kind": -1], ["kind": 70000], ["kind": true], ["kind": 1.5], ["kind": "1"],
            ["kind": 1, "content": 5], ["kind": 1, "tags": "x"], ["kind": 1, "tags": [[1]]],
            ["kind": 1, "content": String(repeating: "a", count: NIP07Method.maxContentBytes + 1)],
            ["kind": 1, "tags": Array(repeating: ["t"], count: NIP07Method.maxTags + 1)],
            ["kind": 1, "created_at": 9_999_999_999], ["kind": 1, "pubkey": 3],
        ]
        for params in bad {
            if case .success = NIP07Method.parse(method: "signEvent", params: params, now: now) { XCTFail("accepted \(params.keys.sorted())") }
        }
        if case .success = NIP07Method.parse(method: "signEvent", params: "x", now: now) { XCTFail() }
        XCTAssertEqual(try? NIP07Method.parse(method: "nip44.encrypt", params: nil, now: now).get(), .unsupported("nip44.encrypt"))
        XCTAssertEqual(try? NIP07Method.parse(method: "getRelays", params: nil, now: now).get(), .getRelays)
    }
}

@MainActor
final class NIP07BrokerTests: XCTestCase {
    var signer: IdentityService!
    var pubkey = ""
    var stored: [String: NIP07SitePermission] = [:]
    let origin = "https://app.example.com"
    let tab = UUID()

    override func setUp() async throws {
        let service = IdentityService(vaultURL: temporaryDirectory("nip07").appendingPathComponent("vault.json"), secrets: MemorySecretStore())
        try await service.importIdentity(nsec: Bech32.encode(hrp: "nsec", data: Data(repeating: 0x31, count: 32)), pin: TestKeys.pin)
        signer = service
        pubkey = try await service.publicKeyHex()
    }

    func makeBroker(sites: [String: NIP07SitePermission] = [:]) -> NIP07Broker {
        let service = signer!
        return NIP07Broker(locked: false, sites: sites,
                           publicKey: { try await service.publicKeyHex() },
                           signer: { try await service.sign($0) },
                           persist: { [weak self] in self?.stored = $0 })
    }

    /// Starts a request and waits until it either finished or shows a prompt.
    func start(_ broker: NIP07Broker, _ method: String, _ params: Any? = nil, document: UInt64 = 1, origin: String? = nil,
               current: @escaping @MainActor () -> Bool = { true }) async -> Task<Result<NIP07Reply, NIP07Error>, Never> {
        let context = NIP07Context(tabId: tab, documentId: document, origin: origin ?? self.origin)
        let before = broker.prompts.count
        let task = Task { @MainActor in await broker.handle(method: method, params: params, context: context, isCurrent: current) }
        for _ in 0..<200 where broker.prompts.count == before { await Task.yield(); try? await Task.sleep(for: .milliseconds(2)) }
        return task
    }

    func testPublicKeyNeedsTheSitesPermissionAndRememberingIsPerOrigin() async throws {
        let broker = makeBroker()
        let first = await start(broker, "getPublicKey")
        let prompt = try XCTUnwrapValue(broker.current)
        XCTAssertEqual(prompt.kind, .connect)
        XCTAssertEqual(prompt.context.origin, origin)
        XCTAssertNotNil(prompt.npub)
        broker.resolve(prompt.id, .allow(remember: true))
        let awaited1 = try await first.value.get()
        XCTAssertEqual(awaited1, .publicKey(pubkey))
        XCTAssertEqual(stored[origin], .allowed)

        // Remembered: no prompt for the same origin; another origin asks again.
        let awaited2 = try await broker.handle(method: "getPublicKey", params: nil, context: .init(tabId: tab, documentId: 1, origin: origin), isCurrent: { true }).get()
        XCTAssertEqual(awaited2,
                       .publicKey(pubkey))
        let other = await start(broker, "getPublicKey", origin: "https://other.example.com")
        let otherPrompt = try XCTUnwrapValue(broker.current)
        broker.resolve(otherPrompt.id, .deny(remember: true))
        let awaited3 = await other.value
        XCTAssertEqual(awaited3, .failure(.denied))
        XCTAssertEqual(stored["https://other.example.com"], .denied)
        // A denied site cannot ask to sign either, and forgetting it lets it ask again.
        let awaited4 = await broker.handle(method: "signEvent", params: ["kind": 1] as [String: Any],
                                           context: .init(tabId: tab, documentId: 1, origin: "https://other.example.com"), isCurrent: { true })
        XCTAssertEqual(awaited4, .failure(.denied))
        broker.forget("https://other.example.com")
        XCTAssertNil(stored["https://other.example.com"])
    }

    func testEverySignatureIsApprovedInASheetNamingTheSite() async throws {
        let broker = makeBroker(sites: [origin: .allowed])
        let params: [String: Any] = ["kind": 1, "content": "hello", "tags": [["t", "x"]], "created_at": 1_800_000_000]
        for round in 0..<2 {
            let task = await start(broker, "signEvent", params)
            let prompt = try XCTUnwrapValue(broker.current)
            XCTAssertEqual(prompt.context.origin, origin)
            XCTAssertFalse(prompt.offersSessionGrant, "ordinary kinds are never allowed in advance")
            guard case .sign(let template) = prompt.kind else { return XCTFail() }
            XCTAssertEqual(template.content, "hello")
            broker.resolve(prompt.id, .allow(remember: true))
            guard case .event(let event) = try await task.value.get() else { return XCTFail() }
            XCTAssertEqual(event.pubkey, pubkey)
            XCTAssertEqual(event.kind, 1)
            XCTAssertEqual(event.tags, [["t", "x"]])
            XCTAssertTrue(SignatureVerifier.verify(event))
            let js = NIP07Reply.event(event).javaScriptValue as? [String: Any]
            XCTAssertEqual(js?["sig"] as? String, event.sig)
        }
        // Rejected: the page's promise fails.
        let rejected = await start(broker, "signEvent", params)
        broker.resolve(try XCTUnwrapValue(broker.current).id, .deny(remember: false))
        let awaited5 = await rejected.value
        XCTAssertEqual(awaited5, .failure(.denied))
        // An event claiming another author is refused without a prompt.
        let awaited6 = await broker.handle(method: "signEvent", params: ["kind": 1, "pubkey": String(repeating: "ab", count: 32)] as [String: Any],
                                           context: .init(tabId: tab, documentId: 1, origin: origin), isCurrent: { true })
        XCTAssertEqual(awaited6,
                       .failure(.invalid("the event's pubkey is not this identity")))
        XCTAssertNil(broker.current)
    }

    func testAuthenticationKindsMayBeAllowedUntilLock() async throws {
        let broker = makeBroker()
        let auth: [String: Any] = ["kind": 27235, "tags": [["u", "https://app.example.com/api"], ["method", "GET"]]]
        let first = await start(broker, "signEvent", auth)
        let prompt = try XCTUnwrapValue(broker.current)
        XCTAssertTrue(prompt.offersSessionGrant)
        broker.resolve(prompt.id, .allow(remember: true))
        guard case .event = try await first.value.get() else { return XCTFail() }
        // Same site and kind: signed without asking. Another site still asks.
        guard case .event = try await broker.handle(method: "signEvent", params: auth, context: .init(tabId: tab, documentId: 1, origin: origin),
                                                    isCurrent: { true }).get() else { return XCTFail() }
        let other = await start(broker, "signEvent", auth, origin: "https://other.example.com")
        XCTAssertNotNil(broker.current)
        broker.resolve(broker.current!.id, .deny(remember: false))
        _ = await other.value
        // Locking forgets the grant.
        broker.setLocked(true)
        broker.setLocked(false)
        let again = await start(broker, "signEvent", auth)
        XCTAssertNotNil(broker.current, "asks again after a lock")
        broker.resolve(broker.current!.id, .deny(remember: false))
        _ = await again.value
    }

    func testLockCancelsWaitingRequestsAndRefusesNewOnes() async throws {
        let broker = makeBroker(sites: [origin: .allowed])
        let waiting = await start(broker, "signEvent", ["kind": 1] as [String: Any])
        XCTAssertNotNil(broker.current)
        broker.setLocked(true)
        XCTAssertNil(broker.current, "the sheet goes away")
        let awaited7 = await waiting.value
        XCTAssertEqual(awaited7, .failure(.locked))
        let awaited8 = await broker.handle(method: "getPublicKey", params: nil, context: .init(tabId: tab, documentId: 1, origin: origin), isCurrent: { true })
        XCTAssertEqual(awaited8,
                       .failure(.locked))
        let awaited9 = await broker.handle(method: "signEvent", params: ["kind": 1] as [String: Any], context: .init(tabId: tab, documentId: 1, origin: origin),
                                           isCurrent: { true })
        XCTAssertEqual(awaited9, .failure(.locked))
    }

    func testNavigationCancelsTheOldDocumentsRequestsAndApprovalIsRecheckedBeforeSigning() async throws {
        let broker = makeBroker(sites: [origin: .allowed])
        // The tab moves on to document 2: what document 1 asked is cancelled.
        var currentDocument: UInt64 = 1
        let old = await start(broker, "signEvent", ["kind": 1] as [String: Any], document: 1, current: { currentDocument == 1 })
        XCTAssertNotNil(broker.current)
        currentDocument = 2
        broker.documentChanged(tabId: tab, documentId: 2)
        XCTAssertNil(broker.current)
        let awaited10 = await old.value
        XCTAssertEqual(awaited10, .failure(.pageChanged))

        // The page changes while the sheet is open and the user still taps Sign: nothing is signed.
        var stillHere = true
        let raced = await start(broker, "signEvent", ["kind": 1] as [String: Any], document: 2, current: { stillHere })
        stillHere = false
        broker.resolve(try XCTUnwrapValue(broker.current).id, .allow(remember: false))
        let awaited11 = await raced.value
        XCTAssertEqual(awaited11, .failure(.pageChanged))

        // A request from a document that is no longer shown is refused outright; closing the tab cancels its prompts.
        let awaited12 = await broker.handle(method: "getPublicKey", params: nil, context: .init(tabId: tab, documentId: 1, origin: origin), isCurrent: { false })
        XCTAssertEqual(awaited12,
                       .failure(.pageChanged))
        let closing = await start(broker, "signEvent", ["kind": 1] as [String: Any], document: 2)
        broker.tabClosed(tab)
        let awaited13 = await closing.value
        XCTAssertEqual(awaited13, .failure(.closed))
    }

    func testWaitingRequestsPerTabAreBoundedAndUnsupportedMethodsReject() async throws {
        let broker = makeBroker(sites: [origin: .allowed])
        var tasks: [Task<Result<NIP07Reply, NIP07Error>, Never>] = []
        for _ in 0..<NIP07Broker.maxPromptsPerTab { tasks.append(await start(broker, "signEvent", ["kind": 1] as [String: Any])) }
        XCTAssertEqual(broker.prompts.count, NIP07Broker.maxPromptsPerTab)
        let awaited14 = await broker.handle(method: "signEvent", params: ["kind": 1] as [String: Any], context: .init(tabId: tab, documentId: 1, origin: origin),
                                           isCurrent: { true })
        XCTAssertEqual(awaited14, .failure(.busy))
        broker.tabClosed(tab)
        for task in tasks { _ = await task.value }
        let awaited15 = await broker.handle(method: "nip04.encrypt", params: nil, context: .init(tabId: tab, documentId: 1, origin: origin), isCurrent: { true })
        XCTAssertEqual(awaited15,
                       .failure(.unsupported("nip04.encrypt")))
        let awaited16 = await broker.handle(method: "getRelays", params: nil, context: .init(tabId: tab, documentId: 1, origin: origin), isCurrent: { true })
        XCTAssertEqual(awaited16,
                       .success(.relays))
        broker.reset()
        XCTAssertEqual(stored, [:])
    }
}
