import AmbulandoCore
import SwiftUI

/// Shared native administration. Every presented editor is pinned to the connection and workspace that opened it.
struct WorkspaceManagementView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showScopes = false
    @State private var selection: WorkspaceManagementSection? = .workspace
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord

    init(workspace: WorkspaceRecord, connection: ConnectionRecord, initialSection: WorkspaceManagementSection = .workspace) {
        self.workspace = workspace; self.connection = connection
        _selection = State(initialValue: initialSection)
    }

    var body: some View {
        Group {
            if model.selectedWorkspace?.id != workspace.id || model.connection?.id != connection.id {
                ContentUnavailableView("Workspace changed", systemImage: "arrow.triangle.2.circlepath", description: Text("Close management and reopen it for the selected workspace."))
            } else {
                #if os(macOS)
                NavigationSplitView {
                    List(WorkspaceManagementSection.allCases, selection: $selection) { section in
                        Label(section.title, systemImage: section.icon).tag(section).accessibilityIdentifier("admin.section.\(section.rawValue)")
                    }.navigationTitle(workspace.label)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                } detail: {
                    NavigationStack { detail(selection ?? .workspace)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                    }
                }
                #else
                NavigationStack {
                    List {
                        Section {
                            Label(workspace.label, systemImage: "building.2").font(.headline)
                            Text("Workspace administration").foregroundStyle(.secondary)
                        }
                        ForEach(WorkspaceManagementSection.allCases) { section in
                            NavigationLink { detail(section) } label: { Label(section.title, systemImage: section.icon) }.accessibilityIdentifier("admin.section.\(section.rawValue)")
                        }
                    }
                    .navigationTitle("Manage Workspace")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                }
                #endif
            }
        }
        .task { model.loadMembership(force: true) }
        .sheet(isPresented: $showScopes) { ScopeManagementSheet() }
        .accessibilityIdentifier("workspace.management")
    }

    @ViewBuilder private func detail(_ section: WorkspaceManagementSection) -> some View {
        WorkspaceAdministrationPage(section: section, workspace: workspace, connection: connection, showScopes: $showScopes)
            .id("\(connection.id):\(workspace.id):\(section.rawValue)")
    }
}

enum WorkspaceManagementSection: String, CaseIterable, Identifiable {
    case workspace, scopes, members, groups, permissions, apps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .scopes: "Scopes & Channels"
        case .members: "Members"
        case .groups: "Groups"
        case .permissions: "Permissions"
        case .apps: "Apps & Integrations"
        }
    }
    var icon: String {
        switch self {
        case .workspace: "building.2"
        case .scopes: "square.stack.3d.up"
        case .members: "person.2"
        case .groups: "person.3"
        case .permissions: "lock.shield"
        case .apps: "app.connected.to.app.below.fill"
        }
    }
}

private struct WorkspaceAdministrationPage: View {
    @Environment(AppModel.self) private var model
    let section: WorkspaceManagementSection
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    @Binding var showScopes: Bool
    @State private var members = LiveQuery<[AdministrationRow]>(initial: [])
    @State private var groups = LiveQuery<[AdministrationRow]>(initial: [])
    @State private var delegations = LiveQuery<[AdministrationRow]>(initial: [])
    @State private var installations = LiveQuery<[AdministrationRow]>(initial: [])
    @State private var publishing = LiveQuery<[AdministrationRow]>(initial: [])
    @State private var phase = ManagementPhase.idle
    @State private var pending: AdministrationCommand?
    private var admin: Bool { model.membership?.isAdmin == true }

    var body: some View {
        List {
            Section {
                WorkspaceIdentityHeader(workspace: workspace)
                Text("\(model.connectionStatus.label) · Changes require a connection. Saved lists may be out of date.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refresh access and lists") { Task { await refresh() } }.disabled(phase.isWorking)
            }
            if !admin {
                Section { Text(model.membership == nil ? "Checking your access…" : "Read only. Workspace administrator access is required for these controls. Scope management uses your scope permissions.") }
            }
            sectionContent
        }
        .navigationTitle(section.title)
        .modifier(ManagementStatusInset(phase: phase))
        .confirmationDialog("Remove access?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Remove access", role: .destructive) { if let command = pending { pending = nil; Task { await run(command) } } }
        } message: { Text("Tower will remove the selected membership, delegation or installation authority immediately. Content is not deleted. Other grants may still provide access.") }
        .task {
            guard let store = model.store else { return }
            observe(members, .members, store); observe(groups, .groups, store)
            observe(delegations, .delegations, store); observe(installations, .installations, store); observe(publishing, .publishing, store)
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard model.selectedWorkspace?.id == workspace.id, model.connection?.id == connection.id else { return }
                await refresh()
            }
        }
        .onDisappear { members.stop(); groups.stop(); delegations.stop(); installations.stop(); publishing.stop() }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .workspace: workspaceContent
        case .scopes: scopesContent
        case .members: membersContent
        case .groups: groupsContent
        case .permissions: permissionsContent
        case .apps: appsContent
        }
    }
    @ViewBuilder private var workspaceContent: some View {
                Section("Workspace identity") {
                    WorkspaceIdentityHeader(workspace: workspace)
                    editor("Edit name, description and avatar", .profile)
                    Text(workspace.ownerNpub ?? "Owner unavailable").font(.caption).textSelection(.enabled)
                    NavigationLink("Delete workspace…") { WorkspaceDangerZone(workspace: workspace, connection: connection) }.disabled(!admin)
                }

    }

    @ViewBuilder private var scopesContent: some View {
                Section {
                    Button("Manage scopes and your scope order") { showScopes = true }
                    NavigationLink("New scope with starting channels") { ScopeSetupView(workspace: workspace, connection: connection) }
                        .disabled(!ManagementPermissions.canCreateScope(model.membership))
                    ForEach(model.navigation.value.groups) { group in
                        NavigationLink(group.scope.name) {
                            List {
                                ForEach(group.channels) { channel in
                                    NavigationLink(channel.name) { ChannelSettingsSheet(channelId: channel.id) }
                                }
                                if ManagementPermissions.canCreateChannel(in: group.scope, membership: model.membership) {
                                    NavigationLink("New channel") { NewChannelSheet(scope: group.scope, onCreated: { _ in }) }
                                }
                            }.navigationTitle(group.scope.name)
                        }
                    }
                }

    }

    @ViewBuilder private var membersContent: some View {
                Section { editor("Add workspace member", .member) }
                Section("Workspace members") {
                    ForEach(members.value) { row in
                        VStack(alignment: .leading) {
                            Text(row.title); Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            editor("Edit display name", .memberProfile(row))
                        }
                    }
                    if members.value.isEmpty { Text("No saved members. Refresh to load the directory.").foregroundStyle(.secondary) }
                }

    }

    @ViewBuilder private var groupsContent: some View {
                Section { editor("New group", .group) }
                ForEach(groups.value) { group in
                    Section(group.title) {
                        Text(group.detail).font(.caption).foregroundStyle(.secondary)
                        editor("Add member", .groupMember(group.id))
                        editor("Add child group", .childGroup(group.id, false))
                        editor("Remove child group", .childGroup(group.id, true))
                        ForEach(group.childGroupIds, id: \.self) { child in
                            Text("Child group: " + (groups.value.first(where: { $0.id == child })?.title ?? child)).font(.caption)
                        }
                        ForEach(group.children) { member in
                            HStack {
                                VStack(alignment: .leading) { Text(member.title); Text(member.detail).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if admin { Button("Remove", role: .destructive) { pending = .removeGroupMember(group: group.id, actor: member.id) } }
                            }
                        }
                    }
                }
                if groups.value.isEmpty { Text("No saved groups. Refresh to load groups.").foregroundStyle(.secondary) }

    }

    @ViewBuilder private var permissionsContent: some View {
                Section("Scope access") {
                    ForEach(model.navigation.value.groups) { group in
                        NavigationLink(group.scope.name) { ScopeAccessAdministrationPage(scope: group.scope, workspace: workspace, connection: connection) }
                    }
                }
                Section("Channel access") {
                    ForEach(model.navigation.value.groups.flatMap(\.channels)) { channel in
                        NavigationLink(channel.name) {
                            ChannelAdministrationPage(channel: channel, workspace: workspace, connection: connection, members: members.value, groups: groups.value)
                        }
                    }
                }
                Section("Your workspace permissions") {
                    ForEach(Array(model.membership?.permissions ?? []).sorted(), id: \.self) { Text($0).font(.caption) }
                }

    }

    @ViewBuilder private var appsContent: some View {
                Section {
                    editor("Grant narrow app management", .delegation)
                    NavigationLink("Activate managed app") { ManagedAppActivationView(workspace: workspace, connection: connection, delegations: delegations.value) }
                    editor("Add publishing installation", .publishing(nil))
                }
                Section("Publishing installations") {
                    ForEach(publishing.value) { row in
                        VStack(alignment: .leading) {
                            Text(row.title); Text(row.detail).font(.caption)
                            editor("Edit publishing destinations", .publishing(row))
                            editor("Rotate publisher public key", .rotation(row))
                            if admin {
                                Button("Disable publishing", role: .destructive) { pending = .disablePublishing(id: row.id) }
                                Button("Revoke publishing and open links", role: .destructive) { pending = .revokePublishing(id: row.id) }
                            }
                        }
                    }
                    if publishing.value.isEmpty { Text("No saved publishing installations").foregroundStyle(.secondary) }
                }
                Section("Delegations") {
                    ForEach(delegations.value) { row in
                        VStack(alignment: .leading) {
                            Text(members.value.first(where: { $0.id == row.fields["delegate_actor_id"] })?.title ?? row.title)
                            Text(row.detail).font(.caption)
                            ForEach(row.filters.keys.sorted(), id: \.self) { key in
                                Text(key.replacingOccurrences(of: "_", with: " ").capitalized + ": " + (row.filters[key] ?? []).map { filterLabel($0, key: key) }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                            if admin { Button("Revoke delegation", role: .destructive) { pending = .revokeDelegation(id: row.id) } }
                        }
                    }
                    if delegations.value.isEmpty { Text("No saved delegations").foregroundStyle(.secondary) }
                }
                Section("Managed installations") {
                    ForEach(installations.value) { row in
                        VStack(alignment: .leading) {
                            Text(row.title); Text(row.detail).font(.caption)
                            if admin || AdministrationAuthority.hasInstallationDelegation(actor: model.membership?.actorId ?? "", installation: row.id, delegations: delegations.value, installationData: row) {
                                Button("Reconcile installation") { Task { await run(.installation(id: row.id, revoke: false)) } }
                                Button("Revoke installation", role: .destructive) { pending = .installation(id: row.id, revoke: true) }
                            }
                        }
                    }
                    if installations.value.isEmpty { Text("No saved installations").foregroundStyle(.secondary) }
                }
    }

    private func filterLabel(_ value: String, key: String) -> String {
        if key == "scope_ids" { return model.navigation.value.groups.first { $0.scope.id == value }?.scope.name ?? "Unavailable scope" }
        if key == "channel_ids" { return model.navigation.value.groups.flatMap(\.channels).first { $0.id == value }?.name ?? "Unavailable channel" }
        return value
    }
    private func editor(_ title: String, _ operation: AdministrationEditorKind) -> some View {
        NavigationLink(title) {
            AdministrationEditor(kind: operation, workspace: workspace, connection: connection, members: members.value, groups: groups.value)
        }.disabled(!admin || phase.isWorking).accessibilityIdentifier("admin.editor.\(operation.key)")
    }
    private func directory(_ rows: [AdministrationRow], empty: String) -> some View {
        Section {
            ForEach(rows) { row in VStack(alignment: .leading) { Text(row.title); Text(row.detail).font(.caption).foregroundStyle(.secondary) } }
            if rows.isEmpty { Text(empty).foregroundStyle(.secondary) }
        }
    }
    private func observe(_ query: LiveQuery<[AdministrationRow]>, _ list: AdministrationList, _ store: LocalStore) {
        let c = connection.id, w = workspace.id
        query.start(store: store, matches: { $0.table == .appState || $0.table == .access }, load: {
            try await store.reader.administrationRows(connection: c, workspace: w, list: list)
        })
    }
    private func refresh() async {
        model.loadMembership(force: true)
        guard let manager = model.manager else { return }
        phase = .working("Refreshing…")
        let lists: [AdministrationList] = section == .apps ? [.members, .delegations, .installations, .publishing] : [.members, .groups]
        var failures: [String] = []
        for list in lists {
            do { try await manager.refreshAdministration(connection, workspace, list: list) }
            catch { failures.append("\(list.rawValue): \(error.localizedDescription)") }
        }
        phase = failures.isEmpty ? .idle : .failed(.unexpected(failures.joined(separator: "\n")))
    }
    private func run(_ command: AdministrationCommand) async {
        guard model.selectedWorkspace?.id == workspace.id, model.connection?.id == connection.id, let manager = model.manager else { return }
        phase = .working("Waiting for Tower…")
        do {
            try await manager.administer(connection, workspace, command: command)
            await refresh()
            if phase == .idle { phase = .done("Saved on Tower.") }
        } catch { model.loadMembership(force: true); phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)) }
    }
}

private struct ChannelAdministrationPage: View {
    @Environment(AppModel.self) private var model
    let channel: ChannelRecord
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    let members: [AdministrationRow]
    let groups: [AdministrationRow]
    @State private var canManage = false
    @State private var query = LiveQuery<[AdministrationRow]>(initial: [])
    @State private var phase = ManagementPhase.idle
    @State private var pending: AdministrationRow?

    var body: some View {
        List {
            Section {
                Text(workspace.label).font(.caption)
                NavigationLink("Grant access") { AdministrationEditor(kind: .grant(channel.id, nil), workspace: workspace, connection: connection, members: members, groups: groups, channelAuthority: canManage) }
                    .disabled(!canManage)
                Button("Refresh channel access") { Task { await refresh() } }
            }
            ForEach(query.value) { row in
                Section(row.title) {
                    Text(row.detail).font(.caption)
                    if canManage {
                        NavigationLink("Change access") { AdministrationEditor(kind: .grant(channel.id, row), workspace: workspace, connection: connection, members: members, groups: groups, channelAuthority: canManage) }
                        Button("Revoke access", role: .destructive) { pending = row }
                    }
                }
            }
        }.navigationTitle(channel.name)
        .modifier(ManagementStatusInset(phase: phase))
        .task {
            if let store = model.store {
                let key = "admin.channel-grants.v1:\(connection.id):\(workspace.id):\(channel.id)"
                query.start(store: store, matches: { $0.table == .appState || $0.table == .access }, load: {
                    guard let raw = try await store.reader.state(key) else { return [] }
                    return try JSONDecoder().decode([AdministrationRow].self, from: Data(raw.utf8))
                })
            }
            await refresh()
        }
        .onDisappear { query.stop(); canManage = false }
        .confirmationDialog("Revoke this channel grant?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Revoke access", role: .destructive) {
                guard let row = pending else { return }; pending = nil
                Task {
                    guard let manager = model.manager, model.selectedWorkspace?.id == workspace.id else { return }
                    do {
                        try await manager.administer(connection, workspace, command: .revokeChannelGrant(channel: channel.id, principalType: row.fields["principal_type"] ?? "", principal: row.fields["principal_id"] ?? row.id))
                        await refresh()
                    } catch { canManage = false; phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)) }
                }
            }
        } message: { Text("This grant is removed immediately. Other grants may still provide access.") }
    }
    private func refresh() async {
        guard let manager = model.manager else { return }
        do {
            let fresh = try await manager.membership(connection, workspace)
            let rows = try await manager.channelGrants(connection, workspace, channel: channel.id)
            canManage = AdministrationAuthority.canManageChannelGrants(membership: fresh, grants: rows, groups: groups, npub: connection.signerNpub)
            phase = .idle
        }
        catch { canManage = false; phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)) }
    }
}

private enum AdministrationEditorKind {
    case profile, member, group, groupMember(String), childGroup(String, Bool), grant(String, AdministrationRow?), delegation, publishing(AdministrationRow?), rotation(AdministrationRow), memberProfile(AdministrationRow)
    case scopeGrant(String, ScopeAdministrationAccess, AdministrationRow?)
    var key: String {
        switch self {
        case .scopeGrant(let scope, _, let row): "scope-grant:\(scope):\(row?.id ?? "new")"
        case .publishing(let row): "publishing:\(row?.id ?? "new")"
        case .rotation(let row): "rotation:\(row.id)"
        case .memberProfile(let row): "member-profile:\(row.id)"
        case .profile: "profile"
        case .member: "member"
        case .group: "group"
        case .groupMember(let id): "group-member:\(id)"
        case .childGroup(let id, let remove): "child-group:\(id):\(remove)"
        case .grant(let id, let row): "grant:\(id):\(row?.id ?? "new")"
        case .delegation: "delegation"
        }
    }
    var title: String {
        switch self {
        case .scopeGrant: "Grant scope access"
        case .publishing: "Publishing installation"
        case .rotation: "Rotate publisher public key"
        case .memberProfile: "Edit member display name"
        case .profile: "Edit workspace"
        case .member: "Add member"
        case .group: "New group"
        case .groupMember: "Add group member"
        case .childGroup(_, let remove): remove ? "Remove child group" : "Add child group"
        case .grant(_, let row): row == nil ? "Grant channel access" : "Change channel access"
        case .delegation: "Grant app management"
        }
    }
}

private struct AdministrationEditor: View {
    @Environment(AppModel.self) private var model
    let kind: AdministrationEditorKind
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    let members: [AdministrationRow]
    let groups: [AdministrationRow]
    var channelAuthority = false
    @State private var values: [String: String] = [:]
    @State private var loaded = false
    @State private var savedFingerprint: String?
    @State private var phase = ManagementPhase.idle
    @State private var confirm = false
    private var fingerprint: String { SHA256Hex.of((try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data()) }
    private var selectedPublishingChannels: Set<String> { Set((values["channels"] ?? "").split(separator: ",").map(String.init)) }
    private var canEdit: Bool {
        if case .scopeGrant(_, let access, _) = kind { return access.canManage }
        if case .grant = kind { return channelAuthority }
        return model.membership?.isAdmin == true
    }
    private var draftKey: String { "admin.draft.v1:\(connection.id):\(workspace.id):\(kind.key)" }

    var body: some View {
        Form {
            Section {
                Text(workspace.label).font(.headline)
                Text("Requires a connection. Drafts stay on this device; no administration request is queued offline.").font(.caption).foregroundStyle(.secondary)
            }
            Section(kind.title) {
                switch kind {
                case .memberProfile(let row):
                    Text(row.title); field("Display name", "name")
                case .rotation(let row):
                    Text(row.title)
                    Text("Current publisher: \(row.fields["publisher_npub"] ?? "Unavailable")").font(.caption)
                    field("Replacement publisher npub", "replacement")
                    Text("Only a public key is accepted. The server may require owner step-up approval.").font(.caption)
                case .publishing(let row):
                    if row == nil { field("Installation UUID", "installation") }
                    field("App identifier", "app"); field("Display name", "name")
                    field("Publisher npub", "publisher"); field("Owner npub", "owner")
                    ForEach(model.navigation.value.groups) { group in
                        Text(group.scope.name).font(.caption).foregroundStyle(.secondary)
                        ForEach(group.channels) { channel in
                            Toggle(channel.name, isOn: Binding(get: { selectedPublishingChannels.contains(channel.id) }, set: { selected in
                                var ids = selectedPublishingChannels
                                if selected { ids.insert(channel.id) } else { ids.remove(channel.id) }
                                values["channels"] = ids.sorted().joined(separator: ",")
                            }))
                        }
                    }
                    field("HTTPS open origins (one per line)", "origins", axis: .vertical)
                    Text("Saving replaces this publishing grant’s destinations and open origins with the values shown. Feed publishing is limited to the selected destinations.").font(.caption)
                case .profile:
                    field("Name", "name"); field("Description", "description", axis: .vertical); field("Avatar HTTPS or storage URL", "avatar")
                    WorkspaceAvatarUpload(workspace: workspace, connection: connection, avatar: binding("avatar"))
                case .member:
                    field("Full public key (npub)", "npub")
                    Picker("Member type", selection: binding("kind", fallback: "human")) { Text("Person").tag("human"); Text("Agent").tag("agent") }
                    Text("Adds a member with the member role. Use a group or channel grant to give access.").font(.caption)
                case .group: field("Group name", "name")
                case .groupMember:
                    Picker("Workspace member", selection: binding("npub")) {
                        Text("Choose a member").tag("")
                        ForEach(members) { Text($0.title).tag($0.fields["npub"] ?? "") }
                    }
                case .childGroup(let parent, _):
                    Picker("Child group", selection: binding("child")) {
                        Text("Choose a group").tag("")
                        ForEach(groups.filter { $0.id != parent }) { Text($0.title).tag($0.id) }
                    }
                case .grant(_, let row):
                    if row == nil {
                        Picker("Principal", selection: binding("type", fallback: "actor")) { Text("Person or agent").tag("actor"); Text("Group").tag("group") }
                        Picker("Give access to", selection: binding("principal")) {
                            Text("Choose a recipient").tag("")
                            ForEach(values["type"] == "group" ? groups : members) { Text($0.title).tag($0.id) }
                        }
                    } else { Text(row?.title ?? "Recipient") }
                    Picker("Access", selection: binding("access", fallback: "view")) {
                        Text("View").tag("view"); Text("Contribute").tag("contribute"); Text("Manage").tag("manage")
                    }
                    Text("Manage access includes authority over this channel. Tower checks the exact grant.").font(.caption)
                case .scopeGrant(_, let access, let row):
                    if row == nil {
                        Picker("Principal", selection: binding("type", fallback: "actor")) { Text("Person or agent").tag("actor"); Text("Group").tag("group") }
                        Picker("Give access to", selection: binding("principal")) {
                            Text("Choose a recipient").tag("")
                            ForEach(values["type"] == "group" ? access.groups : access.actors) { Text($0.title).tag($0.id) }
                        }
                    } else { Text(row?.title ?? "Recipient") }
                    Picker("Role", selection: binding("role", fallback: "context_editor")) {
                        Text("Context editor").tag("context_editor"); Text("Scope manager").tag("scope_manager")
                    }
                    Text("Context editors can edit the context tree. Scope managers can also manage scope settings and access. Neither role grants access to linked content.").font(.caption)
                case .delegation:
                    Picker("Delegate", selection: binding("actor")) {
                        Text("Choose a member").tag("")
                        ForEach(members) { Text($0.title).tag($0.id) }
                    }
                    field("App identifier", "app")
                    Picker("Destination channel", selection: binding("channel")) {
                        Text("Choose a channel").tag("")
                        ForEach(model.navigation.value.groups.flatMap(\.channels)) { Text($0.name).tag($0.id) }
                    }
                    DatePicker("Expires", selection: Binding(get: { ISO8601DateFormatter().date(from: values["expires"] ?? "") ?? Date().addingTimeInterval(86400) }, set: { values["expires"] = ISO8601DateFormatter().string(from: $0) }), in: Date()...)
                    Text("Limited to the specified app and destination, with Feed publishing. Does not grant workspace administration, people, billing, storage or arbitrary channel access.").font(.caption)
                }
            }.disabled(!loaded || phase.isWorking)
            Section {
                Button("Save on Tower") { endEditing(); confirm = true }
                    .disabled(!loaded || phase.isWorking || savedFingerprint == fingerprint || !canEdit || model.selectedWorkspace?.id != workspace.id || model.connection?.id != connection.id)
                    .accessibilityIdentifier("admin.save")
                Text("Your draft is retained after a failure. If Tower accepted a request but the connection was interrupted, refresh the relevant list before trying again.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .macGroupedForm()
        .navigationTitle(kind.title)
        .modifier(ManagementStatusInset(phase: phase))
        .modifier(KeyboardDone())
        .interactiveDismissDisabled(phase.isWorking)
        .confirmationDialog("Apply this workspace change?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Confirm workspace change") { Task { await save() } }.accessibilityIdentifier("admin.confirm")
        } message: { Text("This changes \(workspace.label) immediately. It is not a personal device preference.") }
        .task {
            guard !loaded else { return }
            var initial: [String: String] = ["kind": "human", "type": "actor", "access": "view", "expires": ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))]
            if case .profile = kind {
                let object = (try? JSONSerialization.jsonObject(with: workspace.raw)) as? [String: Any] ?? [:]
                initial["name"] = workspace.label; initial["description"] = object["description"] as? String ?? ""; initial["avatar"] = object["avatar_url"] as? String ?? ""
            }
            if case .publishing(let row) = kind {
                initial["installation"] = row?.id ?? UUID().uuidString.lowercased()
                initial["app"] = row?.fields["app_id"] ?? ""; initial["name"] = row?.title ?? ""
                initial["publisher"] = row?.fields["publisher_npub"] ?? ""; initial["owner"] = row?.fields["owner_npub"] ?? workspace.ownerNpub ?? ""
                if let raw = row?.raw, let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                    initial["origins"] = (object["registered_open_origins"] as? [String] ?? []).joined(separator: "\n")
                    let destinations = object["destinations"] as? [[String: Any]] ?? []
                    initial["channels"] = destinations.compactMap { $0["channel_id"] as? String }.sorted().joined(separator: ",")
                }
            }
            if let draft = try? await model.store?.reader.state(draftKey), let stored = try? JSONDecoder().decode([String: String].self, from: Data(draft.utf8)) { initial = stored }
            savedFingerprint = try? await model.store?.reader.state(draftKey + ":confirmed")
            values = initial; loaded = true
        }
        .task(id: values) {
            guard loaded, let store = model.store else { return }
            let snapshot = values, key = draftKey
            // Debounce with cancellation; the writer actor orders the final persisted draft.
            do { try await Task.sleep(for: .milliseconds(200)); try Task.checkCancellation(); try await store.writer.setState(key, String(decoding: JSONEncoder().encode(snapshot), as: UTF8.self)) }
            catch is CancellationError {} catch { phase = .failed(.unexpected("Could not keep this draft: \(error.localizedDescription)")) }
        }
        .onDisappear {
            guard loaded, let store = model.store else { return }
            let snapshot = values, key = draftKey
            Task { try? await store.writer.setState(key, String(decoding: JSONEncoder().encode(snapshot), as: UTF8.self)) }
        }
    }
    private func binding(_ key: String, fallback: String = "") -> Binding<String> { Binding(get: { values[key] ?? fallback }, set: { values[key] = $0 }) }
    private func field(_ title: String, _ key: String, axis: Axis = .horizontal) -> some View {
        TextField(title, text: binding(key), axis: axis).accessibilityIdentifier("admin.field.\(key)")
    }
    private func command() throws -> AdministrationCommand {
        let v = values
        switch kind {
        case .scopeGrant: throw ManagementError.invalid("Use the scope access editor.")
        case .rotation(let row): return .rotatePublisher(id: row.id, current: row.fields["publisher_npub"] ?? "", replacement: v["replacement"] ?? "")
        case .publishing(let row):
            let available = model.navigation.value.groups.flatMap(\.channels)
            let channels = available.filter { selectedPublishingChannels.contains($0.id) }
            guard !channels.isEmpty, channels.count == selectedPublishingChannels.count else { throw ManagementError.invalid("Choose available publishing destinations. A previous destination may no longer be visible; refresh and review before saving.") }
            return .publishing(id: row?.id ?? v["installation"] ?? "", app: v["app"] ?? "", publisher: v["publisher"] ?? "", owner: v["owner"] ?? "", name: v["name"] ?? "", destinations: channels.map { AdministrationDestination(scope: $0.scopeId, channel: $0.id) }, origins: (v["origins"] ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        case .memberProfile(let row): return .memberProfile(actor: row.id, name: v["name"] ?? "")
        case .profile: return .profile(name: v["name"] ?? "", description: v["description"] ?? "", avatarURL: v["avatar"] ?? "")
        case .member: return .addMember(npub: v["npub"] ?? "", kind: v["kind"] ?? "human")
        case .group: return .createGroup(name: v["name"] ?? "")
        case .groupMember(let id): return .groupMember(group: id, npub: v["npub"] ?? "")
        case .childGroup(let id, let remove): return .childGroup(parent: id, child: v["child"] ?? "", remove: remove)
        case .grant(let channel, let row): return .channelGrant(channel: channel, principalType: row?.fields["principal_type"] ?? v["type"] ?? "actor", principal: row?.fields["principal_id"] ?? v["principal"] ?? "", access: v["access"] ?? "view", update: row != nil)
        case .delegation:
            guard let channel = model.navigation.value.groups.flatMap(\.channels).first(where: { $0.id == v["channel"] }) else { throw ManagementError.invalid("Choose a destination channel.") }
            return .delegation(actor: v["actor"] ?? "", expires: v["expires"] ?? "", app: v["app"] ?? "", scope: channel.scopeId, channel: channel.id)
        }
    }
    private func save() async {
        guard let manager = model.manager, let store = model.store, model.selectedWorkspace?.id == workspace.id, model.connection?.id == connection.id else { phase = .failed(.unexpected("The workspace changed. Reopen management.")); return }
        phase = .working("Waiting for Tower…")
        do {
            // Persist before sending; an app interruption cannot erase the submitted draft.
            try await store.writer.setState(draftKey, String(decoding: JSONEncoder().encode(values), as: UTF8.self))
            if case .scopeGrant(let scope, let access, let row) = kind {
                try await manager.saveScopeAccess(connection, workspace, scope: scope, principalType: row?.fields["principal_type"] ?? values["type"] ?? "actor", principal: row?.fields["principal_id"] ?? values["principal"] ?? "", role: values["role"] ?? "context_editor", revoke: false, expectedRevision: access.revision)
            } else {
                try await manager.administer(connection, workspace, command: command())
            }
            savedFingerprint = fingerprint
            try await store.writer.setState(draftKey + ":confirmed", savedFingerprint)
            phase = .done("Saved on Tower. Refresh the list to see the current result.")
            model.refresh(force: true)
        } catch {
            model.loadMembership(force: true)
            phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription))
        }
    }
}

private struct ScopeAccessAdministrationPage: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeRecord
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    @State private var query = LiveQuery<ScopeAdministrationAccess?>(initial: nil)
    @State private var phase = ManagementPhase.idle
    @State private var fresh = false
    @State private var pending: AdministrationRow?

    var body: some View {
        List {
            Section {
                Text(workspace.label).font(.caption)
                Button("Refresh scope access") { Task { await refresh() } }
                if let access = query.value {
                    NavigationLink("Grant scope role") { AdministrationEditor(kind: .scopeGrant(scope.id, access, nil), workspace: workspace, connection: connection, members: access.actors, groups: access.groups) }
                        .disabled(!fresh || !access.canManage)
                    ForEach(access.grants) { row in
                        VStack(alignment: .leading) {
                            Text(row.title); Text(row.detail).font(.caption)
                            if fresh && access.canManage {
                                NavigationLink("Change role") { AdministrationEditor(kind: .scopeGrant(scope.id, access, row), workspace: workspace, connection: connection, members: access.actors, groups: access.groups) }
                                Button("Revoke role grants", role: .destructive) { pending = row }
                            }
                        }
                    }
                    if access.grants.isEmpty { Text("No scope role grants").foregroundStyle(.secondary) }
                } else { Text(query.loaded ? "No saved scope access. Refresh to load it." : "Loading saved scope access…").foregroundStyle(.secondary) }
                Text("Revoking role grants preserves custom permissions and group-derived access. A revision conflict requires refresh and review.").font(.caption)
            }
        }.navigationTitle(scope.name)
        .modifier(ManagementStatusInset(phase: phase))
        .task {
            guard let store = model.store else { return }
            let c = connection.id, w = workspace.id, id = scope.id
            query.start(store: store, matches: { $0.table == .appState || $0.table == .access }, load: { try await store.reader.scopeAdministrationAccess(connection: c, workspace: w, scope: id) })
            await refresh()
        }
        .onDisappear { query.stop(); fresh = false }
        .confirmationDialog("Revoke scope role grants?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Revoke role grants", role: .destructive) {
                guard let row = pending, let access = query.value else { return }; pending = nil
                Task {
                    guard model.selectedWorkspace?.id == workspace.id, let manager = model.manager else { return }
                    phase = .working("Waiting for Tower…")
                    do {
                        try await manager.saveScopeAccess(connection, workspace, scope: scope.id, principalType: row.fields["principal_type"] ?? "", principal: row.fields["principal_id"] ?? "", role: "context_editor", revoke: true, expectedRevision: access.revision)
                        await refresh()
                    } catch { phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)); fresh = false }
                }
            }
        } message: { Text("Existing custom permissions and group-derived access remain. This removes the selected principal’s role grants on this scope.") }
    }
    private func refresh() async {
        guard let manager = model.manager else { return }
        fresh = false
        do { _ = try await manager.scopeAccess(connection, workspace, scope: scope.id); fresh = true; phase = .idle }
        catch { phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)) }
    }
}

struct WorkspaceIdentityHeader: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    private var current: WorkspaceRecord { model.workspaces.value.first(where: { $0.id == workspace.id }) ?? workspace }
    private var avatar: String? { ((try? JSONSerialization.jsonObject(with: current.raw)) as? [String: Any])?["avatar_url"] as? String }
    var body: some View {
        HStack(spacing: 12) {
            LauncherLogoView(sources: avatar.flatMap(LauncherLogoSource.init).map { [$0] } ?? [], initials: String(current.label.prefix(2)), workspace: current, size: 48)
            VStack(alignment: .leading) {
                Text(current.label).font(.headline)
                Text("Selected workspace").font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}
