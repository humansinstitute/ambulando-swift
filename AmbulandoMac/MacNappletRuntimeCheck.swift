#if DEBUG
import AppKit
import AmbulandoCore
import SwiftUI
import WebKit

extension MacThreadRegression {
    /// Real native Apps/view/sandbox/Sync/store with signed synthetic backend responses.
    static func runtimeNappletCheck(model: AppModel) async throws {
        try require(Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test" && NappletRuntimeFixture.enabled,"isolated post-build Test scenario")
        guard let w = model.selectedWorkspace, let c = model.connection, let sync = model.sync, let store = model.store, let fixture = model.fixture else { throw Failure(description:"fixture context") }
        let root = try fixture.tower.runtimeNapplet.scenario(), apps = root["apps"] as! [[String:Any]]
        try require(apps.count == 2,"two cartridges generated after host build")
        try await sync.refreshRuntimeApps(c,w)
        let context = try sync.runtimeContext(c,w)
        let installations = try await store.reader.runtimeApps(connection:c,workspace:w,context:context)
        try require(installations.count == 2,"requester-only Apps discovery projects both arbitrary installations")
        let trust = NappletRuntimeTrust()
        for app in installations { try trust.forget(context:context,publisher:app.publisher,napplet:app.id) }
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:430,height:720),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; defer { window.orderOut(nil) }
        func web(_ view: NSView?) -> WKWebView? {
            if let view = view as? WKWebView { return view }
            for child in view?.subviews ?? [] { if let found = web(child) { return found } }; return nil
        }
        func mount<V:View>(_ view: V) async {
            window.contentView = NSHostingView(rootView:view.environment(model).environment(\.scenePhase,.active).frame(width:430,height:720).id(UUID()))
            window.makeKeyAndOrderFront(nil); await settle()
        }
        func history(_ id: String) throws -> [[String:Any]] {
            let state = try fixture.tower.runtimeNapplet.scenario(), rows = state["apps"] as! [[String:Any]]
            return rows.first { $0["id"] as? String == id }?["history"] as? [[String:Any]] ?? []
        }
        for (index,app) in apps.enumerated() {
            let id = app["id"] as! String, collection = app["collection"] as! String
            await mount(RuntimeAppsSection(workspace:w,store:store))
            for _ in 0..<100 { if find(window,"runtime.app." + id) != nil { break }; try await Task.sleep(for:.milliseconds(30)) }
            try require(find(window,"runtime.app." + id) != nil,"arbitrary runtime Apps entry")
            await mount(NappletRuntimeView(workspace:w,id:id))
            for _ in 0..<200 { if find(window,"runtime.approve") != nil { break }; try await Task.sleep(for:.milliseconds(30)) }
            try press(window,"runtime.approve")
            var page: WKWebView?
            for _ in 0..<300 { if let v = web(window.contentView), (try? await v.evaluateJavaScript("document.getElementById('napplet')!==null")) as? Bool == true { page = v; break }; try await Task.sleep(for:.milliseconds(30)) }
            guard let page else { throw Failure(description:"approved WK host") }
            // Initial list must finish before the one-in-flight bridge admits Save.
            let resultKey = WorkspaceSync.runtimeKey(c,w) + ":result:" + id + ":" + collection
            for _ in 0..<200 { if try await store.reader.state(resultKey) != nil { break }; try await Task.sleep(for:.milliseconds(30)) }
            _ = try await page.evaluateJavaScript("window.runtimeRequests=[];addEventListener('message',e=>window.runtimeRequests.push(e.data));true")
            _ = try await page.evaluateJavaScript("document.getElementById('napplet').contentWindow.postMessage({command:'save'},'*');true")
            for _ in 0..<200 { if try history(id).count == 1 { break }; try await Task.sleep(for:.milliseconds(30)) }
            let saved = try history(id)
            if saved.count != 1 {
                print("RUNTIME_DEBUG localResult=\(try await store.reader.state(resultKey) ?? "nil")")
                print("RUNTIME_DEBUG requests=\(String(describing:try? await page.evaluateJavaScript("JSON.stringify(window.runtimeRequests)")))")
                dump(window)
            }
            try require(saved.count == 1,"v3 native save confirmed through signed Sync transport")
            let result = try await store.reader.state(resultKey) ?? ""
            try require(result.contains("false") && result.contains("zero"),"native local store confirms false/zero record data")
            try fixture.tower.runtimeNapplet.update(id)
            // The active production view checks for publisher updates; no host rebuild or reinstall.
            var updatedPage: WKWebView?
            for _ in 0..<1500 {
                if let v = web(window.contentView), v !== page, (try? await v.evaluateJavaScript("document.getElementById('napplet')!==null")) as? Bool == true { updatedPage = v; break }
                try await Task.sleep(for:.milliseconds(30))
            }
            guard let updatedPage else { throw Failure(description:"automatic within-access update did not mount") }
            _ = try await updatedPage.evaluateJavaScript("addEventListener('message',e=>{if(e.data?.probe)window.runtimeProbe=e.data.probe});true")
            var rendered = false
            for _ in 0..<300 {
                _ = try await updatedPage.evaluateJavaScript("document.getElementById('napplet').contentWindow.postMessage({command:'probe'},'*');true")
                try await Task.sleep(for:.milliseconds(30))
                if let probe = try? await updatedPage.evaluateJavaScript("window.runtimeProbe") as? [String:Any], probe["loaded"] as? Bool == true,
                   (probe["ui"] as? String)?.hasPrefix("Updated") == true, (probe["rendered"] as? String)?.contains(id) == true { rendered = true; break }
            }
            try require(rendered,"updated arbitrary frame displays retained data after ready response")
            try require(find(window,"runtime.approve") == nil,"code-only update does not ask again")
            try require(try JSONSerialization.data(withJSONObject:history(id),options:.sortedKeys) == JSONSerialization.data(withJSONObject:saved,options:.sortedKeys),"immutable record history retained across code update")
            if index == 0, let destination = root["screenshot"] as? String {
                await settle()
                let image = try await updatedPage.takeSnapshot(configuration:nil)
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let png = rep.representation(using:.png,properties:[:]) { try png.write(to:URL(fileURLWithPath:destination)) }
            }
            await mount(Text("Context closed"))
            for _ in 0..<100 { if updatedPage.superview == nil { break }; try await Task.sleep(for:.milliseconds(10)) }
            try require(updatedPage.superview == nil,"context teardown removes WK private frame")
            print("RUNTIME_CARTRIDGE_PASS \(id) Apps consent signedSave autoUpdate noReconsent historyRetained teardown")
        }
        try require(try history(apps[0]["id"] as! String).count == 1 && history(apps[1]["id"] as! String).count == 1,"independent napplet histories")
        print("RUNTIME_NATIVE_PASS twoPostBuildBundles nativeApps v3Sandbox signedSync localStore CAS autoUpdate dataHistoryRetained teardown syntheticBackend")
    }
}
#endif
