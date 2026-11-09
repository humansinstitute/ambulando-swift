import Foundation

/// Native body, muted and link colors retained from the typography follow-up.
enum ChatTextPalette {
    static func foreground(_ dark: Bool) -> UInt32 { dark ? 0xF5F3FC : 0x10162B }
    static func muted(_ dark: Bool) -> UInt32 { dark ? 0xBDC4D6 : 0x596174 }
    static func link(_ dark: Bool) -> UInt32 { dark ? 0x8CC4FF : 0x0B5CC7 }
    static func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }
}
