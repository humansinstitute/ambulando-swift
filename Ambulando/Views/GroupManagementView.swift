import AmbulandoCore
import SwiftUI

/// Directory and membership remain separate contexts, with one local search field in each.
struct GroupManagementView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    @State private var groups = LiveQuery<[AdministrationRow]>(initial: [])
    @State private var members = LiveQuery<[AdministrationRow]>(initial: [])
    @State private var people = LiveQuery<PeopleDirectory>(initial: PeopleDirectory())
    @State private var selected: String?
    @State private var search = ""
    @State private var results: [AdministrationRow] = []
    @State private var phase = ManagementPhase.idle
    private var admin: Bool { model.membership?.isAdmin == true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.3.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Groups").font(.title2.bold())
                    Text("\(workspace.label) · \(groups.value.count) groups").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh groups and access")
                    .disabled(phase.isWorking).accessibilityLabel("Refresh groups")
                NavigationLink { AdministrationEditor(kind: .group, workspace: workspace, connection: connection, members: members.value, groups: groups.value) } label: {
                    Label("New group", systemImage: "plus")
                }.buttonStyle(.borderedProminent).disabled(!admin).accessibilityIdentifier("admin.editor.group")
            }.padding(20)
            if !admin { Text(model.membership == nil ? "Checking access…" : "Read only · Workspace administrator access is required to change membership.").font(.caption).foregroundStyle(.secondary).padding(.bottom, 10) }
            Divider()
            #if os(macOS)
            HSplitView {
                browser.frame(minWidth: 210, idealWidth: 240, maxWidth: 290)
                if let group = groups.value.first(where: { $0.id == selected }) {
                    groupDetail(group).frame(minWidth: 290, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Choose a group", systemImage: "person.3", description: Text("Browse groups to see direct people and nested membership."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            #else
            browser
            #endif
        }
        .background(Amb.canvas)
        .navigationTitle("Groups")
        .modifier(ManagementStatusInset(phase: phase))
        .task {
            guard let store = model.store else { return }
            let c = connection.id, w = workspace.id
            groups.start(store: store, matches: { $0.table == .appState || $0.table == .access }, load: { try await store.reader.administrationRows(connection: c, workspace: w, list: .groups) })
            members.start(store: store, matches: { $0.table == .appState || $0.table == .access }, load: { try await store.reader.administrationRows(connection: c, workspace: w, list: .members) })
            people.start(store: store, matches: { $0.table == .members || $0.table == .profiles || $0.table == .appState || $0.table == .access }, load: { try await store.reader.people(connectionId: c, workspaceId: w) })
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)); try Task.checkCancellation() } catch { return }
                guard current else { return }; await refresh()
            }
        }
        .task(id: DirectorySearchKey(query: search, rows: groups.value)) {
            let rows = groups.value, query = search
            let found = await Task.detached(priority: .userInitiated) { GroupDirectory.search(rows, query: query) }.value
            guard !Task.isCancelled else { return }; results = found
            if selected == nil { selected = found.first?.id }
        }
        .onDisappear { groups.stop(); members.stop(); people.stop() }
    }
    private var current: Bool { model.connection?.id == connection.id && model.selectedWorkspace?.id == workspace.id }
    private var browser: some View {
        VStack(spacing: 0) {
            DirectorySearchField(prompt: "Find a group", text: $search).padding(12).accessibilityIdentifier("groups.search")
            List {
                ForEach(results) { group in
                    #if os(macOS)
                    Button { selected = group.id } label: { GroupDirectoryRow(group: group) }
                        .buttonStyle(.plain).listRowBackground(selected == group.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        .accessibilityIdentifier("groups.open.\(group.id)")
                    #else
                    NavigationLink { groupDetail(group) } label: { GroupDirectoryRow(group: group) }
                        .accessibilityIdentifier("groups.open.\(group.id)")
                    #endif
                }
                if results.isEmpty {
                    Text(groups.loaded ? (search.isEmpty ? "No saved groups. Create a group or refresh." : "No groups match your search.") : "Loading saved groups…")
                        .foregroundStyle(.secondary).padding(.vertical)
                }
            }.listStyle(.plain)
            Text("Saved directory · \(model.connectionStatus.label)").font(.caption).foregroundStyle(.secondary).padding(12)
        }
    }
    private func groupDetail(_ group: AdministrationRow) -> some View {
        GroupMembershipDetail(workspace: workspace, connection: connection, groupId: group.id, groups: groups.value, members: members.value, people: people.value, admin: admin)
            .id(group.id)
    }
    private func refresh() async {
        guard current, let manager = model.manager else { return }
        model.loadMembership(force: true); phase = .working("Refreshing groups…")
        do {
            try await manager.refreshAdministration(connection, workspace, list: .members)
            try await manager.refreshAdministration(connection, workspace, list: .groups)
            phase = .idle
        } catch { phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)) }
    }
}

private struct DirectorySearchKey: Equatable {
    let query: String
    let rows: [AdministrationRow]
}
private struct DirectorySearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Clear search") }
        }.padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
private struct GroupDirectoryRow: View {
    let group: AdministrationRow
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill").foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title).font(.headline).lineLimit(2)
                Text("\(group.children.count) \(group.children.count == 1 ? "person" : "people") · \(group.childGroupIds.count) \(group.childGroupIds.count == 1 ? "group" : "groups")").font(.caption).foregroundStyle(.secondary)
                Text((group.fields["kind"] ?? "Group").capitalized).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

private struct GroupMembershipDetail: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    let groupId: String
    let groups: [AdministrationRow]
    let members: [AdministrationRow]
    let people: PeopleDirectory
    let admin: Bool
    @State private var phase = ManagementPhase.idle
    @State private var removal: AdministrationRow?
    @State private var removeChild = false
    @State private var liveGroups = LiveQuery<[AdministrationRow]>(initial: [])
    @State private var liveMembers = LiveQuery<[AdministrationRow]>(initial: [])
    @State private var livePeople = LiveQuery<PeopleDirectory>(initial: PeopleDirectory())
    private var currentPeople: PeopleDirectory { livePeople.loaded ? livePeople.value : people }
    private var currentGroups: [AdministrationRow] { liveGroups.loaded ? liveGroups.value : groups }
    private var currentMembers: [AdministrationRow] { liveMembers.loaded ? liveMembers.value : members }
    private var canManage: Bool { admin && model.membership?.isAdmin == true }
    private var group: AdministrationRow? { currentGroups.first { $0.id == groupId } }

    var body: some View {
        ScrollView {
            if let group {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title).font(.largeTitle.bold()).textSelection(.enabled)
                        HStack { Label((group.fields["kind"] ?? "Group").capitalized + " group", systemImage: "person.3"); Text("\(group.children.count) direct \(group.children.count == 1 ? "person" : "people")") }.font(.subheadline).foregroundStyle(.secondary)
                        if group.fields["kind"] == "system" { Text("System group · Tower protects its membership rules.").font(.caption).foregroundStyle(.secondary) }
                    }
                    GroupQuickAdd(workspace: workspace, connection: connection, group: group, groups: currentGroups, members: currentMembers, people: currentPeople, canEdit: canManage)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Direct people (\(group.children.count))").font(.headline)
                        Text("Removing someone here keeps their workspace membership.").font(.caption).foregroundStyle(.secondary)
                        if group.children.isEmpty { empty("No direct people yet", icon: "person.crop.circle.badge.plus") }
                        ForEach(group.children) { person in
                            HStack(spacing: 12) {
                                NavigationLink { personDetail(person) } label: { GroupPersonRow(row: person, people: currentPeople) }.buttonStyle(.plain)
                                Spacer(minLength: 0)
                                if canManage { Button { removeChild = false; removal = person } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove \(person.title) from group").buttonStyle(.borderless) }
                            }.padding(.vertical, 4)
                            Divider()
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Nested groups (\(group.childGroupIds.count))").font(.headline)
                        Text("People inherit access through these groups. Attaching a group does not invite its people to the workspace.").font(.caption).foregroundStyle(.secondary)
                        if group.childGroupIds.isEmpty { empty("No nested groups", icon: "person.3.sequence") }
                        ForEach(group.childGroupIds, id: \.self) { childId in
                            if let child = currentGroups.first(where: { $0.id == childId }) {
                                HStack {
                                    NavigationLink { GroupMembershipDetail(workspace: workspace, connection: connection, groupId: child.id, groups: currentGroups, members: currentMembers, people: currentPeople, admin: admin) } label: { GroupDirectoryRow(group: child) }.buttonStyle(.plain)
                                    if canManage { Button { removeChild = true; removal = child } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Detach \(child.title)").buttonStyle(.borderless) }
                                }
                            } else { Label("Unavailable nested group · \(childId)", systemImage: "person.3").font(.caption) }
                            Divider()
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            } else { ContentUnavailableView("Group unavailable", systemImage: "person.3") }
        }
        .task {
            guard let store = model.store else { return }
            let c = connection.id, w = workspace.id
            liveGroups.start(store: store, matches: { $0.table == .appState || $0.table == .access }, load: { try await store.reader.administrationRows(connection: c, workspace: w, list: .groups) })
            liveMembers.start(store: store, matches: { $0.table == .appState || $0.table == .access }, load: { try await store.reader.administrationRows(connection: c, workspace: w, list: .members) })
            livePeople.start(store: store, matches: { $0.table == .members || $0.table == .profiles || $0.table == .access }, load: { try await store.reader.people(connectionId: c, workspaceId: w) })
        }
        .onDisappear { liveGroups.stop(); liveMembers.stop(); livePeople.stop() }
        .background(Amb.background)
        .navigationTitle(group?.title ?? "Group")
        .inlineTitle()
        .modifier(KeyboardDone())
        .modifier(ManagementStatusInset(phase: phase))
        .confirmationDialog(removeChild ? "Detach nested group?" : "Remove person from group?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button(removeChild ? "Detach group" : "Remove from group", role: .destructive) {
                if let row = removal { let child = removeChild; removal = nil; Task { await remove(row, child: child) } }
            }
        } message: { Text("This removes access supplied by this group. Workspace membership and other grants remain.") }
    }
    private func empty(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
    private func personDetail(_ row: AdministrationRow) -> some View {
        List {
            Section { GroupPersonRow(row: row, people: currentPeople); Text(row.fields["npub"] ?? row.id).font(.caption.monospaced()).textSelection(.enabled) }
            Section("Membership") { Text("Direct member of \(group?.title ?? "this group")"); Text("Workspace: \(workspace.label)"); Text("Removing group membership keeps workspace membership.").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle(currentPeople.person(row.fields["npub"], senderLabel: row.title).name)
    }
    private func remove(_ row: AdministrationRow, child: Bool) async {
        guard model.connection?.id == connection.id, model.selectedWorkspace?.id == workspace.id, let manager = model.manager else { return }
        phase = .working("Removing membership…")
        do {
            try await manager.administer(connection, workspace, command: child ? .childGroup(parent: groupId, child: row.id, remove: true) : .removeGroupMember(group: groupId, actor: row.id))
            try await manager.refreshAdministration(connection, workspace, list: .groups); phase = .idle
        } catch { phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)); model.loadMembership(force: true) }
    }
}

private struct GroupPersonRow: View {
    let row: AdministrationRow
    let people: PeopleDirectory
    var body: some View {
        let person = people.person(row.fields["npub"], senderLabel: row.title)
        HStack(spacing: 10) {
            PersonAvatar(person: person, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).font(.body.weight(.medium)).lineLimit(2)
                Label(row.fields["kind"].map { $0 == "human" ? "Person" : $0.capitalized } ?? "Person", systemImage: row.fields["kind"] == "agent" ? "cpu" : "person").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

private struct GroupQuickAdd: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    let group: AdministrationRow
    let groups: [AdministrationRow]
    let members: [AdministrationRow]
    let people: PeopleDirectory
    let canEdit: Bool
    @State private var query = ""
    @State private var mode = "people"
    @State private var kind = "human"
    @State private var results: [AdministrationRow] = []
    @State private var highlighted = 0
    @State private var working = Set<String>()
    @State private var added = Set<String>()
    @State private var messages: [String: String] = [:]
    @State private var loaded = false
    @State private var confirmNew = false
    @FocusState private var focused: Bool
    private var draftKey: String { "admin.group-add.v1:\(connection.id):\(workspace.id):\(group.id)" }
    private var fullKey: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var newKey: Bool { mode == "people" && NostrKeys.isValidNpub(fullKey) && !members.contains { $0.fields["npub"] == fullKey } }
    private var current: Bool { model.connection?.id == connection.id && model.selectedWorkspace?.id == workspace.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(canEdit ? "Add to group" : "Search saved directory").font(.headline).fixedSize()
                    Spacer()
                    modePicker.frame(width: 200)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(canEdit ? "Add to group" : "Search saved directory").font(.headline)
                    modePicker
                }
            }
            TextField(mode == "people" ? "Type a name, actor ID or full npub" : "Type a group name or ID", text: $query)
                .textFieldStyle(.roundedBorder).noCapitalization().autocorrectionDisabled().focused($focused).accessibilityIdentifier("groups.add.search")
                .onSubmit { chooseHighlighted() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.tab) { if focused && !results.isEmpty { chooseHighlighted(); return .handled }; return .ignored }
                .onKeyPress(.escape) { query = ""; return .handled }
            if !loaded { ProgressView("Loading saved draft…").controlSize(.small) }
            else if results.isEmpty && !newKey {
                Text(fullKey.hasPrefix("npub") ? "Enter a complete valid npub, including its checksum." : "No matches in the saved workspace directory.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                            Button { add(row) } label: {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 10) {
                                        candidateIdentity(row).frame(minWidth: 180)
                                        candidateAction(row).fixedSize()
                                    }
                                    VStack(alignment: .leading, spacing: 6) {
                                        candidateIdentity(row)
                                        HStack { Spacer(); candidateAction(row) }
                                    }
                                }.padding(8).background(highlighted == index && focused ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(state(row) != nil || working.contains(row.id) || !current || !canEdit)
                                .id(row.id).accessibilityIdentifier("groups.add.\(row.id)")
                        }
                    }
                }.frame(minHeight: results.isEmpty ? 0 : 60, maxHeight: 220)
                    .onChange(of: highlighted) { _, index in if results.indices.contains(index) { proxy.scrollTo(results[index].id) } }
            }
            if newKey {
                VStack(alignment: .leading, spacing: 10) {
                    Text("New workspace member").font(.subheadline.bold())
                    Text(fullKey).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Picker("Identity type", selection: $kind) { Text("Person").tag("human"); Text("Agent").tag("agent") }.pickerStyle(.segmented)
                    Text("Adds this identity to \(workspace.label) as a member, then to \(group.title).").font(.caption).foregroundStyle(.secondary)
                    Button("Add to workspace and group…") { confirmNew = true }.accessibilityIdentifier("groups.enrol").buttonStyle(.borderedProminent).disabled(!current || !canEdit || working.contains(fullKey))
                }
            }
            ForEach(messages.keys.sorted(), id: \.self) { id in
                Text(messages[id] ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Searches saved workspace data. Add several people without leaving this view.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).background(Amb.canvas, in: RoundedRectangle(cornerRadius: 12))
        .task {
            if let saved = try? await model.store?.reader.state(draftKey), let data = saved.data(using: .utf8), let values = try? JSONDecoder().decode([String: String].self, from: data) {
                query = values["query"] ?? ""; mode = values["mode"] ?? "people"; kind = values["kind"] ?? "human"
            }; loaded = true
        }
        .task(id: DirectorySearchKey(query: mode + ":" + query, rows: mode == "people" ? members : groups)) {
            let rows = mode == "people" ? members : groups, term = query
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            let found = await Task.detached(priority: .userInitiated) { GroupDirectory.search(rows, query: term) }.value
            guard !Task.isCancelled else { return }; results = found; highlighted = 0
        }
        .task(id: [query, mode, kind]) {
            guard loaded, let store = model.store else { return }
            let key = draftKey, value = draftValue
            do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation(); try await store.writer.setState(key, value) } catch {}
        }
        .onDisappear {
            guard loaded, let store = model.store else { return }; let key = draftKey, value = draftValue
            Task { try? await store.writer.setState(key, value) }
        }
        .onChange(of: mode) { _, _ in results = []; highlighted = 0 }
        .onChange(of: group) { _, value in
            added.subtract(value.children.map(\.id) + value.childGroupIds)
        }
        .confirmationDialog("Add new workspace member?", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("Confirm enrolment") { addNew() }
        } message: { Text("\(kind == "agent" ? "Agent" : "Person"): \(fullKey)\nWorkspace: \(workspace.label)\nGroup: \(group.title)\nMember role only.") }
    }
    private var modePicker: some View {
        Picker("Add", selection: $mode) { Text("People").tag("people"); Text("Groups").tag("groups") }
            .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("groups.add.mode")
    }
    @ViewBuilder private func candidateIdentity(_ row: AdministrationRow) -> some View {
        if mode == "people" { GroupPersonRow(row: row, people: people) }
        else { GroupDirectoryRow(group: row) }
    }
    @ViewBuilder private func candidateAction(_ row: AdministrationRow) -> some View {
        if working.contains(row.id) { ProgressView().controlSize(.small) }
        else if let state = state(row) { Text(state).font(.caption).foregroundStyle(.secondary) }
        else if canEdit { Image(systemName: "plus.circle.fill").foregroundStyle(.tint) }
        else { Text("Read only").font(.caption).foregroundStyle(.secondary) }
    }
    private var draftValue: String { String(decoding: (try? JSONEncoder().encode(["query": query, "mode": mode, "kind": kind])) ?? Data(), as: UTF8.self) }
    private func state(_ row: AdministrationRow) -> String? {
        if added.contains(row.id) { return "Added" }
        if mode == "groups" { return GroupDirectory.attachmentState(parent: group.id, child: row.id, groups: groups) }
        return group.children.contains { $0.id == row.id || ($0.fields["npub"] != nil && $0.fields["npub"] == row.fields["npub"]) } ? "Already a member" : nil
    }
    private func move(_ amount: Int) { if !results.isEmpty { highlighted = min(max(0, highlighted + amount), results.count - 1) } }
    private func chooseHighlighted() { if results.indices.contains(highlighted) { add(results[highlighted]) } }
    private func add(_ row: AdministrationRow) {
        guard current, canEdit, model.membership?.isAdmin == true, state(row) == nil, !working.contains(row.id), let manager = model.manager else { return }
        let child = mode == "groups", snapshot = draftValue, key = draftKey
        working.insert(row.id); messages[row.id] = nil; focused = true
        Task {
            do {
                try await model.store?.writer.setState(key, snapshot)
                guard current else { working.remove(row.id); return }
                if child { try await manager.administer(connection, workspace, command: .childGroup(parent: group.id, child: row.id, remove: false)) }
                else { try await manager.addExistingGroupPerson(connection, workspace, group: group.id, npub: row.fields["npub"] ?? "") }
                added.insert(row.id)
                messages[row.id] = "Added \(row.title)."
                do { try await manager.refreshAdministration(connection, workspace, list: .groups) }
                catch { messages[row.id] = "Added \(row.title); the saved list could not refresh. Refresh when connected." }
            } catch { messages[row.id] = "\(row.title): \(error.localizedDescription) Your search is retained. Check the current group before retrying."; model.loadMembership(force: true) }
            working.remove(row.id)
        }
    }
    private func addNew() {
        guard current, canEdit, model.membership?.isAdmin == true, !working.contains(fullKey), let manager = model.manager, let store = model.store else { return }
        let npub = fullKey, identityKind = kind, key = draftKey, snapshot = draftValue
        working.insert(npub); messages["enrolment"] = "Adding workspace and group membership…"; focused = true
        Task {
            do {
                try await store.writer.setState(key, snapshot)
                guard current else { working.remove(npub); return }
                try await manager.enrolGroupPerson(connection, workspace, group: group.id, npub: npub, kind: identityKind)
                messages["enrolment"] = "Added \(PersonDisplay.unknown(npub).name) to the workspace and group."
                do {
                    try await manager.refreshAdministration(connection, workspace, list: .members)
                    try await manager.refreshAdministration(connection, workspace, list: .groups)
                } catch { messages["enrolment"] = "Workspace and group membership saved; the directory could not refresh. Refresh when connected." }
            } catch {
                messages["enrolment"] = error.localizedDescription
                model.loadMembership(force: true)
            }
            working.remove(npub)
        }
    }
}
