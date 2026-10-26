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
        guard let payload = parsed else {
            notice = "That notification could not be opened."
            return
        }
        let origin = connection.flatMap { try? TowerOrigin($0.origin) }
        let ids = Set(workspaces.value.map { $0.id.lowercased() })
        switch PushRouter.decide(payload, connectedOrigin: origin, connectedTowerNpub: connection?.towerNpub, workspaceIds: ids, isLocked: !isUnlocked) {
        case .open: await openPushPayload(payload)
        case .holdUntilUnlock: pendingPushTap = PendingPushTap(payload: payload, receivedAt: Date())
        case .refuse: notice = "That notification isn't for this Ambulando connection."
        }
    }

    /// After unlock: decide again with the connection as it is now.
    func resumePendingPushTap() {
        guard let held = pendingPushTap else { return }
        pendingPushTap = nil
        guard held.isFresh(now: Date()) else { return }
        Task {
            let origin = connection.flatMap { try? TowerOrigin($0.origin) }
            let ids = Set(workspaces.value.map { $0.id.lowercased() })
            if case .open = PushRouter.decide(held.payload, connectedOrigin: origin, connectedTowerNpub: connection?.towerNpub, workspaceIds: ids, isLocked: !isUnlocked) {
                await openPushPayload(held.payload)
            } else { notice = "That notification isn't for this Ambulando connection." }
        }
    }

    /// Selects the workspace and, for an alert that names an inbox item, reads that item fresh from Tower first (one signed
    /// request through the sync owner, never the local cache): only an item Tower still grants opens, through the ordinary
    /// notification route. A 404/403/removed item says so neutrally; a failed check opens nothing and does not fall back to
    /// the cached copy. An alert with only record ids opens that record the usual way, where its own load checks access.
    private func openPushPayload(_ payload: PushPayload) async {
        guard let sync, let connection, let workspace = workspaces.value.first(where: { $0.id.lowercased() == payload.workspaceId }) else {
            notice = "That notification isn't for this Ambulando connection."
            return
        }
        if selectedWorkspaceId != workspace.id { selectWorkspace(workspace.id) }
        guard let notificationId = payload.notificationId else { openPushDestination(payload); return }
        do {
            switch try await sync.notificationForTap(connection, workspace, id: notificationId) {
            case .unavailable:
                notice = "That notification is no longer available to you."
            case .item(let item):
                if openNotification(item) == .detail { tapDetail = item }
            }
        } catch {
            notice = "Could not check that notification just now. Open Notifications to try again."
        }
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
