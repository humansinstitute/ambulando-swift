import AmbulandoCore
import SwiftUI

// Canvas (sol `canvas/page.js`): the viewer's canvases, and a board showing each naplet at its saved position and size
// over the canvas drawing elements. Pan and zoom are viewer-local and never written back; a naplet is selected with a
// tap and opened in its native screen. Locked naplets show only their frame. Where Tower reports `can_manage`, canvases
// can be created and renamed and items added, moved, resized and removed (`CanvasEditor`); each change is one confirmed
// request with Tower's version check, and the board shows the item where it was dragged until Tower answers. Excalidraw
// boards are edited in the embedded web editor (`BoardNapletWindow`, `BoardEditorPanel`). Canvas drawing elements are
// not edited on this device yet.

struct CanvasListView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var canvases = LiveQuery<[CanvasRecord]>(initial: [])

    var body: some View {
        let key = WorkspaceSync.canvasesKey(workspace.id)
        List {
            ForEach(canvases.value) { canvas in
                CanvasRouteLink(workspaceId: workspace.id, canvasId: canvas.id) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(canvas.title).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground)
                        HStack(spacing: 6) {
                            Text(canvas.visibilityMode == "workspace" ? "Everyone in the workspace" : "Shared with selected people")
                            if !canvas.updatedAt.isEmpty { Text(ChatTime.label(canvas.updatedAt)) }
                        }
                        .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                    }
                }
                .accessibilityIdentifier("canvas.\(canvas.title)")
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
        .navigationTitle("Canvas")
        .overlay {
            if canvases.loaded && canvases.value.isEmpty {
                if let error = model.syncError(forKey: key) { EmptyNote(title: "Canvases unavailable", systemImage: "exclamationmark.icloud", detail: error) }
                else if model.isSyncing(key) { ProgressView("Loading canvases…") }
                else { EmptyNote(title: "No canvases", systemImage: "rectangle.3.group", detail: model.canRead ? "Canvases shared with you appear here. Create one with +." : "Unlock to load canvases.") }
            }
        }
        .refreshable { model.openCanvases(workspace, force: true) }
        .toolbar { ToolbarItem(placement: .primaryAction) { NewCanvasButton(workspace: workspace) } }
        .task {
            let w = workspace.id, store = store
            canvases.start(store: store, matches: { $0.workspaceId == w && $0.table == .canvases }) { try await store.reader.canvases(workspaceId: w) }
            model.openCanvases(workspace)
        }
    }
}

/// "+" for a new canvas (visible to the whole workspace, as the web's default); the created board opens.
struct NewCanvasButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pushRoute) private var pushRoute
    let workspace: WorkspaceRecord
    @State private var creating = false
    @State private var title = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        Button { title = ""; creating = true } label: { if working { ProgressView() } else { Image(systemName: "plus") } }
            .disabled(working || !model.isUnlocked)
            .accessibilityLabel("New canvas").accessibilityIdentifier("canvas.new")
            .alert("New canvas", isPresented: $creating) {
                TextField("Title", text: $title).accessibilityIdentifier("canvas.new.title")
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }.accessibilityIdentifier("canvas.new.create")
            } message: { Text("Everyone in the workspace can see it.") }
            .alert("Canvas not created", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
    }

    private func create() {
        let name = title, w = workspace.id
        working = true
        Task {
            let result = await model.editCanvas { editor, c, workspace in try await editor.createCanvas(c, workspace, title: name) }
            working = false
            switch result {
            case .success(let canvas): pushRoute(.canvas(workspaceId: w, canvasId: canvas.id))
            case .failure(let error): failure = error.localizedDescription
            }
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
    // Editing (only offered when Tower reports `can_manage`; Tower still decides every write).
    @State private var editing = false
    /// Where an item was dragged, shown until the stored snapshot carries a newer version of it (or the write fails).
    @State private var overrides: [String: LayoutOverride] = [:]
    /// The frame an item had when the current move or resize began.
    @State private var dragOrigin: CanvasLayout?
    @State private var busy = false
    @State private var editError: String?
    @State private var removing: CanvasNaplet?
    @State private var showAdd = false
    @State private var renaming = false
    @State private var renameTitle = ""
    @State private var boardSize: CGSize = .zero
    /// A naplet opened at full size over the board (a task tree's Expand); a route chosen inside opens after it closes.
    @State private var focused: CanvasNaplet?
    @State private var focusRoute: WorkRoute?
    // Drawing elements (sol's text, shapes and arrows): selected and dragged like items, edited from the selection bar.
    @State private var selectedElement: String?
    @State private var elementOverrides: [String: LayoutOverride] = [:]
    @State private var elementOrigin: CanvasLayout?
    /// The text sheet: a new text element (nil element) or the text of an existing one.
    @State private var textSheet: TextSheet?
    @State private var creatingBoard = false
    /// Choosing items to group (sol `createGroup`): their `naplet:<id>` / `element:<id>` keys.
    @State private var grouping = false
    @State private var groupKeys: Set<String> = []
    /// An arrow or line end being dragged, in canvas points.
    @State private var endDrag: (id: String, start: Bool, point: [Double])?

    struct TextSheet: Identifiable { var element: CanvasElement?; var id: String { element?.id ?? "new" } }

    struct LayoutOverride: Equatable { var layout: CanvasLayout; var version: Int }
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    /// The on-screen keyboard is up (typing in a conversation or task naplet): the bottom controls step aside for it.
    @State private var keyboardShown = false
    #endif

    /// On the iPhone the canvas uses the whole screen: the section bar is hidden (see `WorkspaceShell`) and Back, the title
    /// and the canvas controls sit at the bottom, within reach of a thumb, as in the in-app browser.
    private var bottomControls: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        let value = snapshot.value
        chrome(tracking(board(value), value), value)
    }

    private func board(_ value: CanvasBoardSnapshot) -> some View {
        GeometryReader { proxy in
            let vp = viewport ?? fitted(value, proxy.size)
            ZStack(alignment: .topLeading) {
                Amb.muted.opacity(0.5)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil }
                CanvasElementsLayer(elements: shownElements(value.scene.elements), transform: transform(vp))
                if editing {
                    ForEach(value.scene.elements) { element in elementHitArea(element, vp) }
                }
                let shownNaplets = visible(value.scene.naplets, vp, proxy.size)
                let live = liveBoards(shownNaplets, vp)
                ForEach(shownNaplets) { naplet in
                    napletView(naplet, value, vp, live: live.contains(naplet.id))
                }
                if let id = selected, let naplet = value.scene.naplets.first(where: { $0.id == id }), movable(naplet) {
                    resizeHandle(naplet, vp)
                }
                if editing, let id = selectedElement, let element = value.scene.elements.first(where: { $0.id == id }) {
                    elementSelection(element, vp)
                }
                if grouping { groupPicker(value, vp) }
            }
            .clipped()
            // A selected live board takes its own touches (drawing, Excalidraw's pan and zoom); the canvas pans again
            // once the board is deselected.
            .gesture(panAndZoom(vp), including: boardActive(value) ? .subviews : .all)
            .onChange(of: viewport) { _, next in if let next { model.canvasViewports[canvasId] = next } }
            .onAppear { boardSize = proxy.size }
            .onChange(of: proxy.size) { _, size in boardSize = size }
        }
    }

    private func tracking(_ content: some View, _ value: CanvasBoardSnapshot) -> some View {
        content
        .onChange(of: value.scene.naplets) { _, naplets in
            // A newer stored version (this edit or someone else's) replaces the dragged position.
            let versions = Dictionary(naplets.map { ($0.id, $0.rowVersion) }, uniquingKeysWith: { a, _ in a })
            overrides = overrides.filter { versions[$0.key] == $0.value.version }
            if let id = selected, versions[id] == nil { selected = nil }
        }
        .onChange(of: value.scene.elements) { _, elements in
            let versions = Dictionary(elements.map { ($0.id, $0.rowVersion) }, uniquingKeysWith: { a, _ in a })
            elementOverrides = elementOverrides.filter { versions[$0.key] == $0.value.version }
            if let id = selectedElement, versions[id] == nil { selectedElement = nil }
        }
        .onChange(of: editing) { _, on in if !on { selectedElement = nil; grouping = false; groupKeys = [] } }
        .onChange(of: selected) { _, id in if id != nil { selectedElement = nil } }
    }

    private func chrome(_ content: some View, _ value: CanvasBoardSnapshot) -> some View {
        content
        .onChange(of: canEdit(value)) { _, allowed in if !allowed { editing = false } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                selectionBar(value)
                if bottomControls && !keyboardVisible { bottomBar(value) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { notices(value) }
        .navigationTitle(value.canvas?.title ?? "Canvas")
        .inlineTitle()
        .toolbar {
            if !bottomControls {
                ToolbarItemGroup(placement: .primaryAction) { controls(value) }
            }
        }
        #if os(iOS)
        .toolbar(bottomControls ? .hidden : .automatic, for: .navigationBar)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardShown = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardShown = false }
        #endif
        .sheet(isPresented: $showItems, onDismiss: { if let next = pendingOpen { pendingOpen = nil; open(next) } }) {
            itemsSheet(value).macSheetSize(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 520)
        }
        .sheet(isPresented: $showAdd) {
            CanvasAddItemSheet(workspace: workspace, canvasId: canvasId, store: store) { choice in add(choice, value) }
                .macSheetSize(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 600)
        }
        .sheet(item: $textSheet) { sheet in
            CanvasTextSheet(initial: sheet.element?.text ?? "") { text in saveText(text, sheet.element, value) }
                .macSheetSize(minWidth: 420, idealWidth: 480, minHeight: 260, idealHeight: 320)
        }
        .sheet(isPresented: $creatingBoard) {
            NewBoardSheet(channels: model.navigation.value.groups.flatMap(\.channels), labels: model.navigation.value.labels,
                          preferred: model.context.channelId) { title, channel in createBoard(title: title, channelId: channel, value) }
                .macSheetSize(minWidth: 420, idealWidth: 480, minHeight: 300, idealHeight: 360)
        }
        .alert("Rename canvas", isPresented: $renaming) {
            TextField("Title", text: $renameTitle).accessibilityIdentifier("canvas.rename.title")
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename(value) }.accessibilityIdentifier("canvas.rename.save")
        }
        .confirmationDialog(removing.map { "Remove “\($0.isReady ? $0.title : "Locked item")” from this canvas?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove from canvas", role: .destructive) { if let n = removing { remove(n) } }.accessibilityIdentifier("naplet.remove.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only the item on this board is removed; what it shows is not deleted.") }
        .fixtureLabel()
        .modifier(FocusCover(focused: $focused, route: $focusRoute, content: { naplet in focusedNaplet(naplet, canManage: value.canvas?.canManage == true) }))
        .overlay {
            if let error = snapshot.error {
                EmptyNote(title: "Canvas cannot be shown", systemImage: "exclamationmark.triangle", detail: error)
            } else if snapshot.loaded && !value.stored {
                let key = WorkspaceSync.canvasKey(workspace.id, canvasId)
                if let error = model.syncError(forKey: key) { EmptyNote(title: "Canvas unavailable", systemImage: "lock", detail: error) }
                else if !model.canRead { EmptyNote(title: "Canvas not on this \(Device.name)", systemImage: "lock", detail: "Unlock to load it.") }
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
                let scene = try CanvasScene.parse(stored.bytes)
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

    /// One item at its saved (or just dragged) frame, scaled to the viewport.
    @ViewBuilder private func napletView(_ naplet: CanvasNaplet, _ value: CanvasBoardSnapshot, _ vp: CanvasViewport, live: Bool) -> some View {
        if case .excalidraw(let ref) = naplet.content {
            placed(BoardNapletWindow(naplet: naplet, reference: ref, workspace: workspace, canvasId: canvasId, preview: value.boards[naplet.id], selected: selected == naplet.id,
                                     live: live, layoutEditing: editing, onSelect: { selected = naplet.id }, onExpand: { open(naplet) }), naplet, vp)
                .gesture(editGesture(naplet, vp, resize: false), including: movable(naplet) ? .all : .subviews)
                .task(id: naplet.id) { requestBoardIfNeeded(naplet, value) }
        } else if let body = interactiveBody(naplet, canManage: value.canvas?.canManage == true, live: live) {
            placed(NapletWindow(naplet: naplet, selected: selected == naplet.id, interactive: selected == naplet.id && !editing,
                                onSelect: { selected = naplet.id }, onExpand: openable(naplet) ? { open(naplet) } : nil,
                                accessory: { EmptyView() }, content: { body }), naplet, vp)
                .gesture(editGesture(naplet, vp, resize: false), including: movable(naplet) ? .all : .subviews)
        } else {
            cardView(naplet, value, vp)
        }
    }

    /// A naplet at full size: its live content with the board's own window title, closed with Done.
    private func focusedNaplet(_ naplet: CanvasNaplet, canManage: Bool) -> some View {
        NavigationStack {
            Group {
                if let body = interactiveBody(naplet, canManage: canManage, live: true, interactive: true) {
                    body
                } else {
                    EmptyNote(title: "Item unavailable", systemImage: "lock", detail: "It cannot be shown here.")
                }
            }
            .navigationTitle(naplet.title)
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { focused = nil }.accessibilityIdentifier("naplet.focus.done") } }
            .environment(\.pushRoute, PushRouteAction { route in focusRoute = route; focused = nil })
        }
    }

    /// The live content of a conversation, document, HTML or task tree naplet (others keep their card).
    private func interactiveBody(_ naplet: CanvasNaplet, canManage: Bool, live: Bool, interactive focus: Bool = false) -> AnyView? {
        let interactive = focus || (selected == naplet.id && !editing)
        switch naplet.content {
        case .chatThread(let thread, _):
            return AnyView(ChatNapletBody(threadId: thread, workspace: workspace, store: store, interactive: interactive))
        case .document(let doc, _):
            return AnyView(DocNapletBody(docId: doc, workspace: workspace, store: store, interactive: interactive))
        case .html:
            return AnyView(HTMLNapletBody(canvasId: canvasId, napletId: naplet.id, workspace: workspace, live: live, interactive: interactive))
        case .taskTree(let channel, let title, let scope, let canCreate):
            return AnyView(TaskTreeNapletBody(naplet: naplet, canvasId: canvasId, channelId: channel, channelTitle: title, scopeId: scope, canCreate: canCreate,
                                              canManage: canManage, workspace: workspace, interactive: interactive))
        default:
            return nil
        }
    }

    /// Positions an item's view at its frame on the board.
    private func placed(_ view: some View, _ naplet: CanvasNaplet, _ vp: CanvasViewport) -> some View {
        let layout = shown(naplet)
        return view
            .frame(width: layout.width, height: layout.height)
            .scaleEffect(vp.scale, anchor: .topLeading)
            .frame(width: layout.width * vp.scale, height: layout.height * vp.scale, alignment: .topLeading)
            .offset(x: vp.x + layout.x * vp.scale, y: vp.y + layout.y * vp.scale)
    }

    private func cardView(_ naplet: CanvasNaplet, _ value: CanvasBoardSnapshot, _ vp: CanvasViewport) -> some View {
        placed(NapletCard(naplet: naplet, board: value.boards[naplet.id], selected: selected == naplet.id), naplet, vp)
            .gesture(editGesture(naplet, vp, resize: false), including: movable(naplet) ? .all : .subviews)
            .onTapGesture(count: 2) { open(naplet) }
            .onTapGesture { selected = naplet.id }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(naplet))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(naplet) }
            .accessibilityIdentifier("naplet.\(naplet.title)")
            .task(id: naplet.id) { requestBoardIfNeeded(naplet, value) }
    }

    /// A board naplet on screen whose scene is not stored yet is fetched now (boards beyond the first batch otherwise
    /// arrive in the background).
    private func requestBoardIfNeeded(_ naplet: CanvasNaplet, _ value: CanvasBoardSnapshot) {
        guard case .excalidraw(let ref) = naplet.content, value.boards[naplet.id]?.state == .notStored else { return }
        model.openBoard(ref, in: workspace)
    }

    // MARK: Live boards

    /// At most this many embedded board editors run at once (each is a web view); the rest show the native preview.
    static let liveBoardLimit = 3
    /// Boards smaller than this on screen show the preview (zoom in, select or expand to edit).
    static let liveBoardMinWidth = 150.0

    /// The board naplets that run the embedded editor: the selected one first, then the largest on screen.
    private func liveBoards(_ naplets: [CanvasNaplet], _ vp: CanvasViewport) -> Set<String> {
        let boards = naplets.filter { switch $0.content { case .excalidraw, .html: true; default: false } }
        let ranked = boards.sorted { a, b in
            if (a.id == selected) != (b.id == selected) { return a.id == selected }
            return a.layout.width * a.layout.height > b.layout.width * b.layout.height
        }
        return Set(ranked.filter { $0.id == selected || $0.layout.width * vp.scale >= Self.liveBoardMinWidth }.prefix(Self.liveBoardLimit).map(\.id))
    }

    /// A selected live naplet (board, conversation, document, HTML, task tree) that is not being moved takes the touches
    /// inside its window.
    private func boardActive(_ value: CanvasBoardSnapshot) -> Bool {
        guard !editing, let id = selected, let naplet = value.scene.naplets.first(where: { $0.id == id }) else { return false }
        switch naplet.content {
        case .excalidraw, .chatThread, .document, .html, .taskTree: return true
        default: return false
        }
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
        if let editError {
            HStack(alignment: .top, spacing: 8) {
                Notice(tone: .warning, text: editError)
                Button { self.editError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .accessibilityIdentifier("canvas.editError")
        } else if editing {
            Text(busy ? "Saving…" : "Tap an item to select it. Drag it to move; drag its corner to resize.")
                .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                .frame(maxWidth: .infinity).padding(.vertical, 6).background(.bar)
                .accessibilityIdentifier("canvas.editing")
        }
        let unsupported = value.scene.unsupportedElements.sorted { $0.key < $1.key }.map { "\($0.value) × \($0.key)" }
        if !unsupported.isEmpty {
            Notice(tone: .info, text: "Not drawn on \(Device.name): " + unsupported.joined(separator: ", ") + ".")
                .padding(.horizontal, 12).padding(.vertical, 6)
                .accessibilityIdentifier("canvas.unsupported")
        }
    }

    private var keyboardVisible: Bool {
        #if os(iOS)
        keyboardShown
        #else
        false
        #endif
    }

    /// Fit, board items and the edit menu (or, while editing, Add and Done): in the toolbar, or the iPhone's bottom bar.
    @ViewBuilder private func controls(_ value: CanvasBoardSnapshot) -> some View {
        if editing {
            Menu {
                Button { showAdd = true } label: { Label("Item from this \(Device.name)…", systemImage: "square.on.square") }
                    .accessibilityIdentifier("canvas.add.item")
                Button { creatingBoard = true } label: { Label("New whiteboard…", systemImage: "scribble.variable") }
                    .accessibilityIdentifier("canvas.add.board")
                Divider()
                Button { textSheet = TextSheet(element: nil) } label: { Label("Text…", systemImage: "textformat") }
                    .accessibilityIdentifier("canvas.add.text")
                Button { addShape(.rectangle, value) } label: { Label("Rectangle", systemImage: "rectangle") }
                Button { addShape(.ellipse, value) } label: { Label("Ellipse", systemImage: "circle") }
                Button { addShape(.diamond, value) } label: { Label("Diamond", systemImage: "diamond") }
                Button { addArrow(value) } label: { Label("Arrow", systemImage: "arrow.right") }
                    .accessibilityIdentifier("canvas.add.arrow")
                Button { addArrow(value, line: true) } label: { Label("Line", systemImage: "line.diagonal") }
                    .accessibilityIdentifier("canvas.add.line")
                Button { addFrame(value) } label: { Label("Frame", systemImage: "rectangle.dashed") }
                    .accessibilityIdentifier("canvas.add.frame")
                Divider()
                Button { selected = nil; selectedElement = nil; groupKeys = []; grouping = true } label: { Label("Group…", systemImage: "square.on.square.dashed") }
                    .accessibilityIdentifier("canvas.add.group")
            } label: { Image(systemName: "plus") }
                .disabled(busy)
                .accessibilityLabel("Add to canvas").accessibilityIdentifier("canvas.add")
            Button("Done") { editing = false }.accessibilityIdentifier("canvas.done")
        } else {
            Button { withAnimation(.snappy) { viewport = nil; model.canvasViewports[canvasId] = nil } } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .accessibilityLabel("Fit board").accessibilityIdentifier("canvas.fit")
            Button { showItems = true } label: { Image(systemName: "list.bullet") }
                .accessibilityLabel("Board items").accessibilityIdentifier("canvas.items")
            if canEdit(value) {
                Menu {
                    Button { editing = true } label: { Label("Edit items", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
                        .accessibilityIdentifier("canvas.edit")
                    Button { editing = true; showAdd = true } label: { Label("Add item…", systemImage: "plus") }
                    Button { renameTitle = value.canvas?.title ?? ""; renaming = true } label: { Label("Rename canvas…", systemImage: "pencil") }
                        .accessibilityIdentifier("canvas.rename")
                } label: { Image(systemName: "pencil.circle") }
                    .accessibilityLabel("Edit canvas").accessibilityIdentifier("canvas.editMenu")
            }
        }
    }

    /// The iPhone's canvas navigation at the bottom: Back, the canvas name and its controls, above the home indicator.
    @ViewBuilder private func bottomBar(_ value: CanvasBoardSnapshot) -> some View {
        #if os(iOS)
        HStack(spacing: 18) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).frame(width: 36, height: 36) }
                .accessibilityLabel("Back").accessibilityIdentifier("canvas.back")
            Text(value.canvas?.title ?? "Canvas").font(.amb(.headline)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Group { controls(value) }.font(.system(size: 18, weight: .medium)).frame(minWidth: 36, minHeight: 36)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Amb.border).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas.bottomBar")
        #endif
    }

    @ViewBuilder private func selectionBar(_ value: CanvasBoardSnapshot) -> some View {
        if editing && grouping {
            groupBar(value)
        } else if editing, let id = selectedElement, let element = value.scene.elements.first(where: { $0.id == id }) {
            elementBar(element, value)
        } else if let id = selected, let naplet = value.scene.naplets.first(where: { $0.id == id }) {
            HStack(spacing: 10) {
                Image(systemName: NapletCard.icon(naplet.content)).foregroundStyle(Amb.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(naplet.title).font(.amb(.subheadline).weight(.semibold)).lineLimit(1)
                    Text(NapletCard.kindLabel(naplet.content)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
                Spacer()
                if editing {
                    if busy { ProgressView() }
                    orderButtons(value) { delta in reorder(naplet, by: delta, value) }
                    if naplet.isReady {
                        Button { run { e, c, w in try await e.duplicate(c, w, canvasId: canvasId, naplet: naplet, topZ: topZ(value)) } } label: {
                            Image(systemName: "plus.square.on.square")
                        }
                        .buttonStyle(.bordered).disabled(busy).accessibilityLabel("Duplicate").accessibilityIdentifier("naplet.duplicate")
                    }
                    Button("Remove", role: .destructive) { removing = naplet }
                        .buttonStyle(.bordered).disabled(busy).accessibilityIdentifier("naplet.remove")
                } else if openable(naplet) {
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
                    Label { VStack(alignment: .leading) { Text(naplet.title).appRowTextSize(); Text(NapletCard.kindLabel(naplet.content)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) } }
                    icon: { Image(systemName: NapletCard.icon(naplet.content)) }
                }
                .disabled(!openable(naplet))
                .accessibilityIdentifier("canvas.item.\(naplet.title)")
            }
            .navigationTitle("Board items")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showItems = false }.accessibilityIdentifier("canvas.items.close") } }
        }
        .presentationDetents([.medium, .large])
    }

    private func accessibilityLabel(_ n: CanvasNaplet) -> String {
        n.isReady ? "\(NapletCard.kindLabel(n.content)): \(n.title)" : "Locked item"
    }

    // MARK: Editing

    private func canEdit(_ value: CanvasBoardSnapshot) -> Bool { value.canvas?.canManage == true && value.stored && model.isUnlocked }

    /// Locked items keep their frame (as on the web, only removal is offered for them).
    private func movable(_ n: CanvasNaplet) -> Bool { editing && !busy && selected == n.id && n.isReady }

    private func shown(_ n: CanvasNaplet) -> CanvasLayout {
        if let o = overrides[n.id], o.version == n.rowVersion { return o.layout }
        return n.layout
    }

    /// Moves (or, from the corner handle, resizes) the selected item in world units; one write when the finger lifts.
    private func editGesture(_ naplet: CanvasNaplet, _ vp: CanvasViewport, resize: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2).onChanged { drag in
            let origin = dragOrigin ?? shown(naplet)
            if dragOrigin == nil { dragOrigin = origin }
            // The fitted view would re-fit around the moved item; keep the board still while editing.
            if viewport == nil { viewport = vp }
            let dx = drag.translation.width / vp.scale, dy = drag.translation.height / vp.scale
            var next = origin
            if resize { next.width = origin.width + dx; next.height = origin.height + dy } else { next.x = origin.x + dx; next.y = origin.y + dy }
            overrides[naplet.id] = LayoutOverride(layout: CanvasEditor.clamped(next), version: naplet.rowVersion)
        }.onEnded { _ in
            let origin = dragOrigin
            dragOrigin = nil
            guard let target = overrides[naplet.id]?.layout, target != origin else { return }
            run(failed: { overrides[naplet.id] = nil }) { e, c, w in
                try await e.updateLayout(c, w, canvasId: canvasId, naplet: naplet, to: target)
            }
        }
    }

    private func resizeHandle(_ naplet: CanvasNaplet, _ vp: CanvasViewport) -> some View {
        let layout = shown(naplet)
        return Circle().fill(Amb.primary).overlay(Circle().stroke(.white, lineWidth: 2))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle().inset(by: -12))
            .offset(x: vp.x + (layout.x + layout.width) * vp.scale - 11, y: vp.y + (layout.y + layout.height) * vp.scale - 11)
            .gesture(editGesture(naplet, vp, resize: true))
            .accessibilityLabel("Resize \(naplet.title)")
            .accessibilityIdentifier("naplet.resize")
    }

    // MARK: Drawing elements

    /// Elements where they were just dragged until Tower has the move.
    private func shownElements(_ elements: [CanvasElement]) -> [CanvasElement] {
        guard !elementOverrides.isEmpty else { return elements }
        return elements.map { e in
            guard let o = elementOverrides[e.id], o.version == e.rowVersion else { return e }
            var moved = e
            moved.layout = o.layout
            return moved
        }
    }

    private func shownLayout(_ e: CanvasElement) -> CanvasLayout {
        if let o = elementOverrides[e.id], o.version == e.rowVersion { return o.layout }
        return e.layout
    }

    private func screenRect(_ layout: CanvasLayout, _ vp: CanvasViewport) -> CGRect {
        CGRect(x: vp.x + layout.x * vp.scale, y: vp.y + layout.y * vp.scale, width: layout.width * vp.scale, height: layout.height * vp.scale)
    }

    /// While editing, each element can be tapped to select it and dragged to move it (one write when the finger lifts).
    private func elementHitArea(_ element: CanvasElement, _ vp: CanvasViewport) -> some View {
        let rect = screenRect(shownLayout(element), vp)
        return Rectangle().fill(Color.white.opacity(0.001))
            .frame(width: max(rect.width, 24), height: max(rect.height, 24))
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture { selected = nil; selectedElement = element.id }
            .gesture(elementGesture(element, vp, resize: false), including: selectedElement == element.id && !busy ? .all : .subviews)
            .accessibilityElement()
            .accessibilityLabel(element.kind == .text ? "Text: \(element.text ?? "")" : "\(element.kindName.capitalized) shape")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("element.\(element.kindName)")
    }

    @ViewBuilder private func elementSelection(_ element: CanvasElement, _ vp: CanvasViewport) -> some View {
        if element.kind == .arrow || element.kind == .line {
            endHandles(element, vp)
        } else {
            boxSelection(element, vp)
        }
    }

    /// An arrow's or line's two ends, each dragged to a new point (sol `moveArrowEndpoint`; any bend stays).
    private func endHandles(_ element: CanvasElement, _ vp: CanvasViewport) -> some View {
        let ends = CanvasEditor.endPoints(element)
        return ZStack(alignment: .topLeading) {
            ForEach([true, false], id: \.self) { isStart in
                let point = endDrag.flatMap { $0.id == element.id && $0.start == isStart ? $0.point : nil } ?? (isStart ? ends.start : ends.end)
                Circle().fill(Amb.primary).overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle().inset(by: -12))
                    .offset(x: vp.x + point[0] * vp.scale - 11, y: vp.y + point[1] * vp.scale - 11)
                    .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                        if viewport == nil { viewport = vp }
                        let origin = isStart ? ends.start : ends.end
                        endDrag = (element.id, isStart, [origin[0] + drag.translation.width / vp.scale, origin[1] + drag.translation.height / vp.scale])
                    }.onEnded { _ in
                        guard let drag = endDrag, drag.id == element.id else { return }
                        endDrag = nil
                        let moved = CanvasEditor.movingEnd(element, start: isStart, to: drag.point.map { $0.rounded() })
                        run { e, c, w in try await e.updateElement(c, w, canvasId: canvasId, element: element, layout: moved.layout, data: moved.data) }
                    })
                    .accessibilityLabel(isStart ? "Start of the arrow" : "End of the arrow")
                    .accessibilityIdentifier(isStart ? "element.start" : "element.end")
            }
        }
    }

    /// Line style, arrowheads and straightening for an arrow or line (sol `setElementOption`, `straightenArrow`).
    private func arrowControls(_ element: CanvasElement) -> some View {
        Menu {
            Picker("Line", selection: Binding(get: { element.lineStyle }, set: { style in
                run { e, c, w in try await e.updateElement(c, w, canvasId: canvasId, element: element, data: ["lineStyle": style]) }
            })) {
                Text("Solid").tag("solid"); Text("Dotted").tag("dotted"); Text("Dashed").tag("dashed")
            }
            ForEach(["startArrowhead", "endArrowhead"], id: \.self) { field in
                Picker(field == "startArrowhead" ? "Start" : "End", selection: Binding(
                    get: { field == "startArrowhead" ? element.startArrowhead : element.endArrowhead },
                    set: { head in run { e, c, w in try await e.updateElement(c, w, canvasId: canvasId, element: element, data: [field: head]) } })) {
                    ForEach(["none", "arrow", "triangle", "diamond", "circle"], id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            if element.curve != nil {
                Button("Straighten") { run { e, c, w in try await e.updateElement(c, w, canvasId: canvasId, element: element, data: ["curve": NSNull()]) } }
            }
        } label: { Image(systemName: "line.3.horizontal.decrease") }
            .disabled(busy).accessibilityLabel("Line style").accessibilityIdentifier("element.lineStyle")
    }

    private func boxSelection(_ element: CanvasElement, _ vp: CanvasViewport) -> some View {
        let rect = screenRect(shownLayout(element), vp)
        return ZStack(alignment: .topLeading) {
            Rectangle().stroke(Amb.primary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
            Circle().fill(Amb.primary).overlay(Circle().stroke(.white, lineWidth: 2))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle().inset(by: -12))
                .offset(x: rect.maxX - 11, y: rect.maxY - 11)
                .gesture(elementGesture(element, vp, resize: true))
                .accessibilityLabel("Resize")
                .accessibilityIdentifier("element.resize")
        }
    }

    private func elementGesture(_ element: CanvasElement, _ vp: CanvasViewport, resize: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2).onChanged { drag in
            let origin = elementOrigin ?? shownLayout(element)
            if elementOrigin == nil { elementOrigin = origin }
            if viewport == nil { viewport = vp }
            let dx = drag.translation.width / vp.scale, dy = drag.translation.height / vp.scale
            var next = origin
            if resize { next.width = origin.width + dx; next.height = origin.height + dy } else { next.x = origin.x + dx; next.y = origin.y + dy }
            elementOverrides[element.id] = LayoutOverride(layout: CanvasEditor.elementLayout(next), version: element.rowVersion)
        }.onEnded { _ in
            let origin = elementOrigin
            elementOrigin = nil
            guard let target = elementOverrides[element.id]?.layout, target != origin else { return }
            run(failed: { elementOverrides[element.id] = nil }) { e, c, w in
                try await e.updateElement(c, w, canvasId: canvasId, element: element, layout: target)
            }
        }
    }

    /// The selected element's controls: edit text and its size, bring forward or send back, duplicate, delete.
    private func elementBar(_ element: CanvasElement, _ value: CanvasBoardSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: element.kind == .text ? "textformat" : element.kind == .arrow || element.kind == .line ? "arrow.right" : "square.on.circle")
                .foregroundStyle(Amb.primary)
            Text(element.kind == .text ? (element.text ?? "Text") : element.isGroup ? "Group" : element.kindName.capitalized)
                .font(.amb(.subheadline).weight(.semibold)).lineLimit(1)
            Spacer()
            if busy { ProgressView() }
            if element.kind == .text {
                Button { textSheet = TextSheet(element: element) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.bordered).disabled(busy).accessibilityLabel("Edit text").accessibilityIdentifier("element.editText")
                Menu {
                    ForEach([12, 16, 20, 24, 32, 48, 72], id: \.self) { size in
                        Button("\(size) pt") { run { e, c, w in try await e.updateElement(c, w, canvasId: canvasId, element: element, data: ["fontSize": size]) } }
                    }
                } label: { Image(systemName: "textformat.size") }
                    .disabled(busy).accessibilityLabel("Text size").accessibilityIdentifier("element.fontSize")
            }
            if element.kind == .arrow || element.kind == .line {
                arrowControls(element)
            }
            orderButtons(value) { delta in
                var layout = element.layout
                layout.z = min(100_000, max(1, layout.z + delta))
                run { e, c, w in try await e.updateElement(c, w, canvasId: canvasId, element: element, layout: layout) }
            }
            Button { run { e, c, w in try await e.duplicate(c, w, canvasId: canvasId, element: element, topZ: topZ(value)) } } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.bordered).disabled(busy).accessibilityLabel("Duplicate").accessibilityIdentifier("element.duplicate")
            Button(role: .destructive) {
                selectedElement = nil
                run { e, c, w in try await e.deleteElement(c, w, canvasId: canvasId, element: element) }
            } label: { Image(systemName: element.isGroup ? "square.on.square.dashed" : "trash") }
                .buttonStyle(.bordered).disabled(busy).accessibilityLabel(element.isGroup ? "Ungroup" : "Delete").accessibilityIdentifier("element.delete")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        // A container identifier would otherwise replace the buttons' own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas.elementBar")
    }

    /// Bring forward / send back by one layer (sol `orderSelected`).
    private func orderButtons(_ value: CanvasBoardSnapshot, _ move: @escaping (Int) -> Void) -> some View {
        Menu {
            Button { move(1) } label: { Label("Bring forward", systemImage: "square.2.layers.3d.top.filled") }
            Button { move(-1) } label: { Label("Send backward", systemImage: "square.2.layers.3d.bottom.filled") }
        } label: { Image(systemName: "square.3.layers.3d") }
            .disabled(busy).accessibilityLabel("Arrange").accessibilityIdentifier("canvas.arrange")
    }

    private func reorder(_ naplet: CanvasNaplet, by delta: Int, _ value: CanvasBoardSnapshot) {
        var layout = shown(naplet)
        layout.z = min(100_000, max(1, layout.z + delta))
        run { e, c, w in try await e.updateLayout(c, w, canvasId: canvasId, naplet: naplet, to: layout) }
    }

    private func topZ(_ value: CanvasBoardSnapshot) -> Int {
        max(value.scene.naplets.map(\.layout.z).max() ?? 0, value.scene.elements.map(\.layout.z).max() ?? 0)
    }

    /// The middle of what is on screen, in board coordinates (new items go there).
    private func screenCentre(_ value: CanvasBoardSnapshot) -> (x: Double, y: Double) {
        let vp = viewport ?? fitted(value, boardSize)
        viewport = vp
        return ((Double(boardSize.width) / 2 - vp.x) / vp.scale, (Double(boardSize.height) / 2 - vp.y) / vp.scale)
    }

    private func addShape(_ kind: CanvasElement.Kind, _ value: CanvasBoardSnapshot) {
        let centre = screenCentre(value), z = topZ(value) + 1
        let layout = CanvasLayout(x: centre.x - 100, y: centre.y - 60, width: 200, height: 120, z: z)
        run { e, c, w in
            let id = try await e.createElement(c, w, canvasId: canvasId, .shape(kind), layout: layout)
            await MainActor.run { selectedElement = id }
        }
    }

    private func addArrow(_ value: CanvasBoardSnapshot, line: Bool = false) {
        let centre = screenCentre(value), z = topZ(value) + 1
        run { e, c, w in
            let id = try await e.createElement(c, w, canvasId: canvasId, .arrow(from: [centre.x - 120, centre.y], to: [centre.x + 120, centre.y], line: line),
                                               layout: CanvasLayout(x: 0, y: 0, width: 8, height: 8, z: z))
            await MainActor.run { selectedElement = id }
        }
    }

    private func addFrame(_ value: CanvasBoardSnapshot) {
        let centre = screenCentre(value), z = topZ(value) + 1
        let layout = CanvasLayout(x: centre.x - 200, y: centre.y - 140, width: 400, height: 280, z: z)
        run { e, c, w in
            let id = try await e.createElement(c, w, canvasId: canvasId, .frame, layout: layout)
            await MainActor.run { selectedElement = id }
        }
    }

    /// Every item (and element) can be tapped to add it to the group or take it out again.
    private func groupPicker(_ value: CanvasBoardSnapshot, _ vp: CanvasViewport) -> some View {
        let items = value.scene.naplets.map { (CanvasEditor.itemKey("naplet", $0.id), $0.layout, $0.isReady ? $0.title : "Locked item") }
            + value.scene.elements.filter { !$0.isGroup }.map { (CanvasEditor.itemKey("element", $0.id), $0.layout, $0.kind == .text ? ($0.text ?? "Text") : $0.kindName) }
        // Largest first, so a smaller item inside a frame or behind a large item stays on top and can be picked.
        let ordered = items.sorted { $0.1.width * $0.1.height > $1.1.width * $1.1.height }
        return ForEach(ordered, id: \.0) { key, layout, title in
            let rect = screenRect(layout, vp), chosen = groupKeys.contains(key)
            RoundedRectangle(cornerRadius: 6)
                .fill(Amb.primary.opacity(chosen ? 0.18 : 0.04))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Amb.primary, style: StrokeStyle(lineWidth: chosen ? 2.5 : 1, dash: chosen ? [] : [4, 3])))
                .overlay(alignment: .topTrailing) {
                    if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(Amb.primary).padding(4) }
                }
                .frame(width: max(rect.width, 24), height: max(rect.height, 24))
                .position(x: rect.midX, y: rect.midY)
                .onTapGesture { if chosen { groupKeys.remove(key) } else { groupKeys.insert(key) } }
                .accessibilityElement()
                .accessibilityLabel(title)
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("canvas.pick.\(title)")
        }
    }

    private func groupBar(_ value: CanvasBoardSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.on.square.dashed").foregroundStyle(Amb.primary)
            Text(groupKeys.count < 2 ? "Tap two or more items to group them." : "\(groupKeys.count) items")
                .font(.amb(.subheadline)).lineLimit(2)
            Spacer()
            Button("Cancel") { grouping = false; groupKeys = [] }.buttonStyle(.bordered).accessibilityIdentifier("canvas.group.cancel")
            Button("Group") {
                let keys = Array(groupKeys).sorted()
                let layouts = value.scene.naplets.filter { keys.contains(CanvasEditor.itemKey("naplet", $0.id)) }.map(\.layout)
                    + value.scene.elements.filter { keys.contains(CanvasEditor.itemKey("element", $0.id)) }.map(\.layout)
                grouping = false; groupKeys = []
                run { e, c, w in
                    let id = try await e.createElement(c, w, canvasId: canvasId, .group(members: keys), layout: CanvasEditor.groupBounds(layouts))
                    await MainActor.run { selectedElement = id }
                }
            }
            .buttonStyle(.borderedProminent).disabled(groupKeys.count < 2 || busy).accessibilityIdentifier("canvas.group.confirm")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas.groupBar")
    }

    private func saveText(_ text: String, _ element: CanvasElement?, _ value: CanvasBoardSnapshot) {
        textSheet = nil
        if let element {
            guard text != element.text else { return }
            run { e, c, w in try await e.updateElement(c, w, canvasId: canvasId, element: element, data: ["text": text]) }
            return
        }
        let centre = screenCentre(value), z = topZ(value) + 1
        let layout = CanvasLayout(x: centre.x - 120, y: centre.y - 60, width: 240, height: 120, z: z)
        run { e, c, w in
            let id = try await e.createElement(c, w, canvasId: canvasId, .text(text), layout: layout)
            await MainActor.run { selectedElement = id }
        }
    }

    private func createBoard(title: String, channelId: String, _ value: CanvasBoardSnapshot) {
        creatingBoard = false
        let centre = screenCentre(value), z = topZ(value) + 1
        let layout = CanvasLayout(x: centre.x - 320, y: centre.y - 230, width: 640, height: 460, z: z)
        run { e, c, w in try await e.createBoard(c, w, canvasId: canvasId, channelId: channelId, title: title, layout: layout) }
    }

    private func remove(_ naplet: CanvasNaplet) {
        removing = nil
        run { e, c, w in try await e.removeNaplet(c, w, canvasId: canvasId, naplet: naplet) }
    }

    /// Places a new item at the middle of what is on screen, above everything else.
    private func add(_ choice: CanvasSourceChoice, _ value: CanvasBoardSnapshot) {
        showAdd = false
        let vp = viewport ?? fitted(value, boardSize)
        viewport = vp
        let board = choice.type == .excalidraw || choice.type == .taskTree
        let width = board ? 640.0 : 380.0, height = board ? 460.0 : 280.0
        let centre = (x: (Double(boardSize.width) / 2 - vp.x) / vp.scale, y: (Double(boardSize.height) / 2 - vp.y) / vp.scale)
        let z = (value.scene.naplets.map(\.layout.z).max() ?? 0) + 1
        let layout = CanvasLayout(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height, z: z)
        editing = true
        if choice.type == .taskTree {
            run { e, c, w in try await e.addTaskTree(c, w, canvasId: canvasId, channelId: choice.sourceId, layout: layout) }
        } else {
            run { e, c, w in try await e.addNaplet(c, w, canvasId: canvasId, type: choice.type, sourceId: choice.sourceId, layout: layout) }
        }
    }

    private func rename(_ value: CanvasBoardSnapshot) {
        guard let canvas = value.canvas else { return }
        let title = renameTitle
        run { e, c, w in try await e.renameCanvas(c, w, canvas: canvas, title: title) }
    }

    /// One edit at a time, like sol's mutation queue: the next waits for Tower's answer and the refreshed board.
    private func run(failed: @escaping () -> Void = {}, _ body: @escaping @Sendable (CanvasEditor, ConnectionRecord, WorkspaceRecord) async throws -> Void) {
        guard !busy else { failed(); return }
        busy = true; editError = nil
        Task {
            let result = await model.editCanvas(body)
            busy = false
            if case .failure(let error) = result {
                failed()
                editError = error.localizedDescription
                if error == .canvasUnavailable { editing = false }
            }
        }
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
        case .taskTree:
            route = nil
            focused = n
        case .taskList(let channel, _):
            // A channel's tasks open in Tasks with that channel as the context (the board position is kept for return).
            route = nil
            if let scope = model.navigation.value.channel(channel)?.scopeId {
                model.selectContext(WorkContext(scopeId: scope, channelId: channel))
                model.show(.tasks)
            } else { model.notice = "This channel is not available on this \(Device.name)." }
        case .unknown, .denied: route = nil
        }
        if let route { pushRoute(route) }
    }

    @Environment(\.pushRoute) private var pushRoute
}

/// Presents a naplet at full size; a route chosen inside is pushed on the board's stack once the cover has closed.
private struct FocusCover<Cover: View>: ViewModifier {
    @Environment(\.pushRoute) private var pushRoute
    @Binding var focused: CanvasNaplet?
    @Binding var route: WorkRoute?
    @ViewBuilder let content: (CanvasNaplet) -> Cover

    func body(content view: Content) -> some View {
        view
            .coverSheet(isPresented: Binding(get: { focused != nil }, set: { if !$0 { focused = nil } })) {
                if let focused { content(focused) }
            }
            .onChange(of: focused) { _, now in if now == nil, let next = route { route = nil; pushRoute(next) } }
    }
}

/// Chooses something stored on this device to place on the canvas (sol's add dialog). Tower authorizes it when added.
struct CanvasAddItemSheet: View {
    let workspace: WorkspaceRecord
    let canvasId: String
    let store: LocalStore
    let choose: (CanvasSourceChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [CanvasSourceChoice] = []
    @State private var loaded = false
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(CanvasEditor.SourceType.allCases, id: \.self) { type in
                    let rows = filtered.filter { $0.type == type }
                    if !rows.isEmpty {
                        Section(Self.sectionTitle(type)) {
                            ForEach(rows) { choice in
                                Button { choose(choice) } label: { Label(choice.title, systemImage: Self.icon(type)).appRowTextSize() }
                                    .accessibilityIdentifier("canvas.add.\(choice.title)")
                            }
                        }
                    }
                }
            }
            .overlay {
                if loaded && filtered.isEmpty {
                    EmptyNote(title: "Nothing to add", systemImage: "tray", detail: search.isEmpty ? "Documents, tasks, conversations and files on this \(Device.name) appear here." : "No match for “\(search)”.")
                }
            }
            .searchable(text: $search)
            .navigationTitle("Add to canvas")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            let w = workspace.id, c = canvasId, store = store
            choices = (try? await store.reader.canvasSourceChoices(workspaceId: w, excludingCanvas: c)) ?? []
            loaded = true
        }
    }

    private var filtered: [CanvasSourceChoice] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? choices : choices.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    static func sectionTitle(_ type: CanvasEditor.SourceType) -> String {
        switch type {
        case .document: "Documents"
        case .taskList: "Channel tasks"
        case .taskTree: "Task trees"
        case .chatThread: "Conversations"
        case .html: "Web content"
        case .excalidraw: "Excalidraw boards"
        case .canvas: "Canvases"
        }
    }

    static func icon(_ type: CanvasEditor.SourceType) -> String {
        switch type {
        case .document: "doc.text"
        case .taskList: "checklist"
        case .taskTree: "point.3.connected.trianglepath.dotted"
        case .chatThread: "bubble.left.and.bubble.right"
        case .html: "globe"
        case .excalidraw: "scribble.variable"
        case .canvas: "rectangle.3.group"
        }
    }
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
        case .taskTree(_, let channel, _, _):
            Text("Task tree for #\(channel ?? "channel"). Select it to see and add tasks.")
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
            Label("“\(type)” items are not shown on \(Device.name) yet.", systemImage: "questionmark.square.dashed").font(.system(size: 13)).foregroundStyle(Amb.mutedForeground).padding(10)
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

/// An Excalidraw board full screen in the embedded editor: Excalidraw's toolbar, drawing, library, images and comments,
/// with the board's save status and version history in the navigation bar. Read-only when Tower does not grant
/// `file.write`, while viewing an older version, or while the identity is locked.
struct BoardSceneView: View {
    @Environment(AppModel.self) private var model
    let canvasId: String
    let napletId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var board = LiveQuery<BoardSnapshot>(initial: BoardSnapshot())
    @State private var session: BoardSession?

    struct BoardSnapshot: Sendable, Equatable {
        var title = "Board"
        var reference: BoardReference?
        var loaded = false
    }

    var body: some View {
        let value = board.value
        VStack(spacing: 0) {
            if let session {
                BoardNotices(session: session).padding(.horizontal, 12).padding(.vertical, 4)
                BoardEditorPanel(session: session)
            } else if value.loaded {
                EmptyNote(title: "Board unavailable", systemImage: "lock",
                          detail: model.canRead ? "This board is no longer on this canvas." : "Unlock to load it.")
            } else {
                ProgressView("Loading board…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(value.title)
        .inlineTitle()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let session {
                    BoardStatusPill(state: session.state)
                    BoardMenu(session: session)
                }
            }
        }
        .fixtureLabel()
        .onChange(of: value.reference) { _, ref in attach(ref, value.title) }
        .task {
            let w = workspace.id, canvas = canvasId, naplet = napletId, store = store
            board.start(store: store, matches: { $0.workspaceId == w && $0.table == .canvases }) {
                guard let snapshot = try await store.reader.canvasSnapshot(workspaceId: w, canvasId: canvas),
                      let n = try CanvasScene.parse(snapshot.bytes).naplets.first(where: { $0.id == naplet }),
                      case .excalidraw(let ref) = n.content else { return BoardSnapshot(loaded: true) }
                return BoardSnapshot(title: n.title, reference: ref, loaded: true)
            }
            attach(board.value.reference, board.value.title)
        }
    }

    private func attach(_ reference: BoardReference?, _ title: String) {
        guard let reference else { return }
        session = model.boardSession(reference, title: title, in: workspace, canvasId: canvasId)
    }
}

/// Text for a new text element, or the text of one being edited (sol's inline text editor).
struct CanvasTextSheet: View {
    let initial: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .font(.amb(.body))
                .padding(12)
                .accessibilityIdentifier("canvas.text.field")
                .navigationTitle(initial.isEmpty ? "New text" : "Edit text")
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(initial.isEmpty ? "Add" : "Save") { save(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("canvas.text.save")
                    }
                }
        }
        .presentationDetents([.medium])
        .onAppear { text = initial; focused = true }
    }
}

/// A new Excalidraw board (sol's "Create board"): a name and the channel its File is kept in.
struct NewBoardSheet: View {
    let channels: [ChannelRecord]
    let labels: [String: String]
    let preferred: String?
    let create: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var channel = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Board name", text: $title).accessibilityIdentifier("canvas.board.title")
                Picker("Channel", selection: $channel) {
                    ForEach(channels) { c in Text("#" + (labels[c.id] ?? c.name)).tag(c.id) }
                }
                .accessibilityIdentifier("canvas.board.channel")
                Text("The board is saved as a file in this channel and placed on the canvas. People who can read the channel can open it.")
                    .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            }
            .macGroupedForm()
            .navigationTitle("New whiteboard")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create(title, channel) }.disabled(channel.isEmpty).accessibilityIdentifier("canvas.board.create")
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { channel = preferred.flatMap { id in channels.contains { $0.id == id } ? id : nil } ?? channels.first?.id ?? "" }
    }
}
