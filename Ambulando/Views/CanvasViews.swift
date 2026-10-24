import AmbulandoCore
import SwiftUI

// Canvas (sol `canvas/page.js`): the viewer's canvases, and a board showing each naplet at its saved position and size
// over the canvas drawing elements. Pan and zoom are viewer-local and never written back; a naplet is selected with a
// tap and opened in its native screen. Locked naplets show only their frame. Moving, resizing, adding or removing items
// stays in the web app in this build.

struct CanvasListView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var canvases = LiveQuery<[CanvasRecord]>(initial: [])

    var body: some View {
        let key = WorkspaceSync.canvasesKey(workspace.id)
        List {
            ForEach(canvases.value) { canvas in
                NavigationLink(value: WorkRoute.canvas(workspaceId: workspace.id, canvasId: canvas.id)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(canvas.title).font(.subheadline.weight(.semibold)).foregroundStyle(Amb.foreground)
                        HStack(spacing: 6) {
                            Text(canvas.visibilityMode == "workspace" ? "Everyone in the workspace" : "Shared with selected people")
                            if !canvas.updatedAt.isEmpty { Text(ChatTime.label(canvas.updatedAt)) }
                        }
                        .font(.caption).foregroundStyle(Amb.mutedForeground)
                    }
                }
                .accessibilityIdentifier("canvas.\(canvas.title)")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Canvas")
        .overlay {
            if canvases.loaded && canvases.value.isEmpty {
                if let error = model.syncError(forKey: key) { EmptyNote(title: "Canvases unavailable", systemImage: "exclamationmark.icloud", detail: error) }
                else if model.isSyncing(key) { ProgressView("Loading canvases…") }
                else { EmptyNote(title: "No canvases", systemImage: "rectangle.3.group", detail: model.canRead ? "Canvases shared with you appear here. Create them in the web app." : "Unlock to load canvases.") }
            }
        }
        .refreshable { model.openCanvases(workspace, force: true) }
        .task {
            let w = workspace.id, store = store
            canvases.start(store: store, matches: { $0.workspaceId == w && $0.table == .canvases }) { try await store.reader.canvases(workspaceId: w) }
            model.openCanvases(workspace)
        }
    }
}

struct CanvasBoardSnapshot: Sendable, Equatable {
    var canvas: CanvasRecord?
    var stored = false
    var scene = CanvasScene()
    /// Board previews by naplet id (parsed off the main actor).
    var boards: [String: PreparedBoard] = [:]
}

struct CanvasBoardView: View {
    @Environment(AppModel.self) private var model
    let canvasId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var snapshot = LiveQuery<CanvasBoardSnapshot>(initial: CanvasBoardSnapshot())
    @State private var viewport: CanvasViewport?
    @State private var gestureStart: CanvasViewport?
    @State private var selected: String?
    @State private var showItems = false
    /// An item chosen in the items sheet opens once the sheet has gone (a push during dismissal is dropped).
    @State private var pendingOpen: CanvasNaplet?

    var body: some View {
        let value = snapshot.value
        GeometryReader { proxy in
            let vp = viewport ?? fitted(value, proxy.size)
            ZStack(alignment: .topLeading) {
                Amb.muted.opacity(0.5)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil }
                CanvasElementsLayer(elements: value.scene.elements, transform: transform(vp))
                ForEach(visible(value.scene.naplets, vp, proxy.size)) { naplet in
                    NapletCard(naplet: naplet, board: value.boards[naplet.id], selected: selected == naplet.id)
                        .frame(width: naplet.layout.width, height: naplet.layout.height)
                        .scaleEffect(vp.scale, anchor: .topLeading)
                        .frame(width: naplet.layout.width * vp.scale, height: naplet.layout.height * vp.scale, alignment: .topLeading)
                        .offset(x: vp.x + naplet.layout.x * vp.scale, y: vp.y + naplet.layout.y * vp.scale)
                        .onTapGesture(count: 2) { open(naplet) }
                        .onTapGesture { selected = naplet.id }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilityLabel(naplet))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { open(naplet) }
                        .accessibilityIdentifier("naplet.\(naplet.title)")
                }
            }
            .clipped()
            .gesture(panAndZoom(vp))
            .onChange(of: viewport) { _, next in if let next { model.canvasViewports[canvasId] = next } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar(value) }
        .safeAreaInset(edge: .top, spacing: 0) { notices(value) }
        .navigationTitle(value.canvas?.title ?? "Canvas")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { withAnimation(.snappy) { viewport = nil; model.canvasViewports[canvasId] = nil } } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .accessibilityLabel("Fit board").accessibilityIdentifier("canvas.fit")
                Button { showItems = true } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Board items").accessibilityIdentifier("canvas.items")
            }
        }
        .sheet(isPresented: $showItems, onDismiss: { if let next = pendingOpen { pendingOpen = nil; open(next) } }) { itemsSheet(value) }
        .fixtureLabel()
        .overlay {
            if snapshot.loaded && !value.stored {
                let key = WorkspaceSync.canvasKey(workspace.id, canvasId)
                if let error = model.syncError(forKey: key) { EmptyNote(title: "Canvas unavailable", systemImage: "lock", detail: error) }
                else if !model.canRead { EmptyNote(title: "Canvas not on this iPhone", systemImage: "lock", detail: "Unlock to load it.") }
                else { ProgressView("Loading canvas…") }
            }
        }
        .task {
            // Returning to this board (or reopening it) keeps the position the viewer left it at.
            if viewport == nil { viewport = model.canvasViewports[canvasId] }
            let w = workspace.id, id = canvasId, store = store
            snapshot.start(store: store, matches: { $0.workspaceId == w && [.canvases, .boards].contains($0.table) }) {
                guard let stored = try await store.reader.canvasSnapshot(workspaceId: w, canvasId: id) else {
                    return CanvasBoardSnapshot(canvas: try await store.reader.canvas(workspaceId: w, id: id))
                }
                let scene = CanvasScene.parse(stored.bytes)
                var boards: [String: PreparedBoard] = [:]
                for naplet in scene.naplets {
                    guard case .excalidraw(let ref) = naplet.content else { continue }
                    try Task.checkCancellation()
                    boards[naplet.id] = try PreparedBoard.prepare(try await store.reader.boardScene(workspaceId: w, fileId: ref.fileId), expected: ref)
                }
                return CanvasBoardSnapshot(canvas: try await store.reader.canvas(workspaceId: w, id: id), stored: true, scene: scene, boards: boards)
            }
            model.openCanvas(workspace, canvasId: canvasId)
        }
        .refreshable { model.openCanvas(workspace, canvasId: canvasId, force: true) }
    }

    // MARK: Geometry

    private func transform(_ vp: CanvasViewport) -> CGAffineTransform { CGAffineTransform(a: vp.scale, b: 0, c: 0, d: vp.scale, tx: vp.x, ty: vp.y) }

    /// Everything on the board fitted to this screen. Items keep their saved positions and sizes; only the phone's view
    /// of them is fitted (the web's saved desktop viewport would show a small corner on a phone). Without items, the
    /// canvas's saved viewport is used.
    private func fitted(_ value: CanvasBoardSnapshot, _ size: CGSize) -> CanvasViewport {
        guard let bounds = value.scene.bounds, size.width > 0 else { return value.canvas?.viewport ?? CanvasViewport() }
        let width = Double(size.width), height = Double(size.height)
        let w = max(1, bounds.maxX - bounds.minX), h = max(1, bounds.maxY - bounds.minY)
        let scale = min(max(0.1, min((width - 24) / w, (height - 24) / h)), 1.5)
        return CanvasViewport(x: (width - w * scale) / 2 - bounds.minX * scale, y: (height - h * scale) / 2 - bounds.minY * scale, scale: scale)
    }

    /// Only naplets intersecting the screen are laid out (large boards stay cheap to pan).
    private func visible(_ naplets: [CanvasNaplet], _ vp: CanvasViewport, _ size: CGSize) -> [CanvasNaplet] {
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: -80, dy: -80)
        return naplets.filter { n in
            screen.intersects(CGRect(x: vp.x + n.layout.x * vp.scale, y: vp.y + n.layout.y * vp.scale, width: n.layout.width * vp.scale, height: n.layout.height * vp.scale))
        }
    }

    private func panAndZoom(_ current: CanvasViewport) -> some Gesture {
        SimultaneousGesture(
            DragGesture(minimumDistance: 4).onChanged { value in
                let start = gestureStart ?? current
                if gestureStart == nil { gestureStart = current }
                viewport = CanvasViewport(x: start.x + value.translation.width, y: start.y + value.translation.height, scale: (viewport ?? start).scale)
            }.onEnded { _ in gestureStart = nil },
            MagnifyGesture().onChanged { value in
                let start = gestureStart ?? current
                if gestureStart == nil { gestureStart = current }
                let scale = min(3, max(0.1, start.scale * value.magnification))
                let anchor = value.startLocation
                let ratio = scale / start.scale
                viewport = CanvasViewport(x: anchor.x - (anchor.x - start.x) * ratio, y: anchor.y - (anchor.y - start.y) * ratio, scale: scale)
            }.onEnded { _ in gestureStart = nil }
        )
    }

    // MARK: Chrome

    @ViewBuilder private func notices(_ value: CanvasBoardSnapshot) -> some View {
        let unsupported = value.scene.unsupportedElements.sorted { $0.key < $1.key }.map { "\($0.value) × \($0.key)" }
        if !unsupported.isEmpty {
            Notice(tone: .info, text: "Not drawn on iPhone: " + unsupported.joined(separator: ", ") + ".")
                .padding(.horizontal, 12).padding(.vertical, 6)
                .accessibilityIdentifier("canvas.unsupported")
        }
    }

    @ViewBuilder private func selectionBar(_ value: CanvasBoardSnapshot) -> some View {
        if let id = selected, let naplet = value.scene.naplets.first(where: { $0.id == id }) {
            HStack(spacing: 10) {
                Image(systemName: NapletCard.icon(naplet.content)).foregroundStyle(Amb.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(naplet.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(NapletCard.kindLabel(naplet.content)).font(.caption).foregroundStyle(Amb.mutedForeground)
                }
                Spacer()
                if openable(naplet) {
                    Button("Open") { open(naplet) }.buttonStyle(.borderedProminent).accessibilityIdentifier("naplet.open")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func itemsSheet(_ value: CanvasBoardSnapshot) -> some View {
        NavigationStack {
            List(value.scene.naplets) { naplet in
                Button { selected = naplet.id; if openable(naplet) { pendingOpen = naplet }; showItems = false } label: {
                    Label { VStack(alignment: .leading) { Text(naplet.title); Text(NapletCard.kindLabel(naplet.content)).font(.caption).foregroundStyle(Amb.mutedForeground) } }
                    icon: { Image(systemName: NapletCard.icon(naplet.content)) }
                }
                .disabled(!openable(naplet))
                .accessibilityIdentifier("canvas.item.\(naplet.title)")
            }
            .navigationTitle("Board items")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showItems = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func accessibilityLabel(_ n: CanvasNaplet) -> String {
        n.isReady ? "\(NapletCard.kindLabel(n.content)): \(n.title)" : "Locked item"
    }

    // MARK: Opening

    private func openable(_ n: CanvasNaplet) -> Bool {
        switch n.content {
        case .denied, .unknown: false
        default: true
        }
    }

    private func open(_ n: CanvasNaplet) {
        selected = n.id
        let w = workspace.id
        let route: WorkRoute?
        switch n.content {
        case .document(let id, _): route = .doc(workspaceId: w, docId: id)
        case .chatThread(let id, _): route = .threadById(workspaceId: w, threadId: id)
        case .excalidraw: route = .board(workspaceId: w, canvasId: canvasId, napletId: n.id)
        case .html: route = .webContent(workspaceId: w, source: .htmlNaplet(canvasId: canvasId, napletId: n.id, title: n.title))
        case .canvas(let other): route = .canvas(workspaceId: w, canvasId: other)
        case .taskList(let channel, _), .taskTree(let channel, _):
            // A channel's tasks open in Tasks with that channel as the context (the board position is kept for return).
            route = nil
            if let scope = model.navigation.value.channel(channel)?.scopeId {
                model.selectContext(WorkContext(scopeId: scope, channelId: channel))
                model.closeSurface()
                model.mode = .tasks
            } else { model.notice = "This channel is not available on this iPhone." }
        case .unknown, .denied: route = nil
        }
        if let route { pushRoute(route) }
    }

    @Environment(\.pushRoute) private var pushRoute
}

/// One naplet drawn at world size (the board scales it). Each source type shows what Tower projected for this viewer.
struct NapletCard: View {
    let naplet: CanvasNaplet
    let board: PreparedBoard?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: Self.icon(naplet.content)).foregroundStyle(naplet.isReady ? Amb.primary : Amb.mutedForeground)
                Text(naplet.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text(Self.kindLabel(naplet.content)).font(.system(size: 11)).foregroundStyle(Amb.mutedForeground)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        }
        .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(selected ? Amb.primary : Amb.border, lineWidth: selected ? 3 : 1))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    @ViewBuilder private var content: some View {
        switch naplet.content {
        case .document(_, let excerpt):
            Text(excerpt.isEmpty ? "Empty document" : excerpt).font(.system(size: 13)).foregroundStyle(Amb.foreground).padding(10)
        case .taskList(_, let tasks):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tasks.prefix(12)) { task in
                    HStack(spacing: 6) {
                        Image(systemName: TaskState(rawValue: task.state)?.isTerminal == true ? "checkmark.circle.fill" : "circle").foregroundStyle(Amb.mutedForeground)
                        Text(task.title).font(.system(size: 13)).lineLimit(1)
                    }
                }
                if tasks.isEmpty { Text("No tasks").font(.system(size: 13)).foregroundStyle(Amb.mutedForeground) }
            }
            .padding(10)
        case .taskTree(_, let channel):
            Text("Task tree for #\(channel ?? "channel"). Opens as the channel's task list on iPhone (the tree graph is web-only).")
                .font(.system(size: 13)).foregroundStyle(Amb.mutedForeground).padding(10)
        case .chatThread(_, let messages):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(messages.suffix(6)) { m in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.author.isEmpty ? "Someone" : m.author).font(.system(size: 11, weight: .semibold)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                        Text(m.body).font(.system(size: 13)).lineLimit(3)
                    }
                }
                if messages.isEmpty { Text("No messages").font(.system(size: 13)).foregroundStyle(Amb.mutedForeground) }
            }
            .padding(10)
        case .excalidraw(let ref):
            if let board, board.state == .ready {
                ExcalidrawCanvas(board: board)
            } else if case .failed(let reason)? = board?.state {
                Text(reason).font(.system(size: 13)).foregroundStyle(Amb.mutedForeground).padding(10)
            } else {
                VStack(spacing: 6) { ProgressView(); Text("Version \(ref.versionNumber)").font(.system(size: 11)).foregroundStyle(Amb.mutedForeground) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .html:
            Label("HTML artefact. Opens as labelled web content.", systemImage: "globe").font(.system(size: 13)).foregroundStyle(Amb.mutedForeground).padding(10)
        case .canvas:
            Label("Link to another canvas", systemImage: "arrow.up.right.square").font(.system(size: 13)).foregroundStyle(Amb.mutedForeground).padding(10)
        case .unknown(let type):
            Label("“\(type)” items are not shown on iPhone yet.", systemImage: "questionmark.square.dashed").font(.system(size: 13)).foregroundStyle(Amb.mutedForeground).padding(10)
        case .denied:
            Label("Not available to you", systemImage: "lock").font(.system(size: 13)).foregroundStyle(Amb.mutedForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func icon(_ content: CanvasNaplet.Content) -> String {
        switch content {
        case .document: "doc.text"
        case .taskList, .taskTree: "checklist"
        case .chatThread: "bubble.left.and.bubble.right"
        case .html: "globe"
        case .excalidraw: "scribble.variable"
        case .canvas: "rectangle.3.group"
        case .unknown: "questionmark.square.dashed"
        case .denied: "lock"
        }
    }

    static func kindLabel(_ content: CanvasNaplet.Content) -> String {
        switch content {
        case .document: "Document"
        case .taskList: "Tasks"
        case .taskTree: "Task tree"
        case .chatThread: "Conversation"
        case .html: "Web content"
        case .excalidraw: "Excalidraw board"
        case .canvas: "Canvas"
        case .unknown: "Unsupported"
        case .denied: "Locked"
        }
    }
}

/// An Excalidraw board full screen: pan and zoom over the native drawing, with the exact list of what is not drawn.
struct BoardSceneView: View {
    @Environment(AppModel.self) private var model
    let canvasId: String
    let napletId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var board = LiveQuery<BoardSnapshot>(initial: BoardSnapshot())
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var start: (CGFloat, CGSize)?

    struct BoardSnapshot: Sendable, Equatable {
        var title = "Board"
        var reference: BoardReference?
        var prepared = PreparedBoard()
    }

    var body: some View {
        let value = board.value
        VStack(spacing: 0) {
            notices(value)
            GeometryReader { proxy in
                let fit = ExcalidrawCanvas.fit(value.prepared.scene, in: proxy.size)
                ExcalidrawCanvas(board: value.prepared,
                                 transform: fit.concatenating(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.width, ty: offset.height)))
                    .background(Color.white)
                    .gesture(SimultaneousGesture(
                        DragGesture().onChanged { v in
                            let s = start ?? (scale, offset); if start == nil { start = s }
                            offset = CGSize(width: s.1.width + v.translation.width, height: s.1.height + v.translation.height)
                        }.onEnded { _ in start = nil },
                        MagnifyGesture().onChanged { v in
                            let s = start ?? (scale, offset); if start == nil { start = s }
                            scale = min(8, max(0.2, s.0 * v.magnification))
                        }.onEnded { _ in start = nil }))
                    .accessibilityLabel("Excalidraw board \(value.title), \(value.prepared.scene.elements.count) drawn elements")
                    .accessibilityIdentifier("board.canvas")
            }
        }
        .navigationTitle(value.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation(.snappy) { scale = 1; offset = .zero } } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .accessibilityLabel("Fit board")
            }
        }
        .fixtureLabel()
        .task {
            let w = workspace.id, canvas = canvasId, naplet = napletId, store = store
            board.start(store: store, matches: { $0.workspaceId == w && [.canvases, .boards].contains($0.table) }) {
                guard let snapshot = try await store.reader.canvasSnapshot(workspaceId: w, canvasId: canvas),
                      let n = CanvasScene.parse(snapshot.bytes).naplets.first(where: { $0.id == naplet }),
                      case .excalidraw(let ref) = n.content else { return BoardSnapshot() }
                return BoardSnapshot(title: n.title, reference: ref,
                                     prepared: try PreparedBoard.prepare(try await store.reader.boardScene(workspaceId: w, fileId: ref.fileId), expected: ref))
            }
        }
    }

    @ViewBuilder private func notices(_ value: BoardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch value.prepared.state {
            case .ready:
                if let ref = value.reference {
                    Text("Version \(ref.versionNumber)" + (ref.updatedAt.map { " · " + ChatTime.label($0) } ?? "") + " · read only on iPhone")
                        .font(.caption).foregroundStyle(Amb.mutedForeground)
                }
                if !value.prepared.scene.unsupportedSummary.isEmpty {
                    Notice(tone: .info, text: "Not drawn on iPhone: " + value.prepared.scene.unsupportedSummary.joined(separator: ", ") + ".")
                        .accessibilityIdentifier("board.unsupported")
                }
                if !value.prepared.scene.approximations.isEmpty {
                    Text(value.prepared.scene.approximations.joined(separator: " ")).font(.caption2).foregroundStyle(Amb.mutedForeground)
                        .accessibilityIdentifier("board.approximations")
                }
            case .failed(let reason):
                Notice(tone: .warning, text: reason)
            case .notStored:
                Notice(tone: .info, text: model.canRead ? "Loading this board…" : "This board is not on this iPhone yet. Unlock to load it.")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
