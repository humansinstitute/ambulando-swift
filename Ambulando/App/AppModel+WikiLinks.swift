import AmbulandoCore
import Foundation

extension AppModel {
    /// A page made by "create and link" exists on Tower: its id goes into the document that asked for it, before the creation
    /// write is retired. An open editor on that document receives the link itself (and makes it a durable draft); otherwise
    /// the link goes through the draft-first save path. Throwing keeps the write queued; the retry finds the page already made.
    func bindCreatedWikiPage(_ connection: ConnectionRecord, _ item: WriteItem, _ created: DocRecord) async throws {
        guard let source = item.string(WikiCreate.sourceKey), let title = item.string(WikiCreate.titleKey), let store, let saver,
              let workspace = try await store.reader.workspaces(connectionId: connection.id).first(where: { $0.id == item.workspaceId }) else { return }
        let occurrence = item.payloadObject[WikiCreate.occurrenceKey] as? Int
        if let editor = WikiEditors.editor(workspaceId: workspace.id, docId: source) {
            guard await editor.bindWiki(title: title, documentId: created.id, occurrence: occurrence) else { throw WikiBindError.sourceChanged }
            return
        }
        _ = try await WikiBinder.bind(title: title, to: created.id, occurrence: occurrence, sourceDocId: source, connection: connection,
                                      workspace: workspace, store: store, saver: saver)
    }

    /// Binds a reference in a document that has no open editor (a link chosen from the reader).
    func bindWikiLink(title: String, documentId: String, occurrence: Int?, sourceDocId: String, workspace: WorkspaceRecord) async throws -> WikiBindOutcome {
        guard let store, let saver, let connection else { return .sourceNotSaved }
        return try await WikiBinder.bind(title: title, to: documentId, occurrence: occurrence, sourceDocId: sourceDocId, connection: connection,
                                         workspace: workspace, store: store, saver: saver)
    }
}
