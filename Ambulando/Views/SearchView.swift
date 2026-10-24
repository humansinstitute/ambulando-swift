import AmbulandoCore
import SwiftUI

/// Search over what is stored on this iPhone (SQLite full-text index); nothing is sent to Tower.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searched = ""
    @State private var path: [WorkRoute] = []
    @State private var generation = 0

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(groups, id: \.0) { title, rows in
                    Section(title) {
                        ForEach(rows) { hit in
                            if let route = route(hit) {
                                NavigationLink(value: route) { row(hit) }.accessibilityIdentifier("search.hit")
                            } else {
                                row(hit)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Amb.background)
            .overlay {
                if hits.isEmpty {
                    EmptyNote(title: searched.count >= 2 ? "No matches" : "Search this iPhone",
                              systemImage: "magnifyingglass",
                              detail: "Searches messages, tasks, documents and files saved on this iPhone for the current workspace.")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Messages, tasks, docs, files")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .navigationDestination(for: WorkRoute.self) { WorkDestination(route: $0, adoptsContext: true) }
            .task(id: query) { await run() }
        }
    }

    private var groups: [(String, [SearchHit])] {
        let order: [(SearchHit.Kind, String)] = [(.task, "Tasks"), (.doc, "Documents"), (.file, "Files"), (.message, "Messages")]
        return order.compactMap { kind, title in
            let rows = hits.filter { $0.kind == kind }
            return rows.isEmpty ? nil : (title, rows)
        }
    }

    private func place(_ hit: SearchHit) -> String? {
        let nav = model.navigation.value
        guard let channel = nav.channel(hit.channelId) else { return nil }
        return [nav.scope(channel.scopeId)?.name, "#" + nav.label(channel)].compactMap { $0 }.joined(separator: " · ")
    }

    private func row(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.title).font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1)
            if !hit.snippet.isEmpty { Text(hit.snippet).font(.caption).foregroundStyle(Amb.mutedForeground).lineLimit(2) }
            // Search spans the workspace; each result says where it lives, and opening it follows that context.
            if let place = place(hit) { Text(place).font(.caption2.weight(.semibold)).foregroundStyle(Amb.primary).lineLimit(1) }
        }
    }

    private func route(_ hit: SearchHit) -> WorkRoute? {
        switch hit.kind {
        case .task: .task(workspaceId: workspace.id, taskId: hit.recordId)
        case .doc: .doc(workspaceId: workspace.id, docId: hit.recordId)
        case .file: .file(workspaceId: workspace.id, fileId: hit.recordId)
        case .message:
            if let channel = hit.channelId, let thread = hit.threadId { .thread(workspaceId: workspace.id, channelId: channel, threadId: thread) }
            else { hit.channelId.map { .channel(workspaceId: workspace.id, channelId: $0) } }
        }
    }

    /// Debounced; a slower earlier query never replaces a newer one.
    private func run() async {
        generation += 1
        let current = generation, text = query, store = store, w = workspace.id
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let found = (try? await store.reader.search(workspaceId: w, text: text)) ?? []
        guard current == generation else { return }
        hits = found
        searched = text
    }
}
