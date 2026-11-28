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
    static func draftArtefactsCheck(_ window: NSWindow, model: AppModel, workspace: WorkspaceRecord, store: LocalStore, connection: ConnectionRecord) async throws {
        let f = MacThreadArtefactFixture.self
        model.selectContext(WorkContext(scopeId: FixtureTower.scopeAmbulando, channelId: FixtureTower.generalChannel))
        model.composingThread = true
        try await waitFor(window, "thread.artefacts.browse", "draft artefact toolbar before first Send")
        guard let state = MacThreadArtefacts.testingState else { throw Failure(description: "draft workspace mounted") }
        try require(state.draftTarget?.threadId == nil && state.draftTarget != nil, "draft local target")
        let target = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: FixtureTower.generalChannel)
        // Wait for the composer's asynchronous model/draft restoration, then use its real input path.
        await settle()
        try type(window, "Before suffix"); await settle()
        let field = try textView(window)
        try require(field.string == "Before suffix", "native typing reaches the restored draft model")
        field.setSelectedRange(NSRange(location: 6, length: 0))
        let before = try await store.reader.channelFeed(workspaceId: workspace.id, channelId: target.channelId, limit: 500).count
        try press(window, "thread.artefacts.browse"); await settle()
        guard let picker = window.attachedSheet else { throw Failure(description: "draft picker") }
        try await waitFor(picker, "thread.artefacts.browser.row.\(f.board)", "draft authorised whiteboard")
        try press(picker, "thread.artefacts.browser.cancel"); await settle()
        try require(state.tabs.isEmpty && field.string == "Before suffix", "cancel preserves text and creates no selection")
        state.open(kind: "file", id: f.board)
        for _ in 0..<60 {
            if let tab = state.tabs.first, let prepare = tab.prepare, (try? await prepare()) != nil { break }
            await settle()
        }
        guard let tab = state.tabs.first, let prepare = tab.prepare else { throw Failure(description: "draft editor ready") }
        try require(state.members.count == 1 && state.transport == nil, "draft membership remains local")
        let member = try ThreadArtefactMember(kind: "file", id: f.board)
        state.remove(member)
        try require(state.members.isEmpty && !tab.attached, "draft removal excludes source without a posted thread")
        let empty = try await state.prepare(target: target)
        try require(empty == nil, "removed draft source is excluded from Send")
        state.open(kind: "file", id: f.board); try await membershipIdle(state)
        await state.saveRecovery(tab)
        try require(tab.attached && state.members == [member], "explicit recovery Save resumes reselected draft source")
        do {
            _ = try await state.prepare(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: "00000000-0000-4000-8000-000000000099"))
            throw Failure(description: "foreign draft destination accepted")
        } catch ArtefactChatContext.ContextError.unresolved {}
        try await waitFor(window, "thread.artefacts.tag", "reattached draft Tag control")
        try press(window, "thread.artefacts.tag"); await settle()
        try require(field.string.contains("mention:file:\(f.board)") && field.string.hasPrefix("Before") && field.string.hasSuffix("suffix"), "canonical Tag keeps caret suffix and text")
        let selectedContext = try await state.prepare(target: target)
        let context = try JSONDecoder().decode(ArtefactChatContext.self, from: selectedContext ?? Data())
        try require(context.threadID == nil && context.open.first?.recordID == f.board, "draft exact revision context")
        let after = try await store.reader.channelFeed(workspaceId: workspace.id, channelId: target.channelId, limit: 500).count
        try require(before == after, "browse select tag never posts an empty thread")
        let original = tab.prepare
        tab.prepare = { throw URLError(.notConnectedToInternet) }
        let typed = field.string
        try press(window, "composer.send"); await settle()
        try require(field.string == typed && state.failure != nil, "save failure keeps first-message draft")
        tab.prepare = original
        try snapshot(window, model: model, name: "mac-draft-artefacts-before-send")
        try press(window, "composer.send")
        var root: MessageRecord?
        for _ in 0..<80 {
            let feed = try await store.reader.channelFeed(workspaceId: workspace.id, channelId: target.channelId, limit: 500)
            root = feed.map(\.message).first { $0.body == typed }
            if root != nil && !model.composingThread { break }
            await settle()
        }
        guard let root, let thread = root.threadId else { throw Failure(description: "first message accepted") }
        let postedTarget = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: target.channelId, threadId: thread)
        let frozen = try ArtefactChatContext.firstMessage(root, for: postedTarget)
        try require(frozen?.open == context.open, "confirmed first message retains exact saved revision metadata")
        guard let row = try await store.reader.thread(workspaceId: workspace.id, id: thread) else { throw Failure(description: "new thread") }
        let members = try ThreadArtefactMembership.read(ThreadArtefactMembership.metadata(row))
        try require(members?.first?.id == f.board, "acknowledged membership promoted with existing CAS")
        try require(MacThreadArtefacts.testingState === state && state.tabs.first === tab, "new thread keeps same pinned editors")
        _ = try await prepare()
    }

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
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacDraftArtefactsCheck") {
            try await draftArtefactsCheck(window, model: model, workspace: workspace, store: store, connection: connection)
            print("PASS: pre-send draft artefacts, native tagging, save barrier and first-message context")
            return
        }
        let focus = ThreadFocus(workspaceId: workspace.id, channelId: FixtureTower.generalChannel,
            threadId: FixtureTower.threadReview)
        let target = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: FixtureTower.generalChannel, threadId: focus.threadId)
        try await store.writer.saveDraft(target, Draft(text: "change this", mentions: []))
        model.focusThread(focus)
        for _ in 0..<50 { if MacThreadArtefacts.testingState != nil { break }; await settle() }
        guard let state = MacThreadArtefacts.testingState else { throw Failure(description: "mounted thread workspace") }
        try require(state.tabs.isEmpty && !state.shown, "zero attachments have no workspace tab bar")
        try await waitFor(window, "thread.artefacts.browse", "zero attachment header icon")
        guard let pin = find(window, "pin.toggle"), let artefactsIcon = find(window, "thread.artefacts.browse") else { throw Failure(description: "Pin and artefacts header controls") }
        try require(abs(frame(of: pin).midY - frame(of: artefactsIcon).midY) < 4 && frame(of: artefactsIcon).minX >= frame(of: pin).maxX - 2,
            "artefacts icon is beside Pin in the actual outer header at zero")
        try press(window, "thread.artefacts.browse"); await settle()
        guard let picker = window.attachedSheet else { throw Failure(description: "native browser sheet") }
        await settle()
        try await waitFor(picker, "thread.artefacts.browser.row.\(f.board)", "authorized board browser row")
        try require(find(picker, "thread.artefacts.browser.row.\(f.board)") != nil, "board enumerated without opening content")
        try snapshot(picker, model: model, name: "mac134-picker")
        try press(picker, "thread.artefacts.browser.cancel"); await settle()
        try require(state.tabs.isEmpty && state.selected == nil && !state.shown, "cancel leaves empty workspace unchanged")
        try press(window, "thread.artefacts.browse"); await settle()
        guard let boardPicker = window.attachedSheet else { throw Failure(description: "board picker") }
        try await waitFor(boardPicker, "thread.artefacts.browser.row.\(f.board)", "authorized artefact browser row")
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
        try await waitFor(htmlPicker, "thread.artefacts.browser.row.\(f.html)", "authorized artefact browser row")
        try press(htmlPicker, "thread.artefacts.browser.row.\(f.html)"); await settle()
        for _ in 0..<100 {
            if !state.busy, let tab = state.tabs.first(where: { $0.id == f.html }), let prepare = tab.prepare, (try? await prepare()) != nil { break }
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
        try await waitForText(existingPicker, "No matching artefacts", "native title search no matches", seconds: 10)
        try require(containsText(existingPicker, "No matching artefacts"), "native title search no matches")
        try snapshot(existingPicker, model: model, name: "mac134-no-matches")
        try press(existingPicker, "thread.artefacts.browser.cancel"); await settle()
        try require(state.selected == f.html && state.tabs.count == 2, "cancel leaves selection unchanged")
        try press(window, "thread.artefacts.add"); await settle()
        guard let refocusPicker = window.attachedSheet else { throw Failure(description: "refocus picker") }
        try await waitFor(refocusPicker, "thread.artefacts.browser.row.\(f.html)", "authorized artefact browser row")
        try press(refocusPicker, "thread.artefacts.browser.row.\(f.html)"); await settle()
        try await membershipIdle(state)
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
        state.close(boardTab); await settle(); try await membershipIdle(state)
        state.open(kind: "file", id: f.board); await settle(); try await membershipIdle(state)
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
        try await sharedMembershipCheck(window, model: model, state: state, target: target, boardTab: boardTab)
        print("PASS: actual AppKit thread, two editor tabs, exact context, tab focus, close/reopen identity, expand, resize and failure draft preservation; synthetic Tower and injected failure")
    }
    static func membershipControlReady(_ window: NSWindow, _ id: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        while Date() < deadline {
            if let node = find(window, id), node.responds(to: selector) {
                typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
                if unsafeBitCast(node.method(for: selector), to: Enabled.self)(node, selector) { return }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw Failure(description: "Control remained disabled: \(id)")
    }
    static func membershipMessage(_ store: LocalStore, _ target: ChatTarget, body: String) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let rows = try await store.reader.threadMessages(workspaceId: target.workspaceId, threadId: target.threadId!, limit: 500)
            if rows.contains(where: { $0.body == body }) { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw Failure(description: "Canonical message not acknowledged: \(body)")
    }

    static func membershipIdle(_ state: MacThreadArtefacts) async throws {
        await Task.yield()
        for _ in 0..<50 {
            if !state.busy {
                await settle()
                if !state.busy { return }
            } else { await settle() }
        }
        throw Failure(description: "Membership/editor command did not finish: \(state.failure ?? "pending")")
    }

    static func sharedMembershipCheck(_ window: NSWindow, model: AppModel, state: MacThreadArtefacts,
                                      target: ChatTarget, boardTab: MacThreadArtefactTab) async throws {
        guard let workspace = model.selectedWorkspace, let connection = model.connection, let sync = model.sync,
              let store = model.store, let fixture = model.fixture, let saver = model.saver, let thread = target.threadId else {
            throw Failure(description: "shared membership fixture")
        }
        let f = MacThreadArtefactFixture.self
        let secondStore = try LocalStore(directory: fixture.directory.appendingPathComponent("independent-membership-store"))
        _ = try await secondStore.writer.saveConnection(connection)
        try await secondStore.writer.replaceWorkspaces(connectionId: connection.id, [workspace])
        let secondSync = WorkspaceSync(store: secondStore, engine: sync.engine, identity: sync.identity, transport: sync.transport)
        let peer = try secondSync.threadMembershipTransport(connection, workspace, threadId: thread)
        let secondRow = try await peer.read()
        let discovered = try ThreadArtefactMembership.read(ThreadArtefactMembership.metadata(secondRow)) ?? []
        try require(Set(discovered.map(\.id)) == Set([f.board, f.html]), "independent store discovers shared board and HTML")
        let htmlTab = state.tabs.first { $0.id == f.html }!
        let historicalBefore = try await htmlTab.prepare!()
        window.orderOut(nil); await settle()
        window.makeKeyAndOrderFront(nil); await state.refresh(); await settle()
        let historicalAfter = try await htmlTab.prepare!()
        try require(historicalBefore == historicalAfter, "native window background/resume preserves historical pin")
        let fresh = MacThreadArtefacts(); fresh.transport = peer; await fresh.refresh()
        try require(fresh.members.count == 2 && fresh.tabs.isEmpty, "fresh client lists attachments without mounting editors")
        let lazyContext = try await fresh.prepare(target: target)
        try require(lazyContext == nil, "unopened members do not enter plain Chat context")
        let title = try await secondSync.threadArtefactLabel(connection, workspace, member: discovered[0])
        try require(title == "Architecture whiteboard", "fresh metadata label is readable without editor load")

        // Seed an authorized Doc and open it through the actual native browser.
        let docID = "f1c70000-0000-4000-8000-00000000af05"
        let body = DocumentBody.newDocument(text: "Shared membership document")
        _ = fixture.tower.work.seedDoc(id: docID, scope: FixtureTower.scopeAmbulando, channel: target.channelId,
            title: "Shared membership document", body: body.bytes, contentType: body.contentType)
        _ = try await saver.latest(connection, workspace, docId: docID)
        try press(window, "thread.artefacts.add"); await settle()
        guard let browser = window.attachedSheet else { throw Failure(description: "Doc add browser") }
        for _ in 0..<30 { if find(browser, "thread.artefacts.browser.row.\(docID)") != nil { break }; await settle() }
        try press(browser, "thread.artefacts.browser.row.\(docID)"); await settle()
        for _ in 0..<50 { if state.tabs.contains(where: { $0.id == docID }) { break }; await settle() }
        guard let docTab = state.tabs.first(where: { $0.id == docID }) else { throw Failure(description: "mounted Doc tab") }
        try await waitFor(window, "doc.edit", "shared Doc reader")
        try press(window, "doc.edit"); await settle()
        for _ in 0..<50 { if docTab.testingDocument != nil { break }; await settle() }
        guard let editor = docTab.testingDocument else { throw Failure(description: "real mounted Doc editor") }
        editor.title = "Detached dirty recovery"
        try require(await editor.checkpoint() && editor.dirty, "Doc dirty edit checkpointed")
        let before = fixture.tower.work.doc(docID)?["row_version"] as? Int
        let docMember = try ThreadArtefactMember(kind: "doc", id: docID)
        _ = try await ThreadArtefactMembershipSync.change(docMember, adding: false, transport: peer)
        await state.refresh(); await settle()
        await editor.flush()
        try require(!docTab.attached && editor.threadDetached && editor.dirty, "remote dirty detach holds Doc automatic publication")
        try require(fixture.tower.work.doc(docID)?["row_version"] as? Int == before, "detach and flush never publish source")
        let recovery = try await store.reader.docDraft(key: editor.draftKey)
        try require(recovery?.title == "Detached dirty recovery", "detached recovery durable in local store")
        try require(recovery?.state == .recovery, "detached checkpoint never resets recovery to editing")
        try require(try await store.reader.documentAutomaticPublishingHeld(key: editor.draftKey), "detached source has durable automatic-publish hold")
        let cachedDoc = try await store.reader.doc(workspaceId: workspace.id, id: docID)!
        let globalEditor = DocEditorModel(doc: cachedDoc, workspace: workspace, store: store, connection: connection, app: model)
        await globalEditor.load(); globalEditor.setActive(true)
        try require(globalEditor.automaticPublishingHeld && globalEditor.title == "Detached dirty recovery", "global Docs restores held recovery")
        await globalEditor.flush()
        try require(!(await globalEditor.save(automatic: true)), "global Docs cannot automatically publish held recovery")
        let reopenedStore = try LocalStore(directory: URL(fileURLWithPath: store.path).deletingLastPathComponent())
        let relaunchedEditor = DocEditorModel(doc: cachedDoc, workspace: workspace, store: reopenedStore, connection: connection, app: model)
        await relaunchedEditor.load()
        try require(relaunchedEditor.automaticPublishingHeld, "reopened database/editor restores durable hold")
        await relaunchedEditor.flush()
        try require(!(await relaunchedEditor.save(automatic: true)), "relaunch cannot automatically publish recovery")
        try require(fixture.tower.work.doc(docID)?["row_version"] as? Int == before, "global and relaunched automatic entrypoints never publish source")
        globalEditor.close(); relaunchedEditor.close()
        let withoutDoc = try await state.prepare(target: target)
        let refs = try JSONDecoder().decode(ArtefactChatContext.self, from: withoutDoc ?? Data())
        try require(!refs.open.contains(where: { $0.recordID == docID }), "removed Doc excluded from future Send")
        _ = try await ThreadArtefactMembershipSync.change(docMember, adding: true, transport: peer)
        await state.refresh()
        state.open(kind: "doc", id: docID); await settle(); try await membershipIdle(state)
        try require(!docTab.attached && editor.dirty && editor.threadDetached, "acknowledged re-add keeps dirty recovery held")
        try press(window, "thread.artefacts.recovery.save"); await settle(); try await membershipIdle(state)
        try require(docTab.attached && !editor.dirty && !editor.threadDetached, "explicit source Save verifies and resumes attachment")
        try require(!(try await store.reader.documentAutomaticPublishingHeld(key: editor.draftKey)), "confirmed explicit source Save releases durable recovery hold")
        let savedDocVersion = fixture.tower.work.doc(docID)?["row_version"] as? Int
        _ = try await ThreadArtefactMembershipSync.change(docMember, adding: false, transport: peer)
        await state.refresh()
        _ = try await ThreadArtefactMembershipSync.change(docMember, adding: true, transport: peer)
        await state.refresh(); state.open(kind: "doc", id: docID); try await membershipIdle(state)
        try press(window, "thread.artefacts.recovery.save"); try await membershipIdle(state)
        print("CLEAN_RESUME_STATE attached=\(docTab.attached) held=\(editor.automaticPublishingHeld) busy=\(state.busy) failure=\(state.failure ?? "none")")
        try require(docTab.attached && !editor.automaticPublishingHeld, "clean detached recovery also resumes after explicit verification")
        try require(fixture.tower.work.doc(docID)?["row_version"] as? Int == savedDocVersion, "clean explicit resume creates no source version")
        let discussed = try await state.prepare(target: target)
        try require(String(decoding: discussed ?? Data(), as: UTF8.self).contains(docID), "reattached clean source usable in discussion")

        // Freeze an exact request, then remove shared membership. No future capture changes that request.
        let frozenItem = try await secondStore.writer.enqueueSend(target: target, origin: connection.origin,
            signerNpub: connection.signerNpub, appNpub: workspace.appNpub, body: "Frozen membership test", mentions: [], artefactContext: discussed)
        let frozen = try await OutboxRequest.build(frozenItem, signer: sync.identity)
        _ = try await secondStore.writer.freezeOutbox(id: frozenItem.id, request: frozen)

        // Simulate an independently attached source inaccessible to this fixture identity. No editor is opened.
        let unreadable = try ThreadArtefactMember(kind: "file", id: "dead0000-0000-4000-8000-000000000001")
        let base = try await peer.read()
        let current = try ThreadArtefactMembership.read(ThreadArtefactMembership.metadata(base)) ?? []
        _ = try await peer.write(base, ThreadArtefactMembership.replacing(ThreadArtefactMembership.metadata(base), with: current + [unreadable]))
        await fresh.refresh()
        let plain = try await fresh.prepare(target: target)
        try require(plain == nil && fresh.tabs.isEmpty, "plain Chat usable with unreadable lazy member")
        do { _ = try await secondSync.threadArtefactLabel(connection, workspace, member: unreadable); throw Failure(description: "unreadable member granted source access") }
        catch let error as TowerError { if case .http(let status, _, _) = error { try require([403, 404].contains(status), "source ACL denied") } else { throw error } }

        // Plain Chat uses the real composer with every source view closed and an unreadable member still attached.
        for tab in state.tabs { tab.open = false }
        state.shown = false
        await state.refresh(); await settle()
        try type(window, "Plain Chat with unreadable lazy member")
        try await membershipControlReady(window, "composer.send")
        try press(window, "composer.send")
        try await membershipMessage(store, target, body: "Plain Chat with unreadable lazy member")
        await settle()
        let plainMessages = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: thread, limit: 500)
        try require(plainMessages.contains(where: { $0.body == "Plain Chat with unreadable lazy member" }), "native plain Chat sends with unreadable lazy member")

        // Real native Remove controls, including last removal; never delete source records.
        await state.refresh(); state.shown = false
        try press(window, "thread.artefacts.browse"); await settle()
        guard let removalBrowser = window.attachedSheet else { throw Failure(description: "removal browser") }
        for member in state.members {
            try await membershipControlReady(removalBrowser, "thread.artefacts.remove.\(member.id)")
            try press(removalBrowser, "thread.artefacts.remove.\(member.id)")
            for _ in 0..<40 { if !state.busy && !state.members.contains(member) { break }; await settle() }
            try require(!state.members.contains(member), "native shared removal acknowledged")
        }
        try press(removalBrowser, "thread.artefacts.browser.cancel"); await settle()
        await fresh.refresh()
        try require(state.members.isEmpty && fresh.members.isEmpty && !state.shown, "last removal shared and empty workspace hidden")
        try require(find(window, "thread.artefacts.browse") != nil, "header browser remains at zero")
        try require(fixture.tower.work.doc(docID) != nil && fixture.tower.boards.currentBytes(f.board) != nil, "removal never deletes sources")
        let retained = try await secondStore.reader.outboxItem(id: frozenItem.id)
        try require(retained?.request == frozen && retained?.artefactContext == discussed, "frozen request/context unchanged after shared removals")
        let emptyBase = try await peer.read()
        var unknown = try JSONSerialization.jsonObject(with: ThreadArtefactMembership.metadata(emptyBase)) as! [String: Any]
        unknown[ThreadArtefactMembership.key] = ["version": 2, "items": []]
        _ = try await peer.write(emptyBase, JSONSerialization.data(withJSONObject: unknown))
        await state.refresh(); await settle()
        try require(state.membershipError != nil, "future schema blocks membership changes")
        try type(window, "Plain Chat with future membership schema")
        try await membershipControlReady(window, "composer.send")
        try press(window, "composer.send")
        try await membershipMessage(store, target, body: "Plain Chat with future membership schema")
        await settle()
        let unknownMessages = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: thread, limit: 500)
        try require(unknownMessages.contains(where: { $0.body == "Plain Chat with future membership schema" }), "future schema does not block ordinary native Chat")
        // Initial absent observation must not race migration and detach retained legacy tabs.
        let futureBase = try await peer.read()
        let absent = try await peer.write(futureBase, Data("{\"other_app\":{\"keep\":true}}".utf8))
        let legacyState = MacThreadArtefacts(); legacyState.transport = peer
        let legacyTab = MacThreadArtefactTab(kind: "doc", id: docID); legacyState.tabs = [legacyTab]
        legacyState.observe(absent)
        try require(legacyTab.attached, "initial absent key preserves retained legacy tab before migration")
        await legacyState.refresh()
        try require(legacyState.members == [docMember] && legacyTab.attached, "nonempty verified legacy migration survives initial observation order")
        print("PASS_SHARED_MEMBERSHIP: independent stores; readable lazy labels; Doc/board/HTML; native duplicate/remove-last; background/pin; dirty detach recovery hold; explicit Save/re-add/resume; unreadable plain Chat; frozen request")
    }

}
#endif
