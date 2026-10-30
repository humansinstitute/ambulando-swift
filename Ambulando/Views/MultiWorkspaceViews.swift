import AmbulandoCore
import SwiftUI

extension WorkspaceColour {
    /// Text/icon palettes meet WCAG AA against the navigation surfaces in each appearance.
    func navigationColour(in scheme: ColorScheme) -> Color {
        let value: UInt32
        if scheme == .dark {
            switch self {
            case .blue: value = 0x8CB8FF
            case .green: value = 0x79D5A5
            case .purple: value = 0xCAA5F5
            case .red: value = 0xFF9EA8
            case .slate: value = 0xB7C8D6
            }
        } else { value = rgb }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    var nativeColour: Color {
        let value = rgb
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

/// The opt-in selection controls are shared by the empty state and the navigation footer.
struct WorkspaceSelectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false

    private var towers: [String] { Array(Set(model.workspaceEntries.map { $0.connection.origin })).sorted() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Checked workspaces appear together and keep syncing. Uncheck a workspace to pause its network activity; its saved content and drafts stay on this device.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(towers, id: \.self) { tower in
                    Section(tower) {
                        ForEach(model.workspaceEntries.filter { $0.connection.origin == tower }) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: Binding(get: { entry.enabled }, set: { model.setWorkspaceEnabled(entry, $0) })) {
                                    HStack {
                                        Circle().fill(entry.colour.nativeColour).frame(width: 10, height: 10).accessibilityHidden(true)
                                        Text(entry.workspace.label)
                                    }
                                }
                                #if os(macOS)
                                .toggleStyle(.checkbox)
                                #else
                                .toggleStyle(WorkspaceCheckboxStyle())
                                #endif
                                .accessibilityIdentifier("workspace.enabled.\(entry.workspace.label)")
                                WorkspaceColourPicker(entry: entry)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section {
                    Button("Add Tower connection", systemImage: "plus") { connecting = true }
                        .disabled(!model.isUnlocked)
                        .accessibilityIdentifier("workspace.addTower")
                }
            }
            .navigationTitle("Choose workspaces")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(idealWidth: 520, idealHeight: 560)
        .accessibilityIdentifier("workspace.selection")
        .sheet(isPresented: $connecting) {
            NavigationStack {
                ConnectView()
                    .navigationTitle("Add Tower")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { connecting = false } } }
            }
            .frame(idealWidth: 560, idealHeight: 620)
        }
    }
}

#if os(iOS)
private struct WorkspaceCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Amb.primary : Amb.mutedForeground)
                    .font(.title3)
                configuration.label.foregroundStyle(Amb.foreground)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle()).frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        .accessibilityValue(configuration.isOn ? "Enabled" : "Paused")
    }
}
#endif

struct WorkspaceColourPicker: View {
    @Environment(AppModel.self) private var model
    let entry: EnabledWorkspaceEntry

    var body: some View {
        Picker("Workspace colour", selection: Binding(get: { entry.colour }, set: { model.setWorkspaceColour(entry, colour: $0) })) {
            ForEach(WorkspaceColour.allCases, id: \.self) { colour in
                Label(colour.rawValue.capitalized, systemImage: "circle.fill")
                    .foregroundStyle(colour.nativeColour).tag(colour)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("workspace.colour.\(entry.workspace.label)")
    }
}

struct WorkspaceSelectionEmptyState: View {
    @State private var choosing = false
    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView("Choose a workspace", systemImage: "square.stack.3d.up", description: Text("All workspaces are paused. Enable one to return to its saved content and catch up."))
            Button("Choose workspaces", systemImage: "checklist") { choosing = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("workspace.empty.choose")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Amb.background)
        .sheet(isPresented: $choosing) { WorkspaceSelectionView() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.empty")
    }
}

/// Each action captures the entry rather than consulting the currently viewed workspace.
struct StackedWorkspaceNavigation: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = model.enabledWorkspaceEntries
        let hasUnread = entries.contains { !SidebarNavigation.unreadChannels($0.navigation.groups, unreadChannelIds: $0.navigation.unread).isEmpty }
        if hasUnread {
            Text("Unread & Active").font(.amb(.footnote).weight(.heavy)).foregroundStyle(Amb.mutedForeground)
                .padding(.horizontal, 10).padding(.vertical, 5).accessibilityAddTraits(.isHeader)
            ForEach(entries) { entry in
                ForEach(SidebarNavigation.unreadChannels(entry.navigation.groups, unreadChannelIds: entry.navigation.unread)) { channel in
                    WorkspaceChannelRow(entry: entry, channel: channel, showsWorkspace: true)
                        .id("unread:\(entry.id):\(channel.id)")
                }
            }
        }
        ForEach(entries) { entry in
            WorkspaceNavigationGroup(entry: entry)
                .padding(.top, 8)
        }
    }
}

private struct WorkspaceNavigationGroup: View {
    @Environment(AppModel.self) private var model
    let entry: EnabledWorkspaceEntry

    private var active: Bool { model.selectedWorkspaceBoundary == entry.boundary }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button { model.toggleWorkspaceCollapsed(entry) } label: {
                    Image(systemName: entry.collapsed ? "chevron.right" : "chevron.down")
                        .font(.amb(.caption).weight(.bold)).frame(width: 28, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.collapsed ? "Expand" : "Collapse") \(entry.workspace.label)")
                .accessibilityIdentifier("workspace.collapse.\(entry.workspace.label)")
                Circle().fill(entry.colour.nativeColour).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(entry.workspace.label).font(.amb(.subheadline).weight(.bold)).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button("Move up", systemImage: "arrow.up") { model.moveWorkspace(entry, offset: -1) }
                    Button("Move down", systemImage: "arrow.down") { model.moveWorkspace(entry, offset: 1) }
                    Divider()
                    Button("Pause workspace", systemImage: "pause") { model.setWorkspaceEnabled(entry, false) }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 32) }
                .fixedSize()
                .accessibilityLabel("Options for \(entry.workspace.label)")
                .accessibilityIdentifier("workspace.options.\(entry.workspace.label)")
            }
            .foregroundStyle(Amb.foreground)
            if !entry.collapsed {
                Button { model.openWorkspace(entry, context: .home) } label: {
                    Label("Home", systemImage: "house")
                        .font(.amb(.subheadline).weight(active && model.context.isHome ? .bold : .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(active && model.context.isHome ? Amb.selectedFill : .clear, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                }
                .buttonStyle(.plain).foregroundStyle(Amb.foreground)
                .accessibilityLabel("Home in \(entry.workspace.label)")
                .accessibilityIdentifier("workspace.home.\(entry.workspace.label)")
                if !entry.navigation.loaded {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading saved navigation…").font(.caption) }.padding(8)
                } else if entry.navigation.groups.isEmpty {
                    Text("No scopes visible").font(.caption).foregroundStyle(.secondary).padding(8)
                }
                ForEach(entry.navigation.groups) { group in
                    let collapsed = entry.navigation.collapsed.contains(group.id)
                    HStack(spacing: 2) {
                        Button { model.toggleScopeCollapsed(entry: entry, scopeId: group.id) } label: {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                .font(.amb(.caption).weight(.bold)).frame(width: 28, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(group.scope.name) in \(entry.workspace.label)")
                        Button { model.openWorkspace(entry, context: WorkContext(scopeId: group.id)) } label: {
                            Text(group.scope.name).font(.amb(.footnote).weight(.heavy))
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Amb.mutedForeground)
                    if !collapsed {
                        ForEach(group.channels) { channel in WorkspaceChannelRow(entry: entry, channel: channel) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.group.\(entry.workspace.label)")
    }
}

private struct WorkspaceChannelRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let entry: EnabledWorkspaceEntry
    let channel: ChannelRecord
    var showsWorkspace = false

    private var active: Bool { model.selectedWorkspaceBoundary == entry.boundary && model.context.channelId == channel.id }

    var body: some View {
        Button { model.openWorkspace(entry, context: WorkContext(scopeId: channel.scopeId, channelId: channel.id)) } label: {
            HStack(spacing: 6) {
                Image(systemName: SidebarNavigation.isDirectMessageChannel(channel) ? "person.2" : "number")
                    .font(.amb(.caption)).frame(width: 14)
                Text(entry.navigation.label(channel))
                    .font(.amb(.subheadline).weight(active ? .bold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if entry.navigation.unread.contains(channel.id) { Circle().fill(Amb.brandOrange).frame(width: 7, height: 7).accessibilityHidden(true) }
            }
            .foregroundStyle(entry.colour.navigationColour(in: scheme))
            .padding(.leading, 28).padding(.trailing, 10).frame(minHeight: 36)
            .background(active ? Amb.selectedFill : .clear, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.navigation.label(channel)), \(entry.workspace.label)\(Set(model.workspaceEntries.map { $0.connection.origin }).count > 1 ? ", " + entry.connection.origin : "")\(entry.navigation.unread.contains(channel.id) ? ", unread" : "")")
        .help("\(entry.navigation.label(channel)) in \(entry.workspace.label)")
        .accessibilityIdentifier("workspace.\(showsWorkspace ? "unread" : "channel").\(entry.workspace.label).\(entry.navigation.label(channel))")
    }
}

/// Place immediately above an input so similarly named channels always retain their destination label.
struct WorkspaceComposerContext: View {
    @Environment(AppModel.self) private var model
    var workspace: WorkspaceRecord? = nil
    var connectionId: String? = nil
    var body: some View {
        if let workspace = workspace ?? model.selectedWorkspace {
            let colour = model.workspaceEntries.first { $0.workspace.id == workspace.id && $0.workspace.appNpub == workspace.appNpub && $0.connection.id == (connectionId ?? model.connection?.id) }?.colour ?? .blue
            HStack(spacing: 6) {
                Circle().fill(colour.nativeColour).frame(width: 7, height: 7).accessibilityHidden(true)
                Text("Working in \(workspace.label)").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 4)
            .accessibilityIdentifier("composer.workspace")
        }
    }
}

/// Colour belongs to the existing navigation chrome, without inserting content or changing toolbar items.
struct WorkspaceHeaderTint: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    private var background: Color {
        guard let entry = model.workspaceEntries.first(where: { $0.boundary == model.selectedWorkspaceBoundary }) else { return Amb.card }
        let rgb = entry.colour.rgb
        let base: UInt32 = scheme == .dark ? 0x1A2238 : 0xFFFFFF
        let amount = 0.12
        func channel(_ shift: UInt32) -> Double {
            (Double((base >> shift) & 255) * (1 - amount) + Double((rgb >> shift) & 255) * amount) / 255
        }
        return Color(red: channel(16), green: channel(8), blue: channel(0))
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        content
            .toolbarBackground(background, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        #endif
    }
}
