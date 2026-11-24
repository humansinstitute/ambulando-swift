import AppKit
import SwiftUI

struct MacNavigationControl {
    let id: String
    let title: String
    let image: String
    var label: String? = nil
    var selected = false
    var enabled = true
    var busy = false
    var width: CGFloat = 104
    let action: () -> Void
}

/// Keep both scrolling and button hit testing in AppKit, rather than crossing a SwiftUI scroll host.
struct MacNavigationStrip: NSViewRepresentable {
    let controls: [MacNavigationControl]
    let route: SectionStripRoute

    final class Button: NSButton {
        var invoke: (() -> Void)?
        let spinner = NSProgressIndicator()
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc func press() { invoke?() }
    }
    final class Coordinator {
        var route: SectionStripRoute?
        var buttons: [String: Button] = [:]
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> NSSize? {
        NSSize(width: proposal.width ?? 600, height: 56)
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.setAccessibilityLabel("Sections")
        scroll.setAccessibilityIdentifier("section.bar")
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.distribution = .fill
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        scroll.documentView = stack
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let stack = scroll.documentView as? NSStackView else { return }
        let ids = controls.map(\.id)
        if stack.arrangedSubviews.compactMap({ $0.identifier?.rawValue }) != ids {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            context.coordinator.buttons = [:]
            for control in controls {
                let button = Button(title: control.title, target: nil, action: nil)
                button.target = button
                button.action = #selector(Button.press)
                button.setButtonType(.momentaryChange)
                button.isBordered = false
                button.imagePosition = control.title.isEmpty ? .imageOnly : .imageAbove
                button.font = .systemFont(ofSize: 11, weight: .medium)
                button.identifier = NSUserInterfaceItemIdentifier(control.id)
                button.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: control.width),
                                             button.heightAnchor.constraint(equalToConstant: 54)])
                button.spinner.style = .spinning
                button.spinner.controlSize = .small
                button.spinner.isDisplayedWhenStopped = false
                button.spinner.frame = NSRect(x: (control.width - 16) / 2, y: 19, width: 16, height: 16)
                button.addSubview(button.spinner)
                stack.addArrangedSubview(button)
                context.coordinator.buttons[control.id] = button
            }
        }
        for control in controls {
            guard let button = context.coordinator.buttons[control.id] else { continue }
            button.invoke = control.action
            button.title = control.title
            button.image = control.busy ? nil : NSImage(systemSymbolName: control.image, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 20, weight: control.selected ? .semibold : .regular))
            button.contentTintColor = control.selected ? .controlAccentColor : .secondaryLabelColor
            button.state = control.selected ? .on : .off
            button.isEnabled = control.enabled
            button.toolTip = control.label ?? control.title
            button.setAccessibilityIdentifier(control.id)
            button.setAccessibilityLabel(control.label ?? control.title)
            button.setAccessibilityValue(control.selected ? 1 : 0)
            button.spinner.isHidden = !control.busy
            if control.busy { button.spinner.startAnimation(nil) } else { button.spinner.stopAnimation(nil) }
        }
        stack.frame = NSRect(x: 0, y: 0, width: controls.reduce(0) { $0 + $1.width }, height: 56)
        stack.layoutSubtreeIfNeeded()
        stack.setAccessibilityChildren(stack.arrangedSubviews)
        if context.coordinator.route != route {
            context.coordinator.route = route
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
