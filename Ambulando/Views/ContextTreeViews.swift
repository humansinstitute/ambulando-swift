import AmbulandoCore
import SwiftUI

// The scope's Context Tree (sol `context-tree-view.js`): an outline of components in Tower's order. A component opens
// its references, which open the native task, document or file; artifact pages open as labelled web content. Editing the
// tree (create, rename, move, link, delete) stays in the web app in this build and is said so on screen.

extension ContextNode {
    /// Nil for leaves, so the outline shows no disclosure arrow for them.
    var outlineChildren: [ContextNode]? { children.isEmpty ? nil : children }
}

struct ContextTreeView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var tree = LiveQuery<[ContextNode]>(initial: [])
    @State private var filter = ""

    private var scopeId: String? { model.context.scopeId }

    var body: some View {
        Group {
            if let scopeId {
                outline(scopeId)
            } else {
                scopePicker
            }
        }
        .navigationTitle("Context")
    }

    private var scopePicker: some View {
        let nav = model.navigation.value
        return List {
            Section {
                ForEach(nav.groups) { group in
                    Button { model.selectContext(WorkContext(scopeId: group.id)) } label: {
                        HStack {
                            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Amb.primary)
                            Text(group.scope.name).foregroundStyle(Amb.foreground).appRowTextSize()
                            Spacer()
                            Image(systemName: "chevron.right").font(.amb(.caption).weight(.semibold)).foregroundStyle(Amb.border)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("context.scope.\(group.scope.name)")
                }
            } header: {
                Text("Each scope has its own Context Tree. Choose one.").textCase(nil)
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
    }

    private func matches(_ node: ContextNode, _ q: String) -> Bool {
        node.component.title.lowercased().contains(q) || node.children.contains { matches($0, q) }
    }

    private func filtered(_ nodes: [ContextNode], _ q: String) -> [ContextNode] {
        guard !q.isEmpty else { return nodes }
        return nodes.filter { matches($0, q) }.map { var n = $0; n.children = filtered($0.children, q); return n }
    }

    private func outline(_ scopeId: String) -> some View {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let nodes = filtered(tree.value, q)
        let key = WorkspaceSync.contextTreeKey(workspace.id, scopeId)
        return List {
            Section {
                OutlineGroup(nodes, children: \.outlineChildren) { node in
                    NavigationLink(value: WorkRoute.contextComponent(workspaceId: workspace.id, scopeId: scopeId, componentId: node.id)) {
                        Label(node.component.title, systemImage: node.children.isEmpty ? "square" : "square.stack")
                            .foregroundStyle(Amb.foreground).appRowTextSize()
                    }
                    .accessibilityIdentifier("context.node.\(node.component.title)")
                }
            } footer: {
                Text("Creating, renaming, moving and linking components is done in the web app for now.").font(.amb(.caption))
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
        .searchable(text: $filter, placement: .drawer, prompt: "Find component")
        .overlay {
            if tree.loaded && tree.value.isEmpty {
                if let error = model.syncError(forKey: key) {
                    EmptyNote(title: "Context unavailable", systemImage: "lock", detail: error)
                } else if model.isSyncing(key) {
                    ProgressView("Loading Context Tree…")
                } else {
                    EmptyNote(title: "No components", systemImage: "point.3.connected.trianglepath.dotted",
                              detail: model.canRead ? "This scope's Context Tree is empty." : "Unlock to load this scope's Context Tree.")
                }
            }
        }
        .refreshable { model.openContextTree(workspace, scopeId: scopeId, force: true) }
        .task(id: scopeId) {
            let w = workspace.id, store = store
            tree.start(store: store, matches: { $0.workspaceId == w && $0.table == .contextTree }) {
                try await store.reader.contextTree(workspaceId: w, scopeId: scopeId)
            }
            model.openContextTree(workspace, scopeId: scopeId)
        }
    }
}

struct ContextComponentSnapshot: Sendable, Equatable {
    var component: ContextComponentRecord?
    var path: [ContextComponentRecord] = []
    var children: [ContextComponentRecord] = []
    var references: [ContextReferenceRecord] = []
    /// Local titles of referenced records stored on this iPhone (Tower's resolved title wins).
    var localTitles: [String: String] = [:]
}

struct ContextComponentView: View {
    @Environment(AppModel.self) private var model
    let scopeId: String
    let componentId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var snapshot = LiveQuery<ContextComponentSnapshot>(initial: ContextComponentSnapshot())

    var body: some View {
        let value = snapshot.value
        List {
            if !value.path.isEmpty {
                Section {
                    Text(value.path.map(\.title).joined(separator: " › ")).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                        .accessibilityLabel("Path: " + value.path.map(\.title).joined(separator: ", "))
                }
            }
            if !value.children.isEmpty {
                Section("Components") {
                    ForEach(value.children) { child in
                        NavigationLink(value: WorkRoute.contextComponent(workspaceId: workspace.id, scopeId: scopeId, componentId: child.id)) {
                            Label(child.title, systemImage: "square").foregroundStyle(Amb.foreground).appRowTextSize()
                        }
                    }
                }
            }
            Section("Linked records") {
                if value.references.isEmpty {
                    Text(model.isSyncing(WorkspaceSync.contextReferencesKey(workspace.id, componentId)) ? "Loading…" : "Nothing linked to this component.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                }
                ForEach(value.references) { reference in
                    referenceRow(reference, localTitle: reference.targetRecordId.flatMap { value.localTitles[$0] })
                }
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
        .navigationTitle(value.component?.title ?? "Component")
        .fixtureLabel()
        .overlay {
            if snapshot.loaded && value.component == nil {
                EmptyNote(title: "Component unavailable", systemImage: "lock", detail: "It was removed, or this scope is no longer visible to you.")
            }
        }
        .refreshable { model.openContextComponent(workspace, scopeId: scopeId, componentId: componentId, force: true) }
        .task {
            let w = workspace.id, id = componentId, scope = scopeId, store = store
            snapshot.start(store: store, matches: { $0.workspaceId == w && [.contextTree, .tasks, .docs, .files].contains($0.table) }) {
                guard let component = try await store.reader.contextComponent(workspaceId: w, id: id), component.scopeId == scope else { return ContextComponentSnapshot() }
                var path: [ContextComponentRecord] = []
                var cursor = component.parentId
                var seen: Set<String> = [component.id]
                while let parent = cursor, !seen.contains(parent), let row = try await store.reader.contextComponent(workspaceId: w, id: parent) {
                    path.insert(row, at: 0); seen.insert(parent); cursor = row.parentId
                }
                let tree = try await store.reader.contextTree(workspaceId: w, scopeId: scope)
                func find(_ nodes: [ContextNode]) -> ContextNode? { for n in nodes { if n.id == id { return n }; if let f = find(n.children) { return f } }; return nil }
                let references = try await store.reader.contextReferences(workspaceId: w, componentId: id)
                var titles: [String: String] = [:]
                for r in references where r.resolution == .available {
                    guard let rid = r.targetRecordId else { continue }
                    switch r.targetType {
                    case .task: titles[rid] = try await store.reader.task(workspaceId: w, id: rid)?.title
                    case .doc: titles[rid] = try await store.reader.doc(workspaceId: w, id: rid)?.title
                    case .file: titles[rid] = try await store.reader.file(workspaceId: w, id: rid)?.displayName
                    default: break
                    }
                }
                return ContextComponentSnapshot(component: component, path: path, children: find(tree)?.children.map(\.component) ?? [],
                                                references: references, localTitles: titles)
            }
            model.openContextComponent(workspace, scopeId: scopeId, componentId: componentId)
        }
    }

    @ViewBuilder private func referenceRow(_ r: ContextReferenceRecord, localTitle: String?) -> some View {
        switch (r.resolution, r.targetType) {
        case (.available, .task?), (.available, .doc?), (.available, .file?):
            if let id = r.targetRecordId {
                NavigationLink(value: route(r.targetType!, id)) {
                    Label(r.resolvedTitle ?? localTitle ?? "Untitled", systemImage: icon(r.targetType!)).foregroundStyle(Amb.foreground)
                }
                .accessibilityIdentifier("context.reference.\(r.resolvedTitle ?? id)")
            }
        case (_, .artifact?):
            if let artifact = r.artifact, artifact.isHTTPS, let url = artifact.latestURL.flatMap({ WebContentPolicy.launchURL($0.absoluteString) }) {
                Button { model.browser.launch(url) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(artifact.artifact, systemImage: "globe").foregroundStyle(Amb.foreground)
                        Text("Web content · \(artifact.origin)").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                    }
                }
                .accessibilityIdentifier("context.reference.artifact.\(artifact.artifact)")
            } else {
                Label(r.artifact.map { "Artifact on \($0.origin) (not HTTPS, not opened)" } ?? "Artifact link that is not valid", systemImage: "globe")
                    .foregroundStyle(Amb.mutedForeground)
            }
        case (.unavailable, _), (.external, _):
            // Tower discloses nothing about a target this viewer cannot read.
            Label("Not available to you", systemImage: "lock").foregroundStyle(Amb.mutedForeground)
                .accessibilityIdentifier("context.reference.locked")
        default:
            Label("Unsupported link type “\(r.targetTypeName)”", systemImage: "questionmark.square.dashed").foregroundStyle(Amb.mutedForeground)
        }
    }

    private func route(_ type: ContextReferenceRecord.TargetType, _ id: String) -> WorkRoute {
        switch type {
        case .task: .task(workspaceId: workspace.id, taskId: id)
        case .doc: .doc(workspaceId: workspace.id, docId: id)
        case .file, .artifact: .file(workspaceId: workspace.id, fileId: id)
        }
    }

    private func icon(_ type: ContextReferenceRecord.TargetType) -> String {
        switch type {
        case .task: "checklist"
        case .doc: "doc.text"
        case .file: "paperclip"
        case .artifact: "globe"
        }
    }
}
