import AmbulandoCore
import Foundation

/// Alerts outside the app (APNs). The coordinator in AmbulandoCore decides what to register and when; this file gives it
/// the app's connection, workspaces and signer, runs the explicit actions from Settings, and turns a tap on a delivered
/// alert into the same navigation a notification row uses — after the item is fetched again and Tower has re-checked access.
extension AppModel {
    var pushAvailable: Bool { pushCoordinator != nil }

    /// What the coordinator needs right now. Nil binding: no Tower connection (everything registered is withdrawn).
    func pushContext(workspaces listed: [WorkspaceRecord]? = nil) -> PushContext {
        let unlockedSigner: String? = if case .unlocked(let npub) = identity { npub } else { nil }
        guard let connection, let origin = try? TowerOrigin(connection.origin) else { return PushContext(binding: nil, unlockedSigner: unlockedSigner) }
        let known = listed ?? workspaces.value
        let map = Dictionary(known.map { ($0.id.lowercased(), $0.appNpub) }, uniquingKeysWith: { first, _ in first })
        return PushContext(binding: PushBinding(origin: origin, signerNpub: connection.signerNpub, workspaces: map), unlockedSigner: unlockedSigner)
    }

    /// Trigger-driven (launch, unlock, foreground, workspace list change): uploads when unlocked and due, withdraws what
    /// no longer matches. An empty workspace list means "not loaded yet" and is never taken as "left every workspace".
    func reconcilePush(workspaces listed: [WorkspaceRecord]? = nil, force: Bool = false) {
        guard let pushCoordinator else { return }
        let known = listed ?? workspaces.value
        guard connection == nil || !known.isEmpty else { return }
        let context = pushContext(workspaces: known)
        Task {
            await pushCoordinator.reconcile(context: context, force: force)
            pushStatus = await pushCoordinator.status()
        }
    }

    /// "Check again": renews the registration now (unlocked only; signing is still refused while locked) so Tower's current
    /// delivery readiness is read instead of waiting for the lease to reach half-life. One request per workspace per tap.
    func recheckPush() { reconcilePush(force: true) }

    func refreshPushStatus() {
        guard let pushCoordinator else { return }
        Task { pushStatus = await pushCoordinator.status() }
    }

    /// "Enable Notifications": the only place the system permission prompt is ever requested.
    func enablePush() {
        guard let pushCoordinator else { return }
        let context = pushContext()
        Task { pushStatus = await pushCoordinator.enable(context: context) }
    }

    func disablePush() {
        guard let pushCoordinator else { return }
        let context = pushContext()
        Task {
            await pushCoordinator.disable(context: context)
            pushStatus = await pushCoordinator.status()
        }
    }

    /// Before Disconnect or Remove identity: withdraw while the signer still exists.
    func unbindPush() async {
        guard let pushCoordinator else { return }
        await pushCoordinator.unbind(context: pushContext())
        pushStatus = await pushCoordinator.status()
    }

    #if os(iOS)
    /// Cache refresh only: never selects a workspace or invokes the tap/open/read-state path.
    func refreshFromPush(_ payload: PushPayload) async -> PushRefreshWindow.Result {
        await start(pushOnly: true)
        guard !Task.isCancelled, let sync, let connection else { return .noData }
        do {
            let changed = try await sync.refreshAfterPush(payload, connection: connection)
            return changed ? .newData : .noData
        } catch is CancellationError { return .failed }
        catch IdentityError.locked { return .noData }
        catch { return .failed }
    }

    /// Replays missed events for every stored workspace without moving the current UI. Keyed jobs coalesce with SSE.
    func catchUpAfterPushDeferral() {
        guard isActive, let sync, let connection, canRead else { return }
        Task {
            let listed = (try? await sync.store.reader.workspaces(connectionId: connection.id)) ?? []
            guard connection.id == self.connection?.id, canRead else { return }
            for workspace in listed {
                await sync.catchUpEvents(connection, workspace, priority: .background, force: true)
                await sync.refreshNotifications(connection, workspace, priority: .background, force: true)
            }
        }
    }
    #endif

    // MARK: OS callbacks

    func pushTokenReceived(_ token: Data) async {
        await start()
        guard let pushCoordinator else { return }
        await pushCoordinator.tokenReceived(token, context: pushContext())
        pushStatus = await pushCoordinator.status()
    }

    func pushRegistrationFailed(_ error: Error) async {
        await start()
        guard let pushCoordinator else { return }
        await pushCoordinator.registrationFailed(error)
        pushStatus = await pushCoordinator.status()
    }

    // MARK: Foreground and tap

    /// The resource on screen, in the shape a notification payload names, so a banner for it is not shown twice.
    var viewedPushDestination: PushDestination? {
        guard let workspace = selectedWorkspace?.id else { return nil }
        if let focusedThread, let channel = focusedThread.channelId { return .thread(workspaceId: workspace, channelId: channel, threadId: focusedThread.threadId) }
        switch mode {
        case .chat:
            if case .thread(let w, let channel, let thread)? = chatPath.last { return .thread(workspaceId: w, channelId: channel, threadId: thread) }
            return nil
        case .tasks: if case .task(let w, let id)? = tasksPath.last { return .task(workspaceId: w, taskId: id) }
        case .docs: if case .doc(let w, let id)? = docsPath.last { return .doc(workspaceId: w, docId: id) }
        default: break
        }
        return nil
    }

    /// A tap on a delivered alert, from a cold start or while running. The payload is parsed strictly; nothing in it is
    /// trusted beyond naming a destination, which is fetched and access-checked again before anything opens.
    func handlePushTap(_ parsed: PushPayload?) async {
        await start()
        await resolvePushTap(parsed)
    }

    /// After unlock: decide again with the connection as it is now.
    func resumePendingPushTap() {
        guard let held = pendingPushTap else { return }
        pendingPushTap = nil
        guard held.isFresh(now: Date()) else { return }
        Task { await resolvePushTap(held.payload) }
    }

    /// The saved connection as the tap needs it. Workspaces come from the store: on a cold start the observed list may not
    /// have delivered its first value when the OS hands over the tap.
    private func pushTapSnapshot() async -> (PushTapSnapshot, [WorkspaceRecord]) {
        var listed = workspaces.value
        if listed.isEmpty, let store, let connection { listed = (try? await store.reader.workspaces(connectionId: connection.id)) ?? [] }
        let origin = connection.flatMap { try? TowerOrigin($0.origin) }
        return (PushTapSnapshot(connectedOrigin: origin, connectedTowerNpub: connection?.towerNpub,
                                workspaceIds: Set(listed.map(\.id)), isLocked: !isUnlocked), listed)
    }

    /// Selects the workspace and, for an alert that names an inbox item, reads that item fresh from Tower first (one signed
    /// request through the sync owner, never the local cache): only an item Tower still grants opens, through the ordinary
    /// notification route. An unavailable or failed check opens nothing and says so (see `PushTapOutcome`). An alert with only
    /// record ids opens that record the usual way, where its own load checks access.
    private func resolvePushTap(_ payload: PushPayload?) async {
        let (snapshot, listed) = await pushTapSnapshot()
        let sync = sync, connection = connection
        let resolution = await PushTapResolver.resolve(payload, snapshot: snapshot) { workspaceId, notificationId in
            guard let sync, let connection, let workspace = listed.first(where: { $0.id.lowercased() == workspaceId }) else { throw TowerError.unsafePath }
            return try await sync.notificationForTap(connection, workspace, id: notificationId)
        }
        switch resolution {
        case .hold(let held):
            pendingPushTap = PendingPushTap(payload: held, receivedAt: Date())
        case .show(let outcome):
            pushTapOutcome = outcome
        case .openItem(let item):
            selectPushWorkspace(item.workspaceId, in: listed)
            if openNotification(item) == .detail { tapDetail = item }
        case .openRecord(let held):
            selectPushWorkspace(held.workspaceId, in: listed)
            openPushDestination(held)
        }
    }

    private func selectPushWorkspace(_ id: String, in listed: [WorkspaceRecord]) {
        guard let workspace = listed.first(where: { $0.id.lowercased() == id.lowercased() }), selectedWorkspaceId != workspace.id else { return }
        selectWorkspace(workspace.id)
    }

    private func openPushDestination(_ payload: PushPayload) {
        guard let destination = PushRouter.destination(for: payload) else { return }
        switch destination {
        case .task(_, let id): openRecord(kind: "task", id: id)
        case .doc(_, let id): openRecord(kind: "doc", id: id)
        case .thread(_, let channel, let thread): openInChat(channelId: channel, threadId: thread)
        case .threadById(_, let id): openRecord(kind: "thread", id: id)
        case .channel(_, let id): openRecord(kind: "channel", id: id)
        case .notification: break   // handled by the fresh item read
        }
    }
}
