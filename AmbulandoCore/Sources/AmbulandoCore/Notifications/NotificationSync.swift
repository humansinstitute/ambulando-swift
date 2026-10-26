import Foundation

/// The notification read path. It is a keyed `SyncEngine` job like every other read: the workspace's event job
/// (`events:<w>`) only *hints* (a `notification_item` event) and this job fetches. There is no second network loop and no
/// timer of its own; foreground resume, reconnect, background refresh, push wake and pull-to-refresh all schedule the same
/// keyed job, which coalesces.
///
/// Recovery follows Tower's snapshot-then-replay rule: the first `items` page carries `head_seq` read in the same
/// snapshot, the inbox is listed, then `changes` is replayed from that sequence and `local_seq` only ever becomes the
/// `through_seq` of a page that was applied. A `410 reset_required` (or a cursor Tower rejects) lists the inbox again;
/// local changes still waiting to be sent are kept and re-applied over the fresh state.
extension WorkspaceSync {
    public static func notificationsKey(_ workspaceId: String) -> String { "notifications:\(workspaceId)" }
    public static func notificationsArchiveKey(_ workspaceId: String) -> String { "notifications.archive:\(workspaceId)" }

    /// Pages of the inbox listing one job fetches (50 items each). A longer inbox continues in the next job from the stored
    /// cursor and snapshot sequence; the inbox is never declared ready, and `local_seq` never moves, before the listing ends.
    public static let notificationListPageBudget = 20
    /// Times one job restarts a listing (expired cursor, rules changed mid-listing) before it stops and reschedules.
    public static let notificationListRestartBudget = 2
    /// Pages of changes applied in one job before it schedules itself again.
    public static let notificationReplayPageBudget = 25
    /// An unsupported backend is asked again no sooner than this (a Tower upgrade makes the inbox appear).
    public static let notificationUnsupportedRecheck: TimeInterval = 15 * 60
    /// A counts mismatch re-lists the inbox no more often than this.
    public static let notificationDriftResetInterval: TimeInterval = 10 * 60

    /// Schedules the job (coalescing). Safe to call from any trigger.
    public func refreshNotifications(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, priority: SyncPriority = .background, force: Bool = false) async {
        let sync = self
        await engine.enqueue(Self.notificationsKey(workspace.id), priority: priority, force: force, retries: SyncBackoff.readRetries) {
            try await sync.runNotifications(connection, workspace, force: force)
        }
    }

    /// A tap on a delivered alert: reads the item fresh from Tower with the unlocked identity (never a cached copy, never
    /// the read-only background credential) and returns it only if Tower still grants access. Throws on any other failure,
    /// including a locked identity: the caller shows "could not check" and opens nothing. The normal keyed job is scheduled
    /// afterwards, so the local inbox catches up through its one sync owner.
    public func notificationForTap(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, id: String) async throws -> TowerAPI.NotificationLookup {
        try await identity.requireSigner(npub: connection.signerNpub)
        let lookup = try await api(origin: try TowerOrigin(connection.origin))
            .notificationLookup(workspaceId: workspace.id, appNpub: workspace.appNpub, id: id)
        await refreshNotifications(connection, workspace, priority: .visible, force: true)
        return lookup
    }

    /// Outcome of one job, for tests and diagnostics.
    public struct NotificationRun: Sendable, Equatable {
        public var listed = 0
        public var replayed = 0
        public var pages = 0
        public var coldStart = false
        public var unsupported = false
        public var accessLost = false
        public var skippedByRecheck = false
        public var reschedule = false
    }

    @discardableResult
    func runNotifications(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, force: Bool = false,
                          listBudget: Int = WorkspaceSync.notificationListPageBudget, continueListing: Bool = true) async throws -> NotificationRun {
        try await identity.requireReader(npub: connection.signerNpub)
        let w = workspace.id, c = connection.id
        let api = api(origin: try TowerOrigin(connection.origin))
        var run = NotificationRun()
        var status = try await store.reader.notificationStatus(connectionId: c, workspaceId: w)
        if status.state == .unsupported, !force, let checked = Self.parseStamp(status.checkedAt), Date().timeIntervalSince(checked) < Self.notificationUnsupportedRecheck {
            run.skippedByRecheck = true
            return run
        }
        do {
            if status.state != .ready || status.hydrating {
                try await hydrateNotifications(connection, workspace, api: api, budget: listBudget, run: &run)
                status = try await store.reader.notificationStatus(connectionId: c, workspaceId: w)
                // Unfinished listing: the next job resumes it; nothing is replayed or reconciled against a partial list.
                if status.state != .ready || status.hydrating {
                    run.reschedule = true
                    if continueListing { await refreshNotifications(connection, workspace, priority: .background, force: true) }
                    return run
                }
            }
            try await replayNotifications(connection, workspace, api: api, from: status.localSeq, rulesRevision: status.rulesRevision, run: &run)
            let counts = try await api.notificationCounts(workspaceId: w, appNpub: workspace.appNpub)
            try Task.checkCancellation()
            try await store.writer.saveNotificationCounts(connectionId: c, workspaceId: w, counts)
            // Rules changed (here or on another device) since this snapshot: the visible set differs, so list again.
            if let current = counts.rulesRevision, let stored = status.rulesRevision, current != stored {
                try await store.writer.resetNotificationCursor(connectionId: c, workspaceId: w)
                run.reschedule = true
            } else {
                try await repairDrift(connection, workspace, counts: counts)
            }
        } catch TowerAPI.NotificationReadFailure.unsupported {
            run.unsupported = true
            try await store.writer.markNotificationSync(connectionId: c, workspaceId: w, state: .unsupported)
            return run
        } catch TowerAPI.NotificationReadFailure.forbidden {
            // Access to this workspace is gone: nothing of its inbox stays on the device.
            run.accessLost = true
            try await store.writer.purgeNotifications(connectionId: c, workspaceId: w)
            await discover(connection, priority: .background, force: true)
            return run
        } catch TowerAPI.NotificationReadFailure.resetRequired {
            // Replay was refused after a successful listing (or the listing's own cursor expired): list again next time.
            try await store.writer.resetNotificationCursor(connectionId: c, workspaceId: w)
            run.reschedule = true
        } catch {
            if !(error is CancellationError) {
                try? await store.writer.markNotificationSync(connectionId: c, workspaceId: w, state: nil, error: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
            throw error
        }
        if run.reschedule {
            await refreshNotifications(connection, workspace, priority: .background, force: true)
        }
        return run
    }

    /// Lists the inbox, resumably. The first page of a listing fixes the snapshot sequence `S` and a generation; every page
    /// is stored as it arrives with the cursor to continue from, so a job that stops at its budget (or is cancelled, or the
    /// app is killed) resumes at that cursor and keeps the original `S`. Only the last page finishes the listing: then the
    /// rows it did not mention leave the inbox, `local_seq = S`, and replay starts. A cursor Tower rejects (expired) restarts
    /// the listing from the first page with a new `S`.
    private func hydrateNotifications(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, api: TowerAPI, budget: Int,
                                      run: inout NotificationRun) async throws {
        run.coldStart = true
        let c = connection.id, w = workspace.id
        let status = try await store.reader.notificationStatus(connectionId: c, workspaceId: w)
        var gen = status.hydrateGen
        var cursor: String? = status.hydrating ? status.hydrateCursor : nil
        // A listing in progress has a snapshot but may not have stored its first cursor (killed after page one): that is a
        // resume only when a cursor exists; otherwise the first page is fetched again under a new snapshot.
        var resumed = status.hydrating && cursor != nil
        var startedAt: String?
        // The rules revision this listing is computed under: pages that disagree are not one snapshot.
        var snapshotRevision: Int? = resumed ? status.rulesRevision : nil
        var fetched = 0
        var restarts = 0
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            let page: TowerAPI.NotificationPage
            do {
                page = try await api.notificationItems(workspaceId: w, appNpub: workspace.appNpub, view: "inbox", cursor: resumed ? cursor : nil)
            } catch TowerAPI.NotificationReadFailure.resetRequired where resumed {
                // The saved cursor expired: start over from the first page, a bounded number of times per job.
                restarts += 1
                if restarts > Self.notificationListRestartBudget { run.reschedule = true; return }
                resumed = false; cursor = nil
                continue
            }
            if resumed, let first = snapshotRevision, let now = page.rulesRevision, now != first {
                // The person's rules changed mid-listing: items of the earlier pages were filtered differently. Start over,
                // but churn never spins a job: past the restart budget the listing stays unfinished (not ready) for the next job.
                restarts += 1
                if restarts > Self.notificationListRestartBudget { run.reschedule = true; return }
                resumed = false; cursor = nil; snapshotRevision = nil
                continue
            }
            if !resumed {
                snapshotRevision = page.rulesRevision
                gen = try await store.writer.beginNotificationHydration(connectionId: c, workspaceId: w, snapshotSeq: page.headSeq, rulesRevision: page.rulesRevision)
                resumed = true
            }
            startedAt = page.inboxStartedAt ?? startedAt
            guard try await store.writer.storeNotificationHydrationPage(connectionId: c, workspaceId: w, gen: gen, items: page.items, nextCursor: page.nextCursor) else {
                run.reschedule = true; return     // superseded by a reset: the next job lists again
            }
            run.listed += page.items.count
            fetched += 1
            guard let next = page.nextCursor else {
                try await store.writer.finishNotificationHydration(connectionId: c, workspaceId: w, gen: gen, startedAt: startedAt)
                return
            }
            guard seen.insert(next).inserted else { throw TowerError.malformed("notification cursor") }
            cursor = next
            if fetched >= budget { return }       // the stored cursor and S carry the listing into the next job
        }
    }

    private func replayNotifications(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, api: TowerAPI, from start: Int, rulesRevision: Int?, run: inout NotificationRun) async throws {
        var after = start
        for _ in 0..<Self.notificationReplayPageBudget {
            try Task.checkCancellation()
            let page = try await api.notificationChanges(workspaceId: workspace.id, appNpub: workspace.appNpub, afterSeq: after, rulesRevision: rulesRevision)
            run.pages += 1
            // The cursor moves to what this page really delivered, never to the head. A page that delivered nothing but
            // claims more is a Tower fault: stop instead of looping.
            if page.throughSeq < after || (page.hasMore && page.throughSeq == after) { throw TowerError.malformed("notification changes") }
            try await store.writer.applyNotificationChanges(connectionId: connection.id, workspaceId: workspace.id, page.changes,
                                                            throughSeq: page.throughSeq, headSeq: page.headSeq)
            run.replayed += page.changes.count
            after = page.throughSeq
            if !page.hasMore { return }
        }
        run.reschedule = true
    }

    /// Tower's unread count wins over a locally derived one when nothing is waiting to be sent: a mismatch means the
    /// device missed or misapplied something, so the inbox is listed again (rarely, never in a loop).
    private func repairDrift(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, counts: NotificationCounts) async throws {
        let c = connection.id, w = workspace.id
        guard try await store.reader.pendingNotificationIds(connectionId: c, workspaceId: w).isEmpty else { return }
        let local = try await store.reader.notificationUnreadCount(connectionId: c, workspaceId: w)
        guard local != min(counts.unreadTotal, counts.cappedAt), counts.unreadTotal < counts.cappedAt else { return }
        let status = try await store.reader.notificationStatus(connectionId: c, workspaceId: w)
        if let last = Self.parseStamp(status.resetAt), Date().timeIntervalSince(last) < Self.notificationDriftResetInterval { return }
        try await store.writer.resetNotificationCursor(connectionId: c, workspaceId: w)
        await refreshNotifications(connection, workspace, priority: .background, force: true)
    }

    /// The archived partition, fetched only when the user asks for it and resumable like the inbox: a page budget per job, the
    /// cursor stored with the rows, nothing silently capped. From the first page on, `changes` keeps archived items current.
    public func loadArchivedNotifications(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, pages: Int = WorkspaceSync.notificationListPageBudget) async {
        let sync = self
        await engine.enqueue(Self.notificationsArchiveKey(workspace.id), priority: .user, force: true) {
            try await sync.identity.requireReader(npub: connection.signerNpub)
            let api = sync.api(origin: try TowerOrigin(connection.origin))
            let c = connection.id, w = workspace.id
            let status = try await sync.store.reader.notificationStatus(connectionId: c, workspaceId: w)
            if status.archivedHydrated, !status.archiveIncomplete { return }
            var cursor = status.archivedHydrated ? status.archiveCursor : nil
            var seen = Set<String>()
            for _ in 0..<pages {
                try Task.checkCancellation()
                let page: TowerAPI.NotificationPage
                do { page = try await api.notificationItems(workspaceId: w, appNpub: workspace.appNpub, view: "archived", cursor: cursor) }
                catch TowerAPI.NotificationReadFailure.unsupported { return }
                catch TowerAPI.NotificationReadFailure.resetRequired where cursor != nil {
                    try await sync.store.writer.resetArchivedNotificationCursor(connectionId: c, workspaceId: w)
                    cursor = nil
                    continue
                }
                try await sync.store.writer.storeArchivedNotifications(connectionId: c, workspaceId: w, items: page.items, nextCursor: page.nextCursor)
                guard let next = page.nextCursor else { return }
                guard seen.insert(next).inserted else { throw TowerError.malformed("notification cursor") }
                cursor = next
            }
            // Budget used with pages left: continue as a new job from the stored cursor.
            await sync.loadArchivedNotifications(connection, workspace, pages: pages)
        }
    }

    static func parseStamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// Preferences are fetched and written directly (not through the inbox job): they are small, server-owned, and a failure is
/// shown to the person instead of being retried silently. Writing needs the unlocked identity; reading needs only read ability.
extension WorkspaceSync {
    public func loadNotificationPreferences(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord) async throws -> NotificationPreferences {
        try await identity.requireReader(npub: connection.signerNpub)
        return try await api(origin: try TowerOrigin(connection.origin)).notificationPreferences(workspaceId: workspace.id, appNpub: workspace.appNpub)
    }

    /// Turns one category's inbox on or off *for this app's view* (`client_app_id = ambulando`); the shared item and what other apps
    /// show are untouched. One compare-and-set write on the exact key. If the key changed elsewhere (`rules_conflict`) nothing is
    /// written and the current rules are returned inside `changedElsewhere`: the screen shows the actual choices and the person
    /// chooses again (a new `mutation_id`); a simultaneous choice made on another device is never silently overwritten.
    public func setNotificationInboxRule(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, category: NotificationCategoryInfo, on: Bool,
                                         known: NotificationPreferences) async throws -> NotificationPreferences {
        guard !category.mandatory else { throw NotificationPreferenceError.mandatory }
        try await identity.requireSigner(npub: connection.signerNpub)
        let api = api(origin: try TowerOrigin(connection.origin))
        let client = TowerAPI.notificationClientAppId
        let rule = NotificationRule(sourceAppId: category.sourceAppId, category: category.category, clientAppId: client, channel: "inbox", mode: on ? "on" : "off")
        let expected = known.rowVersion(source: rule.sourceAppId, category: rule.category, clientAppId: client, channel: "inbox")
        switch try await api.putNotificationRules(workspaceId: workspace.id, appNpub: workspace.appNpub, mutationId: UUID().uuidString.lowercased(), [(rule, expected)]) {
        case .applied(let rules, let revision):
            var updated = known
            updated.rules = rules; updated.rulesRevision = revision
            // The visible set changed: the inbox lists again under the new revision (the one sync owner).
            await refreshNotifications(connection, workspace, priority: .visible, force: true)
            return updated
        case .conflict(let rules, let revision):
            var current = known
            current.rules = rules; current.rulesRevision = revision
            throw NotificationPreferenceError.changedElsewhere(current)
        case .mutationReused:
            throw NotificationPreferenceError.rejected
        }
    }
}

public enum NotificationPreferenceError: LocalizedError, Sendable {
    case mandatory
    /// The rules changed elsewhere twice in a row; these are the current ones.
    case changedElsewhere(NotificationPreferences)
    case rejected
    public var errorDescription: String? {
        switch self {
        case .mandatory: "This kind of notification can't be turned off."
        case .changedElsewhere: "These choices were changed on another device. They are shown as they are now; choose again if you still want to change this."
        case .rejected: "That change was rejected. Nothing was changed."
        }
    }
}
