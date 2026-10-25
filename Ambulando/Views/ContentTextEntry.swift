import AmbulandoCore
import SwiftUI

/// Content fields share explicit paste, staging, privacy stripping and retry with chat. The synthetic draft namespace
/// prevents uploads from ever landing in a real chat. Names, secrets, addresses, filters and search keep system input.
struct ContentTextEntry: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    let placeholder: String
    let workspace: WorkspaceRecord
    let field: String
    var multilineEditor = false
    /// The Mac editor's height at the system text size (it grows with `TextScale`).
    var macEditorHeight: CGFloat = 76
    @State private var focused = false
    @State private var host: ContentUploadHost?

    var body: some View {
        #if os(macOS)
        let height = macEditorHeight * TextScale.shared.factor
        VStack(alignment: .leading, spacing: 4) {
            ComposerTextView(text: $text, focused: $focused, placeholder: placeholder, plainKeyboard: false, onPasteItems: paste, fixedHeight: height)
                .frame(height: height)
            if let uploads = model.uploads, let host { ComposerPastedUploads(uploads: uploads, target: host.uploadTarget, text: text) }
        }
        .task(id: "\(model.connection?.id ?? ""):\(workspace.id):\(field)") {
            if let host { model.uploads?.detach(host) }
            guard let connection = model.connection else { return }
            let target = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: "content-\(field)")
            let next = ContentUploadHost(target: target, binding: $text, store: model.store)
            host = next
            // Recover only if the current field is empty. Existing document/task content always wins.
            if text.isEmpty, let draft = try? await model.store?.reader.draft(target) { text = draft.text }
            model.uploads?.attach(next)
        }
        .onChange(of: text) { _, _ in host?.save() }
        .onDisappear { if let host { host.save(); model.uploads?.detach(host) } }
        #else
        if multilineEditor { TextEditor(text: $text) }
        else { TextField(placeholder, text: $text, axis: .vertical) }
        #endif
    }
    private func paste(_ providers: [NSItemProvider]) -> [String] {
        guard let host, let uploads = model.uploads else { return [] }
        return uploads.paste(providers, target: host.uploadTarget, appNpub: workspace.appNpub, context: "content")
    }
}

@MainActor
final class ContentUploadHost: UploadTokenHost {
    let uploadTarget: ChatTarget
    let binding: Binding<String>
    let store: LocalStore?
    private var saving: Task<Void, Never>?
    var uploadText: String { binding.wrappedValue }
    init(target: ChatTarget, binding: Binding<String>, store: LocalStore?) { uploadTarget = target; self.binding = binding; self.store = store }
    func replaceUploadToken(_ token: String, with replacement: String) -> Bool {
        guard let result = ComposerText.replacing(token, with: replacement, in: uploadText, selection: nil) else { return false }
        binding.wrappedValue = result.text; save(); return true
    }
    func save() {
        let text = uploadText, target = uploadTarget, store = store, previous = saving
        saving = Task { await previous?.value; try? await store?.writer.saveDraft(target, Draft(text: text, mentions: [])) }
    }
}

/// Scope/channel settings obtain their workspace from their existing model context.
struct WorkspaceContentTextEntry: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    let placeholder: String
    let field: String
    var macEditorHeight: CGFloat = 76
    var body: some View {
        if let workspace = model.selectedWorkspace {
            ContentTextEntry(text: $text, placeholder: placeholder, workspace: workspace, field: field, macEditorHeight: macEditorHeight)
        } else { TextField(placeholder, text: $text, axis: .vertical) }
    }
}
