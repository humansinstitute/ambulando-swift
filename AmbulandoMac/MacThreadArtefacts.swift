import AmbulandoCore
import SwiftUI
import AppKit

struct MacThreadArtefactExpandedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
struct MacThreadArtefactsButton: View {
    let state: MacThreadArtefacts
    var body: some View {
        Button { state.browsing = true } label: { Image(systemName: "square.stack") }
            .buttonStyle(.borderless).help("Thread artefacts (\(state.members.count))")
            .accessibilityLabel("Thread artefacts (\(state.members.count))")
            .accessibilityIdentifier("thread.artefacts.browse").disabled(state.busy)
    }
}

/// Keep both conversation and editor trees mounted across tab/visibility changes.
struct MacThreadArtefactLayout<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openMention) private var inheritedOpen
    let state: MacThreadArtefacts
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    @ViewBuilder let content: () -> Content
    @State private var fraction: CGFloat = 0.34
    @State private var retainedWorkspaceWidth: CGFloat = 640
    @State private var retainedChatWidth: CGFloat = 360
    @State private var dragStart: CGFloat?
    @State private var threadQuery = LiveQuery<ThreadRecord?>(initial: nil)
    @Environment(\.scenePhase) private var phase
    var body: some View {
        GeometryReader { proxy in
            let chatWidth: CGFloat = state.expanded && state.shown ? 0 : state.shown ? max(280, min(proxy.size.width - 340, proxy.size.width * fraction)) : proxy.size.width
            let workspaceWidth = state.shown ? max(340, proxy.size.width - chatWidth - 6) : retainedWorkspaceWidth
            HStack(spacing: 0) {
                content().frame(width: chatWidth > 0 ? chatWidth : retainedChatWidth).frame(width: chatWidth).clipped()
                    .accessibilityHidden(state.expanded && state.shown)
                    .environment(\.macThreadArtefacts, state)
                    .environment(\.openMention, OpenMentionAction { kind, id in
                        if ["file", "doc", "document"].contains(kind.lowercased()) {
                            state.open(kind: kind.lowercased(), id: id.lowercased())
                        } else { inheritedOpen(kind: kind, id: id) }
                    })
                Rectangle().fill(Amb.border).frame(width: state.shown ? 6 : 0)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { value in
                        if dragStart == nil { dragStart = fraction }
                        fraction = max(0.2, min(0.7, (dragStart ?? fraction) + value.translation.width / max(1, proxy.size.width)))
                    }.onEnded { _ in dragStart = nil })
                    .accessibilityLabel("Resize conversation and artefact workspace")
                    .accessibilityIdentifier("thread.artefacts.divider")
                workspaceBody.frame(width: workspaceWidth).frame(width: max(0, proxy.size.width - chatWidth - (state.shown ? 6 : 0)))
                    .clipped().opacity(state.shown ? 1 : 0).allowsHitTesting(state.shown)
                    .accessibilityHidden(!state.shown)
            }
            .onChange(of: workspaceWidth) { _, width in if state.shown { retainedWorkspaceWidth = width } }
            .onChange(of: chatWidth) { _, width in if width > 0 { retainedChatWidth = width } }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacThreadArtefactsCheck") { MacThreadArtefacts.testingState = state }
        }
        #endif
        .task(id: model.selectedWorkspaceBoundary?.id) {
            guard let sync = model.sync, let connection = model.connection, let thread = target.threadId else { return }
            state.openFallback = { kind, id in inheritedOpen(kind: kind, id: id) }
            do { state.transport = try sync.threadMembershipTransport(connection, workspace, threadId: thread) }
            catch { state.failure = error.localizedDescription; return }
            threadQuery.start(store: store, matches: { $0.workspaceId == workspace.id && $0.table == .threads }) {
                try await store.reader.thread(workspaceId: workspace.id, id: thread)
            }
            await state.refresh()
        }
        .task(id: state.members) {
            guard let sync = model.sync, let connection = model.connection else { return }
            for member in state.members {
                do { state.labels[member] = try await sync.threadArtefactLabel(connection, workspace, member: member) }
                catch { state.labels[member] = "Unavailable \(member.kind == "doc" ? "document" : "artefact")" }
            }
        }
        .onChange(of: threadQuery.value, initial: true) { _, row in if let row { state.observe(row) } }
        .onChange(of: phase) { _, phase in if phase == .active { Task { await state.refresh() } } }
        .onDisappear { threadQuery.stop() }
        .sheet(isPresented: Bindable(state).browsing) {
            MacThreadArtefactBrowser(state: state, target: target, workspace: workspace, store: store)
        }
        .preference(key: MacThreadArtefactOwnerKey.self, value: state)
        .preference(key: MacThreadArtefactExpandedKey.self, value: state.shown)
    }
    private var workspaceBody: some View {
        VStack(spacing: 0) {
            HStack {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(state.tabs.filter { $0.open && $0.attached }) { tab in
                                MacThreadArtefactTabLabel(state: state, tab: tab).id(tab.id)
                            }
                        }.padding(2)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
                        Task { @MainActor in
                            await Task.yield()
                            if let id = state.selected { proxy.scrollTo(id, anchor: .trailing) }
                        }
                    }
                    .onChange(of: state.shown) { _, shown in
                        if shown, let id = state.selected { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: state.selected) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onChange(of: state.tabs.filter(\.open).map(\.id)) { _, _ in
                        if let id = state.selected { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                Button { state.browsing = true } label: { Image(systemName: "plus").frame(width: 26, height: 28).contentShape(Rectangle()) }
                    .help("Open an existing Doc or artefact")
                    .accessibilityLabel("Browse artefacts")
                    .accessibilityIdentifier("thread.artefacts.add")
                Button { state.expanded.toggle() } label: { Image(systemName: state.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 26, height: 28).contentShape(Rectangle()) }
                    .help(state.expanded ? "Restore conversation split" : "Expand artefact workspace")
                    .accessibilityLabel(state.expanded ? "Restore conversation split" : "Expand artefact workspace")
                    .accessibilityIdentifier("thread.artefacts.expand")
                Button { state.shown = false; state.expanded = false } label: { Image(systemName: "sidebar.right").frame(width: 26, height: 28).contentShape(Rectangle()) }
                    .help("Close workspace; keep tabs and edits")
                    .accessibilityLabel("Close artefact workspace")
                    .accessibilityIdentifier("thread.artefacts.close")
            }.buttonStyle(.borderless).controlSize(.small).padding(6).background(Amb.card).disabled(state.busy)
            if let failure = state.failure { Text(failure).font(.caption).foregroundStyle(Amb.destructive).padding(8) }
            if state.tabs.contains(where: { !$0.attached }) {
                Menu("Detached recovery · automatic publishing held") {
                    ForEach(state.tabs.filter { !$0.attached }) { tab in
                        Button("Open recovery: \(tab.title)") { state.show(tab) }
                    }
                }.accessibilityIdentifier("thread.artefacts.recovery")
            }
            if let tab = state.tabs.first(where: { $0.id == state.selected && !$0.attached }) {
                Text("Removed from thread. Local recovery retained; excluded from Send. Explicit source Save still publishes to the source.")
                    .font(.caption).foregroundStyle(Amb.warning)
                Button("Save to source and resume if attached") {
                    Task { await state.saveRecovery(tab) }
                }.accessibilityIdentifier("thread.artefacts.recovery.save")
            }
            Text("Send includes exact saved revisions of open tabs. Unsaved changes must save first.")
                .font(.caption).foregroundStyle(Amb.mutedForeground).padding(.horizontal, 8)
            Divider()
            ZStack {
                ForEach(state.tabs) { tab in
                    NavigationStack {
                        Group {
                            if tab.kind == "doc" { DocumentView(docId: tab.id, workspace: workspace, store: store) }
                            else { FileDetailView(fileId: tab.id, workspace: workspace, store: store) }
                        }
                        .environment(\.macThreadArtefactTab, tab)
                    }
                    .opacity(state.selected == tab.id && tab.open ? 1 : 0)
                    .allowsHitTesting(state.selected == tab.id && tab.open && !state.busy)
                    .disabled(state.busy)
                    .accessibilityHidden(state.selected != tab.id || !tab.open)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread.artefacts.workspace")
    }
}


private struct MacThreadArtefactTabLabel: View {
    let state: MacThreadArtefacts
    let tab: MacThreadArtefactTab
    @State private var hovering = false
    private var selected: Bool { state.selected == tab.id }
    var body: some View {
        HStack(spacing: 2) {
            Button { state.selected = tab.id; state.shown = true } label: {
                Label(tab.title, systemImage: tab.kind == "doc" ? "doc.text" : tab.icon)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 70, maxWidth: 180, alignment: .leading)
                    .padding(.leading, 9).padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .help(tab.title).accessibilityLabel(tab.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("thread.artefacts.tab.\(tab.id)")
            Button { state.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 23, height: 26).contentShape(Rectangle())
            }
            .foregroundStyle(selected || hovering ? Amb.foreground : Amb.mutedForeground)
            .help("Close tab; save pending changes first")
            .accessibilityLabel("Close \(tab.title) tab; retain work")
            .accessibilityIdentifier("thread.artefacts.tab.close.\(tab.id)")
        }
        .buttonStyle(.plain)
        .background(selected ? Amb.selectedFill : hovering ? Color.primary.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottom) {
            if selected { Capsule().fill(Amb.primary).frame(height: 2).padding(.horizontal, 8) }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close local view") { state.close(tab) }
            Button("Remove from thread", role: .destructive) {
                if let member = try? ThreadArtefactMember(kind: tab.kind, id: tab.id) { state.remove(member) }
            }.disabled(state.membershipError != nil || state.busy)
        }
    }
}
