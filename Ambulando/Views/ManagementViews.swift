import AmbulandoCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

// Scope and channel management opened from the sidebar, as on the web (sol `index.html` New channel, Channel settings,
// Settings › Scopes). Each change is one confirmed request to Tower through `ScopeChannelManager`; the sheet keeps what
// was typed until Tower answers, and says why if it refused. Channel and scope access (grants), the scope template
// wizard, starting channels and access controls are available in Manage Workspace.

/// Ends text editing so a result shown at the top of the form is not behind the keyboard.
@MainActor func endEditing() {
    #if os(iOS)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #else
    NSApp.keyWindow?.makeFirstResponder(nil)
    #endif
}

/// A Done button above the keyboard, so the actions under a text field can be reached.
struct KeyboardDone: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { endEditing() }.accessibilityIdentifier("keyboard.done")
            }
        }
    }
}

/// What a management action is doing now.
enum ManagementPhase: Equatable {
    case idle
    case working(String)
    case failed(ManagementError)
    case done(String)

    var isWorking: Bool { if case .working = self { true } else { false } }
}

/// Progress, refusal (with Retry when trying again can help) or confirmation under a management form.
/// Pins a management result above a form, where it stays visible however far the form is scrolled.
struct ManagementStatusInset: ViewModifier {
    let phase: ManagementPhase
    var retry: (() -> Void)?
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if phase != .idle {
                ManagementStatusView(phase: phase, retry: retry)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
    }
}

struct ManagementStatusView: View {
    let phase: ManagementPhase
    var retry: (() -> Void)?

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground) }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("manage.working")
        case .failed(let error):
            VStack(alignment: .leading, spacing: 6) {
                Notice(tone: error == .locked || isSaved(error) ? .warning : .error, text: error.localizedDescription)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("manage.error")
                if error.retryable, let retry {
                    Button { retry() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("manage.retry")
                }
            }
        case .done(let text):
            Notice(tone: .success, text: text).accessibilityElement(children: .combine).accessibilityIdentifier("manage.done")
        }
    }

    private func isSaved(_ error: ManagementError) -> Bool { if case .savedButNotRefreshed = error { true } else { false } }
}

// MARK: New channel

/// sol "New channel": name, optional description and channel context prompt; in a DM scope, a member to message.
struct NewChannelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let scope: ScopeRecord
    /// Called with the channel to open once the sheet has gone.
    let onCreated: (ChannelRecord) -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var prompt = ""
    @State private var person: String?
    @State private var members: [MemberRecord] = []
    @State private var phase = ManagementPhase.idle

    private var isDirect: Bool { ManagementPermissions.isDirectMessageScope(scope) }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(scope.name).foregroundStyle(Amb.mutedForeground) } header: { Text("Scope") }
                if isDirect {
                    Section {
                        Picker("Person", selection: $person) {
                            Text("Choose…").tag(String?.none)
                            ForEach(members.filter { $0.npub != model.connection?.signerNpub }, id: \.npub) { member in
                                Text(member.label).tag(String?.some(member.npub))
                            }
                        }
                        .accessibilityIdentifier("newChannel.person")
                    } header: { Text("Direct message") } footer: {
                        Text("An existing conversation with this person opens instead of a new one.")
                    }
                } else {
                    Section {
                        Label("Channel access", systemImage: "person.badge.key").font(.amb(.subheadline).weight(.semibold))
                        Text("This creates the channel with no extra permissions: you get Manage access, and nobody else is added. To give people or groups access, use Manage Workspace › Permissions › Channel access.")
                            .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("newChannel.limited")
                    Section("Channel name") {
                        TextField("e.g. general, design, ops", text: $name)
                            .noCapitalization()
                            .accessibilityIdentifier("newChannel.name")
                    }
                    Section("Description (optional)") {
                        WorkspaceContentTextEntry(text: $description, placeholder: "What's this channel about?", field: "new-channel-description-\(scope.id)").accessibilityIdentifier("newChannel.description")
                    }
                    Section {
                        WorkspaceContentTextEntry(text: $prompt, placeholder: "Context agents get in this channel", field: "channel-context-\(scope.id)").lineLimit(2...6)
                            .accessibilityIdentifier("newChannel.prompt")
                    } header: { Text("Channel context prompt (optional)") }
                }
            }
            .macGroupedForm()
            .modifier(KeyboardDone())
            .modifier(ManagementStatusInset(phase: phase, retry: create))
            .navigationTitle(isDirect ? "New direct message" : "New channel")
            .macSheetSize(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 600)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(phase.isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(phase.isWorking || (isDirect ? person == nil : name.trimmingCharacters(in: .whitespaces).isEmpty))
                        .accessibilityIdentifier("newChannel.create")
                }
            }
            .interactiveDismissDisabled(phase.isWorking)
            .task {
                guard isDirect, let store = model.store, let w = model.selectedWorkspace?.id else { return }
                members = (try? await store.reader.directoryMembers(workspaceId: w)) ?? []
            }
        }
    }

    private func create() {
        let scopeId = scope.id, name = name, description = description, prompt = prompt
        if isDirect, let person {
            let mine = model.connection?.signerNpub ?? ""
            if let existing = model.navigation.value.groups.first(where: { $0.id == scopeId })?.channels
                .first(where: { SidebarNavigation.participants($0) == Array(Set([mine, person])).sorted() }) {
                onCreated(existing); dismiss(); return
            }
        }
        endEditing(); phase = .working(isDirect ? "Opening the conversation…" : "Creating the channel…")
        let person = person
        Task {
            let result = await model.manage { manager, connection, workspace in
                if let person {
                    return try await manager.createDirectMessage(connection, workspace, scopeId: scopeId, participantNpub: person)
                }
                return try await manager.createChannel(connection, workspace, scopeId: scopeId, name: name, description: description, contextPrompt: prompt)
            }
            switch result {
            case .success(let channel): onCreated(channel); dismiss()
            case .failure(let error): phase = .failed(error)
            }
        }
    }
}

// MARK: Channel settings

/// sol "Channel settings": name, position, context prompt and archive for members with Manage access; everyone sees the
/// channel's name, participants and scope.
struct ChannelSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let channelId: String
    @State private var name = ""
    @State private var prompt = ""
    @State private var position = 1
    @State private var phase = ManagementPhase.idle
    @State private var confirmArchive = false
    @State private var loaded = false

    var body: some View {
        let nav = model.navigation.value
        NavigationStack {
            Group {
                if let channel = nav.channel(channelId) {
                    form(channel, nav)
                } else {
                    EmptyNote(title: "Channel not available", systemImage: "number", detail: "It was archived or you no longer have access.")
                }
            }
            .modifier(KeyboardDone())
            .modifier(ManagementStatusInset(phase: phase))
            .navigationTitle("Channel settings")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(phase.isWorking) } }
            .interactiveDismissDisabled(phase.isWorking)
        }
        .macSheetSize(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 640)
        .onAppear { model.loadMembership(force: true) }
    }

    @ViewBuilder private func form(_ channel: ChannelRecord, _ nav: NavigationSnapshot) -> some View {
        let siblings = nav.groups.first { $0.id == channel.scopeId }?.channels ?? []
        let index = (siblings.firstIndex { $0.id == channel.id } ?? 0) + 1
        let canManage = ManagementPermissions.canManage(channel, membership: model.membership)
        Form {
            Section {
                LabeledContent("Channel", value: "#" + nav.label(channel))
                LabeledContent("Scope", value: nav.scope(channel.scopeId)?.name ?? "—")
                let participants = SidebarNavigation.participants(channel)
                if !participants.isEmpty { LabeledContent("Participants", value: "\(participants.count)") }
            }
            if canManage {
                #if os(macOS)
                macManageSections(channel, nav, siblings: siblings, index: index)
                #else
                Section {
                    TextField("Channel name", text: $name).noCapitalization().accessibilityIdentifier("channelSettings.name")
                    Button("Rename channel") { rename(channel) }
                        .disabled(phase.isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty || name == channel.name)
                        .accessibilityIdentifier("channelSettings.rename")
                } header: { Text("Channel name") }
                Section {
                    Stepper("Position \(position) of \(siblings.count)", value: $position, in: 1...max(1, siblings.count))
                        .accessibilityIdentifier("channelSettings.position")
                    Button("Move to position \(position)") { move(channel) }
                        .disabled(phase.isWorking || position == index)
                        .accessibilityIdentifier("channelSettings.move")
                } header: { Text("Order in \(nav.scope(channel.scopeId)?.name ?? "scope")") }
                Section {
                    WorkspaceContentTextEntry(text: $prompt, placeholder: "Context agents get in this channel", field: "channel-context-\(channel.id)").lineLimit(2...8)
                        .accessibilityIdentifier("channelSettings.prompt")
                    Button("Save context prompt") { savePrompt(channel) }
                        .disabled(phase.isWorking || prompt == channel.contextPrompt)
                        .accessibilityIdentifier("channelSettings.savePrompt")
                } header: { Text("Channel context prompt") }
                #endif
            } else {
                Section {
                    Text(model.membership == nil && model.isUnlocked ? "Checking your access…"
                         : "You need Manage access to rename, reorder or archive this channel.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                        .accessibilityIdentifier("channelSettings.readOnly")
                    if !channel.contextPrompt.isEmpty { LabeledContent("Context prompt", value: channel.contextPrompt) }
                }
            }
            Section {
                Text("Manage who can read and write this channel in Manage Workspace › Permissions › Channel access.")
                    .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text("Channel access") }
            if canManage {
                Section {
                    Button("Archive channel", role: .destructive) { confirmArchive = true }
                        .disabled(phase.isWorking)
                        .accessibilityIdentifier("channelSettings.archive")
                }
            }
        }
        .macGroupedForm()
        .onAppear {
            guard !loaded else { return }
            loaded = true; name = channel.name; prompt = channel.contextPrompt; position = index
        }
        // A sync or a successful move changes the stored position: the stepper follows unless the user is choosing.
        .onChange(of: index) { _, now in if !phase.isWorking { position = now } }
        .confirmationDialog("Archive #\(nav.label(channel))?", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Archive channel", role: .destructive) {
                run("Archiving…", done: "Channel archived.") { m, c, w in try await m.archiveChannel(c, w, channel: channel) }
            }
        } message: {
            Text("This archives the channel, including nonempty channels. Stored tasks, documents, messages and files remain intact in Tower; the channel is no longer accessible to anyone.")
        }
    }

    #if os(macOS)
    /// The Mac form: each value with its action on the same row, and a context editor tall enough to read and edit
    /// (the column form clipped it and repeated the section names as row labels).
    @ViewBuilder private func macManageSections(_ channel: ChannelRecord, _ nav: NavigationSnapshot, siblings: [ChannelRecord], index: Int) -> some View {
        Section {
            HStack(spacing: 8) {
                TextField("Channel name", text: $name, prompt: Text("Channel name"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("channelSettings.name")
                Button("Rename") { rename(channel) }
                    .disabled(phase.isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty || name == channel.name)
                    .accessibilityIdentifier("channelSettings.rename")
            }
        } header: { Text("Channel name") }
        Section {
            HStack(spacing: 8) {
                Text("Position \(position) of \(siblings.count)").monospacedDigit()
                Stepper("Position", value: $position, in: 1...max(1, siblings.count)).labelsHidden()
                    .accessibilityLabel("Position \(position) of \(siblings.count)")
                    .accessibilityIdentifier("channelSettings.position")
                Spacer(minLength: 8)
                Button("Move to position \(position)") { move(channel) }
                    .disabled(phase.isWorking || position == index)
                    .accessibilityIdentifier("channelSettings.move")
            }
        } header: { Text("Order in \(nav.scope(channel.scopeId)?.name ?? "scope")") }
        Section {
            WorkspaceContentTextEntry(text: $prompt, placeholder: "Context agents get in this channel", field: "channel-context-\(channel.id)",
                                      macEditorHeight: 150)
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: Amb.radiusControl).stroke(Amb.border, lineWidth: 1))
                .accessibilityIdentifier("channelSettings.prompt")
            HStack {
                Text("Agents get this context in the channel.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                Spacer(minLength: 8)
                Button("Save context prompt") { savePrompt(channel) }
                    .disabled(phase.isWorking || prompt == channel.contextPrompt)
                    .accessibilityIdentifier("channelSettings.savePrompt")
            }
        } header: { Text("Channel context prompt") }
    }
    #endif

    private func rename(_ channel: ChannelRecord) {
        let name = name
        run("Renaming…", done: "Channel renamed.") { m, c, w in _ = try await m.renameChannel(c, w, channelId: channel.id, name: name) }
    }

    private func move(_ channel: ChannelRecord) {
        let position = position
        run("Moving…", done: "Channel order saved.") { m, c, w in try await m.moveChannel(c, w, channel: channel, position: position) }
    }

    private func savePrompt(_ channel: ChannelRecord) {
        let prompt = prompt
        run("Saving…", done: "Channel context settings saved.") { m, c, w in _ = try await m.saveContextPrompt(c, w, channel: channel, prompt: prompt) }
    }

    private func run(_ working: String, done: String, _ body: @escaping @Sendable (ScopeChannelManager, ConnectionRecord, WorkspaceRecord) async throws -> Void) {
        endEditing(); phase = .working(working)
        Task {
            switch await model.manage(body) {
            case .success: phase = .done(done)
            case .failure(let error): phase = .failed(error)
            }
        }
    }
}

// MARK: Manage scopes

/// sol Settings › Scopes: your personal scope order (Move up / Move down), and for scopes you manage, rename and
/// archive; New scope where you may create one.
struct ScopeManagementSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var phase = ManagementPhase.idle

    var body: some View {
        let nav = model.navigation.value
        let ordered = nav.groups.map(\.scope).filter(ManagementPermissions.isPersonallyOrdered)
        let others = nav.groups.map(\.scope).filter { !ManagementPermissions.isPersonallyOrdered($0) }
        NavigationStack {
            List {
                Section {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, scope in
                        HStack(spacing: 6) {
                            NavigationLink(value: scope.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scope.name).foregroundStyle(Amb.foreground).appRowTextSize()
                                    Text(ManagementPermissions.canManage(scope, membership: model.membership) ? "You manage this scope" : "View only")
                                        .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                                }
                            }
                            .accessibilityIdentifier("scopes.row.\(scope.name)")
                            moveButton("chevron.up", "Move \(scope.name) up", enabled: index > 0) { move(ordered, from: index, by: -1) }
                            moveButton("chevron.down", "Move \(scope.name) down", enabled: index < ordered.count - 1) { move(ordered, from: index, by: 1) }
                        }
                    }
                } header: { Text("Your scope order") } footer: {
                    Text("This order is yours: it changes the sidebar on every device you use, not for anyone else.")
                }
                if !others.isEmpty {
                    Section("Direct messages and system scopes") { ForEach(others) { Text($0.name).foregroundStyle(Amb.mutedForeground).appRowTextSize() } }
                }
                Section {
                    if ManagementPermissions.canCreateScope(model.membership) {
                        NavigationLink("New scope", value: "new").accessibilityIdentifier("scopes.new")
                    } else {
                        Text(model.membership == nil ? "Checking your access…" : "You don't have permission to create scopes in this workspace.")
                            .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    }
                } footer: {
                    Text("Use Manage Workspace › Scopes & Channels for staged template setup, and Permissions for scope and channel access.")
                }
            }
            .modifier(ManagementStatusInset(phase: phase))
            .navigationTitle("Manage scopes")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(phase.isWorking) } }
            .navigationDestination(for: String.self) { id in
                if id == "new" { ScopeEditView(scope: nil) } else if let scope = nav.scope(id) { ScopeEditView(scope: scope) }
                else { EmptyNote(title: "Scope not available", systemImage: "square.stack", detail: "It was archived or you no longer have access.") }
            }
            .interactiveDismissDisabled(phase.isWorking)
        }
        .onAppear { model.loadMembership(force: true) }
    }

    private func moveButton(_ icon: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 30, height: 30) }
            .buttonStyle(.borderless)
            .disabled(!enabled || phase.isWorking)
            .accessibilityLabel(label)
            .accessibilityIdentifier(label.replacingOccurrences(of: " ", with: "."))
    }

    private func move(_ scopes: [ScopeRecord], from index: Int, by offset: Int) {
        var order = scopes.map(\.id)
        order.swapAt(index, index + offset)
        let ids = order
        endEditing(); phase = .working("Saving your scope order…")
        Task {
            switch await model.manage({ m, c, w in try await m.saveScopeOrder(c, w, scopeIds: ids) }) {
            case .success: phase = .done("Personal scope order saved.")
            case .failure(let error): phase = .failed(error)
            }
        }
    }
}

/// Create a scope, or rename / describe / archive one you manage (sol scope form and delete confirmation).
struct ScopeEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let scope: ScopeRecord?
    @State private var name = ""
    @State private var description = ""
    @State private var phase = ManagementPhase.idle
    @State private var confirmArchive = false
    @State private var loaded = false

    var body: some View {
        let canManage = scope.map { ManagementPermissions.canManage($0, membership: model.membership) } ?? true
        Form {
            if scope == nil {
                Section {
                    Label("Scope settings", systemImage: "person.badge.key").font(.amb(.subheadline).weight(.semibold))
                    Text("This form creates a scope with your Manage access. Manage Workspace offers staged template/channel setup and permission controls.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("scopeEdit.limited")
            }
            Section("Name") {
                TextField("Scope name", text: $name).disabled(!canManage).accessibilityIdentifier("scopeEdit.name")
            }
            Section("Description (optional)") {
                WorkspaceContentTextEntry(text: $description, placeholder: "What this scope is for", field: "scope-description-\(scope?.id ?? "new")").lineLimit(2...6).disabled(!canManage)
                    .accessibilityIdentifier("scopeEdit.description")
            }
            if !canManage {
                Section { Text("You need Manage access to change this scope.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground) }
            }
            if let scope, canManage {
                Section {
                    Button("Archive scope", role: .destructive) { confirmArchive = true }.disabled(phase.isWorking)
                        .accessibilityIdentifier("scopeEdit.archive")
                }
                .confirmationDialog("Archive \(scope.name)?", isPresented: $confirmArchive, titleVisibility: .visible) {
                    Button("Archive scope", role: .destructive) { archive(scope) }
                } message: {
                    Text("This archives the scope and all its channels, including nonempty channels. Stored tasks, documents, messages and files remain intact in Tower; archived channels are no longer accessible. There is no restore control in Flight Deck.")
                }
            }
        }
        .macGroupedForm()
        .modifier(KeyboardDone())
            .modifier(ManagementStatusInset(phase: phase))
            .navigationTitle(scope == nil ? "New scope" : scope!.name)
        .inlineTitle()
        .toolbar {
            if canManage {
                ToolbarItem(placement: .confirmationAction) {
                    Button(scope == nil ? "Create" : "Save") { save() }
                        .disabled(phase.isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (scope != nil && name == scope!.name && description == (scope!.description ?? "")))
                        .accessibilityIdentifier("scopeEdit.save")
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true; name = scope?.name ?? ""; description = scope?.description ?? ""
        }
    }

    private func save() {
        let name = name, description = description, id = scope?.id
        endEditing(); phase = .working(id == nil ? "Creating the scope…" : "Saving…")
        Task {
            let result = await model.manage { m, c, w in
                if let id { try await m.updateScope(c, w, scopeId: id, name: name, description: description) }
                else { _ = try await m.createScope(c, w, name: name, description: description) }
            }
            switch result {
            case .success: if id == nil { dismiss() } else { phase = .done("Scope saved.") }
            case .failure(let error): phase = .failed(error)
            }
        }
    }

    private func archive(_ scope: ScopeRecord) {
        endEditing(); phase = .working("Archiving…")
        Task {
            switch await model.manage({ m, c, w in try await m.archiveScope(c, w, scopeId: scope.id) }) {
            case .success: dismiss()
            case .failure(let error): phase = .failed(error)
            }
        }
    }
}
