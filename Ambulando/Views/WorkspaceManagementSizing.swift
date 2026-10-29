import SwiftUI
#if os(macOS)
import AppKit

/// Apply at the management root, including when it is a sheet above Settings.
struct WorkspaceManagementSizing: ViewModifier {
    private var available: NSSize { NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 900) }
    func body(content: Content) -> some View {
        content
            .frame(minWidth: min(780, available.width - 48), idealWidth: min(1100, available.width - 48), maxWidth: .infinity,
                   minHeight: min(560, available.height - 80), idealHeight: min(780, available.height - 80), maxHeight: .infinity)
            .background(ManagementWindowSize())
    }
}
private struct ManagementWindowSize: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
    final class Probe: NSView {
        private weak var configured: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, configured !== window else { return }
            configured = window
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                // The fixture harness hosts this root in its own window and owns its dimensions.
                guard window.sheetParent != nil else { return }
                let screen = window.sheetParent?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
                window.styleMask.insert(.resizable)
                window.contentMinSize = NSSize(width: min(780, screen.width - 48), height: min(560, screen.height - 80))
                window.setContentSize(NSSize(width: min(1100, screen.width - 48), height: min(780, screen.height - 80)))
            }
        }
    }
}
#else
struct WorkspaceManagementSizing: ViewModifier {
    func body(content: Content) -> some View { content }
}
#endif
