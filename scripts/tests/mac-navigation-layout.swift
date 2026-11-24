// Standalone regression over the production NSViewRepresentable and real AppKit layout.
// swiftc -parse-as-library AmbulandoMac/MacNavigationStrip.swift scripts/tests/mac-navigation-layout.swift -o build/mac-navigation-layout
// build/mac-navigation-layout
import AppKit
import SwiftUI

// Route identity is supplied by AppModel in the app; this harness needs no account or store.
struct SectionStripRoute: Equatable { }

@main struct NavigationLayoutCheck {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        var clicks = 0
        // Sidebar toggle first, then Home, then the sections; no refresh control in the strip.
        let symbols = [("", "sidebar.left"), ("Home", "globe"), ("Deck", "rectangle.3.group"),
                       ("Tasks", "checklist"), ("Artefacts", "doc.text"), ("Files", "folder"),
                       ("Toolbox", "wrench.and.screwdriver")]
        for width in [390.0, 1200.0] {
            for dark in [false, true] {
                for busy in [false, true] {
                    let controls = symbols.enumerated().map { index, pair in
                        MacNavigationControl(id: String(index), title: pair.0, image: pair.1,
                                             selected: index == 2, busy: busy && index == 0, action: { clicks += 1 })
                    }
                    let host = NSHostingView(rootView: MacNavigationStrip(controls: controls, route: SectionStripRoute()).frame(width: width, height: 56))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 56),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.orderFront(nil)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    host.layoutSubtreeIfNeeded()
                    var buttons: [NSButton] = []
                    func walk(_ view: NSView) {
                        if let button = view as? NSButton { buttons.append(button) }
                        view.subviews.forEach(walk)
                    }
                    walk(host)
                    precondition(buttons.count == controls.count, "All navigation controls must render")
                    precondition(buttons[2].state == .on, "Selected section must remain selected")
                    var titleY: CGFloat?, imageY: CGFloat?
                    for button in buttons {
                        let cell = button.cell as! NSButtonCell
                        precondition(button.frame.minY >= 0 && button.frame.maxY <= 56, "Navigation button clipped by strip")
                        let title = cell.titleRect(forBounds: button.bounds).offsetBy(dx: 0, dy: button.frame.minY)
                        let image = cell.imageRect(forBounds: button.bounds).offsetBy(dx: 0, dy: button.frame.minY)
                        if !button.title.isEmpty {
                            if let titleY { precondition(abs(title.minY - titleY) < 0.5, "Uneven navigation title baseline") }
                            titleY = title.minY
                            precondition(button.bounds.contains(cell.titleRect(forBounds: button.bounds)), "Clipped label")
                        }
                        if button.image != nil {
                            precondition(button.bounds.contains(cell.imageRect(forBounds: button.bounds)), "Clipped icon")
                            if let imageY { precondition(abs(image.midY - imageY) < 0.5, "Uneven icon row") }
                            imageY = image.midY
                        }
                        button.performClick(nil)
                    }
                    let busyButton = buttons[0] as! MacNavigationStrip.Button
                    if busy { precondition(abs(busyButton.spinner.frame.midY + busyButton.frame.minY - imageY!) < 0.5, "Busy indicator must share icon row") }
                    window.orderOut(nil)
                }
            }
        }
        precondition(clicks == symbols.count * 8, "Native actions must remain wired")
        print("PASS: native navigation clipping, common icon/title rows, busy indicator, selection and actions at narrow/wide widths in light/dark appearance")
    }
}
