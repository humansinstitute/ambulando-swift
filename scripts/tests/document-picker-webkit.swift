// Native WebKit geometry/interaction check; no account, network, app data or test hooks in the product.
// scripts/build-board-editor.sh
// swiftc -parse-as-library scripts/tests/document-picker-webkit.swift -o /tmp/document-picker-check
// /tmp/document-picker-check <repo>/BoardEditor/dist <ignored-evidence-directory>
import AppKit
import WebKit

final class LocalEditor: NSObject, WKURLSchemeHandler {
    let root: URL
    init(_ root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        let file = root.appendingPathComponent(url.path)
        do {
            let data = try Data(contentsOf: file)
            let mime = ["html":"text/html", "js":"text/javascript", "css":"text/css"][file.pathExtension] ?? "application/octet-stream"
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@main struct PickerCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fputs("FAIL: WebKit check timed out\n", stderr); exit(1) }
        Task { @MainActor in
            do { try await run(); print("PASS: native WebKit document picker geometry and interactions"); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    struct Failure: Error { let message: String }
    @MainActor static func run() async throws {
        fputs("Starting WebKit check\n", stderr)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let evidence = URL(fileURLWithPath: CommandLine.arguments[2])
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalEditor(root), forURLScheme: "ambulando-board")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 350, height: 160), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = web; window.makeKeyAndOrderFront(nil)
        fputs("Loading page\n", stderr)
        web.load(URLRequest(url: URL(string: "ambulando-board://editor/document.html")!))
        func js(_ code: String) async throws -> Any? { try await web.evaluateJavaScript(code) }
        func capture(_ name: String) async throws {
            let image = try await web.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: evidence.appendingPathComponent(name + ".png"))
            }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(180)) }
        for _ in 0..<100 {
            if (try? await js("!!window.ambulandoDocument")) as? Bool == true { break }
            await settle()
        }
        fputs("Page ready poll finished\n", stderr)
        _ = try await js("""
        window.check = (ok, message) => { if (!ok) throw new Error(message); };
        window.key = key => document.querySelector('.ProseMirror').dispatchEvent(new KeyboardEvent('keydown', {key, bubbles:true, cancelable:true}));
        window.ed = () => document.querySelector('.ProseMirror').editor;
        window.panel = () => document.querySelector('.document-mention-picker');
        window.openPicker = () => {
          ed().commands.insertContent(' @');
          const {from} = ed().state.selection;
          const rows = Array.from({length:24}, (_,i) => ({type:'doc', id:'d'+i, label:'Document '+i+' with a longer wrapping title', detail:'Doc'}));
          check(ambulandoDocument.mentionSuggestions(JSON.stringify({range:{from:from-1,to:from,query:''}, rows})), 'suggestions accepted');
        };
        ambulandoDocument.load(JSON.stringify({mode:'markdown', markdown: Array.from({length:30},(_,i)=>'Paragraph '+i).join('\\n\\n') + '\\n\\nTail'}));
        """)
        await settle()
        _ = try await js("ed().commands.focus('end'); openPicker();")
        await settle()
        // The old CSS is measured in the same engine, page and keyboard-reduced dimensions.
        let baseline = try await js("panel().style.maxHeight='45vh'; panel().style.boxSizing='content-box'; panel().getBoundingClientRect().height") as! Double
        try await capture("webkit-baseline")
        let baselineRows = try await js("Array.from(panel().children).filter(e=>e.getBoundingClientRect().bottom<=panel().getBoundingClientRect().bottom).length")
        print("BASELINE complete rows=\(String(describing: baselineRows))")
        _ = try await js("panel().style.removeProperty('box-sizing'); window.dispatchEvent(new Event('resize'));")
        let improved = try await js("panel().getBoundingClientRect().height") as! Double
        guard improved / baseline > 1.8 && improved / baseline < 2.1 else { throw Failure(message: "height ratio \(improved / baseline)") }
        print("KEYBOARD_REDUCED 350x160 baseline=\(baseline) improved=\(improved) ratio=\(improved / baseline)")
        for (name, width, height, font) in [("phone",350,160,15), ("small-phone",296,120,15), ("rotation",720,100,15), ("larger-text",350,160,24), ("mac",900,600,15)] {
            window.setContentSize(NSSize(width: width, height: height)); await settle()
            _ = try await js("document.documentElement.style.setProperty('--doc-body','\(font)px'); window.dispatchEvent(new Event('resize'));")
            print("\(name) \(String(describing: try await js("JSON.stringify({height:panel().getBoundingClientRect().height,viewport:visualViewport.height,rows:Array.from(panel().children).filter(e=>e.getBoundingClientRect().bottom<=panel().getBoundingClientRect().bottom).length})")))")
            _ = try await js("""
            var b=panel().getBoundingClientRect();
            check(b.top >= visualViewport.offsetTop && b.bottom <= visualViewport.offsetTop+visualViewport.height, 'bounded above keyboard');
            var scroll=window.scrollY, selection=ed().state.selection.from;
            for(var i=0;i<18;i++) key('ArrowDown');
            var p=panel(), s=p.querySelector('[aria-selected=true]'), r=s.getBoundingClientRect(), b=p.getBoundingClientRect();
            check(p.scrollTop>0 && r.top>=b.top && r.bottom<=b.bottom, 'later selected result visible');
            check(window.scrollY===scroll && ed().state.selection.from===selection, 'document scroll and caret preserved');
            for(var i=0;i<18;i++) key('ArrowUp');
            """)
            if name == "phone" || name == "larger-text" {
                try await capture("webkit-\(name)")
            }
        }
        _ = try await js("""
        key('Escape'); check(!panel(), 'Escape closes');
        openPicker(); check(!!panel(), 'reopens on fresh trigger');
        panel().scrollTop=panel().scrollHeight;
        panel().lastElementChild.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}));
        panel().lastElementChild.click();
        check(!panel() && ed().getText().includes('Document 23'), 'tap later result');
        ed().commands.insertContent(' kept typing');
        check(ed().getText().endsWith(' kept typing') && !panel(), 'typing continues at caret');
        openPicker(); for(var i=0;i<18;i++) key('ArrowDown'); key('Enter');
        check(!panel() && ed().getText().includes('Document 18'), 'keyboard selects later result');
        var saved=ambulandoDocument.snapshot();
        check(saved.includes('mention:doc:d18') && saved.includes('mention:doc:d23'), 'stable record tokens saved');
        ambulandoDocument.load(JSON.stringify({mode:'markdown',markdown:saved}));
        """)
        await settle()
        _ = try await js("""
        check(document.querySelectorAll('[data-mention-id]').length===2,'record links reopen');
        ed().commands.focus('end');
        ambulandoDocument.wikiInsert(JSON.stringify({documentId:'wiki-target',title:'Wiki target'}));
        check(ambulandoDocument.snapshot().includes('Wiki target'), 'wiki insertion preserved');
        """)
        window.close()
    }
}
