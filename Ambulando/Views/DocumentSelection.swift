#if os(macOS)
import AmbulandoCore
import AppKit
import SwiftUI

struct DocumentSelectionContext {
    var spans: [DocumentTextSpan]
    var version: Int?
    var selected: DocumentAnchor?
    var begin: (DocumentAnchor) -> Void
}
extension EnvironmentValues {
    @Entry var documentSelection: DocumentSelectionContext? = nil
}

/// A small native bridge inside the existing rich block tree. It never edits or reserializes the source.
struct DocumentSelectableText: NSViewRepresentable {
    let runs: [InlineRun]
    let span: DocumentTextSpan
    let selection: DocumentSelectionContext
    var heading = 0
    /// Read while the parent draws, so a text size change (`TextScale`) redraws the text.
    private let textScale = TextScale.shared.factor
    @Environment(\.openURL) private var openURL
    func makeNSView(context: Context) -> SelectionTextView {
        let view = SelectionTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.drawsBackground = false; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false; view.isHorizontallyResizable = false
        view.delegate = context.coordinator
        view.setAccessibilityIdentifier("doc.selectable.\(span.path.map(String.init).joined(separator: "."))")
        return view
    }
    func updateNSView(_ view: SelectionTextView, context: Context) {
        context.coordinator.parent = self
        let result = NSMutableAttributedString()
        for run in runs {
            let size: CGFloat = (heading == 0 ? 15 : (heading == 1 ? 25 : 20)) * textScale
            var font = run.code ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: heading > 0 || run.bold ? .semibold : .regular)
            if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, let url = URL(string: link), (RichLinks.isSafeWeb(url) || (url.scheme == nil && url.host == nil && url.path == "/canvas.html")) {
                attrs[.link] = url
                attrs[.foregroundColor] = NSColor(Amb.link)
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if let kind = run.mentionKind, let id = run.mentionId { attrs[.link] = RichLinks.mentionURL(kind: kind, id: id) }
            if let wiki = run.wiki, let url = RichLinks.wikiURL(wiki) {
                attrs[.link] = url
                attrs[.foregroundColor] = NSColor(Amb.link)
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | (wiki.documentId == nil ? NSUnderlineStyle.patternDash.rawValue : 0)
            }
            result.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        if context.coordinator.rendered != result {
            context.coordinator.rendered = result
            view.textStorage?.setAttributedString(result)
        }
        view.begin = { range in if let anchor = span.anchor(range, version: selection.version) { selection.begin(anchor) } }
        if let selected = selection.selected, let resolved = DocumentAnchors.resolve(selected, in: selection.spans), resolved.span.path == span.path {
            if view.selectedRange() != resolved.range { view.setSelectedRange(resolved.range) }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectionTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let rect = nsView.attributedString().boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: max(22, ceil(rect.height)))
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentSelectableText
        var rendered: NSAttributedString?
        init(_ parent: DocumentSelectableText) { self.parent = parent }
        func textViewDidChangeSelection(_ notification: Notification) { (notification.object as? SelectionTextView)?.updateButton() }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { parent.openURL(url) }
            return true
        }
    }
}

final class SelectionTextView: NSTextView {
    var begin: ((NSRange) -> Void)?
    private var savedRange = NSRange(location: 0, length: 0)
    private lazy var addButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Comment on selected text")!, target: self, action: #selector(addComment))
        button.bezelStyle = .circular; button.refusesFirstResponder = true; button.setAccessibilityLabel("Comment on selection")
        button.setAccessibilityIdentifier("doc.selection.comment")
        addSubview(button); return button
    }()
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if !addButton.isHidden { children.append(addButton) }
        return children
    }
    override func setSelectedRange(_ charRange: NSRange) {
        super.setSelectedRange(charRange)
        updateButton()
    }
    func updateButton() {
        let range = selectedRange()
        addButton.isHidden = range.length == 0 || range.location == NSNotFound || NSMaxRange(range) > (string as NSString).length
        guard !addButton.isHidden, let layout = layoutManager, let container = textContainer else { return }
        savedRange = range
        let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let visible = visibleRect
        guard rect.intersects(visible), visible.width >= 28, visible.height > 0 else { addButton.isHidden = true; return }
        addButton.frame = NSRect(x: max(visible.minX, visible.maxX - 28), y: min(max(visible.minY, rect.minY), max(visible.minY, visible.maxY - 28)), width: 28, height: 28)
    }
    override func layout() { super.layout(); updateButton() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
    @objc private func viewportChanged() { updateButton() }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { addButton.isHidden = true }
        return result
    }
    @objc private func addComment() { begin?(savedRange) }
}
#endif
