import AppKit
import SwiftUI

/// AppKit owns mouse tracking inside the horizontal NSScrollView; SwiftUI plain/borderless
/// button gestures can lose the real mouse release there even when accessibility presses work.
struct MacStripButton: View {
    let title: String
    let image: String
    let selected: Bool
    let identifier: String
    var label: String? = nil
    let action: () -> Void
    var body: some View {
        MacStripTrackingButton(title: title, image: image, selected: selected, identifier: identifier, label: label, action: action)
            .accessibilityLabel(label ?? title)
            .accessibilityIdentifier(identifier)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct MacStripTrackingButton: NSViewRepresentable {
    let title: String
    let image: String
    let selected: Bool
    let identifier: String
    let label: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    final class TrackingButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func press(_ sender: NSButton) { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = TrackingButton(title: title, target: context.coordinator, action: #selector(Coordinator.press(_:)))
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.imagePosition = title.isEmpty ? .imageOnly : .imageAbove
        button.font = .systemFont(ofSize: 11, weight: .medium)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: selected ? .semibold : .regular)
        button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        button.state = selected ? .on : .off
        button.isEnabled = enabled
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label ?? title)
        button.toolTip = label ?? title
    }
}
