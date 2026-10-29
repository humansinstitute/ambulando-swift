import AmbulandoCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autopilotAdministrationOrigin") private var autopilotAdministrationOrigin = ""
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @AppStorage(AppMode.agentsPreference) private var showAgents = false
    @AppStorage(AppMode.contextPreference) private var showContext = false
    @State private var showWorkspaceManagement = false
    @State private var confirmRemove = false
    @State private var confirmDisconnect = false
    @State private var unsent = 0
    @State private var live: LiveStatus?

    /// A value from the installed app's Info.plist (the version and build actually running).
    private func bundleValue(_ key: String) -> String { Bundle.main.infoDictionary?[key] as? String ?? "Unknown" }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                if let account = model.me.value, let npub = model.identity.npub {
                    Section("Profile") { ProfileHeader(account: account, npub: npub) }
                }
                if let workspace = model.selectedWorkspace, model.connection != nil {
                    Section("Workspace") {
                        Button("Manage Workspace") { showWorkspaceManagement = true }
                        Text(workspace.label).font(.caption).foregroundStyle(.secondary)
                    }
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
                        ConnectionStatusRow()
                        Button("Refresh now") { model.refresh(force: true) }.disabled(model.identity.npub == nil)
                        Button("Disconnect and clear local data", role: .destructive) {
                            Task { unsent = await model.unsentCount(); confirmDisconnect = true }
                        }
                    }
                }
                Section {
                    TextField("Autopilot HTTPS origin", text: $autopilotAdministrationOrigin)
                } header: { Text("Advanced connection") } footer: {
                    Text("Optional origin for managed app activation. Catalog and activation requests require explicit confirmation before signing to this host. It is a device preference, not a workspace authority grant.")
                }
                Section("Sync") {
                    LabeledContent("Running", value: "\(model.syncStatus.running.count)")
                    LabeledContent("Queued", value: "\(model.syncStatus.queued.count)")
                    ForEach(model.syncStatus.errors.sorted(by: { $0.key < $1.key }), id: \.key) { key, message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.split(separator: ":").first.map(String.init) ?? key).font(.amb(.caption).weight(.semibold))
                            Text(message).font(.amb(.caption)).foregroundStyle(Amb.destructive)
                        }
                    }
                }
                Section {
                    ShareLink(item: DiagnosticsExport(model: model), preview: SharePreview("Ambulando diagnostics")) {
                        Label("Export diagnostics", systemImage: "square.and.arrow.up")
                    }
                        .accessibilityIdentifier("settings.diagnostics.export")
                } header: { Text("Diagnostics") } footer: {
                    Text("Export diagnostics shares a short text log of recent connection attempts: times (UTC), the kind of request, how long it took and the error code. It contains your Tower's address but no keys, messages, names or record ids, and nothing is sent unless you share it.")
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
                NotificationSettingsSection()
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
                    AboutRow(label: "Version", value: bundleValue("CFBundleShortVersionString"), id: "settings.version")
                    AboutRow(label: "Build", value: bundleValue("CFBundleVersion"), id: "settings.build")
                    AboutRow(label: "Platform", value: Device.name, id: "settings.platform")
                    Text("FIPS transport is not part of this build. This app uses HTTPS only; notifications are read from Tower's inbox.")
                        .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                } header: { Text("About") }
                }
                .ambListRows()
            }
            .macGroupedForm()
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
            .sheet(isPresented: $showWorkspaceManagement) {
                if let workspace = model.selectedWorkspace, let connection = model.connection {
                    WorkspaceManagementView(workspace: workspace, connection: connection)
                        .id("\(connection.id):\(workspace.id)")
                        .frame(minWidth: Device.name == "Mac" ? 780 : 0, minHeight: Device.name == "Mac" ? 580 : 0)
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
            Button("Simulate incoming notification") { fixture.tower.simulateNotification() }.accessibilityIdentifier("fixture.notification")
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
                Text(account.person.name).font(.amb(.headline)).foregroundStyle(Amb.foreground).accessibilityIdentifier("profile.name")
                Text(source).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).accessibilityIdentifier("profile.source")
                if let publicName = account.publicName, account.person.nameSource != .nostr, publicName != account.person.name {
                    Text("Public profile: \(publicName)").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                        .accessibilityIdentifier("profile.publicName")
                }
                Text(shortNpub(npub)).font(.amb(.caption).monospaced()).foregroundStyle(Amb.mutedForeground)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile.header")
    }
}

/// An About value that can be selected and copied (for reporting which build is installed).
private struct AboutRow: View {
    let label: String
    let value: String
    let id: String

    var body: some View {
        LabeledContent(label) { Text(value).textSelection(.enabled) }
            .accessibilityIdentifier(id)
    }
}

/// Connection status with Retry: the one place connection trouble is spelled out, instead of raw errors on each screen.
private struct ConnectionStatusRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let status = model.connectionStatus
        LabeledContent("Status") {
            HStack(spacing: 6) {
                if status == .reconnecting { ProgressView().controlSize(.small) }
                Text(status.label).foregroundStyle(status == .lost ? Amb.warning : Amb.foreground)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.connection.status")
        if status != .connected {
            Button("Retry") { model.retryConnection() }
                .accessibilityIdentifier("settings.connection.retry")
        }
    }
}

/// The diagnostics text, built when the share sheet asks for it.
private struct DiagnosticsExport: Transferable {
    let model: AppModel
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { item in
            Data(await item.model.diagnosticsText().utf8)
        }
    }
}
