#if DEBUG
import AppKit
import WebKit
import AmbulandoCore

extension MacThreadRegression {
    static func dataRefreshCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", let fixture = model.fixture else {
            throw Failure(description: "Refresh check requires isolated Mac Test")
        }
        model.selectWorkspace(FixtureTower.studio)
        model.selectContext(WorkContext(scopeId: FixtureTower.scopeAmbulando, channelId: FixtureTower.generalChannel))
        model.mode = .chat
        await settle(); await settle()
        guard let store = model.store, let connection = model.connection, let workspace = model.selectedWorkspace,
              let entry = model.enabledWorkspaceEntries.first(where: { $0.boundary == model.selectedWorkspaceBoundary }),
              let runtime = entry.runtime else { throw Failure(description: "Missing selected runtime") }
        let boundary = model.selectedWorkspaceBoundary, context = model.context, path = model.chatPath
        let thread = FixtureTower.threadReview
        let target = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: FixtureTower.generalChannel, threadId: thread)
        let pending = PendingAttachment(filename: "refresh-draft.txt", mimeType: "text/plain", sizeBytes: 1,
                                        sha256: String(repeating: "0", count: 64), staged: "fixture-only.txt")
        try await store.writer.saveDraft(target, Draft(text: "Unsent refresh reply", mentions: [], attachments: [pending]))
        model.focusThread(ThreadFocus(workspaceId: workspace.id, channelId: FixtureTower.generalChannel, threadId: thread))
        await settle(); await settle()
        try await waitFor(window, "composer.field", "open reply")
        let composer = try textView(window)
        try require(composer.string == "Unsent refresh reply", "stored reply restored")
        try type(window, " plus typing")
        let text = composer.string, focus = model.focusedThread
        fixture.tower.postAsMember(channel: FixtureTower.generalChannel, body: "Remote reply fetched by Refresh data", threadId: thread)
        try press(window, "data.refresh")
        let attempts = model.dataRefresh.attempts
        model.dataRefresh.start(model); model.dataRefresh.start(model)
        try require(model.dataRefresh.running && model.dataRefresh.attempts == attempts, "duplicate refresh requests suppressed synchronously")
        await model.dataRefresh.operation?.value
        try require(!model.dataRefresh.failed, "refresh succeeds")
        try await waitForText(window, "Remote reply fetched by Refresh data", "same open thread receives remote reply", seconds: 10)
        fixture.tower.postAsMember(channel: FixtureTower.generalChannel, body: "Live reply after explicit refresh", threadId: thread)
        try await waitForText(window, "Live reply after explicit refresh", "automatic other-device updates continue without another refresh", seconds: 15)
        try require(try textView(window) === composer && composer.string == text, "same live composer retains typed reply")
        try require(model.focusedThread == focus && model.context == context && model.chatPath == path && model.selectedWorkspaceBoundary == boundary, "selection and navigation preserved")
        try await Task.sleep(for: .milliseconds(500))
        let draft = try await store.reader.draft(target)
        try require(draft?.text == text && draft?.attachments == [pending], "durable draft and pending attachment preserved")
        window.setContentSize(NSSize(width: 900, height: 600)); await settle()
        try require(find(window, "data.refresh") != nil, "refresh accessible in narrow focused conversation")
        fixture.tower.failScopes = true
        model.dataRefresh.start(model); await model.dataRefresh.operation?.value
        try require(model.dataRefresh.failed && model.dataRefresh.message?.contains("could not refresh") == true, "failed scoped refresh reported honestly")
        try require(composer.string == text && model.focusedThread == focus, "failure keeps draft and thread")
        fixture.tower.failScopes = false
        model.dataRefresh.start(model); await model.dataRefresh.operation?.value
        try require(!model.dataRefresh.failed, "explicit retry recovers past backoff")
        model.dataRefresh.start(model)
        runtime.activity.pause()
        await model.dataRefresh.operation?.value
        try require(model.dataRefresh.failed && model.dataRefresh.message?.contains("stopped") == true, "invalidated generation never reports success")
        runtime.activity.resume()
        try require(composer.string == text, "access cancellation preserves unsent text")
        try press(window, "thread.focus.close"); await settle()
        try require(find(window, "data.refresh") == nil, "section strip carries no refresh control; Account > Refresh Data and per-surface buttons remain")
        model.focusedThread = ThreadFocus(workspaceId: FixtureTower.lab, channelId: "foreign-channel", threadId: "foreign-thread")
        model.dataRefresh.start(model)
        model.focusedThread = nil
        await model.dataRefresh.operation?.value
        try require(!model.dataRefresh.failed, "stale foreign workspace focus cannot schedule foreign channel reads")
        if let other = model.workspaceEntries.first(where: { $0.boundary != boundary }) {
            model.setWorkspaceEnabled(other, true)
            for _ in 0..<50 { if other.runtime?.validated == true { break }; await settle() }
            try require(other.runtime?.validated == true, "second workspace ready for selection race")
            model.dataRefresh.start(model)
            model.openWorkspace(other, context: .home)
            await model.dataRefresh.operation?.value
            try require(model.selectedWorkspaceBoundary == other.boundary, "late refresh never restores previous selection")
            try require(model.dataRefresh.message != "Data refreshed.", "old workspace completion never reports current workspace success")
            model.openWorkspace(entry, context: context); await settle(); await settle()
        } else { throw Failure(description: "Missing second workspace for selection race") }

        // The browser uses the same operation without navigating/reloading its WebKit document.
        model.browser.open(nil)
        guard let tab = model.browser.selected else { throw Failure(description: "Missing browser tab") }
        tab.webView.loadHTMLString("<html><body><input id='draft' value='Browser unsent form'></body></html>", baseURL: nil)
        for _ in 0..<40 {
            if (try? await tab.webView.evaluateJavaScript("document.getElementById('draft')?.value")) as? String == "Browser unsent form" { break }
            await settle()
        }
        let tabId = tab.id, history = tab.webView.backForwardList.backList.count
        guard let browserWindow = NSApp.windows.first(where: { find($0, "browser.return") != nil }) else {
            throw Failure(description: "Missing browser window")
        }
        browserWindow.setContentSize(NSSize(width: 640, height: 480)); await settle()
        try require(find(browserWindow, "data.refresh") != nil, "browser refresh accessible at minimum width")
        _ = try await tab.webView.evaluateJavaScript("window.refreshSentinel = 42")
        model.dataRefresh.start(model); await model.dataRefresh.operation?.value
        try require(!model.dataRefresh.failed, "refresh recovers after cancellation")
        try require(model.browser.selectedId == tabId && tab.webView.backForwardList.backList.count == history, "browser tab and history preserved")
        try require((try await tab.webView.evaluateJavaScript("window.refreshSentinel === 42 && document.getElementById('draft').value === 'Browser unsent form'")) as? Bool == true, "browser document and unsent form not reloaded")
        model.browser.presented = false

        // A live document editor must keep both its host and uncheckpointed content during refresh.
        model.selectContext(.home); model.mode = .docs; model.docsPath = []
        window.makeKeyAndOrderFront(nil)
        await settle(); await settle()
        try await waitFor(window, "doc.Native app plan", "document list")
        try press(window, "doc.Native app plan"); await settle(); await settle()
        try await waitFor(window, "doc.edit", "document reader")
        try press(window, "doc.edit"); await settle()
        let docs = try await store.reader.docs(workspaceId: workspace.id)
        guard let doc = docs.first(where: { $0.title == "Native app plan" }) else { throw Failure(description: "Missing doc") }
        for _ in 0..<60 {
            if WikiEditors.editor(connectionId: connection.id, workspaceId: workspace.id, docId: doc.id)?.pageReady == true { break }
            await settle()
        }
        guard let editor = WikiEditors.editor(connectionId: connection.id, workspaceId: workspace.id, docId: doc.id), let page = editor.page?.webView else {
            throw Failure(description: "Missing document editor")
        }
        let body = try await page.evaluateJavaScript("(()=>{const e=document.querySelector('.ProseMirror').editor;e.view.dom.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'insertText',data:' refresh sentinel'}));e.commands.focus();e.commands.setTextSelection(e.state.doc.content.size-1);e.commands.insertContent(' Refresh unsaved document sentinel');return e.getText()})()") as? String
        try require(body?.contains("Refresh unsaved document sentinel") == true, "unsaved document edit was actually entered")
        let docsPath = model.docsPath
        model.dataRefresh.start(model); await model.dataRefresh.operation?.value
        try require(!model.dataRefresh.failed, "document refresh succeeds")
        try require(editor.page?.webView === page && model.docsPath == docsPath, "document host and navigation preserved")
        try require((try await page.evaluateJavaScript("document.querySelector('.ProseMirror').editor.getText()")) as? String == body, "unsaved document edits preserved")
        print("PASS: native Refresh data same-thread remote update, live composer/durable attachment, duplicate suppression, narrow/main controls, failure/retry, generation cancellation, browser form/history, unsaved document editor")
    }
}
#endif
