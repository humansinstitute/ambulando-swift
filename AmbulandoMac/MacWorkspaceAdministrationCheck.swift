#if DEBUG
import AmbulandoCore
import AppKit
import SwiftUI

extension MacThreadRegression {
    static func workspaceAdministrationCheck(_ original: NSWindow, model: AppModel) async throws {
        guard model.fixture != nil, let workspace = model.selectedWorkspace, let connection = model.connection else { throw Failure(description: "Missing isolated sample workspace") }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1060, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Workspace administration · SAMPLE DATA"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        model.loadMembership(force: true)
        for section in WorkspaceManagementSection.allCases {
            window.contentView = NSHostingView(rootView:
                VStack(spacing: 0) {
                    Text("SAMPLE DATA · Isolated workspace administration check").font(.caption).padding(8)
                    WorkspaceManagementView(workspace: workspace, connection: connection, initialSection: section)
                }.environment(model).preferredColorScheme(.light))
            window.makeKeyAndOrderFront(nil)
            await settle(); await settle()
            try snapshot(window, model: model, name: "mac-workspace-\(section.rawValue)")
            try require(containsText(window, workspace.label), "selected workspace remains visible in \(section.rawValue)")
            window.setContentSize(NSSize(width: 800, height: 600)); await settle()
            try snapshot(window, model: model, name: "mac-workspace-\(section.rawValue)-narrow")
            window.setContentSize(NSSize(width: 1060, height: 760))
        }
        try require(model.selectedWorkspace?.id == workspace.id, "inspection preserves workspace")
        _ = original
    }
}
#endif
