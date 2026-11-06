import AmbulandoCore
import SwiftUI

/// Choose the family conversation once: space → channel → an existing conversation (or, deliberately, a new one).
/// Everything listed is what Tower already lets this account see; the app adds no permissions of its own.
@MainActor
@Observable
final class FamilySetupModel {
    enum Step: Equatable { case workspace, channel, conversation }

    var step: Step = .workspace
    var entry: EnabledWorkspaceEntry?
    var channel: ChannelRecord?
    var channelLabel = ""
    var options: [FamilyConversationOption] = []
    var loading = false
    var error: String?
    /// True only when the thread list of the chosen channel was fetched from Tower during this setup.
    var refreshedFromTower = false
    var incomplete = false

    func chooseWorkspace(_ entry: EnabledWorkspaceEntry, app: AppModel) async {
        self.entry = entry; error = nil; loading = true; defer { loading = false }
        if !entry.enabled { app.setWorkspaceEnabled(entry, true) }
        app.openWorkspace(entry)
        // The workspace's own store and sync start before its channels can be listed.
        for _ in 0..<60 where !(entry.runtime != nil && app.selectedWorkspaceId == entry.workspace.id && entry.navigation.loaded) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard entry.runtime != nil, app.selectedWorkspaceId == entry.workspace.id else {
            error = "Could not open \(entry.workspace.label). Check the connection and try again."
            return
        }
        step = .channel
    }

    func chooseChannel(_ channel: ChannelRecord, label: String, family: FamilyChatModel) async {
        self.channel = channel; channelLabel = label; step = .conversation
        options = []; refreshedFromTower = false
        await reloadConversations(family: family)
    }

    /// Fetches the channel's conversations from Tower (never only the cache), so the list shown and the check before a
    /// creation both reflect what exists now.
    func reloadConversations(family: FamilyChatModel) async {
        guard let entry, let channel, let api = family.api(for: entry), let runtime = entry.runtime else { return }
        loading = true; error = nil; defer { loading = false }
        do {
            let result = try await api.threads(workspaceId: entry.workspace.id, appNpub: entry.workspace.appNpub, channelId: channel.id)
            try await runtime.store.writer.upsertThreads(workspaceId: entry.workspace.id, result.threads)
            options = FamilyConversationOption.options(fromThreads: result.threads)
            incomplete = !result.complete
            refreshedFromTower = true
        } catch {
            refreshedFromTower = false
            self.error = "Could not load the conversations in this channel. \(error.localizedDescription)"
        }
    }

    func back() {
        error = nil
        switch step {
        case .workspace: break
        case .channel: step = .workspace; entry = nil
        case .conversation: step = .channel; channel = nil; options = []
        }
    }
}

struct FamilySetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(FamilyChatModel.self) private var family
    @State private var setup = FamilySetupModel()
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BrandHeader(subtitle: "Pick the one family conversation this app will always open.").padding(.top, 24)
                if let notice = family.notice { FamilyNotice(tone: .info, text: notice) }
                if setup.step != .workspace {
                    Button { setup.back() } label: { Label("Back", systemImage: "chevron.left").font(.amb(.title3)) }
                        .frame(minHeight: Amb.touchTarget).accessibilityIdentifier("family.setup.back")
                }
                switch setup.step {
                case .workspace: workspaceStep
                case .channel: channelStep
                case .conversation: conversationStep
                }
                if let error = setup.error { FamilyNotice(tone: .error, text: error) }
                Button { showSettings = true } label: { Label("Account and connection", systemImage: "gearshape").font(.amb(.body)) }
                    .frame(minHeight: Amb.touchTarget).accessibilityIdentifier("family.setup.settings")
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showSettings) { FamilySettingsView(binding: nil) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("family.setup")
    }

    // MARK: Steps

    private var entries: [EnabledWorkspaceEntry] { app.workspaceEntries.filter { $0.connection.id == app.connection?.id } }

    private var workspaceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle(number: 1, text: "Where does your family chat live?")
            if entries.isEmpty {
                FamilyNotice(tone: .info, text: "Looking for the spaces your account can open… If this stays empty, your account has no space yet. Ask whoever runs your NStack to add you.")
                Button { app.retryConnection(); app.refresh(force: true) } label: { Text("Check again") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            ForEach(entries) { entry in
                ChoiceRow(title: entry.workspace.label, detail: entry.workspace.role.map { "You are \($0)" }, identifier: "family.workspace.\(entry.workspace.id)") {
                    Task { await setup.chooseWorkspace(entry, app: app) }
                }
            }
            if setup.loading { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    private var channelStep: some View {
        let navigation = setup.entry?.navigation ?? NavigationSnapshot()
        return VStack(alignment: .leading, spacing: 12) {
            StepTitle(number: 2, text: "Which channel is it in?")
            Text(setup.entry?.workspace.label ?? "").font(.amb(.headline)).foregroundStyle(Amb.mutedForeground)
            if navigation.groups.flatMap(\.channels).isEmpty {
                FamilyNotice(tone: .info, text: navigation.loaded ? "No channels are available to your account in this space." : "Loading channels…")
            }
            ForEach(navigation.groups, id: \.scope.id) { group in
                if !group.channels.isEmpty {
                    Text(group.scope.name).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.mutedForeground).padding(.top, 6)
                    ForEach(group.channels) { channel in
                        ChoiceRow(title: navigation.label(channel), detail: nil, identifier: "family.channel.\(channel.id)") {
                            Task { await setup.chooseChannel(channel, label: navigation.label(channel), family: family) }
                        }
                    }
                }
            }
        }
    }

    private var conversationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle(number: 3, text: "Which conversation is your family chat?")
            Text("\(setup.entry?.workspace.label ?? "") · \(setup.channelLabel)").font(.amb(.headline)).foregroundStyle(Amb.mutedForeground)
            if setup.loading && setup.options.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            if setup.refreshedFromTower && setup.options.isEmpty {
                FamilyNotice(tone: .info, text: "There is no conversation in this channel yet. Start your family conversation once in Ambulando, then come back here and choose it. This app only opens a conversation that already exists.")
                    .accessibilityIdentifier("family.setup.empty")
            }
            ForEach(setup.options) { option in
                ChoiceRow(title: option.title, detail: detail(option), identifier: "family.conversation.\(option.id)") { Task { await bind(option) } }
            }
            if setup.incomplete { FamilyNotice(tone: .info, text: "Only the most recent conversations are shown.") }
            Button { Task { await setup.reloadConversations(family: family) } } label: { Text(setup.refreshedFromTower ? "Look again" : "Load conversations again") }
                .buttonStyle(.bordered).controlSize(.large).frame(minHeight: Amb.touchTarget)
                .accessibilityIdentifier("family.setup.reload")
        }
    }

    private func detail(_ option: FamilyConversationOption) -> String? {
        var parts: [String] = []
        if option.archived { parts.append("Archived") }
        if !option.firstMessage.isEmpty, option.firstMessage != option.title { parts.append(String(option.firstMessage.prefix(80))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func bind(_ option: FamilyConversationOption) async {
        guard let entry = setup.entry, let channel = setup.channel, let connection = app.connection else { return }
        let binding = FamilyBinding(connectionId: connection.id, origin: connection.origin, signerNpub: connection.signerNpub,
                                    workspaceId: entry.workspace.id, appNpub: entry.workspace.appNpub, workspaceLabel: entry.workspace.label,
                                    channelId: channel.id, channelName: setup.channelLabel, threadId: option.id, conversationTitle: option.title)
        await family.save(binding)
    }
}

private struct StepTitle: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.amb(.headline)).foregroundStyle(Amb.primaryForeground)
                .frame(width: 34, height: 34).background(Amb.primary, in: Circle()).accessibilityHidden(true)
            Text(text).font(.amb(.title2).weight(.bold)).foregroundStyle(Amb.foreground).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

/// A large, whole-row button for one choice.
private struct ChoiceRow: View {
    let title: String
    let detail: String?
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.amb(.title3).weight(.semibold)).foregroundStyle(Amb.foreground).multilineTextAlignment(.leading)
                    if let detail { Text(detail).font(.amb(.callout)).foregroundStyle(Amb.mutedForeground).multilineTextAlignment(.leading).lineLimit(3) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(Amb.mutedForeground).accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusControl).stroke(Amb.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
