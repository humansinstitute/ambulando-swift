import AmbulandoCore
import SwiftUI

struct DocumentHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceRecord
    let versions: [DocumentVersion]
    let loading: Bool
    let error: String?
    let canRestore: Bool
    let restore: (DocumentVersion) async -> Bool
    @State private var selected: Int?
    @State private var showSource = false
    @State private var comparing = false
    @State private var confirming = false
    @State private var restoring = false
    private var version: DocumentVersion? { versions.first { $0.id == selected } ?? versions.first }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if loading { ProgressView("Loading shared history…") }
                if let error { Text(error).foregroundStyle(.red) }
                if !loading && error == nil && versions.isEmpty { Text("No shared versions available.") }
                if let version {
                    Picker("Shared version", selection: $selected) {
                        ForEach(versions) { row in
                            Text("v\(row.rowVersion) · \(row.operation) · \(row.updatedAt)").tag(Optional(row.id))
                        }
                    }
                    if let actor = version.actorNpub { Text("By \(actor)").font(.caption).textSelection(.enabled) }
                    Toggle("Compare with previous version", isOn: $comparing)
                    Toggle("Show Markdown source", isOn: $showSource)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if comparing, let index = versions.firstIndex(where: { $0.id == version.id }), versions.indices.contains(index + 1) {
                                Text("Previous · v\(versions[index + 1].rowVersion)").font(.headline)
                                preview(versions[index + 1])
                                Divider()
                                Text("Selected · v\(version.rowVersion)").font(.headline)
                            }
                            preview(version)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button("Copy source") { Pasteboard.copy(source(version)) }.disabled(version.bytes == nil)
                        Spacer()
                        Button(restoring ? "Restoring…" : "Restore as draft…") { confirming = true }
                            .disabled(!canRestore || version.bytes == nil || restoring)
                            .accessibilityIdentifier("doc.history.restore")
                    }
                    Text("Restoring preserves current work and opens a draft. Save in the editor to publish a new shared version.").font(.caption)
                }
            }.padding().frame(minWidth: 300, minHeight: 360)
            .onAppear { synchronizeSelection() }
            .onChange(of: versions.map(\.id)) { _, _ in synchronizeSelection() }
            .navigationTitle("Versioning")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Restore this shared version as a draft?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Restore as draft") {
                    guard let version else { return }
                    restoring = true
                    Task { let restored = await restore(version); restoring = false; if restored { dismiss() } }
                }
            } message: { Text("Your current work will be retained. Nothing is published until you Save.") }
        }
    }
    private func synchronizeSelection() {
        if !versions.contains(where: { $0.id == selected }) { selected = versions.first?.id }
    }
    @ViewBuilder private func preview(_ version: DocumentVersion) -> some View {
        if showSource || version.bytes == nil { Text(source(version)).textSelection(.enabled) }
        else if let bytes = version.bytes {
            VStack(alignment: .leading, spacing: 12) {
                Text(version.title).font(.title2)
                RichBlocksView(blocks: DocumentRender.blocks(DocumentBody(bytes: bytes, contentType: version.contentType)), style: .document, workspace: workspace)
            }
        }
    }
    private func source(_ version: DocumentVersion) -> String {
        guard let bytes = version.bytes else { return "The stored body is unavailable. This version cannot be restored." }
        return "# \(version.title)\n\n" + DocumentBody(bytes: bytes, contentType: version.contentType).markdown
    }
}
