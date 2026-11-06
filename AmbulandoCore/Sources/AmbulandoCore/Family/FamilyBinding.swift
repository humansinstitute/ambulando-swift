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
    /// The existing conversation, chosen from the channel's own list. The app never creates one.
    public let threadId: String
    public var conversationTitle: String
    public let boundAt: String

    public init(connectionId: String, origin: String, signerNpub: String, workspaceId: String, appNpub: String, workspaceLabel: String,
                channelId: String, channelName: String, threadId: String, conversationTitle: String,
                boundAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.version = Self.currentVersion
        self.connectionId = connectionId; self.origin = origin; self.signerNpub = signerNpub
        self.workspaceId = workspaceId.lowercased(); self.appNpub = appNpub; self.workspaceLabel = workspaceLabel
        self.channelId = channelId.lowercased(); self.channelName = channelName
        self.threadId = threadId.lowercased(); self.conversationTitle = conversationTitle
        self.boundAt = boundAt
    }

    /// Every id must be a UUID. Anything else is unusable and is not restored.
    public var isWellFormed: Bool {
        version == Self.currentVersion && UUID(uuidString: workspaceId) != nil && UUID(uuidString: channelId) != nil && UUID(uuidString: threadId) != nil
    }

    /// Where drafts and unsent messages of the bound conversation live.
    public var target: ChatTarget {
        ChatTarget(connectionId: connectionId, workspaceId: workspaceId, channelId: channelId, threadId: threadId)
    }

    /// An unsent message may go out only if it was written for exactly this account, Tower, space, channel and conversation.
    /// (The connection id may differ after a reconnect to the same Tower; the origin and signer are what identify it.)
    public func admits(_ item: OutboxItem) -> Bool {
        item.origin == origin && item.signerNpub == signerNpub && item.workspaceId == workspaceId && item.appNpub == appNpub
            && item.channelId == channelId && item.threadId == threadId
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
    case ready

    public var canShowConversation: Bool { self == .ready || self == .conversationArchived || self == .checking }
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
    /// Tower just returned `thread` for this account, which also proves the channel is readable (no channel listing needed).
    public var threadConfirmedLive: Bool

    public init(signerNpub: String?, connection: ConnectionRecord?, accessibleWorkspaces: [WorkspaceRecord]?, channelsLoaded: Bool = false,
                channel: ChannelRecord? = nil, threadLoaded: Bool = false, thread: ThreadRecord? = nil, threadConfirmedLive: Bool = false) {
        self.signerNpub = signerNpub; self.connection = connection; self.accessibleWorkspaces = accessibleWorkspaces
        self.channelsLoaded = channelsLoaded; self.channel = channel; self.threadLoaded = threadLoaded; self.thread = thread
        self.threadConfirmedLive = threadConfirmedLive
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
        let channelKnown = facts.channel?.id == binding.channelId || facts.threadConfirmedLive
        if !channelKnown { return facts.channelsLoaded ? .channelUnavailable : .checking }
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
        guard let binding else { return .ignore }
        let threadId = binding.threadId
        switch destination {
        case .thread(let workspace, let channel, let thread):
            return same(workspace, binding.workspaceId) && same(channel, binding.channelId) && same(thread, threadId) ? .showConversation : .ignore
        case .threadById(let workspace, let thread):
            return same(workspace, binding.workspaceId) && same(thread, threadId) ? .showConversation : .ignore
        case .task, .doc, .channel, .notification:
            return .ignore
        }
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

    /// From Tower's thread list for a channel (the authoritative one used when setting up): its title, else the newest
    /// message's text. Deleted threads are never offered; archived ones are listed but marked.
    public static func options(fromThreads threads: [ThreadRecord]) -> [FamilyConversationOption] {
        threads.filter { !$0.deleted }.map { thread in
            let latest = MentionCodec.plain(thread.latest ?? "")
            let title = (thread.title?.isEmpty == false ? thread.title.map(MentionCodec.plain) : nil) ?? String(latest.prefix(60))
            return FamilyConversationOption(id: thread.id, title: title.isEmpty ? "Conversation" : title, firstMessage: latest, startedBy: nil,
                                            messageCount: 0, lastActivityAt: thread.updatedAt, archived: thread.archived)
        }
        .sorted { ($0.lastActivityAt, $0.id) > ($1.lastActivityAt, $1.id) }
    }

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
