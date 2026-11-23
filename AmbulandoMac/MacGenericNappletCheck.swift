#if DEBUG
import AppKit
import AmbulandoCore
import SwiftUI
import WebKit

private actor GenericNativeGate {
    private var released = false
    private var continuation: CheckedContinuation<Void,Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

extension MacThreadRegression {
    static func genericAuthorizationQueueCheck(_ code:GenericNappletCode) async throws {
        for mode in 0..<4 {
            let gate = GenericNativeGate(); var reads = 0
            let host = GenericNappletHost(code:code,canWrite:true,authorize:{
                await gate.wait()
                if mode == 1 { throw FileNappletError.unavailable }
                return mode != 3
            },read:{ _ in reads += 1; return FileNappletData(bytes:Data("{}".utf8),versionId:code.versionId,canWrite:true) },save:{ _,_ in throw FileNappletError.invalid })
            let page = NappletPage(html:"",binding:code.binding,genericReceive:{ _ in false }); host.page = page
            func request(_ id:String,_ operation:String = "read") throws -> GenericNappletRequest {
                var o:[String:Any] = ["type":"wingman-napplet-data","version":2,"session":page.session,"requestId":id,"operation":operation,"binding":code.binding.name]
                if operation == "save" { o["baseVersionId"] = code.versionId; o["value"] = [:] as [String:Any] }
                return try GenericNappletRequest.parse(JSONSerialization.data(withJSONObject:o),session:page.session,binding:code.binding)
            }
            host.reauthorize()
            try require(host.authorizing && !host.busy,"authorization is separate from operation busy")
            try require(host.receive(request("first")),"one initial valid read admitted during delayed authority check")
            try require(!host.receive(request("second")),"only one read queued")
            try require(!host.receive(request("write","save")),"writes are never queued during authority checks")
            if mode == 2 { host.destroy() }
            await gate.release()
            for _ in 0..<200 { if !host.authorizing && !host.busy { break }; try await Task.sleep(for:.milliseconds(1)) }
            for _ in 0..<10 { await Task.yield() }
            try require(reads == (mode == 0 ? 1 : 0),"queued read requires successful unchanged grant and live context")
            if mode != 0 { try require(host.page == nil,"denial/changed grant/context destroys queued run") }
            host.destroy()
        }
        let gate = GenericNativeGate(); var reads = 0
        let host = GenericNappletHost(code:code,canWrite:true,authorize:{ true },read:{ _ in
            reads += 1; await gate.wait(); return FileNappletData(bytes:Data("{}".utf8),versionId:code.versionId,canWrite:true)
        },save:{ _,_ in throw FileNappletError.invalid })
        let page = NappletPage(html:"",binding:code.binding,genericReceive:{ _ in false }); host.page = page
        let data:[String:Any] = ["type":"wingman-napplet-data","version":2,"session":page.session,"requestId":"operation","operation":"read","binding":code.binding.name]
        let request = try GenericNappletRequest.parse(JSONSerialization.data(withJSONObject:data),session:page.session,binding:code.binding)
        try require(host.receive(request) && host.busy,"operation starts busy")
        try require(!host.receive(request),"operation-busy requests ignored without consuming IDs")
        await gate.release()
        for _ in 0..<200 where host.busy { try await Task.sleep(for:.milliseconds(1)) }
        try require(reads == 1,"one bridge operation in flight")
        host.destroy()
        print("GENERIC_AUTH_QUEUE_PASS delayedCheck oneFirstRead noWrites normalBusyIgnored denied changedGrant contextDestroyed")
    }

    /// Exercises production native views/bridge with synthetic signed File transport, never a human backend.
    static func genericNappletCheck(model:AppModel) async throws {
        try require(Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test" && GenericNappletFixture.enabled,"isolated synthetic scenario")
        guard let workspace = model.selectedWorkspace, let sync = model.sync, let c = model.connection, let store = model.store, let fixture = model.fixture else { throw Failure(description:"fixture context") }
        let scenario = try fixture.tower.genericNapplet.scenario(), rows = scenario["files"] as! [[String:Any]]
        let codeIDs = rows.filter { $0["content_type"] as? String == "text/html" }.map { $0["id"] as! String }
        try require(codeIDs.count == 2,"two arbitrary supplied apps after build")
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:820),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; defer { window.orderOut(nil) }
        func mount<V:View>(_ view:V) async {
            window.contentView = NSHostingView(rootView:view.environment(model).environment(\.scenePhase,.active).frame(width:800,height:820).id(UUID()))
            window.makeKeyAndOrderFront(nil); await settle()
        }
        func wait(_ id:String) async throws {
            for _ in 0..<200 { if find(window,id) != nil { return }; try await Task.sleep(for:.milliseconds(30)) }
            dump(window); throw Failure(description:"Missing generic control " + id)
        }
        func web(_ view:NSView?) -> WKWebView? {
            if let view = view as? WKWebView { return view }
            for child in view?.subviews ?? [] { if let found = web(child) { return found } }; return nil
        }
        var codes:[GenericNappletCode] = [], files:[FileRecord] = []
        for id in codeIDs {
            let file = try await sync.genericNappletFile(c,workspace,fileId:id), code = try await sync.genericNappletCode(c,workspace,fileId:id)
            if files.isEmpty { try await genericAuthorizationQueueCheck(code) }
            files.append(file); codes.append(code)
            await mount(AddGenericNappletView(workspace:workspace,store:store))
            try await wait("generic.file-link"); try click(window,"generic.file-link")
            guard let editor = window.firstResponder as? NSTextView else { throw Failure(description:"native File link editor") }
            editor.insertText(c.origin + "/flight-deck?workspaceid=\(workspace.id)&nappletFile=\(id)",replacementRange:editor.selectedRange())
            try press(window,"generic.verify"); try await wait("generic.install"); try press(window,"generic.install")
            var pinned = false
            for _ in 0..<200 {
                pinned = (try await store.reader.pin(connectionId:c.id,workspaceId:workspace.id,type:.file,resourceId:id))?.pinned == true
                if pinned { break }; try await Task.sleep(for:.milliseconds(30))
            }
            try require(pinned,"installation acknowledged through signed personal File pin")
            await mount(GenericAppsSection(workspace:workspace,store:store)); try await wait("generic.app.\(id)")
            let before = model.toolboxPath.count
            _ = model.handleAppLink(URL(string:"/flight-deck?workspaceid=\(workspace.id)&nappletFile=\(id)")!)
            try require(model.toolboxPath.count == before + 1 && model.toolboxPath.last == .file(workspaceId:workspace.id,fileId:id),"stable arbitrary File app route")
            await mount(GenericNappletFileView(file:file,workspace:workspace))
            try await wait("generic.approve"); try press(window,"generic.approve"); try await wait("generic.menu")
            await settle()
            try require(web(window.contentView) != nil,"real opaque native WK frame")
            await mount(GenericNappletFileView(file:file,workspace:workspace)); try await wait("generic.menu")
            try require(find(window,"generic.approve") == nil,"unchanged reopened approval remembered")
        }
        for (index,code) in codes.enumerated() {
            let id = codeIDs[index]
            var reads = 0, saves = 0
            let h = GenericNappletHost(code:code,canWrite:true,authorize:{ try await sync.authorizeGenericNapplet(c,workspace,fileId:id,code:code) },read:{ _ in
                reads += 1; return try await sync.readGenericJSON(c,workspace,fileId:id,code:code)
            },save:{ base,bytes in
                saves += 1; return try await sync.saveGenericJSON(c,workspace,fileId:id,code:code,base:base,bytes:bytes)
            })
            h.open(); defer { h.destroy() }
            guard let p = h.page, let wk = p.webView else { throw Failure(description:"generic host page") }
            window.contentView = wk
            for _ in 0..<200 { if reads == 1 && !h.busy { break }; try await Task.sleep(for:.milliseconds(30)) }
            try require(reads == 1 && h.failure == nil,"unknown app read through production sync and opaque bridge")
            _ = try await wk.evaluateJavaScript("addEventListener('message',e=>{if(e.data?.probe)window.genericProbe=e.data.probe});true")
            func command(_ command:String) async throws {
                _ = try await wk.evaluateJavaScript("document.getElementById('napplet').contentWindow.postMessage({command:'\(command)'},'*');true")
                try await Task.sleep(for:.milliseconds(250))
                for _ in 0..<200 where h.busy || h.authorizing { try await Task.sleep(for:.milliseconds(20)) }
            }
            try await command("save")
            try require(saves == 1 && h.failure == nil,"unknown app whole-object CAS save")
            let saved = try await sync.readGenericJSON(c,workspace,fileId:id,code:code)
            let expected = try GenericJSON.canonical(["answered":false,"zero":0,"unanswered":NSNull(),"entry":"synthetic","marker":code.binding.appId])
            try require(saved.bytes == expected,"only valid dense JSON reaches save; sparse/huge-sparse/negative-zero messages rejected")
            try require(saved.versionId != (rows.first { $0["id"] as? String == code.binding.resourceId }?["head"] as? String),"save acknowledged new data version")
            try await command("dirty"); try require(h.dirty,"dirty notification")
            let session = p.session; h.reauthorize()
            for _ in 0..<200 where h.busy || h.authorizing { try await Task.sleep(for:.milliseconds(20)) }
            try require(h.dirty && h.page?.session == session,"healthy authority check preserves draft DOM")
            let before = reads
            try await command("replay")
            try require(reads == before,"replayed initial request ignored")
            try await command("probe")
            let probe = try await wk.evaluateJavaScript("window.genericProbe") as? [String:Any]
            try require(probe?["loaded"] as? Bool == true && probe?["overflow"] as? Bool == false,"loaded unknown app UI")
            for width in [320,390,430,1000] {
                window.setContentSize(NSSize(width:width,height:820)); wk.frame = window.contentView!.bounds
                try await command("probe")
                let layout = try await wk.evaluateJavaScript("window.genericProbe") as? [String:Any]
                try require(layout?["overflow"] as? Bool == false,"responsive arbitrary bundle at \(width)")
                if index == 0 {
                    let image = try await wk.takeSnapshot(configuration:nil)
                    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff) { try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:FileManager.default.currentDirectoryPath + "/tmp/docs/handoffs/generic-mac-\(width).png")) }
                }
            }
            h.destroy()
            // Same binary, new HTML head of the SAME File. Data bytes/version/history stay untouched.
            if index == 0 {
                let beforeUpdate = try fixture.tower.genericNapplet.scenario(), beforeFiles = beforeUpdate["files"] as! [[String:Any]]
                var changed = beforeUpdate, updatedFiles = beforeFiles
                let at = updatedFiles.firstIndex { $0["id"] as? String == id }!
                var updated = updatedFiles[at], history = updated["history"] as! [String:String]
                let text = (updated["text"] as! String).replacingOccurrences(of:"Initial UI",with:"Updated UI"), head = UUID().uuidString.lowercased()
                history[head] = text; updated["history"] = history; updated["head"] = head; updated["text"] = text; updatedFiles[at] = updated; changed["files"] = updatedFiles
                try JSONSerialization.data(withJSONObject:changed,options:[.sortedKeys]).write(to:GenericNappletFixture.scenarioURL!,options:.atomic)
                let newCode = try await sync.genericNappletCode(c,workspace,fileId:id)
                try require(newCode.sha256 != code.sha256 && newCode.binding == code.binding,"new code version and digest, same resource")
                await mount(GenericNappletFileView(file:files[index],workspace:workspace)); try await wait("generic.approve")
                try press(window,"generic.approve"); try await wait("generic.menu")
                await mount(GenericNappletFileView(file:files[index],workspace:workspace)); try await wait("generic.menu")
                try require(find(window,"generic.approve") == nil,"changed code prompts once, unchanged reopen remembered")
                if let observed = web(window.contentView) {
                    let state = try? await observed.evaluateJavaScript("JSON.stringify({ready:document.readyState,frames:document.querySelectorAll('iframe').length,htmlLength:document.documentElement.outerHTML.length})")
                    print("UPDATED_SWIFTUI_VIEW url=\(observed.url?.absoluteString ?? "nil") bounds=\(observed.bounds) state=\(String(describing:state))")
                    if let image = try? await observed.takeSnapshot(configuration:nil), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff) {
                        try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:FileManager.default.currentDirectoryPath + "/tmp/docs/handoffs/generic-mac-updated-swiftui.png"))
                    }
                }
                // Consent and remembered reopen above exercise the SwiftUI view. Observe the updated
                // HTML directly in the production host after its initial data read completes.
                let rendered = GenericNappletHost(code:newCode,canWrite:true,authorize:{ try await sync.authorizeGenericNapplet(c,workspace,fileId:id,code:newCode) },read:{ _ in try await sync.readGenericJSON(c,workspace,fileId:id,code:newCode) },save:{ base,bytes in try await sync.saveGenericJSON(c,workspace,fileId:id,code:newCode,base:base,bytes:bytes) })
                rendered.open()
                guard let renderedPage = rendered.page, let updatedWeb = renderedPage.webView else { throw Failure(description:"updated native frame") }
                window.contentView = updatedWeb
                for _ in 0..<200 { if renderedPage.ready && !rendered.busy { break }; try await Task.sleep(for:.milliseconds(30)) }
                _ = try await updatedWeb.evaluateJavaScript("addEventListener('message',e=>{if(e.data?.probe)window.updatedProbe=e.data.probe});true")
                var changedUI = false
                for _ in 0..<200 {
                    _ = try await updatedWeb.evaluateJavaScript("document.getElementById('napplet').contentWindow.postMessage({command:'probe'},'*');true")
                    if let probe = try? await updatedWeb.evaluateJavaScript("window.updatedProbe") as? [String:Any], probe["ui"] as? String == "Updated UI", probe["loaded"] as? Bool == true { changedUI = true; break }
                    try await Task.sleep(for:.milliseconds(20))
                }
                if !changedUI { print("UPDATED_UI_PROBE failure=\(String(describing:rendered.failure)) ready=\(renderedPage.ready) busy=\(rendered.busy)") }
                try require(changedUI,"new same-File UI visibly rendered after reapproval")
                let renderedImage = try await updatedWeb.takeSnapshot(configuration:nil)
                if let tiff = renderedImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff) {
                    try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:FileManager.default.currentDirectoryPath + "/tmp/docs/handoffs/generic-mac-updated-loaded.png"))
                }
                rendered.destroy()
                let after = try fixture.tower.genericNapplet.scenario()["files"] as! [[String:Any]]
                let oldData = beforeFiles.filter { $0["content_type"] as? String == "application/json" }, newData = after.filter { $0["content_type"] as? String == "application/json" }
                try require(try JSONSerialization.data(withJSONObject:oldData,options:[.sortedKeys]) == JSONSerialization.data(withJSONObject:newData,options:[.sortedKeys]),"UI update preserves both data Files, bytes and histories")
            }
        }
        model.setPinned(false,type:.file,id:codeIDs[0],in:workspace)
        for _ in 0..<200 {
            if (try await store.reader.pin(connectionId:c.id,workspaceId:workspace.id,type:.file,resourceId:codeIDs[0]))?.pinned == false { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        let removedPin = try await store.reader.pin(connectionId:c.id,workspaceId:workspace.id,type:.file,resourceId:codeIDs[0])
        try require(removedPin?.pinned == false,"uninstall acknowledged by NStack pin transport")
        let remaining = try fixture.tower.genericNapplet.scenario()["files"] as! [[String:Any]]
        try require(remaining.count == rows.count,"uninstall unpins without deletion")
        let finalCode = try await sync.genericNappletCode(c,workspace,fileId:codeIDs[1])
        let deniedHost = GenericNappletHost(code:finalCode,canWrite:true,authorize:{ try await sync.authorizeGenericNapplet(c,workspace,fileId:codeIDs[1],code:finalCode) },read:{ _ in try await sync.readGenericJSON(c,workspace,fileId:codeIDs[1],code:finalCode) },save:{ base,bytes in try await sync.saveGenericJSON(c,workspace,fileId:codeIDs[1],code:finalCode,base:base,bytes:bytes) })
        deniedHost.open()
        try await Task.sleep(for:.milliseconds(300))
        var deniedScenario = try fixture.tower.genericNapplet.scenario(); deniedScenario["denied"] = true
        try JSONSerialization.data(withJSONObject:deniedScenario).write(to:GenericNappletFixture.scenarioURL!,options:.atomic)
        deniedHost.reauthorize()
        for _ in 0..<200 where deniedHost.page != nil { try await Task.sleep(for:.milliseconds(20)) }
        try require(deniedHost.page == nil,"permission loss destroys opaque frame and private values")
        deniedScenario["denied"] = false; try JSONSerialization.data(withJSONObject:deniedScenario).write(to:GenericNappletFixture.scenarioURL!,options:.atomic)
        print("GENERIC_NATIVE_PASS syntheticSignedTransport twoUnknownApps installPin apps directRoute consent save reopen sameFileUpdate remembered unchangedBinary isolatedData draftDOM replay widths3203904301000 unpinNoDelete")
    }
}
#endif

#if DEBUG
extension MacThreadRegression {
    /// Candidate HTML and golden data are supplied externally; this never reads a live workspace.
    static func storageReportCheck() async throws {
        try require(Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", "isolated test app")
        let args = ProcessInfo.processInfo.arguments
        func argument(_ flag: String) throws -> String {
            guard let at = args.firstIndex(of: flag), args.indices.contains(at + 1) else { throw Failure(description: "missing " + flag) }; return args[at + 1]
        }
        let candidate = try String(contentsOfFile: argument("-StorageCandidate"), encoding: .utf8)
        let golden = try GenericJSON.decode(Data(contentsOf: URL(fileURLWithPath: argument("-StorageGolden"))))
        let errors = try GenericJSON.decode(Data(contentsOf: URL(fileURLWithPath: argument("-StorageErrors"))))
        let forbidden = errors["forbidden"] as! [String: Any]
        let aggregate = golden["value"] as! [String: Any]
        let probe = "<script>addEventListener('message',e=>{if(e.data?.status==='error')window.storageError=e.data;if(e.data?.storageRefresh)document.getElementById('refresh').click();if(e.data?.storageProbe)parent.postMessage({storageProbe:{error:window.storageError,text:document.body.innerText,overflow:document.documentElement.scrollWidth>innerWidth+1,metrics:[...document.querySelectorAll('.storage-metrics article')].map(x=>({label:x.querySelector('p').textContent,value:x.querySelector('strong').textContent}))}},'*')})</script>"
        let html = candidate + probe
        guard let binding = try GenericNappletBinding.parse(html: html, metadata: GenericJSON.canonical(golden["metadata"]!)) else { throw Failure(description: "candidate binding") }
        try require(binding.includesWorkspaceStorage, "candidate uses aggregate capability 2")
        let code = GenericNappletCode(html: html, binding: binding, versionId: UUID().uuidString.lowercased(), sha256: SHA256Hex.of(Data(html.utf8)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.orderOut(nil) }
        var revoked = false, reads = 0
        for reopen in 0..<2 {
            let host = GenericNappletHost(code: code, canWrite: false, authorize: { false }, read: { range in
                reads += 1
                if revoked { throw FileNappletError.forbidden }
                var report = aggregate; let range = range ?? "30d"; report["range"] = range
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let end = formatter.date(from: report["as_of"] as! String)!
                report["from"] = ["7d": 7, "30d": 30, "90d": 90][range].map { formatter.string(from: end.addingTimeInterval(-Double($0) * 86400)) as Any } ?? NSNull()
                return FileNappletData(bytes: try GenericJSON.canonical(report), versionId: "", canWrite: false)
            }, save: { _, _ in throw FileNappletError.invalid })
            host.open(); defer { host.destroy() }
            guard let page = host.page, let wk = page.webView else { throw Failure(description: "storage WebKit") }
            window.contentView = wk; window.makeKeyAndOrderFront(nil)
            for _ in 0..<200 { if reads > reopen && !host.busy { break }; try await Task.sleep(for: .milliseconds(30)) }
            try require(host.failure == nil && reads > reopen, "candidate read on fresh reopen")
            _ = try await wk.evaluateJavaScript("addEventListener('message',e=>{if(e.data?.storageProbe)window.storageProbe=e.data.storageProbe});true")
            for width in [320, 390, 800] {
                window.setContentSize(NSSize(width: width, height: 820)); wk.frame = window.contentView!.bounds
                var state: [String: Any]?
                for _ in 0..<100 {
                    _ = try await wk.evaluateJavaScript("window.storageProbe=null;document.getElementById('napplet').contentWindow.postMessage({storageProbe:true},'*');true")
                    try await Task.sleep(for: .milliseconds(40))
                    state = try await wk.evaluateJavaScript("window.storageProbe") as? [String: Any]
                    if (state?["metrics"] as? [[String: Any]])?.isEmpty == false { break }
                }
                let metrics = state?["metrics"] as? [[String: Any]] ?? []
                try require(state?["overflow"] as? Bool == false, "storage responsive at \(width)")
                for label in ["Physical database bytes", "Provider-measured bytes"] {
                    try require(metrics.first { $0["label"] as? String == label }?["value"] as? String == "Unavailable", "unmeasured value never zero")
                }
                try require((state?["text"] as? String)?.contains("subset") == true, "subset labeling")
            }
            if reopen == 1 {
                revoked = true
                _ = try await wk.evaluateJavaScript("document.getElementById('napplet').contentWindow.postMessage({storageRefresh:true},'*');true")
                var denied = false
                for _ in 0..<100 {
                    _ = try await wk.evaluateJavaScript("document.getElementById('napplet').contentWindow.postMessage({storageProbe:true},'*');true")
                    try await Task.sleep(for: .milliseconds(40))
                    let state = try await wk.evaluateJavaScript("window.storageProbe") as? [String: Any]
                    if (state?["error"] as? [String: Any])?["message"] as? String == forbidden["message"] as? String {
                        try require((state?["metrics"] as? [[String: Any]])?.isEmpty == true, "forbidden clears rendered metrics")
                        denied = true; break
                    }
                }
                try require(denied, "exact forbidden message through native bridge")
                host.reauthorize()
                for _ in 0..<200 where host.authorizing { try await Task.sleep(for: .milliseconds(20)) }
                try require(host.page == nil && host.failure != nil, "periodic management revocation clears projection")
            }
            host.destroy()
        }
        print("STORAGE_REPORT_PASS candidateRendered freshReopen responsive320390800 unavailableNotZero subsetLabels managementRevocationClears")
    }
}
#endif
