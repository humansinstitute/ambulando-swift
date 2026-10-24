import XCTest
@testable import AmbulandoCore

final class TowerOriginTests: XCTestCase {
    func testAcceptsAndNormalisesHTTPSOrigins() throws {
        XCTAssertEqual(try TowerOrigin("https://Tower.Example/").description, "https://tower.example")
        XCTAssertEqual(try TowerOrigin(" https://tower.example:443 ").description, "https://tower.example")
        XCTAssertEqual(try TowerOrigin("https://tower.example:8443").description, "https://tower.example:8443")
    }

    func testRejectsUnsafeOrigins() {
        for value in ["http://tower.example", "https://u:p@tower.example", "https://tower.example/app", "https://tower.example?x=1",
                      "https://tower.example#f", "tower.example", "ftp://tower.example", ""] {
            XCTAssertThrowsError(try TowerOrigin(value), value) { XCTAssertEqual($0 as? TowerError, .unsafeOrigin, value) }
        }
    }

    func testRefusesFIPSWithoutFallback() {
        XCTAssertThrowsError(try TowerOrigin("http://npub1abc.fips:8080")) { XCTAssertEqual($0 as? TowerError, .fipsNotSupported) }
        XCTAssertThrowsError(try TowerOrigin("https://npub1abc.FIPS")) { XCTAssertEqual($0 as? TowerError, .fipsNotSupported) }
    }

    func testPathsAreConfinedToTheAPI() throws {
        let origin = try TowerOrigin("https://tower.example")
        XCTAssertEqual(try origin.url(path: "/api/v4/flightdeck-pg/workspaces", query: [URLQueryItem(name: "limit", value: "200")]).absoluteString,
                       "https://tower.example/api/v4/flightdeck-pg/workspaces?limit=200")
        for path in ["/admin", "/api/v4/../admin", "//evil.example/api/v4/x", "/api/v4/x?y=1", "https://evil.example/api/v4/x"] {
            XCTAssertThrowsError(try origin.url(path: path), path)
        }
    }

    func testRedirectDelegateRefuses() {
        let delegate = RefuseRedirects()
        let expectation = expectation(description: "completion")
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://tower.example")!)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(), newRequest: URLRequest(url: URL(string: "https://evil.example")!)) {
            XCTAssertNil($0)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}

final class TowerClientTests: XCTestCase {
    func testSignedRequestCarriesExactURLBodyHashAndAppHeader() async throws {
        let identity = try await makeIdentity()
        let transport = StubTransport { _ in (200, ["ok": true]) }
        let client = TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity)
        let body = Fixtures.json(["body": "hello", "client_request_id": "r1"])
        _ = try await client.request(method: "POST", path: "/api/v4/flightdeck-pg/workspaces/\(Fixtures.workspaceId)/channels/\(Fixtures.channel1)/messages",
                                     appNpub: Fixtures.appNpub, jsonBody: body)
        _ = try await client.request(path: "/api/v4/flightdeck-pg/workspaces", query: [URLQueryItem(name: "cursor", value: "abc_-")])
        let post = transport.recorded[0], get = transport.recorded[1]
        let postAuth = try decodeAuthorization(post), getAuth = try decodeAuthorization(get)
        XCTAssertEqual(post.httpBody, body)
        XCTAssertEqual(postAuth.tags, [["u", post.url!.absoluteString], ["method", "POST"], ["payload", SHA256Hex.of(body)]])
        XCTAssertEqual(post.value(forHTTPHeaderField: "x-flightdeck-pg-app-npub"), Fixtures.appNpub)
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(getAuth.tags, [["u", "https://tower.example/api/v4/flightdeck-pg/workspaces?cursor=abc_-"], ["method", "GET"]])
        XCTAssertNil(get.httpBody)
        XCTAssertTrue(SignatureVerifier.verify(postAuth) && SignatureVerifier.verify(getAuth))
        XCTAssertNotEqual(postAuth.id, getAuth.id, "fresh event per request")
    }

    func testLockedIdentityCannotSign() async throws {
        let identity = try await makeIdentity(unlocked: false)
        let transport = StubTransport { _ in (200, [:]) }
        let client = TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity)
        do { _ = try await client.request(path: "/api/v4/flightdeck-pg/workspaces"); XCTFail() } catch { XCTAssertEqual(error as? IdentityError, .locked) }
        XCTAssertTrue(transport.recorded.isEmpty, "nothing sent unsigned")
    }

    func testHTTPErrorsCarryTowerCodeAndStage() async throws {
        let identity = try await makeIdentity()
        let client = TowerClient(origin: try TowerOrigin("https://tower.example"), transport: StubTransport { _ in (403, ["code": "forbidden"]) }, signer: identity)
        do { _ = try await client.request(path: "/api/v4/flightdeck-pg/workspaces"); XCTFail() }
        catch { XCTAssertEqual(error as? TowerError, .http(status: 403, code: "forbidden", stage: "workspace discovery")) }
    }

    func testListFollowsCursorsAndReportsTruncation() async throws {
        let identity = try await makeIdentity()
        let transport = StubTransport { request in
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "cursor" }?.value
            switch cursor {
            case nil: return (200, ["scopes": [Fixtures.scope(Fixtures.scopeA, name: "A")], "next_cursor": "p2"])
            default: return (200, ["scopes": [Fixtures.scope(Fixtures.scopeB, name: "B")], "next_cursor": NSNull()])
            }
        }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
        let scopes = try await api.scopes(workspaceId: Fixtures.workspaceId, appNpub: Fixtures.appNpub)
        XCTAssertEqual(scopes.map(\.name), ["A", "B"])
        XCTAssertEqual(transport.recorded.count, 2)

        let full = Fixtures.json(["scopes": (0..<200).map { Fixtures.scope(UUID().uuidString.lowercased(), name: "S\($0)") }, "next_cursor": NSNull()])
        transport.setHandler { _ in (200, full) }
        do { _ = try await api.scopes(workspaceId: Fixtures.workspaceId, appNpub: Fixtures.appNpub); XCTFail() }
        catch { XCTAssertEqual(error as? TowerError, .listLimitReached("scopes")) }

        transport.setHandler { _ in (200, ["scopes": [], "next_cursor": "same"]) }
        do { _ = try await api.scopes(workspaceId: Fixtures.workspaceId, appNpub: Fixtures.appNpub); XCTFail() }
        catch { XCTAssertEqual(error as? TowerError, .malformed("scopes cursor")) }
    }

    func testRejectsNonUUIDPathComponents() async throws {
        let identity = try await makeIdentity()
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: StubTransport { _ in (200, [:]) }, signer: identity))
        do { _ = try await api.scopes(workspaceId: "../admin", appNpub: Fixtures.appNpub); XCTFail() } catch { XCTAssertEqual(error as? TowerError, .unsafePath) }
    }
}

final class DescriptorTests: XCTestCase {
    func testParsesMatchingHTTPSDescriptor() throws {
        let origin = try TowerOrigin("https://tower.example")
        let descriptor = try NStackDescriptor.parse(Fixtures.json(Fixtures.descriptor(origin: "https://tower.example")), expectedOrigin: origin)
        XCTAssertEqual(descriptor.tower?.availability?.status, "available")
        XCTAssertEqual(descriptor.stack?.tower_npub, TestKeys.npub)
        XCTAssertFalse(descriptor.advertisesFIPS)
        XCTAssertTrue(try NStackDescriptor.parse(Fixtures.json(Fixtures.descriptor(origin: "https://tower.example", fips: true)), expectedOrigin: origin).advertisesFIPS)
    }

    func testRejectsMismatchedOrUnsupportedDescriptors() throws {
        let origin = try TowerOrigin("https://tower.example")
        XCTAssertThrowsError(try NStackDescriptor.parse(Fixtures.json(Fixtures.descriptor(origin: "https://other.example")), expectedOrigin: origin))
        XCTAssertThrowsError(try NStackDescriptor.parse(Fixtures.json(Fixtures.descriptor(origin: "http://tower.example")), expectedOrigin: origin))
        XCTAssertThrowsError(try NStackDescriptor.parse(Fixtures.json(Fixtures.descriptor(origin: "https://tower.example", protocols: ["https"])), expectedOrigin: origin))
        var wrong = Fixtures.descriptor(origin: "https://tower.example")
        wrong["schema_version"] = 2
        XCTAssertThrowsError(try NStackDescriptor.parse(Fixtures.json(wrong), expectedOrigin: origin))
        XCTAssertThrowsError(try NStackDescriptor.parse(Data("<html>".utf8), expectedOrigin: origin))
    }

    /// Opt-in live check of the public descriptor only (no identity, no authenticated call):
    /// `AMBULANDO_LIVE_ORIGIN=https://<tower> swift test --filter LiveDescriptor`
    func testLiveDescriptorWhenConfigured() async throws {
        guard let value = ProcessInfo.processInfo.environment["AMBULANDO_LIVE_ORIGIN"] else { throw XCTSkip("AMBULANDO_LIVE_ORIGIN not set") }
        let origin = try TowerOrigin(value)
        let api = TowerAPI(client: TowerClient(origin: origin, transport: URLSessionTransport(timeout: 20), signer: nil))
        let descriptor = try await api.descriptor()
        print("LIVE descriptor: tower=\(descriptor.tower?.endpoint ?? "-") status=\(descriptor.tower?.availability?.status ?? "-") protocols=\(descriptor.tower?.protocols ?? []) fips=\(descriptor.advertisesFIPS) services=\(descriptor.services.map(\.kind))")
        XCTAssertEqual(descriptor.tower?.protocols?.contains("nip-98"), true)
    }

    /// Opt-in: proves a live Tower accepts this client's NIP-98 signatures, using the *public NIP-19 test key*
    /// (a non-member). Expected result: HTTP 200 with zero workspaces. It reads no user data and is not
    /// evidence of a real user's workspace sync.
    func testLiveSignedDiscoveryWithPublicTestKeyWhenConfigured() async throws {
        guard let value = ProcessInfo.processInfo.environment["AMBULANDO_LIVE_ORIGIN"] else { throw XCTSkip("AMBULANDO_LIVE_ORIGIN not set") }
        let identity = try await makeIdentity()
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin(value), transport: URLSessionTransport(timeout: 20), signer: identity))
        let workspaces = try await api.workspaces()
        print("LIVE signed discovery (public NIP-19 test key, non-member): HTTP 200, workspaces=\(workspaces.count)")
        XCTAssertEqual(workspaces.count, 0)
    }
}
