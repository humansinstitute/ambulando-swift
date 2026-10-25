import AmbulandoCore
import SwiftUI
#if os(iOS)
import UIKit

/// The composer's text box: a text view that grows to six lines. Over SwiftUI's field it adds one thing: an explicit
/// Paste (edit menu or ⌘V) of images or files goes to `onPasteItems`, which returns the upload placeholders to insert
/// at the caret (sol `handleChatPaste`). Any other paste is the system's own text paste, unchanged. The clipboard is
/// never read except inside that Paste.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let plainKeyboard: Bool
    let onPasteItems: ([NSItemProvider]) -> [String]
    /// Return sends on the Mac; the iPhone keyboard's Return always inserts a new line.
    var onSubmit: (() -> Void)? = nil

    static let maxLines: CGFloat = 6

    func makeUIView(context: Context) -> PasteAwareTextView {
        let view = PasteAwareTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(Amb.foreground)
        view.tintColor = UIColor(Amb.primary)
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "composer.field"
        view.text = text
        view.placeholder = placeholder
        return view
    }

    func updateUIView(_ view: PasteAwareTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteItems = onPasteItems
        view.placeholder = placeholder
        // Only a change made outside the keyboard (a mention, a finished upload, a restored draft) is written back.
        // SwiftUI can update in the middle of a keystroke: before `textViewDidChange` reports the new character, or
        // inside the composer's change while it still holds the previous text. Writing that text back would drop the
        // character, so nothing is synced while the view is reporting, and the text it last reported is not written back.
        if !context.coordinator.reporting {
            if text != context.coordinator.reported, view.text != text {
                // Keep the caret in place.
                let old = view.text ?? "", selection = view.selectedRange
                view.text = text
                view.selectedRange = ComposerText.remap(selection, from: old, to: text)
                view.refreshPlaceholder()
                view.invalidateIntrinsicContentSize()
            }
            context.coordinator.reported = text
        }
        let correction: UITextAutocorrectionType = plainKeyboard ? .no : .default
        if view.autocorrectionType != correction {
            view.autocorrectionType = correction
            view.spellCheckingType = plainKeyboard ? .no : .default
            view.smartQuotesType = plainKeyboard ? .no : .default
            view.smartDashesType = plainKeyboard ? .no : .default
        }
        if focused, !view.isFirstResponder {
            DispatchQueue.main.async { if view.window != nil { view.becomeFirstResponder() } }
        } else if !focused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PasteAwareTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let line = (view.font ?? .preferredFont(forTextStyle: .body)).lineHeight
        let fitted = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let cap = ceil(line * Self.maxLines)
        let scrolls = fitted > cap
        if view.isScrollEnabled != scrolls { DispatchQueue.main.async { view.isScrollEnabled = scrolls } }
        return CGSize(width: width, height: min(max(fitted, ceil(line)), cap))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        /// The text last reported by the view or written to it (what the composer holds when nothing changed outside).
        var reported: String
        /// True while the view's own change is being handed to the composer.
        var reporting = false
        init(parent: ComposerTextView) { self.parent = parent; reported = parent.text }

        func textViewDidChange(_ view: UITextView) {
            reported = view.text ?? ""
            reporting = true
            parent.text = reported
            reporting = false
            (view as? PasteAwareTextView)?.refreshPlaceholder()
        }

        func textViewDidBeginEditing(_ view: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ view: UITextView) { if parent.focused { parent.focused = false } }
    }
}

final class PasteAwareTextView: UITextView {
    var onPasteItems: (([NSItemProvider]) -> [String])?
    private let placeholderLabel = UILabel()

    var placeholder: String {
        get { placeholderLabel.text ?? "" }
        set {
            guard placeholderLabel.text != newValue else { return }
            placeholderLabel.text = newValue
            accessibilityLabel = newValue
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = UIColor(Amb.mutedForeground)
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor),
            placeholderLabel.widthAnchor.constraint(lessThanOrEqualTo: frameLayoutGuide.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func refreshPlaceholder() { placeholderLabel.isHidden = !(text ?? "").isEmpty }

    override var text: String! {
        didSet { refreshPlaceholder() }
    }

    /// Only the pasteboard's has-flags are read here (they do not open its contents): Paste is offered for images,
    /// and for files (items that carry no text).
    private var pasteboardOffersItems: Bool {
        let pasteboard = UIPasteboard.general
        return pasteboard.hasImages || (pasteboard.numberOfItems > 0 && !pasteboard.hasStrings)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, onPasteItems != nil, pasteboardOffersItems { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard let onPasteItems, pasteboardOffersItems else { return super.paste(sender) }
        let tokens = onPasteItems(UIPasteboard.general.itemProviders)
        guard !tokens.isEmpty else { return super.paste(sender) }
        // Through the normal text input path: replaces the selection, moves the caret after it, and can be undone.
        insertText(tokens.joined())
        delegate?.textViewDidChange?(self)
    }
}
#else
import AppKit
import UniformTypeIdentifiers

/// The Mac composer's text box: an `NSTextView` that grows to six lines, then scrolls. Return sends and Shift-Return
/// (or Option-Return) starts a new line, as in desktop chat apps. Pasting or dropping images and files goes to
/// `onPasteItems` (the same upload path as the iPhone's Paste); text pastes are the system's own. The pasteboard is
/// read only inside an explicit Paste or drop.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let plainKeyboard: Bool
    let onPasteItems: ([NSItemProvider]) -> [String]
    var onSubmit: (() -> Void)? = nil
    var fixedHeight: CGFloat? = nil
    /// Read while the parent draws, so a text size change (`TextScale`) reaches `updateNSView`.
    private let textScale = TextScale.shared.factor

    static let maxLines: CGFloat = 6

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = PasteAwareTextView()
        view.delegate = context.coordinator
        view.font = TextScale.shared.nsFont(.body)
        view.textColor = NSColor(Amb.foreground)
        view.insertionPointColor = NSColor(Amb.primary)
        view.drawsBackground = false
        view.isRichText = false
        view.isAutomaticTextReplacementEnabled = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.setAccessibilityIdentifier("composer.field")
        view.string = text
        view.placeholder = placeholder
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? PasteAwareTextView else { return }
        context.coordinator.parent = self
        view.onPasteItems = onPasteItems
        view.onSubmit = onSubmit
        view.onFocusChange = { focused in
            DispatchQueue.main.async {
                if context.coordinator.parent.focused != focused { context.coordinator.parent.focused = focused }
            }
        }
        view.placeholder = placeholder
        let font = TextScale.shared.nsFont(.body)
        if view.font != font {
            view.font = font
            scroll.invalidateIntrinsicContentSize()
        }
        // As on the iPhone: only a change made outside typing (a mention, a finished upload, a restored draft) is
        // written back, so an update that arrives mid-keystroke never drops a character.
        if !context.coordinator.reporting {
            if text != context.coordinator.reported, view.string != text {
                let old = view.string, selection = view.selectedRange()
                view.string = text
                view.setSelectedRange(ComposerText.remap(selection, from: old, to: text))
                view.needsDisplay = true
            }
            context.coordinator.reported = text
        }
        view.isAutomaticSpellingCorrectionEnabled = !plainKeyboard
        view.isAutomaticQuoteSubstitutionEnabled = !plainKeyboard
        view.isAutomaticDashSubstitutionEnabled = !plainKeyboard
        let exposed = !context.environment.behindModal
        if view.isAccessibilityElement() != exposed { view.setAccessibilityElement(exposed) }
        let isFirst = view.window?.firstResponder === view
        if focused, !isFirst {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if !focused, isFirst {
            DispatchQueue.main.async { view.window?.makeFirstResponder(nil) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let view = scroll.documentView as? NSTextView else { return nil }
        if let fixedHeight { return CGSize(width: width, height: fixedHeight) }
        let font = view.font ?? .preferredFont(forTextStyle: .body)
        let line = font.ascender - font.descender + font.leading
        // Measure a detached string. Mutating the live text container during SwiftUI's speculative layout proposals
        // makes AppKit resize the text view and can cause an endless layout cycle when upload status appears.
        let measured = NSAttributedString(string: view.string.isEmpty ? " " : view.string, attributes: [.font: font])
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return CGSize(width: width, height: min(max(ceil(measured), ceil(line)), ceil(line * Self.maxLines)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var reported: String
        var reporting = false
        init(parent: ComposerTextView) { self.parent = parent; reported = parent.text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            reported = view.string
            reporting = true
            parent.text = reported
            reporting = false
            view.needsDisplay = true
            view.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textDidBeginEditing(_ notification: Notification) { if !parent.focused { parent.focused = true } }
        func textDidEndEditing(_ notification: Notification) { if parent.focused { parent.focused = false } }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                view.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            // Return while choosing a mention or composing (marked text) behaves as usual.
            guard !view.hasMarkedText(), let onSubmit = parent.onSubmit else { return false }
            onSubmit()
            return true
        }
    }
}

final class PasteAwareTextView: NSTextView {
    var onPasteItems: (([NSItemProvider]) -> [String])?
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(self) }
        else { super.setAccessibilityFocused(false) }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            setAccessibilityLabel(placeholder)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.preferredFont(forTextStyle: .body),
                                                         .foregroundColor: NSColor(Amb.mutedForeground)]
        NSAttributedString(string: placeholder, attributes: attributes).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height))
    }

    /// Images and files on a pasteboard, as item providers for the upload path (empty: nothing but text).
    static func providers(from pasteboard: NSPasteboard) -> [NSItemProvider] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap { NSItemProvider(contentsOf: $0) }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) {
                let uti = type == .png ? UTType.png : UTType.tiff
                return [NSItemProvider(item: data as NSData, typeIdentifier: uti.identifier)]
            }
        }
        return []
    }

    private func insertUploads(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable, let onPasteItems else { return false }
        let providers = Self.providers(from: pasteboard)
        guard !providers.isEmpty else { return false }
        let tokens = onPasteItems(providers)
        guard !tokens.isEmpty else { return false }
        // Through the normal text input path: replaces the selection, moves the caret after it, and can be undone.
        insertText(tokens.joined(), replacementRange: selectedRange())
        return true
    }

    // AppKit disables Paste for an image-only clipboard in a plain-text NSTextView before dispatching paste(_:).
    // Keep the action available without inspecting the clipboard; the explicit action decides attachment vs text.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v", isEditable, window?.firstResponder === self {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action, [#selector(paste(_:)), #selector(pasteAsPlainText(_:)), #selector(pasteAsRichText(_:))].contains(action), isEditable, onPasteItems != nil { return true }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, onPasteItems != nil { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        if !insertUploads(from: .general) { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if !insertUploads(from: .general) { super.pasteAsPlainText(sender) }
    }

    override func pasteAsRichText(_ sender: Any?) {
        if !insertUploads(from: .general) { super.pasteAsRichText(sender) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if insertUploads(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }
}
#endif
