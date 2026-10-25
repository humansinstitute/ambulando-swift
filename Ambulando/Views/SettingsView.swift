import AmbulandoCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @AppStorage(AppMode.agentsPreference) private var showAgents = false
    @AppStorage(AppMode.contextPreference) private var showContext = false
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
                Group {
                if let account = model.me.value, let npub = model.identity.npub {
                    Section("Profile") { ProfileHeader(account: account, npub: npub) }
                }
                Section("Identity") {
                    LabeledContent("Public key", value: model.identity.npub.map(shortNpub) ?? "None")
                    switch model.identity {
                    case .unlocked: Button("Lock now") { Task { await model.lock() } }
                    case .locked, .none, .unavailable: EmptyView()
                    }
                    if model.identity.npub != nil {
                        Button("Remove identity from this \(Device.name)", role: .destructive) { confirmRemove = true }
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
                Section {
                    Toggle("Public Nostr profiles", isOn: Binding(get: { model.publicProfilesEnabled },
                                                                  set: { on in Task { await model.setPublicProfiles(on) } }))
                        .accessibilityIdentifier("settings.profiles.toggle")
                    Button("Refresh Nostr profiles") { model.refreshProfiles(force: true) }
                        .disabled(!model.publicProfilesEnabled || model.connection == nil)
                        .accessibilityIdentifier("settings.profiles.refresh")
                    LabeledContent("Saved on this \(Device.name)", value: "\(model.me.value?.savedProfiles ?? 0)")
                        .accessibilityIdentifier("settings.profiles.saved")
                } header: { Text("Nostr profiles") } footer: {
                    Text("Names and pictures from people's public Nostr profiles are saved on this \(Device.name) and shown offline. A name set in the workspace comes first. Profiles are read from relay.primal.net, nos.lol and purplepag.es, as in the web app, and each picture is fetched from the address in the profile, which sees this \(Device.name)'s network address. Nothing is signed or sent with them. Turning this off stops all of these requests; saved names and pictures stay until you disconnect.")
                }
                #if os(iOS)
                BackgroundSection(live: live)
                #else
                Section {
                    LabeledContent("Live updates", value: live.map(BackgroundSection.liveLabel) ?? "—")
                        .accessibilityIdentifier("settings.liveStatus")
                } header: { Text("Updates") } footer: {
                    Text("While Ambulando is running on this Mac, changes arrive live and unsent work is retried. Closing the window keeps it running; quitting stops updates until it is opened again.")
                }
                #endif
                if let fixture = model.fixture { FixtureControls(fixture: fixture, model: model) }
                Section {
                    Toggle("Agents", isOn: $showAgents).accessibilityIdentifier("settings.sections.agents")
                    Toggle("Context", isOn: $showContext).accessibilityIdentifier("settings.sections.context")
                } header: { Text("Sections") } footer: {
                    Text("Agents and Context are optional sections, off unless you turn them on, as in the web app. They appear in the \(Device.name == "Mac" ? "sidebar" : "bar at the bottom").")
                }
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
                .ambListRows()
            }
            .scrollContentBackground(.hidden)
            .background(Amb.canvas)   // grouped rows (white) on the recessed surface
            .navigationTitle("Settings")
            .inlineTitle()
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
                     + "Removes saved workspaces, channels, messages and drafts for this Tower from this \(Device.name). Nothing on the server changes.")
            }
        }
    }
}

/// Controls for the local sample data used by UI automation. Only present when the app runs on sample data.
private struct FixtureControls: View {
    @Bindable var fixture: FixtureEnvironment
    let model: AppModel
    var body: some View {
        Section {
            Toggle("Simulate offline", isOn: $fixture.offline).accessibilityIdentifier("fixture.offline")
            Toggle("Reject next send", isOn: $fixture.rejectNextSend).accessibilityIdentifier("fixture.reject")
            Toggle("Fail scope lists", isOn: $fixture.failScopes).accessibilityIdentifier("fixture.failScopes")
            Button("Store workspace list again") { Task { await model.fixtureStoreWorkspacesAgain() } }
                .accessibilityIdentifier("fixture.storeWorkspaces")
            LabeledContent("Context restores", value: "\(model.contextRestores)").accessibilityIdentifier("fixture.restores")
        } header: { Text("Sample data") } footer: {
            Text("This build is running on sample data stored on this \(Device.name). Nothing is sent to a Tower.")
        }
    }
}

/// Avatar, name and where the name comes from (the profile menu header).
private struct ProfileHeader: View {
    let account: AccountProfile
    let npub: String

    private var source: String {
        switch account.person.nameSource {
        case .workspace: "Your name in this workspace"
        case .agent: "Agent name in this workspace"
        case .message: "Name from Tower"
        case .nostr: "From your public Nostr profile"
        case .npub: account.profileCheckedAt == nil ? "Looking for your public profile…" : "No name in this workspace or your public profile"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            PersonAvatar(person: account.person, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.person.name).font(.headline).foregroundStyle(Amb.foreground).accessibilityIdentifier("profile.name")
                Text(source).font(.caption).foregroundStyle(Amb.mutedForeground).accessibilityIdentifier("profile.source")
                if let publicName = account.publicName, account.person.nameSource != .nostr, publicName != account.person.name {
                    Text("Public profile: \(publicName)").font(.caption).foregroundStyle(Amb.mutedForeground)
                        .accessibilityIdentifier("profile.publicName")
                }
                Text(shortNpub(npub)).font(.caption.monospaced()).foregroundStyle(Amb.mutedForeground)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile.header")
    }
}
