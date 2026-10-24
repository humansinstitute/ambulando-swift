import SwiftUI
import UIKit

/// Ambulando "perspective passage" tokens, copied from sol/src/ambulando-tokens.css (light / dark).
enum Amb {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let background = dynamic(0xF6F6FA, 0x10162B)
    static let foreground = dynamic(0x10162B, 0xF5F3FC)
    static let card = dynamic(0xFFFFFF, 0x1A2238)
    static let muted = dynamic(0xEEEFF5, 0x26314A)
    static let mutedForeground = dynamic(0x596174, 0xBDC4D6)
    static let border = dynamic(0xD7D9E2, 0x48546D)
    static let primary = dynamic(0x2B1B3C, 0xCBB8FF)
    static let primaryForeground = dynamic(0xFFFFFF, 0x20123C)
    static let itemHeading = primary
    static let accent = dynamic(0xEEE8FA, 0x302447)
    static let accentForeground = dynamic(0x2B1B3C, 0xE5DAFF)
    static let destructive = dynamic(0xB42318, 0xFCA59D)
    static let destructiveBackground = dynamic(0xFEECEB, 0x411710)
    static let success = dynamic(0x25613E, 0xA4D1B5)
    static let successBackground = dynamic(0xE6F2E9, 0x203D2C)
    static let warning = dynamic(0x805400, 0xF3CF80)
    static let warningBackground = dynamic(0xFFF3D6, 0x40331C)
    static let info = dynamic(0x215C85, 0xADD2F0)
    static let infoBackground = dynamic(0xE8F1F9, 0x20384C)
    static let brandOrange = Color(UIColor(hex: 0xBF4D0D))
    static let brandNavy = Color(UIColor(hex: 0x10162B))

    static let radiusPanel: CGFloat = 10      // --radius-panel 0.625rem
    static let radiusControl: CGFloat = 6     // --radius-control 0.375rem
    static let touchTarget: CGFloat = 44      // --touch-target 2.75rem

    static let editorial = Font.system(.title2, design: .serif).weight(.semibold)   // --font-editorial
    static let heading = Font.headline
    static let code = Font.system(.footnote, design: .monospaced)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Approved passage artwork on its original white backing (never recoloured or clipped).
struct PassageMark: View {
    var size: CGFloat = 32
    var body: some View {
        Image("PassageMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
            .accessibilityLabel("Ambulando")
    }
}

struct BrandHeader: View {
    var subtitle: String?
    var body: some View {
        VStack(spacing: 12) {
            PassageMark(size: 64)
            Text("Ambulando").font(.system(.largeTitle, design: .serif).weight(.semibold)).foregroundStyle(Amb.foreground)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Amb.mutedForeground).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: Amb.touchTarget)
            .foregroundStyle(Amb.primaryForeground)
            .background(Amb.primary.opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: Amb.radiusControl, style: .continuous))
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel, style: .continuous).stroke(Amb.border, lineWidth: 1))
    }
}

extension View {
    func ambCard() -> some View { modifier(CardModifier()) }
}

/// Inline notice using the semantic status palettes.
struct Notice: View {
    enum Tone { case info, warning, error, success }
    let tone: Tone
    let text: String

    var body: some View {
        let (fg, bg, icon): (Color, Color, String) = switch tone {
        case .info: (Amb.info, Amb.infoBackground, "info.circle")
        case .warning: (Amb.warning, Amb.warningBackground, "exclamationmark.triangle")
        case .error: (Amb.destructive, Amb.destructiveBackground, "xmark.octagon")
        case .success: (Amb.success, Amb.successBackground, "checkmark.circle")
        }
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(fg)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg, in: RoundedRectangle(cornerRadius: Amb.radiusControl, style: .continuous))
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}
