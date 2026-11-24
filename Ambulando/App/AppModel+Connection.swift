import AmbulandoCore
import Foundation

/// What Settings shows instead of raw transport errors.
enum ConnectionStatus: Equatable {
    case connected, reconnecting, lost

    var label: String {
        switch self {
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .lost: "Connection lost"
        }
    }
}

extension AppModel {
    /// Connection trouble is either the last request failing or a read that never recovered. While any job is running or
    /// waiting for its backed-off retry the app is reconnecting; with nothing pending it is lost until a trigger or Retry.
    var connectionStatus: ConnectionStatus {
        guard connectionFailing || !syncStatus.connectionFailures.isEmpty else { return .connected }
        // Backed-off loops of live updates are not counted: only running work or a pending read retry is "reconnecting".
        return syncStatus.isIdle && syncStatus.retrying.isEmpty ? .lost : .reconnecting
    }

    /// Follows `ConnectionHealth`. Leaving the failing state is the moment to clear anything still marking an obsolete failure.
    func watchHealth() {
        healthTask?.cancel()
        healthTask = Task { [weak self, health] in
            for await failing in await health.updates() {
                guard let self else { return }
                connectionFailing = failing
                if failing { startProbes() } else {
                    probeTask?.cancel(); probeTask = nil; probesSpent = false
                    // A response came back while reads still wait on long backoffs: refresh them now rather than later.
                    if !syncStatus.connectionFailures.isEmpty { recoverConnection(reason: "response-after-failure") }
                }
            }
        }
    }

    /// Foreground and network return: if the connection was failing (or a read never recovered) refresh what failed, now,
    /// signing afresh. Coalesced: triggers within two seconds of each other, and jobs already pending, run once.
    func recoverConnection(reason: String) {
        guard canRead, connection != nil, connectionFailing || !syncStatus.connectionFailures.isEmpty else { return }
        guard Date().timeIntervalSince(lastRecoveryTrigger) > 2 else { return }
        lastRecoveryTrigger = Date()
        if !reason.hasPrefix("probe") { probesSpent = false }
        if let diagnostics {
            Task { await diagnostics.record(DiagnosticEntry(kind: "trigger", outcome: "recover", note: reason)) }
        }
        refresh(force: true)
        if let sync, let connection, let workspace = selectedWorkspace {
            Task { await sync.refreshInbox(connection, workspace, priority: .visible, force: true) }
        }
        startLive()
    }

    /// Retry in Settings: same recovery, immediately.
    func retryConnection() {
        lastRecoveryTrigger = .distantPast
        kickOutbox(force: true)
        recoverConnection(reason: "retry")
        if !connectionFailing && syncStatus.connectionFailures.isEmpty { refresh(force: true) }
    }

    /// While the connection stays lost with the app active, one probe at 15 s, 30 s, 60 s, 2 min and 4 min, then it waits
    /// for a foreground, network-return or Retry trigger. Never a tight loop.
    func startProbes() {
        guard probeTask == nil, !probesSpent else { return }
        probeTask = Task { [weak self] in
            for seconds in [15, 30, 60, 120, 240] {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                guard isActive, connectionStatus != .connected else { self.probeTask = nil; return }
                recoverConnection(reason: "probe-\(seconds)s")
            }
            self?.probeTask = nil
            self?.probesSpent = true
        }
    }

    /// Per workspace: is authorization verified, are sends open, is data caught up, what is waiting, and why startup last failed.
    /// Counts and codes only. Authorization-ready (access) is reported apart from data-caught-up (data).
    func workspaceStateText() async -> String {
        var lines = ["Workspace state (identity \(isUnlocked ? "unlocked" : "locked"))"]
        for (index, entry) in enabledWorkspaceEntries.enumerated() {
            guard let runtime = entry.runtime else { lines.append("  #\(index + 1): runtime not created"); continue }
            var counts: [String: Int] = [:]
            for item in (try? await runtime.store.reader.outbox(connectionId: entry.connection.id, signerNpub: entry.connection.signerNpub)) ?? [] {
                counts[item.state.rawValue, default: 0] += 1
            }
            let waiting = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            lines.append("  #\(index + 1): access=\(runtime.accessValidated ? "verified" : "pending") data=\(runtime.validated ? "caught-up" : "pending") " +
                         "reads=\(runtime.activity.isEnabled ? "on" : "off") writes=\(runtime.writeActivity.isEnabled ? "open" : "fenced") " +
                         "unsent[\(waiting.isEmpty ? "none" : waiting)] lastStartupFailure=\(runtime.lastStartupFailure ?? "none")")
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// Plain-text export for the share sheet, built only when the user asks.
    func diagnosticsText() async -> String {
        let info = Bundle.main.infoDictionary
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let log = await diagnostics?.exportText(app: info?["CFBundleShortVersionString"] as? String ?? "Unknown",
                                                build: info?["CFBundleVersion"] as? String ?? "Unknown",
                                                platform: Device.name, system: system) ?? "No diagnostics recorded.\n"
        return await workspaceStateText() + log
    }
}
