import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AmbulandoCore

// Public Nostr profiles: parsing, name/avatar precedence, verification of relay events, the cache's freshness and
// isolation rules, the refresh job and avatar downloads. Synthetic keys and data only; no network.

/// A signing identity for a synthetic person (the scalar is `byte` repeated, a valid secp256k1 key for small bytes).
private func person(_ byte: UInt8) async throws -> (signer: IdentityService, pubkey: String, npub: String) {
    let service = IdentityService(vaultURL: temporaryDirectory("person\(byte)").appendingPathComponent("vault.json"), secrets: MemorySecretStore())
    try await service.importIdentity(nsec: Bech32.encode(hrp: "nsec", data: Data(repeating: byte, count: 32)), pin: TestKeys.pin)
    let hex = try await service.publicKeyHex()
    return (service, hex, NostrKeys.npub(publicKeyHex: hex)!)
}

private func profileEvent(_ signer: IdentityService, _ content: [String: Any], at createdAt: Int, kind: Int = 0) async throws -> NostrEvent {
    let text = String(decoding: try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]), as: UTF8.self)
    return try await signer.sign(NostrEventTemplate(kind: kind, tags: [], content: text, createdAt: createdAt))
}

private func samplePNG(width: Int = 64, height: Int = 64) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.17, green: 0.11, blue: 0.24, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

private func pixelSize(_ data: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

/// Answers avatar requests from a table, counting calls and the most requests in flight at once.
private final class StubAvatarTransport: AvatarTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [URL: (Data, Int, String?)] = [:]
    private(set) var calls: [URL] = []
    private var active = 0
    private(set) var peak = 0
    var delay: Duration = .zero
    var offline = false

    func answer(_ url: URL, _ data: Data, status: Int = 200, type: String? = "image/png") { lock.withLock { answers[url] = (data, status, type) } }

    func fetch(_ url: URL, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let answer: (Data, Int, String?)? = lock.withLock {
            calls.append(url); active += 1; peak = max(peak, active)
            return answers[url]
        }
        defer { lock.withLock { active -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        if lock.withLock({ offline }) { throw URLError(.notConnectedToInternet) }
        guard let (data, status, type) = answer else { throw URLError(.badServerResponse) }
        if data.count > maxBytes { throw AvatarError.tooLarge }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: type.map { ["Content-Type": $0] })!
        if status != 200 { throw AvatarError.httpStatus(status) }
        return (data, response)
    }
}

/// Profile source answering from a table; records each batch and can go offline.
private final class StubProfileSource: ProfileSource, @unchecked Sendable {
    private let lock = NSLock()
    var records: [String: ProfileRecord] = [:]
    private(set) var batches: [[String]] = []
    var offline = false
    var delay: Duration = .zero
    /// Runs while a batch is "on the wire" (after it was asked for, before the answer returns).
    var during: (@Sendable () async -> Void)?

    func profiles(pubkeys: [String]) async throws -> [ProfileRecord] {
        lock.withLock { batches.append(pubkeys) }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let during { await during() }
        return try lock.withLock {
            if offline { throw URLError(.notConnectedToInternet) }
            return pubkeys.compactMap { records[$0] }
        }
    }
    var asked: [String] { lock.withLock { batches.flatMap { $0 } } }
}

final class ProfileContentTests: XCTestCase {
    func testDisplayNameBeforeNameAndUsernameFallback() {
        let both = NostrProfileContent.parse(#"{"display_name":"  Ana Lima ","name":"ana"}"#)
        XCTAssertEqual(both.displayName, "Ana Lima")
        XCTAssertEqual(both.name, "ana")
        XCTAssertEqual(ProfileRecord(pubkey: "", npub: "", displayName: both.displayName, name: both.name, status: .found, checkedAt: Date()).preferredName, "Ana Lima")
        let camel = NostrProfileContent.parse(#"{"displayName":"Bea","username":"bea_k"}"#)
        XCTAssertEqual(camel.displayName, "Bea")
        XCTAssertEqual(camel.name, "bea_k")
        let nameOnly = ProfileRecord(pubkey: "", npub: "", name: "cal", status: .found, checkedAt: Date())
        XCTAssertEqual(nameOnly.preferredName, "cal")
    }

    func testBrokenAndHostileContentIsDropped() {
        XCTAssertEqual(NostrProfileContent.parse("not json"), .init())
        XCTAssertEqual(NostrProfileContent.parse(#"["array"]"#), .init())
        XCTAssertEqual(NostrProfileContent.parse(#"{"name":42,"display_name":"   ","picture":7}"#), .init())
        let lines = NostrProfileContent.parse(#"{"name":"Ana\nLima\u0007"}"#)
        XCTAssertEqual(lines.name, "Ana Lima")
        let long = NostrProfileContent.parse("{\"name\":\"\(String(repeating: "x", count: 500))\"}")
        XCTAssertEqual(long.name?.count, 120)
        let huge = "{\"name\":\"a\",\"about\":\"\(String(repeating: "y", count: NostrProfileContent.maxContentBytes))\"}"
        XCTAssertNil(NostrProfileContent.parse(huge).name)
    }

    func testPictureKeysAndURLPolicy() {
        XCTAssertEqual(NostrProfileContent.parse(#"{"image":"https://img.example.com/a.png"}"#).picture?.absoluteString, "https://img.example.com/a.png")
        XCTAssertEqual(NostrProfileContent.parse(#"{"picture":"http://img.example.com/a.png","image":"https://cdn.example.com/b.png"}"#).picture?.host, "cdn.example.com")
        for refused in ["http://img.example.com/a.png", "https://user:pw@img.example.com/a.png", "https://192.168.1.10/a.png", "https://[::1]/a.png",
                        "https://localhost/a.png", "https://printer.local/a.png", "https://nas.home.arpa/a.png", "https://10.1/a.png",
                        "https://2130706433/a.png", "https://0x7f.0x1/a.png", "file:///etc/passwd", "data:image/png;base64,AAAA", "javascript:alert(1)",
                        "https://" + String(repeating: "a", count: 2100) + ".com/a.png"] {
            XCTAssertNil(AvatarURLPolicy.validate(refused), refused)
        }
        XCTAssertNotNil(AvatarURLPolicy.validate("https://nostr.build/i/abc.jpg"))
        XCTAssertNotNil(AvatarURLPolicy.validate("https://avatars.sample.invalid/ana.png"))
    }

    func testInitialsFollowTheWebHelper() {
        XCTAssertEqual(PersonInitials.of("Ana Lima"), "AL")
        XCTAssertEqual(PersonInitials.of("rick"), "RI")
        XCTAssertEqual(PersonInitials.of("  "), "?")
        XCTAssertEqual(PersonInitials.of("You (sample identity)"), "YS")
        XCTAssertEqual(PersonInitials.of("(()) !!"), "((")
        XCTAssertEqual(PersonInitials.of("npub1abc…wxyz"), "NP")
        XCTAssertEqual(PersonInitials.of("élodie Ø"), "ÉØ")
    }
}

final class PeopleDirectoryTests: XCTestCase {
    let w = Fixtures.workspaceId
    let ana = NostrKeys.npub(publicKeyHex: String(repeating: "a1", count: 32))!
    let rick = NostrKeys.npub(publicKeyHex: String(repeating: "b2", count: 32))!
    let bea = NostrKeys.npub(publicKeyHex: String(repeating: "c3", count: 32))!
    let stranger = NostrKeys.npub(publicKeyHex: String(repeating: "d4", count: 32))!
    let cal = NostrKeys.npub(publicKeyHex: String(repeating: "e5", count: 32))!

    private func profile(_ npub: String, display: String? = nil, name: String? = nil, picture: String? = nil, at: Int = 1) -> ProfileRecord {
        ProfileRecord(pubkey: NostrKeys.publicKeyHex(npub: npub)!, npub: npub, displayName: display, name: name, picture: picture,
                      eventId: String(repeating: "0", count: 64), eventCreatedAt: at, status: .found, checkedAt: Date())
    }

    /// sol `getSenderName` order: public profile, then Tower's member or agent name, then the message label, then the
    /// short npub. Build 10 put Tower first, so members Tower had no name for showed as npubs in the mention picker.
    func testProfileThenWorkspaceThenAgentThenMessageLabelThenNpub() {
        let members = [MemberRecord(workspaceId: w, actorId: "a", npub: ana, kind: "human", displayName: "Ana (Studio)"),
                       MemberRecord(workspaceId: w, actorId: "b", npub: bea, kind: "human", displayName: nil),
                       MemberRecord(workspaceId: w, actorId: "c", npub: cal, kind: "human", displayName: "Cal Tower")]
        let directory = PeopleDirectory(members: members, agents: [rick: .init(name: "Rick", avatarURL: "https://agents.example.com/rick.png")],
                                        profiles: [profile(ana, display: "Ana Nostr", picture: "https://img.example.com/ana.png"),
                                                   profile(rick, display: "Rick Nostr", picture: "https://img.example.com/rick-public.png"),
                                                   profile(bea, display: nil, name: "bea")])
        XCTAssertEqual(directory.person(ana).name, "Ana Nostr")
        XCTAssertEqual(directory.person(ana).nameSource, .nostr)
        XCTAssertEqual(directory.person(ana).avatarURL?.absoluteString, "https://img.example.com/ana.png")
        XCTAssertEqual(directory.person(ana, senderLabel: "Old label").name, "Ana Nostr", "a message label never hides the public name")
        XCTAssertEqual(directory.person(rick).name, "Rick Nostr")
        XCTAssertEqual(directory.person(rick).avatarURL?.absoluteString, "https://agents.example.com/rick.png", "Tower agent avatar before the profile")
        XCTAssertEqual(directory.person(bea).name, "bea", "Tower has no name: the public profile names the member")
        XCTAssertEqual(directory.person(bea).nameSource, .nostr)
        XCTAssertEqual(directory.names[bea], "bea", "name maps (pickers, tasks, docs) see the profile name too")
        XCTAssertEqual(directory.person(cal).name, "Cal Tower")
        XCTAssertEqual(directory.person(cal).nameSource, .workspace)
        XCTAssertEqual(directory.person(stranger, senderLabel: "Stranger K").name, "Stranger K")
        XCTAssertEqual(directory.person(stranger).name, shortLabel(stranger))
        XCTAssertEqual(directory.person(stranger).initials, "NP")
        XCTAssertNil(directory.person(stranger).avatarURL)
        XCTAssertEqual(directory.person(nil, senderLabel: "System").name, "System")
    }

    /// Tower setup placeholders and names that are only a key never count as a name.
    func testPlaceholderAndKeyNamesAreSkipped() {
        let members = [MemberRecord(workspaceId: w, actorId: "a", npub: ana, kind: "human", displayName: "Workspace Creator"),
                       MemberRecord(workspaceId: w, actorId: "b", npub: bea, kind: "human", displayName: shortLabel(bea)),
                       MemberRecord(workspaceId: w, actorId: "c", npub: cal, kind: "human", displayName: cal)]
        let directory = PeopleDirectory(members: members, agents: [:], profiles: [profile(bea, display: "Bea")])
        XCTAssertEqual(directory.person(ana).name, shortLabel(ana))
        XCTAssertEqual(directory.person(ana).nameSource, .npub)
        XCTAssertEqual(directory.person(bea).name, "Bea")
        XCTAssertEqual(directory.person(cal).name, shortLabel(cal))
        XCTAssertEqual(directory.person(cal, senderLabel: String(repeating: "ab", count: 32)).name, shortLabel(cal))
        XCTAssertEqual(directory.person(cal, senderLabel: "Cal").name, "Cal")
        XCTAssertNil(PersonNamePolicy.usable("Flight Deck PG Creator"))
        XCTAssertNil(PersonNamePolicy.usable("npub1abcd…wxyz"))
        XCTAssertEqual(PersonNamePolicy.usable("npub fan club"), "npub fan club")
    }

    func testProfilesNeverAddMembersAndBrokenPicturesFallBack() {
        let directory = PeopleDirectory(members: [MemberRecord(workspaceId: w, actorId: "a", npub: ana, kind: "human", displayName: "Ana")],
                                        agents: [:], profiles: [profile(stranger, display: "Mallory", picture: "http://insecure.example.com/x.png"),
                                                                profile(ana, picture: "https://10.0.0.1/a.png")])
        XCTAssertEqual(directory.memberNpubs, [ana])
        XCTAssertEqual(directory.person(stranger).name, "Mallory")
        XCTAssertNil(directory.person(stranger).avatarURL)
        XCTAssertNil(directory.person(ana).avatarURL)
    }
}

final class ProfileEventTests: XCTestCase {
    func testOnlyVerifiedKindZeroEventsOfRequestedKeysAreAccepted() async throws {
        let ana = try await person(0x21), bea = try await person(0x22)
        let good = try await profileEvent(ana.signer, ["display_name": "Ana", "picture": "https://img.example.com/a.png"], at: 1_800_000_100)
        let older = try await profileEvent(ana.signer, ["display_name": "Ana (old)"], at: 1_800_000_050)
        let other = try await profileEvent(bea.signer, ["name": "Bea"], at: 1_800_000_100)
        let note = try await profileEvent(ana.signer, ["name": "Not a profile"], at: 1_800_000_200, kind: 1)
        let tampered = NostrEvent(id: good.id, pubkey: good.pubkey, created_at: good.created_at, kind: 0, tags: [],
                                  content: #"{"display_name":"Mallory"}"#, sig: good.sig)
        let forged = NostrEvent(id: other.id, pubkey: ana.pubkey, created_at: other.created_at, kind: 0, tags: [], content: other.content, sig: other.sig)
        let badSig = NostrEvent(id: good.id, pubkey: good.pubkey, created_at: good.created_at, kind: 0, tags: [], content: good.content,
                                sig: String(repeating: "0", count: 128))
        let accepted = ProfileEventFilter.accept([older, tampered, forged, badSig, note, good, other], requested: [ana.pubkey], checkedAt: Date(timeIntervalSince1970: 1_800_001_000))
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(accepted.first?.displayName, "Ana")
        XCTAssertEqual(accepted.first?.eventCreatedAt, 1_800_000_100)
        XCTAssertEqual(accepted.first?.npub, ana.npub)
        XCTAssertEqual(accepted.first?.picture, "https://img.example.com/a.png")
    }

    func testFutureAndPreNostrDatesAreRefused() async throws {
        let ana = try await person(0x24)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let future = try await profileEvent(ana.signer, ["name": "Pinned forever"], at: 1_900_000_000 + 3600)
        let ancient = try await profileEvent(ana.signer, ["name": "1970"], at: 1000)
        let skewed = try await profileEvent(ana.signer, ["name": "Slightly ahead"], at: 1_900_000_000 + 600)
        let accepted = ProfileEventFilter.accept([future, ancient, skewed], requested: [ana.pubkey], checkedAt: now)
        XCTAssertEqual(accepted.map(\.name), ["Slightly ahead"])
    }

    func testRelayFramesAreParsedStrictly() async throws {
        let ana = try await person(0x23)
        let event = try await profileEvent(ana.signer, ["name": "Ana"], at: 10)
        let frame = String(decoding: try JSONSerialization.data(withJSONObject: ["EVENT", "p1", event.jsonObject]), as: UTF8.self)
        guard case .event(let parsed)? = RelayFrame(frame)?.kind else { return XCTFail("EVENT not parsed") }
        XCTAssertEqual(parsed, event)
        XCTAssertNotNil(RelayFrame(#"["EOSE","p1"]"#))
        XCTAssertNotNil(RelayFrame(#"["CLOSED","p1","error: rate-limited"]"#))
        XCTAssertNil(RelayFrame(#"["NOTICE","hello"]"#))
        XCTAssertNil(RelayFrame(#"["EVENT","p1",{"id":1}]"#))
        XCTAssertNil(RelayFrame("garbage"))
    }

    func testRelayListIsTheWebClientsPublicList() {
        XCTAssertEqual(RelayProfileSource.relays.map(\.absoluteString), ["wss://relay.primal.net", "wss://nos.lol", "wss://purplepag.es"])
        XCTAssertTrue(RelayProfileSource(relays: [URL(string: "ws://plain.example.com")!, URL(string: "https://x.example.com")!]).relays.isEmpty)
    }
}

final class ProfileStoreTests: XCTestCase {
    let w = Fixtures.workspaceId
    let ana = NostrKeys.npub(publicKeyHex: String(repeating: "a1", count: 32))!
    let bea = NostrKeys.npub(publicKeyHex: String(repeating: "c3", count: 32))!
    var anaHex: String { NostrKeys.publicKeyHex(npub: ana)! }
    var beaHex: String { NostrKeys.publicKeyHex(npub: bea)! }

    private func record(_ npub: String, _ name: String, at: Int, id: String = String(repeating: "1", count: 64), picture: String? = nil) -> ProfileRecord {
        ProfileRecord(pubkey: NostrKeys.publicKeyHex(npub: npub)!, npub: npub, displayName: name, picture: picture, eventId: id, eventCreatedAt: at,
                      status: .found, checkedAt: Date())
    }

    private func connectedStore() async throws -> (LocalStore, ConnectionRecord) {
        let store = try LocalStore(directory: temporaryDirectory(), coalesceInterval: .milliseconds(5))
        let connection = try await store.writer.saveConnection(ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil))
        try await store.writer.replaceWorkspaces(connectionId: connection.id, [try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(w, label: "Studio")))])
        try await store.writer.replaceMembers(workspaceId: w, [MemberRecord(workspaceId: w, actorId: "a", npub: ana, kind: "human", displayName: nil),
                                                              MemberRecord(workspaceId: w, actorId: "b", npub: bea, kind: "human", displayName: "Bea")])
        return (store, connection)
    }

    func testNewestProfileWinsAndMissingNeverClobbersAFoundProfile() async throws {
        let (store, c) = try await connectedStore()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.writer.recordProfileCheck(connectionId: c.id, found: [record(ana, "Ana v2", at: 200, picture: "https://img.example.com/2.png")],
                                                  checked: [anaHex: ana, beaHex: bea], at: t0)
        var rows = Dictionary(try await store.reader.profiles(connectionId: c.id).map { ($0.npub, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(rows[ana]?.displayName, "Ana v2")
        XCTAssertEqual(rows[bea]?.status, .missing)
        // An older event (relay lag) does not replace a newer one, but the check time moves on.
        let t1 = t0.addingTimeInterval(60)
        try await store.writer.recordProfileCheck(connectionId: c.id, found: [record(ana, "Ana v1", at: 100)], checked: [anaHex: ana], at: t1)
        // A round where the relays return nothing for Ana keeps her profile.
        let t2 = t1.addingTimeInterval(60)
        try await store.writer.recordProfileCheck(connectionId: c.id, found: [], checked: [anaHex: ana], at: t2)
        rows = Dictionary(try await store.reader.profiles(connectionId: c.id).map { ($0.npub, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(rows[ana]?.displayName, "Ana v2")
        XCTAssertEqual(rows[ana]?.status, .found)
        XCTAssertEqual(rows[ana]?.checkedAt, t2)
        // A changed picture (newer event) replaces the URL.
        try await store.writer.recordProfileCheck(connectionId: c.id, found: [record(ana, "Ana v3", at: 300, picture: "https://img.example.com/3.png")],
                                                  checked: [anaHex: ana], at: t2.addingTimeInterval(1))
        let people = try await store.reader.people(connectionId: c.id, workspaceId: w)
        XCTAssertEqual(people.person(ana).name, "Ana v3")
        XCTAssertEqual(people.person(ana).avatarURL?.absoluteString, "https://img.example.com/3.png")
        XCTAssertEqual(people.person(bea).name, "Bea", "Tower's name is unaffected by a missing profile")
        // Same created_at: the lower event id wins (NIP-01).
        try await store.writer.recordProfileCheck(connectionId: c.id, found: [record(ana, "Ana tie-high", at: 300, id: String(repeating: "f", count: 64))],
                                                  checked: [anaHex: ana], at: t2.addingTimeInterval(2))
        let tie = try await store.reader.people(connectionId: c.id, workspaceId: w).person(ana).name
        XCTAssertEqual(tie, "Ana v3")
    }

    func testProfilesFollowTheConnectionAndForgetPeopleOfRemovedWorkspaces() async throws {
        let (store, c) = try await connectedStore()
        let outsider = NostrKeys.npub(publicKeyHex: String(repeating: "e5", count: 32))!
        try await store.writer.recordProfileCheck(connectionId: c.id, found: [record(ana, "Ana", at: 1), record(outsider, "Outsider", at: 1)],
                                                  checked: [anaHex: ana, NostrKeys.publicKeyHex(npub: outsider)!: outsider], at: Date())
        try await store.writer.pruneProfiles(connectionId: c.id)
        let kept = try await store.reader.profiles(connectionId: c.id).map(\.npub)
        XCTAssertEqual(Set(kept), [ana], "a profile nobody in the workspaces refers to is pruned")
        // Another connection never sees this connection's profiles.
        let other = try await store.writer.saveConnection(ConnectionRecord(origin: try TowerOrigin("https://other.example"), signerNpub: TestKeys.npub, towerNpub: nil))
        let foreign = try await store.reader.people(connectionId: other.id, workspaceId: w)
        XCTAssertEqual(foreign.person(ana).nameSource, .npub)
        // Removing the workspace forgets its people; disconnecting removes everything.
        try await store.writer.replaceWorkspaces(connectionId: c.id, [])
        let afterRemoval = try await store.reader.profiles(connectionId: c.id).map(\.npub)
        XCTAssertEqual(afterRemoval, [])
        try await store.writer.recordProfileCheck(connectionId: c.id, found: [record(NostrKeys.npub(publicKeyHex: TestKeys.pubkeyHex)!, "Me", at: 1)],
                                                  checked: [TestKeys.pubkeyHex: TestKeys.npub], at: Date())
        try await store.writer.removeConnection(id: c.id)
        let afterDisconnect = try await store.reader.profiles(connectionId: c.id)
        XCTAssertEqual(afterDisconnect, [])
    }

    func testCandidatesAreTheSignerMembersAgentsAndRecentSendersBounded() async throws {
        let (store, c) = try await connectedStore()
        let sender = NostrKeys.npub(publicKeyHex: String(repeating: "f6", count: 32))!
        try await store.writer.upsertMessages([MessageRecord(workspaceId: w, id: "m1", channelId: Fixtures.channel1, threadId: nil, body: "hi",
                                                             senderNpub: sender, createdAt: "2026-10-24T00:00:00Z", updatedAt: "2026-10-24T00:00:00Z",
                                                             rowVersion: 1, raw: Data("{}".utf8)),
                                               MessageRecord(workspaceId: w, id: "m2", channelId: Fixtures.channel1, threadId: nil, body: "bad",
                                                             senderNpub: "npub1notvalid", createdAt: "2026-10-24T00:00:01Z",
                                                             updatedAt: "2026-10-24T00:00:01Z", rowVersion: 1, raw: Data("{}".utf8))])
        let candidates = try await store.reader.profileCandidates(connectionId: c.id, workspaceId: w)
        XCTAssertEqual(Set(candidates), [TestKeys.npub, ana, bea, sender])
        XCTAssertEqual(candidates.first, TestKeys.npub)
        let bounded = try await store.reader.profileCandidates(connectionId: c.id, workspaceId: w, limit: 2)
        XCTAssertEqual(bounded.count, 2)
    }

    func testSchemaFourStoreUpgradesToFiveKeepingData() async throws {
        let directory = temporaryDirectory()
        do {
            let store = try LocalStore(directory: directory)
            let c = try await store.writer.saveConnection(ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil))
            try await store.writer.replaceWorkspaces(connectionId: c.id, [try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(w, label: "Studio")))])
            try await store.writer.replaceMembers(workspaceId: w, [MemberRecord(workspaceId: w, actorId: "a", npub: ana, kind: "human", displayName: "Ana")])
            try await store.writer.setState("selected.connection", c.id)
        }
        // Turn the fresh database back into a build-9 (schema 4) file: no profiles table, no sender index.
        do {
            let db = try SQLiteConnection(path: directory.appendingPathComponent(ProductionStorage.databaseFileName).path, readOnly: false)
            try db.execute("DROP TABLE profiles; DROP INDEX messages_sender; PRAGMA user_version = 4;")
        }
        let store = try LocalStore(directory: directory)
        let version = try await store.writer.schemaVersion()
        XCTAssertEqual(version, 5)
        let connections = try await store.reader.connections()
        XCTAssertEqual(connections.map(\.signerNpub), [TestKeys.npub])
        let members = try await store.reader.members(workspaceId: w).map(\.label)
        XCTAssertEqual(members, ["Ana"])
        let profiles = try await store.reader.profiles(connectionId: connections[0].id)
        XCTAssertEqual(profiles, [])
        let people = try await store.reader.people(connectionId: connections[0].id, workspaceId: w)
        XCTAssertEqual(people.person(ana).name, "Ana", "an upgraded install shows Tower names before any profile is fetched")
    }
}

final class ProfileSyncTests: XCTestCase {
    let w = Fixtures.workspaceId

    private func setUp(members count: Int) async throws -> (LocalStore, ConnectionRecord, ProfileSync, StubProfileSource, [String]) {
        let store = try LocalStore(directory: temporaryDirectory(), coalesceInterval: .milliseconds(5))
        let c = try await store.writer.saveConnection(ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil))
        try await store.writer.replaceWorkspaces(connectionId: c.id, [try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(w, label: "Studio")))])
        let npubs = (0..<count).map { i in NostrKeys.npub(publicKeyHex: String(format: "%064x", i + 1))! }
        try await store.writer.replaceMembers(workspaceId: w, npubs.enumerated().map { MemberRecord(workspaceId: w, actorId: "a\($0.offset)", npub: $0.element, kind: "human", displayName: nil) })
        let source = StubProfileSource()
        let clock = MutableClock()
        let sync = ProfileSync(store: store, engine: SyncEngine(), source: source, now: { clock.now })
        return (store, c, sync, source, npubs)
    }

    func testOnlyDueKeysAreAskedInBoundedBatches() async throws {
        let (store, c, sync, source, npubs) = try await setUp(members: 120)
        let first = NostrKeys.publicKeyHex(npub: npubs[0])!
        source.records[first] = ProfileRecord(pubkey: first, npub: npubs[0], displayName: "First", eventId: String(repeating: "1", count: 64),
                                              eventCreatedAt: 5, status: .found, checkedAt: Date())
        try await sync.run(connectionId: c.id, workspaceId: w, force: false)
        XCTAssertTrue(source.batches.allSatisfy { $0.count <= ProfileSync.batchSize })
        XCTAssertEqual(Set(source.asked).count, 121, "120 members and the signer")
        let named = try await store.reader.people(connectionId: c.id, workspaceId: w).person(npubs[0]).name
        XCTAssertEqual(named, "First")
        // Within the freshness windows nothing is asked again; a forced refresh asks everyone.
        let before = source.asked.count
        try await sync.run(connectionId: c.id, workspaceId: w, force: false)
        XCTAssertEqual(source.asked.count, before)
        try await sync.run(connectionId: c.id, workspaceId: w, force: true)
        XCTAssertEqual(source.asked.count, before + 121)
    }

    func testFreshnessWindows() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let found = ProfileRecord(pubkey: "", npub: "", status: .found, checkedAt: now.addingTimeInterval(-ProfileSync.foundTTL + 10))
        let staleFound = ProfileRecord(pubkey: "", npub: "", status: .found, checkedAt: now.addingTimeInterval(-ProfileSync.foundTTL - 1))
        let missing = ProfileRecord(pubkey: "", npub: "", status: .missing, checkedAt: now.addingTimeInterval(-ProfileSync.missingTTL + 10))
        let staleMissing = ProfileRecord(pubkey: "", npub: "", status: .missing, checkedAt: now.addingTimeInterval(-ProfileSync.missingTTL - 1))
        let future = ProfileRecord(pubkey: "", npub: "", status: .found, checkedAt: now.addingTimeInterval(3600))
        XCTAssertFalse(ProfileSync.isDue(found, now: now, force: false))
        XCTAssertTrue(ProfileSync.isDue(staleFound, now: now, force: false))
        XCTAssertFalse(ProfileSync.isDue(missing, now: now, force: false))
        XCTAssertTrue(ProfileSync.isDue(staleMissing, now: now, force: false))
        XCTAssertTrue(ProfileSync.isDue(future, now: now, force: false), "a clock that moved back does not freeze the cache")
        XCTAssertTrue(ProfileSync.isDue(found, now: now, force: true))
        XCTAssertTrue(ProfileSync.isDue(nil, now: now, force: false))
    }

    func testOfflineRoundLeavesTheCacheAndIsRetried() async throws {
        let (store, c, sync, source, npubs) = try await setUp(members: 3)
        source.offline = true
        do { try await sync.run(connectionId: c.id, workspaceId: w, force: false); XCTFail("expected the offline error") } catch {}
        let rows = try await store.reader.profiles(connectionId: c.id)
        XCTAssertEqual(rows, [], "an unreachable source is not recorded as 'no profile'")
        source.offline = false
        try await sync.run(connectionId: c.id, workspaceId: w, force: false)
        let after = try await store.reader.profiles(connectionId: c.id)
        XCTAssertEqual(Set(after.map(\.npub)), Set(npubs + [TestKeys.npub]))
        XCTAssertTrue(after.allSatisfy { $0.status == .missing })
    }

    /// Manager review: switching workspace A → B → A while A's refresh runs must still refresh B's people (the job is
    /// per workspace, so B's request is never coalesced away by A's).
    func testWorkspaceSwitchDuringARefreshStillRefreshesTheOtherWorkspace() async throws {
        let (store, c, _, source, npubsA) = try await setUp(members: 2)
        let w2 = Fixtures.workspaceId2
        try await store.writer.replaceWorkspaces(connectionId: c.id, [try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(w, label: "Studio"))),
                                                                     try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(w2, label: "Lab")))])
        let bea = NostrKeys.npub(publicKeyHex: String(repeating: "c3", count: 32))!
        try await store.writer.replaceMembers(workspaceId: w2, [MemberRecord(workspaceId: w2, actorId: "b", npub: bea, kind: "human", displayName: nil)])
        source.delay = .milliseconds(200)
        let engine = SyncEngine()
        let sync = ProfileSync(store: store, engine: engine, source: source)
        await sync.refresh(connection: c, workspaceId: w)
        try await Task.sleep(for: .milliseconds(50))         // A is running
        await sync.refresh(connection: c, workspaceId: w2)   // switch to B
        await sync.refresh(connection: c, workspaceId: w)    // and back to A
        await engine.waitUntilIdle()
        let asked = Set(source.asked)
        XCTAssertTrue(asked.contains(NostrKeys.publicKeyHex(npub: bea)!), "B's people were refreshed")
        XCTAssertTrue(asked.isSuperset(of: npubsA.compactMap { NostrKeys.publicKeyHex(npub: $0) }))
    }

    /// Manager review: turning profiles off while a relay round is in flight stores nothing from that round; cached
    /// rows stay readable.
    func testTurningOffDuringARoundStoresNothingFromIt() async throws {
        let (store, c, sync, source, npubs) = try await setUp(members: 2)
        let first = NostrKeys.publicKeyHex(npub: npubs[0])!
        source.records[first] = ProfileRecord(pubkey: first, npub: npubs[0], displayName: "Kept", eventId: String(repeating: "1", count: 64),
                                              eventCreatedAt: 1_800_000_000, status: .found, checkedAt: Date())
        try await sync.run(connectionId: c.id, workspaceId: w, force: false)
        source.records[first] = ProfileRecord(pubkey: first, npub: npubs[0], displayName: "Late", eventId: String(repeating: "2", count: 64),
                                              eventCreatedAt: 1_800_000_500, status: .found, checkedAt: Date())
        source.during = { try? await store.writer.setState(ProfileSync.preferenceKey, "off") }
        try await sync.run(connectionId: c.id, workspaceId: w, force: true)
        let name = try await store.reader.people(connectionId: c.id, workspaceId: w).person(npubs[0]).name
        XCTAssertEqual(name, "Kept", "the round answered after opting out was not stored; the cached name stays")
        // The guard is in the writer's transaction too, for a round that passed the job's own check.
        try await store.writer.recordProfileCheck(connectionId: c.id, found: [source.records[first]!], checked: [first: npubs[0]], at: Date(),
                                                  unlessOff: ProfileSync.preferenceKey)
        let still = try await store.reader.people(connectionId: c.id, workspaceId: w).person(npubs[0]).name
        XCTAssertEqual(still, "Kept")
    }

    func testTurningProfilesOffStopsRequests() async throws {
        let (store, c, sync, source, _) = try await setUp(members: 3)
        try await store.writer.setState(ProfileSync.preferenceKey, "off")
        try await sync.run(connectionId: c.id, workspaceId: w, force: true)
        XCTAssertEqual(source.batches.count, 0)
        let enabled = await ProfileSync.isEnabled(store)
        XCTAssertFalse(enabled)
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_900_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

final class AvatarStoreTests: XCTestCase {
    let url = URL(string: "https://img.example.com/ana.png")!

    func testDownloadIsShrunkReencodedAndCachedByURL() async throws {
        let transport = StubAvatarTransport()
        transport.answer(url, samplePNG(width: 800, height: 600))
        let store = AvatarStore(directory: temporaryDirectory(), transport: transport)
        let file = await store.thumbnail(for: url)
        let data = try Data(contentsOf: try XCTUnwrapValue(file))
        let size = try XCTUnwrapValue(pixelSize(data))
        XCTAssertEqual(max(size.0, size.1), AvatarStore.thumbnailPixels)
        XCTAssertEqual(store.cachedFile(for: url), file)
        _ = await store.thumbnail(for: url)
        XCTAssertEqual(transport.calls.count, 1, "a cached avatar is not downloaded again")
        // A changed picture URL is a different cache entry.
        let changed = URL(string: "https://img.example.com/ana-2.png")!
        transport.answer(changed, samplePNG(width: 32, height: 32))
        XCTAssertNil(store.cachedFile(for: changed))
        let second = await store.thumbnail(for: changed)
        XCTAssertNotEqual(second, file)
        let small = try XCTUnwrapValue(pixelSize(try Data(contentsOf: try XCTUnwrapValue(second))))
        XCTAssertEqual(small.0, 32, "small images are not enlarged")
    }

    func testConcurrentRequestsShareOneDownloadAndConcurrencyIsBounded() async throws {
        let transport = StubAvatarTransport()
        transport.delay = .milliseconds(80)
        let urls = (0..<8).map { URL(string: "https://img.example.com/\($0).png")! }
        for u in urls { transport.answer(u, samplePNG()) }
        let store = AvatarStore(directory: temporaryDirectory(), transport: transport, maxConcurrent: 3)
        await withTaskGroup(of: URL?.self) { group in
            for _ in 0..<5 { group.addTask { await store.thumbnail(for: urls[0]) } }
            for u in urls.dropFirst() { group.addTask { await store.thumbnail(for: u) } }
            for await _ in group {}
        }
        XCTAssertEqual(transport.calls.filter { $0 == urls[0] }.count, 1)
        XCTAssertEqual(transport.calls.count, 8)
        XCTAssertLessThanOrEqual(transport.peak, 3)
    }

    func testCorruptOversizedAndNonImageDownloadsAreRefusedAndNotRetriedAtOnce() async throws {
        let transport = StubAvatarTransport()
        let corrupt = URL(string: "https://img.example.com/corrupt.png")!
        let html = URL(string: "https://img.example.com/page.png")!
        let huge = URL(string: "https://img.example.com/huge.png")!
        transport.answer(corrupt, Data("\u{89}PNG not really".utf8))
        transport.answer(html, samplePNG(), type: "text/html")
        transport.answer(huge, Data(count: AvatarStore.maxBytes + 1))
        let clock = MutableClock()
        let store = AvatarStore(directory: temporaryDirectory(), transport: transport, now: { clock.now })
        for u in [corrupt, html, huge] {
            let file = await store.thumbnail(for: u)
            XCTAssertNil(file, u.absoluteString)
        }
        for u in [corrupt, html, huge] { _ = await store.thumbnail(for: u) }
        XCTAssertEqual(transport.calls.count, 3, "a failed URL is not asked for again straight away")
        clock.advance(7 * 3600)
        transport.answer(corrupt, samplePNG())
        let repaired = await store.thumbnail(for: corrupt)
        XCTAssertNotNil(repaired, "retried after the back-off")
        XCTAssertThrowsError(try AvatarStore.thumbnailPNG(samplePNG(width: 100, height: 100), maxPixels: 64, maxSourcePixels: 5000))
    }

    func testPicturesOverTwoMegabytesUpToTheFiveMebibyteCapAreAccepted() async throws {
        XCTAssertEqual(AvatarStore.maxBytes, 5 * 1024 * 1024)
        let transport = StubAvatarTransport()
        let large = URL(string: "https://img.example.com/large.png")!
        let atCap = URL(string: "https://img.example.com/cap.png")!
        let over = URL(string: "https://img.example.com/over.png")!
        // A real 2.17 MB profile photo was refused by the old 2 MB cap. Trailing bytes pad a small PNG to each size.
        transport.answer(large, samplePNG() + Data(count: 2_170_000))
        transport.answer(atCap, samplePNG() + Data(count: AvatarStore.maxBytes - samplePNG().count))
        transport.answer(over, samplePNG() + Data(count: AvatarStore.maxBytes + 1 - samplePNG().count))
        let store = AvatarStore(directory: temporaryDirectory(), transport: transport)
        let largeFile = await store.thumbnail(for: large)
        let atCapFile = await store.thumbnail(for: atCap)
        let overFile = await store.thumbnail(for: over)
        XCTAssertNotNil(largeFile)
        XCTAssertNotNil(atCapFile)
        XCTAssertNil(overFile)
        let thumbnail = try XCTUnwrap(largeFile.flatMap { try? Data(contentsOf: $0) })
        XCTAssertLessThan(thumbnail.count, 64 * 1024, "the stored file is the small re-encoded thumbnail")
    }

    func testOfflineFailureIsRetriedSoonAndRefusedURLsAreNeverFetched() async throws {
        let transport = StubAvatarTransport()
        transport.answer(url, samplePNG())
        transport.offline = true
        let clock = MutableClock()
        let store = AvatarStore(directory: temporaryDirectory(), transport: transport, now: { clock.now })
        let offline = await store.thumbnail(for: url)
        XCTAssertNil(offline)
        clock.advance(301)
        transport.offline = false
        let online = await store.thumbnail(for: url)
        XCTAssertNotNil(online)
        for refused in ["http://img.example.com/a.png", "https://192.168.0.2/a.png", "https://router.local/a.png"] {
            let file = await store.thumbnail(for: URL(string: refused)!)
            XCTAssertNil(file)
        }
        XCTAssertEqual(transport.calls.count, 2)
    }

    func testTurningDownloadsOffCancelsInFlightAndKeepsCachedFiles() async throws {
        let transport = StubAvatarTransport()
        let cached = URL(string: "https://img.example.com/cached.png")!
        let slow = URL(string: "https://img.example.com/slow.png")!
        transport.answer(cached, samplePNG())
        transport.answer(slow, samplePNG())
        let store = AvatarStore(directory: temporaryDirectory(), transport: transport)
        let kept = await store.thumbnail(for: cached)
        XCTAssertNotNil(kept)
        transport.delay = .seconds(5)
        let pending = Task { await store.thumbnail(for: slow) }
        try await Task.sleep(for: .milliseconds(50))
        let started = Date()
        await store.setEnabled(false)
        let cancelled = await pending.value
        XCTAssertNil(cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the in-flight download was cancelled, not awaited")
        XCTAssertNil(store.cachedFile(for: slow))
        let stillShown = await store.thumbnail(for: cached)
        XCTAssertEqual(stillShown, kept, "cached avatars stay visible offline and after opting out")
        let refused = await store.thumbnail(for: URL(string: "https://img.example.com/new.png")!)
        XCTAssertNil(refused)
        await store.setEnabled(true)
        transport.delay = .zero
        let resumed = await store.thumbnail(for: slow)
        XCTAssertNotNil(resumed, "a cancelled download is not remembered as a failure")
    }

    /// Manager review: a download whose bytes arrive after opting out is neither decoded nor stored.
    func testDownloadFinishingAfterOptOutIsNotStored() async throws {
        let transport = StubAvatarTransport()
        transport.answer(url, samplePNG())
        transport.delay = .milliseconds(300)
        let store = AvatarStore(directory: temporaryDirectory(), transport: transport)
        let target = url
        let pending = Task { await store.thumbnail(for: target) }
        try await Task.sleep(for: .milliseconds(100))
        await store.setEnabled(false)
        let file = await pending.value
        XCTAssertNil(file)
        XCTAssertNil(store.cachedFile(for: target))
    }

    func testOtherCacheVersionsAreRemoved() async throws {
        let root = temporaryDirectory()
        let stale = root.appendingPathComponent("v0", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: stale.appendingPathComponent("x.png"))
        let store = AvatarStore(directory: root, transport: StubAvatarTransport())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(store.directory.lastPathComponent, AvatarStore.cacheVersion)
    }

    func testDiskCacheIsBounded() async throws {
        let transport = StubAvatarTransport()
        let store = AvatarStore(directory: temporaryDirectory(), transport: transport)
        let urls = (0..<(AvatarStore.maxFiles + 5)).map { URL(string: "https://img.example.com/b\($0).png")! }
        let png = samplePNG(width: 8, height: 8)
        for u in urls { transport.answer(u, png); _ = await store.thumbnail(for: u) }
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertLessThanOrEqual(files.count, AvatarStore.maxFiles)
    }

    /// The production transport sends no credentials or cookies, keeps no cache, and follows only a few redirects to
    /// addresses the avatar policy accepts (Blossom servers redirect every picture to their CDN).
    func testProductionTransportSendsNoCredentialsAndFollowsOnlySafeRedirects() async throws {
        let transport = URLSessionAvatarTransport(protocolClasses: [RecordingAvatarProtocol.self])
        let config = transport.session.configuration
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
        RecordingAvatarProtocol.reset()
        let (data, response) = try await transport.fetch(URL(string: "https://img.example.com/ok.png")!, maxBytes: 1024 * 1024)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(data.isEmpty)
        let request = try XCTUnwrapValue(RecordingAvatarProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-flightdeck-pg-app-npub"))
        do {
            _ = try await transport.fetch(URL(string: "https://img.example.com/redirect.png")!, maxBytes: 1024 * 1024)
            XCTFail("a redirect must not be followed")
        } catch AvatarError.httpStatus(let status) {
            XCTAssertEqual(status, 302)
        }
        XCTAssertFalse(RecordingAvatarProtocol.requests.contains { $0.url?.host == "10.0.0.1" })
        // blossom.primal.net style: a redirect to a public HTTPS CDN is followed, without credentials.
        let (cdnData, cdnResponse) = try await transport.fetch(URL(string: "https://img.example.com/cdn.png")!, maxBytes: 1024 * 1024)
        XCTAssertEqual(cdnResponse.statusCode, 200)
        XCTAssertEqual(cdnResponse.url?.host, "cdn.example.com")
        XCTAssertFalse(cdnData.isEmpty)
        let cdnRequest = try XCTUnwrapValue(RecordingAvatarProtocol.requests.last { $0.url?.host == "cdn.example.com" })
        XCTAssertNil(cdnRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(cdnRequest.value(forHTTPHeaderField: "Cookie"))
        // Plain HTTP and endless redirects are not followed.
        for name in ["http.png", "loop.png"] {
            do {
                _ = try await transport.fetch(URL(string: "https://img.example.com/\(name)")!, maxBytes: 1024 * 1024)
                XCTFail("\(name) must not be followed to the end")
            } catch AvatarError.httpStatus(let status) {
                XCTAssertEqual(status, 302)
            }
        }
        XCTAssertFalse(RecordingAvatarProtocol.requests.contains { $0.url?.scheme == "http" })
        XCTAssertLessThanOrEqual(RecordingAvatarProtocol.requests.filter { $0.url?.lastPathComponent == "loop.png" }.count, AvatarRedirects.maxRedirects + 1)
        do {
            _ = try await transport.fetch(URL(string: "https://img.example.com/big.png")!, maxBytes: 1000)
            XCTFail("an oversized body must be refused")
        } catch AvatarError.tooLarge {}
    }
}

/// URLProtocol stand-in: records requests and answers `ok`, redirects (to a local address, a public CDN, plain HTTP,
/// itself) and `big`.
final class RecordingAvatarProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    private static let lock = NSLock()
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request) }
        let url = request.url!
        let redirects = ["redirect.png": "https://10.0.0.1/x.png", "cdn.png": "https://cdn.example.com/x.png",
                         "http.png": "http://cdn.example.com/x.png", "loop.png": "https://img.example.com/loop.png"]
        switch url.lastPathComponent {
        case let name where url.host != "cdn.example.com" && redirects[name] != nil:
            let location = redirects[name]!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            var next = URLRequest(url: URL(string: location)!)
            next.httpMethod = "GET"
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case "big.png":
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(count: 5000))
            client?.urlProtocolDidFinishLoading(self)
        default:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0x89, 0x50, 0x4E, 0x47]))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// A 32×32 Windows icon, as sites serve `/favicon.ico`.
private func sampleICO() -> Data {
    let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.75, green: 0.3, blue: 0.05, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.ico.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

/// Mac Deck launcher logos: where a logo may come from, and that a shown logo is local bytes on the next display.
final class LauncherLogoTests: XCTestCase {
    func testCandidatesFollowTheWebOrderAndRefuseUnsafeSources() throws {
        let object = UUID().uuidString
        let wapp = try PersonalWappRecord(raw: Fixtures.json([
            "id": UUID().uuidString, "workspace_id": Fixtures.workspaceId, "title": "Timesheets", "launch_url": "https://apps.example.com/time/",
            "icon_url": "storage://\(object)", "sort_order": 1, "status": "active", "row_version": 1,
            "metadata": ["manifest_icon_url": "https://apps.example.com/icon-192.png", "icon_url": "http://apps.example.com/plain.png",
                         "favicon_url": "https://apps.example.com/icon-192.png"],
        ]))
        XCTAssertEqual(wapp.logoCandidates, [.storage(objectId: object.lowercased()), .web(URL(string: "https://apps.example.com/icon-192.png")!),
                                             .web(URL(string: "https://apps.example.com/favicon.ico")!)],
                       "storage icon, then the manifest icon once (duplicates dropped), then the launch origin's favicon; plain HTTP is skipped")
        for refused in ["storage://not-a-uuid", "http://apps.example.com/a.png", "https://192.168.1.2/a.png", "javascript:alert(1)", "https://user:pw@apps.example.com/a.png", " "] {
            XCTAssertNil(LauncherLogoSource(refused), refused)
        }
        let bare = try PersonalWappRecord(raw: Fixtures.json(["id": UUID().uuidString, "workspace_id": Fixtures.workspaceId, "title": "Legacy",
                                                             "launch_url": "http://legacy.example.com/", "sort_order": 2, "status": "active"]))
        XCTAssertEqual(bare.logoCandidates, [], "no safe source: the launcher shows initials")
    }

    func testFaviconIsCachedAndAFreshStoreShowsTheSameBytesOffline() async throws {
        let favicon = URL(string: "https://apps.example.com/favicon.ico")!
        let transport = StubAvatarTransport()
        transport.answer(favicon, sampleICO(), type: "image/x-icon")
        let root = temporaryDirectory()
        let first = AvatarStore(directory: root, transport: transport)
        let file = try XCTUnwrapValue(await first.thumbnail(for: favicon))
        let stored = try Data(contentsOf: file)
        XCTAssertEqual(pixelSize(stored).map { [$0.0, $0.1] }, [32, 32], "ICO accepted and stored as a PNG thumbnail")
        XCTAssertEqual(transport.calls, [favicon])

        // Next launch, network gone: a new store over the same directory answers from disk without asking.
        transport.offline = true
        let relaunched = AvatarStore(directory: root, transport: transport)
        XCTAssertEqual(relaunched.cachedFile(for: favicon), file)
        let again = await relaunched.thumbnail(for: favicon)
        XCTAssertEqual(again, file)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrapValue(again)), stored, "the same local bytes")
        let uncached = await relaunched.thumbnail(for: URL(string: "https://notes.example.com/favicon.ico")!)
        XCTAssertNil(uncached, "an uncached logo offline fails cleanly (initials placeholder)")
        XCTAssertEqual(transport.calls.count, 2, "only the uncached logo was asked for")
        let downloads = await relaunched.downloads
        XCTAssertEqual(downloads, 1)
    }
}
