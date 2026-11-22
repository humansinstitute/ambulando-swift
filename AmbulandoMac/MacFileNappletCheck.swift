#if DEBUG
import AppKit
import AmbulandoCore

extension MacThreadRegression {
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
