#if DEBUG
import AppKit
import SwiftUI
import WebKit
import AmbulandoCore

/// Synthetic routes for the isolated Mac acceptance check only; no production catalogue or API.
enum MacThreadArtefactFixture {
    static let board = "f1c70000-0000-4000-8000-00000000af01"
    static let html = "f1c70000-0000-4000-8000-00000000af02"
    static let htmlV1 = "f1c70000-0000-4000-8000-00000000af03"
    static let htmlV2 = "f1c70000-0000-4000-8000-00000000af04"
    static let htmlBytes = Data("<html><body style='height:3000px'><h1>HTML proposal</h1><p>Revision two</p></body></html>".utf8)
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-AmbulandoMacThreadArtefactsCheck") }
    static func row(_ id: String) -> [String: Any] {
        let isBoard = id == board
        return ["id": id, "workspace_id": FixtureTower.studio, "channel_id": FixtureTower.generalChannel,
            "display_name": isBoard ? "Architecture whiteboard" : "HTML proposal.html", "row_version": 1,
            "can_write": true, "content_type": isBoard ? BoardScene.contentType : "text/html",
            "created_at": "2026-11-26T00:00:00Z", "updated_at": "2026-11-26T00:00:00Z",
            "metadata": ["artefact": ["schema_version": 1, "format_version": 1,
                "type": isBoard ? "excalidraw" : "html", "editor_id": isBoard ? "builtin.excalidraw" : "builtin.html"]]]
    }
    static func handle(_ request: URLRequest) -> (Int, Any)? {
        guard enabled, let url = request.url, request.httpMethod == "GET" else { return nil }
        let base = "/api/v4/flightdeck-pg/workspaces/\(FixtureTower.studio)/files/"
        if url.path == "/api/v4/flightdeck-pg/workspaces/\(FixtureTower.studio)/channels/\(FixtureTower.generalChannel)/files" {
            return (200, ["files": [row(board), row(html)], "next_cursor": NSNull()])
        }
        if [base + board, base + html].contains(url.path) {
            return (200, ["file": row(url.lastPathComponent)])
        }
        if url.path == base + html + "/html" {
            let selected = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "version_id" }?.value ?? htmlV2
            return (200, ["workspace_id": FixtureTower.studio, "source": ["id": html, "type": "html"],
                "content": ["html": String(decoding: htmlBytes, as: UTF8.self), "digest": SHA256Hex.of(htmlBytes), "version_id": selected,
                    "version_number": selected == htmlV1 ? 1 : 2, "current_version_id": htmlV2, "current_version_number": 2],
                "versions": [["id": htmlV1, "version_number": 1], ["id": htmlV2, "version_number": 2]]])
        }
        if url.path == base + html + "/comments" { return (200, ["comments": [], "next_cursor": NSNull()]) }
        return nil
    }
}

extension MacThreadRegression {
    static func threadArtefactsCheck(_ window: NSWindow, model: AppModel) async throws {
        guard let workspace = model.selectedWorkspace, let store = model.store, let connection = model.connection,
              let fixture = model.fixture else { throw Failure(description: "fixture only") }
        try require(Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", "isolated test bundle")
        print("TASK_FIXTURE_DIR \(fixture.directory.path)")
        let f = MacThreadArtefactFixture.self
        fixture.tower.boards.seed(fileId: f.board, bytes: FixtureTower.sampleBoard(), canWrite: true, author: FixtureTower.ana)
        fixture.tower.boards.seed(fileId: f.html, bytes: f.htmlBytes, canWrite: true, author: FixtureTower.ana)
        let files = try [f.board, f.html].map { try FileRecord(raw: JSONSerialization.data(withJSONObject: f.row($0))) }
        _ = try await store.writer.upsertFiles(workspaceId: workspace.id, files)
        let focus = ThreadFocus(workspaceId: workspace.id, channelId: FixtureTower.generalChannel,
            threadId: FixtureTower.threadReview)
        let target = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: FixtureTower.generalChannel, threadId: focus.threadId)
        try await store.writer.saveDraft(target, Draft(text: "change this", mentions: []))
        model.focusThread(focus)
        for _ in 0..<50 { if MacThreadArtefacts.testingState != nil { break }; await settle() }
        guard let state = MacThreadArtefacts.testingState else { throw Failure(description: "mounted thread workspace") }
        try require(state.tabs.isEmpty, "conversation starts without artefact tabs")
        try press(window, "thread.artefacts.browse"); await settle()
        guard let picker = window.attachedSheet else { throw Failure(description: "native browser sheet") }
        await settle()
        try require(find(picker, "thread.artefacts.browser.row.\(f.board)") != nil, "board enumerated without opening content")
        try snapshot(picker, model: model, name: "mac134-picker")
        try press(picker, "thread.artefacts.browser.cancel"); await settle()
        try require(state.tabs.isEmpty && state.selected == nil && !state.shown, "cancel leaves empty workspace unchanged")
        try press(window, "thread.artefacts.browse"); await settle()
        guard let boardPicker = window.attachedSheet else { throw Failure(description: "board picker") }
        try press(boardPicker, "thread.artefacts.browser.row.\(f.board)"); await settle()
        for _ in 0..<100 {
            if let prepare = state.tabs.first?.prepare, (try? await prepare()) != nil { break }
            await settle()
        }
        guard let boardTab = state.tabs.first, let boardPrepare = boardTab.prepare else { throw Failure(description: "board callback") }
        _ = try await boardPrepare()
        let reply = try textView(window)
        try require(reply.string == "change this", "draft retained on open")
        try press(window, "thread.artefacts.add"); await settle()
        guard let htmlPicker = window.attachedSheet else { throw Failure(description: "HTML picker") }
        try press(htmlPicker, "thread.artefacts.browser.row.\(f.html)"); await settle()
        for _ in 0..<100 {
            if let tab = state.tabs.last, let prepare = tab.prepare, (try? await prepare()) != nil { break }
            await settle()
        }
        let context = try await state.prepare(target: target)
        await settle()
        try require(String(decoding: context ?? Data(), as: UTF8.self).contains(f.board) && String(decoding: context ?? Data(), as: UTF8.self).contains(f.htmlV2), "both exact loaded revisions in context")
        try await menuAction(window, title: "v1", button: "artefacts.versionPicker")
        await settle()
        guard let htmlPrepare = state.tabs.last?.prepare else { throw Failure(description: "HTML version callback") }
        let historicalHTML = try await htmlPrepare()
        try require(historicalHTML.historical && historicalHTML.revision == f.htmlV1, "native version menu pins historical HTML")
        try press(window, "thread.artefacts.add"); await settle()
        guard let existingPicker = window.attachedSheet else { throw Failure(description: "existing picker") }
        try click(existingPicker, "thread.artefacts.browser.search")
        guard let searchEditor = existingPicker.firstResponder as? NSTextView else { throw Failure(description: "native search editor") }
        searchEditor.insertText("no-matching-title-134", replacementRange: NSRange(location: 0, length: searchEditor.string.utf16.count))
        await settle()
        try require(containsText(existingPicker, "No matching artefacts"), "native title search no matches")
        try snapshot(existingPicker, model: model, name: "mac134-no-matches")
        try press(existingPicker, "thread.artefacts.browser.cancel"); await settle()
        try require(state.selected == f.html && state.tabs.count == 2, "cancel leaves selection unchanged")
        try press(window, "thread.artefacts.add"); await settle()
        guard let refocusPicker = window.attachedSheet else { throw Failure(description: "refocus picker") }
        try press(refocusPicker, "thread.artefacts.browser.row.\(f.html)"); await settle()
        let refocusedHTML = try await htmlPrepare()
        try require(refocusedHTML == historicalHTML && state.tabs.count == 2, "browser deduplicates without resetting pinned revision")
        let choice = try await scopeChoice(store, workspace.id)
        let sample = DocsSnapshot(files: files, choice: choice)
        try require(MacThreadArtefactBrowser.rows(sample, channel: FixtureTower.generalChannel, search: "architecture", type: .whiteboard).count == 1, "scope/search/type intersection")
        try require(MacThreadArtefactBrowser.rows(sample, channel: "foreign-channel", search: "", type: nil).isEmpty, "foreign channel excluded")
        var denied = sample; denied.choice.channels = []
        try require(MacThreadArtefactBrowser.rows(denied, channel: "", search: "", type: nil).isEmpty, "undiscovered channels excluded")
        try require(state.tabs.count == 2, "two retained tabs")
        try snapshot(window, model: model, name: "mac-thread-artefacts-before-tab")
        try press(window, "thread.artefacts.tab.\(f.board)"); await settle()
        try require(state.selected == f.board, "native tab button focuses board")
        state.close(boardTab); await settle()
        state.open(kind: "file", id: f.board); await settle()
        try require(state.tabs.first === boardTab && state.tabs.count == 2, "close/reopen retains editor identity")
        try press(window, "thread.artefacts.close"); await settle()
        try require(!state.shown && reply.string == "change this", "close restores draft")
        try press(window, "thread.artefacts.reopen"); await settle()
        try press(window, "thread.artefacts.expand"); await settle()
        try require(state.expanded, "expand keeps mounted work")
        try press(window, "thread.artefacts.expand"); await settle()
        let old = window.frame
        window.setContentSize(NSSize(width: 1000, height: 700)); await settle()
        try require(reply.string == "change this", "resize retains composer")
        window.setFrame(old, display: true)
        // Failure injection exercises the real host send barrier, without claiming a live network denial.
        let savedPrepare = boardTab.prepare
        boardTab.prepare = { throw URLError(.notConnectedToInternet) }
        state.close(boardTab); await settle()
        try require(boardTab.open && state.failure != nil, "close failure retains tab")
        do { _ = try await state.prepare(target: target); throw Failure(description: "offline barrier accepted") }
        catch is URLError {}
        try require(state.failure != nil && reply.string == "change this", "failed save retains actionable draft")
        let beforeFailedSend = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500).count
        try press(window, "composer.send"); await settle(); await settle()
        try require(reply.string == "change this", "native Send failure retains original draft")
        let afterFailedSend = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500).count
        let pendingFailedSend = try await store.reader.outbox(connectionId: connection.id, signerNpub: connection.signerNpub)
        try require(afterFailedSend == beforeFailedSend && pendingFailedSend.isEmpty, "failed save neither enqueues nor posts a message")
        boardTab.prepare = savedPrepare
        _ = try await state.prepare(target: target)
        await settle()
        // Deliver a synthetic editing peer's change to the real mounted board, then send through the native composer.
        guard let sync = model.sync else { throw Failure(description: "fixture sync") }
        let reference = try await sync.artefactBoard(connection, workspace, fileId: f.board)
        guard let boardSession = model.boardSession(reference, title: "Architecture whiteboard", in: workspace) else {
            throw Failure(description: "shared board controller")
        }
        await boardSession.controller.attach("acceptance-peer") { _ in }
        var scene = try JSONSerialization.jsonObject(with: FixtureTower.sampleBoard()) as! [String: Any]
        var elements = scene["elements"] as! [[String: Any]]
        elements[0]["version"] = 1001
        elements[0]["customData"] = ["threadSendAcceptance": true]
        scene["elements"] = elements
        await boardSession.controller.receive("acceptance-peer", BoardController.message(["type": "change", "scene": scene]))
        await boardSession.controller.detach("acceptance-peer")
        await settle()
        try require(boardSession.state.dirty, "pending whiteboard edit before Send")
        let versionsBeforeSend = fixture.tower.boards.versionCount(f.board)
        try press(window, "composer.send")
        var sent: MessageRecord?
        for _ in 0..<60 {
            sent = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500)
                .first { $0.body == "change this" }
            if sent != nil { break }; await settle()
        }
        guard let sent else { throw Failure(description: "canonical fixture message receipt after save") }
        let savedState = await boardSession.controller.current
        try require(fixture.tower.boards.versionCount(f.board) == versionsBeforeSend + 1, "Send publishes pending whiteboard change first")
        try require(sent.body == "change this", "canonical visible body is exact user text")
        let received = try JSONSerialization.jsonObject(with: sent.raw) as! [String: Any]
        let metadata = received["metadata"] as? [String: Any]
        let snapshotData = try JSONSerialization.data(withJSONObject: metadata?[ArtefactChatContext.metadataKey] as Any)
        _ = try ArtefactChatContext.validate(snapshotData, for: target)
        let frozenContext = try JSONDecoder().decode(ArtefactChatContext.self, from: snapshotData)
        try require(frozenContext.open.contains { $0.recordID == f.board && $0.revision == savedState.baseVersionId }
            && frozenContext.open.contains { $0.recordID == f.html && $0.revision == f.htmlV1 && $0.historical }, "metadata names exact saved board and pinned HTML revisions")
        let exactSnapshot = try await state.prepare(target: target)
        let expectedSnapshot = try JSONDecoder().decode(ArtefactChatContext.self, from: exactSnapshot ?? Data())
        try require(frozenContext.open.first { $0.recordID == f.board }?.digest == SHA256Hex.of(fixture.tower.boards.currentBytes(f.board) ?? Data()), "saved board digest survives version-list clearing")
        try require(frozenContext.open.first { $0.recordID == f.html }?.digest == SHA256Hex.of(f.htmlBytes), "pinned HTML digest retained")
        try require(frozenContext == expectedSnapshot, "canonical metadata equals complete exact selected snapshot")
        guard let canonical = fixture.tower.boards.currentBytes(f.board) else { throw Failure(description: "saved board bytes") }
        try require(String(decoding: canonical, as: UTF8.self).contains("threadSendAcceptance"), "exact saved board contains final edit")
        print("AGENT_CONTEXT_BASE64 \(sent.raw.base64EncodedString())")
        let realTabs = state.tabs
        for index in 0..<12 {
            let tab = MacThreadArtefactTab(kind: "doc", id: "layout-\(index)")
            tab.title = "A very long document title for architecture and planning \(index)"
            state.tabs.append(tab)
        }
        state.tabs = Array(state.tabs.dropFirst(realTabs.count)) + realTabs
        state.selected = f.board
        await settle()
        for (index, tab) in state.tabs.filter({ $0.id.hasPrefix("layout-") }).enumerated() {
            tab.title = "A very long document title for architecture and planning \(index)"
        }
        state.selected = f.html
        window.setContentSize(NSSize(width: 1440, height: 900)); await settle()
        try snapshot(window, model: model, name: "mac134-tabs-wide")
        window.setContentSize(NSSize(width: 1000, height: 700)); await settle()
        try require(find(window, "thread.artefacts.add") != nil, "plus remains reachable in narrow many-tab strip")
        try snapshot(window, model: model, name: "mac134-tabs-narrow")
        let priorAppearance = UserDefaults.standard.string(forKey: "appearance")
        let priorWindowAppearance = window.appearance
        UserDefaults.standard.set("dark", forKey: "appearance")
        window.appearance = NSAppearance(named: .darkAqua); await settle()
        try snapshot(window, model: model, name: "mac134-tabs-narrow-dark")
        UserDefaults.standard.set(priorAppearance, forKey: "appearance")
        window.appearance = priorWindowAppearance
        state.tabs = realTabs; state.selected = f.html
        window.setFrame(old, display: true); await settle()
        try snapshot(window, model: model, name: "mac-thread-artefacts")
        print("PASS: actual AppKit thread, two editor tabs, exact context, tab focus, close/reopen identity, expand, resize and failure draft preservation; synthetic Tower and injected failure")
    }
}
#endif
