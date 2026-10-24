import AmbulandoCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @State private var confirmRemove = false
    @State private var confirmDisconnect = false
    @State private var unsent = 0
    @State private var live: LiveStatus?

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    LabeledContent("Public key", value: model.identity.npub.map(shortNpub) ?? "None")
                    switch model.identity {
                    case .unlocked: Button("Lock now") { Task { await model.lock() } }
                    case .locked, .none: EmptyView()
                    }
                    if model.identity != .none {
                        Button("Remove identity from this iPhone", role: .destructive) { confirmRemove = true }
                    }
                }
                if let connection = model.connection {
                    Section("Connection") {
                        LabeledContent("Tower", value: connection.origin)
                        LabeledContent("Transport", value: "HTTPS + NIP-98")
                        LabeledContent("Workspaces", value: "\(model.workspaces.value.count)")
                        Button("Refresh now") { model.refresh(force: true) }.disabled(model.identity.npub == nil)
                        Button("Disconnect and clear local data", role: .destructive) {
                            Task { unsent = await model.unsentCount(); confirmDisconnect = true }
                        }
                    }
                }
                Section("Sync") {
                    LabeledContent("Running", value: "\(model.syncStatus.running.count)")
                    LabeledContent("Queued", value: "\(model.syncStatus.queued.count)")
                    ForEach(model.syncStatus.errors.sorted(by: { $0.key < $1.key }), id: \.key) { key, message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.split(separator: ":").first.map(String.init) ?? key).font(.caption.weight(.semibold))
                            Text(message).font(.caption).foregroundStyle(Amb.destructive)
                        }
                    }
                }
                BackgroundSection(live: live)
                if let fixture = model.fixture { FixtureControls(fixture: fixture) }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppearancePreference.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    LabeledContent("Version", value: version)
                    Text("Push notifications and FIPS transport are not part of this build. Tower provides Web Push only; this app uses HTTPS only.")
                        .font(.caption).foregroundStyle(Amb.mutedForeground)
                } header: { Text("About") }
            }
            .scrollContentBackground(.hidden)
            .background(Amb.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                while !Task.isCancelled {
                    live = await model.liveStatus()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .confirmationDialog("Remove identity?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove identity", role: .destructive) { Task { await model.removeIdentity() } }
            } message: {
                Text("This deletes the encrypted identity from this app only. Keep your own backup of your nsec; Ambulando cannot recover it.")
            }
            .confirmationDialog("Disconnect?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await model.disconnect(); dismiss() } }
            } message: {
                Text((unsent > 0 ? "\(unsent) unsent \(unsent == 1 ? "message" : "messages") will be discarded. " : "")
                     + "Removes saved workspaces, channels, messages and drafts for this Tower from this iPhone. Nothing on the server changes.")
            }
        }
    }
}

/// Controls for the local sample data used by UI automation. Only present when the app runs on sample data.
private struct FixtureControls: View {
    @Bindable var fixture: FixtureEnvironment
    var body: some View {
        Section {
            Toggle("Simulate offline", isOn: $fixture.offline).accessibilityIdentifier("fixture.offline")
            Toggle("Reject next send", isOn: $fixture.rejectNextSend).accessibilityIdentifier("fixture.reject")
        } header: { Text("Sample data") } footer: {
            Text("This build is running on sample data stored on this iPhone. Nothing is sent to a Tower.")
        }
    }
}
