#if DEBUG
import AppKit
import AmbulandoCore

extension MacThreadRegression {
    static func documentActionsCheck(model: AppModel) async throws {
        guard let fixture = model.fixture, let store = model.store, let workspace = model.selectedWorkspace,
              let connection = model.connection, let saver = model.saver,
              let seed = try await store.reader.docs(workspaceId: workspace.id).first, let scope = seed.scopeId else { throw Failure(description: "Missing fixture") }
        let id = fixture.tower.work.seedDoc(scope: scope, channel: seed.channelId, title: "History actions", body: Data("Current shared".utf8), contentType: "text/markdown")
        let head = try await saver.latest(connection, workspace, docId: id)
        let editor = DocEditorModel(doc: head.doc, workspace: workspace, store: store, connection: connection, app: model)
        await editor.load(); editor.pageChanged("Unsaved local work")
        try require(await editor.checkpoint(), "local draft checkpoint")
        try require(await editor.pauseForLifecycle(), "lifecycle pauses editor without flushing")
        try require(!(await editor.save()), "lifecycle pause blocks body saves")
        try require(fixture.tower.work.doc(id)?["row_version"] as? Int == 1, "lifecycle pause never autosaves")
        editor.resumeAfterLifecycle()
        fixture.tower.work.externalDocSave(id, body: Data("Remote shared".utf8), contentType: "text/markdown")
        await editor.reconcileRemote(); await editor.beginMerge()
        editor.mergeText += "\nRetain unfinished merge preview"
        await editor.persistReview()
        let historical = "Historical text with exact trailing space "
        let row: [String: Any] = ["workspace_id":workspace.id,"doc_id":id,"title":"Historical title","row_version":1,"content":["raw":historical,"content_type":"text/markdown"]]
        let version = try DocumentVersion(raw: JSONSerialization.data(withJSONObject: row), workspaceId: workspace.id, docId: id)
        try require(await editor.restoreCanonical(version), "restore shared version as draft")
        try require(editor.content == historical && editor.title == "Historical title" && editor.dirty, "restore exact historical bytes and title")
        try require(editor.journal.retained.contains { String(decoding: $0.bytes, as: UTF8.self) == "Unsaved local work" }, "restore retains previous local work")
        try require(fixture.tower.work.doc(id)?["row_version"] as? Int == 2, "restore draft creates no shared version")
        try require(editor.remoteVersion == nil && !editor.mergeReady && editor.journal.previousPreviews.contains { $0.text.contains("Retain unfinished merge preview") }, "restore archives unfinished merge and clears stale review blocker")
        try require(await editor.save(), "normal guarded Save publishes restored draft")
        try require(fixture.tower.work.doc(id)?["row_version"] as? Int == 3, "restoring creates new shared version on Save")
        editor.close()
        print("DOCUMENT_ACTIONS_PASS restoreExactBytesTitle retainedLocalWork explicitSaveNewVersion")
    }
}
#endif
