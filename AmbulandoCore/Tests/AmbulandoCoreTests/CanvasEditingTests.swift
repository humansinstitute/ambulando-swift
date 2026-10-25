import XCTest
@testable import AmbulandoCore

/// Canvas create/rename and naplet add/move/resize/remove against `SampleSurfaceTower`, which follows Tower's checks:
/// visibility (404), `can_manage` (403), source authorization (400) and `expected_row_version` (409).
final class CanvasEditingTests: XCTestCase {
    private func editor(_ h: SurfaceHarness) -> CanvasEditor { CanvasEditor(sync: h.sync) }

    private func scene(_ h: SurfaceHarness, _ canvas: String) async throws -> CanvasScene {
        let stored = try await h.store.reader.canvasSnapshot(workspaceId: h.workspace.id, canvasId: canvas)
        return try CanvasScene.parse(try XCTUnwrap(stored).bytes)
    }

    private func storedNaplet(_ h: SurfaceHarness, _ canvas: String, _ id: String? = nil) async throws -> CanvasNaplet {
        let naplets = try await scene(h, canvas).naplets
        return try XCTUnwrap(id.map { id in naplets.first { $0.id == id } } ?? naplets.first)
    }

    private func open(_ h: SurfaceHarness, _ canvas: String) async {
        await h.sync.refreshCanvases(h.connection, h.workspace)
        await h.sync.refreshCanvas(h.connection, h.workspace, canvasId: canvas)
        await h.idle()
    }

    func testCreateAndRenameCanvasWithVersionCheck() async throws {
        let h = try await SurfaceHarness.make()
        let created = try await editor(h).createCanvas(h.connection, h.workspace, title: "  Launch plan  ")
        XCTAssertEqual(created.title, "Launch plan")
        let listed = try await h.store.reader.canvases(workspaceId: h.workspace.id)
        XCTAssertEqual(listed.map(\.title), ["Launch plan"], "the list is stored from Tower's answer")
        XCTAssertTrue(h.tower.canvasWrites.contains { $0.hasPrefix("POST ") && $0.hasSuffix("/canvases") })

        try await editor(h).renameCanvas(h.connection, h.workspace, canvas: created, title: "Launch")
        await h.idle()
        let renamedRow = try await h.store.reader.canvas(workspaceId: h.workspace.id, id: created.id)
        let renamed = try XCTUnwrap(renamedRow)
        XCTAssertEqual(renamed.title, "Launch")
        XCTAssertEqual(renamed.rowVersion, 2)

        // Renaming again from the version read before the first rename is refused, never replayed.
        do {
            try await editor(h).renameCanvas(h.connection, h.workspace, canvas: created, title: "Stale")
            XCTFail("a stale rename must be refused")
        } catch let error as CanvasEditError { XCTAssertEqual(error, .conflict) }
        let after = try await h.store.reader.canvas(workspaceId: h.workspace.id, id: created.id)
        XCTAssertEqual(after?.title, "Launch")

        do { _ = try await editor(h).createCanvas(h.connection, h.workspace, title: "   "); XCTFail() }
        catch let error as CanvasEditError { XCTAssertEqual(error, .invalid("A title is required.")) }
    }

    func testAddMoveResizeAndRemoveNapletKeepsSavedLayoutKeys() async throws {
        let h = try await SurfaceHarness.make()
        let canvas = h.tower.seedCanvas(title: "Board", position: 1)
        let doc = UUID().uuidString.lowercased()
        h.tower.seedRecord(id: doc, type: "doc", title: "Release notes", channel: Fixtures.channel1, scope: Fixtures.scopeA)
        await open(h, canvas)

        try await editor(h).addNaplet(h.connection, h.workspace, canvasId: canvas, type: .document, sourceId: doc,
                                      layout: CanvasLayout(x: 80.4, y: 90, width: 100, height: 5000, z: 2))
        var naplet = try await storedNaplet(h, canvas)
        XCTAssertEqual(naplet.title, "Release notes")
        XCTAssertEqual(naplet.layout, CanvasLayout(x: 80, y: 90, width: 220, height: 1000, z: 2), "clamped to Tower's bounds")

        // A layout key this build does not draw (a task tree's view) survives a move.
        let tree = h.tower.seedNaplet(canvas: canvas, sourceType: "task_tree", sourceId: Fixtures.channel1, title: "Tree",
                                      layout: ["x": 0, "y": 0, "width": 400, "height": 300, "z": 3], content: ["channel_id": Fixtures.channel1])
        h.tower.moveNaplet(tree, layout: ["x": 0, "y": 0, "width": 400, "height": 300, "z": 3])
        await h.sync.refreshCanvas(h.connection, h.workspace, canvasId: canvas, force: true)
        await h.idle()
        // Seed the extra key through a Tower-side write, as the web would have saved it.
        var treeNaplet = try await storedNaplet(h, canvas, tree)
        let withView = try JSONSerialization.data(withJSONObject: ["x": 0, "y": 0, "width": 400, "height": 300, "z": 3,
                                                                   "task_tree": ["root_task_id": NSNull(), "collapsed": [], "upstream": [], "viewport": ["x": 0, "y": 0, "scale": 1]]])
        treeNaplet = CanvasNaplet(id: treeNaplet.id, layout: treeNaplet.layout, title: treeNaplet.title, sourceType: treeNaplet.sourceType,
                                  content: treeNaplet.content, rowVersion: treeNaplet.rowVersion, savedLayout: withView)
        try await editor(h).updateLayout(h.connection, h.workspace, canvasId: canvas, naplet: treeNaplet, to: CanvasLayout(x: 500, y: 40, width: 400, height: 300, z: 3))
        let movedTree = try await storedNaplet(h, canvas, tree)
        XCTAssertEqual(movedTree.layout.x, 500)
        let savedTree = try XCTUnwrap(JSONSerialization.jsonObject(with: movedTree.savedLayout) as? [String: Any])
        XCTAssertNotNil(savedTree["task_tree"], "keys outside x/y/width/height/z are sent back unchanged")

        naplet = try await storedNaplet(h, canvas, naplet.id)
        try await editor(h).updateLayout(h.connection, h.workspace, canvasId: canvas, naplet: naplet, to: CanvasLayout(x: 10, y: 20, width: 640, height: 480, z: 2))
        naplet = try await storedNaplet(h, canvas, naplet.id)
        XCTAssertEqual(naplet.layout, CanvasLayout(x: 10, y: 20, width: 640, height: 480, z: 2))
        XCTAssertEqual(naplet.rowVersion, 2)

        try await editor(h).removeNaplet(h.connection, h.workspace, canvasId: canvas, naplet: naplet)
        let remaining = try await scene(h, canvas).naplets.map(\.id)
        XCTAssertEqual(remaining, [tree])
        XCTAssertFalse(h.tower.canvasWrites.contains { $0.contains("/elements") }, "no drawing-element write")
    }

    func testStaleNapletVersionIsRefusedAndTheBoardShowsTheOtherChange() async throws {
        let h = try await SurfaceHarness.make()
        let canvas = h.tower.seedCanvas(title: "Board", position: 1)
        let doc = UUID().uuidString.lowercased()
        h.tower.seedRecord(id: doc, type: "doc", title: "Notes", channel: Fixtures.channel1, scope: Fixtures.scopeA)
        let id = h.tower.seedNaplet(canvas: canvas, sourceType: "document", sourceId: doc, title: "Notes",
                                    layout: ["x": 0, "y": 0, "width": 360, "height": 280, "z": 1], content: ["body": "hi"])
        await open(h, canvas)
        let stale = try await storedNaplet(h, canvas)

        // Another device moves it first.
        h.tower.moveNaplet(id, layout: ["x": 900, "y": 900, "width": 360, "height": 280, "z": 1])
        do {
            try await editor(h).updateLayout(h.connection, h.workspace, canvasId: canvas, naplet: stale, to: CanvasLayout(x: 5, y: 5, width: 360, height: 280, z: 1))
            XCTFail("a stale move must be refused")
        } catch let error as CanvasEditError { XCTAssertEqual(error, .conflict) }
        let current = try await storedNaplet(h, canvas)
        XCTAssertEqual(current.layout.x, 900, "the board was read again and shows the other device's move")
        XCTAssertEqual(current.rowVersion, 2)
        do {
            try await editor(h).removeNaplet(h.connection, h.workspace, canvasId: canvas, naplet: stale)
            XCTFail("a stale remove must be refused")
        } catch let error as CanvasEditError { XCTAssertEqual(error, .conflict) }
        let still = try await scene(h, canvas).naplets.count
        XCTAssertEqual(still, 1)
    }

    func testPermissionAccessLossDeniedSourcesAndLockedItems() async throws {
        let h = try await SurfaceHarness.make()
        let readOnly = h.tower.seedCanvas(title: "Read only", position: 1, canManage: false)
        let canvas = h.tower.seedCanvas(title: "Board", position: 2)
        let secret = UUID().uuidString.lowercased(), hiddenDoc = UUID().uuidString.lowercased()
        h.tower.seedRecord(id: secret, type: "doc", title: "Secret", channel: Fixtures.channel2, scope: Fixtures.scopeA)
        h.tower.seedRecord(id: hiddenDoc, type: "doc", title: "Hidden", channel: Fixtures.channel2, scope: Fixtures.scopeA)
        let locked = h.tower.seedNaplet(canvas: canvas, sourceType: "document", sourceId: secret, title: "Secret",
                                        layout: ["x": 0, "y": 0, "width": 360, "height": 280, "z": 1], content: ["body": "secret"])
        h.tower.deny(record: secret)
        h.tower.deny(record: hiddenDoc)
        await open(h, canvas)
        await h.sync.refreshCanvas(h.connection, h.workspace, canvasId: readOnly)
        await h.idle()

        // Read-only canvas: Tower refuses (the screen hides the controls, Tower still decides).
        do {
            try await editor(h).addNaplet(h.connection, h.workspace, canvasId: readOnly, type: .canvas, sourceId: canvas,
                                          layout: CanvasLayout(x: 0, y: 0, width: 360, height: 280, z: 1))
            XCTFail()
        } catch let error as CanvasEditError { XCTAssertEqual(error, .forbidden) }

        // A source this viewer cannot read is refused and nothing is added.
        do {
            try await editor(h).addNaplet(h.connection, h.workspace, canvasId: canvas, type: .document, sourceId: hiddenDoc,
                                          layout: CanvasLayout(x: 0, y: 0, width: 360, height: 280, z: 2))
            XCTFail()
        } catch let error as CanvasEditError { XCTAssertEqual(error, .sourceUnavailable) }

        // A locked item keeps its frame: it cannot be moved, but it can be removed.
        let frame = try await storedNaplet(h, canvas, locked)
        XCTAssertEqual(frame.content, .denied)
        do {
            try await editor(h).updateLayout(h.connection, h.workspace, canvasId: canvas, naplet: frame, to: CanvasLayout(x: 1, y: 1, width: 360, height: 280, z: 1))
            XCTFail()
        } catch let error as CanvasEditError { XCTAssertEqual(error, .locked) }
        XCTAssertFalse(h.tower.canvasWrites.contains { $0.hasPrefix("PATCH ") }, "a locked move never reaches Tower")
        try await editor(h).removeNaplet(h.connection, h.workspace, canvasId: canvas, naplet: frame)
        let left = try await scene(h, canvas).naplets
        XCTAssertTrue(left.isEmpty)

        // The canvas disappears for this viewer: the write is refused and the stored copy removed.
        h.tower.hide(canvas: canvas)
        do {
            try await editor(h).addNaplet(h.connection, h.workspace, canvasId: canvas, type: .canvas, sourceId: readOnly,
                                          layout: CanvasLayout(x: 0, y: 0, width: 360, height: 280, z: 1))
            XCTFail()
        } catch let error as CanvasEditError { XCTAssertEqual(error, .canvasUnavailable) }
        let gone = try await h.store.reader.canvasSnapshot(workspaceId: h.workspace.id, canvasId: canvas)
        XCTAssertNil(gone)
        let row = try await h.store.reader.canvas(workspaceId: h.workspace.id, id: canvas)
        XCTAssertNil(row)
    }

    func testOfflineWriteChangesNothing() async throws {
        let h = try await SurfaceHarness.make()
        let canvas = h.tower.seedCanvas(title: "Board", position: 1)
        await open(h, canvas)
        h.tower.inject(.offline, matching: "/canvases/\(canvas)/naplets")
        do {
            try await editor(h).addNaplet(h.connection, h.workspace, canvasId: canvas, type: .canvas, sourceId: canvas,
                                          layout: CanvasLayout(x: 0, y: 0, width: 360, height: 280, z: 1))
            XCTFail()
        } catch let error as CanvasEditError {
            // Tower refuses a canvas linking to itself, but offline fails first.
            guard case .offline = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.retryable)
        }
        let naplets = try await scene(h, canvas).naplets
        XCTAssertTrue(naplets.isEmpty)
    }
}
