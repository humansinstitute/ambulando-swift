import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The app's text size on the Mac (View › Increase Text Size, Decrease Text Size, Actual Text Size), kept across
/// launches. macOS SwiftUI ignores `dynamicTypeSize`, so the app's text styles go through `Font.amb(_:)`, which scales
/// the system size for each style; reading `factor` while a view draws makes that view redraw when it changes. On the
/// iPhone and iPad `Font.amb` is the plain text style, so Dynamic Type stays in charge there.
@MainActor
@Observable
final class TextScale {
    static let shared = TextScale()
    static let defaultsKey = "textScale"
    /// The sizes the menu steps through; 1 is the system size.
    static let steps: [CGFloat] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]

    private(set) var factor: CGFloat

    init(defaults: UserDefaults = .standard) {
        let saved = defaults.double(forKey: Self.defaultsKey)
        factor = Self.steps.contains(CGFloat(saved)) ? CGFloat(saved) : 1
    }

    var canIncrease: Bool { factor < Self.steps[Self.steps.count - 1] }
    var canDecrease: Bool { factor > Self.steps[0] }
    var isDefault: Bool { factor == 1 }

    func increase() { set(Self.steps.first { $0 > factor } ?? factor) }
    func decrease() { set(Self.steps.last { $0 < factor } ?? factor) }
    func reset() { set(1) }

    private func set(_ value: CGFloat) {
        guard value != factor else { return }
        factor = value
        UserDefaults.standard.set(Double(value), forKey: Self.defaultsKey)
    }

    #if os(macOS)
    /// The system point size of a text style at the current scale.
    func pointSize(_ style: Font.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style.appKit).pointSize * factor
    }

    /// AppKit text (composer, document selection) at the current scale.
    func nsFont(_ style: Font.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        factor == 1 && weight == .regular ? .preferredFont(forTextStyle: style.appKit) : .systemFont(ofSize: pointSize(style), weight: weight)
    }
    #endif
}

extension Font {
    /// A text style at the app's text size (see `TextScale`).
    @MainActor static func amb(_ style: Font.TextStyle, design: Font.Design? = nil) -> Font {
        #if os(macOS)
        let scale = TextScale.shared
        if scale.factor != 1 {
            return .system(size: scale.pointSize(style), weight: style == .headline ? .bold : .regular, design: design)
        }
        #endif
        return .system(style, design: design)
    }
}

#if os(macOS)
private extension Font.TextStyle {
    var appKit: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
#endif

extension View {
    /// Text without its own font (labels, fields, form rows, rich paragraphs) at the app's text size.
    func appTextSize() -> some View { modifier(AppTextSize(row: false)) }

    /// The same for a row of a Mac `List`, which draws rows in its own font: setting the font the window already has
    /// changes nothing there, so the row gets an equal-looking font value of its own.
    func appRowTextSize() -> some View { modifier(AppTextSize(row: true)) }
}

private struct AppTextSize: ViewModifier {
    let row: Bool
    func body(content: Content) -> some View { content.font(row ? .amb(.body).weight(.regular) : .amb(.body)) }
}
