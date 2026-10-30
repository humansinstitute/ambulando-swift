import AmbulandoCore
import Foundation

extension AppModel {
    /// A page made by "create and link" exists on Tower: its id goes into the document that asked for it, before the creation
    /// write is retired. An open editor on that document (of this account) receives the link itself and stores it as a durable
    /// draft; otherwise the link goes through the draft-first save path. Anything that leaves the link unrecorded throws, which
    /// keeps the write queued with the page's location; the retry finds the page already made and never makes a second one.
    func bindCreatedWikiPage(_ connection: ConnectionRecord, _ item: WriteItem, _ created: DocRecord,
                            capturedStore: LocalStore? = nil, capturedSaver: DocumentSaver? = nil,
                            capturedWorkspace: WorkspaceRecord? = nil) async throws {
        let epoch = wikiContextEpoch
        guard item.connectionId == connection.id, item.origin == connection.origin,
              item.signerNpub == connection.signerNpub, created.workspaceId == item.workspaceId else { throw WikiBindError.notReady }
        guard capturedStore != nil || self.connection?.id == connection.id else { throw WikiBindError.notReady }
        guard let source = item.string(WikiCreate.sourceKey), let title = item.string(WikiCreate.titleKey) else { return }
        guard let store = capturedStore ?? store, let saver = capturedSaver ?? saver else { throw WikiBindError.notReady }
        let listed = try await store.reader.workspaces(connectionId: connection.id)
        guard let workspace = capturedWorkspace ?? listed.first(where: { $0.id == item.workspaceId }),
              workspace.id == item.workspaceId, workspace.appNpub == item.appNpub else { throw WikiBindError.notReady }
        let payload = item.payloadObject
        var changedBySomeoneElse = false
        if let editor = WikiEditors.editor(connectionId: connection.id, workspaceId: workspace.id, docId: source), editor.workspace.appNpub == workspace.appNpub {
            switch await editor.bindWiki(title: title, documentId: created.id, occurrence: payload[WikiCreate.occurrenceKey] as? Int,
                                         expectedCount: payload[WikiCreate.expectedCountKey] as? Int) {
            case .bound, .nothingToBind: break
            case .noLongerRequested: changedBySomeoneElse = true
            case .failed: throw WikiBindError.notReady
            }
        } else {
            changedBySomeoneElse = try await WikiBinder.complete(item: item, created: created, connection: connection, workspace: workspace, store: store, saver: saver) == .noLongerRequested
        }
        // An offscreen workspace may finish its durable binding, but cannot navigate or display notices in another.
        guard epoch == wikiContextEpoch, self.connection?.id == connection.id,
              selectedWorkspace?.id == workspace.id, selectedWorkspace?.appNpub == workspace.appNpub else { return }
        if changedBySomeoneElse {
            notice = "“\(title)” was created, but the text changed while it was being made, so the link was not changed automatically. Link it from the document."
            return
        }
        WikiControllers.created(request: payload[WikiCreate.requestKey] as? String, created, connectionId: connection.id)
    }

    /// Binds a reference in a document that has no open editor (a link chosen or opened from the reader).
    func bindWikiLink(title: String, documentId: String, occurrence: Int?, expectedCount: Int? = nil, sourceDocId: String, workspace: WorkspaceRecord) async throws -> WikiBindOutcome {
        guard let store, let saver, let connection, selectedWorkspace?.id == workspace.id,
              selectedWorkspace?.appNpub == workspace.appNpub else { return .sourceNotSaved }
        let epoch = wikiContextEpoch
        let outcome = try await WikiBinder.bind(title: title, to: documentId, occurrence: occurrence, expectedCount: expectedCount, sourceDocId: sourceDocId,
                                         connection: connection, workspace: workspace, store: store, saver: saver)
        guard epoch == wikiContextEpoch else { throw CancellationError() }
        return outcome
    }
}
