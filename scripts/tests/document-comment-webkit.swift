// Native WebKit selection overlay regression check; no account, network, app data or test hooks in the product.
// scripts/build-board-editor.sh
// swiftc -parse-as-library scripts/tests/document-comment-webkit.swift -o /tmp/document-comment-check
// /tmp/document-comment-check <repo>/BoardEditor/dist
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

@main struct CommentCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fputs("FAIL: timed out\n", stderr); exit(1) }
        Task { @MainActor in
            do { try await run(); print("PASS: native WebKit comment geometry, focus, scroll, resize, keyboard viewport and exact anchor"); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    @MainActor static func run() async throws {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalEditor(URL(fileURLWithPath: CommandLine.arguments[1])), forURLScheme: "ambulando-board")
        config.userContentController.addUserScript(WKUserScript(source: "window.recordMessages=[]; window.webkit=window.webkit||{messageHandlers:{}}; window.webkit.messageHandlers.document={postMessage: v=>window.recordMessages.push(JSON.parse(v))};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x:0,y:0,width:900,height:600), configuration:config)
        let window = NSWindow(contentRect:web.frame, styleMask:[.titled], backing:.buffered, defer:false)
        window.contentView=web; window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url:URL(string:"ambulando-board://editor/document.html")!))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!window.ambulandoDocument")) as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        let result = try await web.callAsyncJavaScript("""
        const check=(ok,msg)=>{if(!ok) throw Error(msg)};
        const tick=()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        const load=()=>ambulandoDocument.load(JSON.stringify({mode:'rich',state:{type:'doc',content:Array.from({length:30},(_,i)=>({type:'paragraph',content:[{type:'text',text:'Passage '+i+' selected words and continued writing.'}]}))}}));
        load(); await tick();
        const e=document.querySelector('.ProseMirror').editor;
        const button=document.getElementById('doc.commentSelection');
        const paper=()=>document.querySelector('.ProseMirror').getBoundingClientRect().top;
        e.commands.focus(); e.commands.setTextSelection(1); await tick();
        const before=paper(), scroll=scrollY, height=document.body.scrollHeight;
        for(let i=0;i<5;i++) {
          e.commands.setTextSelection({from:1,to:10}); await tick();
          check(!button.hidden,'visible on selection');
          const selection=window.getSelection().getRangeAt(0).getBoundingClientRect(), b=button.getBoundingClientRect();
          check(b.left>=selection.right,'icon right beside short selected line');
          check(b.width===44 && b.height===44,'44px target');
          check(paper()===before && scrollY===scroll && document.body.scrollHeight===height,'zero selection layout/scroll movement');
          e.commands.setTextSelection(10); await tick();
          check(button.hidden && paper()===before && scrollY===scroll,'clear without movement');
        }
        e.commands.setTextSelection({from:1,to:10}); await tick();
        const selected=e.state.selection, focused=document.activeElement;
        const touch=new PointerEvent('pointerdown',{bubbles:true,cancelable:true,pointerType:'touch',pointerId:1});
        button.dispatchEvent(touch); check(touch.defaultPrevented,'touch preserves selection');
        button.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,pointerType:'touch',pointerId:1}));
        button.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}));
        check(e.state.selection===selected && document.activeElement===focused,'pointer preserves selection/focus');
        button.click(); await tick();
        const message=recordMessages.filter(m=>m.type==='comment-selection').at(-1);
        check(message?.anchor.anchor_quote==='Passage 0','captures exact quote');
        check(message.anchor.anchor_start_offset===1 && message.anchor.anchor_end_offset===10,'captures exact offsets');
        check(button.hidden,'dismissed after action');
        e.view.dom.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'insertText',data:' typed'}));
        e.commands.setTextSelection(10); e.commands.insertContent(' typed'); await tick();
        check(button.hidden && document.activeElement===focused && paper()===before && scrollY===scroll,'typing keeps focus and layout');
        e.commands.setTextSelection({from:1,to:10}); await tick();
        window.scrollTo(0,700); await tick(); check(button.hidden,'hide scrolled-out selection');
        window.scrollTo(0,0); await tick(); check(!button.hidden,'tracks scroll back');
        document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true})); await tick(); check(button.hidden,'Escape dismisses');
        e.commands.setTextSelection(10); e.commands.setTextSelection({from:1,to:12}); await tick();
        // Same visualViewport geometry input as an iPhone keyboard; actual touch/keyboard tested in simulator.
        Object.defineProperty(window,'visualViewport',{configurable:true,value:{offsetLeft:0,offsetTop:0,width:320,height:180}});
        window.dispatchEvent(new Event('resize')); await tick();
        const b=button.getBoundingClientRect(); check(b.right<=316 && b.bottom<=176,'keyboard viewport bounds');
        delete window.visualViewport;
        e.commands.setTextSelection(1); e.commands.setTextSelection({from:1,to:8}); await tick();
        const count=recordMessages.filter(m=>m.type==='comment-selection').length;
        document.dispatchEvent(new KeyboardEvent('keydown',{key:'µ',code:'KeyM',metaKey:true,altKey:true,bubbles:true,cancelable:true})); await tick();
        check(recordMessages.filter(m=>m.type==='comment-selection').length===count+1,'Mac Option Command M shortcut');
        const snapshot=ambulandoDocument.snapshot(); ambulandoDocument.load(JSON.stringify({mode:'rich',state:JSON.parse(snapshot)})); await tick();
        check(document.querySelector('.ProseMirror').editor.state.doc.textContent.includes(' typed'),'typed content survives reopen');
        return 'zero movement: select/clear/type; exact quote/offsets; pointer focus; scroll; Escape; keyboard viewport; reopen';
        """, arguments: [:], contentWorld: .page)
        print(String(describing:result))
        for size in [NSSize(width: 390, height: 300), NSSize(width: 1000, height: 700)] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(200))
            let bounds = try await web.callAsyncJavaScript("""
            const e=document.querySelector('.ProseMirror').editor; e.commands.focus(); e.commands.setTextSelection({from:1,to:9});
            await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
            const b=document.getElementById('doc.commentSelection'), r=b.getBoundingClientRect();
            if(b.hidden || r.right>innerWidth || r.bottom>innerHeight) throw Error('native resize bounds');
            return [innerWidth,innerHeight,r.x,r.y];
            """, arguments: [:], contentWorld: .page)
            print("Native resize: \(String(describing: bounds))")
        }
        if CommandLine.arguments.count > 2 {
            let image = try await web.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            }
        }
        window.close()
    }
}
