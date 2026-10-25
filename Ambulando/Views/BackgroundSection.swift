import AmbulandoCore
import SwiftUI

/// Settings section that states what background refresh actually does on this iPhone, with the last real outcome.
struct BackgroundSection: View {
    @Environment(AppModel.self) private var model
    let live: LiveStatus?

    var body: some View {
        Section {
            Toggle("Refresh while locked", isOn: Binding(get: { model.backgroundRefreshEnabled },
                                                         set: { on in Task { await model.setBackgroundRefresh(on) } }))
                .disabled(!model.isUnlocked && !model.backgroundRefreshEnabled)
                .accessibilityIdentifier("settings.backgroundRefresh")
            LabeledContent("Live updates", value: live.map(Self.liveLabel) ?? "—")
                .accessibilityIdentifier("settings.liveStatus")
            if let report = model.lastBackgroundReport {
                LabeledContent("Last background refresh") {
                    Text("\(Self.reportLabel(report.result)) · \(report.finishedAt.formatted(date: .omitted, time: .shortened))"
                         + (report.events > 0 ? " · \(report.events) changes" : ""))
                }
                .accessibilityIdentifier("settings.lastBackgroundRefresh")
            }
            if model.backgroundRevocationIncomplete {
                Text("The stored key could not be deleted from the Keychain yet. It is blocked and will not be used; Ambulando retries the deletion.")
                    .font(.amb(.caption)).foregroundStyle(Amb.destructive)
            }
            if let error = model.backgroundScheduleError {
                Text("iOS did not accept a background refresh request: \(error)").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            }
        } header: { Text("Background") } footer: {
            Text(footer)
        }
    }

    private var host: String { model.connection.map { (try? TowerOrigin($0.origin))?.url.host ?? $0.origin } ?? "your Tower" }

    private var footer: String {
        var text = "While Ambulando is open, changes arrive live. In the background, iOS decides if and when the app may refresh "
            + "(opportunistically, never on demand). If the app was only suspended and is still unlocked, that refresh also sends waiting messages. "
            + "Once iOS has ended the app, nothing can be signed without your PIN unless Refresh while locked is on.\n\n"
            + "Refresh while locked keeps a copy of your full signing key on this \(Device.name), outside the PIN-protected vault, in a Keychain item "
            + "that stays on this device and opens after the first unlock following a restart. It is not a separate read-only key: this app "
            + "only allows it to sign requests that fetch updates from \(host) for your workspaces, and still asks for your PIN to send "
            + "anything. Lock now and turning this off remove it."
        if model.backgroundRefreshEnabled && !model.canReadWhileLocked { text += " Paused until you unlock." }
        return text
    }

    static func liveLabel(_ status: LiveStatus) -> String {
        let state = switch status.stream {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .stopped: "Paused"
        case .locked: "Locked"
        case .accessLost: "No access"
        }
        return status.eventsApplied > 0 ? "\(state) · \(status.eventsApplied) changes" : state
    }

    static func reportLabel(_ result: BackgroundRefreshReport.Result) -> String {
        switch result {
        case .completed: "Updated"
        case .expired: "Stopped by iOS"
        case .skippedLocked: "Skipped (locked)"
        case .skippedNoConnection: "Skipped (no Tower)"
        case .failed: "Failed"
        }
    }
}
