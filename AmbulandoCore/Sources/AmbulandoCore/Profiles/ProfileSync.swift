import Foundation

/// Keeps the public-profile cache fresh for the people a workspace shows. Runs as one background job per connection on
/// the shared `SyncEngine` (deduplicated, cancellable, backed off on failure), reads candidates from the local store,
/// and asks the profile source only for keys whose cached answer is due.
///
/// Screens never wait for it: they render from the cache (or the npub and initials) and update when a row changes.
public struct ProfileSync: Sendable {
    /// `app_state` key; "off" turns off every request for profiles and profile pictures. On by default, as on the web.
    public static let preferenceKey = "profiles.public"
    /// A found profile is checked again after a day; a missing one after six hours.
    public static let foundTTL: TimeInterval = 24 * 3600
    public static let missingTTL: TimeInterval = 6 * 3600
    public static let batchSize = 50

    let store: LocalStore
    let engine: SyncEngine
    let source: ProfileSource
    let now: @Sendable () -> Date

    public init(store: LocalStore, engine: SyncEngine, source: ProfileSource, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.engine = engine; self.source = source; self.now = now
    }

    /// One job per connection and workspace: candidates are workspace-specific, so a refresh for workspace B queued
    /// while A's is running must not be coalesced into A's job.
    public static func jobKey(_ connectionId: String, _ workspaceId: String) -> String { "\(jobPrefix(connectionId))\(workspaceId)" }
    public static func jobPrefix(_ connectionId: String) -> String { "profiles:\(connectionId):" }

    public static func isEnabled(_ store: LocalStore) async -> Bool {
        (try? await store.reader.state(preferenceKey)) != "off"
    }

    /// Whether a cached answer should be asked for again.
    public static func isDue(_ profile: ProfileRecord?, now: Date, force: Bool) -> Bool {
        guard let profile, !force else { return true }
        let age = now.timeIntervalSince(profile.checkedAt)
        return age < 0 || age >= (profile.status == .found ? foundTTL : missingTTL)
    }

    /// Schedules a refresh of the profiles `workspaceId` shows. `force` (Settings › Refresh Nostr profiles) asks again
    /// for everyone, keeping cached rows until newer ones arrive.
    public func refresh(connection: ConnectionRecord, workspaceId: String, force: Bool = false) async {
        let job = self
        await engine.enqueue(Self.jobKey(connection.id, workspaceId), priority: .background, force: force) {
            try await job.run(connectionId: connection.id, workspaceId: workspaceId, force: force)
        }
    }

    /// One refresh pass. Public so tests can await it directly.
    public func run(connectionId: String, workspaceId: String, force: Bool) async throws {
        guard await Self.isEnabled(store) else { return }
        let candidates = try await store.reader.profileCandidates(connectionId: connectionId, workspaceId: workspaceId)
        let cached = Dictionary(try await store.reader.profiles(connectionId: connectionId).map { ($0.npub, $0) }, uniquingKeysWith: { a, _ in a })
        let date = now()
        var due: [String: String] = [:]   // pubkey → npub
        for npub in candidates where Self.isDue(cached[npub], now: date, force: force) {
            if let hex = NostrKeys.publicKeyHex(npub: npub) { due[hex] = npub }
        }
        let keys = due.keys.sorted()
        for start in stride(from: 0, to: keys.count, by: Self.batchSize) {
            try Task.checkCancellation()
            guard await Self.isEnabled(store) else { return }
            let batch = Array(keys[start..<min(start + Self.batchSize, keys.count)])
            let found = try await source.profiles(pubkeys: batch)
            try Task.checkCancellation()
            // Turned off while the relays were answering: nothing from that round is stored.
            guard await Self.isEnabled(store) else { return }
            let checked = Dictionary(uniqueKeysWithValues: batch.compactMap { key in due[key].map { (key, $0) } })
            try await store.writer.recordProfileCheck(connectionId: connectionId, found: found, checked: checked, at: now(),
                                                      unlessOff: Self.preferenceKey)
        }
        try await store.writer.pruneProfiles(connectionId: connectionId)
    }
}
