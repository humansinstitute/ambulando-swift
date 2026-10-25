import AmbulandoCore
import SwiftUI

/// An Excalidraw board on a canvas as the web shows it: a window with the board's title, save status, options and
/// full-screen button over the live embedded editor (toolbar, drawing, Save, comments). The editor takes touches only
/// once the board is selected, so the canvas pans normally until then. A board that is too small on screen (or beyond
/// the live editor budget) shows the native preview instead, and becomes live when zoomed in or selected.
struct BoardNapletWindow: View {
    @Environment(AppModel.self) private var model
    let naplet: CanvasNaplet
    let reference: BoardReference
    let workspace: WorkspaceRecord
    let canvasId: String
    let preview: PreparedBoard?
    let selected: Bool
    /// Run the embedded editor (on screen, large enough, within the live budget).
    let live: Bool
    /// Moving or resizing items: the editor does not take touches.
    let layoutEditing: Bool
    let onSelect: () -> Void
    let onExpand: () -> Void
    @State private var session: BoardSession?

    static let headerHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                if live, let session {
                    BoardEditorPanel(session: session, interactive: selected && !layoutEditing)
                } else {
                    previewBody
                }
                if !selected || layoutEditing {
                    // Taps select (and double taps expand) without reaching the editor.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: onExpand)
                        .onTapGesture(perform: onSelect)
                }
            }
            if selected, let session, hasNotices(session.state) {
                Divider()
                BoardNotices(session: session).padding(8).background(Amb.card)
            }
        }
        .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .clipShape(RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(selected ? Amb.primary : Amb.border, lineWidth: selected ? 3 : 1))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .task(id: reference) { session = model.boardSession(reference, title: naplet.title, in: workspace, canvasId: canvasId) }
    }

    private func hasNotices(_ state: BoardState) -> Bool {
        !state.error.isEmpty || !state.notice.isEmpty || !state.viewingVersionId.isEmpty || state.save == .stale || state.newerAvailable
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "scribble.variable").foregroundStyle(Amb.primary)
            Text(naplet.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let session {
                BoardStatusPill(state: session.state)
                if selected && !layoutEditing { BoardMenu(session: session).buttonStyle(.borderless) }
            }
            Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open \(naplet.title) full screen").accessibilityIdentifier("board.expand")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.headerHeight)
        .background(Amb.muted.opacity(0.6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onExpand)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("naplet.\(naplet.title)")
    }

    @ViewBuilder private var previewBody: some View {
        if let preview, preview.state == .ready {
            ExcalidrawCanvas(board: preview).background(Color.white)
        } else if case .failed(let reason)? = preview?.state {
            Text(reason).font(.system(size: 13)).foregroundStyle(Amb.mutedForeground).padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 6) { ProgressView(); Text("Version \(reference.versionNumber)").font(.system(size: 11)).foregroundStyle(Amb.mutedForeground) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
