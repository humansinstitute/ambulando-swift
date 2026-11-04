// Bundled native document editor typography and editing regression; local WebKit, no app account or network.
// scripts/build-board-editor.sh
// swiftc -parse-as-library scripts/tests/document-typography-webkit.swift -o /tmp/document-typography-check
// /tmp/document-typography-check <repo>/BoardEditor/dist <existing-output-directory>
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
      let mime =
        ["html": "text/html", "js": "text/javascript", "css": "text/css"][file.pathExtension]
        ?? "application/octet-stream"
      task.didReceive(
        URLResponse(
          url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
      task.didReceive(data)
      task.didFinish()
    } catch { task.didFailWithError(error) }
  }
  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@main struct TypographyCheck {
  @MainActor static func main() {
    let app = NSApplication.shared
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
      fputs("FAIL timeout\n", stderr)
      exit(1)
    }
    Task { @MainActor in
      do {
        try await run()
        exit(0)
      } catch {
        print("FAIL \(error)")
        exit(1)
      }
    }
    app.run()
  }
  @MainActor static func run() async throws {
    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(
      LocalEditor(URL(fileURLWithPath: CommandLine.arguments[1])), forURLScheme: "ambulando-board")
    config.userContentController.addUserScript(
      WKUserScript(
        source:
          "window.recordMessages=[]; window.webkit.messageHandlers.document={postMessage:v=>window.recordMessages.push(JSON.parse(v))};",
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 748, height: 800), configuration: config)
    let window = NSWindow(
      contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = web
    window.makeKeyAndOrderFront(nil)
    web.load(URLRequest(url: URL(string: "ambulando-board://editor/document.html")!))
    for _ in 0..<100 {
      if (try? await web.evaluateJavaScript("!!window.ambulandoDocument")) as? Bool == true {
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    for (width, factor, dark) in [(748, 1.0, false), (346, 1.0, false), (346, 1.5, true)] {
      web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.setContentSize(NSSize(width: width, height: 900))
      try await Task.sleep(for: .milliseconds(100))
      let result = try await web.callAsyncJavaScript(
        #"""
        const check=(ok,label)=>{if(!ok)throw Error(label)};
        const md='# A calm document heading\n\nReadable paragraphs and lists share one size and colour. Links and selections remain available.\n\n- Tight first item with enough words to wrap across a narrow phone viewport and retain its hanging indent.\n- Second tight item\n\n1. Loose ordered paragraph with enough words to wrap across a narrow phone viewport while keeping the marker with the first line.\n\n   A second paragraph in the same item.\n\n   - Nested unordered item with a long wrap that stays inside the page.\n   - Another nested item\n\n2. Second ordered paragraph\n\n## A smaller section heading\n\nA final paragraph with [a link](https://example.com).';
        ambulandoDocument.setStyle(JSON.stringify({body:15*factor,h1:22*factor,h2:19*factor,h3:16*factor,code:13*factor}));
        ambulandoDocument.load(JSON.stringify({mode:'markdown',markdown:md}));
        await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        const root=document.querySelector('.ProseMirror'),e=root.editor;
        check(root.querySelectorAll('li').length>=6,'tight loose nested lists loaded');
        const body=getComputedStyle(root.querySelector('p')).fontSize;
        check(body===`${15*factor}px`,'app text scale applied');
        check(getComputedStyle(root.querySelector('h1')).fontSize===`${22*factor}px`,'heading scales with body');
        check(getComputedStyle(root.querySelector('h2')).fontSize===`${19*factor}px`,'section heading scales with body');
        check(getComputedStyle(document.body).backgroundColor==='rgb(255, 255, 255)','paper remains light in dark chrome');
        check(root.querySelector('a')?.getAttribute('href')==='https://example.com','link identity retained');
        for(const li of root.querySelectorAll('li')) {
        const p=li.querySelector(':scope > p'); if(!p)continue;
        check(getComputedStyle(p).fontSize===body,'consistent list font');
        check(getComputedStyle(li.parentElement).listStylePosition==='outside','outside hanging marker');
        check(Math.abs(li.getBoundingClientRect().top-p.getBoundingClientRect().top)<1,'first paragraph aligned with marker row');
        check(p.getBoundingClientRect().right<=innerWidth+1,'wrap within viewport');
        }
        const times=[]; e.view.dom.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'insertText',data:' x'})); e.commands.focus();e.commands.setTextSelection(e.state.doc.content.size-1);
        for(let i=0;i<30;i++){const t=performance.now();e.commands.insertContent(' x');root.getBoundingClientRect();times.push(performance.now()-t)}
        e.commands.setTextSelection({from:1,to:8});await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));check(window.getSelection().toString().length>0,'selection works');
        const saved=ambulandoDocument.snapshot();check(saved,'snapshot preserves edit');
        ambulandoDocument.load(JSON.stringify({mode:'markdown',markdown:saved}));
        check(document.querySelector('.ProseMirror').textContent.includes(' x x'),'save/reopen edit');
        times.sort((a,b)=>a-b);
        return {width:innerWidth,body,items:root.querySelectorAll('li').length,typingP95:times[28],typingMax:times[29]};
        """#, arguments: ["factor": factor], contentWorld: .page)
      print("TYPOGRAPHY_WEBKIT_PASS \(String(describing: result))")
      let image = try await web.takeSnapshot(configuration: nil)
      let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
      try rep.representation(using: .png, properties: [:])!.write(
        to: URL(
          fileURLWithPath: CommandLine.arguments[2] + "/typography-editor-\(width)-\(factor).png"))
    }
    window.close()
  }
}
