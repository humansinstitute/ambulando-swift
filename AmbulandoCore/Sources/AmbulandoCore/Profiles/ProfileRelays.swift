import Foundation

/// Where public profiles come from. Production reads kind-0 events from public relays; sample-data mode and tests
/// inject their own.
public protocol ProfileSource: Sendable {
    /// Verified profiles for (some of) `pubkeys`, newest per key. Throws only when no source could be asked at all, so
    /// a failed network round is retried later instead of being recorded as "no profile".
    func profiles(pubkeys: [String]) async throws -> [ProfileRecord]
}

/// Accepts a relay event only if it is a kind-0 profile of one of the requested keys with a valid NIP-01 id and
/// BIP-340 signature and a plausible time, and keeps the newest per key.
public enum ProfileEventFilter {
    /// Profiles dated before Nostr existed, or more than this far ahead of the device clock, are refused: a far-future
    /// date would otherwise pin a profile against every later, genuine update.
    public static let earliest = 1_577_836_800   // 2020-01-01
    public static let maxClockSkew: TimeInterval = 15 * 60

    public static func accept(_ events: [NostrEvent], requested: Set<String>, checkedAt: Date) -> [ProfileRecord] {
        var best: [String: ProfileRecord] = [:]
        let latest = Int(checkedAt.timeIntervalSince1970 + maxClockSkew)
        for event in events {
            guard event.kind == 0, requested.contains(event.pubkey), isLowerHex(event.pubkey, length: 64),
                  event.created_at >= earliest, event.created_at <= latest,
                  event.content.utf8.count <= NostrProfileContent.maxContentBytes,
                  SignatureVerifier.verify(event), let record = ProfileRecord.from(event: event, checkedAt: checkedAt) else { continue }
            if let current = best[event.pubkey], !record.isNewer(than: current) { continue }
            best[event.pubkey] = record
        }
        return Array(best.values)
    }

    static func isLowerHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// Reads profiles from the same public relays the web client uses (sol `nostr-relays.js PUBLIC_NOSTR_RELAYS`), never a
/// Tower transport. One `REQ` for kind 0 per relay and batch, closed at `EOSE` or the timeout; nothing is signed or
/// published, and no credentials, cookies or Tower data are sent.
public struct RelayProfileSource: ProfileSource {
    public static let relays = ["wss://relay.primal.net", "wss://nos.lol", "wss://purplepag.es"].compactMap(URL.init(string:))
    public static let maxFrameBytes = 512 * 1024

    let relays: [URL]
    let timeout: Duration
    let session: URLSession

    /// Per relay, including the WebSocket handshake: relay.primal.net's handshake alone was measured at up to 3.3 s,
    /// so a 4 s budget often left only one relay answering.
    public static let defaultTimeout: Duration = .seconds(8)

    public init(relays: [URL] = RelayProfileSource.relays, timeout: Duration = RelayProfileSource.defaultTimeout) {
        self.relays = relays.filter { $0.scheme == "wss" && $0.user == nil && $0.password == nil }
        self.timeout = timeout
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func profiles(pubkeys: [String]) async throws -> [ProfileRecord] {
        let requested = Set(pubkeys)
        guard !requested.isEmpty else { return [] }
        let results = await withTaskGroup(of: [NostrEvent]?.self) { group in
            for relay in relays { group.addTask { try? await query(relay, authors: Array(requested)) } }
            var all: [[NostrEvent]?] = []
            for await result in group { all.append(result) }
            return all
        }
        // Every relay failed to answer: treat as offline, not as "these people have no profile".
        guard results.contains(where: { $0 != nil }) else { throw URLError(.cannotConnectToHost) }
        return ProfileEventFilter.accept(results.compactMap { $0 }.flatMap { $0 }, requested: requested, checkedAt: Date())
    }

    /// Events from one relay until its `EOSE`, `CLOSED` or the timeout (which also covers the connection handshake).
    /// nil if the relay could not be reached or did not answer in time.
    func query(_ relay: URL, authors: [String]) async throws -> [NostrEvent]? {
        let task = session.webSocketTask(with: relay)
        task.maximumMessageSize = Self.maxFrameBytes
        task.resume()
        let subscription = "p" + UUID().uuidString.prefix(8).lowercased()
        let filter: [String: Any] = ["kinds": [0], "authors": authors, "limit": authors.count * 2]
        let request = String(decoding: try JSONSerialization.data(withJSONObject: ["REQ", subscription, filter]), as: UTF8.self)
        let close = String(decoding: try JSONSerialization.data(withJSONObject: ["CLOSE", subscription]), as: UTF8.self)
        let limit = authors.count * 4
        let timeout = timeout
        let outcome: [NostrEvent]? = try await withThrowingTaskGroup(of: [NostrEvent]?.self) { group in
            group.addTask {
                try await task.send(.string(request))
                var events: [NostrEvent] = []
                while events.count < limit {
                    let message = try await task.receive()
                    guard case .string(let text) = message, let frame = RelayFrame(text), frame.subscription == subscription else { continue }
                    switch frame.kind {
                    case .event(let event): events.append(event)
                    case .end: return events
                    }
                }
                return events
            }
            group.addTask { try await Task.sleep(for: timeout); return nil }
            defer {
                // Ends a receive that is still waiting; the group then finishes at once (child errors are discarded).
                task.cancel(with: .normalClosure, reason: nil)
                group.cancelAll()
            }
            let first = try await group.next() ?? nil
            if first != nil { try? await task.send(.string(close)) }
            return first
        }
        return outcome
    }
}

/// One relay → client frame of interest (`EVENT`, `EOSE`, `CLOSED`).
struct RelayFrame {
    enum Kind { case event(NostrEvent), end }
    let subscription: String
    let kind: Kind

    init?(_ text: String) {
        guard text.utf8.count <= RelayProfileSource.maxFrameBytes, let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any], let type = array.first as? String,
              array.count >= 2, let subscription = array[1] as? String else { return nil }
        self.subscription = subscription
        switch type {
        case "EVENT":
            guard array.count >= 3, let object = array[2] as? [String: Any],
                  let body = try? JSONSerialization.data(withJSONObject: object),
                  let event = try? JSONDecoder().decode(NostrEvent.self, from: body) else { return nil }
            kind = .event(event)
        case "EOSE", "CLOSED": kind = .end
        default: return nil
        }
    }
}
