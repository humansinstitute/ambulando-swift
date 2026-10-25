import AmbulandoCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Decoded avatar thumbnails in memory, backed by `AvatarStore` on disk. Lookups are synchronous and thread-safe so a
/// row can show a known avatar in its first frame; loading and decoding run off the main actor.
final class AvatarCenter: @unchecked Sendable {
    let store: AvatarStore
    private let memory: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    init(store: AvatarStore) { self.store = store }

    func cached(_ url: URL) -> PlatformImage? { memory.object(forKey: url.absoluteString as NSString) }

    /// The avatar for `url`: memory, then the disk cache, then (when allowed) a download. nil keeps the initials.
    func load(_ url: URL, scale: CGFloat) async -> PlatformImage? {
        if let hit = cached(url) { return hit }
        let store = store
        let image = await Task.detached(priority: .utility) { () -> PlatformImage? in
            guard let file = await store.thumbnail(for: url) else { return nil }
            return StorageImageCache.downsample(file, maxPixels: CGFloat(AvatarStore.thumbnailPixels), scale: scale)
        }.value
        if let image {
            memory.setObject(image, forKey: url.absoluteString as NSString, cost: image.decodedBytes)
        }
        return image
    }

    func clear() async {
        memory.removeAllObjects()
        await store.clear()
    }
}

/// The signed-in person for the profile button and Settings: how they are shown, where the name comes from, their
/// public profile name (even when the workspace name wins) and how many profiles this iPhone has saved.
struct AccountProfile: Sendable, Equatable {
    var person: PersonDisplay
    var publicName: String?
    var profileCheckedAt: Date?
    var savedProfiles: Int
}

/// Profile and avatar sources that are never reachable (debug test runs that must not touch the public network).
struct UnreachableProfiles: ProfileSource, AvatarTransport {
    func profiles(pubkeys: [String]) async throws -> [ProfileRecord] { throw URLError(.notConnectedToInternet) }
    func fetch(_ url: URL, maxBytes: Int) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}

extension AppModel {
    /// Starts the profile reads for the selected workspace: the signed-in person, and the member/agent list whose
    /// changes schedule a (bounded, deduplicated) profile refresh.
    func observePeople(connection: ConnectionRecord, workspaceId: String) {
        guard let store else { return }
        let signer = connection.signerNpub, connectionId = connection.id
        me.start(store: store, matches: { key in
            key.table == .profiles || ([.members, .agents].contains(key.table) && key.workspaceId == workspaceId)
        }) {
            async let people = store.reader.people(connectionId: connectionId, workspaceId: workspaceId)
            let profiles = try await store.reader.profiles(connectionId: connectionId)
            let own = profiles.first { $0.npub == signer }
            return AccountProfile(person: try await people.person(signer), publicName: own?.preferredName,
                                  profileCheckedAt: own?.checkedAt, savedProfiles: profiles.filter { $0.status == .found }.count)
        }
        lastProfilePeople = nil
        profilePeople.onLoad = { [weak self] people in
            guard let self, people != self.lastProfilePeople else { return }
            self.lastProfilePeople = people
            self.refreshProfiles()
        }
        profilePeople.start(store: store, matches: { [.members, .agents].contains($0.table) && $0.workspaceId == workspaceId }) {
            try await store.reader.profileCandidates(connectionId: connectionId, workspaceId: workspaceId)
        }
    }

    /// Profiles are fetched only in the foreground (an iPhone app in the background, never a Mac app that is running).
    static var inForeground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState != .background
        #else
        true
        #endif
    }

    func stopPeople() {
        me.stop()
        profilePeople.stop()
        lastProfilePeople = nil
    }

    /// Asks for profiles that are due (or everyone, when forced). Only in the foreground and only when the user allows
    /// public profiles; the job itself reads the candidates from the store and never blocks a screen.
    func refreshProfiles(force: Bool = false) {
        // The id, not the observed workspace list: at launch the list may not have loaded when the people are read.
        guard publicProfilesEnabled, let profiles, let connection, let workspaceId = navigationWorkspaceId ?? selectedWorkspaceId,
              fixture != nil || Self.inForeground else { return }
        Task { await profiles.refresh(connection: connection, workspaceId: workspaceId, force: force) }
    }

    /// Settings › Nostr profiles. Off stops and cancels relay and picture requests; cached names and pictures stay.
    func setPublicProfiles(_ on: Bool) async {
        guard let store else { return }
        publicProfilesEnabled = on
        try? await store.writer.setState(ProfileSync.preferenceKey, on ? nil : "off")
        await avatars?.store.setEnabled(on)
        if on { refreshProfiles() }
        else if let sync, let connection { await sync.engine.cancel(prefix: ProfileSync.jobPrefix(connection.id)) }
    }
}

/// A person's avatar: the cached picture when there is one, otherwise their initials on the primary colour (sol
/// `.identity-card-avatar-fallback`). Never waits on the network before drawing.
struct PersonAvatar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let person: PersonDisplay
    var size: CGFloat = 34
    @State private var loaded: PlatformImage?
    @State private var loadedURL: URL?

    var body: some View {
        let image = (loadedURL == person.avatarURL ? loaded : nil) ?? person.avatarURL.flatMap { model.avatars?.cached($0) }
        ZStack {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
                    .accessibilityIdentifier("avatar.image")
            } else {
                InitialsAvatar(initials: person.initials, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: person.avatarURL) {
            guard let url = person.avatarURL, let center = model.avatars, center.cached(url) == nil else { return }
            let image = await center.load(url, scale: scale)
            guard !Task.isCancelled else { return }
            loaded = image
            loadedURL = url
        }
    }
}

struct InitialsAvatar: View {
    let initials: String
    var size: CGFloat = 34
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(Amb.primaryForeground)
            .frame(width: size, height: size)
            .background(Amb.primary, in: Circle())
            .accessibilityHidden(true)
    }
}
