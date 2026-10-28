import Foundation

/// The extra payload keys of a "create and link" document write, and the checks made before one is queued.
public enum WikiCreate {
    /// The document whose `[[Title]]` asked for the page.
    public static let sourceKey = "wiki_source_doc"
    public static let titleKey = "wiki_title"
    /// Which matching reference in the source (document order) was opened; absent: every reference with that title.
    public static let occurrenceKey = "wiki_occurrence"

    /// What already answers a request to create `title` in `channelId`: a saved page with that title there, or a creation
    /// still waiting in the write queue. Either way no second page is made.
    public enum Existing: Sendable, Equatable {
        case page(DocRecord)
        case pending(WriteItem)
    }

    public static func existing(title: String, channelId: String, docs: [DocRecord], pending: [WriteItem]) -> Existing? {
        let wanted = WikiLinks.normalized(title)
        if let queued = pending.first(where: { $0.kind == .docCreate && $0.targetId == channelId && WikiLinks.normalized($0.string("title") ?? "") == wanted }) {
            return .pending(queued)
        }
        let same = docs.filter { !$0.archived && $0.channelId == channelId && WikiLinks.normalized($0.title) == wanted }
        return same.count == 1 ? .page(same[0]) : nil
    }

    /// Extra keys for the creation write that will link the page back into its source.
    public static func linkPayload(sourceDocId: String, title: String, occurrence: Int?) -> [String: any Sendable] {
        var payload: [String: any Sendable] = [sourceKey: sourceDocId, titleKey: title]
        if let occurrence { payload[occurrenceKey] = occurrence }
        return payload
    }
}

public enum WikiBindOutcome: Sendable, Equatable {
    /// Nothing referred to the title any more (already linked, or edited away): nothing to do.
    case alreadyBound
    /// The source now holds the link and Tower has the saved document.
    case saved
    /// The source holds the link in its draft on this device and has not reached Tower yet (offline, lease held, newer version).
    /// The link is kept in the draft and shown as unsaved edits; the message says why.
    case keptInDraft(String)
    /// The source document is not saved on this device, so nothing could be changed here.
    case sourceNotSaved
}

/// Puts a created page's id into the document that asked for it, through the same draft-first save path as editing, so a
/// failed save keeps the link instead of losing it. The source is never changed while its editor is open here; that
/// editor receives the link itself (the app checks first).
public enum WikiBinder {
    public static func bind(title: String, to documentId: String, occurrence: Int?, sourceDocId: String, connection: ConnectionRecord,
                            workspace: WorkspaceRecord, store: LocalStore, saver: DocumentSaver) async throws -> WikiBindOutcome {
        let key = DocDraft.key(connectionId: connection.id, workspaceId: workspace.id, docId: sourceDocId)
        let existingDraft = try await store.reader.docDraft(key: key)
        let cached = try await store.reader.docBody(workspaceId: workspace.id, docId: sourceDocId)
        guard let source = existingDraft.map({ ($0.body, $0.contentType) }) ?? cached.map({ ($0.bytes, $0.contentType) }) else { return .sourceNotSaved }
        let body = DocumentBody(bytes: source.0, contentType: source.1)
        let encoded: (bytes: Data, contentType: String)
        if let state = body.editorState {
            guard let bound = WikiLinks.binding(title, to: documentId, inEditorState: state, occurrence: occurrence) else { return .alreadyBound }
            try DocumentBody.checkEdited(bound, original: state)
            encoded = try body.encoded(editorState: bound)
        } else if body.isEditable {
            guard let bound = WikiLinks.binding(title, to: documentId, inMarkdown: body.markdown, occurrence: occurrence) else { return .alreadyBound }
            encoded = try body.encoded(markdown: bound)
        } else {
            return .sourceNotSaved
        }
        let draft: DocDraft
        if let existingDraft {
            draft = DocDraft(connectionId: existingDraft.connectionId, workspaceId: existingDraft.workspaceId, docId: existingDraft.docId, title: existingDraft.title,
                             body: encoded.bytes, contentType: encoded.contentType, baseRowVersion: existingDraft.baseRowVersion, baseSha256: existingDraft.baseSha256,
                             baseStorageObjectId: existingDraft.baseStorageObjectId, state: existingDraft.state, lastError: existingDraft.lastError,
                             recoveryId: existingDraft.recoveryId)
        } else if let cached {
            let doc = try await store.reader.doc(workspaceId: workspace.id, id: sourceDocId)
            draft = DocDraft(connectionId: connection.id, workspaceId: workspace.id, docId: sourceDocId, title: doc?.title ?? "Untitled document",
                             body: encoded.bytes, contentType: encoded.contentType, baseRowVersion: cached.docRowVersion, baseSha256: cached.sha256,
                             baseStorageObjectId: cached.storageObjectId, state: .editing)
        } else {
            return .sourceNotSaved
        }
        try await store.writer.saveDocDraft(draft)
        // Someone's own unsaved edits are not uploaded behind their back; a clean source is saved right away.
        if let existingDraft {
            return .keptInDraft(existingDraft.lastError ?? "The link was added to your unsaved edits on this device.")
        }
        switch await saver.save(draft, connection: connection, workspace: workspace) {
        case .saved: return .saved
        case .recovery(_, let message), .leaseHeld(let message), .notSaved(let message): return .keptInDraft(message)
        }
    }
}
