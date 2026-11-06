import SwiftUI

/// The person's own text size for the whole app, on top of the device's Dynamic Type setting. "Device" follows the
/// system and allows every accessibility size; the others fix a comfortable floor for people who never changed it.
enum FamilyTextSize: String, CaseIterable, Identifiable {
    case device, large, larger, largest

    static let defaultsKey = "family.textSize"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .device: "Same as this device"
        case .large: "Large"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }

    /// Never smaller than the choice; never larger than the biggest accessibility size.
    var range: ClosedRange<DynamicTypeSize> {
        switch self {
        case .device: DynamicTypeSize.xSmall ... .accessibility5
        case .large: DynamicTypeSize.xLarge ... .accessibility5
        case .larger: DynamicTypeSize.xxxLarge ... .accessibility5
        case .largest: DynamicTypeSize.accessibility3 ... .accessibility5
        }
    }
}
