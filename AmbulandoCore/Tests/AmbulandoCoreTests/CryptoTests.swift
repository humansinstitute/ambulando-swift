import XCTest
@testable import AmbulandoCore

final class Bech32Tests: XCTestCase {
    func testNIP19Vectors() {
        XCTAssertEqual(NostrKeys.npub(publicKeyHex: TestKeys.pubkeyHex), TestKeys.npub)
        XCTAssertEqual(NostrKeys.publicKeyHex(npub: TestKeys.npub), TestKeys.pubkeyHex)
        XCTAssertEqual(NostrKeys.secretKey(nsec: TestKeys.nsec)?.hex, TestKeys.secretHex)
        XCTAssertEqual(NostrKeys.secretKey(nsec: TestKeys.nsec.uppercased())?.hex, TestKeys.secretHex)
    }

    func testRejectsInvalidSecrets() {
        var broken = Array(TestKeys.nsec)
        broken[20] = broken[20] == "q" ? "p" : "q"
        XCTAssertNil(NostrKeys.secretKey(nsec: String(broken)), "checksum")
        XCTAssertNil(NostrKeys.secretKey(nsec: TestKeys.npub), "wrong hrp")
        XCTAssertNil(NostrKeys.secretKey(nsec: "nsec1" + TestKeys.nsec.dropFirst(5).uppercased()), "mixed case")
        XCTAssertNil(NostrKeys.secretKey(nsec: Bech32.encode(hrp: "nsec", data: Data(count: 32))), "zero scalar")
        XCTAssertNil(NostrKeys.secretKey(nsec: Bech32.encode(hrp: "nsec", data: Data(NostrKeys.order))), "scalar == n")
        XCTAssertNil(NostrKeys.secretKey(nsec: Bech32.encode(hrp: "nsec", data: Data(repeating: 0xff, count: 32))), "scalar > n")
        XCTAssertNil(NostrKeys.secretKey(nsec: Bech32.encode(hrp: "nsec", data: Data(repeating: 1, count: 31))), "short")
        XCTAssertFalse(NostrKeys.isValidNpub("npub1notvalid"))
    }
}

final class EventSerializationTests: XCTestCase {
    /// Fixture produced by nostr-tools `finalizeEvent` (sol/node_modules) with the NIP-19 test key.
    static let jsId = "e57e2c6cbc63655a061e15b3177d395ef70ae5e0f2eeeaaaf9e9e73665e2014f"
    static let jsSig = "385240f679db5544ac3ea8304e4b8955c9262049ee9c744f13ef8bb15b37ccb0b71c9ec926be0503e0e21b3270086b000f8b72127ceb7248771de016205a6b27"
    static let template = NostrEventTemplate(
        kind: 33358,
        tags: [["protocol", "flightdeck_pg_message_instruction"], ["body_sha256", "abc"], ["thread_id", "t/1"]],
        content: "Hello \"world\"\\ \n\t\u{01} é ✓ / </script>", createdAt: 1_760_000_000)

    func testEventIdMatchesNostrTools() {
        XCTAssertEqual(NostrSerialization.eventId(pubkey: TestKeys.pubkeyHex, template: Self.template), Self.jsId)
    }

    func testVerifiesNostrToolsSignature() {
        let event = NostrEvent(id: Self.jsId, pubkey: TestKeys.pubkeyHex, created_at: 1_760_000_000, kind: 33358,
                               tags: Self.template.tags, content: Self.template.content, sig: Self.jsSig)
        XCTAssertTrue(SignatureVerifier.verify(event))
        let tampered = NostrEvent(id: event.id, pubkey: event.pubkey, created_at: event.created_at, kind: event.kind,
                                  tags: event.tags, content: event.content + "!", sig: event.sig)
        XCTAssertFalse(SignatureVerifier.verify(tampered))
    }

    func testQuoteMatchesJSONStringifyRules() {
        XCTAssertEqual(NostrSerialization.quote("a\"b\\c\n\r\t\u{08}\u{0C}\u{1F}é/"), "\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u001fé/\"")
    }
}

final class IdentityVaultTests: XCTestCase {
    func testImportUnlockSignLockLifecycle() async throws {
        let dir = temporaryDirectory()
        let secrets = MemorySecretStore()
        let service = IdentityService(vaultURL: dir.appendingPathComponent("vault.json"), secrets: secrets)
        let initial = await service.state
        XCTAssertEqual(initial, .none)
        let imported = try await service.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        XCTAssertEqual(imported, .unlocked(npub: TestKeys.npub))

        let event = try await service.sign(NostrEventTemplate(kind: 1, tags: [], content: "hi"))
        XCTAssertEqual(event.pubkey, TestKeys.pubkeyHex)
        XCTAssertTrue(SignatureVerifier.verify(event))

        do { let value = await service.lock(); XCTAssertEqual(value, .locked(npub: TestKeys.npub)) }
        do { _ = try await service.sign(NostrEventTemplate(kind: 1, tags: [], content: "x")); XCTFail("signed while locked") }
        catch { XCTAssertEqual(error as? IdentityError, .locked) }

        do { try await service.unlock(pin: "999999"); XCTFail("wrong PIN accepted") }
        catch { XCTAssertEqual(error as? IdentityError, .invalidVault) }
        do { let value = try await service.unlock(pin: TestKeys.pin); XCTAssertEqual(value, .unlocked(npub: TestKeys.npub)) }

        // A fresh service on the same files (app relaunch) starts locked and knows the public identity only.
        let relaunched = IdentityService(vaultURL: dir.appendingPathComponent("vault.json"), secrets: secrets)
        do { let value = await relaunched.state; XCTAssertEqual(value, .locked(npub: TestKeys.npub)) }
        XCTAssertEqual(secrets.writes, 1)
    }

    func testEnvelopeNeverContainsSecretMaterial() async throws {
        let dir = temporaryDirectory()
        _ = try await makeIdentity(directory: dir)
        let disk = try String(contentsOf: dir.appendingPathComponent("vault.json"), encoding: .utf8)
        XCTAssertFalse(disk.contains(TestKeys.nsec))
        XCTAssertFalse(disk.contains(TestKeys.secretHex))
        XCTAssertFalse(disk.contains(Data(hex: TestKeys.secretHex)!.base64EncodedString()))
        XCTAssertTrue(disk.contains(TestKeys.pubkeyHex))
    }

    func testRefusesOverwriteBadPINAndBadNsec() async throws {
        let dir = temporaryDirectory()
        let service = IdentityService(vaultURL: dir.appendingPathComponent("vault.json"), secrets: MemorySecretStore())
        do { try await service.importIdentity(nsec: TestKeys.nsec, pin: "12"); XCTFail() } catch { XCTAssertEqual(error as? IdentityError, .invalidPIN) }
        do { try await service.importIdentity(nsec: "nsec1bad", pin: TestKeys.pin); XCTFail() } catch { XCTAssertEqual(error as? IdentityError, .invalidNsec) }
        try await service.importIdentity(nsec: TestKeys.nsec, pin: TestKeys.pin)
        do { try await service.importIdentity(nsec: TestKeys.otherNsec(), pin: TestKeys.pin); XCTFail() } catch { XCTAssertEqual(error as? IdentityError, .exists) }
        do { let value = await service.state; XCTAssertEqual(value, .unlocked(npub: TestKeys.npub)) }
        try await service.remove()
        do { let value = await service.state; XCTAssertEqual(value, .none) }
    }

    func testSignerBinding() async throws {
        let service = try await makeIdentity()
        try await service.requireSigner(npub: TestKeys.npub)
        do { try await service.requireSigner(npub: NostrKeys.npub(publicKeyHex: String(repeating: "ab", count: 32))!); XCTFail() }
        catch { XCTAssertEqual(error as? IdentityError, .signerMismatch) }
        await service.lock()
        do { try await service.requireSigner(npub: TestKeys.npub); XCTFail() } catch { XCTAssertEqual(error as? IdentityError, .locked) }
    }
}

final class SigningContractTests: XCTestCase {
    func testNIP98TagsAndExactBodyHash() async throws {
        let identity = try await makeIdentity()
        let url = URL(string: "https://tower.example/api/v4/flightdeck-pg/workspaces?limit=200")!
        let body = Data(#"{"b":1,"a":"x"}"#.utf8)
        let header = try await NIP98.authorization(url: url, method: "post", body: body, signer: identity)
        var request = URLRequest(url: url)
        request.setValue(header, forHTTPHeaderField: "Authorization")
        let event = try decodeAuthorization(request)
        XCTAssertEqual(event.kind, 27235)
        XCTAssertEqual(event.content, "")
        XCTAssertEqual(event.tags, [["u", url.absoluteString], ["method", "POST"], ["payload", SHA256Hex.of(body)]])
        XCTAssertTrue(SignatureVerifier.verify(event))
        XCTAssertLessThan(abs(event.created_at - Int(Date().timeIntervalSince1970)), 5)
        XCTAssertEqual(NIP98.tags(url: url, method: "GET", body: nil).count, 2, "no payload tag without a body")
    }

    func testMessageInstructionSignatureMatchesWebContract() async throws {
        let identity = try await makeIdentity()
        let signed = try await MessageInstructionSignature.sign(body: "Ship it", workspaceId: "w", channelId: "c", threadId: "t", signer: identity)
        XCTAssertEqual(signed.event.kind, 33358)
        XCTAssertEqual(signed.event.content, "Ship it")
        XCTAssertEqual(signed.event.tags, [["protocol", "flightdeck_pg_message_instruction"], ["body_sha256", SHA256Hex.of("Ship it")],
                                           ["workspace_id", "w"], ["channel_id", "c"], ["thread_id", "t"]])
        XCTAssertEqual(signed.signerNpub, TestKeys.npub)
        XCTAssertTrue(SignatureVerifier.verify(signed.event))
        let object = signed.requestObject
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["body_sha256"] as? String, SHA256Hex.of("Ship it"))
        XCTAssertNotNil(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(MessageInstructionSignature.tags(body: "x", workspaceId: "w", channelId: "c", messageId: "m", revision: 2).suffix(2),
                       [["message_id", "m"], ["revision", "2"]])
    }
}
