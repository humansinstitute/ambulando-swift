import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The native body font is authoritative for both lightweight plain text and the selection document.
/// Resolve Dynamic Type from the view environment, including local overrides, rather than a size table.
@MainActor
struct NativeChatTypography {
    #if os(macOS)
    let nativeFont: NSFont
    #else
    let nativeFont: UIFont
    #endif
    let lineSpacing: CGFloat
    let lineHeight: CGFloat
    var pointSize: CGFloat { nativeFont.pointSize }
    var font: Font { Font(nativeFont) }

    init(scale: CGFloat = 1, typeSize: DynamicTypeSize = .large) {
        #if os(macOS)
        let preferred = NSFont.preferredFont(forTextStyle: .body)
        nativeFont = scale == 1 ? preferred : .systemFont(ofSize: preferred.pointSize * scale, weight: .regular)
        lineSpacing = 3 * scale
        // SwiftUI uses the native text bounds without the preferred font's extra leading.
        // Bounds also account for optical sizing; ascent/descent alone differ at some Mac scales.
        let bounds = NSAttributedString(string: "Body", attributes: [.font: nativeFont])
            .boundingRect(with: NSSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin])
        lineHeight = bounds.height - nativeFont.leading + lineSpacing
        #else
        let category: UIContentSizeCategory = switch typeSize {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        default: .accessibilityExtraExtraExtraLarge
        }
        nativeFont = .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        lineSpacing = 0
        lineHeight = nativeFont.lineHeight
        #endif
    }

    /// JSON is passed as one style value; updating it leaves the active DOM selection untouched.
    func webStyle(dark: Bool, muted: Bool) -> String {
        let value: [String: Any] = [
            "size": pointSize, "lineHeight": lineHeight, "weight": 400, "dark": dark,
            "foreground": ChatTextPalette.hex(muted ? ChatTextPalette.muted(dark) : ChatTextPalette.foreground(dark)),
            "link": ChatTextPalette.hex(ChatTextPalette.link(dark))
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    }
}

/// Shared with the SwiftUI theme so adding a mention cannot change the surrounding prose ink.
enum ChatTextPalette {
    static func foreground(_ dark: Bool) -> UInt32 { dark ? 0xF5F3FC : 0x10162B }
    static func muted(_ dark: Bool) -> UInt32 { dark ? 0xBDC4D6 : 0x596174 }
    static func link(_ dark: Bool) -> UInt32 { dark ? 0x8CC4FF : 0x0B5CC7 }
    static func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }
}
