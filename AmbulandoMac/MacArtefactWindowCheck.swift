#if DEBUG
import AppKit
import SwiftUI
import WebKit
import AmbulandoCore

extension MacThreadRegression {
    private static func artefactWeb(_ view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { artefactWeb($0) }.first
    }
    private static func readyBoard(_ window: NSWindow, session: BoardSession) async throws -> WKWebView {
        for _ in 0..<100 {
            if session.state.status == .ready, let web = artefactWeb(window.contentView),
               (try? await web.evaluateJavaScript("document.querySelectorAll('.excalidraw canvas').length")) as? Int ?? 0 > 0 {
                return web
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(description: "Board did not render: \(session.state.status) \(session.state.error)")
    }
    private static func artefactCapture(_ window: NSWindow, model: AppModel, name: String) async throws {
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        try require(window.frame.width >= 640 && window.frame.height >= 480, "useful detached viewport before screenshot")
        guard let view = window.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(description: "Window capture") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "Window capture encoding") }
        print("SNAPSHOT_BASE64 \(name) \(png.base64EncodedString())")
    }
    private static func openArtefact(_ main: NSWindow, route: WorkRoute) async throws {
        main.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(200))
        try click(main, "artefact.window.open")
        for _ in 0..<50 {
            if MacArtefactSession.sessions.values.contains(where: { $0.route == route && $0.window != nil }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        for s in MacArtefactSession.sessions.values { print("WINDOW_DIAGNOSTIC route=\(s.route) active=\(s.active) detach=\(s.detached) busy=\(s.busy) transfer=\(s.transferring) allowed=\(s.canDetach) sources=\(s.sources.count) editors=\(s.editors.count) window=\(s.window != nil)") }
        throw Failure(description: "Open did not create owning window")
    }
    static func artefactWindowCheck(_ main: NSWindow, model: AppModel) async throws {
        try require(Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", "isolated synthetic app")
        guard let workspace = model.selectedWorkspace, let store = model.store, let fixture = model.fixture else { throw Failure(description: "fixture workspace") }
        model.mode = .deck
        model.openCanvases(workspace, force: true)
        var canvas: CanvasRecord?
        for _ in 0..<60 {
            canvas = try await store.reader.canvases(workspaceId: workspace.id).first { $0.title == "Launch board" }
            if canvas != nil { break }; await settle()
        }
        guard let canvas else { throw Failure(description: "sample canvas") }
        model.openCanvas(workspace, canvasId: canvas.id, force: true)
        var board: CanvasNaplet?
        for _ in 0..<60 {
            if let snap = try await store.reader.canvasSnapshot(workspaceId: workspace.id, canvasId: canvas.id) {
                board = try CanvasScene.parse(snap.bytes).naplets.first { if case .excalidraw = $0.content { return true }; return false }
            }
            if board != nil { break }; await settle()
        }
        guard let board, case .excalidraw(let reference) = board.content,
              let boardSession = model.boardSession(reference, title: board.title, in: workspace, canvasId: canvas.id) else { throw Failure(description: "sample whiteboard") }
        let boardRoute = WorkRoute.board(workspaceId: workspace.id, canvasId: canvas.id, napletId: board.id)
        model.mode = .docs; model.docsPath = [boardRoute]
        try await waitFor(main, "artefact.window.open", "whiteboard popout")
        _ = try await readyBoard(main, session: boardSession)
        try require(find(main, "section.bar") == nil, "global sections hidden in focused whiteboard")
        try await artefactCapture(main, model: model, name: "mac-focused-whiteboard")
        if let candidate = MacArtefactSession.sessions.values.first(where: { $0.route == boardRoute }) {
            print("ARTEFACT_OPEN active=\(candidate.active) busy=\(candidate.busy) canDetach=\(candidate.canDetach) editors=\(candidate.editors.count)")
        }
        try click(main, "artefact.window.open")
        var session: MacArtefactSession?
        for _ in 0..<80 {
            session = MacArtefactSession.sessions.values.first { $0.route == boardRoute && $0.window != nil }
            if session != nil { break }; await settle()
        }
        guard let session, let window = session.window else { throw Failure(description: "detached whiteboard window") }
        try await waitFor(main, "artefact.window.focus", "single owning window placeholder")
        try require(session.editors.isEmpty, "source editor released before detached editor owns record")
        let web = try await readyBoard(window, session: boardSession)
        try await artefactCapture(window, model: model, name: "mac-whiteboard-popout")
        var scene = try JSONSerialization.jsonObject(with: FixtureTower.sampleBoard()) as! [String: Any]
        var elements = scene["elements"] as! [[String: Any]]
        elements[0]["customData"] = ["fixtureWindowDraft": "retained"]
        elements[0]["version"] = 99
        scene["elements"] = elements
        let message = BoardController.message(["type": "change", "scene": scene])
        _ = try await web.callAsyncJavaScript("window.webkit.messageHandlers.board.postMessage(m)", arguments: ["m": message], contentWorld: .page)
        for _ in 0..<30 { if boardSession.state.dirty { break }; await settle() }
        try require(boardSession.state.dirty, "real window bridge accepts synthetic unsaved board input")
        try press(main, "artefact.window.focus"); await settle()
        try require(session.window === window, "repeat open focuses same window")
        let originalContext = model.context
        try click(main, "chevron.backward"); await settle()
        try require(find(main, "section.bar") != nil && model.context == originalContext, "Back restores sections and same list context")
        model.mode = .tasks; await settle()
        try require(window.isVisible && session.route == boardRoute, "main navigation independent of whiteboard window")
        let originalCheckpoint = session.checkpoint
        session.checkpoint = { false }
        window.performClose(nil); await settle()
        try require(session.window === window && window.isVisible, "failed/in-flight checkpoint vetoes native close")
        session.checkpoint = originalCheckpoint
        window.performClose(nil); await settle(); await settle()
        try require(session.window == nil && boardSession.state.dirty, "close preserves unsaved board draft")
        try require(fixture.tower.boards.currentBytes(reference.fileId) == FixtureTower.sampleBoard(), "close does not publish a new board revision")
        model.mode = .docs; model.docsPath = [boardRoute]
        try await waitFor(main, "artefact.window.open", "reopen whiteboard")
        try await openArtefact(main, route: boardRoute)
        guard let reopened = MacArtefactSession.sessions.values.first(where: { $0.route == boardRoute }), let reopenedWindow = reopened.window else { throw Failure(description: "reopened window") }
        _ = try await readyBoard(reopenedWindow, session: boardSession)
        try require(reopenedWindow !== window && boardSession.state.dirty, "closed record reopens with original dirty session")
        if let snap = try await store.reader.canvasSnapshot(workspaceId: workspace.id, canvasId: canvas.id),
           let item = try CanvasScene.parse(snap.bytes).naplets.first(where: { if case .html = $0.content { return true }; return false }) {
            let htmlRoute = WorkRoute.webContent(workspaceId: workspace.id, source: .htmlNaplet(canvasId: canvas.id, napletId: item.id, title: item.title))
            model.toolboxPath = [htmlRoute]; model.mode = .toolbox
            try await waitFor(main, "artefact.window.open", "HTML artefact entry")
            try await openArtefact(main, route: htmlRoute)
            guard let htmlSession = MacArtefactSession.sessions.values.first(where: { $0.route == htmlRoute }), let htmlWindow = htmlSession.window else { throw Failure(description: "HTML window") }
            try await waitFor(htmlWindow, "web.label", "sandboxed HTML content")
            try await artefactCapture(htmlWindow, model: model, name: "mac-html-popout")
            htmlWindow.performClose(nil); await settle(); await settle()
        } else { throw Failure(description: "sample HTML naplet") }
        let htmlSource = WebContentSource.installedNapplet(key: "project_register", title: "Synthetic registered napplet")
        let registered = WorkRoute.webContent(workspaceId: workspace.id, source: htmlSource)
        model.toolboxPath = [registered]; model.mode = .toolbox
        try await waitFor(main, "artefact.window.open", "registered napplet entry")
        try await openArtefact(main, route: registered)
        try require(MacArtefactSession.sessions.values.filter { $0.window != nil }.count == 2, "multiple records have separate windows")
        guard let registeredWindow = MacArtefactSession.sessions.values.first(where: { $0.route == registered })?.window else { throw Failure(description: "registered window") }
        // Opaque sandbox iframe text is not exposed by this host's in-process AX tree.
        // Verify the real loaded parent/sandbox source; the native snapshot also records its
        // rendered authorization status for review without weakening the frame boundary.
        var sandboxLoaded = false
        for _ in 0..<100 {
            if let web = artefactWeb(registeredWindow.contentView), !web.isLoading,
               (try? await web.evaluateJavaScript("(()=>{const f=document.getElementById('napplet');return f?.sandbox.value==='allow-scripts'&&f.srcdoc.includes('Sample Project Register')})()")) as? Bool == true { sandboxLoaded = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(sandboxLoaded, "registered napplet loaded in its original opaque sandbox")
        try await Task.sleep(for: .milliseconds(500))
        try await artefactCapture(registeredWindow, model: model, name: "mac-registered-napplet-popout")
        for current in Array(MacArtefactSession.sessions.values) { current.window?.performClose(nil) }
        await settle(); await settle()
        // Reuse the private File fixture, including its real native consent/sandbox path.
        if NappletTrustFixture.enabled {
            let route = WorkRoute.file(workspaceId: workspace.id, fileId: NappletTrustFixture.codeId)
            model.mode = .files; model.filesPath = [route]
            try await waitFor(main, "artefact.window.open", "private File HTML entry")
            try await openArtefact(main, route: route)
            guard let privateSession = MacArtefactSession.sessions.values.first(where: { $0.route == route }), let privateWindow = privateSession.window else { throw Failure(description: "private File window") }
            for _ in 0..<50 { if find(privateWindow, "napplet.approve") != nil || find(privateWindow, "napplet.forget") != nil { break }; await settle() }
            try require(find(privateWindow, "napplet.approve") != nil || find(privateWindow, "napplet.forget") != nil, "private File resolves consent or remembered trust")
            if find(privateWindow, "napplet.approve") != nil {
                privateWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                try press(privateWindow, "napplet.approve")
            }
            try await waitFor(privateWindow, "napplet.forget", "authorized private File napplet")
            try require(privateSession.requestClose != nil, "detached private host owns its native close protection")
            var privateReady = false
            for _ in 0..<100 {
                if let node = find(privateWindow, "napplet.forget"), let web = artefactWeb(privateWindow.contentView), !web.isLoading {
                    for name in ["isAccessibilityEnabled", "accessibilityEnabled"] {
                        let selector = NSSelectorFromString(name)
                        if node.responds(to: selector) {
                            typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
                            if unsafeBitCast(node.method(for: selector), to: Enabled.self)(node, selector),
                               (try? await web.evaluateJavaScript("Boolean(document.getElementById('napplet')?.srcdoc)")) as? Bool == true { privateReady = true }
                            break
                        }
                    }
                }
                if privateReady { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(privateReady, "private File bridge rendered and access verification completed")
            try await Task.sleep(for: .seconds(1))
            try await artefactCapture(privateWindow, model: model, name: "mac-file-napplet-popout")
            privateWindow.performClose(nil); await settle(); await settle()
        }
        _ = fixture // All records and mutations above belong to the synthetic fixture only.
        print("ARTEFACT_WINDOW_PASS focusToolbar sourceRelease repeatFocus backContext mainIndependent closeVeto reopen multipleRecords registeredEntry privateFileEntry")
    }
}
#endif
