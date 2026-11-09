import AmbulandoCore
import Foundation
import WebKit
import CoreGraphics

/// Exports saved document content without mounting an editor or acquiring an edit lease.
enum DocumentExport {
    static func markdown(title: String, body: DocumentBody) -> Data {
        Data(("# \(title)\n\n" + body.markdown).utf8)
    }

    enum Failure: LocalizedError {
        case renderer, timeout, image, tooLarge, pdf
        var errorDescription: String? {
            switch self {
            case .renderer: "The bundled document renderer could not load."
            case .timeout: "The document renderer timed out. Please try again."
            case .image: "An image could not be loaded. Download it and try exporting again."
            case .tooLarge: "This document is too large to export as PDF on this device."
            case .pdf: "The PDF could not be created."
            }
        }
    }

    /// Uses the same restricted local renderer as native editing. Stored images are supplied by the caller's
    /// authenticated cache; this page has no network or signing authority. Every output page has A4 bounds.
    @MainActor static func pdf(title: String, body: DocumentBody,
                              imageResolver: ((String) async -> String?)? = nil) async throws -> Data {
        guard BoardEditorBundle.available else { throw Failure.renderer }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(BoardSchemeHandler(), forURLScheme: BoardEditorBundle.scheme)
        config.userContentController.addUserScript(WKUserScript(source:
            "window.webkit.messageHandlers.document={postMessage:()=>{}};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 523, height: 770), configuration: config)
        web.load(URLRequest(url: URL(string: "ambulando-board://editor/document.html")!))
        defer { web.stopLoading() }
        var ready = false
        for _ in 0..<150 {
            try Task.checkCancellation()
            if (try? await web.evaluateJavaScript("!!window.ambulandoDocument")) as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { throw Failure.timeout }
        let payload: String
        if let state = body.editorState {
            payload = JSONValue.object([("mode", .string("rich")), ("state", state)]).serializedString()
        } else {
            payload = JSONValue.object([("mode", .string("markdown")), ("markdown", .string(body.markdown))]).serializedString()
        }
        _ = try await web.callAsyncJavaScript("""
            ambulandoDocument.load(payload);
            const root=document.querySelector('.ProseMirror');
            if(!root)throw Error('Missing document');
            root.editor.setEditable(false);
            // Freeze rendered content, excluding ProseMirror's src-less caret separator images. They are editor
            // machinery, not missing document images, and a live editor observer would recreate them if removed.
            const output=root.cloneNode(true);
            output.querySelectorAll('.ProseMirror-separator,.ProseMirror-trailingBreak').forEach(e=>e.remove());
            output.removeAttribute('contenteditable');root.replaceWith(output);
            const heading=document.createElement('h1');heading.textContent=title;
            output.parentElement.insertBefore(heading,output);
            const style=document.createElement('style');style.textContent=`
              html,body{width:523px!important;margin:0!important;padding:0!important;overflow:visible!important}
              #document-root{padding:0!important}
              .ProseMirror{min-height:0!important}
              .doc-rich-editor>h1{font-size:24px;line-height:1.25;margin:0 0 20px}
              .ProseMirror pre{white-space:pre-wrap!important;overflow:visible!important;word-break:break-word}
              .ProseMirror table{width:100%!important;table-layout:fixed!important}
              .ProseMirror img{max-width:100%!important;max-height:650px!important;object-fit:contain}
              .document-comment-action,.document-mention-picker{display:none!important}
            `;document.head.append(style);
            await new Promise(r=>setTimeout(r,50));
            return true;
            """, arguments: ["payload": payload, "title": title], contentWorld: .page)
        let imageIDs = try await web.evaluateJavaScript("JSON.stringify(Array.from(new Set(Array.from(document.querySelectorAll('img[data-fd-storage-object-id]'),i=>i.dataset.fdStorageObjectId))))")
        guard let imageIDs = imageIDs as? String, let imageIDData = imageIDs.data(using: .utf8),
              let ids = try JSONSerialization.jsonObject(with: imageIDData) as? [String] else { throw Failure.image }
        for id in ids {
            try Task.checkCancellation()
            guard let dataURL = await imageResolver?(id) else { throw Failure.image }
            let accepted = try await web.callAsyncJavaScript("return ambulandoDocument.setImage(id,url)",
                arguments: ["id": id, "url": dataURL], contentWorld: .page)
            guard accepted as? Bool == true else { throw Failure.image }
        }
        let imagesReady = try await web.callAsyncJavaScript("""
            await Promise.race([
              Promise.all(Array.from(document.images,i=>i.decode().catch(()=>{}))),
              new Promise(r=>setTimeout(r,5000))]);
            return Array.from(document.images).every(i=>i.complete&&i.naturalWidth>0);
            """, arguments: [:], contentWorld: .page)
        guard imagesReady as? Bool == true else { throw Failure.image }
        let cuts = try await web.callAsyncJavaScript("""
            // Bound image decoding; blocked/remote images must not turn into a successful but incomplete file.
            await document.fonts.ready;
            await new Promise(r=>setTimeout(r,50));
            const height=Math.ceil(document.querySelector('#document-root').getBoundingClientRect().bottom);
            if(height>770*250)throw Error('This document exceeds the 250-page PDF export limit.');
            // Protect ordinary blocks, table rows and images. Oversized paragraphs/rows fall back to line bounds.
            const blocks=Array.from(document.querySelectorAll('h1,h2,h3,h4,p,pre,blockquote,tr,img,li'))
              .map(e=>{const r=e.getBoundingClientRect();return {top:r.top,bottom:r.bottom}});
            const lines=[];const walker=document.createTreeWalker(document.querySelector('#document-root'),NodeFilter.SHOW_TEXT);
            while(walker.nextNode()){
              const node=walker.currentNode;if(!node.textContent.trim())continue;
              const range=document.createRange();range.selectNodeContents(node);
              for(const r of range.getClientRects())if(r.height>0)lines.push({top:r.top,bottom:r.bottom});
            }
            const cuts=[0];let y=0;
            while(y<height){
              let end=Math.min(y+770,height);
              for(const r of blocks)if(r.top>y+80&&r.top<end&&r.bottom>end&&r.bottom-r.top<690)end=r.top;
              for(const r of lines)if(r.top<end&&r.bottom>end&&r.top>y+1)end=r.top;
              if(end<=y+1)throw Error('Could not paginate document');
              cuts.push(end);y=end;
            }
            return cuts;
            """, arguments: [:], contentWorld: .page)
        guard let numbers = cuts as? [NSNumber], numbers.count > 1, numbers.count <= 251 else { throw Failure.tooLarge }
        let result = NSMutableData()
        guard let consumer = CGDataConsumer(data: result) else { throw Failure.pdf }
        var paper = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &paper, nil) else { throw Failure.pdf }
        for index in 1..<numbers.count {
            try Task.checkCancellation()
            let top = numbers[index-1].doubleValue, height = numbers[index].doubleValue - top
            let options = WKPDFConfiguration()
            options.rect = CGRect(x: 0, y: top, width: 523, height: height)
            let data = try await web.pdf(configuration: options)
            guard let provider = CGDataProvider(data: data as CFData), let source = CGPDFDocument(provider), let page = source.page(at: 1) else { throw Failure.pdf }
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 36, y: 842 - 36 - height)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return result as Data
    }
}
