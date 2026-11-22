#if DEBUG
import AppKit
import AmbulandoCore
import SwiftUI
import WebKit

extension MacThreadRegression {
    static func workspaceReportCheck(model: AppModel) async throws {
        try require(Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test" && WorkspaceReportFixture.enabled, "isolated synthetic report fixture")
        guard let workspace = model.selectedWorkspace, let sync = model.sync, let connection = model.connection else { throw Failure(description: "fixture context") }
        let pathCount = model.toolboxPath.count
        _ = model.handleAppLink(URL(string: "/flight-deck?workspaceid=\(workspace.id)&napplet=workspace-report")!)
        try require(model.toolboxPath.count == pathCount + 1 && model.toolboxPath.last == .webContent(workspaceId: workspace.id, source: .workspaceReport), "stable direct route")
        _ = model.handleAppLink(URL(string: "/flight-deck?workspaceid=00000000-0000-4000-8000-000000000099&napplet=workspace-report")!)
        try require(model.toolboxPath.count == pathCount + 1, "foreign workspace route refused")
        let files = try await sync.workspaceReports(connection, workspace)
        try require(files.count == 1 && files[0].id == NappletTrustFixture.codeId, "complete discovery reuses private code File")
        let code = try await sync.workspaceReportCode(connection, workspace, fileId: files[0].id)
        try require(code.sha256 == "9c0fba639750c304902db0351e0bba4a3e50400e250585819e697e56817ec42d" && Data(code.html.utf8).count == 16019, "exact frozen source")
        let receipt = try FileNappletTrustReceipt(connection: connection, workspace: workspace, codeFile: files[0].id, report: code)
        try FileNappletTrustStore.local.forget(receipt)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        func mount() async {
            window.contentView = NSHostingView(rootView: WorkspaceReportFileView(file: files[0], workspace: workspace).environment(model).environment(\.scenePhase, .active).frame(width: 800, height: 820).id(UUID()))
            window.makeKeyAndOrderFront(nil); await settle()
        }
        func wait(_ id: String) async throws {
            for _ in 0..<150 { if find(window, id) != nil { return }; try await Task.sleep(for: .milliseconds(40)) }
            dump(window); throw Failure(description: "Missing report control " + id)
        }
        await mount(); try await wait("report.approve")
        do { try press(window, "report.approve") } catch { await settle(); if find(window, "report.approve") != nil { try click(window, "report.approve") } }
        try await wait("report.forget"); await settle()
        try require(FileNappletTrustStore.local.contains(receipt), "device-only approval persisted")
        try press(window, "report.reload"); try await wait("report.forget")
        try require(find(window, "report.approve") == nil, "reload retains approval")
        await mount(); try await wait("report.forget")
        try require(find(window, "report.approve") == nil, "recreated view retains approval")
        // Exercise the real opaque frame with test-only DOM instrumentation, never changing bundled bytes.
        var reads = 0
        let host = WorkspaceReportHost(authorize: { try await sync.authorizeWorkspaceReport(connection, workspace, fileId: files[0].id, code: code) }, read: { range in
            reads += 1
            return try await sync.readWorkspaceReport(connection, workspace, fileId: files[0].id, code: code, range: range)
        })
        defer { host.destroy() }
        host.open(code)
        let page = host.page!, web = page.webView!
        let probe = """
        if(window.top!==window){
          try{window.webkit?.messageHandlers?.napplet?.postMessage({type:'wingman-napplet-data',version:1,session:window.nappletSession,requestId:'raw_subframe',operation:'read',binding:'report',range:'30d'});}catch{}
          parent.postMessage({type:'wingman-napplet-data',version:1,session:'wrong',requestId:'wrong_nonce',operation:'read',binding:'report',range:'30d'},'*');
          parent.postMessage({type:'wingman-napplet-data',version:1,session:window.nappletSession,requestId:'write_probe',operation:'save',binding:'report',range:'30d'},'*');
          addEventListener('message',e=>{if(e.data?.probeRange){const r=document.getElementById('range');r.value=e.data.probeRange;r.dispatchEvent(new Event('change'));}});
          addEventListener('message',e=>{if(e.data?.probeWidth)parent.postMessage({reportProbe:{width:innerWidth,overflow:document.documentElement.scrollWidth>document.documentElement.clientWidth,loaded:!document.getElementById('report').hidden,messages:document.getElementById('messages').textContent}},'*');});
          (async()=>{for(let n=0;n<400;n++){if(!document.getElementById('report')?.hidden&&document.getElementById('messages')?.textContent==='123'){parent.postMessage({reportLoaded:true},'*');return;}await new Promise(r=>setTimeout(r,25));}})();
        }else{addEventListener('message',e=>{if(e.data?.reportProbe)window.reportProbe=e.data.reportProbe;if(e.data?.reportLoaded)window.reportLoaded=true;});}
        """
        web.configuration.userContentController.addUserScript(WKUserScript(source: probe, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        window.contentView = web; window.setContentSize(NSSize(width: 800, height: 820)); web.frame = window.contentView!.bounds
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("window.reportLoaded===true")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(reads == 1 && host.failure == nil, "canonical fixture read through native transport")
        for range in ["7d", "90d", "all", "30d"] {
            let target = reads + 1
            _ = try await web.evaluateJavaScript("document.getElementById('napplet').contentWindow.postMessage({probeRange:'\(range)'},'*');true")
            for _ in 0..<200 {
                if reads == target && !host.pending { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try require(reads == target && host.failure == nil, "canonical native range " + range)
        }
        for width in [320, 390, 430, 1000] {
            window.setContentSize(NSSize(width: width, height: 820)); web.frame = window.contentView!.bounds
            await settle()
            _ = try await web.evaluateJavaScript("window.reportProbe=null;document.getElementById('napplet').contentWindow.postMessage({probeWidth:true},'*');true")
            try await Task.sleep(for: .milliseconds(100))
            let result = try await web.evaluateJavaScript("window.reportProbe") as? [String: Any]
            try require(result?["loaded"] as? Bool == true && result?["overflow"] as? Bool == false && result?["messages"] as? String == "123", "loaded report without overflow at \(width): \(String(describing: result))")
            let image = try await web.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/tmp/docs/handoffs/workspace-report-mac-\(width).png"))
            }
        }
        // Raw native injection, wrong nonce, save and duplicate ID never reach the report reader.
        let raw: [String: Any] = ["type": "wingman-napplet-data", "version": 1, "session": page.session, "requestId": "raw", "operation": "read", "binding": "report", "range": "30d"]
        _ = try await web.evaluateJavaScript("window.webkit.messageHandlers.napplet.postMessage(\(NappletPage.json(raw)));true")
        for _ in 0..<100 where host.pending { try await Task.sleep(for: .milliseconds(20)) }
        // Main-frame bypass can reach native only through this test-owned evaluation; the real frame cannot access parent objects.
        // Nonce/parser/replay protections are asserted independently in core and opaque frame forwarding below.
        let before = reads
        _ = try await web.evaluateJavaScript("window.webkit.messageHandlers.napplet.postMessage(\(NappletPage.json(raw)));true")
        try await Task.sleep(for: .milliseconds(100)); try require(reads == before, "duplicate IDs rejected")
        model.fixture?.tower.trustNapplet.change("denied")
        host.reauthorize()
        for _ in 0..<100 where host.page != nil { try await Task.sleep(for: .milliseconds(30)) }
        try require(host.page == nil && host.failure != nil, "permission loss destroys frame and aggregates")
        print("WORKSPACE_REPORT_NATIVE_PASS exactBundle consentReloadReopen canonicalRead widths3203904301000 replay denied")
    }
}
#endif
