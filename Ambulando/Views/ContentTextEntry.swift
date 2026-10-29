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

    /// Only comment composers opt into actor lookup; descriptions and settings retain their existing input behavior.
    var actorMentions = false
    @State private var members = LiveQuery<[MentionCandidate]>(initial: [])
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var highlighted = 0
    @State private var dismissedQuery: CommentMentions.Query?

    private var query: CommentMentions.Query? {
        actorMentions && focused ? CommentMentions.query(in: text, selection: selection) : nil
    }

    private var suggestions: [MentionSuggestion] {
        guard let query, query != dismissedQuery else { return [] }
        return MentionRanking.merge(actors: members.value.filter { NostrKeys.isValidNpub($0.member.npub) }
            .map { (Mention(member: $0.member), $0.member.npub) }, records: [], query: MentionQuery(query.text))
    }

    private func pick(_ mention: Mention) {
        guard let next = CommentMentions.complete(text, selection: selection, with: mention) else { return }
        text = next
        highlighted = 0
        focused = true
    }

    private func mentionKey(_ key: ComposerKey) -> Bool {
        let rows = suggestions
        guard !rows.isEmpty else { return false }
        let index = min(highlighted, rows.count - 1)
        switch key {
        case .up: highlighted = (index - 1 + rows.count) % rows.count
        case .down: highlighted = (index + 1) % rows.count
        case .enter, .tab: pick(rows[index].mention)
        case .escape: dismissedQuery = query
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !suggestions.isEmpty {
                MentionPicker(suggestions: suggestions, people: members.value, highlighted: min(highlighted, suggestions.count - 1)) { pick($0.mention) }
            }
            editor
            if let uploads = model.uploads, let host { ComposerPastedUploads(uploads: uploads, target: host.uploadTarget, text: text) }
        }
        .task(id: "\(model.connection?.id ?? ""):\(workspace.id):\(field)") {
            #if os(iOS)
            guard actorMentions else { return }
            #endif
            if let host { model.uploads?.detach(host) }
            guard let connection = model.connection else { return }
            let target = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: "content-\(field)")
            let next = ContentUploadHost(target: target, binding: $text, store: model.store)
            host = next
            if text.isEmpty, let draft = try? await model.store?.reader.draft(target) { text = draft.text }
            model.uploads?.attach(next)
            if actorMentions, let store = model.store {
                let workspaceId = workspace.id
                members.start(store: store, matches: { ($0.table == .members && $0.workspaceId == workspaceId) || $0.table == .profiles }) {
                    async let people = store.reader.people(workspaceId: workspaceId)
                    let rows = try await store.reader.directoryMembers(workspaceId: workspaceId)
                    let directory = try await people
                    return rows.map { MentionCandidate(member: $0, person: directory.person($0.npub)) }
                }
            }
        }
        .onChange(of: text) { _, _ in host?.save() }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onDisappear { if let host { host.save(); model.uploads?.detach(host) } }
    }

    @ViewBuilder private var editor: some View {
        #if os(macOS)
        let height = macEditorHeight * TextScale.shared.factor
        ComposerTextView(text: $text, focused: $focused, placeholder: placeholder, plainKeyboard: false, onPasteItems: paste,
                         onPickerKey: mentionKey, pickerOpen: !suggestions.isEmpty, fixedHeight: height,
                         selection: actorMentions ? $selection : nil)
            .frame(height: height)
        #else
        if actorMentions {
            ComposerTextView(text: $text, focused: $focused, placeholder: placeholder,
                             plainKeyboard: model.fixture?.plainKeyboard == true, onPasteItems: paste,
                             onPickerKey: mentionKey, pickerOpen: !suggestions.isEmpty, selection: $selection)
        } else if multilineEditor { TextEditor(text: $text) }
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
        saving = Task { await previous?.value; try? await store?.writer.saveDraft(target, Draft(text: text, mentions: CommentMentions.actors(in: text))) }
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
