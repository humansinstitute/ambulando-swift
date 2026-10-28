// Native WebKit Return/link regression check; no account, network, app data or test hooks in the product.
// scripts/build-board-editor.sh
// swiftc -parse-as-library scripts/tests/document-return-webkit.swift -o /tmp/document-return-check
// /tmp/document-return-check <repo>/BoardEditor/dist
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

@main struct ReturnCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fputs("FAIL: timed out\n", stderr); exit(1) }
        Task { @MainActor in
            do { try await run(); print("PASS: native WebKit synthetic Return, caret, save/reopen and links"); exit(0) }
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
        let result = try await web.evaluateJavaScript("""
        (() => {
          const check=(ok,msg)=>{if(!ok) throw Error(msg)};
          const ed=()=>document.querySelector('.ProseMirror').editor;
          const link={type:'text',text:'Petes Notes',marks:[{type:'fdMention',attrs:{mentionType:'doc',mentionId:'petes-notes',label:'Petes Notes'}}]};
          for (const mode of ['markdown','rich']) {
            const doc={type:'doc',content:[{type:'paragraph',content:[link]}]};
            const load = content => ambulandoDocument.load(JSON.stringify(mode==='markdown'?{mode,markdown:content}:{mode,state:JSON.parse(content)}));
            load(mode==='markdown'?'[Petes Notes](mention:doc:petes-notes)':JSON.stringify(doc));
            const e=ed(); e.view.dom.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'insertText',data:'Intro'}));
            const handlers=e.state.plugins.find(p=>p.props.handleDOMEvents?.pointercancel && p.props.handleKeyDown).props;
            for (const target of [null, document, window, document.createTextNode('detached')]) {
              const event={target,key:'Enter',preventDefault(){throw Error('ordinary Return consumed')}};
              check(handlers.handleKeyDown(e.view,event)===false,mode+' non-Element key target');
              check(handlers.handleDOMEvents.pointerdown(e.view,event)===false,mode+' non-Element pointer target');
              check(handlers.handleDOMEvents.click(e.view,event)===false,mode+' non-Element click target');
            }
            e.commands.setTextSelection(1); e.commands.insertContent('Intro');
            check(e.state.selection.from===6,mode+' text caret');
            // Same undispatched Event construction as prosemirror-view's iOS Return fallback.
            const enter=document.createEvent('Event'); enter.initEvent('keydown',true,true); enter.keyCode=13; enter.key=enter.code='Enter';
            check(enter.target===null,'synthetic event has null target');
            let originalFailed=false;
            try { enter.target.closest?.('[data-mention-id]'); } catch(error) { originalFailed=error instanceof TypeError; }
            check(originalFailed,'original unguarded target.closest throws TypeError');
            check(e.view.someProp('handleKeyDown', f=>f(e.view,enter)),mode+' Return handled');
            check(e.state.doc.child(0).textContent==='Intro',mode+' split preceding text');
            check(e.state.doc.child(1).textContent==='Petes Notes',mode+' link on next line');
            check(e.state.selection.$from.parentOffset===0,mode+' newline caret');
            e.commands.insertContent('More ');
            check(e.state.selection.$from.parentOffset===5,mode+' continued caret');
            const saved=ambulandoDocument.snapshot(); load(saved);
            check(ed().state.doc.child(0).textContent==='Intro',mode+' reopened first paragraph');
            check(ed().state.doc.child(1).textContent==='More Petes Notes',mode+' reopened second paragraph');
            const a=document.querySelector('[data-mention-id="petes-notes"]');
            check(!!a,mode+' stable link restored');
            a.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,button:0,detail:0}));
            check(recordMessages.some(m=>m.type==='record-link'&&m.id==='petes-notes'),mode+' link callback');
            check(!recordMessages.some(m=>m.type==='error'),mode+' no page error');
          }
          return 'Markdown and rich passed';
        })()
        """)
        print(String(describing:result)); window.close()
    }
}
