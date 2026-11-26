import AmbulandoCore
import SwiftUI
import AppKit

@MainActor @Observable
final class MacThreadArtefactTab: Identifiable {
    let id: String
    let kind: String
    var title: String
    var open = true
    @ObservationIgnored var validate: ((ArtefactChatReference) async -> Bool)?
    @ObservationIgnored var checkpoint: (() async -> Bool)?
    @ObservationIgnored var prepare: (() async throws -> ArtefactChatReference)?
    init(kind: String, id: String) { self.kind = kind; self.id = id; self.title = kind == "doc" ? "Document" : "Artefact" }
}

@MainActor @Observable
final class MacThreadArtefacts: Equatable {
    nonisolated static func == (lhs: MacThreadArtefacts, rhs: MacThreadArtefacts) -> Bool { lhs === rhs }
    var tabs: [MacThreadArtefactTab] = []
    var selected: String?
    var shown = false
    var expanded = false
    var busy = false
    var failure: String?
    #if DEBUG
    static weak var testingState: MacThreadArtefacts?
    #endif
    func open(kind: String, id: String) {
        guard !busy else { return }
        let kind = kind == "document" ? "doc" : kind
        if let tab = tabs.first(where: { $0.id == id && $0.kind == kind }) { tab.open = true }
        else { tabs.append(MacThreadArtefactTab(kind: kind, id: id)) }
        selected = id; shown = true
    }
    func close(_ tab: MacThreadArtefactTab) {
        guard !busy else { return }
        busy = true; failure = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task { @MainActor in
            defer { busy = false }
            do {
                if let prepare = tab.prepare { _ = try await prepare() }
                tab.open = false
                selected = tabs.first(where: \.open)?.id
                if selected == nil { shown = false }
            } catch {
                failure = "Tab kept open: \(error.localizedDescription) Save or resolve this tab, then retry close."
            }
        }
    }
    func checkpointAll() async -> Bool {
        guard !busy else { return false }
        NSApp.keyWindow?.makeFirstResponder(nil)
        busy = true
        defer { busy = false }
        for tab in tabs {
            if let checkpoint = tab.checkpoint, !(await checkpoint()) {
                failure = "Keep this conversation open: an editor could not preserve its latest changes. Retry closing after resolving the tab."
                return false
            }
        }
        return true
    }
    func prepare(target: ChatTarget, holdForEnqueue: Bool = false) async throws -> Data? {
        guard !busy else { throw ArtefactChatContext.ContextError.unresolved }
        guard let thread = target.threadId else { return nil }
        let open = tabs.filter(\.open)
        // Hidden workspace has no visible artefact, but dirty open editors must still save.
        guard !open.isEmpty else { return nil }
        NSApp.keyWindow?.makeFirstResponder(nil)
        busy = true; failure = nil
        var prepared = false
        defer { if !holdForEnqueue || !prepared { busy = false } }
        var preparingTitle = "artefact"
        do {
            var refs: [ArtefactChatReference] = []
            for tab in open {
                preparingTitle = tab.title
                guard let prepare = tab.prepare else { throw ArtefactChatContext.ContextError.unresolved }
                refs.append(try await prepare())
            }
            for (tab, reference) in zip(open, refs) {
                preparingTitle = tab.title
                if let validate = tab.validate, !(await validate(reference)) { throw ArtefactChatContext.ContextError.unresolved }
            }
            let context = try ArtefactChatContext(workspaceID: target.workspaceId, channelID: target.channelId,
                threadID: thread, visibleRecordID: selected ?? open[0].id, workspaceVisible: shown, open: refs).encoded(for: target)
            prepared = true
            return context
        } catch {
            failure = "Send paused for \(preparingTitle): \(error.localizedDescription) Resolve the affected tab, then press Send to retry."
            throw error
        }
    }
}

struct MacThreadArtefactOwnerKey: PreferenceKey {
    static let defaultValue: MacThreadArtefacts? = nil
    static func reduce(value: inout MacThreadArtefacts?, nextValue: () -> MacThreadArtefacts?) { value = nextValue() ?? value }
}
struct MacThreadArtefactExpandedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
extension EnvironmentValues {
    @Entry var macThreadArtefacts: MacThreadArtefacts? = nil
    @Entry var macThreadArtefactTab: MacThreadArtefactTab? = nil
}

/// Keep both conversation and editor trees mounted across tab/visibility changes.
struct MacThreadArtefactLayout<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openMention) private var inheritedOpen
    let state: MacThreadArtefacts
    let workspace: WorkspaceRecord
    let store: LocalStore
    @ViewBuilder let content: () -> Content
    @State private var fraction: CGFloat = 0.34
    @State private var retainedWorkspaceWidth: CGFloat = 640
    @State private var retainedChatWidth: CGFloat = 360
    @State private var dragStart: CGFloat?
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
        .preference(key: MacThreadArtefactOwnerKey.self, value: state)
        .preference(key: MacThreadArtefactExpandedKey.self, value: state.shown)
    }
    private var workspaceBody: some View {
        VStack(spacing: 0) {
            HStack {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(state.tabs.filter(\.open)) { tab in
                            HStack(spacing: 5) {
                                Button(tab.title) { state.selected = tab.id; state.shown = true }
                                    .fontWeight(state.selected == tab.id ? .bold : .regular)
                                    .accessibilityIdentifier("thread.artefacts.tab.\(tab.id)")
                                Button { state.close(tab) } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("Close \(tab.title) tab; retain work")
                            }.padding(8).background(state.selected == tab.id ? Amb.selectedFill : Amb.card)
                        }
                    }
                }
                Button { state.expanded.toggle() } label: { Image(systemName: state.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .help(state.expanded ? "Restore conversation split" : "Expand artefact workspace")
                    .accessibilityLabel(state.expanded ? "Restore conversation split" : "Expand artefact workspace")
                    .accessibilityIdentifier("thread.artefacts.expand")
                Button { state.shown = false; state.expanded = false } label: { Image(systemName: "sidebar.right") }
                    .help("Close workspace; keep tabs and edits")
                    .accessibilityLabel("Close artefact workspace")
                    .accessibilityIdentifier("thread.artefacts.close")
            }.padding(6).disabled(state.busy)
            if let failure = state.failure { Text(failure).font(.caption).foregroundStyle(Amb.destructive).padding(8) }
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
