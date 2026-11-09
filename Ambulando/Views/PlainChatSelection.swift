import SwiftUI
#if os(iOS)
import UIKit

/// SwiftUI Text's iPhone selection does not provide a continuous native text range. A non-scrolling UITextView
/// gives plain messages the same standard long-press handles as rich messages without a web process per short row.
struct PlainChatSelection: UIViewRepresentable {
    let text: String
    var muted = false
    @Environment(\.dynamicTypeSize) private var typeSize
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "chat.plain.selection"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        view.font = NativeChatTypography(typeSize: typeSize).nativeFont
        view.textColor = UIColor(muted ? Amb.mutedForeground : Amb.foreground)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
#else
struct PlainChatSelection: View {
    let text: String
    var muted = false
    var body: some View {
        let typography = NativeChatTypography(scale: ChatTypography.scale)
        Text(verbatim: text).font(typography.font).foregroundStyle(muted ? Amb.mutedForeground : Amb.foreground)
            .textSelection(.enabled).lineSpacing(typography.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
