import Foundation

/// Pending live-update work of one workspace, shared by the foreground event stream and event polls. Both are drained
/// by the single `events:<w>` job, so one workspace's event cursor is only ever advanced by one job at a time.
public actor LiveFeed {
    /// Consecutive stream events: `from` is the cursor the first one follows, `through` the last one's cursor.
    struct Batch: Sendable { var from: String; var through: String; var events: [TowerEvent] }

    private var batch: Batch?
    private var pollPages = 0
    private var pollWaiters: [UUID: CheckedContinuation<EventCatchUp, Error>] = [:]
    /// nil value: waiting for the next poll; a result: finished before anyone awaited it.
    private var pollSlots: [UUID: Result<EventCatchUp, Error>?] = [:]
    /// Set when a stream batch no longer follows the stored cursor; the stream reopens from storage.
    private(set) var needsReconnect = false
    public private(set) var visibleChannelId: String?
    public private(set) var status = LiveStatus()

    public init() {}

    func push(_ event: TowerEvent, after previous: String) {
        if var current = batch, current.through == previous {
            current.events.append(event)
            current.through = event.cursor
            batch = current
        } else if batch == nil {
            batch = Batch(from: previous, through: event.cursor, events: [event])
        } else {
            needsReconnect = true   // the stream skipped: never splice two chains
        }
    }

    func requestPoll(pages: Int) { pollPages = max(pollPages, pages) }

    func take() -> (batch: Batch?, pages: Int) {
        defer { batch = nil; pollPages = 0 }
        return (batch, pollPages)
    }

    /// Puts a batch that failed to apply back in front of anything received meanwhile.
    func restore(_ failed: Batch) {
        if let current = batch, current.from == failed.through {
            batch = Batch(from: failed.from, through: current.through, events: failed.events + current.events)
        } else if batch == nil {
            batch = failed
        } else {
            needsReconnect = true
        }
    }

    func restorePoll(pages: Int) { pollPages = max(pollPages, pages) }

    func takeReconnect() -> Bool { defer { needsReconnect = false }; return needsReconnect }

    func markDiscontiguous() { needsReconnect = true; batch = nil }

    /// Registers interest in the next finished poll before the job is scheduled, so a fast job cannot finish unseen.
    func expectPoll() -> UUID {
        let id = UUID()
        pollSlots[id] = .some(nil)
        return id
    }

    func waitForPoll(_ id: UUID, timeout: Duration) async throws -> EventCatchUp {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resolve(id, .failure(URLError(.timedOut)))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { c in
            if case .some(.some(let done)) = pollSlots[id] { pollSlots[id] = nil; c.resume(with: done); return }
            guard pollSlots[id] != nil else { c.resume(throwing: CancellationError()); return }
            pollWaiters[id] = c
        }
    }

    private func resolve(_ id: UUID, _ result: Result<EventCatchUp, Error>) {
        if let waiter = pollWaiters.removeValue(forKey: id) { pollSlots[id] = nil; waiter.resume(with: result) }
        else if pollSlots[id] != nil { pollSlots[id] = .some(result) }
    }

    func finishPoll(_ result: Result<EventCatchUp, Error>) {
        for id in Array(pollSlots.keys) { resolve(id, result) }
    }

    public func setVisibleChannel(_ id: String?) { visibleChannelId = id }

    func update(_ change: (inout LiveStatus) -> Void) { change(&status) }

    /// Drops queued stream events (workspace switch, lock, stream restart) and fails waiting polls.
    func reset() {
        batch = nil
        needsReconnect = false
        finishPoll(.failure(CancellationError()))
    }
}

/// Observable diagnostics of live updates for one workspace (Settings, tests).
public struct LiveStatus: Sendable, Equatable {
    public enum Stream: String, Sendable { case stopped, connecting, connected, reconnecting, locked, accessLost }
    public var stream: Stream = .stopped
    public var eventsApplied = 0
    public var batches = 0
    public var gapRecoveries = 0
    public var seeded = 0
    public var lastEventAt: Date?
    public var lastError: String?
}

/// Result of one bounded event catch-up.
public struct EventCatchUp: Sendable, Equatable {
    public var pages = 0
    public var events = 0
    /// No stored cursor: started at the current head and caught lists up directly.
    public var seeded = false
    /// More history than the page budget, or a cursor Tower no longer accepts: restarted at the head and scheduled a
    /// full list catch-up instead of replaying.
    public var gapRecovered = false
    /// Tower refused the workspace (403/404): discovery was scheduled to remove it if access is gone.
    public var accessLost = false
    public var complete = false

    public init() {}
}

/// Per-workspace `LiveFeed`s. One per `WorkspaceSync`.
public actor LiveRegistry {
    private var feeds: [String: LiveFeed] = [:]
    public init() {}
    public func feed(_ workspaceId: String) -> LiveFeed {
        if let feed = feeds[workspaceId] { return feed }
        let feed = LiveFeed()
        feeds[workspaceId] = feed
        return feed
    }
}

extension WorkspaceSync {
    public static func eventsKey(_ workspaceId: String) -> String { "events:\(workspaceId)" }
    /// Pages a single catch-up may read before treating the backlog as a gap (200 events per page).
    public static let eventPageBudget = 10
    /// Records fetched at once while applying a batch.
    static let liveFetchConcurrency = 3

    /// Bounded event catch-up from the stored cursor (foreground resume, background refresh, pull to refresh).
    public func catchUpEvents(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, pages: Int = WorkspaceSync.eventPageBudget,
                              priority: SyncPriority = .background, force: Bool = false) async {
        let feed = await live.feed(workspace.id)
        await feed.requestPoll(pages: max(1, pages))
        await scheduleEvents(connection, workspace, priority: priority, force: force)
    }

    /// Like `catchUpEvents`, then waits for that catch-up to finish (the event stream opens only afterwards).
    public func catchUpEventsAndWait(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, pages: Int = WorkspaceSync.eventPageBudget,
                                     priority: SyncPriority = .visible) async throws -> EventCatchUp {
        let feed = await live.feed(workspace.id)
        let slot = await feed.expectPoll()
        await feed.requestPoll(pages: max(1, pages))
        await scheduleEvents(connection, workspace, priority: priority, force: true)
        return try await feed.waitForPoll(slot, timeout: .seconds(180))
    }

    func scheduleEvents(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, priority: SyncPriority, force: Bool = false,
                        delay: Duration? = nil) async {
        let sync = self
        await engine.enqueue(Self.eventsKey(workspace.id), priority: priority, force: force, delay: delay) {
            try await sync.runEvents(connection, workspace)
        }
    }

    /// The `events:<w>` job: applies queued stream events (only if they follow the stored cursor), then any requested
    /// poll. The cursor is saved only after the batch's records are materialised.
    func runEvents(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord) async throws {
        let feed = await live.feed(workspace.id)
        let (batch, pages) = await feed.take()
        do {
            try await identity.requireReader(npub: connection.signerNpub)
            if let batch {
                let stored = try await store.reader.eventCursor(connectionId: connection.id, workspaceId: workspace.id)
                if stored == batch.from {
                    do {
                        try await applyEvents(batch.events, connection, workspace)
                    } catch {
                        await feed.restore(batch)
                        throw error
                    }
                    try await store.writer.saveEventCursor(connectionId: connection.id, workspaceId: workspace.id, batch.through)
                    let count = batch.events.count
                    await feed.update { $0.eventsApplied += count; $0.batches += 1; $0.lastEventAt = Date(); $0.lastError = nil }
                } else {
                    await feed.markDiscontiguous()
                }
            }
            if pages > 0 {
                let result: EventCatchUp
                do { result = try await pollEvents(connection, workspace, pages: pages) }
                catch {
                    if !(error is CancellationError) { await feed.restorePoll(pages: pages) }
                    throw error
                }
                await feed.update {
                    $0.eventsApplied += result.events
                    if result.events > 0 { $0.lastEventAt = Date() }
                    if result.gapRecovered { $0.gapRecoveries += 1 }
                    if result.seeded { $0.seeded += 1 }
                    if result.accessLost { $0.stream = .accessLost }
                    $0.lastError = nil
                }
                await feed.finishPoll(.success(result))
            }
        } catch {
            if pages > 0 { await feed.finishPoll(.failure(error)) }
            if !(error is CancellationError) { await feed.update { $0.lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error) } }
            throw error
        }
    }

    /// Reads event pages from the stored cursor, applying and saving after each page. Stops at a short page, after
    /// `pages` pages (gap recovery) or on cancellation (progress so far is kept).
    func pollEvents(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, pages: Int) async throws -> EventCatchUp {
        let api = api(origin: try TowerOrigin(connection.origin))
        var result = EventCatchUp()
        guard var cursor = try await store.reader.eventCursor(connectionId: connection.id, workspaceId: workspace.id) else {
            try await reseed(connection, workspace, api: api)
            result.seeded = true
            result.complete = true
            return result
        }
        while result.pages < pages {
            try Task.checkCancellation()
            let page: TowerAPI.EventPage
            do {
                page = try await api.events(workspaceId: workspace.id, appNpub: workspace.appNpub, cursor: cursor)
            } catch TowerError.http(400, _, _) {
                // Tower no longer accepts this cursor: restart at the head instead of replaying from zero.
                try await reseed(connection, workspace, api: api)
                result.gapRecovered = true
                result.complete = true
                return result
            } catch TowerError.http(let status, _, _) where status == 403 || status == 404 {
                result.accessLost = true
                await discover(connection, priority: .background, force: true)
                return result
            }
            try Task.checkCancellation()
            result.pages += 1
            if !page.events.isEmpty { try await applyEvents(page.events, connection, workspace) }
            result.events += page.events.count
            if let next = page.nextCursor, next != cursor {
                try await store.writer.saveEventCursor(connectionId: connection.id, workspaceId: workspace.id, next)
                cursor = next
            }
            if page.events.count + page.skipped < TowerAPI.eventPageLimit { result.complete = true; return result }
        }
        // Backlog larger than the budget: skip to the head and catch the lists up directly (bounded, background).
        try await reseed(connection, workspace, api: api)
        result.gapRecovered = true
        result.complete = true
        return result
    }

    /// Starts from the current head and schedules direct catch-up of everything the screens show.
    func reseed(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, api: TowerAPI) async throws {
        let head = try await api.eventHead(workspaceId: workspace.id, appNpub: workspace.appNpub)
        try Task.checkCancellation()
        // The head is saved before the catch-up runs, so changes made meanwhile are replayed, never skipped.
        try await store.writer.saveEventCursor(connectionId: connection.id, workspaceId: workspace.id, head)
        await refreshWorkspace(connection, workspace, priority: .background)
        await refreshInbox(connection, workspace, priority: .background)
        let feed = await live.feed(workspace.id)
        let visible = await feed.visibleChannelId
        for channel in try await store.reader.channels(workspaceId: workspace.id) {
            let priority: SyncPriority = channel.id == visible ? .visible : .background
            // Only channels this phone has read before; others catch up when opened.
            if try await store.reader.channelSync(workspaceId: workspace.id, channelId: channel.id) != nil {
                await catchUpChannel(connection, workspace, channelId: channel.id, priority: priority)
            }
        }
        await refreshTasks(connection, workspace, priority: .background)
        await refreshDocs(connection, workspace, priority: .background)
        await refreshFiles(connection, workspace, priority: .background)
        await refreshPins(connection, workspace, priority: .background)
        await refreshCanvases(connection, workspace, priority: .background)
        await refreshToolbox(connection, workspace, priority: .background)
        await refreshAgents(connection, workspace, channelIds: [], priority: .background)
    }

    /// Applies one ordered batch: tombstones first, then the records it names (visible channel first, bounded
    /// concurrency). Throws if a record could not be read, so the caller keeps the cursor and the batch is replayed.
    public func applyEvents(_ events: [TowerEvent], _ connection: ConnectionRecord, _ workspace: WorkspaceRecord) async throws {
        let plan = EventPlan.make(events, workspaceId: workspace.id)
        try await store.writer.applyTombstones(workspaceId: workspace.id, plan.tombstones)
        let visible = await live.feed(workspace.id).visibleChannelId
        let ordered = plan.refreshes.sorted { Self.rank($0, visible) < Self.rank($1, visible) }
        let api = api(origin: try TowerOrigin(connection.origin))
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            for refresh in ordered {
                if running >= Self.liveFetchConcurrency { try await group.next(); running -= 1 }
                let version = plan.versions[refresh]
                group.addTask { try await self.materialize(refresh, version: version, connection, workspace, api: api, visible: visible) }
                running += 1
            }
            try await group.waitForAll()
        }
    }

    static func rank(_ refresh: EventPlan.Refresh, _ visible: String?) -> Int {
        switch refresh {
        case .message(let c, _), .thread(let c, _), .channelMessages(let c), .reactions(let c, _): c == visible ? 0 : 2
        case .channelTasks(let c), .channelDocs(let c), .channelFiles(let c): c == visible ? 1 : 3
        case .task, .doc: 2
        case .inbox, .pins: 3
        case .agentActivity(let c): c == visible ? 1 : 3
        case .canvas, .contextReferences: 3
        case .structure, .directory, .access, .canvases, .contextTree, .agents, .toolbox: 4
        }
    }

    private func materialize(_ refresh: EventPlan.Refresh, version: Int?, _ connection: ConnectionRecord, _ workspace: WorkspaceRecord,
                             api: TowerAPI, visible: String?) async throws {
        let w = workspace.id, app = workspace.appNpub
        func lost(_ error: Error) -> Bool {
            if case TowerError.http(let status, _, _) = error { return status == 403 || status == 404 }
            return false
        }
        try Task.checkCancellation()
        switch refresh {
        case .message(let channel, let id):
            if let version, let local = try await store.reader.message(workspaceId: w, id: id), local.rowVersion >= version { return }
            if let message = try await api.message(workspaceId: w, appNpub: app, messageId: id) {
                guard message.channelId == channel else { return }   // never file a record under another channel
                try await store.writer.upsertMessages([message])
            } else {
                try await store.writer.applyTombstones(workspaceId: w, [.message(id)])
            }
        case .thread(let channel, let id):
            do {
                let thread = try await api.thread(workspaceId: w, appNpub: app, threadId: id)
                if thread.workspaceId == w, thread.channelId == channel { try await store.writer.upsertThreads(workspaceId: w, [thread]) }
            } catch where lost(error) { try await store.writer.applyTombstones(workspaceId: w, [.thread(id)]) }
        case .channelMessages(let channel):
            try await runChannelCatchUp(connection, workspace, channelId: channel, fromStart: false)
        case .task(let id):
            if let version, let local = try await store.reader.task(workspaceId: w, id: id), local.rowVersion >= version { return }
            do {
                let task = try await api.task(workspaceId: w, appNpub: app, taskId: id)
                try await store.writer.upsertTasks(workspaceId: w, [task])
                let comments = try await api.taskComments(workspaceId: w, appNpub: app, taskId: id)
                try await store.writer.upsertComments(workspaceId: w, comments, complete: (.task, task.id))
            } catch where lost(error) { try await store.writer.applyTombstones(workspaceId: w, [.task(id)]) }
        case .channelTasks(let channel):
            let tasks = try await api.channelTasks(workspaceId: w, appNpub: app, channelId: channel)
            try await store.writer.upsertTasks(workspaceId: w, tasks, completeChannel: channel)
            try await store.writer.saveListSync(workspaceId: w, key: Self.tasksKey(w, channel), complete: true)
        case .doc(let id):
            if let version, let local = try await store.reader.doc(workspaceId: w, id: id), local.rowVersion >= version { return }
            do {
                let doc = try await api.doc(workspaceId: w, appNpub: app, docId: id)
                try await store.writer.upsertDocs(workspaceId: w, [doc])
                // A body kept for offline reading stays current; others are fetched when opened.
                if let cached = try await store.reader.docBody(workspaceId: w, docId: id), cached.docRowVersion < doc.rowVersion {
                    let fetched = try await api.docBody(workspaceId: w, appNpub: app, docId: id)
                    let text = DocumentBody(bytes: fetched.body.bytes, contentType: fetched.body.contentType).markdown
                    try await store.writer.saveDocBody(fetched.body, doc: fetched.doc, searchText: text)
                }
                let comments = try await api.docComments(workspaceId: w, appNpub: app, docId: id)
                try await store.writer.upsertComments(workspaceId: w, comments, complete: (.doc, doc.id))
            } catch where lost(error) { try await store.writer.applyTombstones(workspaceId: w, [.doc(id)]) }
        case .channelDocs(let channel):
            let page = try await api.channelDocs(workspaceId: w, appNpub: app, channelId: channel)
            try await store.writer.upsertDocs(workspaceId: w, page.docs, completeChannel: page.complete ? channel : nil)
            try await store.writer.saveListSync(workspaceId: w, key: Self.docsKey(w, channel), complete: page.complete)
        case .channelFiles(let channel):
            let files = try await api.channelFiles(workspaceId: w, appNpub: app, channelId: channel)
            try await store.writer.upsertFiles(workspaceId: w, files.files, completeChannel: files.complete ? channel : nil)
            let folders = try await api.channelFolders(workspaceId: w, appNpub: app, channelId: channel)
            try await store.writer.upsertFolders(workspaceId: w, channelId: channel, folders.folders, complete: folders.complete)
            try await store.writer.saveListSync(workspaceId: w, key: Self.filesKey(w, channel), complete: files.complete)
        case .reactions(_, let message):
            let list = try await api.reactions(workspaceId: w, appNpub: app, targetType: "message", targetId: message)
            try await store.writer.replaceReactions(workspaceId: w, targets: [message], list)
        case .inbox:
            let states = try await api.viewStates(workspaceId: w, appNpub: app)
            try await store.writer.upsertViewStates(workspaceId: w, states, complete: true)
        case .structure:
            // Scopes/channels are re-listed as their own coalescing job (also run on every foreground resume).
            await refreshWorkspace(connection, workspace, priority: .background)
        case .directory:
            await refreshDirectory(connection, workspace, priority: .background)
        case .access:
            await discover(connection, priority: .background, force: true)
        case .canvases:
            try await store.writer.replaceCanvases(workspaceId: w, try await api.canvases(workspaceId: w, appNpub: app))
        case .canvas(let id):
            // Only canvases this phone has opened are kept current; others are read when opened.
            guard try await store.reader.canvasSnapshot(workspaceId: w, canvasId: id) != nil else { return }
            do {
                let fetched = try await api.canvasSnapshot(workspaceId: w, appNpub: app, canvasId: id)
                try await store.writer.saveCanvasSnapshot(fetched.snapshot, canvas: fetched.canvas)
                for board in CanvasScene.parse(fetched.snapshot.bytes).boards.prefix(Self.boardFetchLimit) {
                    await refreshBoard(connection, workspace, board: board, priority: .background)
                }
            } catch where lost(error) { try await store.writer.removeCanvas(workspaceId: w, id: id) }
        case .contextTree(let scope):
            guard try await store.reader.listSyncComplete(workspaceId: w, key: Self.contextTreeKey(w, scope)) != nil else { return }
            do {
                let components = try await api.contextComponents(workspaceId: w, appNpub: app, scopeId: scope)
                try await store.writer.upsertContextComponents(workspaceId: w, scopeId: scope, components, complete: true)
            } catch where lost(error) { try await store.writer.removeContextTree(workspaceId: w, scopeId: scope) }
        case .contextReferences(let scope, let component):
            guard try await store.reader.listSyncComplete(workspaceId: w, key: Self.contextReferencesKey(w, component)) != nil else { return }
            do {
                let references = try await api.contextReferences(workspaceId: w, appNpub: app, scopeId: scope, componentId: component)
                try await store.writer.replaceContextReferences(workspaceId: w, scopeId: scope, componentId: component, references)
            } catch where lost(error) { try await store.writer.removeContextComponent(workspaceId: w, id: component) }
        case .pins:
            try await store.writer.upsertPins(connectionId: connection.id, workspaceId: w, try await api.personalPins(workspaceId: w, appNpub: app).pins, complete: true)
        case .agents:
            try await store.writer.replaceWorkspaceAgents(workspaceId: w, try await api.workspaceAgents(workspaceId: w, appNpub: app))
        case .agentActivity(let channel):
            guard try await store.reader.listSyncComplete(workspaceId: w, key: Self.agentActivityKey(w, channel)) != nil else { return }
            do {
                try await store.writer.replaceAgentActivities(workspaceId: w, channelId: channel, try await api.agentActivities(workspaceId: w, appNpub: app, channelId: channel))
            } catch where lost(error) { try await store.writer.replaceAgentActivities(workspaceId: w, channelId: channel, []) }
        case .toolbox:
            try await store.writer.replacePersonalWapps(connectionId: connection.id, workspaceId: w, try await api.personalWapps(workspaceId: w, appNpub: app))
        }
    }
}
