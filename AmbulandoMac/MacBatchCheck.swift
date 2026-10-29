#if DEBUG
import AppKit
import AmbulandoCore
import WebKit

extension MacThreadRegression {
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
