import AmbulandoCore
import Foundation

/// The web app's sections, in its mobile bottom-bar order (sol `index.html` `.mobile-section-switcher`): Deck, Chat,
/// Tasks, Docs, Files, Agents and Context (optional, off by default as on the web), Toolbox. Every section reads the
/// shared Workspace → Scope → Channel context except Toolbox (the member's own WApps).
enum AppMode: String, CaseIterable, Codable {
    case deck, chat, tasks, docs, files, agents, context, toolbox

    /// A saved section from any build. Builds 3–8 had an Inbox tab; Deck's Inbox card replaces it.
    init(stored: String?) {
        if stored == "inbox" { self = .deck } else { self = stored.flatMap(AppMode.init(rawValue:)) ?? .chat }
    }

    var title: String {
        switch self {
        case .deck: "Deck"
        case .chat: "Chat"
        case .tasks: "Tasks"
        case .docs: "Docs"
        case .files: "Files"
        case .agents: "Agents"
        case .context: "Context"
        case .toolbox: "Toolbox"
        }
    }

    var systemImage: String {
        switch self {
        case .deck: "rectangle.3.group"
        case .chat: "bubble.left.and.bubble.right"
        case .tasks: "checklist"
        case .docs: "doc.text"
        case .files: "folder"
        case .agents: "sparkles"
        case .context: "point.3.connected.trianglepath.dotted"
        case .toolbox: "wrench.and.screwdriver"
        }
    }

    /// Sections whose records belong to the sidebar context; a new sidebar choice returns them to their first screen.
    var followsContext: Bool { [.tasks, .docs, .files, .agents, .context].contains(self) }

    /// Agents and Context are personal options (web Settings › Agents / Context, default off).
    static let agentsPreference = "sections.agents"
    static let contextPreference = "sections.context"

    static func visible(agents: Bool, context: Bool) -> [AppMode] {
        allCases.filter { ($0 != .agents || agents) && ($0 != .context || context) }
    }
}

/// Deck's cards on a phone, in the web's order (`DECK_MOBILE_CARDS`). Pinned items is shown only when there are pins.
enum DeckCard: String, CaseIterable, Identifiable, Codable {
    case hello, inbox, pinned, canvas, feed, recent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hello: "Hello and Links"
        case .inbox: "Inbox"
        case .pinned: "Pinned items"
        case .canvas: "Canvas"
        case .feed: "Feed"
        case .recent: "Recent"
        }
    }
}

extension AppModel {
    // MARK: Sections

    static func pathKey(_ mode: AppMode) -> ReferenceWritableKeyPath<AppModel, [WorkRoute]>? {
        switch mode {
        case .deck: \.deckPath
        case .chat: nil
        case .tasks: \.tasksPath
        case .docs: \.docsPath
        case .files: \.filesPath
        case .agents: \.agentsPath
        case .context: \.contextPath
        case .toolbox: \.toolboxPath
        }
    }

    func push(_ route: WorkRoute, in mode: AppMode) {
        guard let key = Self.pathKey(mode) else { return }
        self[keyPath: key].append(route)
    }

    /// Back to a section's first screen (tapping the current section again, as on a tab bar).
    func popToRoot(_ mode: AppMode) {
        if let key = Self.pathKey(mode) { self[keyPath: key] = [] } else { chatPath = [] }
    }

    func resetSectionPaths() {
        for mode in AppMode.allCases where mode != .chat { popToRoot(mode) }
    }

    /// A new sidebar choice: records open in the old context would otherwise stay on top.
    func resetContextSections() {
        for mode in AppMode.allCases where mode.followsContext { popToRoot(mode) }
    }

    /// Chat, Tasks, Docs and Files can be locked so a sidebar choice keeps them (sol `canLockCurrentView`).
    var canLockCurrentView: Bool { [.chat, .tasks, .docs, .files].contains(mode) }
    var isCurrentViewLocked: Bool { canLockCurrentView && lockedView == mode }
    func toggleCurrentViewLock() { lockedView = canLockCurrentView && !isCurrentViewLocked ? mode : nil }

    /// A Home, scope or channel choice in the sidebar, with the web's destination (sol `selectWorkContextBoard`): Deck
    /// for the new context, unless the current Chat, Tasks, Docs or Files view is locked, which then stays.
    /// Deck then shows its Inbox card for the new context at its first screen, as the web resets its card track; ordinary
    /// section switches keep Deck's card and open screen.
    func chooseInSidebar(_ next: WorkContext) {
        let destination: AppMode = isCurrentViewLocked ? mode : .deck
        selectContext(next)
        if destination == .deck { deckPath = []; deckInboxRequests &+= 1 }
        mode = destination
    }

    /// Shows a section; the sidebar closes so the section is visible.
    func show(_ next: AppMode) {
        sidebarOpen = false
        mode = next
    }

    /// Opens a record in its own section and follows its context (mentions, Search, sidebar). Channels and
    /// conversations open in Chat.
    func openRecord(kind: String, id: String) {
        guard let workspace = selectedWorkspace?.id else { return }
        let record = id.lowercased()
        sidebarOpen = false
        switch kind.lowercased() {
        case "task":
            mode = .tasks; tasksPath.append(.task(workspaceId: workspace, taskId: record))
            adoptContext(for: .task(workspaceId: workspace, taskId: record))
        case "doc", "document":
            mode = .docs; docsPath.append(.doc(workspaceId: workspace, docId: record))
            adoptContext(for: .doc(workspaceId: workspace, docId: record))
        case "file":
            mode = .files; filesPath.append(.file(workspaceId: workspace, fileId: record))
            adoptContext(for: .file(workspaceId: workspace, fileId: record))
        case "channel":
            adoptContext(for: .channel(workspaceId: workspace, channelId: record)); mode = .chat
        case "scope":
            // A scope mention makes that scope the context (as choosing it in the sidebar does).
            if navigation.value.scope(record) != nil { selectContext(WorkContext(scopeId: record, channelId: nil)) }
        case "thread":
            // Focused over the current screen; the view fetches the conversation when it is not stored yet.
            focusThread(ThreadFocus(workspaceId: workspace, channelId: nil, threadId: record))
        case "chat", "message":
            // The web's "FD Ref" for a message: `<channel>#<message>` (or just the message). Its conversation opens when
            // it has one; otherwise the channel does.
            let parts = record.split(separator: "#", maxSplits: 1).map(String.init)
            let channelId = parts.count == 2 ? parts[0] : nil, messageId = parts.last ?? record
            Task { @MainActor in
                let stored = try? await store?.reader.message(workspaceId: workspace, id: messageId)
                let channel = stored?.channelId ?? channelId
                if let channel { openInChat(channelId: channel, threadId: stored?.threadId ?? (stored == nil ? nil : messageId)) }
                else { focusThread(ThreadFocus(workspaceId: workspace, channelId: nil, threadId: messageId)) }
            }
        default:
            return
        }
    }

    /// A channel (and optionally one of its conversations) opened in Chat from Deck: the channel becomes the context,
    /// as the web's Recent channels and channel pins do.
    func openInChat(channelId: String, threadId: String? = nil) {
        guard let workspace = selectedWorkspaceId else { return }
        let scope = navigation.value.channel(channelId)?.scopeId
        guard let scope else { openRecord(kind: "channel", id: channelId); return }
        selectContext(WorkContext(scopeId: scope, channelId: channelId))
        mode = .chat
        if let threadId { focusThread(ThreadFocus(workspaceId: workspace, channelId: channelId, threadId: threadId)) }
    }

    // MARK: Scope and channel management

    /// Reads the member's role and permissions once per workspace (again with `force`), for showing management controls.
    func loadMembership(force: Bool = false) {
        guard let manager, let connection, let workspace = selectedWorkspace, canRead, isUnlocked else { return }
        guard force || membershipWorkspaceId != workspace.id else { return }
        membershipWorkspaceId = workspace.id
        Task {
            let result = try? await manager.membership(connection, workspace)
            guard selectedWorkspace?.id == workspace.id else { return }
            if let result { membership = result } else if membership == nil { membershipWorkspaceId = nil }
        }
    }

    /// Runs one management request for the selected workspace. Errors come back classified for the screen; a result for
    /// a workspace the user has since left is dropped.
    func manage<T: Sendable>(_ body: @escaping @Sendable (ScopeChannelManager, ConnectionRecord, WorkspaceRecord) async throws -> T) async -> Result<T, ManagementError> {
        guard let manager, let connection, let workspace = selectedWorkspace else { return .failure(.unexpected("No workspace is selected.")) }
        do {
            let value = try await body(manager, connection, workspace)
            guard selectedWorkspace?.id == workspace.id else { return .failure(.unexpected("The workspace changed before Tower answered.")) }
            return .success(value)
        } catch let error as ManagementError {
            return .failure(error)
        } catch {
            return .failure(.unexpected(error.localizedDescription))
        }
    }
}
