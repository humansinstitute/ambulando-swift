import XCTest
@testable import AmbulandoCore

/// Drawing elements (text, shapes, arrows), duplicates and new Excalidraw boards against `SampleSurfaceTower` and the
/// sample work routes, which follow Tower's checks (`can_manage`, validation, `expected_row_version`).
final class CanvasElementEditingTests: XCTestCase {
    private func editor(_ h: SurfaceHarness) -> CanvasEditor { CanvasEditor(sync: h.sync) }

    private func scene(_ h: SurfaceHarness, _ canvas: String) async throws -> CanvasScene {
        let stored = try await h.store.reader.canvasSnapshot(workspaceId: h.workspace.id, canvasId: canvas)
        return try CanvasScene.parse(try XCTUnwrap(stored).bytes)
    }

    private func storedElement(_ h: SurfaceHarness, _ canvas: String, _ id: String?) async throws -> CanvasElement {
        let elements = try await scene(h, canvas).elements
        return try XCTUnwrap(elements.first { $0.id == id })
    }

    private func open(_ h: SurfaceHarness, _ canvas: String) async {
        await h.sync.refreshCanvases(h.connection, h.workspace)
        await h.sync.refreshCanvas(h.connection, h.workspace, canvasId: canvas)
        await h.idle()
    }

    func testTextElementCreateEditMoveAndDeleteWithVersionChecks() async throws {
        let h = try await SurfaceHarness.make()
        let canvas = h.tower.seedCanvas(title: "Board", position: 1)
        await open(h, canvas)

        do {
            try await editor(h).createElement(h.connection, h.workspace, canvasId: canvas, .text("   "), layout: CanvasLayout(x: 0, y: 0, width: 240, height: 120, z: 1))
            XCTFail("empty text is refused before sending")
        } catch let error as CanvasEditError { XCTAssertEqual(error, .invalid("Text can't be empty.")) }

        let id = try await editor(h).createElement(h.connection, h.workspace, canvasId: canvas, .text("Kick-off"),
                                                   layout: CanvasLayout(x: 10.4, y: 20, width: 2, height: 9000, z: 3))
        var element = try await storedElement(h, canvas, id)
        XCTAssertEqual(element.text, "Kick-off")
        XCTAssertEqual(element.layout, CanvasLayout(x: 10, y: 20, width: 8, height: 4000, z: 3), "clamped to Tower's element bounds")
        XCTAssertEqual(element.rowVersion, 1)

        // A data key this build does not draw survives a text edit (the saved data is patched, as sol merges it).
        element = CanvasElement(id: element.id, kind: element.kind, kindName: element.kindName, layout: element.layout, text: element.text,
                                fontSize: element.fontSize, start: element.start, end: element.end, curve: element.curve, lineStyle: element.lineStyle,
                                startArrowhead: element.startArrowhead, endArrowhead: element.endArrowhead, points: element.points, isGroup: false,
                                rowVersion: element.rowVersion, savedLayout: element.savedLayout,
                                savedData: try JSONSerialization.data(withJSONObject: ["text": "Kick-off", "colour": "violet"]))
        try await editor(h).updateElement(h.connection, h.workspace, canvasId: canvas, element: element, data: ["text": "Kick-off notes", "fontSize": 24])
        var edited = try await storedElement(h, canvas, id)
        XCTAssertEqual(edited.text, "Kick-off notes")
        XCTAssertEqual(edited.fontSize, 24)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: edited.savedData) as? [String: Any])?["colour"] as? String, "violet")
        XCTAssertEqual(edited.rowVersion, 2)

        // A stale edit (the version read before) is refused and never replayed.
        do {
            try await editor(h).updateElement(h.connection, h.workspace, canvasId: canvas, element: element, layout: CanvasLayout(x: 1, y: 1, width: 100, height: 50, z: 3))
            XCTFail("a stale edit must be refused")
        } catch let error as CanvasEditError { XCTAssertEqual(error, .conflict) }

        try await editor(h).updateElement(h.connection, h.workspace, canvasId: canvas, element: edited, layout: CanvasLayout(x: 300, y: 200, width: 320, height: 90, z: 9))
        edited = try await storedElement(h, canvas, id)
        XCTAssertEqual(edited.layout, CanvasLayout(x: 300, y: 200, width: 320, height: 90, z: 9))

        try await editor(h).duplicate(h.connection, h.workspace, canvasId: canvas, element: edited, topZ: 9)
        let copies = try await scene(h, canvas).elements
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(copies.last?.layout, CanvasLayout(x: 324, y: 224, width: 320, height: 90, z: 10))
        XCTAssertEqual(copies.last?.text, "Kick-off notes")

        try await editor(h).deleteElement(h.connection, h.workspace, canvasId: canvas, element: edited)
        let left = try await scene(h, canvas).elements
        XCTAssertEqual(left.count, 1)
        XCTAssertNotEqual(left.first?.id, id)
    }

    func testShapesAndArrowsUseTheWebGeometry() async throws {
        let h = try await SurfaceHarness.make()
        let canvas = h.tower.seedCanvas(title: "Board", position: 1)
        await open(h, canvas)
        try await editor(h).createElement(h.connection, h.workspace, canvasId: canvas, .shape(.ellipse), layout: CanvasLayout(x: 0, y: 0, width: 200, height: 120, z: 1))
        try await editor(h).createElement(h.connection, h.workspace, canvasId: canvas, .arrow(from: [400, 300], to: [100, 340]),
                                          layout: CanvasLayout(x: 0, y: 0, width: 8, height: 8, z: 2))
        let elements = try await scene(h, canvas).elements
        XCTAssertEqual(elements.map(\.kind), [.ellipse, .arrow])
        let arrow = try XCTUnwrap(elements.last)
        XCTAssertEqual(arrow.layout, CanvasLayout(x: 100, y: 300, width: 300, height: 40, z: 2), "the frame spans both ends")
        XCTAssertEqual(arrow.start, [300, 0])
        XCTAssertEqual(arrow.end, [0, 40])
        XCTAssertEqual(arrow.endArrowhead, "triangle")
        do {
            try await editor(h).createElement(h.connection, h.workspace, canvasId: canvas, .shape(.text), layout: CanvasLayout(x: 0, y: 0, width: 10, height: 10, z: 1))
            XCTFail("only shapes are created as shapes")
        } catch let error as CanvasEditError { XCTAssertEqual(error, .invalid("That shape can't be drawn here.")) }
    }

    func testLinesFramesGroupsAndArrowEditing() async throws {
        let h = try await SurfaceHarness.make()
        let canvas = h.tower.seedCanvas(title: "Board", position: 1)
        await open(h, canvas)
        let z = CanvasLayout(x: 0, y: 0, width: 8, height: 8, z: 4)
        let line = try await editor(h).createElement(h.connection, h.workspace, canvasId: canvas, .arrow(from: [0, 0], to: [100, 50], line: true), layout: z)
        let frame = try await editor(h).createElement(h.connection, h.workspace, canvasId: canvas, .frame, layout: CanvasLayout(x: 200, y: 200, width: 300, height: 200, z: 5))
        var elements = try await scene(h, canvas).elements
        let drawnLine = try XCTUnwrap(elements.first { $0.id == line })
        XCTAssertEqual(drawnLine.kind, .line)
        XCTAssertEqual(drawnLine.endArrowhead, "none", "a line has no arrowhead")
        XCTAssertEqual(elements.first { $0.id == frame }?.kind, .frame)
        XCTAssertEqual(elements.first { $0.id == frame }?.isGroup, false)

        // A group needs two items; it sits around them, one layer below the lowest.
        do {
            try await editor(h).createElement(h.connection, h.workspace, canvasId: canvas, .group(members: ["element:x"]), layout: z)
            XCTFail("one item is not a group")
        } catch let error as CanvasEditError { XCTAssertEqual(error, .invalid("Choose at least two items to group.")) }
        let members = elements.map { CanvasEditor.itemKey("element", $0.id) }
        let bounds = CanvasEditor.groupBounds(elements.map(\.layout))
        XCTAssertEqual(bounds, CanvasLayout(x: -32, y: -32, width: 564, height: 464, z: 3))
        let group = try await editor(h).createElement(h.connection, h.workspace, canvasId: canvas, .group(members: members), layout: bounds)
        elements = try await scene(h, canvas).elements
        let made = try XCTUnwrap(elements.first { $0.id == group })
        XCTAssertTrue(made.isGroup)
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: made.savedData) as? [String: Any])
        XCTAssertEqual(data["members"] as? [String], members)

        // Arrow style, heads and an end dragged to a new point.
        let arrowId = try await editor(h).createElement(h.connection, h.workspace, canvasId: canvas, .arrow(from: [0, 0], to: [100, 0]), layout: z)
        var arrow = try await storedElement(h, canvas, arrowId)
        try await editor(h).updateElement(h.connection, h.workspace, canvasId: canvas, element: arrow, data: ["lineStyle": "dashed", "startArrowhead": "circle"])
        arrow = try await storedElement(h, canvas, arrowId)
        XCTAssertEqual(arrow.lineStyle, "dashed")
        XCTAssertEqual(arrow.startArrowhead, "circle")
        let moved = CanvasEditor.movingEnd(arrow, start: false, to: [60, 80])
        try await editor(h).updateElement(h.connection, h.workspace, canvasId: canvas, element: arrow, layout: moved.layout, data: moved.data)
        arrow = try await storedElement(h, canvas, arrowId)
        let ends = CanvasEditor.endPoints(arrow)
        XCTAssertEqual(ends.start, [0, 0], "the other end stays")
        XCTAssertEqual(ends.end, [60, 80])
        XCTAssertEqual(arrow.lineStyle, "dashed", "style kept through the move")
    }

    func testDuplicateNapletKeepsItsSourceAndRefusesLockedItems() async throws {
        let h = try await SurfaceHarness.make()
        let canvas = h.tower.seedCanvas(title: "Board", position: 1)
        let doc = UUID().uuidString.lowercased(), hidden = UUID().uuidString.lowercased()
        h.tower.seedRecord(id: doc, type: "doc", title: "Plan", channel: Fixtures.channel1, scope: Fixtures.scopeA)
        h.tower.seedRecord(id: hidden, type: "doc", title: "Secret", channel: Fixtures.channel1, scope: Fixtures.scopeA)
        h.tower.seedNaplet(canvas: canvas, sourceType: "document", sourceId: doc, title: "Plan", layout: ["x": 10, "y": 10, "width": 360, "height": 280, "z": 4], content: ["body": ""])
        h.tower.seedNaplet(canvas: canvas, sourceType: "document", sourceId: hidden, title: "Secret", layout: ["x": 500, "y": 10, "width": 360, "height": 280, "z": 5], content: ["body": ""])
        h.tower.deny(record: hidden)
        await open(h, canvas)
        let naplets = try await scene(h, canvas).naplets
        let plan = try XCTUnwrap(naplets.first { $0.title == "Plan" })
        XCTAssertEqual(plan.sourceId, doc)
        try await editor(h).duplicate(h.connection, h.workspace, canvasId: canvas, naplet: plan, topZ: 5)
        let after = try await scene(h, canvas).naplets.filter { $0.title == "Plan" }
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after.last?.layout, CanvasLayout(x: 34, y: 34, width: 360, height: 280, z: 6))
        let locked = try XCTUnwrap(naplets.first { !$0.isReady })
        do {
            try await editor(h).duplicate(h.connection, h.workspace, canvasId: canvas, naplet: locked, topZ: 6)
            XCTFail("a locked item can't be copied")
        } catch let error as CanvasEditError { XCTAssertEqual(error, .invalid("Restricted items can't be duplicated.")) }
    }

    func testNewBoardIsAFileWithAnEmptyScenePlacedOnTheCanvas() async throws {
        let h = try await SurfaceHarness.make()
        let canvas = h.tower.seedCanvas(title: "Board", position: 1)
        let work = h.work.work
        h.tower.recordLookup = { id in work.file(id).map { ["title": $0["display_name"] ?? "", "channel_id": $0["channel_id"] ?? NSNull()] } }
        await open(h, canvas)
        try await editor(h).createBoard(h.connection, h.workspace, canvasId: canvas, channelId: Fixtures.channel1, title: "Sketches",
                                        layout: CanvasLayout(x: 100, y: 100, width: 300, height: 200, z: 1))
        let placed = try await scene(h, canvas).naplets
        let naplet = try XCTUnwrap(placed.first)
        XCTAssertEqual(naplet.sourceType, "excalidraw")
        XCTAssertEqual(naplet.title, "Sketches")
        XCTAssertEqual(naplet.layout.width, 640, "boards open at the web's board size")
        let file = try XCTUnwrap(work.file(try XCTUnwrap(naplet.sourceId)))
        XCTAssertEqual(file["display_name"] as? String, BoardScene.fileName("Sketches"))
        let bytes = try XCTUnwrap(work.completedObjectBytes(try XCTUnwrap(file["storage_object_id"] as? String)))
        let scene = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(scene["type"] as? String, "excalidraw")
        XCTAssertEqual((scene["elements"] as? [Any])?.count, 0)
    }
}
