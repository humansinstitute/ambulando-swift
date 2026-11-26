import CryptoKit
import Foundation
import P256K
import XCTest
@testable import AmbulandoCore

// NIP-44 v2 against the official vectors (Fixtures/nip44.vectors.json, paulmillr/nip44), and the browser boundary for
// `window.nostr.nip44`: strict parameters, per-request approval, account/document/lock binding. Synthetic keys only.

final class NIP44VectorTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/nip44.vectors.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return root["v2"] as! [String: Any]
    }
    private func section(_ group: String, _ name: String) throws -> [[String: Any]] {
        ((try vectors()[group] as! [String: Any])[name]) as! [[String: Any]]
    }
    private func sha256Hex(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    func testConversationKeysMatchOfficialVectors() throws {
        let cases = try section("valid", "get_conversation_key")
        XCTAssertGreaterThan(cases.count, 30)
        for c in cases {
            let key = try NIP44.conversationKey(secret: Data(hex: c["sec1"] as! String)!, peer: c["pub2"] as! String)
            XCTAssertEqual(key.hex, c["conversation_key"] as? String, "sec1 \(c["sec1"] as! String)")
        }
    }

    func testInvalidConversationKeyInputsAreRefused() throws {
        for c in try section("invalid", "get_conversation_key") {
            XCTAssertThrowsError(try NIP44.conversationKey(secret: Data(hex: c["sec1"] as! String) ?? Data(), peer: c["pub2"] as! String), c["note"] as! String)
        }
        // Not a lowercase 32-byte hex key.
        let secret = Data(repeating: 0x31, count: 32)
        for bad in ["", "ab", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "a", count: 66), "npub1xyz"] {
            XCTAssertThrowsError(try NIP44.conversationKey(secret: secret, peer: bad), bad)
        }
    }

    func testMessageKeysAndPaddingMatchOfficialVectors() throws {
        let keys = (try vectors()["valid"] as! [String: Any])["get_message_keys"] as! [String: Any]
        let conversation = Data(hex: keys["conversation_key"] as! String)!
        for k in keys["keys"] as! [[String: Any]] {
            let material = NIP44.keys(conversation, Data(hex: k["nonce"] as! String)!)
            XCTAssertEqual(material.prefix(32).hex, k["chacha_key"] as? String)
            XCTAssertEqual(material.subdata(in: 32..<44).hex, k["chacha_nonce"] as? String)
            XCTAssertEqual(material.suffix(32).hex, k["hmac_key"] as? String)
        }
        let lengths = (try vectors()["valid"] as! [String: Any])["calc_padded_len"] as! [[Int]]
        for pair in lengths { XCTAssertEqual(NIP44.paddedLength(pair[0]), pair[1], "\(pair[0])") }
    }

    func testEncryptDecryptMatchOfficialVectors() throws {
        for c in try section("valid", "encrypt_decrypt") {
            let key = Data(hex: c["conversation_key"] as! String)!
            let plaintext = c["plaintext"] as! String
            let payload = c["payload"] as! String
            XCTAssertEqual(try NIP44.encryptStrict(plaintext, key: key, nonce: Data(hex: c["nonce"] as! String)!), payload)
            XCTAssertEqual(try NIP44.decryptStrict(payload, key: key), plaintext)
            // And from the secret keys: both sides derive the same conversation key.
            let a = try NIP44.conversationKey(secret: Data(hex: c["sec1"] as! String)!, peer: try pub(of: c["sec2"] as! String))
            XCTAssertEqual(a.hex, c["conversation_key"] as? String)
        }
    }

    func testLongMessagesMatchOfficialVectors() throws {
        for c in try section("valid", "encrypt_decrypt_long_msg") {
            let key = Data(hex: c["conversation_key"] as! String)!
            let plaintext = String(repeating: c["pattern"] as! String, count: c["repeat"] as! Int)
            XCTAssertEqual(sha256Hex(plaintext), c["plaintext_sha256"] as? String)
            let payload = try NIP44.encryptStrict(plaintext, key: key, nonce: Data(hex: c["nonce"] as! String)!)
            XCTAssertEqual(sha256Hex(payload), c["payload_sha256"] as? String)
            XCTAssertEqual(try NIP44.decryptStrict(payload, key: key), plaintext)
        }
    }

    func testInvalidPayloadsAreRefused() throws {
        for c in try section("invalid", "decrypt") {
            let key = Data(hex: c["conversation_key"] as! String)!
            XCTAssertThrowsError(try NIP44.decryptStrict(c["payload"] as! String, key: key), c["note"] as! String)
        }
        let key = Data(repeating: 7, count: 32)
        XCTAssertThrowsError(try NIP44.encryptStrict("", key: key), "empty plaintext")
        XCTAssertThrowsError(try NIP44.encryptStrict(String(repeating: "a", count: 65536), key: key), "over 65535 bytes")
        let good = try NIP44.encryptStrict("hello", key: key)
        XCTAssertEqual(try NIP44.decryptStrict(good, key: key), "hello")
        XCTAssertThrowsError(try NIP44.decryptStrict(good, key: Data(repeating: 8, count: 32)), "wrong key")
        var tampered = Array(good.utf8)
        tampered[tampered.count / 2] = tampered[tampered.count / 2] == 65 ? 66 : 65
        XCTAssertThrowsError(try NIP44.decryptStrict(String(decoding: tampered, as: UTF8.self), key: key), "tampered MAC")
        XCTAssertThrowsError(try NIP44.decryptStrict("#" + good.dropFirst(), key: key), "future version marker")
    }

    private func pub(of secretHex: String) throws -> String {
        // x-only public key from the secret, via the identity code path used for npubs.
        try Data(P256K.Schnorr.PrivateKey(dataRepresentation: Data(hex: secretHex)!).xonly.bytes).hex
    }
}

final class NIP44ParseTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let peer = String(repeating: "ab", count: 32)

    func testStrictParameters() {
        func parse(_ method: String, _ params: Any?) -> Result<NIP07Method, NIP07Error> { NIP07Method.parse(method: method, params: params, now: now) }
        guard case .success(.nip44(.encrypt(let p, let t))) = parse("nip44.encrypt", ["pubkey": peer, "plaintext": "hi"]) else { return XCTFail() }
        XCTAssertEqual(p, peer); XCTAssertEqual(t, "hi")
        let payload = String(repeating: "A", count: 132)
        guard case .success(.nip44(.decrypt(_, let c))) = parse("nip44.decrypt", ["pubkey": peer, "ciphertext": payload]) else { return XCTFail() }
        XCTAssertEqual(c, payload)
        let bad: [(String, Any?)] = [
            ("nip44.encrypt", nil), ("nip44.encrypt", "x"), ("nip44.encrypt", [String: Any]()),
            ("nip44.encrypt", ["pubkey": peer]), ("nip44.encrypt", ["plaintext": "x"]),
            ("nip44.encrypt", ["pubkey": peer, "plaintext": "x", "extra": 1]),
            ("nip44.encrypt", ["pubkey": peer, "ciphertext": "x"]),
            ("nip44.encrypt", ["pubkey": peer, "plaintext": 5]),
            ("nip44.encrypt", ["pubkey": peer, "plaintext": ""]),
            ("nip44.encrypt", ["pubkey": peer, "plaintext": String(repeating: "a", count: 65536)]),
            ("nip44.encrypt", ["pubkey": peer.uppercased(), "plaintext": "x"]),
            ("nip44.encrypt", ["pubkey": "02" + peer, "plaintext": "x"]),
            ("nip44.encrypt", ["pubkey": 5, "plaintext": "x"]),
            ("nip44.decrypt", ["pubkey": peer, "plaintext": payload]),
            ("nip44.decrypt", ["pubkey": peer, "ciphertext": "#" + payload]),
            ("nip44.decrypt", ["pubkey": peer, "ciphertext": "short"]),
            ("nip44.decrypt", ["pubkey": peer, "ciphertext": String(repeating: "A", count: 87473)]),
            ("nip44.decrypt", ["pubkey": "nothex", "ciphertext": payload]),
        ]
        for (method, params) in bad {
            if case .success = parse(method, params) { XCTFail("accepted \(method) \(String(describing: params).prefix(80))") }
        }
        if case .success(.nip44) = parse("nip44.encrypt", ["pubkey": peer, "plaintext": String(repeating: "a", count: 65535)]) {} else { XCTFail("65535 bytes is the limit") }
        XCTAssertEqual(try? parse("nip04.encrypt", nil).get(), .unsupported("nip04.encrypt"))
    }
}

private final class ActiveAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var service: IdentityService
    init(_ service: IdentityService) { self.service = service }
    var current: IdentityService { lock.lock(); defer { lock.unlock() }; return service }
    func switchTo(_ other: IdentityService) { lock.lock(); service = other; lock.unlock() }
}

private actor CipherGate {
    private var continuation: CheckedContinuation<String, Never>?
    var started: Bool { continuation != nil }
    func run() async -> String { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(returning: "cipher output"); continuation = nil }
}

@MainActor
final class NIP44BrokerTests: XCTestCase {
    private var alice: IdentityService!
    private var bob: IdentityService!
    private var account: ActiveAccount!
    private var alicePub = ""
    private var bobPub = ""
    let origin = "https://gitworkshop.example"
    let tab = UUID()

    override func setUp() async throws {
        func make(_ byte: UInt8) async throws -> IdentityService {
            let s = IdentityService(vaultURL: temporaryDirectory("nip44").appendingPathComponent("vault.json"), secrets: MemorySecretStore())
            try await s.importIdentity(nsec: Bech32.encode(hrp: "nsec", data: Data(repeating: byte, count: 32)), pin: TestKeys.pin)
            return s
        }
        alice = try await make(0x31); bob = try await make(0x32)
        alicePub = try await alice.publicKeyHex(); bobPub = try await bob.publicKeyHex()
        account = ActiveAccount(alice)
    }

    private func makeBroker(sites: [String: NIP07SitePermission] = [:]) -> NIP07Broker {
        let box = account!
        return NIP07Broker(locked: false, sites: sites,
                           publicKey: { try await box.current.publicKeyHex() },
                           signer: { try await box.current.sign($0) },
                           cipher: { op, expected in try await box.current.nip44(op, expectedPublicKey: expected) })
    }

    private func start(_ broker: NIP07Broker, _ method: String, _ params: Any?, document: UInt64 = 1,
                       current: @escaping @MainActor () -> Bool = { true }) async -> Task<Result<NIP07Reply, NIP07Error>, Never> {
        let context = NIP07Context(tabId: tab, documentId: document, origin: origin)
        let before = broker.prompts.count
        let task = Task { @MainActor in await broker.handle(method: method, params: params, context: context, isCurrent: current) }
        for _ in 0..<200 where broker.prompts.count == before { await Task.yield(); try? await Task.sleep(for: .milliseconds(2)) }
        return task
    }

    private func encrypt(_ broker: NIP07Broker, to peer: String, _ text: String, remember: Bool = false) async throws -> String {
        let task = await start(broker, "nip44.encrypt", ["pubkey": peer, "plaintext": text])
        broker.resolve(try XCTUnwrapValue(broker.current).id, .allow(remember: remember))
        guard case .text(let payload) = try await task.value.get() else { throw NIP07Error.closed }
        return payload
    }

    func testSelfEncryptionRoundTripsAndIsPromptedForSelfAndPeer() async throws {
        let broker = makeBroker()
        let task = await start(broker, "nip44.encrypt", ["pubkey": alicePub, "plaintext": "private list"])
        let prompt = try XCTUnwrapValue(broker.current)
        XCTAssertEqual(prompt.kind, .encrypt(peer: alicePub, isSelf: true, bytes: 12))
        XCTAssertEqual(prompt.context.origin, origin)
        broker.resolve(prompt.id, .allow(remember: false))
        guard case .text(let payload) = try await task.value.get() else { return XCTFail() }
        XCTAssertEqual(NIP07Reply.text(payload).javaScriptValue as? String, payload)

        let back = await start(broker, "nip44.decrypt", ["pubkey": alicePub, "ciphertext": payload])
        XCTAssertEqual(try XCTUnwrapValue(broker.current).kind, .decrypt(peer: alicePub, isSelf: true, bytes: payload.utf8.count))
        broker.resolve(try XCTUnwrapValue(broker.current).id, .allow(remember: false))
        let backResult = try await back.value.get()
        XCTAssertEqual(backResult, .text("private list"))

        // Interoperates: Bob decrypts a message Alice encrypted to him, using Alice's pubkey.
        let toBob = try await encrypt(broker, to: bobPub, "for bob")
        let bobBroker = { account.switchTo(bob); return makeBroker() }()
        let read = await start(bobBroker, "nip44.decrypt", ["pubkey": alicePub, "ciphertext": toBob])
        let bobPrompt = try XCTUnwrapValue(bobBroker.current)
        XCTAssertEqual(bobPrompt.kind, .decrypt(peer: alicePub, isSelf: false, bytes: toBob.utf8.count))
        bobBroker.resolve(bobPrompt.id, .allow(remember: true))
        let readResult = try await read.value.get()
        XCTAssertEqual(readResult, .text("for bob"))
        // Approval applies to decrypt only, including after unlock.
        bobBroker.setLocked(true); bobBroker.setLocked(false)
        let again = await bobBroker.handle(method: "nip44.decrypt", params: ["pubkey": alicePub, "ciphertext": toBob],
            context: .init(tabId: tab, documentId: 2, origin: origin), isCurrent: { true })
        XCTAssertEqual(again, .success(.text("for bob")))
    }

    func testPersistentGrantIsPerOriginAndOperation() async throws {
        let broker = makeBroker()
        let payload = try await encrypt(broker, to: alicePub, "list", remember: true)
        let saved = try JSONDecoder().decode(Set<String>.self, from: JSONEncoder().encode(broker.grants))
        let box = account!
        let reopened = NIP07Broker(locked: false, grants: saved,
            publicKey: { try await box.current.publicKeyHex() }, signer: { try await box.current.sign($0) },
            cipher: { try await box.current.nip44($0, expectedPublicKey: $1) })
        let silent = await reopened.handle(method: "nip44.encrypt", params: ["pubkey": bobPub, "plaintext": "again"],
            context: .init(tabId: tab, documentId: 2, origin: origin), isCurrent: { true })
        guard case .success(.text) = silent else { return XCTFail("persisted encryption should not prompt") }
        let decrypt = await start(reopened, "nip44.decrypt", ["pubkey": alicePub, "ciphertext": payload])
        XCTAssertNotNil(reopened.current, "decrypt asks separately")
        reopened.resolve(reopened.current!.id, .deny(remember: false))
        _ = await decrypt.value
        let allowDecrypt = await start(reopened, "nip44.decrypt", ["pubkey": alicePub, "ciphertext": payload])
        reopened.resolve(reopened.current!.id, .allow(remember: true))
        _ = try await allowDecrypt.value.get()
        // Revoke encryption alone; independent decrypt authority survives.
        let grant = NIP07Broker.operationGrant(origin, alicePub, "nip44.encrypt")
        reopened.revoke(grant)
        XCTAssertFalse(reopened.grants.contains(grant))
        let stillDecrypts = await reopened.handle(method: "nip44.decrypt", params: ["pubkey": alicePub, "ciphertext": payload],
            context: .init(tabId: tab, documentId: 3, origin: origin), isCurrent: { true })
        XCTAssertEqual(stillDecrypts, .success(.text("list")))
        reopened.forget(origin)
        XCTAssertTrue(reopened.grants.isEmpty)
        let revoked = await start(reopened, "nip44.encrypt", ["pubkey": alicePub, "plaintext": "x"])
        XCTAssertNotNil(reopened.current)
        reopened.resolve(reopened.current!.id, .deny(remember: false))
        _ = await revoked.value
    }

    func testDenialAndMalformedCallsNeverReachTheKey() async throws {
        let broker = makeBroker(sites: [origin: .denied])
        let denied = await broker.handle(method: "nip44.decrypt", params: ["pubkey": alicePub, "ciphertext": String(repeating: "A", count: 200)],
                                         context: .init(tabId: tab, documentId: 1, origin: origin), isCurrent: { true })
        XCTAssertEqual(denied, .failure(.denied))
        let open = makeBroker()
        let malformed = await open.handle(method: "nip44.encrypt", params: ["pubkey": "zz", "plaintext": "x"],
                                          context: .init(tabId: tab, documentId: 1, origin: origin), isCurrent: { true })
        guard case .failure(.invalid) = malformed else { return XCTFail() }
        XCTAssertNil(open.current, "malformed calls never show a sheet")
        // Well-formed but not a curve point, and a tampered payload: approved, then refused without output.
        for params in [["pubkey": String(repeating: "00", count: 32), "plaintext": "x"],
                       ["pubkey": String(repeating: "ff", count: 32), "plaintext": "x"]] {
            let task = await start(open, "nip44.encrypt", params)
            open.resolve(try XCTUnwrapValue(open.current).id, .allow(remember: false))
            guard case .failure(.invalid) = await task.value else { return XCTFail("invalid curve point must fail") }
        }
        let garbage = await start(open, "nip44.decrypt", ["pubkey": alicePub, "ciphertext": String(repeating: "A", count: 200)])
        open.resolve(try XCTUnwrapValue(open.current).id, .allow(remember: false))
        guard case .failure(.invalid) = await garbage.value else { return XCTFail("bad MAC must fail") }
        let unsupported = await open.handle(method: "nip04.encrypt", params: nil, context: .init(tabId: tab, documentId: 1, origin: origin), isCurrent: { true })
        XCTAssertEqual(unsupported, .failure(.unsupported("nip04.encrypt")))
    }

    func testSelfGrantForAliceNeverAuthorizesBob() async throws {
        let broker = makeBroker()
        _ = try await encrypt(broker, to: alicePub, "alice", remember: true)
        account.switchTo(bob)
        let next = await start(broker, "nip44.encrypt", ["pubkey": bobPub, "plaintext": "bob"])
        let prompt = try XCTUnwrapValue(broker.current)
        XCTAssertEqual(prompt.npub, NostrKeys.npub(publicKeyHex: bobPub))
        broker.resolve(prompt.id, .deny(remember: false))
        let result = await next.value
        XCTAssertEqual(result, .failure(.denied))
    }

    func testChangesDuringAwaitedCipherSuppressResult() async throws {
        for change in ["account", "denial", "forget", "reset", "lock", "navigation"] {
            account.switchTo(alice)
            let box = account!
            let gate = CipherGate()
            let broker = NIP07Broker(locked: false,
                publicKey: { try await box.current.publicKeyHex() },
                signer: { try await box.current.sign($0) },
                cipher: { _, _ in await gate.run() })
            var live = true
            let request = await start(broker, "nip44.encrypt", ["pubkey": alicePub, "plaintext": "x"], current: { live })
            broker.resolve(try XCTUnwrapValue(broker.current).id, .allow(remember: false))
            for _ in 0..<200 {
                if await gate.started { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            let started = await gate.started
            XCTAssertTrue(started)
            switch change {
            case "account": account.switchTo(bob)
            case "denial":
                let connect = await start(broker, "getPublicKey", nil)
                broker.resolve(try XCTUnwrapValue(broker.current).id, .deny(remember: true))
                _ = await connect.value
            case "forget": broker.forget(origin)
            case "reset": broker.reset()
            case "lock": broker.setLocked(true); broker.setLocked(false)
            default: live = false
            }
            await gate.finish()
            let result = await request.value
            let expected: NIP07Error = change == "account" ? .accountChanged : (change == "navigation" ? .pageChanged : .denied)
            XCTAssertEqual(result, .failure(expected), change)
        }
    }

    func testSigningIsBoundToAccountAndKind() async throws {
        let broker = makeBroker()
        let first = await start(broker, "signEvent", ["kind": 1])
        account.switchTo(bob)
        broker.resolve(broker.current!.id, .allow(remember: true))
        let switched = await first.value
        XCTAssertEqual(switched, .failure(.accountChanged))
        XCTAssertTrue(broker.grants.isEmpty)
        account.switchTo(alice)
        let granted = await start(broker, "signEvent", ["kind": 1])
        broker.resolve(broker.current!.id, .allow(remember: true))
        _ = try await granted.value.get()
        account.switchTo(bob)
        let otherAccount = await start(broker, "signEvent", ["kind": 1])
        XCTAssertNotNil(broker.current)
        broker.resolve(broker.current!.id, .deny(remember: false))
        _ = await otherAccount.value
        do {
            _ = try await bob.signForBrowser(NostrEventTemplate(kind: 1, tags: [], content: "x"), expectedPublicKey: alicePub)
            XCTFail("identity actor must refuse mismatched browser signing")
        } catch { XCTAssertEqual(error as? IdentityError, .signerMismatch) }
    }

    func testAccountTransitionInvalidatesAwaitedCipherEvenAfterSwitchBack() async throws {
        let box = account!
        let gate = CipherGate()
        let broker = NIP07Broker(locked: false,
            publicKey: { try await box.current.publicKeyHex() }, signer: { try await box.current.sign($0) },
            cipher: { _, _ in await gate.run() })
        let request = await start(broker, "nip44.encrypt", ["pubkey": alicePub, "plaintext": "x"])
        broker.resolve(broker.current!.id, .allow(remember: false))
        for _ in 0..<200 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        broker.accountChanged()
        await gate.finish()
        let result = await request.value
        XCTAssertEqual(result, .failure(.denied))
    }

    func testAccountSwitchWhileWaitingRefusesTheCall() async throws {
        let broker = makeBroker()
        let task = await start(broker, "nip44.encrypt", ["pubkey": alicePub, "plaintext": "secret"])
        XCTAssertNotNil(broker.current)
        account.switchTo(bob)
        broker.resolve(broker.current!.id, .allow(remember: false))
        let result = await task.value
        XCTAssertEqual(result, .failure(.accountChanged), "approved for one account, never run for another")
        // The identity itself also refuses a mismatched expectation.
        do { _ = try await bob.nip44(.encrypt(peer: alicePub, plaintext: "x"), expectedPublicKey: alicePub); XCTFail() } catch { XCTAssertEqual(error as? IdentityError, .signerMismatch) }
    }

    func testNavigationLockAndRevocationWinOverApproval() async throws {
        // Navigation: the document changes while the sheet is up.
        let broker = makeBroker()
        var live = true
        let nav = await start(broker, "nip44.encrypt", ["pubkey": alicePub, "plaintext": "x"], current: { live })
        live = false
        broker.resolve(broker.current!.id, .allow(remember: false))
        let navResult = await nav.value
        XCTAssertEqual(navResult, .failure(.pageChanged))
        // documentChanged cancels the waiting request.
        var docLive = true
        let doc = await start(broker, "nip44.decrypt", ["pubkey": alicePub, "ciphertext": String(repeating: "A", count: 200)], current: { docLive })
        docLive = false
        broker.documentChanged(tabId: tab, documentId: 2)
        let docResult = await doc.value
        XCTAssertEqual(docResult, .failure(.pageChanged))
        // Lock.
        let lock = await start(broker, "nip44.encrypt", ["pubkey": alicePub, "plaintext": "x"])
        broker.setLocked(true)
        let lockResult = await lock.value
        XCTAssertEqual(lockResult, .failure(.locked))
        broker.setLocked(false)
        // Identity removed / disconnected.
        let reset = await start(broker, "nip44.encrypt", ["pubkey": alicePub, "plaintext": "x"])
        broker.reset()
        let resetResult = await reset.value
        XCTAssertNotEqual(resetResult, .success(.text("")))
        guard case .failure = resetResult else { return XCTFail() }
        // Tab closed.
        let closed = await start(broker, "nip44.encrypt", ["pubkey": alicePub, "plaintext": "x"])
        broker.tabClosed(tab)
        guard case .failure = await closed.value else { return XCTFail() }
    }

    func testSiteDeniedWhileWaitingRefusesTheCall() async throws {
        let broker = makeBroker()
        let task = await start(broker, "nip44.encrypt", ["pubkey": alicePub, "plaintext": "x"])
        // The user denies the site in the connect flow elsewhere before answering this sheet.
        let other = await start(broker, "getPublicKey", nil)
        broker.resolve(broker.prompts.last!.id, .deny(remember: true))
        _ = await other.value
        broker.resolve(broker.prompts.first!.id, .allow(remember: false))
        let result = await task.value
        XCTAssertEqual(result, .failure(.denied))
    }
}
