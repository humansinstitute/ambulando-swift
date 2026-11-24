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
    var width: CGFloat = 44
    let action: () -> Void
}

/// Keep both scrolling and button hit testing in AppKit, rather than crossing a SwiftUI scroll host.
struct MacNavigationStrip: NSViewRepresentable {
    let controls: [MacNavigationControl]
    let route: SectionStripRoute
    var font: NSFont = .preferredFont(forTextStyle: .body)

    static func height(for font: NSFont = .preferredFont(forTextStyle: .body)) -> CGFloat {
        max(36, ceil(font.ascender - font.descender) + 12)
    }
    var rowHeight: CGFloat { Self.height(for: font) }
    private func width(for control: MacNavigationControl) -> CGFloat {
        max(control.width, control.title.isEmpty ? 36 : ceil((control.title as NSString).size(withAttributes: [.font: font]).width) + 42)
    }

    final class Button: NSButton {
        var invoke: (() -> Void)?
        let spinner = NSProgressIndicator()
        // NSButton's symbol-dependent alignment insets make equal Auto Layout heights
        // produce unequal physical frames, extending beyond the strip's clip view.
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc func press() { invoke?() }
    }
    final class Cell: NSButtonCell {
        override func imageRect(forBounds rect: NSRect) -> NSRect {
            guard let image else { return .zero }
            let scale = min(16 / max(image.size.width, 1), 16 / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            return NSRect(x: title.isEmpty ? rect.midX - size.width / 2 : rect.minX + 10 + (16 - size.width) / 2,
                          y: rect.midY - size.height / 2, width: size.width, height: size.height)
        }
        override func titleRect(forBounds rect: NSRect) -> NSRect {
            let textFont = font ?? .preferredFont(forTextStyle: .body)
            let height = ceil(textFont.ascender - textFont.descender)
            return NSRect(x: rect.minX + 32, y: rect.midY - height / 2,
                          width: max(0, rect.width - 42), height: height)
        }
        override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
            let colour = (controlView as? NSButton)?.contentTintColor ?? .secondaryLabelColor
            let tint = isEnabled ? colour : colour.withAlphaComponent(0.4)
            image?.withSymbolConfiguration(.init(paletteColors: [tint]))?
                .draw(in: imageRect(forBounds: cellFrame), from: .zero, operation: .sourceOver,
                      fraction: isHighlighted ? 0.65 : 1, respectFlipped: true, hints: nil)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            (title as NSString).draw(in: titleRect(forBounds: cellFrame), withAttributes: [
                .font: font ?? NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: tint, .paragraphStyle: paragraph
            ])
        }
    }
    final class Coordinator {
        var route: SectionStripRoute?
        var buttons: [String: Button] = [:]
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> NSSize? {
        NSSize(width: proposal.width ?? 600, height: rowHeight)
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
        let previousOffset = scroll.contentView.bounds.origin
        let routeChanged = context.coordinator.route != route
        let ids = controls.map(\.id)
        if stack.arrangedSubviews.compactMap({ $0.identifier?.rawValue }) != ids {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            context.coordinator.buttons = [:]
            for control in controls {
                let button = Button(title: control.title, target: nil, action: nil)
                button.cell = Cell(textCell: control.title)
                button.target = button
                button.action = #selector(Button.press)
                button.setButtonType(.momentaryChange)
                button.isBordered = false
                button.imagePosition = control.title.isEmpty ? .imageOnly : .imageLeft
                button.font = font
                button.identifier = NSUserInterfaceItemIdentifier(control.id)
                button.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: width(for: control)),
                                             button.heightAnchor.constraint(equalToConstant: rowHeight)])
                button.spinner.style = .spinning
                button.spinner.controlSize = .small
                button.spinner.isDisplayedWhenStopped = false
                button.spinner.frame = NSRect(x: control.title.isEmpty ? (width(for: control) - 16) / 2 : 10, y: (rowHeight - 16) / 2, width: 16, height: 16)
                button.addSubview(button.spinner)
                stack.addArrangedSubview(button)
                context.coordinator.buttons[control.id] = button
            }
        }
        for control in controls {
            guard let button = context.coordinator.buttons[control.id] else { continue }
            button.font = font
            for constraint in button.constraints {
                if constraint.firstAttribute == .width { constraint.constant = width(for: control) }
                if constraint.firstAttribute == .height { constraint.constant = rowHeight }
            }
            button.spinner.frame = NSRect(x: control.title.isEmpty ? (width(for: control) - 16) / 2 : 10,
                                          y: (rowHeight - 16) / 2, width: 16, height: 16)
            button.invoke = control.action
            button.title = control.title
            button.image = control.busy ? nil : NSImage(systemSymbolName: control.image, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: control.selected ? .semibold : .regular))
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
        stack.frame = NSRect(x: 0, y: 0, width: controls.reduce(0) { $0 + width(for: $1) }, height: rowHeight)
        stack.layoutSubtreeIfNeeded()
        stack.setAccessibilityChildren(stack.arrangedSubviews)
        context.coordinator.route = route
        // Removing arranged controls can momentarily shrink the document. Restore the retained clip
        // position after layout, including refresh-result and optional-section changes on this route.
        scroll.contentView.scroll(to: routeChanged ? .zero : previousOffset)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
