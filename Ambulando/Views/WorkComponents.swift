import AmbulandoCore
import SwiftUI

/// Scope filter shared by Tasks, Docs and Files (nil = every scope in the workspace).
struct ScopeChoice: Sendable, Equatable {
    var scopes: [ScopeRecord] = []
    var channels: [ChannelRecord] = []

    func channelName(_ id: String?) -> String? { channels.first { $0.id == id }?.name }
    func scopeName(_ id: String?) -> String? { scopes.first { $0.id == id }?.name }
    func scope(ofChannel id: String) -> String? { channels.first { $0.id == id }?.scopeId }

    /// Channels a new record can be written to in `context`: the context's channel, its scope's channels, or (Home) all.
    /// Tower lists only channels this member can read; it still decides write access and rejects a write without it.
    func channels(in context: WorkContext) -> [ChannelRecord] {
        guard let scopeId = context.scopeId else { return channels }
        if let channelId = context.channelId { return channels.filter { $0.id == channelId } }
        return channels.filter { $0.scopeId == scopeId }
    }
}

func scopeChoice(_ store: LocalStore, _ workspaceId: String) async throws -> ScopeChoice {
    async let scopes = store.reader.scopes(workspaceId: workspaceId)
    async let channels = store.reader.channels(workspaceId: workspaceId)
    async let order = store.reader.state(WorkspaceSync.scopeOrderKey(workspaceId))
    let ordered = ScopeOrdering.apply(try await scopes, order: ScopeOrdering.decode(try await order), id: \.id)
    return ScopeChoice(scopes: ordered, channels: try await channels)
}

struct ScopeMenu: View {
    let choice: ScopeChoice
    @Binding var selection: String?

    var body: some View {
        Menu {
            Button { selection = nil } label: { if selection == nil { Label("All scopes", systemImage: "checkmark") } else { Text("All scopes") } }
            ForEach(choice.scopes) { scope in
                Button { selection = scope.id } label: {
                    if selection == scope.id { Label(scope.name, systemImage: "checkmark") } else { Text(scope.name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(choice.scopeName(selection) ?? "All scopes").lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
        }
        .accessibilityIdentifier("scope.filter")
    }
}

/// Names for npubs from the local directory.
func directoryNames(_ store: LocalStore, _ workspaceId: String) async throws -> [String: String] {
    Dictionary(try await store.reader.members(workspaceId: workspaceId).map { ($0.npub, $0.label) }, uniquingKeysWith: { a, _ in a })
}

func displayName(_ npub: String?, _ names: [String: String], me: String?) -> String {
    guard let npub else { return "Unknown" }
    if npub == me { return names[npub].map { "\($0)" } ?? "You" }
    return names[npub] ?? shortNpub(npub)
}

/// State of a queued write, shown beside the thing it changes.
struct WriteStatusLine: View {
    @Environment(AppModel.self) private var model
    let item: WriteItem
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(text, systemImage: icon).font(.caption).foregroundStyle(tone)
            Spacer(minLength: 4)
            switch item.state {
            case .failed, .retrying:
                Button("Retry") { retry(force: false) }.font(.caption.weight(.semibold)).accessibilityIdentifier("write.retry")
                if item.state == .failed { discard }
            case .conflict:
                Button("Apply mine") { retry(force: true) }.font(.caption.weight(.semibold)).accessibilityIdentifier("write.force")
                discard
            default: EmptyView()
            }
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("write.status")
    }

    private var discard: some View {
        Button("Discard", role: .destructive) { Task { try? await model.store?.writer.discardWrite(id: item.id) } }
            .font(.caption.weight(.semibold)).accessibilityIdentifier("write.discard")
    }

    private var text: String {
        switch item.state {
        case .queued, .sending: model.isUnlocked ? "\(label): sending…" : "\(label): waits for unlock"
        case .retrying: "\(label): \(item.lastError ?? "will retry")"
        case .failed: "\(label) not saved. \(item.lastError ?? "")"
        case .conflict: item.lastError ?? "Changed elsewhere."
        }
    }
    private var icon: String {
        switch item.state {
        case .queued, .sending: "arrow.up.circle"
        case .retrying: "arrow.clockwise.circle"
        case .failed: "exclamationmark.circle"
        case .conflict: "arrow.triangle.branch"
        }
    }
    private var tone: Color {
        switch item.state {
        case .queued, .sending: Amb.mutedForeground
        case .retrying, .conflict: Amb.warning
        case .failed: Amb.destructive
        }
    }

    private func retry(force: Bool) {
        guard let writes = model.writes, let connection = model.connection, connection.id == item.connectionId else { return }
        Task { try? await writes.retry(item.id, connection: connection, force: force) }
    }
}

/// Destination for a `WorkRoute` inside any tab's navigation stack.
struct WorkDestination: View {
    @Environment(AppModel.self) private var model
    let route: WorkRoute
    /// Opened from a workspace-wide list (Inbox, Search): the shared context follows the record.
    var adoptsContext = false

    var body: some View {
        Group { destination }
            .task(id: route) { if adoptsContext { model.adoptContext(for: route) } }
    }

    @ViewBuilder private var destination: some View {
        if let workspace = model.selectedWorkspace, route.workspaceId == workspace.id, let store = model.store, let connection = model.connection {
            switch route {
            case .task(_, let id): TaskDetailView(taskId: id, workspace: workspace, store: store)
            case .doc(_, let id): DocumentView(docId: id, workspace: workspace, store: store)
            case .file(_, let id): FileDetailView(fileId: id, workspace: workspace, store: store)
            case .thread(_, let channel, let thread):
                ThreadView(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: channel, threadId: thread), workspace: workspace, store: store)
            case .channel(_, let channel):
                ChannelView(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: channel), workspace: workspace, store: store)
            }
        } else {
            ContentUnavailableView("Not in this workspace", systemImage: "arrow.uturn.backward", description: Text("This item belongs to another workspace."))
        }
    }
}

/// A tab's navigation stack whose root renders from the store and whose pushes are `WorkRoute`s.
struct WorkStack<Root: View, Banner: View>: View {
    @Binding var showSettings: Bool
    @Binding var path: [WorkRoute]
    /// Context-bound modes show the shared Scope | Channel strip; the global Inbox does not.
    var contextBar = true
    @ViewBuilder let banner: () -> Banner
    @ViewBuilder let root: () -> Root

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                banner()
                if contextBar { ContextBar() }
                root()
            }
            .background(Amb.background)
            .toolbarItems(showSettings: $showSettings)
            .navigationDestination(for: WorkRoute.self) { WorkDestination(route: $0, adoptsContext: !contextBar) }
        }
    }
}

enum WorkTime {
    static func relative(_ iso: String) -> String { ChatTime.label(iso) }
}

struct EmptyNote: View {
    let title: String
    let systemImage: String
    let detail: String
    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
            .foregroundStyle(Amb.mutedForeground)
    }
}

/// Byte count for display.
func byteLabel(_ count: Int?) -> String {
    guard let count else { return "" }
    return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

/// Filter and action row under the navigation bar. (A `.bottomBar` toolbar would sit behind the tab bar.)
struct ListHeaderBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 12) { content() }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Amb.background)
    }
}
