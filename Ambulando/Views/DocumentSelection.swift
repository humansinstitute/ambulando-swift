import AmbulandoCore
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

#if os(macOS)
import AppKit

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
            let sizes = DocumentEditorStyle.sizes()
            let size = sizes[heading == 0 ? "body" : heading == 1 ? "h1" : heading == 2 ? "h2" : "h3"]!
            var font = run.code ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: heading > 0 || run.bold ? .semibold : .regular)
            if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Amb.paperInk)]
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
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = DocumentTypography.lineSpacing
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        if context.coordinator.rendered != result {
            context.coordinator.rendered = result
            view.textStorage?.setAttributedString(result)
        }
        view.begin = { range in if let anchor = span.anchor(range, version: selection.version) { selection.begin(anchor) } }
        if let selected = selection.selected, let resolved = DocumentAnchors.resolve(selected, in: selection.spans), resolved.span.path == span.path {
            if view.selectedRange() != resolved.range { view.setSelectedRange(resolved.range) }
        }
        if selection.selected == nil, let previous = context.coordinator.revealed,
           let found = DocumentAnchors.resolve(previous, in: selection.spans), found.span.path == span.path,
           view.selectedRange() == found.range { view.setSelectedRange(NSRange(location: found.range.location, length: 0)) }
        context.coordinator.revealed = selection.selected
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectionTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let rect = nsView.attributedString().boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: max(22 * textScale, ceil(rect.height)))
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentSelectableText
        var rendered: NSAttributedString?
        var revealed: DocumentAnchor?
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

#if os(iOS)
import UIKit

struct DocumentSelectableText: UIViewRepresentable {
    let runs: [InlineRun]
    let span: DocumentTextSpan
    let selection: DocumentSelectionContext
    var heading = 0
    @Environment(\.openURL) private var openURL
    private let textScale = TextScale.shared.factor

    func makeUIView(context: Context) -> DocumentSelectionTextView {
        let view = DocumentSelectionTextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "doc.selectable.\(span.path.map(String.init).joined(separator: "."))"
        return view
    }
    func updateUIView(_ view: DocumentSelectionTextView, context: Context) {
        context.coordinator.parent = self
        let result = NSMutableAttributedString()
        for run in runs {
            let sizes = DocumentEditorStyle.sizes()
            let size = sizes[heading == 0 ? "body" : heading == 1 ? "h1" : heading == 2 ? "h2" : "h3"]!
            var font = run.code ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular) : UIFont.systemFont(ofSize: size, weight: heading > 0 || run.bold ? .semibold : .regular)
            if run.italic, let descriptor = font.fontDescriptor.withSymbolicTraits([font.fontDescriptor.symbolicTraits, .traitItalic]) { font = UIFont(descriptor: descriptor, size: size) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(Amb.paperInk)]
            if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, let url = URL(string: link), (RichLinks.isSafeWeb(url) || (url.scheme == nil && url.host == nil && url.path == "/canvas.html")) { attrs[.link] = url }
            if let kind = run.mentionKind, let id = run.mentionId { attrs[.link] = RichLinks.mentionURL(kind: kind, id: id) }
            if let wiki = run.wiki, let url = RichLinks.wikiURL(wiki) { attrs[.link] = url }
            result.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        if view.attributedText != result { view.attributedText = result }
        view.begin = { range in if let anchor = span.anchor(range, version: selection.version) { selection.begin(anchor) } }
        if let selected = selection.selected, let found = DocumentAnchors.resolve(selected, in: selection.spans), found.span.path == span.path, view.selectedRange != found.range { view.selectedRange = found.range }
        if selection.selected == nil, let previous = context.coordinator.revealed,
           let found = DocumentAnchors.resolve(previous, in: selection.spans), found.span.path == span.path,
           view.selectedRange == found.range { view.selectedRange = NSRange(location: found.range.location, length: 0) }
        context.coordinator.revealed = selection.selected
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DocumentSelectionTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: DocumentSelectableText
        var revealed: DocumentAnchor?
        init(_ parent: DocumentSelectableText) { self.parent = parent }
        func textViewDidChangeSelection(_ textView: UITextView) { (textView as? DocumentSelectionTextView)?.updateButton() }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool { parent.openURL(URL); return false }
    }
}

final class DocumentSelectionTextView: UITextView {
    var begin: ((NSRange) -> Void)?
    private var displayLink: CADisplayLink?
    private lazy var commentButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "text.bubble"), for: .normal)
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 22
        button.accessibilityLabel = "Comment on selected text"
        button.accessibilityIdentifier = "doc.selection.comment"
        button.addTarget(self, action: #selector(comment), for: .touchUpInside)
        return button
    }()
    func updateButton() {
        guard isFirstResponder, selectedRange.length > 0, let range = selectedTextRange, let window else {
            commentButton.removeFromSuperview(); displayLink?.invalidate(); displayLink = nil; return
        }
        // A table cell can be shorter than the 44pt touch target. Float in the
        // window so the control never clips or changes the cell's measured size.
        if commentButton.superview !== window { window.addSubview(commentButton) }
        var viewport = window.bounds.inset(by: window.safeAreaInsets)
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds { viewport = viewport.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        let rect = convert(firstRect(for: range), to: window)
        commentButton.isHidden = !rect.intersects(viewport) || viewport.width < 44 || viewport.height < 44
        if !commentButton.isHidden {
            commentButton.frame = CGRect(x: max(viewport.minX, min(viewport.maxX - 44, convert(bounds, to: window).maxX - 44)),
                y: max(viewport.minY, min(viewport.maxY - 44, rect.minY)), width: 44, height: 44)
        }
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(viewportChanged))
            link.add(to: .main, forMode: .common); displayLink = link
        }
    }
    @objc private func viewportChanged() { updateButton() }
    override func layoutSubviews() { super.layoutSubviews(); updateButton() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { commentButton.removeFromSuperview(); displayLink?.invalidate(); displayLink = nil } }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { commentButton.removeFromSuperview(); displayLink?.invalidate(); displayLink = nil }
        return result
    }
    @objc private func comment() { begin?(selectedRange) }
}
#endif
