import AmbulandoCore
import SwiftUI

// The web app's primary navigation on a phone: a drawer with the workspace, Home, "Unread & Active" channels and every
// scope with its channels (collapsible), opened from the menu button in every mode. Choosing Home, a scope or a channel
// sets the shared context that Chat, Tasks, Docs and Files read and write in (sol `sidebar-navigation.js`,
// `index.html` #sol-primary-navigation and `.mobile-scope-switcher`).

/// The menu button that opens the sidebar (toolbar leading item of every mode).
struct SidebarButton: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.tabletNavigation) private var tablet
    #endif
    var body: some View {
        Button {
            #if os(iOS)
            if let tablet, tablet.available {
                tablet.collapsed.toggle()
            } else {
                withAnimation(.snappy) { model.sidebarOpen = true }
            }
            #else
            withAnimation(.snappy) { model.sidebarOpen = true }
            #endif
        } label: {
            Image(systemName: "line.3.horizontal").font(.amb(.body).weight(.semibold)).foregroundStyle(Amb.foreground)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Open navigation")
        .accessibilityIdentifier("sidebar.open")
    }
}

/// Context strip under the navigation bar (sol `.mobile-scope-switcher`): workspace avatar (Home), current scope and
/// channel. Tapping it opens the sidebar.
struct ContextBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let nav = model.navigation.value
        let context = model.context
        HStack(spacing: 8) {
            Button { model.selectContext(.home) } label: { WorkspaceAvatar(label: model.selectedWorkspace?.label ?? "A", size: 26) }
                .buttonStyle(.plain)
                .accessibilityLabel("Show all in \(model.selectedWorkspace?.label ?? "workspace")")
                .accessibilityIdentifier("context.home")
            Button { withAnimation(.snappy) { model.sidebarOpen = true } } label: {
                HStack(spacing: 6) {
                    Text(nav.scope(context.scopeId)?.name ?? "All scopes")
                        .font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1)
                    Text("|").font(.amb(.subheadline)).foregroundStyle(Amb.border).accessibilityHidden(true)
                    Text(nav.channel(context.channelId).map { "#" + nav.label($0) } ?? (context.isHome ? "Everything" : "All channels"))
                        .font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.amb(.caption).weight(.semibold)).foregroundStyle(Amb.mutedForeground)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(contextDescription(nav, context))
            .accessibilityHint("Opens scopes and channels")
            .accessibilityIdentifier("context.bar")
            // sol `.view-lock-button`: keep this section when choosing a scope or channel (otherwise Deck opens).
            if model.canLockCurrentView {
                let locked = model.isCurrentViewLocked
                Button { model.toggleCurrentViewLock() } label: {
                    Image(systemName: locked ? "lock.fill" : "lock.open").font(.amb(.caption).weight(.semibold))
                        .foregroundStyle(locked ? Amb.primary : Amb.mutedForeground)
                        .frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(locked ? "Unlock \(model.mode.title) view" : "Keep \(model.mode.title) when changing scope or channel")
                .accessibilityAddTraits(locked ? .isSelected : [])
                .accessibilityIdentifier("context.lock")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Amb.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Amb.border.opacity(0.6)).frame(height: 0.5) }
    }

    private func contextDescription(_ nav: NavigationSnapshot, _ context: WorkContext) -> String {
        guard let scope = nav.scope(context.scopeId) else { return "Current context: all scopes" }
        if let channel = nav.channel(context.channelId) { return "Current scope: \(scope.name), channel: \(nav.label(channel))" }
        return "Current scope: \(scope.name), all channels"
    }
}

struct WorkspaceAvatar: View {
    let label: String
    var size: CGFloat = 28
    var body: some View {
        // sol `.sidebar-workspace-avatar-fallback`: solid primary with its foreground.
        Text(initials).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Amb.primaryForeground)
            .frame(width: size, height: size)
            .background(Amb.primary, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            .accessibilityHidden(true)
    }
    private var initials: String {
        let words = label.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return String(words.prefix(2).compactMap(\.first)).uppercased().ifEmpty("A")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// The drawer. Presented over every mode; dismissed by choosing a context, the backdrop, a swipe left or Escape.
struct SidebarDrawer: View {
    @Environment(AppModel.self) private var model
    @State private var dragOffset: CGFloat = 0
    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.86, 340)
            ZStack(alignment: .leading) {
                Color.black.opacity(0.32).ignoresSafeArea()
                    .onTapGesture { close() }
                    .accessibilityLabel("Close navigation")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("sidebar.backdrop")
                SidebarContent()
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Amb.card.ignoresSafeArea())
                    .overlay(alignment: .trailing) { Rectangle().fill(Amb.border).frame(width: 0.5).ignoresSafeArea() }
                    .offset(x: min(0, dragOffset))
                    .gesture(DragGesture(minimumDistance: 12).onChanged { dragOffset = $0.translation.width }.onEnded { value in
                        if value.translation.width < -width / 4 { close() } else { withAnimation(.snappy) { dragOffset = 0 } }
                    })
                    .accessibilityAddTraits(.isModal)
                    .accessibilityFocused($focused)
            }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
        .onAppear { focused = true }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func close() {
        withAnimation(.snappy) { model.sidebarOpen = false }
        dragOffset = 0
    }
}

struct SidebarContent: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: SidebarSheet?
    /// A channel created in the New channel sheet, opened in Chat once the sheet has gone (as the web selects it).
    @State private var created: ChannelRecord?

    private func openCreated() {
        guard let channel = created else { return }
        created = nil
        model.selectContext(WorkContext(scopeId: channel.scopeId, channelId: channel.id))
        model.show(.chat)
    }

    var body: some View {
        let nav = model.navigation.value
        let context = model.context
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Button { model.chooseInSidebar(.home) } label: {
                        HStack(spacing: 8) {
                            WorkspaceAvatar(label: model.selectedWorkspace?.label ?? "A", size: 24)
                            Text("Home").font(.amb(.subheadline).weight(context.isHome ? .bold : .semibold))
                                .foregroundStyle(context.isHome ? Amb.selectedForeground : Amb.foreground)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(context.isHome ? Amb.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
                        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(Amb.border, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("All workspace activity")
                    .accessibilityAddTraits(context.isHome ? .isSelected : [])
                    .accessibilityIdentifier("sidebar.home")
                    .padding(.bottom, 8)

                    NavigationStatus(state: model.navigationState, compact: true)

                    let unread = SidebarNavigation.unreadChannels(nav.groups, unreadChannelIds: nav.unread)
                    if !unread.isEmpty {
                        SidebarHeading(text: "Unread & Active")
                        // Own identities: the same channel is also listed under its scope below.
                        ForEach(unread, id: \.unreadRowId) { channel in
                            ChannelRow(channel: channel, label: nav.label(channel), unread: true,
                                       active: context.channelId == channel.id, identifierPrefix: "sidebar.unread")
                        }
                        .padding(.bottom, 6)
                    }

                    ForEach(nav.groups) { group in
                        let collapsed = nav.collapsed.contains(group.id)
                        HStack(spacing: 2) {
                            Button { model.toggleScopeCollapsed(group.id) } label: {
                                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                    .font(.amb(.caption).weight(.bold)).foregroundStyle(Amb.mutedForeground)
                                    .frame(width: 28, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(group.scope.name) channels")
                            .accessibilityIdentifier("sidebar.collapse.\(group.scope.name)")
                            Button { model.chooseInSidebar(WorkContext(scopeId: group.id)) } label: {
                                Text(group.scope.name)
                                    .font(.amb(.footnote).weight(.heavy)).foregroundStyle(context.scopeId == group.id && context.channelId == nil ? Amb.primary : Amb.mutedForeground)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                    .padding(.horizontal, 4)
                                    .background(context.scopeId == group.id && context.channelId == nil ? Amb.selectedFill : Color.clear,
                                                in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(group.scope.name) home")
                            .accessibilityAddTraits(context.scopeId == group.id && context.channelId == nil ? .isSelected : [])
                            .accessibilityIdentifier("sidebar.scope.\(group.scope.name)")
                            // sol `.sidebar-scope-add-channel`: shown where the member may create channels in the scope.
                            if ManagementPermissions.canCreateChannel(in: group.scope, membership: model.membership) {
                                Button { sheet = .newChannel(group.scope) } label: {
                                    Image(systemName: "plus").font(.amb(.caption).weight(.bold)).foregroundStyle(Amb.mutedForeground)
                                        .frame(width: 30, height: 32).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Create channel in \(group.scope.name)")
                                .accessibilityIdentifier("sidebar.addChannel.\(group.scope.name)")
                            }
                        }
                        .padding(.top, 6)
                        if !collapsed {
                            if group.channels.isEmpty {
                                Text("No channels visible").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).padding(.leading, 34).padding(.vertical, 4)
                            }
                            ForEach(group.channels) { channel in
                                HStack(spacing: 0) {
                                    ChannelRow(channel: channel, label: nav.label(channel), unread: nav.unread.contains(channel.id),
                                               active: context.channelId == channel.id, identifierPrefix: "sidebar.channel")
                                    // sol `.sidebar-scope-channel-menu`: Channel settings on every channel.
                                    Button { sheet = .channelSettings(channel) } label: {
                                        Image(systemName: "ellipsis").font(.amb(.caption).weight(.bold)).foregroundStyle(Amb.mutedForeground)
                                            .frame(width: 30, height: 36).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Channel settings for \(nav.label(channel))")
                                    .accessibilityIdentifier("sidebar.channelSettings.\(nav.label(channel))")
                                }
                            }
                        }
                    }
                    if !nav.groups.isEmpty {
                        // sol `.sidebar-manage-scopes-footer`.
                        Button { sheet = .manageScopes } label: {
                            Label("Manage scopes", systemImage: "slider.horizontal.3").font(.amb(.subheadline).weight(.semibold))
                                .foregroundStyle(Amb.primary).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .padding(.horizontal, 10).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                        .accessibilityIdentifier("sidebar.manageScopes")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
            }
            WorkspaceFooter()
        }
        .onAppear { model.loadMembership() }
        .sheet(item: $sheet, onDismiss: openCreated) { sheet in
            switch sheet {
            case .newChannel(let scope): NewChannelSheet(scope: scope) { created = $0 }
            case .channelSettings(let channel): ChannelSettingsSheet(channelId: channel.id)
            case .manageScopes: ScopeManagementSheet()
            }
        }
    }
}

/// Management sheets opened from the sidebar.
enum SidebarSheet: Identifiable {
    case newChannel(ScopeRecord)
    case channelSettings(ChannelRecord)
    case manageScopes
    var id: String {
        switch self {
        case .newChannel(let scope): "new:\(scope.id)"
        case .channelSettings(let channel): "settings:\(channel.id)"
        case .manageScopes: "scopes"
        }
    }
}

private struct SidebarHeading: View {
    let text: String
    var body: some View {
        Text(text).font(.amb(.footnote).weight(.heavy)).foregroundStyle(Amb.mutedForeground)
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One channel in the sidebar (sol `.sidebar-scope-channel-row`).
private struct ChannelRow: View {
    @Environment(AppModel.self) private var model
    let channel: ChannelRecord
    let label: String
    let unread: Bool
    let active: Bool
    let identifierPrefix: String

    var body: some View {
        Button { model.chooseInSidebar(WorkContext(scopeId: channel.scopeId, channelId: channel.id)) } label: {
            HStack(spacing: 6) {
                if SidebarNavigation.isDirectMessageChannel(channel) {
                    Image(systemName: "person.2").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).frame(width: 14)
                } else {
                    Text("#").font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground).frame(width: 14)
                }
                // sol `.sidebar-scope-channel-row.active`: muted fill, primary bold label.
                Text(label).font(.amb(.subheadline).weight(active ? .bold : unread ? .semibold : .regular))
                    .foregroundStyle(active ? Amb.selectedForeground : unread ? Amb.foreground : Amb.mutedForeground).lineLimit(1)
                Spacer(minLength: 0)
                if unread { Circle().fill(Amb.brandOrange).frame(width: 7, height: 7).accessibilityHidden(true) }
            }
            .padding(.leading, 28).padding(.trailing, 10)
            .frame(minHeight: 36)
            .background(active ? Amb.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label + (unread ? ", unread" : ""))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("\(identifierPrefix).\(label)")
    }
}

/// Workspace switcher at the bottom of the sidebar (sol `.sidebar-workspace-footer`).
private struct WorkspaceFooter: View {
    @Environment(AppModel.self) private var model
    @State private var showManagement = false
    var body: some View {
        Menu {
            ForEach(model.workspaces.value) { workspace in
                Button { model.selectWorkspace(workspace.id); model.sidebarOpen = false } label: {
                    if workspace.id == model.selectedWorkspace?.id { Label(workspace.label, systemImage: "checkmark") } else { Text(workspace.label) }
                }
            }
            if model.workspaces.value.isEmpty { Text(model.workspaces.loaded ? "No workspaces yet" : "Loading…") }
            Divider()
            if model.selectedWorkspace != nil { Button("Manage Workspace", systemImage: "gearshape.2") { showManagement = true } }
        } label: {
            HStack(spacing: 10) {
                WorkspaceAvatar(label: model.selectedWorkspace?.label ?? "A", size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Workspace").font(.amb(.caption2)).foregroundStyle(Amb.mutedForeground)
                    Text(model.selectedWorkspace?.label ?? "Ambulando").font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.amb(.caption).weight(.semibold)).foregroundStyle(Amb.mutedForeground)
            }
            .padding(10)
            .background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
        }
        .fullLabelMenu()
        .accessibilityLabel("Switch workspace, current \(model.selectedWorkspace?.label ?? "none")")
        .accessibilityIdentifier("sidebar.workspace")
        .sheet(isPresented: $showManagement) {
            if let workspace = model.selectedWorkspace, let connection = model.connection {
                WorkspaceManagementView(workspace: workspace, connection: connection)
                    .id("\(connection.id):\(workspace.id)")

            }
        }
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(Amb.border).frame(height: 0.5) }
    }
}

/// The Chat root when the context is Home or a scope: that context's channels, grouped like the sidebar. Choosing one
/// sets the context to it, which opens its conversation.
struct ChannelDirectoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let nav = model.navigation.value
        let context = model.context
        let groups = nav.groups.filter { context.scopeId == nil || $0.id == context.scopeId }
        List {
            ForEach(groups) { group in
                Section {
                    if group.channels.isEmpty {
                        Text("No channels visible").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    }
                    ForEach(group.channels) { channel in
                        Button { model.selectContext(WorkContext(scopeId: group.id, channelId: channel.id)) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: SidebarNavigation.isDirectMessageChannel(channel) ? "person.2" : "number")
                                    .foregroundStyle(Amb.mutedForeground).frame(width: 20)
                                Text(nav.label(channel)).foregroundStyle(Amb.foreground)
                                    .fontWeight(nav.unread.contains(channel.id) ? .semibold : .regular)
                                Spacer()
                                if nav.unread.contains(channel.id) { Circle().fill(Amb.brandOrange).frame(width: 8, height: 8).accessibilityLabel("Unread") }
                                Image(systemName: "chevron.right").font(.amb(.caption).weight(.semibold)).foregroundStyle(Amb.border)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .appRowTextSize()
                        .accessibilityIdentifier("channel.\(nav.label(channel))")
                    }
                } header: {
                    Text(group.scope.name).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.itemHeading).textCase(nil)
                }
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
        .onChange(of: nav.groups.isEmpty, initial: true) { _, empty in if !empty { model.markCachedListShown() } }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .ready(let error?) = model.navigationState {
                NavigationStatus(state: .ready(refreshError: error), compact: true).padding(.horizontal, 16).padding(.top, 6)
            }
        }
        .overlay {
            if case .ready = model.navigationState {
                if groups.isEmpty {
                    ContentUnavailableView("No channels here", systemImage: "number", description: Text("This scope has no channels you can see."))
                }
            } else {
                NavigationStatus(state: model.navigationState, compact: false).padding(24)
            }
        }
        .refreshable { model.refresh(force: true) }
    }
}

private extension ChannelRecord {
    var unreadRowId: String { "unread:" + id }
}

/// The sidebar's (and the Chat channel list's) account of scopes and channels when they are not simply listed: loading,
/// a failure with Retry, a locked identity, or a list that may be out of date. An empty list is never shown without one.
struct NavigationStatus: View {
    @Environment(AppModel.self) private var model
    let state: NavigationLoadState
    /// Sidebar row style; otherwise a centred placeholder for the Chat channel list.
    let compact: Bool

    var body: some View {
        switch state {
        case .ready(nil):
            EmptyView()
        case .loading, .findingWorkspaces:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(state == .loading ? "Loading scopes and channels…" : "Finding your workspaces…")
                    .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    .accessibilityIdentifier("sidebar.state.loading")
            }
            .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
            .padding(.horizontal, compact ? 10 : 0)
        case .failed(let error), .workspacesFailed(let error):
            message(tone: .error, text: (state == .failed(error) ? "Couldn't load scopes and channels. " : "Couldn't load your workspaces. ") + error,
                    identifier: "sidebar.state.error", retry: true)
        case .ready(let error?):
            message(tone: .warning, text: "Couldn't refresh; showing scopes saved on this \(Device.name). " + error,
                    identifier: "sidebar.state.stale", retry: true)
        case .locked:
            message(tone: .info, text: model.identity == .unavailable
                    ? "Scopes and channels load once this \(Device.name) is unlocked."
                    : "Unlock your identity to load scopes and channels.", identifier: "sidebar.state.locked", retry: false)
        case .empty:
            message(tone: .info, text: "No scopes are shared with you in this workspace yet.", identifier: "sidebar.state.empty", retry: true)
        case .noWorkspaces:
            message(tone: .info, text: "This identity isn't a member of any workspace on this Tower yet.", identifier: "sidebar.state.empty", retry: true)
        }
    }

    private func message(tone: Notice.Tone, text: String, identifier: String, retry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.amb(.footnote))
                .foregroundStyle(tone == .error ? Amb.destructive : tone == .warning ? Amb.warning : Amb.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
            if retry {
                Button { model.retryNavigation() } label: { Label("Retry", systemImage: "arrow.clockwise").font(.amb(.footnote).weight(.semibold)) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("sidebar.retry")
            }
        }
        .padding(10)
        .frame(maxWidth: compact ? .infinity : 360, alignment: .leading)
        .background(tone == .error ? Amb.destructiveBackground : tone == .warning ? Amb.warningBackground : Amb.muted,
                    in: RoundedRectangle(cornerRadius: Amb.radiusControl, style: .continuous))
        .padding(.bottom, compact ? 6 : 0)
    }
}
