import XCTest
@testable import AmbulandoCore

final class WorkspaceIndexTests: XCTestCase {
    struct Fixture: Decodable { let events: [NostrEvent]; let user_pubkey: String }
    func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/workspace-self-index-v1.json")
        return try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
    }
    func identity() async throws -> IdentityService {
        let service = IdentityService(vaultURL:temporaryDirectory().appendingPathComponent("vault"),secrets:MemorySecretStore())
        try await service.importIdentity(nsec:Bech32.encode(hrp:"nsec",data:Data(hex:String(repeating:"0",count:63)+"1")!),pin:TestKeys.pin)
        return service
    }
    func testRealNostrToolsFixtureCrossAppFlatNestedAndTombstones() async throws {
        let f = try fixture(), user = try await identity()
        var origins = [String]()
        for event in WorkspaceIndex.latest(Array(f.events.prefix(2)),user:f.user_pubkey) {
            let clear = try await user.decryptWorkspaceIndex(event.content)
            let decoded = try WorkspaceIndex.decode(event,user:f.user_pubkey,plaintext:clear)
            if !decoded.deleted { origins.append(decoded.locator.origin) }
        }
        XCTAssertEqual(Set(origins),["https://one.example","https://two.example"])
        var remaining = [String]()
        for event in WorkspaceIndex.latest(f.events,user:f.user_pubkey) {
            let decoded = try WorkspaceIndex.decode(event,user:f.user_pubkey,plaintext:await user.decryptWorkspaceIndex(event.content))
            if !decoded.deleted { remaining.append(decoded.locator.origin) }
        }
        XCTAssertEqual(remaining,["https://two.example"])
        let event = f.events[0]
        let tampered = NostrEvent(id:event.id,pubkey:event.pubkey,created_at:99,kind:event.kind,tags:event.tags,content:event.content,sig:event.sig)
        XCTAssertEqual(WorkspaceIndex.latest([event,tampered],user:f.user_pubkey),[event])
        _ = await user.lock()
        do { _ = try await user.decryptWorkspaceIndex(event.content); XCTFail("Locked identity decrypted relay") } catch {}
    }
}
extension WorkspaceIndexTests {
    func testFreshMembershipRejectsOneTowerWithoutHidingOthersOrChangingPersistence() async throws {
        let f = try fixture(), user = try await identity()
        let clear = try await user.decryptWorkspaceIndex(f.events[1].content)
        let loc = try WorkspaceIndex.decode(f.events[1],user:f.user_pubkey,plaintext:clear).locator
        let transport = StubTransport { request in
            if request.url?.host == "one.example" { return (403,["error":"membership removed"]) }
            return (200,["identity":["workspace_id":loc.workspaceId,"tower_service_npub":loc.tower,
                "workspace_service_npub":loc.service,"workspace_owner_npub":loc.owner,"app_npub":loc.app]])
        }
        let store = try LocalStore(directory:temporaryDirectory())
        try await store.writer.setState("selected.connection","original")
        let sync = WorkspaceSync(store:store,engine:SyncEngine(),identity:user,transport:transport)
        let origins = try await sync.verifiedTowerIndexes(events:Array(f.events.prefix(2)))
        XCTAssertEqual(origins,["https://two.example"])
        let saved = try await store.reader.state("selected.connection")
        XCTAssertEqual(saved,"original")
        let connections = try await store.reader.connections()
        XCTAssertTrue(connections.isEmpty)
        XCTAssertEqual(transport.recorded.count,2)
        for request in transport.recorded { XCTAssertNotNil(request.value(forHTTPHeaderField:"Authorization")) }
        transport.setHandler { _ in (200,["identity":["workspace_id":"wrong"]]) }
        let mismatched = try await sync.verifiedTowerIndexes(events:Array(f.events.prefix(2)))
        XCTAssertTrue(mismatched.isEmpty)
    }
}
extension WorkspaceIndexTests {
    func testNewestMalformedAddressSuppressesOlderCandidate() async throws {
        let f = try fixture(), user = try await identity(), old = f.events[0]
        for extra in [[["p",old.pubkey]], [["d","invalid-second-address"]]] {
            let newer = try await user.sign(NostrEventTemplate(kind:33356,tags:old.tags + extra,content:old.content,createdAt:3))
            let reduced = WorkspaceIndex.latest([old,newer],user:f.user_pubkey)
            XCTAssertEqual(reduced,[newer])
            let clear = try await user.decryptWorkspaceIndex(newer.content)
            XCTAssertThrowsError(try WorkspaceIndex.decode(newer,user:f.user_pubkey,plaintext:clear))
        }
    }
    func testPublisherUsesNativeNamespaceFreshMembershipAndExactReadback() async throws {
        let f = try fixture(), user = try await identity()
        let clear = try await user.decryptWorkspaceIndex(f.events[1].content)
        let loc = try WorkspaceIndex.decode(f.events[1],user:f.user_pubkey,plaintext:clear).locator
        let fields = ["workspace_id":loc.workspaceId,"tower_service_npub":loc.tower,"workspace_service_npub":loc.service,
                      "workspace_owner_npub":loc.owner,"app_npub":loc.app]
        let transport = StubTransport { _ in (200,["identity":fields]) }
        let store = try LocalStore(directory:temporaryDirectory())
        let sync = WorkspaceSync(store:store,engine:SyncEngine(),identity:user,transport:transport)
        let connection = ConnectionRecord(origin:try TowerOrigin(loc.origin),signerNpub:NostrKeys.npub(publicKeyHex:f.user_pubkey)!,towerNpub:loc.tower)
        let workspace = try WorkspaceRecord(raw:JSONSerialization.data(withJSONObject:["identity":fields,"label":"Two"]))
        let event = try await sync.workspaceIndexEvent(connection:connection,workspace:workspace)
        XCTAssertEqual(event.tags.first{$0.first == "app_pub"}?.last,WorkspaceIndex.appPubkey)
        XCTAssertNotEqual(WorkspaceIndex.appNpub,workspace.appNpub)
        let decoded = try WorkspaceIndex.decode(event,user:event.pubkey,plaintext:await user.decryptWorkspaceIndex(event.content))
        XCTAssertEqual(decoded.locator,loc)
        XCTAssertNoThrow(try WorkspaceIndex.verifyPublication(event,acknowledged:true,readback:[event]))
        XCTAssertThrowsError(try WorkspaceIndex.verifyPublication(event,acknowledged:false,readback:[event]))
        XCTAssertThrowsError(try WorkspaceIndex.verifyPublication(event,acknowledged:true,readback:[]))
        let forged = NostrEvent(id:event.id,pubkey:event.pubkey,created_at:event.created_at,kind:event.kind,tags:event.tags,content:"tampered",sig:event.sig)
        XCTAssertThrowsError(try WorkspaceIndex.verifyPublication(event,acknowledged:true,readback:[forged]))
        transport.setHandler { _ in (403,["error":"revoked"]) }
        do { _ = try await sync.workspaceIndexEvent(connection:connection,workspace:workspace); XCTFail("Published without fresh access") } catch {}
    }
}
extension WorkspaceIndexTests {
    func testSelectedTowerListsAllPagesIncludingUnindexedWorkspacesAndRejectsPartial() async throws {
        let f = try fixture(), user = try await identity()
        let loc = try WorkspaceIndex.decode(f.events[1],user:f.user_pubkey,plaintext:await user.decryptWorkspaceIndex(f.events[1].content)).locator
        let transport = StubTransport { request in
            let second = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.contains { $0.name == "cursor" && $0.value == "page two" } == true
            let wid = second ? "33333333-3333-4333-8333-333333333333" : loc.workspaceId
            let row: [String:Any] = ["identity":["workspace_id":wid,"app_npub":loc.app],"label":second ? "Unindexed" : "Indexed"]
            if second { return (200,["workspaces":[row],"has_more":false]) }
            return (200,["workspaces":[row],"next_cursor":"page two","has_more":true])
        }
        let api = TowerAPI(client:TowerClient(origin:try TowerOrigin("https://selected.example"),transport:transport,signer:user))
        let listed = try await api.workspaces()
        XCTAssertEqual(listed.map(\.label),["Indexed","Unindexed"])
        XCTAssertEqual(transport.recorded.count,2)
        XCTAssertTrue(transport.recorded.allSatisfy { $0.url?.host == "selected.example" })
        transport.setHandler { _ in (200,["workspaces":[],"partial":true]) }
        do { _ = try await api.workspaces(); XCTFail("Accepted partial workspace list") } catch {}
        transport.setHandler { _ in (200,["workspaces":[],"next_cursor":"loop"]) }
        do { _ = try await api.workspaces(); XCTFail("Accepted looping cursor") } catch {}
    }
}
