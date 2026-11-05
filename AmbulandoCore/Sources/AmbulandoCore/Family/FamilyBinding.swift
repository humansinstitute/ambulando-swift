import Foundation

/// The one conversation a Grandparent Chat install is bound to: an existing Tower workspace → channel → thread chosen
/// by the person who set it up. The binding names records; it never copies messages (the canonical thread stays in
/// Tower and is read and written through the same contracts as Ambulando). It is scoped to the signing identity and
/// the Tower origin, so a different account or Tower can never send into it.
public struct FamilyBinding: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var connectionId: String
    public let origin: String
    public let signerNpub: String
    public let workspaceId: String
    public let appNpub: String
    public let workspaceLabel: String
    public let channelId: String
    public let channelName: String
    /// Nil only while an explicitly created conversation waits for Tower to answer its first message.
    public var threadId: String?
    public var conversationTitle: String
    public var pendingCreation: PendingCreation?
    public let boundAt: String

    /// A conversation being created by sending its first message. `requestId` is the outbox row's `client_request_id`,
    /// fixed before anything is sent so every retry (and a relaunch) replays the same request instead of making a second.
    public struct PendingCreation: Codable, Equatable, Sendable {
        public let requestId: String
        public let createdAt: String
        public init(requestId: String, createdAt: String) { self.requestId = requestId; self.createdAt = createdAt }
    }

    public init(connectionId: String, origin: String, signerNpub: String, workspaceId: String, appNpub: String, workspaceLabel: String,
                channelId: String, channelName: String, threadId: String?, conversationTitle: String,
                pendingCreation: PendingCreation? = nil, boundAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.version = Self.currentVersion
        self.connectionId = connectionId; self.origin = origin; self.signerNpub = signerNpub
        self.workspaceId = workspaceId.lowercased(); self.appNpub = appNpub; self.workspaceLabel = workspaceLabel
        self.channelId = channelId.lowercased(); self.channelName = channelName
        self.threadId = threadId?.lowercased(); self.conversationTitle = conversationTitle
        self.pendingCreation = pendingCreation; self.boundAt = boundAt
    }

    /// A binding must name a thread or a creation in flight; anything else is unusable and is not restored.
    public var isWellFormed: Bool {
        version == Self.currentVersion && (threadId != nil || pendingCreation != nil)
            && UUID(uuidString: workspaceId) != nil && UUID(uuidString: channelId) != nil && threadId.map { UUID(uuidString: $0) != nil } != false
    }

    /// Where drafts and unsent messages of the bound conversation live. Nil while the conversation is still being created.
    public var target: ChatTarget? {
        threadId.map { ChatTarget(connectionId: connectionId, workspaceId: workspaceId, channelId: channelId, threadId: $0) }
    }

    /// Where the first message of a conversation being created waits.
    public var creationTarget: ChatTarget { ChatTarget(connectionId: connectionId, workspaceId: workspaceId, channelId: channelId, threadId: nil) }

    public func withThread(_ id: String, title: String) -> FamilyBinding {
        var next = self
        next.threadId = id.lowercased(); next.pendingCreation = nil; next.conversationTitle = title
        return next
    }
}

/// What the app currently knows about whether the binding may be read and written.
public enum FamilyAccess: Equatable, Sendable {
    case needsSignIn
    case needsConnection
    /// The identity on this device is not the one that bound the conversation. Nothing is deleted or sent.
    case differentAccount
    case differentTower
    /// Facts are still loading; cached messages may show but nothing is sent yet.
    case checking
    case workspaceUnavailable
    case channelUnavailable
    case conversationUnavailable
    case conversationArchived
    case awaitingCreation
    case ready

    public var canShowConversation: Bool { self == .ready || self == .conversationArchived || self == .checking || self == .awaitingCreation }
    /// Only a confirmed, writable target accepts a message. Archived is read-only here: Ambulando reopens a thread on reply,
    /// but a family member should not silently un-archive something someone else put away.
    public var canSend: Bool { self == .ready }
}

/// What is known locally and from the last confirmed listing. `nil` means "not loaded yet", never "absent".
public struct FamilyFacts: Sendable {
    public var signerNpub: String?
    public var connection: ConnectionRecord?
    /// The workspaces Tower listed for the connection, once a listing has completed.
    public var accessibleWorkspaces: [WorkspaceRecord]?
    public var channelsLoaded: Bool
    public var channel: ChannelRecord?
    public var threadLoaded: Bool
    public var thread: ThreadRecord?

    public init(signerNpub: String?, connection: ConnectionRecord?, accessibleWorkspaces: [WorkspaceRecord]?, channelsLoaded: Bool = false,
                channel: ChannelRecord? = nil, threadLoaded: Bool = false, thread: ThreadRecord? = nil) {
        self.signerNpub = signerNpub; self.connection = connection; self.accessibleWorkspaces = accessibleWorkspaces
        self.channelsLoaded = channelsLoaded; self.channel = channel; self.threadLoaded = threadLoaded; self.thread = thread
    }
}

public enum FamilyAccessEvaluator {
    /// The order matters: identity and account first (so another person's data is never shown as ready), then the
    /// workspace, channel and thread. A missing record is "unavailable" only when its listing is known to be complete.
    public static func evaluate(_ binding: FamilyBinding, _ facts: FamilyFacts) -> FamilyAccess {
        guard let signer = facts.signerNpub else { return .needsSignIn }
        guard signer == binding.signerNpub else { return .differentAccount }
        guard let connection = facts.connection else { return .needsConnection }
        guard connection.origin == binding.origin, connection.signerNpub == binding.signerNpub else { return .differentTower }
        guard let workspaces = facts.accessibleWorkspaces else { return .checking }
        guard workspaces.contains(where: { $0.id == binding.workspaceId && $0.appNpub == binding.appNpub }) else { return .workspaceUnavailable }
        guard facts.channelsLoaded else { return .checking }
        guard facts.channel?.id == binding.channelId else { return .channelUnavailable }
        if binding.threadId == nil { return binding.pendingCreation == nil ? .conversationUnavailable : .awaitingCreation }
        guard facts.threadLoaded else { return .checking }
        guard let thread = facts.thread, thread.id == binding.threadId, thread.channelId == binding.channelId,
              thread.workspaceId == binding.workspaceId, !thread.deleted else { return .conversationUnavailable }
        return thread.archived ? .conversationArchived : .ready
    }
}

/// Notification and link routing. The app shows exactly one conversation, so a route either names it or is ignored; it can
/// never select another workspace, channel, thread, task or document. (Tower still decides who may read what.)
public enum FamilyRouting {
    public enum Outcome: Equatable, Sendable {
        case showConversation
        case ignore
    }

    public static func resolve(_ destination: PushDestination, binding: FamilyBinding?) -> Outcome {
        guard let binding, let threadId = binding.threadId else { return .ignore }
        switch destination {
        case .thread(let workspace, let channel, let thread):
            return same(workspace, binding.workspaceId) && same(channel, binding.channelId) && same(thread, threadId) ? .showConversation : .ignore
        case .threadById(let workspace, let thread):
            return same(workspace, binding.workspaceId) && same(thread, threadId) ? .showConversation : .ignore
        case .task, .doc, .channel, .notification:
            return .ignore
        }
    }

    /// An alert for any other destination is not shown while the app is open (the system would otherwise present a
    /// banner whose tap this app refuses to follow).
    public static func presentsBanner(_ destination: PushDestination?, binding: FamilyBinding?) -> Bool {
        guard let destination else { return false }
        return resolve(destination, binding: binding) == .showConversation
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }
}

/// One selectable conversation in setup. Titles come from Tower, then the first message.
public struct FamilyConversationOption: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let firstMessage: String
    public let startedBy: String?
    public let messageCount: Int
    public let lastActivityAt: String
    public let archived: Bool

    public static func options(from summaries: [ThreadSummary]) -> [FamilyConversationOption] {
        summaries.map { summary in
            let title = (summary.title?.isEmpty == false ? summary.title : nil) ?? String(MentionCodec.plain(summary.rootBody).prefix(60))
            return FamilyConversationOption(id: summary.id, title: title.isEmpty ? "Conversation" : title,
                                            firstMessage: MentionCodec.plain(summary.rootBody), startedBy: summary.rootSender,
                                            messageCount: summary.replyCount + 1, lastActivityAt: summary.lastActivityAt, archived: summary.archived)
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}

/// Creating a conversation sends its first message with `create_thread` under a `client_request_id` chosen once.
/// Tower replays that id, so a retry or relaunch cannot make a second thread from this install. It is not a global
/// uniqueness guarantee (another device can create its own), which is why the existing threads are fetched first and
/// shown, and why the person must say they still want a new one.
public enum FamilyCreationGate {
    public enum Decision: Equatable, Sendable {
        case allowed
        /// The channel's threads were not fetched from Tower just now (offline, or the fetch failed).
        case refreshRequired
        /// Conversations already exist; the person must pick one or explicitly choose to start another.
        case existingConversations([FamilyConversationOption])
        case emptyMessage
    }

    public static func check(refreshedFromTower: Bool, existing: [FamilyConversationOption], acknowledgedExisting: Bool, firstMessage: String) -> Decision {
        guard refreshedFromTower else { return .refreshRequired }
        let live = existing.filter { !$0.archived }
        if !live.isEmpty, !acknowledgedExisting { return .existingConversations(live) }
        return OutboxRequest.normalizedBody(firstMessage).isEmpty ? .emptyMessage : .allowed
    }

    public static func makePending(now: Date = Date()) -> FamilyBinding.PendingCreation {
        FamilyBinding.PendingCreation(requestId: UUID().uuidString.lowercased(), createdAt: ISO8601DateFormatter().string(from: now))
    }
}
