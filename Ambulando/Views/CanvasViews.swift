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

    struct LayoutOverride: Equatable { var layout: CanvasLayout; var version: Int }

    var body: some View {
        let value = snapshot.value
        GeometryReader { proxy in
            let vp = viewport ?? fitted(value, proxy.size)
            ZStack(alignment: .topLeading) {
                Amb.muted.opacity(0.5)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil }
                CanvasElementsLayer(elements: value.scene.elements, transform: transform(vp))
                let shownNaplets = visible(value.scene.naplets, vp, proxy.size)
                let live = liveBoards(shownNaplets, vp)
                ForEach(shownNaplets) { naplet in
                    napletView(naplet, value, vp, live: live.contains(naplet.id))
                }
                if let id = selected, let naplet = value.scene.naplets.first(where: { $0.id == id }), movable(naplet) {
                    resizeHandle(naplet, vp)
                }
            }
            .clipped()
            // A selected live board takes its own touches (drawing, Excalidraw's pan and zoom); the canvas pans again
            // once the board is deselected.
            .gesture(panAndZoom(vp), including: boardActive(value) ? .subviews : .all)
            .onChange(of: viewport) { _, next in if let next { model.canvasViewports[canvasId] = next } }
            .onAppear { boardSize = proxy.size }
            .onChange(of: proxy.size) { _, size in boardSize = size }
        }
        .onChange(of: value.scene.naplets) { _, naplets in
            // A newer stored version (this edit or someone else's) replaces the dragged position.
            let versions = Dictionary(naplets.map { ($0.id, $0.rowVersion) }, uniquingKeysWith: { a, _ in a })
            overrides = overrides.filter { versions[$0.key] == $0.value.version }
            if let id = selected, versions[id] == nil { selected = nil }
        }
        .onChange(of: canEdit(value)) { _, allowed in if !allowed { editing = false } }
        .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar(value) }
        .safeAreaInset(edge: .top, spacing: 0) { notices(value) }
        .navigationTitle(value.canvas?.title ?? "Canvas")
        .inlineTitle()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if editing {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .disabled(busy)
                        .accessibilityLabel("Add item").accessibilityIdentifier("canvas.add")
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
        }
        .sheet(isPresented: $showItems, onDismiss: { if let next = pendingOpen { pendingOpen = nil; open(next) } }) { itemsSheet(value) }
        .sheet(isPresented: $showAdd) {
            CanvasAddItemSheet(workspace: workspace, canvasId: canvasId, store: store) { choice in add(choice, value) }
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
            placed(BoardNapletWindow(naplet: naplet, reference: ref, workspace: workspace, preview: value.boards[naplet.id], selected: selected == naplet.id,
                                     live: live, layoutEditing: editing, onSelect: { selected = naplet.id }, onExpand: { open(naplet) }), naplet, vp)
                .gesture(editGesture(naplet, vp, resize: false), including: movable(naplet) ? .all : .subviews)
                .task(id: naplet.id) { requestBoardIfNeeded(naplet, value) }
        } else {
            cardView(naplet, value, vp)
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
        let boards = naplets.filter { if case .excalidraw = $0.content { true } else { false } }
        let ranked = boards.sorted { a, b in
            if (a.id == selected) != (b.id == selected) { return a.id == selected }
            return a.layout.width * a.layout.height > b.layout.width * b.layout.height
        }
        return Set(ranked.filter { $0.id == selected || $0.layout.width * vp.scale >= Self.liveBoardMinWidth }.prefix(Self.liveBoardLimit).map(\.id))
    }

    /// A selected board that is not being moved takes the touches inside its window.
    private func boardActive(_ value: CanvasBoardSnapshot) -> Bool {
        guard !editing, let id = selected, let naplet = value.scene.naplets.first(where: { $0.id == id }), case .excalidraw = naplet.content else { return false }
        return true
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
                .font(.caption).foregroundStyle(Amb.mutedForeground)
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

    @ViewBuilder private func selectionBar(_ value: CanvasBoardSnapshot) -> some View {
        if let id = selected, let naplet = value.scene.naplets.first(where: { $0.id == id }) {
            HStack(spacing: 10) {
                Image(systemName: NapletCard.icon(naplet.content)).foregroundStyle(Amb.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(naplet.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(NapletCard.kindLabel(naplet.content)).font(.caption).foregroundStyle(Amb.mutedForeground)
                }
                Spacer()
                if editing {
                    if busy { ProgressView() }
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

    private func remove(_ naplet: CanvasNaplet) {
        removing = nil
        run { e, c, w in try await e.removeNaplet(c, w, canvasId: canvasId, naplet: naplet) }
    }

    /// Places a new item at the middle of what is on screen, above everything else.
    private func add(_ choice: CanvasSourceChoice, _ value: CanvasBoardSnapshot) {
        showAdd = false
        let vp = viewport ?? fitted(value, boardSize)
        viewport = vp
        let board = choice.type == .excalidraw
        let width = board ? 640.0 : 380.0, height = board ? 460.0 : 280.0
        let centre = (x: (Double(boardSize.width) / 2 - vp.x) / vp.scale, y: (Double(boardSize.height) / 2 - vp.y) / vp.scale)
        let z = (value.scene.naplets.map(\.layout.z).max() ?? 0) + 1
        let layout = CanvasLayout(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height, z: z)
        editing = true
        run { e, c, w in try await e.addNaplet(c, w, canvasId: canvasId, type: choice.type, sourceId: choice.sourceId, layout: layout) }
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
        case .taskList(let channel, _), .taskTree(let channel, _):
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
                                Button { choose(choice) } label: { Label(choice.title, systemImage: Self.icon(type)) }
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
        case .taskTree(_, let channel):
            Text("Task tree for #\(channel ?? "channel"). Opens as the channel's task list on \(Device.name) (the tree graph is web-only).")
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
        session = model.boardSession(reference, title: title, in: workspace)
    }
}
