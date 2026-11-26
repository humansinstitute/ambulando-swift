#if os(iOS)
import AmbulandoCore
import SwiftUI

/// State belongs to the complete verified routing/identity boundary supplied by ThreadView.id.
struct PhoneThreadArtefactHost<Content: View>: View {
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    @ViewBuilder let content: (MacThreadArtefacts) -> Content
    @State private var state = MacThreadArtefacts()
    var body: some View {
        PhoneThreadArtefactLayout(state: state, target: target, workspace: workspace, store: store) { content(state) }
    }
}

/// Header-only navigation. Both trees stay mounted: switching never recreates an editor or the chat scroll view.
struct PhoneThreadArtefactLayout<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openMention) private var inheritedOpen
    @Environment(\.scenePhase) private var phase
    let state: MacThreadArtefacts
    let target: ChatTarget
    let workspace: WorkspaceRecord
    let store: LocalStore
    @ViewBuilder let content: () -> Content
    @State private var threadQuery = LiveQuery<ThreadRecord?>(initial: nil)

    var body: some View {
        ZStack {
            content()
                .opacity(state.shown ? 0 : 1).allowsHitTesting(!state.shown && !state.busy)
                .accessibilityHidden(state.shown)
            workspaceBody
                .opacity(state.shown ? 1 : 0).allowsHitTesting(state.shown && !state.busy)
                .accessibilityHidden(!state.shown)
        }
        .environment(\.macThreadArtefacts, state)
        .environment(\.openMention, OpenMentionAction { kind, id in
            if ["file", "doc", "document"].contains(kind.lowercased()) {
                state.open(kind: kind.lowercased(), id: id.lowercased())
            } else { inheritedOpen(kind: kind, id: id) }
        })
        .task(id: model.selectedWorkspaceBoundary?.id) {
            guard let sync = model.sync, let connection = model.connection, let thread = target.threadId,
                  connection.id == target.connectionId, model.selectedWorkspaceId == workspace.id else { return }
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
        .onChange(of: phase) { _, phase in
            if phase == .active { Task { await state.refresh() } }
            else if phase == .background { Task { _ = await state.checkpointAll() } }
        }
        .onDisappear { threadQuery.stop() }
        .sheet(isPresented: Bindable(state).browsing) {
            MacThreadArtefactBrowser(state: state, target: target, workspace: workspace, store: store)
        }
        .preference(key: MacThreadArtefactOwnerKey.self, value: state)
    }

    private var workspaceBody: some View {
        VStack(spacing: 0) {
            HStack {
                Button { state.shown = false } label: { Label("Back to chat", systemImage: "chevron.left") }
                    .accessibilityIdentifier("thread.artefacts.chat")
                Spacer(minLength: 4)
                Menu {
                    ForEach(state.tabs.filter { $0.open && $0.attached }) { tab in
                        Button("\(tab.title) · \(tab.revisionLabel)") { state.show(tab) }
                    }
                    Divider()
                    Button("Browse artefacts", systemImage: "plus") { state.browsing = true }
                    if let tab = selected {
                        Button("Close local view") { state.close(tab) }
                        if tab.attached {
                            Button("Remove from thread", role: .destructive) {
                                if let member = try? ThreadArtefactMember(kind: tab.kind, id: tab.id) { state.remove(member) }
                            }
                        }
                    }
                } label: {
                    Text(selected.map { "\($0.title) · \($0.revisionLabel)" } ?? "Artefacts").lineLimit(1)
                }.accessibilityIdentifier("thread.artefacts.switcher")
                PhoneThreadArtefactsButton(state: state)
            }.padding(10).background(Amb.card)
            if let failure = state.failure { Text(failure).font(.caption).foregroundStyle(Amb.warning).padding(8) }
            if let tab = selected, !tab.attached {
                Text("Removed from thread. Local recovery retained and excluded from Send.").font(.caption).foregroundStyle(Amb.warning)
                Button("Save to source and resume if attached") { Task { await state.saveRecovery(tab) } }
                    .accessibilityIdentifier("thread.artefacts.recovery.save")
            }
            if state.tabs.contains(where: { !$0.attached }) {
                Menu("Detached recovery") {
                    ForEach(state.tabs.filter { !$0.attached }) { tab in
                        Button(tab.title) { tab.open = true; state.show(tab) }
                    }
                }.accessibilityIdentifier("thread.artefacts.recovery")
            }
            if let tab = selected, tab.attached {
                Button("Discuss this") { state.shown = false; state.discussionTarget = tab.id; state.discussionExcluded = false }
                    .accessibilityIdentifier("thread.artefacts.discuss")
            }
            Divider()
            ZStack {
                ForEach(state.tabs) { tab in
                    NavigationStack {
                        Group {
                            if tab.kind == "doc" { DocumentView(docId: tab.id, workspace: workspace, store: store) }
                            else { FileDetailView(fileId: tab.id, workspace: workspace, store: store) }
                        }.environment(\.macThreadArtefactTab, tab)
                    }
                    .opacity(state.selected == tab.id && tab.open ? 1 : 0)
                    .allowsHitTesting(state.selected == tab.id && tab.open && !state.busy)
                    .accessibilityHidden(state.selected != tab.id || !tab.open)
                }
            }
        }
    }
    private var selected: MacThreadArtefactTab? { state.tabs.first { $0.id == state.selected && $0.open } }
}

struct PhoneThreadArtefactsButton: View {
    let state: MacThreadArtefacts
    var body: some View {
        Button { state.browsing = true } label: {
            Image(systemName: "square.stack").frame(width: Amb.touchTarget, height: Amb.touchTarget)
        }
        .buttonStyle(.plain).accessibilityLabel("Thread artefacts (\(state.members.count))")
        .accessibilityIdentifier("thread.artefacts.browse").disabled(state.busy)
    }
}

struct PhoneThreadArtefactTarget: View {
    let state: MacThreadArtefacts
    var body: some View {
        if let tab = state.tabs.first(where: { $0.id == state.discussionTarget && $0.attached && $0.open }) {
            HStack {
                Button { state.show(tab) } label: { Label("\(tab.title) · \(tab.revisionLabel)", systemImage: tab.icon).lineLimit(1) }
                Menu("Switch target") {
                    ForEach(state.tabs.filter { $0.open && $0.attached }) { candidate in
                        Button(candidate.title) { state.selected = candidate.id; state.discussionTarget = candidate.id; state.discussionExcluded = false }
                    }
                }
                Button { state.discussionTarget = nil; state.discussionExcluded = true } label: { Image(systemName: "xmark.circle") }
                    .accessibilityLabel("Remove discussion target")
            }.font(.caption).padding(8).accessibilityIdentifier("composer.artefact.target")
        }
    }
}
#endif
