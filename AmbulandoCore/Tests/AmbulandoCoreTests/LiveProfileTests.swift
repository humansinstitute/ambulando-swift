import Foundation
import XCTest
@testable import AmbulandoCore

/// Opt-in read of real public profiles from the production relays, through the app's own relay source and filter.
/// Nothing is signed or published, and no private key is involved.
///
/// `AMBULANDO_LIVE_PROFILES=<hex pubkey>,<hex pubkey> swift test --filter LiveProfileTests`
/// `AMBULANDO_LIVE_AVATAR=<https picture URL> swift test --filter LiveProfileTests` (for example a Blossom URL, which
/// redirects to its CDN)
final class LiveProfileTests: XCTestCase {
    func testPublicProfilesAreReadFromTheRelaysWhenConfigured() async throws {
        guard let value = ProcessInfo.processInfo.environment["AMBULANDO_LIVE_PROFILES"] else { throw XCTSkip("AMBULANDO_LIVE_PROFILES not set") }
        let keys = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let found = try await RelayProfileSource().profiles(pubkeys: keys)
        for record in found {
            print("live profile \(record.npub.prefix(14)) name=\(record.preferredName ?? "-") picture=\(record.picture != nil)")
        }
        if ProcessInfo.processInfo.environment["AMBULANDO_LIVE_PROFILES_DEBUG"] != nil {
            for relay in RelayProfileSource.relays {
                let start = Date()
                let events = try? await RelayProfileSource().query(relay, authors: keys)
                print("relay \(relay.host ?? "") events=\(events.map { String($0.count) } ?? "nil") pubkeys=\(Set(events?.map { String($0.pubkey.prefix(6)) } ?? []).sorted()) in \(Date().timeIntervalSince(start))")
            }
        }
        XCTAssertFalse(found.isEmpty, "no verified profile came back for \(keys.count) keys")
        XCTAssertTrue(found.allSatisfy { $0.preferredName != nil || $0.picture != nil })
    }

    func testAvatarIsDownloadedThroughSafeRedirectsWhenConfigured() async throws {
        guard let value = ProcessInfo.processInfo.environment["AMBULANDO_LIVE_AVATAR"], let url = AvatarURLPolicy.validate(value) else {
            throw XCTSkip("AMBULANDO_LIVE_AVATAR not set")
        }
        let (data, response) = try await URLSessionAvatarTransport().fetch(url, maxBytes: AvatarStore.maxBytes)
        print("live avatar \(url.host ?? "") -> \(response.url?.host ?? "") status=\(response.statusCode) bytes=\(data.count)")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNoThrow(try AvatarStore.thumbnailPNG(data))
    }
}
