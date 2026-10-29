import AmbulandoCore
import SwiftUI

/// Keys the composer hands to the open mention list.
enum ComposerKey { case up, down, enter, tab, escape }

/// Picked people and agents drawn as inline pills inside the text: a tinted capsule-like background and the primary colour
/// on each `@Name`, while the characters stay ordinary text (so editing, undo and the structured mention stay in step).
enum MentionStyling {
    @MainActor
    static func apply(to storage: NSTextStorage, tokens: [String], base: PlatformColor, highlight: PlatformColor, fill: PlatformColor) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: base, range: full)
        let text = storage.string as NSString
        for token in Set(tokens) where !token.isEmpty {
            var search = NSRange(location: 0, length: text.length)
            while true {
                let found = text.range(of: token, options: [], range: search)
                if found.location == NSNotFound { break }
                let end = NSMaxRange(found)
                // Not a longer name (`@Rick` inside `@Rickety`).
                let trailing = end < text.length ? text.substring(with: NSRange(location: end, length: 1)) : " "
                if trailing.rangeOfCharacter(from: .alphanumerics) == nil {
                    storage.addAttributes([.backgroundColor: fill, .foregroundColor: highlight], range: found)
                }
                search = NSRange(location: end, length: text.length - end)
            }
        }
        storage.endEditing()
    }
}

/// A paste that became an attachment instead of text: the composer's text and selection are untouched, and Undo/Redo
/// remove and restore the attachment.
struct TextPasteResult {
    let undo: () -> Void
    let redo: () -> Void
}

/// Receives pasted (or dropped) text and its selection in the field; returns a result when it took the text as a file,
/// nil to let the text go in as usual.
typealias TextPasteHandler = (String, NSRange) -> TextPasteResult?

enum InlineLimit {
    /// Whether an edit replacing `replaced` with `insert` is allowed: any edit that does not grow the text, or one that
    /// stays within the inline limits. Counts are Unicode code points and UTF-8 bytes, as the policy defines them.
    static func allows(insert: String, replacing replaced: String, in current: String) -> Bool {
        let added = TextAttachmentPolicy.codePoints(insert), removed = TextAttachmentPolicy.codePoints(replaced)
        if added <= removed, insert.utf8.count <= replaced.utf8.count { return true }
        return TextAttachmentPolicy.typingFits(insert: insert, replacing: replaced, existingCodePoints: TextAttachmentPolicy.codePoints(current),
                                               existingUTF8Bytes: current.utf8.count)
    }
}

#if os(iOS)
import UIKit
import UniformTypeIdentifiers

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
    /// Hardware-keyboard keys while the mention list is open (`pickerOpen`); returns whether the key was used.
    var onPickerKey: ((ComposerKey) -> Bool)? = nil
    var pickerOpen = false
    /// `@Name` texts of the picked mentions, drawn as inline pills.
    var mentionTokens: [String] = []
    var onPasteText: TextPasteHandler? = nil
    /// Direct typing may not grow the text past the inline limit (10,000 characters).
    var limitsInline = false
    /// Text to put in at the caret once (for example a picked photo's upload placeholder), then cleared.
    var insertion: Binding<String?>? = nil
    /// Optional caret observation for content-field mention completion; chat retains its existing behavior.
    var selection: Binding<NSRange>? = nil

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
        view.onPasteText = onPasteText
        view.onPickerKey = onPickerKey
        view.pickerOpen = pickerOpen
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
        if let pending = insertion?.wrappedValue, !pending.isEmpty {
            // Inserted as typing is, so the composer hears it through the delegate and the caret ends after it.
            let binding = insertion
            DispatchQueue.main.async {
                binding?.wrappedValue = nil
                view.insertText(pending)
            }
        }
        styleMentions(view)
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

    fileprivate func styleMentions(_ textView: UITextView) {
        // Long pasted text is left alone unless a name was styled before (nothing to add or take away).
        guard let view = textView as? PasteAwareTextView, view.textStorage.length > 0, !mentionTokens.isEmpty || view.mentionStyled else { return }
        view.mentionStyled = !mentionTokens.isEmpty
        MentionStyling.apply(to: view.textStorage, tokens: mentionTokens, base: UIColor(Amb.foreground), highlight: UIColor(Amb.primary), fill: UIColor(Amb.accent))
        view.typingAttributes = [.font: view.font ?? UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor(Amb.foreground)]
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
            reportSelection(view)
            reporting = false
            (view as? PasteAwareTextView)?.refreshPlaceholder()
            parent.styleMentions(view)
        }

        func textViewDidChangeSelection(_ view: UITextView) { reportSelection(view) }

        private func reportSelection(_ view: UITextView) {
            guard let binding = parent.selection else { return }
            let selected = view.selectedRange
            // UIKit reports selection before finishing some keyboard/autocorrection edits. Do not cause a SwiftUI
            // update inside that transaction, or an older text snapshot can move the live caret mid-word.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, view.selectedRange == selected, view.text == self.parent.text,
                      binding.wrappedValue != selected else { return }
                binding.wrappedValue = selected
            }
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Composition (marked text) is never interrupted; a finished commit is the user's text.
            guard parent.limitsInline, view.markedTextRange == nil else { return true }
            let current = view.text ?? ""
            let ns = current as NSString
            guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return true }
            // A large block arriving as an edit (a drop, dictation, a service) is handled like a paste.
            if TextAttachmentPolicy.codePoints(text) > TextAttachmentPolicy.pasteFileThreshold,
               let result = parent.onPasteText?(text, range) {
                (view as? PasteAwareTextView)?.registerAttachmentUndo(result)
                return false
            }
            return InlineLimit.allows(insert: text, replacing: ns.substring(with: range), in: current)
        }

        func textViewDidBeginEditing(_ view: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ view: UITextView) { if parent.focused { parent.focused = false } }
    }
}

final class PasteAwareTextView: UITextView {
    var onPasteItems: (([NSItemProvider]) -> [String])?
    var onPasteText: TextPasteHandler?
    var onPickerKey: ((ComposerKey) -> Bool)?
    var pickerOpen = false
    var mentionStyled = false

    /// While the mention list is open a hardware keyboard's arrows, Return, Tab and Escape drive it.
    override var keyCommands: [UIKeyCommand]? {
        guard pickerOpen else { return super.keyCommands }
        let pairs: [(String, ComposerKey)] = [(UIKeyCommand.inputUpArrow, .up), (UIKeyCommand.inputDownArrow, .down), ("\r", .enter),
                                              ("\t", .tab), (UIKeyCommand.inputEscape, .escape)]
        return pairs.map { input, _ in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(pickerCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func pickerCommand(_ command: UIKeyCommand) {
        let key: ComposerKey?
        switch command.input {
        case UIKeyCommand.inputUpArrow: key = .up
        case UIKeyCommand.inputDownArrow: key = .down
        case "\r": key = .enter
        case "\t": key = .tab
        case UIKeyCommand.inputEscape: key = .escape
        default: key = nil
        }
        if let key { _ = onPickerKey?(key) }
    }
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
        if let onPasteItems, pasteboardOffersItems {
            let tokens = onPasteItems(UIPasteboard.general.itemProviders)
            if !tokens.isEmpty {
                // Through the normal text input path: replaces the selection, moves the caret after it, and can be undone.
                insertText(tokens.joined())
                delegate?.textViewDidChange?(self)
                return
            }
        }
        // Text is read only inside this explicit Paste. A long one becomes a file and the field is left as it is.
        if let onPasteText, isEditable, UIPasteboard.general.hasStrings {
            let pasteboard = UIPasteboard.general
            let exact = pasteboard.data(forPasteboardType: UTType.utf8PlainText.identifier).flatMap(TextAttachmentPolicy.exactUTF8)
            if let string = exact ?? pasteboard.string, let result = onPasteText(string, selectedRange) {
                registerAttachmentUndo(result)
                return
            }
        }
        super.paste(sender)
    }

    /// Undo removes the attachment a paste created; Redo brings it back (and registers Undo again).
    func registerAttachmentUndo(_ result: TextPasteResult) {
        undoManager?.registerUndo(withTarget: self) { view in
            result.undo()
            view.undoManager?.registerUndo(withTarget: view) { again in result.redo(); again.registerAttachmentUndo(result) }
            view.undoManager?.setActionName("Paste as Attachment")
        }
        undoManager?.setActionName("Paste as Attachment")
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
    /// Arrow, Return, Tab and Escape keys while the mention list is open; returns whether the key was used.
    var onPickerKey: ((ComposerKey) -> Bool)? = nil
    var pickerOpen = false
    /// `@Name` texts of the picked mentions, drawn as inline pills.
    var mentionTokens: [String] = []
    var onPasteText: TextPasteHandler? = nil
    var limitsInline = false
    var fixedHeight: CGFloat? = nil
    /// Text to put in at the caret once (for example a picked photo's upload placeholder), then cleared.
    var insertion: Binding<String?>? = nil
    /// Optional caret observation for content-field mention completion; chat retains its existing behavior.
    var selection: Binding<NSRange>? = nil
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
        view.onPasteText = onPasteText
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
        if let pending = insertion?.wrappedValue, !pending.isEmpty {
            let binding = insertion
            DispatchQueue.main.async {
                binding?.wrappedValue = nil
                view.insertText(pending, replacementRange: view.selectedRange())
            }
        }
        styleMentions(view)
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

    fileprivate func styleMentions(_ textView: NSTextView) {
        guard let view = textView as? PasteAwareTextView, let storage = view.textStorage, storage.length > 0, !mentionTokens.isEmpty || view.mentionStyled else { return }
        view.mentionStyled = !mentionTokens.isEmpty
        MentionStyling.apply(to: storage, tokens: mentionTokens, base: NSColor(Amb.foreground), highlight: NSColor(Amb.primary), fill: NSColor(Amb.accent))
        view.typingAttributes = [.font: view.font ?? NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor(Amb.foreground)]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let view = scroll.documentView as? NSTextView else { return nil }
        if let fixedHeight { return CGSize(width: width, height: fixedHeight) }
        let font = view.font ?? .preferredFont(forTextStyle: .body)
        return CGSize(width: width, height: context.coordinator.measurement.height(
            text: text, font: font, width: width, maxLines: Int(Self.maxLines)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let measurement = MacComposerMeasurement()
        var parent: ComposerTextView
        var reported: String
        var reporting = false
        init(parent: ComposerTextView) { self.parent = parent; reported = parent.text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            reported = view.string
            reporting = true
            parent.text = reported
            reportSelection(view)
            reporting = false
            parent.styleMentions(view)
            view.needsDisplay = true
            view.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            reportSelection(view)
        }

        private func reportSelection(_ view: NSTextView) {
            guard let binding = parent.selection else { return }
            let selected = view.selectedRange()
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, view.selectedRange() == selected, view.string == self.parent.text,
                      binding.wrappedValue != selected else { return }
                binding.wrappedValue = selected
            }
        }

        func textDidBeginEditing(_ notification: Notification) { if !parent.focused { parent.focused = true } }
        func textDidEndEditing(_ notification: Notification) { if parent.focused { parent.focused = false } }

        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard parent.limitsInline, let text, !view.hasMarkedText() else { return true }
            let current = view.string
            let ns = current as NSString
            guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return true }
            if TextAttachmentPolicy.codePoints(text) > TextAttachmentPolicy.pasteFileThreshold, let result = parent.onPasteText?(text, range) {
                (view as? PasteAwareTextView)?.registerAttachmentUndo(result)
                return false
            }
            return InlineLimit.allows(insert: text, replacing: ns.substring(with: range), in: current)
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if parent.pickerOpen, !view.hasMarkedText(), let onKey = parent.onPickerKey {
                let key: ComposerKey? = switch selector {
                case #selector(NSResponder.moveUp(_:)): .up
                case #selector(NSResponder.moveDown(_:)): .down
                case #selector(NSResponder.insertNewline(_:)): .enter
                case #selector(NSResponder.insertTab(_:)): .tab
                case #selector(NSResponder.cancelOperation(_:)): .escape
                default: nil
                }
                if let key, onKey(key) { return true }
            }
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
    var onPasteText: TextPasteHandler?
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var mentionStyled = false
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

    /// Pasted or dropped text that the composer takes as a file: the field keeps its text and selection.
    private func takeLongText(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable, let onPasteText else { return false }
        let exact = pasteboard.data(forType: .string).flatMap(TextAttachmentPolicy.exactUTF8)
        guard let string = exact ?? pasteboard.string(forType: .string), let result = onPasteText(string, selectedRange()) else { return false }
        registerAttachmentUndo(result)
        return true
    }

    func registerAttachmentUndo(_ result: TextPasteResult) {
        breakUndoCoalescing()
        undoManager?.registerUndo(withTarget: self) { view in
            result.undo()
            view.undoManager?.registerUndo(withTarget: view) { again in result.redo(); again.registerAttachmentUndo(result) }
            view.undoManager?.setActionName("Paste as Attachment")
        }
        undoManager?.setActionName("Paste as Attachment")
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
        if !insertUploads(from: .general), !takeLongText(from: .general) { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if !insertUploads(from: .general), !takeLongText(from: .general) { super.pasteAsPlainText(sender) }
    }

    override func pasteAsRichText(_ sender: Any?) {
        if !insertUploads(from: .general), !takeLongText(from: .general) { super.pasteAsRichText(sender) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if insertUploads(from: sender.draggingPasteboard) { return true }
        if takeLongText(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }
}
#endif
