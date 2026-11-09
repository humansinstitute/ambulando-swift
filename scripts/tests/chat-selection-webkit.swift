// Runs the shipped selection script/template against the core-rendered fixture, in real macOS WebKit.
// See chat-selection.sh. It exercises DOM ranges and native clipboard, not a simulated mouse or iPhone touch.
import AppKit
import WebKit
import SwiftUI

@MainActor final class Messages: NSObject, WKScriptMessageHandler {
    var values: [[String:Any]] = []
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if let v = m.body as? [String:Any] { values.append(v) }
    }
}
@main struct SelectionCheck {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fputs("FAIL timeout\n",stderr); exit(1) }
        Task { @MainActor in
            do { try await run(); print("PASS continuous ranges, partial tables, styles, streaming, sizing and native HTML/plain clipboard"); exit(0) }
            catch { fputs("FAIL \(error)\n",stderr); exit(1) }
        }
        app.run()
    }
    static func rgb(_ value: UInt32) -> String {
        "rgb(\((value >> 16) & 255), \((value >> 8) & 255), \(value & 255))"
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let resources = root.appendingPathComponent("Ambulando/Resources")
        let script = try String(contentsOf: resources.appendingPathComponent("ChatSelection.js"), encoding: .utf8)
        let html = try String(contentsOf: resources.appendingPathComponent("ChatSelection.html"), encoding: .utf8).replacingOccurrences(of: "<!--CONTENT-->", with: fixture)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let messages = Messages(); config.userContentController.add(messages, name:"chatSelection")
        config.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        let web = WKWebView(frame:NSRect(x:0,y:0,width:800,height:1200),configuration:config)
        let window = NSWindow(contentRect:web.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.contentView=web; window.makeKeyAndOrderFront(nil)
        web.loadHTMLString(html,baseURL:nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof chatClipboard==='function'")) as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        // Compare the shipped WebKit body with the actual SwiftUI plain font and multiline rhythm.
        for scale: CGFloat in [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2] {
            let type = NativeChatTypography(scale: scale)
            let expected = NSFont.preferredFont(forTextStyle: .body).pointSize * scale
            guard type.pointSize == expected else { throw NSError(domain: "Native body size mismatch", code: 4) }
            func plainHeight(_ lines: Int) -> CGFloat {
                NSHostingView(rootView: Text(verbatim: Array(repeating: "Matching body", count: lines).joined(separator: "\n"))
                    .font(type.font).lineSpacing(3 * scale).fixedSize()).fittingSize.height
            }
            let nativeWidth = NSHostingView(rootView: Text("Matching body").font(type.font).fixedSize()).fittingSize.width
            let step = (plainHeight(30) - plainHeight(10)) / 20
            for dark in [false, true] {
                for muted in [false, true] {
                    let style = try JSONSerialization.jsonObject(with: Data(type.webStyle(dark: dark, muted: muted).utf8))
                    let report = try await web.callAsyncJavaScript("""
                    chatContent('<p>Matching body<br>Matching body<br>Matching body</p><p>Before <a href="https://example.com">link</a> <a><mark>Agent</mark></a> <a><mark>Document</mark></a> <a><mark>Task</mark></a> <strong>bold</strong> <em>italic</em> after.</p><h2>Heading</h2><pre><code>Code</code></pre>');
                    chatStyle(style);
                    const root=document.getElementById('message'), p=root.querySelector('p'), s=getComputedStyle(p);
                    const check=(ok,msg)=>{if(!ok)throw Error(msg)};
                    check(Math.abs(parseFloat(s.fontSize)-size)<.01,'native body size');
                    check(Math.abs(parseFloat(s.lineHeight)-step)<.06,'native multiline rhythm: '+s.lineHeight+' vs '+step);
                    const word=document.createRange();word.selectNodeContents(p.firstChild);
                    check(Math.abs(word.getBoundingClientRect().width-nativeWidth)<1,'native glyph width');
                    check(s.fontWeight==='400','regular prose');
                    check(s.color===ink,'shared body ink: '+s.color+' vs '+ink);
                    for(const n of root.querySelectorAll('a,mark,strong,em')) {
                        const t=getComputedStyle(n);check(t.fontSize===s.fontSize && t.lineHeight===s.lineHeight,'inline size/rhythm');
                    }
                    check(getComputedStyle(root.querySelector('mark')).fontWeight==='600','tag emphasis');
                    check(getComputedStyle(root.querySelector('strong')).fontWeight>=600,'bold emphasis');
                    check(parseFloat(getComputedStyle(root.querySelector('h2')).fontSize)>size,'heading hierarchy');
                    check(getComputedStyle(root.querySelector('code')).fontFamily.includes('monospace'),'code family');
                    const r=document.createRange();r.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(r);
                    const before=getSelection().toString();chatStyle(style);check(getSelection().toString()===before,'style retains range');
                    return {size:s.fontSize,line:s.lineHeight,color:s.color,nativeStep:step};
                    """, arguments: ["style":style,"size":expected,"nativeWidth":nativeWidth,"step":step,"ink":rgb(muted ? ChatTextPalette.muted(dark) : ChatTextPalette.foreground(dark))], contentWorld: .page)
                    print("Matching typography scale=\(scale) dark=\(dark) muted=\(muted): \(String(describing: report))")
                }
            }
        }
        _ = try await web.callAsyncJavaScript("chatContent(html)", arguments:["html":fixture], contentWorld:.page)
        let result = try await web.callAsyncJavaScript("""
        const check=(ok,msg)=>{if(!ok) throw Error(msg)};
        const root=document.getElementById('message'), original=root.innerHTML;
        const select=(a,ai,b,bi)=>{const r=document.createRange(); r.setStart(a,ai);r.setEnd(b,bi);getSelection().removeAllRanges();getSelection().addRange(r)};
        const ps=root.querySelectorAll(':scope>p');
        select(ps[0].firstChild,6,ps[1].firstChild,16);
        let clip=chatClipboard();
        check(clip.text.startsWith('bold paragraph with emoji 🪴'),'partial paragraph starts exactly after First');
        check(clip.text.endsWith('Second paragraph'),'cross paragraph endpoint exact');
        check(clip.html.includes('<strong>bold</strong>') && clip.html.includes('https://example.com/ref'),'inline format and link preserved');
        const cells=root.querySelectorAll('td');
        select(cells[0].firstChild,2,cells[5].firstChild,2);
        clip=chatClipboard();
        check(clip.text==='tch A\\t600\\t30 June\\nCatch-up B\\t450\\t31','partial table cells/rows are TSV: '+JSON.stringify(clip.text));
        check(clip.html.includes('<table>') && clip.html.includes('<tr>') && clip.html.includes('<td>') && clip.html.includes('<strong>600</strong>'),'partial table rich structure');
        // Paragraph -> table -> paragraph is one continuous range in either direction.
        select(ps[1].firstChild,7,ps[2].firstChild,11);
        clip=chatClipboard();
        check(clip.text.startsWith('paragraph before the table.') && clip.text.endsWith('After table'),'prose table prose exact');
        check(clip.text.includes('Contributor\\tQuantity\\tDate\\nBatch A\\t600\\t30 June'),'table boundaries inside larger selection');
        const before=getSelection().toString();
        chatContent(original+'<p>Streaming append.</p>');
        check(getSelection().toString()===before,'streaming append preserves active range');
        chatStyle({size:24,lineHeight:32,weight:400,dark:true,foreground:'#f5f3fc',link:'#8cc4ff'});
        check(getSelection().toString()===before,'text scale and theme preserve range');
        check(getComputedStyle(document.documentElement).colorScheme==='dark','dark mode');
        check(getComputedStyle(document.documentElement).fontSize==='24px','text scale');
        root.querySelector('button').click();
        root.querySelector('a').click();
        const r=document.createRange();r.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(r);
        clip=chatClipboard();
        check(clip.text.includes('Final paragraph remains reachable.') && clip.text.includes('print(value)'),'near full message and code selected');
        check(!clip.text.includes('swiftCopy') && !clip.html.includes('data-no-copy'),'toolbar excluded');
        chatContent(original);
        const range=document.createRange();range.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(range);
        window.expectedClipboard=chatClipboard();
        return {characters:expectedClipboard.text.length,height:root.getBoundingClientRect().height};
        """, arguments:[:],contentWorld:.page)
        print("DOM range checks: \(String(describing:result))")
        // Real trusted responder copy writes the system pasteboard, unlike a synthetic DOM copy event.
        let copyAction = #selector(NSText.copy(_:))
        func copyResponder(_ view: NSView) -> NSView? {
            if view.responds(to: copyAction) { return view }
            return view.subviews.compactMap(copyResponder).first
        }
        let responder = copyResponder(web)
        print("Copy responder: \(String(describing:responder))")
        window.makeFirstResponder(responder ?? web)
        print("Clear clipboard")
        NSPasteboard.general.clearContents()
        print("Send native copy")
        let copied = NSApp.sendAction(copyAction,to:responder,from:nil)
        print("Native copy dispatched")
        try await Task.sleep(for:.milliseconds(300))
        let expected = try await web.evaluateJavaScript("expectedClipboard.text") as? String
        guard copied, NSPasteboard.general.string(forType:.string) == expected else {
            throw NSError(domain:"Native clipboard mismatch",code:1,userInfo:[NSLocalizedDescriptionKey:"Responder=\(copied), types=\(String(describing:NSPasteboard.general.types)), actual=\(String(describing:NSPasteboard.general.string(forType:.string)))"])
        }
        guard let rich = NSPasteboard.general.string(forType:.html), rich.contains("<table>"), rich.contains("<strong>600</strong>") else {
            throw NSError(domain:"Native HTML missing table/style",code:2)
        }
        guard messages.values.contains(where: { $0["type"] as? String == "code" && ($0["text"] as? String)?.contains("print(value)") == true }),
              messages.values.contains(where: { $0["type"] as? String == "link" }),
              messages.values.contains(where: { $0["type"] as? String == "height" }) else { throw NSError(domain:"Bridge events missing",code:3) }
        print("Native pasteboard: exact plain text (\(expected?.count ?? 0) characters), HTML table/strong/link. Bridge: size, code, link.")
        for width in [280,390,800] {
            window.setContentSize(NSSize(width:width,height:1200))
            try await Task.sleep(for:.milliseconds(150))
            let metrics = try await web.callAsyncJavaScript("""
            chatStyle({size:17,lineHeight:23,weight:400,dark:false,foreground:'#10162b',link:'#0b5cc7'});
            const viewport=document.querySelector('.table-scroll'), table=document.querySelector('table');
            if(document.documentElement.scrollWidth>innerWidth+1) throw Error('message exceeds viewport');
            if(innerWidth===280) {viewport.scrollLeft=100; if(viewport.scrollLeft===0) throw Error('table cannot scroll horizontally')}
            return {width:innerWidth,height:document.getElementById('message').getBoundingClientRect().height,tableWidth:table.offsetWidth,tableViewport:viewport.clientWidth,tableScroll:viewport.scrollLeft};
            """,arguments:[:],contentWorld:.page)
            print("Sizing: \(String(describing:metrics))")
        }
        window.close()
    }
}
