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
        state.open(kind: "file", id: f.board)
        for _ in 0..<100 {
            if let prepare = state.tabs.first?.prepare, (try? await prepare()) != nil { break }
            await settle()
        }
        guard let boardTab = state.tabs.first, let boardPrepare = boardTab.prepare else { throw Failure(description: "board callback") }
        _ = try await boardPrepare()
        let reply = try textView(window)
        try require(reply.string == "change this", "draft retained on open")
        state.open(kind: "file", id: f.html)
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
        try snapshot(window, model: model, name: "mac-thread-artefacts")
        print("PASS: actual AppKit thread, two editor tabs, exact context, tab focus, close/reopen identity, expand, resize and failure draft preservation; synthetic Tower and injected failure")
    }
}
#endif
