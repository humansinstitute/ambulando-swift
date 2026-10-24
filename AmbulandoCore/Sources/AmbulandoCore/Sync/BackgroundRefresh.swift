import Foundation

/// What one opportunistic background refresh did. Persisted for the Settings screen, so background behaviour is visible
/// rather than assumed.
public struct BackgroundRefreshReport: Codable, Sendable, Equatable {
    public enum Result: String, Codable, Sendable {
        /// Nothing could be signed: the identity is locked and background refresh is not enabled (or was revoked by a
        /// manual lock). No request was made.
        case skippedLocked
        case skippedNoConnection
        case completed
        /// The OS ended the window (or the budget ran out) first; jobs were cancelled, progress so far is kept.
        case expired
        case failed
    }

    public var result: Result
    public var startedAt: Date
    public var finishedAt: Date
    public var workspaces = 0
    public var events = 0
    public var gapRecoveries = 0
    /// Unsent messages/changes were retried (only when the identity was unlocked in memory).
    public var sentPending = false
    public var error: String?

    public static let stateKey = "background.last-refresh"
}

extension WorkspaceSync {
    /// Most workspaces caught up per background window (selected first).
    public static let backgroundWorkspaceLimit = 5
    /// Event pages per workspace per window.
    public static let backgroundPageBudget = 5

    /// The background refresh pipeline: the same keyed, bounded jobs as the foreground, at background priority.
    ///
    /// - With the identity unlocked in memory (the app was suspended, not terminated) everything runs, including unsent
    ///   messages and changes.
    /// - With it locked, only reads run, and only if the user enabled background refresh (the policy-limited credential).
    ///   Unsent items wait for the PIN.
    /// - Cancelling the calling task (BGTask expiration) cancels all jobs; cursors and pages already stored are kept.
    public func backgroundRefresh(_ connection: ConnectionRecord, workspaces: [WorkspaceRecord], outbox: OutboxSender?, writes: WriteSender?,
                                  budget: Duration) async -> BackgroundRefreshReport {
        let started = Date()
        var report = BackgroundRefreshReport(result: .completed, startedAt: started, finishedAt: started)
        do {
            try await identity.requireReader(npub: connection.signerNpub)
        } catch {
            report.result = .skippedLocked
            report.finishedAt = Date()
            await save(report)
            return report
        }
        let targets = Array(workspaces.prefix(Self.backgroundWorkspaceLimit))
        report.workspaces = targets.count
        var before: [String: LiveStatus] = [:]
        for workspace in targets { before[workspace.id] = await live.feed(workspace.id).status }
        for workspace in targets { await catchUpEvents(connection, workspace, pages: Self.backgroundPageBudget, priority: .background) }
        if case .unlocked = await identity.state {
            report.sentPending = true
            await outbox?.kick(connection)
            await writes?.kick(connection)
        }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.engine.waitUntilIdle(); return true }
            group.addTask { try? await Task.sleep(for: budget); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first && !Task.isCancelled
        }
        if !finished {
            await engine.cancelAll()
            report.result = .expired
        }
        for workspace in targets {
            let after = await live.feed(workspace.id).status
            let previous = before[workspace.id] ?? LiveStatus()
            report.events += after.eventsApplied - previous.eventsApplied
            report.gapRecoveries += after.gapRecoveries - previous.gapRecoveries
            if report.result == .completed, let error = after.lastError, after.lastError != previous.lastError {
                report.result = .failed
                report.error = error
            }
        }
        report.finishedAt = Date()
        await save(report)
        return report
    }

    func save(_ report: BackgroundRefreshReport) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) { try? await store.writer.setState(BackgroundRefreshReport.stateKey, String(decoding: data, as: UTF8.self)) }
    }

    public static func decodeReport(_ text: String?) -> BackgroundRefreshReport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.flatMap { try? decoder.decode(BackgroundRefreshReport.self, from: Data($0.utf8)) }
    }
}
