#if DEBUG
import AppKit
import AmbulandoCore
import SwiftUI

@MainActor
private final class CloseLifecycleProbe: NSObject, NSWindowDelegate {
    var closed = false
    var allowClose = false
    func windowShouldClose(_ sender: NSWindow) -> Bool { allowClose }
    func windowWillClose(_ notification: Notification) { closed = true }
}

extension MacThreadRegression {
    static func nappletTrustCheck(model: AppModel) async throws {
        try require(Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test" && NappletTrustFixture.enabled, "isolated trust fixture")
        guard let workspace = model.selectedWorkspace, let tower = model.fixture?.tower else { throw Failure(description: "fixture context") }
        guard let sync = model.sync, let connection = model.connection else { throw Failure(description: "fixture sync") }
        let reviewed = try await sync.fileNappletCode(connection, workspace, fileId: NappletTrustFixture.codeId)
        let expectedReceipt = try FileNappletTrustReceipt(connection: connection, workspace: workspace, codeFile: NappletTrustFixture.codeId, code: reviewed, canWrite: true)
        let file = try FileRecord(raw: JSONSerialization.data(withJSONObject: ["id": NappletTrustFixture.codeId, "workspace_id": workspace.id, "channel_id": NappletTrustFixture.channelId, "display_name": "Synthetic tracker.html"]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        func mount(store: FileNappletTrustStore = .local) async {
            window.contentView = NSHostingView(rootView: DirectHTMLFileView(file: file, workspace: workspace, appMode: true, trustStore: store).environment(model).environment(\.scenePhase, .active).id(UUID()))
            window.makeKeyAndOrderFront(nil)
            await settle()
        }
        func wait(_ id: String) async throws {
            for _ in 0..<100 { if find(window, id) != nil { return }; try await Task.sleep(for: .milliseconds(50)) }
            dump(window)
            throw Failure(description: "Missing trust UI: " + id)
        }
        func act(_ id: String) async throws {
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<100 {
                if let node = find(window, id) {
                    var enabled = value(node, "AXEnabled") as? Bool
                    for getter in ["isAccessibilityEnabled", "accessibilityEnabled"] {
                        let selector = NSSelectorFromString(getter)
                        if node.responds(to: selector) {
                            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
                            enabled = unsafeBitCast(node.method(for: selector), to: Getter.self)(node, selector)
                            break
                        }
                    }
                    if enabled == true {
                        print("TRUST_CONTROL_ENABLED " + id)
                        do { try press(window, id) } catch { try click(window, id) }
                        return
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            dump(window)
            throw Failure(description: "Trust control stayed disabled: " + id)
        }
        await mount(); try await wait("napplet.approve")
        try require(find(window, "napplet.forget") == nil, "no bridge before first consent")
        try await act("napplet.approve"); try await wait("napplet.forget")
        try await act("napplet.reload"); await settle(); try await wait("napplet.forget")
        try require(find(window, "napplet.approve") == nil, "reload remembered approval")
        await mount(); try await wait("napplet.forget")
        try require(find(window, "napplet.approve") == nil, "close/reopen remembered approval")
        tower.trustNapplet.change("data")
        try await act("napplet.reload"); await settle(); try await wait("napplet.forget")
        try require(find(window, "napplet.approve") == nil, "ordinary data edits retain trust")
        try require(FileNappletTrustStore.local.contains(expectedReceipt), "native approval receipt persisted before revoke")
        try await act("napplet.forget")
        await settle()
        print("TRUST_REVOKE_STILL_REMEMBERED \(FileNappletTrustStore.local.contains(expectedReceipt))")
        try await wait("napplet.approve")
        try await act("napplet.approve"); try await wait("napplet.forget")
        for scenario in ["code", "binding", "access"] {
            tower.trustNapplet.change(scenario)
            await mount(); try await wait("napplet.approve")
            try require(find(window, "napplet.forget") == nil, "changed " + scenario + " needs consent")
            tower.trustNapplet.change("")
            await mount(); try await wait("napplet.forget")
        }
        tower.trustNapplet.change("denied")
        await mount(); try await Task.sleep(for: .milliseconds(300))
        try require(find(window, "napplet.forget") == nil && find(window, "napplet.approve") == nil, "denied access cannot use receipt")
        tower.trustNapplet.change("")
        let blocked = model.fixture!.directory.appendingPathComponent("blocked-trust-file")
        try Data().write(to: blocked)
        await mount(store: FileNappletTrustStore(directory: blocked))
        try await wait("napplet.approve"); try await act("napplet.approve")
        try await wait("napplet.remember-notice"); try await wait("napplet.forget")
        await mount(store: FileNappletTrustStore(directory: blocked))
        try await wait("napplet.approve")
        print("PASS: native consent UI first approval, reload, close/reopen, revoke, code/binding/access changes, denied access; synthetic signed Tower boundary")
        try await fileNappletCheck(model: model)
    }

    static func dailyMetricsAppsCheck(model: AppModel) async throws {
        try require(Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", "isolated Test app")
        guard let workspace = model.selectedWorkspace, let store = model.store else { throw Failure(description: "fixture workspace") }
        model.setDailyMetricsVisible(true, in: workspace)
        model.setDailyMetricsLast(false, in: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DeckHelloCard(workspace: workspace, store: store).environment(model))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); model.setDailyMetricsVisible(true, in: workspace); model.setDailyMetricsLast(false, in: workspace) }
        try await settle()
        try require(find(window, "deck.napplet.daily-tracker") != nil, "phone-width Apps entry before tracker provisioning")
        try press(window, "deck.napplet.daily-tracker")
        try require(model.toolboxPath.last == .webContent(workspaceId: workspace.id, source: .dailyMetrics), "Apps opens direct app route")
        model.toolboxPath = []
        model.setDailyMetricsVisible(false, in: workspace)
        try await settle()
        try require(find(window, "deck.napplet.daily-tracker") == nil, "hide placement")
        _ = model.handleAppLink(URL(string: "/flight-deck?workspaceid=\(workspace.id)&napplet=daily-tracker")!)
        try require(model.toolboxPath.last == .webContent(workspaceId: workspace.id, source: .dailyMetrics), "hidden placement retains explicit app route")
        model.toolboxPath = []
        _ = model.handleAppLink(URL(string: "/flight-deck?workspaceid=00000000-0000-4000-8000-000000000099&napplet=daily-tracker")!)
        try require(model.toolboxPath.isEmpty, "wrong workspace route rejected")
        model.fileNappletNavigation = { _ in true }
        model.openDailyMetrics(in: workspace)
        try require(model.toolboxPath.isEmpty, "Apps launch respects current navigation close guard")
        model.fileNappletNavigation = nil
        model.setDailyMetricsVisible(true, in: workspace)
        model.setDailyMetricsLast(true, in: workspace)
        try require(model.dailyMetricsVisible(workspace) && model.dailyMetricsLast(workspace), "show and order placement")
        print("PASS: Daily Metrics Apps at 390px, default entry, hide/show/order, direct route, hidden route, wrong workspace and navigation gate")
        try await fileNappletCheck(model: model)
    }

    static func fileNappletCloseCheck(_ main: NSWindow, model: AppModel) async throws {
        try require(Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", "isolated Test app")
        try require(main.delegate is MacMainWindowCloseDelegate, "SwiftUI main scene installs production close delegate")
        let template = try String(contentsOf: Bundle.main.url(forResource: "daily-tracker-v1", withExtension: "html")!, encoding: .utf8)
        let bytes = Data("{\"format\":\"daily-tracker-v1\",\"metrics\":[],\"days\":{}}".utf8)
        var saving: CheckedContinuation<Void, Never>?
        let host = FileNappletHost(read: { FileNappletData(bytes: bytes, versionId: "11111111-1111-4111-8111-111111111111", canWrite: true) }, save: { _, value in
            await withCheckedContinuation { saving = $0 }
            return FileNappletData(bytes: value, versionId: "saved", canWrite: true)
        })
        host.open(html: template + """
        <script>
        addEventListener('message',e=>{
          if(e.data==='probe-draft'){
            document.getElementById('manage').click();
            document.querySelector('input[placeholder]').value='Exact unsaved draft 102';
            parent.postMessage({type:'wingman-napplet-data',version:1,session:window.nappletSession,requestId:'draft_probe',operation:'dirty',dirty:true},'*');
          }
          if(e.data==='probe-snapshot')parent.postMessage({probe:document.querySelector('input[placeholder]').value},'*');
          if(e.data==='probe-save')parent.postMessage({type:'wingman-napplet-data',version:1,session:window.nappletSession,requestId:'save_probe',operation:'save',binding:'tracker',baseVersionId:'11111111-1111-4111-8111-111111111111',value:{format:'daily-tracker-v1',metrics:[],days:{}}},'*');
        });
        </script>
        """)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MacMainWindowCloseGuard.WindowView(model: model)
        window.contentView = view
        if let web = host.page?.webView { view.addSubview(web); web.frame = view.bounds }
        window.makeKeyAndOrderFront(nil)
        let page = host.page!
        let web = page.webView!
        var discard: (() -> Void)?
        model.fileNappletNavigation = { action in host.interceptNavigation(action) { discard = $0 } }
        model.fileNappletContextLost = { host.destroy(); discard = nil }
        defer { saving?.resume(); model.clearFileNappletForContextLoss(); window.orderOut(nil) }
        func command(_ value: String) async throws {
            _ = try await web.evaluateJavaScript("document.getElementById('napplet').contentWindow.postMessage('\(value)','*')")
        }
        for _ in 0..<200 where !page.ready || host.pending { try await Task.sleep(for: .milliseconds(25)) }
        try require(page.ready && !host.pending, "production tracker initial read")
        _ = try await web.evaluateJavaScript("addEventListener('message',e=>{if(e.source===document.getElementById('napplet').contentWindow&&e.data?.probe)window.draftProbe=e.data.probe})")
        try await command("probe-draft")
        for _ in 0..<100 where !host.dirty { try await Task.sleep(for: .milliseconds(10)) }
        try require(host.dirty, "real frame reports draft")
        // A window-targeted native menu lets the command run even on CI hosts where this
        // unsigned Test process cannot take global keyboard focus from the logged-in app.
        let closeMenu = NSMenu()
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.target = window; closeItem.keyEquivalentModifierMask = .command
        closeMenu.addItem(closeItem)
        func commandW() throws {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
            try require(closeMenu.performKeyEquivalent(with: event), "Cmd-W native menu action routed")
        }
        for close in 0..<2 {
            if close == 0 { window.standardWindowButton(.closeButton)!.performClick(nil) }
            else { try commandW() }
            try require(window.isVisible && discard != nil && host.page === page, "red close/Cmd-W guarded")
            discard = nil // Same cancellation as Keep editing: never execute deferred action.
            try await command("probe-snapshot")
            try await Task.sleep(for: .milliseconds(50))
            let draft = try await web.evaluateJavaScript("window.draftProbe") as? String
            try require(draft == "Exact unsaved draft 102" && host.page === page && host.dirty, "cancel preserves exact DOM draft and document")
        }
        try await command("probe-save")
        for _ in 0..<100 where saving == nil { try await Task.sleep(for: .milliseconds(10)) }
        try require(saving != nil && host.writing, "actual bridge save is pending")
        window.standardWindowButton(.closeButton)!.performClick(nil)
        try commandW()
        try require(window.isVisible && discard == nil && host.page === page && host.writing, "both close paths refuse in-flight save")
        saving?.resume(); saving = nil
        for _ in 0..<100 where host.writing { try await Task.sleep(for: .milliseconds(10)) }
        try require(!host.writing && !host.dirty, "save completes")
        host.dirty = true
        window.performClose(nil)
        try require(discard != nil, "discard offered after save")
        let next = discard; discard = nil; host.destroy(); model.fileNappletNavigation = nil; next?()
        try require(!window.isVisible && host.page == nil, "explicit discard closes window")
        let revoked = FileNappletHost(read: { throw FileNappletError.unavailable }, save: { _, _ in throw FileNappletError.unavailable })
        revoked.open(html: "<p>Disposable context-loss probe</p>")
        revoked.dirty = true; revoked.writing = true
        model.fileNappletNavigation = { _ in true }
        model.fileNappletContextLost = { revoked.destroy() }
        model.clearFileNappletForContextLoss()
        try require(revoked.page == nil && !revoked.dirty && !revoked.writing && model.fileNappletNavigation == nil, "forced context loss destroys dirty pending host immediately")
        let ordinary = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        ordinary.isReleasedWhenClosed = false
        let lifecycle = CloseLifecycleProbe()
        ordinary.delegate = lifecycle
        let proxy = MacMainWindowCloseDelegate(model: model)
        proxy.attach(to: ordinary)
        ordinary.makeKeyAndOrderFront(nil)
        ordinary.performClose(nil)
        try require(ordinary.isVisible && !lifecycle.closed, "original delegate close veto preserved")
        lifecycle.allowClose = true
        ordinary.performClose(nil)
        try require(!ordinary.isVisible && lifecycle.closed, "original window lifecycle forwarded")
        proxy.attach(to: nil)
        try require(ordinary.delegate === lifecycle, "original scene delegate restored on detach")
        print("FILE_NAPPLET_CLOSE_PASS red-button; Cmd-W responder action; cancel exact DOM draft; actual pending save blocked; discard closes; context loss destroys. Synthetic transport, local Test app only.")
    }

    /// Actual production host and packaged UI, synthetic memory transport only. Never opens a real workspace File.
    static func fileNappletCheck(model: AppModel) async throws {
        try require(Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", "File napplet check requires isolated Test app")
        let template = try String(contentsOf: Bundle.main.url(forResource: "daily-tracker-v1", withExtension: "html")!, encoding: .utf8)
        var bytes = Data("{\"format\":\"daily-tracker-v1\",\"metrics\":[],\"days\":{}}".utf8)
        var version = UUID().uuidString.lowercased(), reads = 0, saves = 0, denied = false
        let start = ContinuousClock.now
        let host = FileNappletHost(read: {
            if denied { throw FileNappletError.unavailable }
            reads += 1; return FileNappletData(bytes: bytes, versionId: version, canWrite: true)
        }, save: { base, value in
            try require(base == version, "save kept original base")
            try TrackerDocument.validate(value, previous: bytes)
            bytes = value; version = UUID().uuidString.lowercased(); saves += 1
            return FileNappletData(bytes: bytes, versionId: version, canWrite: true)
        })
        defer { host.destroy() }
        let script = """
        <script>
        (async()=>{
          const wait=async f=>{for(let i=0;i<200;i++){if(f())return;await new Promise(r=>setTimeout(r,25));}throw Error('UI timeout');};
          const click=t=>{const b=Array.from(document.querySelectorAll('button')).find(b=>b.textContent===t);if(!b)throw Error('missing '+t);b.click();};
          if(typeof window.nostr!=='undefined')throw Error('unexpected signer');
          let blocked=false;try{await fetch('https://napplet-network-check.invalid/')}catch{blocked=true;}if(!blocked)throw Error('network');
          window.webkit?.messageHandlers?.napplet?.postMessage({type:'wingman-napplet-data',version:1,session:window.nappletSession,requestId:'raw_frame_bypass',operation:'read',binding:'tracker'});
          parent.postMessage({type:'wingman-napplet-data',version:1,session:'wrong',requestId:'wrong_nonce',operation:'read',binding:'tracker'},'*');
          await wait(()=>document.getElementById('status').textContent.includes('Saved in NStack'));
          document.getElementById('manage').click();
          const add=(label,type)=>{const input=document.querySelector('input[placeholder]');input.value=label;document.querySelector('select').value=type;click('Add metric');};
          add('Synthetic boolean','boolean');add('Synthetic number','number');
          document.getElementById('checkin').click();click('No');
          const number=document.querySelector('input[type=number]');number.value='0';number.dispatchEvent(new Event('input'));
          document.getElementById('save').click();
          await wait(()=>document.getElementById('status').textContent.includes('Saved in NStack'));
          document.getElementById('date').value='2024-02-29';document.getElementById('date').dispatchEvent(new Event('change'));
          click('Yes');document.getElementById('save').click();
        })().catch(()=>parent.postMessage({type:'wingman-napplet-data',version:1,session:window.nappletSession,requestId:'probe_error',operation:'dirty',dirty:true},'*'));
        </script>
        """
        host.open(html: template + script)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.page?.webView; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<300 {
            if saves == 2 || host.failure != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(host.failure == nil && saves == 2, "packaged UI reads and saves through real opaque WebKit frame: \(host.failure ?? "saves=\(saves)")")
        let root = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let days = root["days"] as! [String: [String: Any]]
        try require(days.count == 2 && days["2024-02-29"]?.count == 1, "earlier local-calendar day preserves unanswered field")
        let today = days.first { $0.key != "2024-02-29" }!.value
        try require(today.values.contains { ($0 as? NSNumber) == 0 }, "false and numeric zero saved")
        let seconds = Double(start.duration(to: .now).components.attoseconds) / 1e18 + Double(start.duration(to: .now).components.seconds)
        try require(reads == 1, "raw subframe/native and wrong-nonce calls rejected")
        let originalMode = model.mode
        var next: (() -> Void)?
        host.dirty = true
        model.fileNappletNavigation = { action in host.interceptNavigation(action) { next = $0 } }
        let destination: AppMode = originalMode == .tasks ? .docs : .tasks
        model.show(destination)
        try require(model.mode == originalMode && next != nil && host.page != nil, "section switch defers while draft is dirty")
        next = nil // Cancel keeps editing.
        model.show(destination)
        model.fileNappletNavigation = nil; next?()
        try require(model.mode == destination, "explicit discard permits deferred navigation")
        model.fileNappletNavigation = { action in host.interceptNavigation(action) { next = $0 } }
        host.writing = true; next = nil
        model.show(originalMode)
        try require(model.mode == destination && next == nil, "pending save blocks voluntary section navigation")
        host.writing = false; model.fileNappletNavigation = nil
        let page = host.page
        host.reauthorize()
        for _ in 0..<100 where host.pending { try await Task.sleep(for: .milliseconds(10)) }
        try require(host.page === page && !host.pending, "reauthorization preserves document")
        denied = true; host.reauthorize()
        for _ in 0..<100 where host.page != nil { try await Task.sleep(for: .milliseconds(10)) }
        try require(host.page == nil && host.failure != nil, "denied reauthorization destroys frame and clears values")
        print("FILE_NAPPLET_WEBKIT_PASS phoneWidth=390 saves=\(saves) reads=\(reads) flowSeconds=\(seconds) false/zero/unanswered/calendar-history; denied-frame-destroyed; synthetic memory only")
    }
}
#endif
