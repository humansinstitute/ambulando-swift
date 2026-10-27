import Foundation

// Drawing elements, new boards and duplicates on a canvas (sol `canvas/page.js` and `sync-service.js`):
//
// - `POST   /canvases/:c/elements` `{ kind, layout, data }` (a text element needs text)
// - `PATCH  /canvases/:c/elements/:e` `{ layout?, data?, expected_row_version }`
// - `DELETE /canvases/:c/elements/:e` `{ expected_row_version }`
// - a new Excalidraw board: its empty scene uploaded (storage prepare, upload, complete), `POST /channels/:ch/files`
//   with `metadata.kind = excalidraw_board`, then an `excalidraw` naplet linked to the new File (sol `createBoardNaplet`)
//
// Each is one confirmed request with Tower's version check, followed by a fresh snapshot, like the naplet edits.

extension CanvasEditor {
    /// Tower's element layout bounds (`normalizeFlightDeckPgCanvasElementLayout`).
    public static let elementSize = (min: 8.0, max: 4000.0)
    /// The kinds this build creates (sol's tools): text, rectangle, ellipse, diamond, arrow, line, frame and group frames.
    public enum NewElement: Sendable, Equatable {
        case text(String)
        case shape(CanvasElement.Kind)
        /// An arrow, or a plain line, between two canvas points.
        case arrow(from: [Double], to: [Double], line: Bool = false)
        /// A visible frame (sol's frame tool).
        case frame
        /// A group frame around canvas items (sol `createGroup`): `members` are their `naplet:<id>` / `element:<id>` keys.
        case group(members: [String])
    }

    /// An item's key in a group's `members` (sol `canvasItemKey`).
    public static func itemKey(_ type: String, _ id: String) -> String { "\(type):\(id)" }

    /// The frame around items with sol's 32-point padding, one layer below the lowest of them (sol `groupBounds`).
    public static func groupBounds(_ items: [CanvasLayout], padding: Double = 32) -> CanvasLayout {
        guard let first = items.first else { return CanvasLayout(x: 0, y: 0, width: 8, height: 8, z: 1) }
        let minX = items.map(\.x).min() ?? first.x, minY = items.map(\.y).min() ?? first.y
        let maxX = items.map { $0.x + $0.width }.max() ?? first.x, maxY = items.map { $0.y + $0.height }.max() ?? first.y
        return CanvasLayout(x: minX - padding, y: minY - padding, width: maxX - minX + padding * 2, height: maxY - minY + padding * 2,
                            z: max(1, (items.map(\.z).min() ?? 1) - 1))
    }

    /// sol `arrowGeometry`: the frame spans both canvas points (at least 8 points); the ends are relative to its corner.
    static func arrowGeometry(from: [Double], to: [Double], z: Int) -> (layout: CanvasLayout, start: [Double], end: [Double]) {
        let x = min(from[0], to[0]), y = min(from[1], to[1])
        let box = elementLayout(CanvasLayout(x: x, y: y, width: max(8, abs(to[0] - from[0])), height: max(8, abs(to[1] - from[1])), z: z))
        return (box, [(from[0] - box.x).rounded(), (from[1] - box.y).rounded()], [(to[0] - box.x).rounded(), (to[1] - box.y).rounded()])
    }

    /// The canvas points of an arrow's or line's ends.
    public static func endPoints(_ e: CanvasElement) -> (start: [Double], end: [Double]) {
        ([e.layout.x + e.start[0], e.layout.y + e.start[1]], [e.layout.x + e.end[0], e.layout.y + e.end[1]])
    }

    /// Moves one end of an arrow or line to a canvas point, keeping the other end and any bend where they are (sol
    /// `moveArrowEndpoint`): the new frame and the data keys for `updateElement`.
    public static func movingEnd(_ e: CanvasElement, start moveStart: Bool, to point: [Double]) -> (layout: CanvasLayout, data: [String: Any]) {
        let ends = endPoints(e)
        let a = moveStart ? point : ends.start, b = moveStart ? ends.end : point
        guard let curve = e.curve else {
            let g = arrowGeometry(from: a, to: b, z: e.layout.z)
            return (g.layout, ["start": g.start, "end": g.end])
        }
        let bend = [e.layout.x + curve[0], e.layout.y + curve[1]]
        let left = min(a[0], b[0], bend[0]), top = min(a[1], b[1], bend[1])
        let box = elementLayout(CanvasLayout(x: left, y: top, width: max(8, max(a[0], b[0], bend[0]) - left),
                                             height: max(8, max(a[1], b[1], bend[1]) - top), z: e.layout.z))
        func relative(_ p: [Double]) -> [Double] { [(p[0] - box.x).rounded(), (p[1] - box.y).rounded()] }
        return (box, ["start": relative(a), "end": relative(b), "curve": relative(bend)])
    }

    public static func elementLayout(_ layout: CanvasLayout) -> CanvasLayout {
        CanvasLayout(x: layout.x.rounded(), y: layout.y.rounded(),
                     width: min(elementSize.max, max(elementSize.min, layout.width.rounded())),
                     height: min(elementSize.max, max(elementSize.min, layout.height.rounded())),
                     z: min(100_000, max(1, layout.z)))
    }

    /// The body sol sends to create an element of `kind` at `layout`.
    static func elementBody(_ element: NewElement, layout: CanvasLayout) throws -> [String: Any] {
        let frame = elementLayout(layout)
        switch element {
        case .text(let text):
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw CanvasEditError.invalid("Text can't be empty.") }
            return ["kind": "text", "layout": layoutObject(frame, base: [:]), "data": ["text": value]]
        case .shape(let kind):
            guard [.rectangle, .ellipse, .diamond].contains(kind) else { throw CanvasEditError.invalid("That shape can't be drawn here.") }
            return ["kind": kind.rawValue, "layout": layoutObject(frame, base: [:]), "data": [String: Any]()]
        case .arrow(let from, let to, let line):
            let g = arrowGeometry(from: from, to: to, z: frame.z)
            var data: [String: Any] = ["start": g.start, "end": g.end]
            if !line { data["direction"] = "forward" }
            return ["kind": line ? "line" : "arrow", "layout": layoutObject(g.layout, base: [:]), "data": data]
        case .frame:
            return ["kind": "frame", "layout": layoutObject(frame, base: [:]), "data": [String: Any]()]
        case .group(let members):
            guard members.count >= 2 else { throw CanvasEditError.invalid("Choose at least two items to group.") }
            return ["kind": "frame", "layout": layoutObject(frame, base: [:]), "data": ["role": "group", "label": "Group", "members": members]]
        }
    }

    /// Creates a drawing element and returns its id once the board has been read again.
    @discardableResult
    public func createElement(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, _ element: NewElement,
                              layout: CanvasLayout) async throws -> String? {
        let object = try await send(connection, workspace, method: "POST", path: try Self.canvasPath(workspace, canvasId) + "/elements",
                                    body: try Self.elementBody(element, layout: layout), canvasId: canvasId)
        try await reloadSnapshot(connection, workspace, canvasId: canvasId)
        return (object["element"] as? [String: Any])?["id"] as? String
    }

    /// Moves or resizes an element and/or replaces keys of its data (text, font size, line style, arrowheads), keeping
    /// the saved keys it does not change.
    public func updateElement(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, element: CanvasElement,
                              layout: CanvasLayout? = nil, data: [String: Any]? = nil) async throws {
        var body: [String: Any] = ["expected_row_version": element.rowVersion]
        if let layout {
            let base = ((try? JSONSerialization.jsonObject(with: element.savedLayout)) as? [String: Any]) ?? [:]
            body["layout"] = Self.layoutObject(Self.elementLayout(layout), base: base)
        }
        if let data {
            var merged = ((try? JSONSerialization.jsonObject(with: element.savedData)) as? [String: Any]) ?? [:]
            for (key, value) in data { merged[key] = value is NSNull ? nil : value }
            if element.kind == .text, ((merged["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CanvasEditError.invalid("Text can't be empty.")
            }
            body["data"] = merged
        }
        guard body.count > 1 else { return }
        _ = try await send(connection, workspace, method: "PATCH", path: try Self.elementPath(workspace, canvasId, element.id), body: body, canvasId: canvasId)
        try await reloadSnapshot(connection, workspace, canvasId: canvasId)
    }

    public func deleteElement(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, element: CanvasElement) async throws {
        _ = try await send(connection, workspace, method: "DELETE", path: try Self.elementPath(workspace, canvasId, element.id),
                           body: ["expected_row_version": element.rowVersion], canvasId: canvasId)
        try await reloadSnapshot(connection, workspace, canvasId: canvasId)
    }

    /// A copy of an item 24 points down and right, above everything (sol `duplicateSelected`). A locked item can't be copied.
    public func duplicate(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, naplet: CanvasNaplet, topZ: Int) async throws {
        guard naplet.isReady, let sourceId = naplet.sourceId else { throw CanvasEditError.invalid("Restricted items can't be duplicated.") }
        var layout = ((try? JSONSerialization.jsonObject(with: naplet.savedLayout)) as? [String: Any]) ?? [:]
        layout = Self.layoutObject(Self.clamped(CanvasLayout(x: naplet.layout.x + 24, y: naplet.layout.y + 24, width: naplet.layout.width,
                                                             height: naplet.layout.height, z: topZ + 1)), base: layout)
        if var tree = layout["task_tree"] as? [String: Any] { tree["instance_id"] = UUID().uuidString.lowercased(); layout["task_tree"] = tree }
        try await addNaplet(connection, workspace, canvasId: canvasId, sourceType: naplet.sourceType, sourceId: sourceId, title: naplet.title, layoutObject: layout)
    }

    public func duplicate(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, element: CanvasElement, topZ: Int) async throws {
        let data = ((try? JSONSerialization.jsonObject(with: element.savedData)) as? [String: Any]) ?? [:]
        let frame = Self.elementLayout(CanvasLayout(x: element.layout.x + 24, y: element.layout.y + 24, width: element.layout.width,
                                                    height: element.layout.height, z: topZ + 1))
        _ = try await send(connection, workspace, method: "POST", path: try Self.canvasPath(workspace, canvasId) + "/elements",
                           body: ["kind": element.kindName, "layout": Self.layoutObject(frame, base: [:]), "data": data], canvasId: canvasId)
        try await reloadSnapshot(connection, workspace, canvasId: canvasId)
    }

    /// Creates an empty Excalidraw board as a File in `channelId` and places it on the canvas (sol `createBoardNaplet`).
    /// When the File was made but linking failed, the error says so (the board can be added with Add item).
    public func createBoard(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, canvasId: String, channelId: String, title: String,
                            layout: CanvasLayout) async throws {
        let name = String((title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled board" : title)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(BoardScene.maxTitle))
        do { try await sync.identity.requireSigner(npub: connection.signerNpub) } catch { throw CanvasEditError.locked }
        let api = try sync.api(origin: try TowerOrigin(connection.origin))
        let fileId: String
        do {
            let bytes = try JSONSerialization.data(withJSONObject: BoardScene.empty(), options: [.sortedKeys])
            let objectId = try await api.store(workspaceId: workspace.id, appNpub: workspace.appNpub, bytes: bytes, contentType: BoardScene.contentType,
                                               fileName: BoardScene.fileName(name), prepared: nil, onPrepared: { _ in })
            let created = try await send(connection, workspace, method: "POST", path: try TowerAPI.base(workspace.id) + "/channels/" + TowerAPI.uuid(channelId) + "/files",
                                         body: ["storage_object_id": objectId, "display_name": BoardScene.fileName(name),
                                                "metadata": ["kind": "excalidraw_board", "title": name]], canvasId: nil)
            guard let id = lowerUUID((created["file"] as? [String: Any])?["id"] as? String) else { throw CanvasEditError.unexpected("Tower did not return the new board.") }
            fileId = id
        } catch CanvasEditError.forbidden {
            throw CanvasEditError.invalid("You can't create files in that channel.")
        } catch let error as CanvasEditError {
            throw error
        } catch {
            throw CanvasEditError.offline(error.localizedDescription)
        }
        var frame = Self.clamped(layout)
        frame.width = max(frame.width, 640); frame.height = max(frame.height, 460)
        do {
            try await addNaplet(connection, workspace, canvasId: canvasId, sourceType: "excalidraw", sourceId: fileId, title: name,
                                layoutObject: Self.layoutObject(Self.clamped(frame), base: [:]))
        } catch let error as CanvasEditError {
            if case .savedButNotRefreshed = error { throw error }
            throw CanvasEditError.invalid("The board “\(name)” was saved but couldn't be placed on this canvas (\(error.localizedDescription)). Add it with Add item › Excalidraw boards.")
        }
    }

    static func elementPath(_ workspace: WorkspaceRecord, _ canvasId: String, _ elementId: String) throws -> String {
        try canvasPath(workspace, canvasId) + "/elements/" + TowerAPI.uuid(elementId)
    }
}
