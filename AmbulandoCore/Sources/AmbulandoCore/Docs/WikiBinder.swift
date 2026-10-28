import Foundation

/// The extra payload keys of a "create and link" document write, and the checks made before one is queued.
public enum WikiCreate {
    /// The document whose `[[Title]]` asked for the page.
    public static let sourceKey = "wiki_source_doc"
    public static let titleKey = "wiki_title"
    /// Which matching reference in the source (document order) was opened; absent: every reference with that title.
    public static let occurrenceKey = "wiki_occurrence"
    /// How many title-only references with that title the source had when the page was requested. If the count has changed by
    /// the time the page exists, the position of the opened reference can no longer be trusted, so nothing is bound by guessing.
    public static let expectedCountKey = "wiki_expected_count"
    /// The screen that asked, so the page can be opened for the person only if they are still there.
    public static let requestKey = "wiki_request"
    /// Written once the page exists: where to find it if the link could not be added yet.
    public static let createdKey = "wiki_created_doc"
    /// Written once the link has been recorded in the source, so a retry never binds a second reference.
    public static let boundKey = "wiki_bound"

    /// What already answers a request to create `title` in `channelId`: a saved page with that title there, or a creation
    /// still waiting in the write queue. Either way no second page is made.
    public enum Existing: Sendable, Equatable {
        case page(DocRecord)
        case pending(WriteItem)
        /// Several saved pages already have the title there: the person picks one, nothing is chosen or created arbitrarily.
        case several([DocRecord])
    }

    public static func existing(title: String, channelId: String, docs: [DocRecord], pending: [WriteItem]) -> Existing? {
        let wanted = WikiLinks.normalized(title)
        if let queued = pending.first(where: { $0.kind == .docCreate && $0.targetId == channelId && WikiLinks.normalized($0.string("title") ?? "") == wanted }) {
            return .pending(queued)
        }
        let same = docs.filter { !$0.archived && $0.channelId == channelId && WikiLinks.normalized($0.title) == wanted }
        switch same.count {
        case 0: return nil
        case 1: return .page(same[0])
        default: return .several(same)
        }
    }

    /// Extra keys for the creation write that will link the page back into its source.
    public static func linkPayload(sourceDocId: String, title: String, occurrence: Int?, expectedCount: Int? = nil, request: String? = nil) -> [String: any Sendable] {
        var payload: [String: any Sendable] = [sourceKey: sourceDocId, titleKey: title]
        if let occurrence { payload[occurrenceKey] = occurrence }
        if let expectedCount { payload[expectedCountKey] = expectedCount }
        if let request { payload[requestKey] = request }
        return payload
    }
}

/// The source changed while the link was being added; the caller keeps its write queued and tries again on the new text.
public enum WikiBindError: Error, Equatable, Sendable, LocalizedError {
    case sourceChanged
    /// The source document is not saved on this device (or its format cannot be edited), so the link could not be added yet.
    case sourceUnavailable
    case notReady
    public var errorDescription: String? {
        switch self {
        case .sourceChanged: "The source document changed while the link was being added."
        case .sourceUnavailable: "The source document is not saved on this device, so the link could not be added yet."
        case .notReady: "The page was created; its link will be added when the document is ready."
        }
    }
}

public enum WikiBindOutcome: Sendable, Equatable {
    /// The source already links to this page: nothing to do.
    case alreadyBound
    /// The source's references with that title changed after the page was requested (one was removed, added or linked
    /// elsewhere), so the opened reference cannot be identified; nothing was changed. The created page still exists.
    case noLongerRequested
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
    /// What the creation write asked for, applied to a source that has no open editor. A source that cannot be changed is an
    /// error (the write stays queued with the page's location, never retired as if linked); a source whose references changed
    /// since the request is reported, not guessed at.
    public static func complete(item: WriteItem, created: DocRecord, connection: ConnectionRecord, workspace: WorkspaceRecord,
                                store: LocalStore, saver: DocumentSaver) async throws -> WikiBindOutcome {
        guard let source = item.string(WikiCreate.sourceKey), let title = item.string(WikiCreate.titleKey) else { return .alreadyBound }
        let payload = item.payloadObject
        let outcome = try await bind(title: title, to: created.id, occurrence: payload[WikiCreate.occurrenceKey] as? Int,
                                     expectedCount: payload[WikiCreate.expectedCountKey] as? Int, sourceDocId: source, connection: connection,
                                     workspace: workspace, store: store, saver: saver)
        if outcome == .sourceNotSaved { throw WikiBindError.sourceUnavailable }
        return outcome
    }

    public static func bind(title: String, to documentId: String, occurrence: Int?, expectedCount: Int? = nil, sourceDocId: String, connection: ConnectionRecord,
                            workspace: WorkspaceRecord, store: LocalStore, saver: DocumentSaver) async throws -> WikiBindOutcome {
        let key = DocDraft.key(connectionId: connection.id, workspaceId: workspace.id, docId: sourceDocId)
        let existingDraft = try await store.reader.docDraft(key: key)
        let cached = try await store.reader.docBody(workspaceId: workspace.id, docId: sourceDocId)
        guard let source = existingDraft.map({ ($0.body, $0.contentType) }) ?? cached.map({ ($0.bytes, $0.contentType) }) else { return .sourceNotSaved }
        let body = DocumentBody(bytes: source.0, contentType: source.1)
        let references = WikiLinks.references(in: body)
        if references.contains(where: { $0.documentId == documentId }) { return .alreadyBound }
        if let expectedCount {
            let current = references.filter { $0.documentId == nil && WikiLinks.normalized($0.title) == WikiLinks.normalized(title) }.count
            if current != expectedCount { return .noLongerRequested }
        }
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
        // Written only if nothing changed the draft since it was read: edits made meanwhile are never overwritten.
        let stored: Bool
        if let existingDraft { stored = try await store.writer.replaceDocDraft(ifUnchanged: existingDraft, with: draft) }
        else { stored = try await store.writer.insertDocDraftIfAbsent(draft) }
        guard stored else { throw WikiBindError.sourceChanged }
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
