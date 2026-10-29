#if DEBUG
import AppKit
import WebKit
import AmbulandoCore

extension MacThreadRegression {
    static func documentWorkflowCheck(_ window: NSWindow, model: AppModel) async throws {
        guard let fixture = model.fixture, let store = model.store, let workspace = model.selectedWorkspace,
              let connection = model.connection else { throw Failure(description: "Missing isolated fixture") }
        model.selectContext(.home)
        try press(window, "section.docs"); await settle()
        try await waitFor(window, "doc.Native app plan", "sample document")
        try press(window, "doc.Native app plan"); await settle(); await settle()
        try await waitFor(window, "editor.title", "Mac opens editable by default")
        func web(_ view: NSView) -> WKWebView? {
            if let page = view as? WKWebView { return page }
            return view.subviews.lazy.compactMap { web($0) }.first
        }
        guard let page = window.contentView.flatMap(web) else { throw Failure(description: "Missing editor web view") }
        for _ in 0..<40 {
            if (try? await page.evaluateJavaScript("!!document.querySelector('.ProseMirror')?.editor")) as? Bool == true { break }
            await settle()
        }
        let selected = try await page.evaluateJavaScript("""
        (()=>{const e=document.querySelector('.ProseMirror').editor;
          const node=e.state.doc.child(0); e.commands.setTextSelection({from:1,to:1+node.textContent.length}); return node.textContent;})()
        """) as? String
        await settle()
        try require(selected?.isEmpty == false, "synthetic passage selected")
        try await waitFor(window, "doc.commentSelection", "selection comment icon")
        try press(window, "doc.commentSelection"); await settle(); await settle()
        // The captured anchor survives native focus moving to the comment composer.
        try type(window, "Anchored synthetic workflow comment"); await settle()
        try press(window, "doccomment.send"); await settle(); await settle()
        let docs = try await store.reader.docs(workspaceId: workspace.id)
        guard let doc = docs.first(where: { $0.title == "Native app plan" }) else { throw Failure(description: "Missing plan") }
        let accepted = fixture.tower.work.docComments(doc.id).first { $0["body"] as? String == "Anchored synthetic workflow comment" }
        let metadata = accepted?["metadata"] as? [String: Any]
        try require(metadata?["anchor_quote"] as? String == selected, "accepted anchor quotes exact intended selection")
        page.reload()
        model.openDoc(doc.id, in: workspace, force: true)
        await settle(); await settle()
        let comments = try await store.reader.comments(workspaceId: workspace.id, parent: .doc, parentId: doc.id)
        try require(comments.contains { $0.body == "Anchored synthetic workflow comment" && $0.documentAnchor?.quote == selected }, "anchored comment persists after reload")
        try press(window, "section.tasks"); await settle(); await settle()
        // Exercise the actual editor model against synthetic durable drafts and remote saves.
        let local = DocEditorModel(doc: doc, workspace: workspace, store: store, connection: connection, app: model)
        await local.load()
        if !ProcessInfo.processInfo.arguments.contains("-AmbulandoSkipMinuteCheck") {
            local.title = "Minute checkpoint synthetic title"
            local.holdLease()
            try await Task.sleep(for: .seconds(62))
            try require(fixture.tower.work.doc(doc.id)?["title"] as? String == "Minute checkpoint synthetic title", "real-minute cloud checkpoint saves without Save")
            print("DOCUMENT_REAL_MINUTE_PASS")
        }
        let newer = DocumentBody.newDocument(text: "Latest synthetic remote")
        fixture.tower.work.externalDocSave(doc.id, body: newer.bytes, contentType: newer.contentType)
        await local.reconcileRemote()
        try require(local.content.contains("Latest synthetic remote") && !local.dirty && local.followingRemote, "unchanged returning device follows latest without authority")
        local.close()
        let latestDoc = try await store.reader.doc(workspaceId: workspace.id, id: doc.id)!
        let divergent = DocEditorModel(doc: latestDoc, workspace: workspace, store: store, connection: connection, app: model)
        await divergent.load()
        let previous = DocumentBody.newDocument(text: "Previous meaningful local work 🙂")
        divergent.pageChanged(DocumentBody(bytes: previous.bytes, contentType: previous.contentType).editorState!.serializedString())
        divergent.title = "Previous local title"
        fixture.offline = true
        await divergent.reconcileRemote()
        let offline = try await store.reader.docDraft(key: divergent.draftKey)
        try require(offline?.title == "Previous local title", "offline durable local title and bytes retained")
        fixture.offline = false
        let newest = DocumentBody.newDocument(text: "Newest canonical bytes")
        fixture.tower.work.externalDocSave(doc.id, body: newest.bytes, contentType: newest.contentType)
        await divergent.reconcileRemote()
        try require(divergent.content.contains("Newest canonical bytes") && divergent.followingRemote && !divergent.recoveries.isEmpty, "divergent returning editor follows latest with recovery indicator")
        await divergent.openVersions()
        guard let recovery = divergent.recoveries.first else { throw Failure(description: "Missing previous version") }
        await divergent.previewVersion(recovery)
        try require(divergent.versionPreview?.contains("Previous meaningful local work 🙂") == true, "chooser previews previous saved content and title")
        await divergent.resolveVersion(promote: true)
        try require(!divergent.followingRemote && !divergent.dirty && divergent.title == "Previous local title", "chosen previous version keeps explicit editing authority")
        let continued = DocumentBody.newDocument(text: "Continued after choosing previous")
        divergent.pageChanged(DocumentBody(bytes: continued.bytes, contentType: continued.contentType).editorState!.serializedString())
        let continuedSaved = await divergent.save()
        try require(continuedSaved && fixture.tower.work.docBody(doc.id).map { DocumentBody(bytes: $0, contentType: continued.contentType).markdown } == "Continued after choosing previous", "chosen version continues editing and saving")
        divergent.pageChanged(DocumentBody(bytes: previous.bytes, contentType: previous.contentType).editorState!.serializedString())
        fixture.tower.work.externalDocSave(doc.id, body: newest.bytes, contentType: newest.contentType)
        await divergent.reconcileRemote(); await divergent.openVersions()
        await divergent.previewVersion(divergent.recoveries.first)
        await divergent.resolveVersion(promote: false)
        try require(fixture.tower.work.docBody(doc.id) == newest.bytes, "dismiss preserves exact canonical bytes")
        divergent.close()
        guard let saver = model.saver, let scope = doc.scopeId else { throw Failure(description: "Missing document saver") }
        let markdownId = fixture.tower.work.seedDoc(scope: scope, channel: doc.channelId, title: "Empty Markdown preservation", body: Data("Delete me".utf8), contentType: "text/markdown")
        let markdown = try await saver.latest(connection, workspace, docId: markdownId)
        let empty = DocEditorModel(doc: markdown.doc, workspace: workspace, store: store, connection: connection, app: model)
        await empty.load(); empty.pageChanged("")
        let emptySaved = await empty.save()
        try require(emptySaved, "empty Markdown can save")
        try require(fixture.tower.work.docBody(markdownId) == Data(), "empty Markdown retains exact empty bytes")
        empty.close(); await settle()
        let denied = DocEditorModel(doc: markdown.doc, workspace: workspace, store: store, connection: connection, app: model)
        await denied.load()
        fixture.tower.work.inject(.status(403, "permission_denied"), matching: "/acquire")
        denied.holdLease(); await settle(); await settle()
        try require(denied.permissionDenied, "permission-denied document remains read only")
        denied.close()
        print("DOCUMENT_WORKFLOW_PASS defaultEdit selectionIcon exactAnchor reload offlineDraft noDivergenceFollow divergenceRecovery preview dismissCanonical")
    }
}
#endif
