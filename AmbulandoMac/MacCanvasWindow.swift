import AmbulandoCore
import SwiftUI

/// One canvas in a window of its own, so it can sit beside the main window or fill a screen (full screen gives the board
/// and its live naplets the whole display). The window keeps its own navigation: an item opened from the board (a
/// document, a task, an Excalidraw board) opens in this window, with Back to the board. A conversation opens in the main
/// window's thread view, which comes forward; a linked canvas opens in another window.
struct MacCanvasWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let route: CanvasWindowRoute?
    @State private var path: [WorkRoute] = []

    var body: some View {
        Group {
            if let route, let workspace = model.selectedWorkspace, workspace.id == route.workspaceId, let store = model.store {
                NavigationStack(path: Binding(get: { path }, set: { path = absorbing($0) })) {
                    CanvasBoardView(canvasId: route.canvasId, workspace: workspace, store: store)
                        .navigationDestination(for: WorkRoute.self) { WorkDestination(route: $0) }
                }
                .environment(\.pushRoute, PushRouteAction { next in path = absorbing(path + [next]) })
                .environment(\.openMention, OpenMentionAction { kind, id in
                    model.openRecord(kind: kind, id: id)
                    openWindow(id: MacWindow.main)
                })
                .environment(\.openURL, OpenURLAction { model.browser.handleLink($0) })
            } else if route == nil || model.selectedWorkspace == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Canvas from another workspace", systemImage: "rectangle.3.group",
                                       description: Text("Switch to its workspace in the main window to open it here."))
            }
        }
        .background(Amb.background)
        .imageLightboxHost()
    }

    /// Conversations open in the main window's thread view and other canvases in their own windows; anything else is
    /// pushed in this window.
    private func absorbing(_ next: [WorkRoute]) -> [WorkRoute] {
        var kept = next
        if case .canvas(let workspace, let canvas)? = kept.last {
            kept.removeLast()
            if canvas != route?.canvasId { openWindow(id: MacWindow.canvas, value: CanvasWindowRoute(workspaceId: workspace, canvasId: canvas)) }
        }
        if let focus = kept.lazy.compactMap(ThreadFocus.init).last {
            kept.removeAll { ThreadFocus($0) != nil }
            model.focusThread(focus)
            openWindow(id: MacWindow.main)
        }
        return kept
    }
}
