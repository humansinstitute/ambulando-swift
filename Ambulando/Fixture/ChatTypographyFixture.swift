#if DEBUG && os(iOS)
import SwiftUI
import WebKit
import AmbulandoCore

/// Isolated native/WebKit comparison. Only the explicitly labelled fixture can expose these diagnostics.
struct ChatTypographyFixture: View {
    @State private var large = false
    @State private var result = "Checking"
    @State private var page = ChatSelectionPage()
    @State private var height: CGFloat = 200
    private let text = "Ordinary body text before a reference and after it.\nSecond line keeps the same rhythm."
    var body: some View {
        let type: DynamicTypeSize = large ? .accessibility3 : .large
        let typography = NativeChatTypography(typeSize: type)
        VStack {
            Text("Synthetic typography check. No live account.")
            Button(large ? "Use normal text" : "Use larger text") { large.toggle() }
                .accessibilityIdentifier("typography.scale")
            PlainChatSelection(text: text).dynamicTypeSize(type).frame(height: 180)
            ChatSelectionWeb(page: page, html: ChatSelectionHTML.blocks(MarkdownBlocks.parse("Ordinary body text before @[Agent](mention:agent:abc), @[Doc](mention:document:doc) and @[Task](mention:task:task). Read [link](https://example.com) and **bold**.")), typography: typography, dark: false, muted: false, onHeight: { height = $0 }, onLink: { _ in })
                .frame(height: height)
            Text(result).accessibilityIdentifier("typography.result")
        }
        .task(id: large) {
            result = "Checking"
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                if page.ready, let web = page.web {
                    // Inspect the actual production plain view and rich document, not a parallel size table.
                    @MainActor func plain(_ view: UIView) -> UITextView? {
                        if let text = view as? UITextView, text.accessibilityIdentifier == "chat.plain.selection" { return text }
                        return view.subviews.compactMap(plain).first
                    }
                    let category: UIContentSizeCategory = large ? .accessibilityExtraLarge : .large
                    let expected = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
                    if let native = web.window.flatMap(plain), native.font?.pointSize == expected.pointSize {
                        do {
                            let value = try await web.callAsyncJavaScript("""
                            const root=document.getElementById('message'), p=root.querySelector('p'), s=getComputedStyle(p);
                            const same=n=>getComputedStyle(n).fontSize===s.fontSize && getComputedStyle(n).lineHeight===s.lineHeight;
                            if(Math.abs(parseFloat(s.fontSize)-size)>.01 || Math.abs(parseFloat(s.lineHeight)-line)>.01) throw Error('native metrics mismatch');
                            if(s.color!=='rgb(16, 22, 43)' || s.fontWeight!=='400') throw Error('body ink/weight mismatch');
                            if(![...p.querySelectorAll('a,mark,strong')].every(same)) throw Error('inline metrics mismatch');
                            if(p.querySelectorAll('mark').length!==3) throw Error('agent/document/task mentions missing');
                            if(getComputedStyle(p.querySelector('strong')).fontWeight < 600) throw Error('bold lost');
                            const r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);
                            const before=getSelection().toString();chatStyle(style);
                            if(getSelection().toString()!==before || !chatClipboard().text.includes('Ordinary body')) throw Error('selection lost');
                            return 'PASS '+size+'pt line '+line;
                            """, arguments: ["size": expected.pointSize, "line": expected.lineHeight, "style": try JSONSerialization.jsonObject(with: Data(typography.webStyle(dark: false, muted: false).utf8))], contentWorld: .page)
                            result = value as? String ?? "FAIL result"
                            return
                        } catch { result = "FAIL \(error)"; return }
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            result = "FAIL timed out waiting for native views"
        }
    }
}
#endif
