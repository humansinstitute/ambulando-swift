#if DEBUG
import AppKit
import AmbulandoCore
import WebKit

extension MacThreadRegression {
    /// Focused UI check: sends pointer events through AppKit; never substitutes model.movePin for a drag.
    static func pinCardCheck(_ window: NSWindow, model: AppModel) async throws {
        model.mode = .deck
        window.setFrame(NSRect(x: 20, y: 20, width: 1400, height: 900), display: true)
        await settle()
        let ids = model.pins.value.items.map { "deck.pinned.\($0.title ?? $0.pin.resourceId)" }
        try require(ids.count >= 2, "two fixture pins")
        try await waitFor(window, ids[0], "pinned main action")
        try snapshot(window, model: model, name: "pin-clean-mac-desktop")
        func point(_ id: String, fraction: CGFloat) throws -> NSPoint {
            guard let node = find(window, id) else { throw Failure(description: "Missing pin " + id) }
            let rect = frame(of: node)
            return window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.maxY - rect.height * fraction))
        }
        func pointerDrag(_ source: String, _ target: String, fraction: CGFloat) async throws {
            let start = try point(source, fraction: 0.5), end = try point(target, fraction: fraction)
            let screenHeight = NSScreen.screens.first!.frame.height
            let screenStart = window.convertPoint(toScreen: start), screenEnd = window.convertPoint(toScreen: end)
            print("PIN_POINTER source=\(start) target=\(end) hit=\(String(describing: window.contentView?.hitTest(window.contentView!.convert(start, from: nil)))))")
            // Address the calling app only; no Accessibility permission or other app identity is borrowed.
            DispatchQueue.global().async {
                for step in 0...30 {
                    let t = Double(step) / 30
                    let point = CGPoint(x: screenStart.x + (screenEnd.x - screenStart.x) * t,
                        y: screenHeight - (screenStart.y + (screenEnd.y - screenStart.y) * t))
                    CGWarpMouseCursorPosition(point)
                    let kind: CGEventType = step == 0 ? .leftMouseDown : (step == 30 ? .leftMouseUp : .leftMouseDragged)
                    CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?.postToPid(getpid())
                    Thread.sleep(forTimeInterval: step == 0 ? 0.8 : 0.04)
                }
            }
            try? await Task.sleep(for: .seconds(3))
            await settle(); await settle()
        }
        window.setFrame(NSRect(x: 20, y: 20, width: 900, height: 1200), display: true)
        await settle()
        try snapshot(window, model: model, name: "pin-clean-mac-narrow")
        window.setFrame(NSRect(x: 20, y: 20, width: 1400, height: 900), display: true)
        await settle()
        let original = model.pins.value.items.map(\.id)
        try await pointerDrag(ids[1], ids[0], fraction: 0.15)
        try snapshot(window, model: model, name: "pin-mac-after-pointer-before")
        try require(model.mode == .deck, "pointer drag does not open")
        try require(model.pins.value.items.map(\.id) == [original[1], original[0]], "actual pointer moved last before first")
        try await pointerDrag(ids[1], ids[0], fraction: 0.85)
        try require(model.pins.value.items.map(\.id) == original, "actual pointer lower-half drop moves to end")
        guard let store = model.store, let connection = model.connection, let workspace = model.selectedWorkspace else { throw Failure(description: "Fixture store") }
        let saved = try await store.reader.pinnedItems(connectionId: connection.id, workspaceId: workspace.id)
        try require(saved.map(\.id) == original, "drag order durable")
        window.setFrame(NSRect(x: 20, y: 20, width: 900, height: 1200), display: true)
        await settle()
        try snapshot(window, model: model, name: "pin-clean-mac-narrow")
        window.setFrame(NSRect(x: 20, y: 20, width: 1400, height: 900), display: true)
        await settle()
        try sendClick(window, point: point(ids[0], fraction: 0.5)); await settle()
        try require(model.mode != .deck, "short pointer click opens channel")
    }

    static func batchCheck(_ window: NSWindow, model: AppModel) async throws {
        // The actual native composer is hit through the real AppKit window, including lower blank padding.
        model.mode = .chat
        model.selectContext(WorkContext(scopeId: FixtureTower.scopeAmbulando, channelId: FixtureTower.generalChannel))
        try await waitFor(window, "composer.field", "channel composer")
        let editor = try textView(window)
        let browserOnly = ProcessInfo.processInfo.arguments.contains("-AmbulandoMacBatchBrowserOnly")
        if !browserOnly {
        window.makeFirstResponder(nil); await settle()
        let field = editor.convert(editor.bounds, to: nil)
        print("COMPOSER_GEOMETRY field=\(field) bounds=\(editor.bounds) scroll=\(String(describing: editor.enclosingScrollView?.frame))")
        try snapshot(window, model: model, name: "batch-before-composer")
        let box = NSRect(x: field.minX - 12, y: field.minY - 8, width: field.width + 24, height: field.height + 16)
        for point in [NSPoint(x: box.maxX - 4, y: box.midY), NSPoint(x: box.midX, y: box.minY + 3), NSPoint(x: box.minX + 4, y: box.maxY - 3)] {
            window.makeFirstResponder(nil); await settle()
            print("COMPOSER_HIT point=\(point) hit=\(String(describing: window.contentView?.hitTest(window.contentView!.convert(point, from: nil))))")
            try sendClick(window, point: point); await settle()
            try require(window.firstResponder === editor, "blank composer focuses at \(point)")
        }
        try postKey(window, key: "x", code: 7, modifiers: []); await settle()
        try require(editor.string == "x", "keyboard after blank click types into existing draft")
        try press(window, "composer.hideKeyboard"); await settle()
        try require(editor.string == "x", "hide keyboard preserves draft")
        try press(window, "composer.mention"); await settle()
        try require(editor.string.contains("@"), "mention action remains independent")
        try snapshot(window, model: model, name: "batch-composer")

        }
        guard let workspace = model.selectedWorkspace, let store = model.store, let connection = model.connection else { throw Failure(description: "No fixture workspace") }
        for _ in 0..<30 {
            if model.pins.value.items.count >= 2 { break }; await settle()
        }
        let pins = model.pins.value.items
        try require(pins.count >= 2, "mixed pins loaded")
        model.movePin(pins.last!, before: pins.first!, in: workspace)
        for _ in 0..<40 {
            if model.pins.value.items.first?.id == pins.last!.id { break }; await settle()
        }
        try require(model.pins.value.items.first?.id == pins.last!.id, "move travels queue, signed fixture API and live store")
        let persisted = try await store.reader.pinnedItems(connectionId: connection.id, workspaceId: workspace.id)
        try require(persisted.first?.id == pins.last!.id, "order persists in local store")

        model.browser.open(URL(string: "https://browser.sample.invalid/")!)
        await settle()
        guard let tab = model.browser.selected else { throw Failure(description: "No browser tab") }
        for _ in 0..<50 {
            if tab.origin != nil { break }; await settle()
        }
        // Drive the real WebKit file input and cancel its native open panel.
        let firstPicker = Task { _ = try await tab.webView.evaluateJavaScript("document.getElementById('upload').click()") }
        var panel: NSOpenPanel?
        for _ in 0..<40 {
            panel = NSApp.windows.compactMap { $0 as? NSOpenPanel }.first
            if panel != nil { break }; await settle()
        }
        try require(panel != nil, "file input opens actual native picker")
        panel?.cancel(nil); _ = try await firstPicker.value; await settle()
        print("BROWSER_PICKER_CANCEL_PASS"); fflush(stdout)
        let cancelled = try await tab.webView.evaluateJavaScript("document.getElementById('upload').files.length") as? Int
        try require(cancelled == 0, "picker cancellation returns no files")
        print("BROWSER_UPLOAD_LIMITATION native picker opens/cancels; selecting file in remote OpenPanel service requires manual check"); fflush(stdout)

        for scheme in ["data", "blob"] {
            model.browser.exportingDownload = false; model.browser.downloadFile = nil
            // A real DOM link click exercises WKNavigationAction -> WKDownload -> temporary file bytes.
            let script = scheme == "data" ? "const a=document.createElement('a');a.href='data:text/plain;base64,YmF0Y2gtZmlsZQ==';a.download='batch-data.txt';document.body.append(a);a.click();" : "const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['batch-file'],{type:'text/plain'}));a.download='batch-blob.txt';document.body.append(a);a.click();"
            _ = try await tab.webView.evaluateJavaScript("(()=>{\(script)})()")
            for _ in 0..<50 {
                if model.browser.downloadFile != nil || tab.refusal != nil { break }; await settle()
            }
            try require(model.browser.downloadFile?.bytes == Data("batch-file".utf8), "actual \(scheme) download bytes; refusal=\(tab.refusal ?? "none")")
            print("BROWSER_DOWNLOAD_PASS scheme=\(scheme) filename=\(model.browser.downloadFilename)")
            model.browser.exportingDownload = false; model.browser.downloadFile = nil
        }
        model.browser.presented = false
        await settle()
        if !browserOnly { try require(editor.string.contains("x"), "browser return preserves draft") }
    }
}
#endif
