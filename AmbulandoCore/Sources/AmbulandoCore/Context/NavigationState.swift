import Foundation

/// Which workspace the app shows for a connection.
public enum WorkspaceSelection {
    /// App-state key set when Tower's workspace list for a connection was stored (in the same transaction).
    public static func listedKey(_ connectionId: String) -> String { "workspaces.listed:\(connectionId)" }

    /// The chosen workspace while Tower still lists it, otherwise the first listed one.
    ///
    /// A choice is persisted only when the user picks a workspace in the switcher, so most people have none. Builds 6
    /// and 7 started the sidebar only for a persisted choice and stayed on "Loading navigation…" without one.
    /// An empty list keeps the choice only while no list has been stored yet (`listComplete` false: first launch,
    /// offline); once Tower has answered with no workspaces, nothing is shown, so a removed workspace cannot linger.
    public static func effective(persisted: String?, listed: [WorkspaceRecord], listComplete: Bool) -> String? {
        if listed.isEmpty { return listComplete ? nil : persisted }
        if let persisted, listed.contains(where: { $0.id == persisted }) { return persisted }
        return listed.first?.id
    }

    public enum Change: Equatable, Sendable {
        /// Nothing to do (the common case: the same list stored again by a refresh).
        case none
        /// The shown workspace is right but its sidebar was never started (no choice at launch, list arrived later).
        case startNavigation(String)
        /// Show another workspace from its Home (the shown one is no longer listed, or none was shown).
        case show(String)
        /// No workspace is listed any more: clear the selection and everything read for it.
        case clear
    }

    /// What a new or re-stored workspace list means for the app, given the shown workspace and the workspace the sidebar
    /// is reading. Re-storing the same list is `.none`, so a refresh never resets context, drafts, boards or scroll.
    public static func change(selected: String?, navigationFor: String?, listed: [WorkspaceRecord], listComplete: Bool) -> Change {
        guard let shown = effective(persisted: selected, listed: listed, listComplete: listComplete) else {
            return selected == nil && navigationFor == nil ? .none : .clear
        }
        if shown != selected { return .show(shown) }
        return navigationFor == shown ? .none : .startNavigation(shown)
    }
}

/// What the sidebar (and the Chat channel list) can honestly say about scopes and channels. Never an empty list
/// without a reason: a failed refresh, a lock or a refresh still running is shown as such.
public enum NavigationLoadState: Equatable, Sendable {
    /// No workspace is stored yet and discovery is running (or about to).
    case findingWorkspaces
    /// No workspace is stored and discovery failed.
    case workspacesFailed(String)
    /// Discovery finished and this identity is a member of no workspace.
    case noWorkspaces
    /// The stored scopes are being read, or nothing is stored yet and a refresh is running.
    case loading
    /// Nothing is stored and the last refresh failed.
    case failed(String)
    /// Nothing is stored and requests cannot be signed (identity locked or sealed).
    case locked
    /// Tower answered and lists no scopes for this member.
    case empty
    /// Scopes are shown. `refreshError` is set when the latest refresh failed, so the list may be out of date.
    case ready(refreshError: String?)

    public struct Inputs: Sendable, Equatable {
        public var hasWorkspace: Bool
        public var workspacesLoaded: Bool
        public var navigationLoaded: Bool
        public var hasScopes: Bool
        public var canRead: Bool
        public var refreshing: Bool
        public var error: String?
        public init(hasWorkspace: Bool, workspacesLoaded: Bool, navigationLoaded: Bool, hasScopes: Bool, canRead: Bool,
                    refreshing: Bool, error: String?) {
            self.hasWorkspace = hasWorkspace; self.workspacesLoaded = workspacesLoaded; self.navigationLoaded = navigationLoaded
            self.hasScopes = hasScopes; self.canRead = canRead; self.refreshing = refreshing; self.error = error
        }
    }

    public static func resolve(_ i: Inputs) -> NavigationLoadState {
        guard i.hasWorkspace else {
            if !i.workspacesLoaded { return .findingWorkspaces }
            if let error = i.error, !i.refreshing { return .workspacesFailed(error) }
            if !i.canRead { return .locked }
            return i.refreshing ? .findingWorkspaces : .noWorkspaces
        }
        if !i.navigationLoaded { return .loading }
        if i.hasScopes { return .ready(refreshError: i.refreshing ? nil : i.error) }
        if i.refreshing { return .loading }
        if let error = i.error { return .failed(error) }
        if !i.canRead { return .locked }
        return .empty
    }
}

extension WorkspaceSync {
    /// Sync keys that feed the sidebar of `workspaceId`: discovery for the connection, its scopes and channel lists.
    public static func isNavigationKey(_ key: String, connectionId: String, workspaceId: String?) -> Bool {
        if key == "discover:\(connectionId)" { return true }
        guard let workspaceId else { return false }
        return key == "scopes:\(workspaceId)" || key.hasPrefix("channels:\(workspaceId):")
    }

    /// Whether sidebar data is being fetched now (scheduled retries waiting for their backoff do not count).
    public static func navigationRefreshing(_ snapshot: SyncSnapshot, connectionId: String, workspaceId: String?) -> Bool {
        snapshot.running.union(snapshot.queued).contains { isNavigationKey($0, connectionId: connectionId, workspaceId: workspaceId) }
    }

    /// The latest failure of a sidebar job, discovery first (without it nothing below can load).
    public static func navigationError(_ snapshot: SyncSnapshot, connectionId: String, workspaceId: String?) -> String? {
        if let error = snapshot.errors["discover:\(connectionId)"] { return error }
        return snapshot.errors.filter { isNavigationKey($0.key, connectionId: connectionId, workspaceId: workspaceId) }
            .sorted { $0.key < $1.key }.first?.value
    }
}
