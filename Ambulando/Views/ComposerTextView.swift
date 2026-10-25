import AmbulandoCore
import SwiftUI
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
