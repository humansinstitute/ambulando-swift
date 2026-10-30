#if DEBUG
import AppKit
import WebKit
import AmbulandoCore

extension MacThreadRegression {
    static func documentWorkflowCheck(_ window: NSWindow, model: AppModel) async throws {
        guard let fixture = model.fixture, let store = model.store, let workspace = model.selectedWorkspace,
              let connection = model.connection else { throw Failure(description: "Missing isolated fixture") }
        // The separate reading-mode NSTextView bridge must track its enclosing native scroll viewport too.
        let readerScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 140))
        let readerText = SelectionTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
        readerText.isEditable = false; readerText.isSelectable = true
        readerText.textContainerInset = .zero
        readerText.string = String(repeating: "Reading selection bridge passage.\n", count: 40)
        readerScroll.documentView = readerText
        window.contentView?.addSubview(readerScroll)
        readerText.viewDidMoveToWindow()
        readerText.setSelectedRange(NSRange(location: 0, length: 7))
        readerText.layoutManager?.ensureLayout(for: readerText.textContainer!)
        readerText.updateButton()
        guard let readerButton = readerText.subviews.compactMap({ $0 as? NSButton }).first else { throw Failure(description: "Reader comment control missing") }
        try require(!readerButton.isHidden && readerButton.frame.maxX <= readerText.visibleRect.maxX, "reader icon at visible right edge")
        var readerAnchor: NSRange?
        readerText.begin = { readerAnchor = $0 }
        readerButton.performClick(nil)
        try require(readerAnchor == NSRange(location: 0, length: 7), "reader captures original selection")
        readerScroll.contentView.scroll(to: NSPoint(x: 0, y: 600)); readerScroll.reflectScrolledClipView(readerScroll.contentView)
        await settle()
        try require(readerButton.isHidden, "reader hides scrolled-out selection")
        readerScroll.contentView.scroll(to: .zero); readerScroll.reflectScrolledClipView(readerScroll.contentView)
        await settle()
        try require(!readerButton.isHidden, "reader tracks scroll back")
        readerText.setSelectedRange(NSRange(location: 7, length: 0))
        try require(readerButton.isHidden, "reader hides cleared selection")
        readerScroll.removeFromSuperview()
        print("DOCUMENT_READER_OVERLAY_PASS exactSelection rightEdge scrollOut/back clear")
        model.selectContext(.home)
        try press(window, "section.docs"); await settle()
        try await waitFor(window, "doc.Native app plan", "sample document")
        try press(window, "doc.Native app plan"); await settle(); await settle()
        try await waitFor(window, "doc.edit", "Mac opens in View by default")
        try require(find(window, "editor.title") == nil, "unset preference has no editor")
        let records = try await store.reader.docs(workspaceId: workspace.id)
        guard let openingDoc = records.first(where: { $0.title == "Native app plan" }) else { throw Failure(description: "Missing document") }
        let openingDeniedProbe = DocEditorModel(doc: openingDoc, workspace: workspace, store: store, connection: connection, app: model)
        fixture.tower.work.inject(.status(403, "forbidden"), matching: "/edit-leases/acquire")
        let mayEdit = await openingDeniedProbe.prepareOpening()
        try require(!mayEdit && openingDeniedProbe.permissionDenied, "permission denial keeps reader without an editor")
        openingDeniedProbe.close()
        let openingOfflineProbe = DocEditorModel(doc: openingDoc, workspace: workspace, store: store, connection: connection, app: model)
        fixture.tower.work.inject(.offline, matching: "/edit-leases/acquire")
        let mayDraft = await openingOfflineProbe.prepareOpening()
        try require(mayDraft && !openingOfflineProbe.permissionDenied, "openingOfflineProbe entry preserves local draft behavior")
        openingOfflineProbe.close()
        await model.setDocumentOpeningMode(.edit)
        try require(model.documentOpeningMode == .edit, "explicit Edit saved for the current user")
        print("DOCUMENT_OPENING_POLICY_PASS unsetView deniedReadOnly offlineDraft explicitEdit")
        try press(window, "doc.edit"); await settle()
        try await waitFor(window, "editor.title", "manual Edit opens editor")
        func web(_ view: NSView) -> WKWebView? {
            if let page = view as? WKWebView { return page }
            return view.subviews.lazy.compactMap { web($0) }.first
        }
        guard let page = window.contentView.flatMap(web) else { throw Failure(description: "Missing editor web view") }
        for _ in 0..<40 {
            if (try? await page.evaluateJavaScript("!!document.querySelector('.ProseMirror')?.editor")) as? Bool == true { break }
            await settle()
        }
        try snapshot(window, model: model, name: "mac-document-status-panel")
        guard let leaseStatus = find(window, "editor.lease") else { throw Failure(description: "Missing edit status") }
        let pageScreen = window.convertToScreen(page.convert(page.bounds, to: nil))
        try require(frame(of: leaseStatus).minX >= pageScreen.maxX, "status moved out of paper into right panel")
        let originalPageFrame = page.convert(page.bounds, to: nil)
        guard let saveControl = find(window, "editor.save") else { throw Failure(description: "Missing Save toolbar") }
        let originalToolbarFrame = frame(of: saveControl)
        _ = try await page.evaluateJavaScript("""
        (()=>{const e=document.querySelector('.ProseMirror').editor;
          e.view.dom.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'insertText',data:' steady typing'}));
          e.commands.focus(); e.commands.setTextSelection(e.state.doc.content.size-1); e.commands.insertContent(' steady typing'); return true;})()
        """)
        await settle()
        try require(page.convert(page.bounds, to: nil) == originalPageFrame && frame(of: saveControl) == originalToolbarFrame, "typing/save status causes zero page/toolbar movement")
        let selected = try await page.evaluateJavaScript("""
        (()=>{const e=document.querySelector('.ProseMirror').editor;
          const node=e.state.doc.child(0); e.commands.focus(); e.commands.setTextSelection({from:1,to:1+node.textContent.length}); return node.textContent;})()
        """) as? String
        await settle()
        try require(selected?.isEmpty == false, "synthetic passage selected")
        for _ in 0..<3 {
            try require(page.convert(page.bounds, to: nil) == originalPageFrame && frame(of: saveControl) == originalToolbarFrame, "selection causes zero native page/toolbar movement")
            _ = try await page.evaluateJavaScript("document.querySelector('.ProseMirror').editor.commands.setTextSelection(1)")
            await settle()
            try require(page.convert(page.bounds, to: nil) == originalPageFrame && frame(of: saveControl) == originalToolbarFrame, "clear causes zero native page/toolbar movement")
            _ = try await page.evaluateJavaScript("(()=>{const e=document.querySelector('.ProseMirror').editor; e.commands.focus(); e.commands.setTextSelection({from:1,to:1+e.state.doc.child(0).textContent.length});})()")
            await settle()
        }
        try snapshot(window, model: model, name: "mac-document-floating-comment")
        print("DOCUMENT_OVERLAY_NATIVE_GEOMETRY_PASS page/toolbar selection/clear delta=0")
        try require((try await page.evaluateJavaScript("!document.getElementById('doc.commentSelection').hidden")) as? Bool == true, "selection comment icon visible")
        try press(window, "doc.commentsPanel.toggle"); await settle()
        guard let rail = find(window, "doc.commentColumn") else { throw Failure(description: "Missing collapsed rail") }
        try require(frame(of: rail).width <= 45 && find(window, "doc.statusPanel.expand") != nil, "44pt collapsed rail keeps status access")
        try snapshot(window, model: model, name: "mac-document-collapsed-comments")
        let collapsedFrame = page.convert(page.bounds, to: nil)
        _ = try await page.evaluateJavaScript("(()=>{window.webkit.messageHandlers.document.postMessage(JSON.stringify({type:'error',message:'Synthetic collapsed save error'}));return true;})()")
        await settle()
        try require(containsText(rail, "Synthetic collapsed save error"), "collapsed rail exposes current error by accessibility label")
        try require(page.convert(page.bounds, to: nil) == collapsedFrame, "collapsed error status does not move page")
        try press(window, "doc.statusPanel.expand"); await settle()
        try require(find(window, "editor.status") != nil, "status action opens full error controls")
        try type(window, "Retained panel draft"); await settle()
        try press(window, "doc.commentsPanel.toggle"); await settle()
        try press(window, "doc.commentsPanel.toggle"); await settle()
        let draftField = try textView(window)
        try require(draftField.string == "Retained panel draft", "unsent comment draft survives panel collapse/reopen")
        draftField.insertText("", replacementRange: NSRange(location: 0, length: (draftField.string as NSString).length))
        await settle()
        try press(window, "doc.commentsPanel.toggle"); await settle()

        window.makeFirstResponder(page)
        _ = try await page.evaluateJavaScript("(()=>{const e=document.querySelector('.ProseMirror').editor;e.commands.focus();e.commands.setTextSelection(1);e.commands.setTextSelection({from:1,to:1+e.state.doc.child(0).textContent.length});return true;})()")
        await settle()
        try require(page.convert(page.bounds, to: nil) == collapsedFrame, "selection keeps collapsed panel and page stable")
        let actionState = try await page.evaluateJavaScript("JSON.stringify({hidden:document.getElementById('doc.commentSelection').hidden,selected:window.getSelection().toString(),from:document.querySelector('.ProseMirror').editor.state.selection.from,to:document.querySelector('.ProseMirror').editor.state.selection.to})")
        print("DOCUMENT_COMMENT_ACTION_STATE \(String(describing: actionState))")
        try require((try await page.evaluateJavaScript("!document.getElementById('doc.commentSelection').hidden")) as? Bool == true, "actual reader selection offers comment after panel changes")
        _ = try await page.evaluateJavaScript("document.getElementById('doc.commentSelection').click()");
        await settle()
        try await waitFor(window, "doc.statusPanel", "comment save finishes and expands panel")
        try snapshot(window, model: model, name: "mac-document-expanded-selection-comment")
        try require(find(window, "doc.statusPanel.expand") == nil && find(window, "composer.field") != nil, "anchored comment expands panel and composer")
        print("DOCUMENT_PANEL_PASS rightStatus collapsed44 statusAccess selectionStable commentExpands"); await settle(); await settle()
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
