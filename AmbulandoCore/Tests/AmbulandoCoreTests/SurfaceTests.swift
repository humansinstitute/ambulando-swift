import XCTest
@testable import AmbulandoCore

/// Context Tree, Canvas (snapshots, naplets, Excalidraw boards), agents, Toolbox and personal pins against deterministic
/// transport fixtures that follow the Tower route rules (`SampleSurfaceTower`). No live Tower is involved.
struct SurfaceHarness {
    let work: WorkHarness
    let tower: SampleSurfaceTower
    let other: SampleSurfaceTower
    let transport: StubTransport

    var store: LocalStore { work.store }
    var connection: ConnectionRecord { work.connection }
    var workspace: WorkspaceRecord { work.workspace }
    var engine: SyncEngine { work.engine }
    var sync: WorkspaceSync { WorkspaceSync(store: store, engine: engine, identity: work.chat.identity, transport: transport) }
    var writes: WriteSender { WriteSender(store: store, engine: engine, identity: work.chat.identity, transport: transport, staging: work.staging) }

    static func make() async throws -> SurfaceHarness {
        let work = try await WorkHarness.make()
        let tower = SampleSurfaceTower(workspaceId: Fixtures.workspaceId)
        // A second workspace on the same Tower: none of its rows may ever be filed under the first.
        let other = SampleSurfaceTower(workspaceId: Fixtures.workspaceId2)
        let chatHandler = work.chat.tower.handler()
        let sample = work.work
        let transport = StubTransport { request in try tower.handle(request) ?? other.handle(request) ?? sample.handle(request) ?? chatHandler(request) }
        return SurfaceHarness(work: work, tower: tower, other: other, transport: transport)
    }

    func idle() async { await engine.waitUntilIdle() }
    func error(_ key: String) async -> String? { await engine.snapshot.errors[key] }
}

final class SurfaceTests: XCTestCase {
    let scope = Fixtures.scopeA

    // MARK: Context Tree

    func testContextTreeOutlineIsPagedNestedAndScopedToItsScope() async throws {
        let h = try await SurfaceHarness.make()
        let root = h.tower.seedComponent(scope: scope, title: "Architecture", sortOrder: 0)
        let api = h.tower.seedComponent(scope: scope, title: "API", parent: root, sortOrder: 1)
        h.tower.seedComponent(scope: scope, title: "Sync", parent: root, sortOrder: 0)
        h.tower.seedComponent(scope: scope, title: "Endpoints", parent: api, sortOrder: 0)
        // More than one page (Tower pages at 200).
        for n in 0..<205 { h.tower.seedComponent(scope: scope, title: "Note \(n)", sortOrder: 10 + n) }
        h.tower.seedComponent(scope: Fixtures.scopeB, title: "Other scope", sortOrder: 0)
        h.other.seedComponent(scope: scope, title: "Other workspace", sortOrder: 0)

        await h.sync.refreshContextTree(h.connection, h.workspace, scopeId: scope)
        await h.idle()
        let tree = try await h.store.reader.contextTree(workspaceId: h.workspace.id, scopeId: scope)
        XCTAssertEqual(tree.count, 206, "4 nested + 205 roots → 206 roots")
        XCTAssertEqual(tree.first?.component.title, "Architecture")
        XCTAssertEqual(tree.first?.children.map(\.component.title), ["Sync", "API"], "children in Tower's sort order")
        XCTAssertEqual(tree.first?.children.last?.children.map(\.component.title), ["Endpoints"])
        XCTAssertTrue(h.tower.requestLog.contains { $0.contains("/context/components") })
        let titles = tree.map(\.component.title)
        XCTAssertFalse(titles.contains("Other scope")); XCTAssertFalse(titles.contains("Other workspace"))
        let otherWorkspace = try await h.store.reader.contextTree(workspaceId: Fixtures.workspaceId2, scopeId: scope)
        XCTAssertTrue(otherWorkspace.isEmpty)

        // Rename and delete on Tower: a complete re-read follows.
        h.tower.renameComponent(root, title: "System architecture")
        h.tower.deleteComponent(api)
        await h.sync.refreshContextTree(h.connection, h.workspace, scopeId: scope, force: true)
        await h.idle()
        let after = try await h.store.reader.contextTree(workspaceId: h.workspace.id, scopeId: scope)
        XCTAssertEqual(after.first?.component.title, "System architecture")
        XCTAssertEqual(after.first?.children.map(\.component.title), ["Sync"])
        XCTAssertFalse(after.contains { $0.component.title == "Endpoints" }, "a deleted subtree is gone, not orphaned")
    }

    func testContextReferencesResolvePerViewerAndAccessLossRemovesTheTree() async throws {
        let h = try await SurfaceHarness.make()
        let component = h.tower.seedComponent(scope: scope, title: "Launch", sortOrder: 0)
        let task = UUID().uuidString.lowercased(), doc = UUID().uuidString.lowercased(), hidden = UUID().uuidString.lowercased()
        h.tower.seedRecord(id: task, type: "task", title: "Ship build 7", channel: Fixtures.channel1, scope: scope)
        h.tower.seedRecord(id: doc, type: "doc", title: "Release notes", channel: Fixtures.channel1, scope: scope)
        h.tower.seedRecord(id: hidden, type: "file", title: "Secret plan", channel: Fixtures.channel2, scope: scope)
        h.tower.deny(record: hidden)
        h.tower.seedReference(component: component, type: "task", recordId: task, sortOrder: 0)
        h.tower.seedReference(component: component, type: "doc", recordId: doc, sortOrder: 1)
        h.tower.seedReference(component: component, type: "file", recordId: hidden, sortOrder: 2)
        h.tower.seedReference(component: component, type: "artifact", artifact: ["origin": "https://pale-log-tank.example", "project": "Wingman_Suite",
                                                                                   "artifact": "wingman-suite-arch", "page": "index.html", "version_policy": "latest"], sortOrder: 3)
        await h.sync.refreshContextTree(h.connection, h.workspace, scopeId: scope)
        await h.sync.refreshContextReferences(h.connection, h.workspace, scopeId: scope, componentId: component)
        await h.idle()
        let refs = try await h.store.reader.contextReferences(workspaceId: h.workspace.id, componentId: component)
        XCTAssertEqual(refs.map(\.targetType), [.task, .doc, .file, .artifact])
        XCTAssertEqual(refs.map(\.resolution), [.available, .available, .unavailable, .external])
        XCTAssertEqual(refs[0].resolvedTitle, "Ship build 7")
        XCTAssertNil(refs[2].resolvedTitle, "an unavailable target discloses no title")
        XCTAssertEqual(refs[2].targetRecordId, hidden)
        XCTAssertEqual(refs[3].artifact?.latestURL?.absoluteString, "https://pale-log-tank.example/artifacts/Wingman_Suite/wingman-suite-arch/")

        // The scope becomes unreadable: Tower answers 404 context_not_found and nothing of the tree stays.
        h.tower.deny(scope: scope)
        await h.sync.refreshContextTree(h.connection, h.workspace, scopeId: scope, force: true)
        await h.idle()
        let tree = try await h.store.reader.contextTree(workspaceId: h.workspace.id, scopeId: scope)
        XCTAssertTrue(tree.isEmpty)
        let gone = try await h.store.reader.contextReferences(workspaceId: h.workspace.id, componentId: component)
        XCTAssertTrue(gone.isEmpty)
    }

    func testContextReferenceRefusesForeignRowsAndMalformedArtifacts() throws {
        let good = try ContextReferenceRecord(raw: Fixtures.json(["id": UUID().uuidString, "workspace_id": Fixtures.workspaceId, "scope_id": scope,
                                                                  "component_id": UUID().uuidString, "target_type": "artifact", "sort_order": 0, "row_version": 1,
                                                                  "target": ["origin": "https://a.example/path", "project": "p", "artifact": "a", "page": "index.html", "version_policy": "latest"],
                                                                  "resolution": ["status": "external"]]))
        XCTAssertNil(good.artifact, "an origin with a path is not a canonical artifact target")
        let unknown = try ContextReferenceRecord(raw: Fixtures.json(["id": UUID().uuidString, "workspace_id": Fixtures.workspaceId, "scope_id": scope,
                                                                     "component_id": UUID().uuidString, "target_type": "task", "target": ["record_id": UUID().uuidString],
                                                                     "sort_order": 0, "row_version": 1]))
        XCTAssertEqual(unknown.resolution, .unavailable, "a missing resolution never implies access")
        XCTAssertThrowsError(try ContextComponentRecord(raw: Fixtures.json(["id": "not-a-uuid", "workspace_id": Fixtures.workspaceId, "scope_id": scope])))
    }

    // MARK: Canvas

    func seedCanvas(_ h: SurfaceHarness) -> (canvas: String, doc: String, denied: String, board: BoardSceneFixture) {
        let canvas = h.tower.seedCanvas(title: "Launch board", position: 1, viewport: ["x": -120, "y": 40, "scale": 0.8])
        h.tower.seedCanvas(title: "Retro", position: 2)
        let doc = UUID().uuidString.lowercased()
        h.tower.seedNaplet(canvas: canvas, sourceType: "document", sourceId: doc, title: "Release notes",
                           layout: ["x": 40, "y": 60, "width": 360, "height": 280, "z": 2],
                           content: ["title": "Release notes", "body": "# Build 7\n\nContext tree and canvas.", "updated_at": "2026-10-24T09:00:00.000Z"])
        h.tower.seedNaplet(canvas: canvas, sourceType: "task_list", sourceId: Fixtures.channel1, title: "Tasks",
                           layout: ["x": 440, "y": 60, "width": 300, "height": 240, "z": 1],
                           content: ["tasks": [["id": UUID().uuidString.lowercased(), "title": "Ship it", "state": "ready"]]])
        let denied = UUID().uuidString.lowercased()
        h.tower.seedNaplet(canvas: canvas, sourceType: "document", sourceId: denied, title: "Private plan",
                           layout: ["x": -300, "y": 400, "width": 240, "height": 180, "z": 3], content: ["body": "secret"])
        h.tower.deny(record: denied)
        let board = BoardSceneFixture.make()
        let projection = h.tower.seedBoardVersion(fileId: board.fileId, versionId: board.versionId, versionNumber: 3, bytes: board.bytes)
        h.tower.seedNaplet(canvas: canvas, sourceType: "excalidraw", sourceId: board.fileId, title: "Architecture sketch",
                           layout: ["x": 800, "y": -200, "width": 600, "height": 420, "z": 4], content: projection)
        h.tower.seedElement(canvas: canvas, kind: "arrow", layout: ["x": 400, "y": 200, "width": 40, "height": 20, "z": 5], data: ["endArrowhead": "arrow"])
        h.tower.seedElement(canvas: canvas, kind: "text", layout: ["x": 40, "y": 0, "width": 200, "height": 40, "z": 6], data: ["text": "Launch", "fontSize": 24])
        h.tower.seedElement(canvas: canvas, kind: "sticker", layout: ["x": 0, "y": 0, "width": 40, "height": 40, "z": 7], data: [:])
        return (canvas, doc, denied, board)
    }

    func testCanvasSnapshotKeepsSavedLayoutDeniedFramesAndNeverWritesTheBoard() async throws {
        let h = try await SurfaceHarness.make()
        let seeded = seedCanvas(h)
        h.other.seedCanvas(title: "Other workspace board", position: 1)
        await h.sync.refreshCanvases(h.connection, h.workspace)
        await h.sync.refreshCanvas(h.connection, h.workspace, canvasId: seeded.canvas)
        await h.idle()

        let canvases = try await h.store.reader.canvases(workspaceId: h.workspace.id)
        XCTAssertEqual(canvases.map(\.title), ["Launch board", "Retro"])
        XCTAssertEqual(canvases[0].viewport, CanvasViewport(x: -120, y: 40, scale: 0.8))
        let storedSnapshot = try await h.store.reader.canvasSnapshot(workspaceId: h.workspace.id, canvasId: seeded.canvas)
        let snapshot = try XCTUnwrap(storedSnapshot)
        let scene = CanvasScene.parse(snapshot.bytes)
        XCTAssertEqual(scene.naplets.map(\.layout.z), [1, 2, 3, 4], "drawn in saved z order")
        let doc = try XCTUnwrap(scene.naplets.first { $0.title == "Release notes" })
        XCTAssertEqual(doc.layout, CanvasLayout(x: 40, y: 60, width: 360, height: 280, z: 2), "exact saved position and size")
        XCTAssertEqual(doc.content, .document(docId: seeded.doc, excerpt: "# Build 7\nContext tree and canvas."))
        let denied = try XCTUnwrap(scene.naplets.first { $0.layout.z == 3 })
        XCTAssertEqual(denied.content, .denied)
        XCTAssertEqual(denied.sourceType, "", "a locked naplet does not say what it points at")
        XCTAssertEqual(denied.title, "Not available to you", "nor its title")
        XCTAssertEqual(denied.layout, CanvasLayout(x: -300, y: 400, width: 240, height: 180, z: 3), "a denied naplet keeps its frame")
        XCTAssertFalse(String(decoding: snapshot.bytes, as: UTF8.self).contains("secret"), "denied source content never reaches the phone")
        XCTAssertEqual(scene.elements.map(\.kind), [.arrow, .text])
        XCTAssertEqual(scene.unsupportedElements, ["sticker": 1], "unknown element kinds are counted, not dropped silently")
        XCTAssertEqual(scene.elements[0].endArrowhead, "arrow")
        XCTAssertEqual(scene.elements[0].start, [0, 20], "sol default arrow start (0, height)")

        // The board scene was fetched, verified and stored.
        let storedBoard = try await h.store.reader.boardScene(workspaceId: h.workspace.id, fileId: seeded.board.fileId)
        let board = try XCTUnwrap(storedBoard)
        XCTAssertEqual(board.versionId, seeded.board.versionId)
        XCTAssertEqual(board.bytes, seeded.board.bytes)
        XCTAssertTrue(h.tower.canvasWrites.isEmpty, "rendering never writes a canvas: \(h.tower.canvasWrites)")
        XCTAssertTrue(h.tower.requestLog.allSatisfy { $0.hasPrefix("GET ") }, "reads only: \(h.tower.requestLog)")
        let otherCanvases = try await h.store.reader.canvases(workspaceId: Fixtures.workspaceId2)
        XCTAssertTrue(otherCanvases.isEmpty)
    }

    func testCanvasLostAccessAndTamperedBoardBytes() async throws {
        let h = try await SurfaceHarness.make()
        let seeded = seedCanvas(h)
        // The stored bytes on "Tower" no longer match the sha256 projected for the naplet.
        _ = h.tower.seedBoardVersion(fileId: seeded.board.fileId, versionId: seeded.board.versionId, versionNumber: 3, bytes: Data("{\"elements\":[]}".utf8))
        await h.sync.refreshCanvas(h.connection, h.workspace, canvasId: seeded.canvas)
        await h.idle()
        let stored = try await h.store.reader.boardScene(workspaceId: h.workspace.id, fileId: seeded.board.fileId)
        XCTAssertNil(stored, "bytes that do not match the projected sha256 are refused")
        let failure = await h.error(WorkspaceSync.boardKey(h.workspace.id, seeded.board.fileId))
        XCTAssertNotNil(failure)
        let snapshot = try await h.store.reader.canvasSnapshot(workspaceId: h.workspace.id, canvasId: seeded.canvas)
        XCTAssertNotNil(snapshot, "the rest of the canvas is still shown")

        // The canvas stops being visible: 404 canvas_unavailable removes its definition and snapshot.
        h.tower.hide(canvas: seeded.canvas)
        await h.sync.refreshCanvas(h.connection, h.workspace, canvasId: seeded.canvas, force: true)
        await h.idle()
        let gone = try await h.store.reader.canvasSnapshot(workspaceId: h.workspace.id, canvasId: seeded.canvas)
        XCTAssertNil(gone)
        let list = try await h.store.reader.canvas(workspaceId: h.workspace.id, id: seeded.canvas)
        XCTAssertNil(list)
    }

    func testBoardScenesArePurgedWhenNoVisibleCanvasShowsThem() async throws {
        let h = try await SurfaceHarness.make()
        let seeded = seedCanvas(h)
        await h.sync.refreshCanvas(h.connection, h.workspace, canvasId: seeded.canvas)
        await h.idle()
        var board = try await h.store.reader.boardScene(workspaceId: h.workspace.id, fileId: seeded.board.fileId)
        XCTAssertNotNil(board)
        // The board File becomes unreadable: Tower now projects the naplet as denied, so the stored scene goes.
        h.tower.deny(record: seeded.board.fileId)
        await h.sync.refreshCanvas(h.connection, h.workspace, canvasId: seeded.canvas, force: true)
        await h.idle()
        board = try await h.store.reader.boardScene(workspaceId: h.workspace.id, fileId: seeded.board.fileId)
        XCTAssertNil(board, "no stored scene once no visible canvas shows the board")
        // A fetch that completes after access was lost stores nothing.
        try await h.store.writer.saveBoardScene(BoardSceneRecord(workspaceId: h.workspace.id, fileId: seeded.board.fileId, versionId: seeded.board.versionId,
                                                                 sha256: SHA256Hex.of(seeded.board.bytes), bytes: seeded.board.bytes, fetchedAt: "now"))
        board = try await h.store.reader.boardScene(workspaceId: h.workspace.id, fileId: seeded.board.fileId)
        XCTAssertNil(board)
        // Access back, then the whole canvas is hidden: definition, snapshot and scene all go.
        h.tower.allow(record: seeded.board.fileId)
        await h.sync.refreshCanvas(h.connection, h.workspace, canvasId: seeded.canvas, force: true)
        await h.idle()
        board = try await h.store.reader.boardScene(workspaceId: h.workspace.id, fileId: seeded.board.fileId)
        XCTAssertNotNil(board)
        h.tower.hide(canvas: seeded.canvas)
        await h.sync.refreshCanvases(h.connection, h.workspace, force: true)
        await h.idle()
        board = try await h.store.reader.boardScene(workspaceId: h.workspace.id, fileId: seeded.board.fileId)
        XCTAssertNil(board)
        let snapshot = try await h.store.reader.canvasSnapshot(workspaceId: h.workspace.id, canvasId: seeded.canvas)
        XCTAssertNil(snapshot)
    }

    func testCanvasEventsRefreshOnlyStoredCanvases() async throws {
        let h = try await SurfaceHarness.make()
        let seeded = seedCanvas(h)
        let unopened = h.tower.seedCanvas(title: "Never opened", position: 3)
        await h.sync.refreshCanvas(h.connection, h.workspace, canvasId: seeded.canvas)
        await h.idle()
        let naplet = CanvasScene.parse(try await h.store.reader.canvasSnapshot(workspaceId: h.workspace.id, canvasId: seeded.canvas)!.bytes)
            .naplets.first { $0.title == "Release notes" }!
        h.tower.moveNaplet(naplet.id, layout: ["x": 900, "y": 900, "width": 360, "height": 280, "z": 2])
        let events = [event(1, "canvas_naplet", naplet.id, "updated", canvas: seeded.canvas), event(2, "canvas_element", UUID().uuidString.lowercased(), "created", canvas: unopened)]
        let plan = EventPlan.make(events, workspaceId: h.workspace.id)
        XCTAssertEqual(plan.refreshes, [.canvas(seeded.canvas), .canvas(unopened)])
        let before = h.tower.requestLog.count
        try await h.sync.applyEvents(events, h.connection, h.workspace)
        await h.idle()
        let moved = CanvasScene.parse(try await h.store.reader.canvasSnapshot(workspaceId: h.workspace.id, canvasId: seeded.canvas)!.bytes)
            .naplets.first { $0.id == naplet.id }!
        XCTAssertEqual(moved.layout.x, 900)
        let fetched = h.tower.requestLog.dropFirst(before)
        XCTAssertFalse(fetched.contains { $0.contains(unopened) }, "a canvas never opened on this phone is not fetched by events")
    }

    func event(_ row: Int, _ type: String, _ id: String?, _ op: String, scope: String? = nil, channel: String? = nil, canvas: String? = nil,
               component: String? = nil) -> TowerEvent {
        TowerEvent(rowVersion: row, cursor: "c\(row)", workspaceId: Fixtures.workspaceId, entityType: type, entityId: id, operation: op,
                   scopeId: scope, channelId: channel, canvasId: canvas, componentId: component)
    }

    func testEventPlanCoversEveryNewFamily() {
        let comp = UUID().uuidString.lowercased()
        let plan = EventPlan.make([
            event(1, "context_component", comp, "updated", scope: scope),
            event(2, "context_reference", UUID().uuidString.lowercased(), "created", scope: scope, component: comp),
            event(3, "personal_pin", UUID().uuidString.lowercased(), "updated"),
            event(4, "agent_activity", UUID().uuidString.lowercased(), "updated", channel: Fixtures.channel1),
            event(5, "workspace_agent", UUID().uuidString.lowercased(), "created"),
            event(6, "personal_wapp", UUID().uuidString.lowercased(), "updated"),
            event(7, "canvas_order", UUID().uuidString.lowercased(), "updated"),
            event(8, "canvas", UUID().uuidString.lowercased(), "deleted"),
            event(9, "workroom", UUID().uuidString.lowercased(), "updated"),
        ], workspaceId: Fixtures.workspaceId)
        XCTAssertEqual(plan.refreshes, [.contextTree(scopeId: scope), .contextReferences(scopeId: scope, componentId: comp), .pins,
                                        .agentActivity(channelId: Fixtures.channel1), .agents, .toolbox, .canvases])
        XCTAssertEqual(plan.ignored, 1)
        let parsed = TowerEvent(json: ["row_version": 3, "cursor": "x", "workspace_id": Fixtures.workspaceId, "entity_type": "canvas_naplet",
                                       "entity_id": comp, "operation": "updated", "payload": ["canvas_id": Fixtures.channel2.uppercased()]])
        XCTAssertEqual(parsed?.canvasId, Fixtures.channel2)
    }

    // MARK: Excalidraw

    func testExcalidrawSubsetIsDrawnAndEverythingElseIsListed() throws {
        let scene = try ExcalidrawScene.parse(BoardSceneFixture.make().bytes)
        XCTAssertEqual(scene.elements.map(\.kind), [.rectangle, .ellipse, .diamond, .arrow, .line, .freedraw, .text, .image, .frame])
        XCTAssertEqual(scene.unsupported, ["embeddable": 1, "iframe": 1, "image (image/svg+xml)": 1, "magicframe": 1])
        XCTAssertEqual(scene.unsupportedSummary, ["1 × embeddable", "1 × iframe", "1 × image (image/svg+xml)", "1 × magicframe"])
        XCTAssertEqual(scene.deletedCount, 1)
        XCTAssertEqual(scene.images.count, 1)
        XCTAssertEqual(scene.images.values.first?.mimeType, "image/png")
        let arrow = try XCTUnwrap(scene.elements.first { $0.kind == .arrow })
        XCTAssertEqual(arrow.points, [[0, 0], [120, 40]])
        XCTAssertEqual(arrow.endArrowhead, "arrow")
        XCTAssertEqual(scene.minX, -10, "the frame reaches furthest left"); XCTAssertEqual(scene.maxX, 530)
        XCTAssertTrue(scene.approximations.contains("Hand-drawn strokes are drawn as clean lines."))
        XCTAssertTrue(scene.approximations.contains("Hatched fills are shown as a light tint."))
        XCTAssertEqual(scene.viewBackgroundColor, "#fdf8f0")
        XCTAssertThrowsError(try ExcalidrawScene.parse(Data("{\"type\":\"tldraw\",\"elements\":[]}".utf8)))
        XCTAssertThrowsError(try ExcalidrawScene.parse(Data("not json".utf8)))
        // Artifact-style wrapper is accepted (sol `normalizeBoardScene`).
        let wrapped = try ExcalidrawScene.parse(Fixtures.json(["scene": ["elements": [["id": "r", "type": "rectangle", "x": 1, "y": 2, "width": 3, "height": 4, "version": 1]]]]))
        XCTAssertEqual(wrapped.elements.count, 1)
    }

    func testExcalidrawLimitsAndCancellation() async throws {
        XCTAssertThrowsError(try ExcalidrawScene.parse(Data(count: ExcalidrawScene.maxBytes + 1))) { XCTAssertEqual($0 as? ExcalidrawScene.ParseError, .tooLarge) }
        let many = (0...ExcalidrawScene.maxElements).map { ["id": "e\($0)", "type": "rectangle", "version": 1] as [String: Any] }
        XCTAssertThrowsError(try ExcalidrawScene.parse(Fixtures.json(["elements": many]))) { XCTAssertEqual($0 as? ExcalidrawScene.ParseError, .tooLarge) }
        let big = Data(count: ExcalidrawScene.maxImageBytes + 1).base64EncodedString()
        let scene = try ExcalidrawScene.parse(Fixtures.json([
            "elements": [["id": "i", "type": "image", "fileId": "f", "x": 0, "y": 0, "width": 1, "height": 1, "version": 1]],
            "files": ["f": ["id": "f", "mimeType": "image/png", "dataURL": "data:image/png;base64," + big]],
        ]))
        XCTAssertTrue(scene.elements.isEmpty)
        XCTAssertEqual(scene.unsupported, ["image (larger than 6 MB)": 1])
        // Closing a board while a large scene is parsed stops the work.
        let bytes = Fixtures.json(["elements": (0..<5000).map { ["id": "e\($0)", "type": "rectangle", "version": 1] as [String: Any] }])
        let task = Task.detached { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try ExcalidrawScene.parse(bytes); return nil } catch { return error }
        }
        let outcome = await task.value
        XCTAssertTrue(outcome is CancellationError)
    }

    func testWebContentNavigationStaysOnItsOrigin() throws {
        let origin = "https://artifacts.example"
        XCTAssertEqual(WebContentPolicy.decide(URL(string: "https://artifacts.example/next"), within: origin, newWindow: false), .allow)
        XCTAssertEqual(WebContentPolicy.decide(URL(string: "https://artifacts.example/popup"), within: origin, newWindow: true), .allow,
                       "a same-origin new-window link loads in place")
        // A server redirect is a new navigation to its target; another origin is refused (offered to Safari only).
        XCTAssertEqual(WebContentPolicy.decide(URL(string: "https://login.example/redirected"), within: origin, newWindow: false),
                       .refuse(offerExternal: URL(string: "https://login.example/redirected")))
        XCTAssertEqual(WebContentPolicy.decide(URL(string: "http://artifacts.example/"), within: origin, newWindow: false), .refuse(offerExternal: nil))
        XCTAssertEqual(WebContentPolicy.decide(URL(string: "javascript:alert(1)"), within: origin, newWindow: true), .refuse(offerExternal: nil))
        XCTAssertEqual(WebContentPolicy.decide(URL(string: "https://evil.example@artifacts.example.attacker.example/"), within: origin, newWindow: false),
                       .refuse(offerExternal: nil), "embedded credentials are never offered")
        XCTAssertEqual(WebContentPolicy.decide(nil, within: origin, newWindow: true), .refuse(offerExternal: nil))
    }

    // MARK: Agents

    func testAgentsAndActivityAreReadFromTowerRecordsPerChannel() async throws {
        let h = try await SurfaceHarness.make()
        let rick = Bech32.encode(hrp: "npub", data: Data(repeating: 0xB2, count: 32))
        h.tower.seedAgent(npub: rick, name: "Rick", sortOrder: 1)
        h.tower.seedAgent(npub: Bech32.encode(hrp: "npub", data: Data(repeating: 0xB3, count: 32)), name: "Hidden", sortOrder: 2, visible: false)
        let thread = UUID().uuidString.lowercased()
        h.tower.seedActivity(channel: Fixtures.channel1, scope: scope, thread: thread, agent: rick, state: "working", label: "Reviewing outbox")
        h.tower.seedActivity(channel: Fixtures.channel1, scope: scope, thread: thread, agent: rick, state: "completed", label: "Answered")
        h.tower.seedActivity(channel: Fixtures.channel1, scope: scope, thread: thread, agent: rick, state: "working", label: "internal", visibility: "internal")
        h.tower.seedActivity(channel: Fixtures.channel2, scope: scope, thread: thread, agent: rick, state: "queued", label: "Waiting")
        await h.sync.refreshAgents(h.connection, h.workspace, channelIds: [Fixtures.channel1, Fixtures.channel2])
        await h.idle()
        let agents = try await h.store.reader.workspaceAgents(workspaceId: h.workspace.id)
        XCTAssertEqual(agents.map(\.displayName), ["Rick"], "hidden agents are not listed")
        var activity = try await h.store.reader.agentActivities(workspaceId: h.workspace.id, channelIds: [Fixtures.channel1])
        XCTAssertEqual(Set(activity.map(\.label)), ["Reviewing outbox", "Answered"], "only user-visible activity")
        XCTAssertEqual(activity.filter(\.isTerminal).map(\.label), ["Answered"])
        let query = h.transport.recorded.compactMap(\.url).filter { $0.path.hasSuffix("/agent-activities") }
        XCTAssertTrue(query.allSatisfy { $0.query?.contains("history_limit=0") == true })
        XCTAssertFalse(h.transport.recorded.contains { $0.url?.host?.hasSuffix(".fips") == true }, "no direct Autopilot transport")

        // Channel read lost: 403 → nothing of that channel's activity stays.
        h.tower.deny(channel: Fixtures.channel1)
        await h.sync.refreshAgentActivity(h.connection, h.workspace, channelId: Fixtures.channel1, force: true)
        await h.idle()
        activity = try await h.store.reader.agentActivities(workspaceId: h.workspace.id, channelIds: [Fixtures.channel1])
        XCTAssertTrue(activity.isEmpty)
        let others = try await h.store.reader.agentActivities(workspaceId: h.workspace.id, channelIds: [Fixtures.channel2])
        XCTAssertEqual(others.map(\.label), ["Waiting"])
        let none = try await h.store.reader.agentActivities(workspaceId: h.workspace.id, channelIds: [])
        XCTAssertTrue(none.isEmpty, "an empty context reads nothing")
    }

    // MARK: Toolbox

    func testToolboxListsActiveWappsAndOnlyOpensSafeHTTPSOrigins() async throws {
        let h = try await SurfaceHarness.make()
        h.tower.seedWapp(title: "Artifacts", launchURL: "https://artifacts.example/app/", sortOrder: 2, owner: TestKeys.npub)
        h.tower.seedWapp(title: "Timesheets", launchURL: "https://time.example", sortOrder: 1, owner: TestKeys.npub)
        h.tower.seedWapp(title: "Old", launchURL: "https://old.example", sortOrder: 0, owner: TestKeys.npub, status: "archived")
        h.tower.seedWapp(title: "Plain HTTP", launchURL: "http://insecure.example", sortOrder: 3, owner: TestKeys.npub)
        await h.sync.refreshToolbox(h.connection, h.workspace)
        await h.idle()
        let wapps = try await h.store.reader.personalWapps(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(wapps.map(\.title), ["Timesheets", "Artifacts", "Plain HTTP"])
        XCTAssertEqual(wapps[0].safeLaunchURL?.absoluteString, "https://time.example")
        XCTAssertNil(wapps[2].safeLaunchURL, "only HTTPS is opened")
        XCTAssertNil(WebContentPolicy.launchURL("https://user:pw@x.example/"))
        XCTAssertNil(WebContentPolicy.launchURL("https://npub1abc.fips/"))
        XCTAssertNil(WebContentPolicy.launchURL("javascript:alert(1)"))
        let origin = try XCTUnwrap(WebContentPolicy.origin(of: URL(string: "https://Artifacts.example/app/")!))
        XCTAssertEqual(origin, "https://artifacts.example")
        XCTAssertTrue(WebContentPolicy.allows(URL(string: "https://artifacts.example/other")!, within: origin))
        XCTAssertFalse(WebContentPolicy.allows(URL(string: "https://evil.example/")!, within: origin))
        XCTAssertFalse(WebContentPolicy.allows(URL(string: "http://artifacts.example/")!, within: origin), "no scheme downgrade")
    }

    // MARK: Personal pins

    func pinnable(_ h: SurfaceHarness) -> (thread: String, task: String, doc: String, forbidden: String) {
        let thread = UUID().uuidString.lowercased(), task = UUID().uuidString.lowercased(), doc = UUID().uuidString.lowercased(), forbidden = UUID().uuidString.lowercased()
        h.tower.seedRecord(id: thread, type: "thread", title: "Outbox retries", channel: Fixtures.channel1, scope: scope)
        h.tower.seedRecord(id: task, type: "task", title: "Ship build 7", channel: Fixtures.channel1, scope: scope)
        h.tower.seedRecord(id: doc, type: "document", title: "Release notes", channel: Fixtures.channel2, scope: scope)
        h.tower.seedRecord(id: forbidden, type: "task", title: "Board-only", channel: Fixtures.channel2, scope: scope)
        h.tower.deny(record: forbidden)
        return (thread, task, doc, forbidden)
    }

    func testPinsAreReadThroughTheRecordSyncFeedAcrossPages() async throws {
        let h = try await SurfaceHarness.make()
        let r = pinnable(h)
        h.tower.pinPageSize = 2
        h.tower.externalPin(type: "thread", resource: r.thread, pinned: true)
        h.tower.externalPin(type: "task", resource: r.task, pinned: true)
        h.tower.externalPin(type: "document", resource: r.doc, pinned: true)
        h.tower.externalPin(type: "channel", resource: Fixtures.channel1, pinned: true)
        h.tower.externalPin(type: "document", resource: r.doc, pinned: false)
        h.other.externalPin(type: "task", resource: r.task, pinned: true)
        await h.sync.refreshPins(h.connection, h.workspace)
        await h.idle()
        let items = try await h.store.reader.pinnedItems(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(Set(items.map(\.pin.resourceType)), [.thread, .task, .channel], "an unpinned row is a tombstone, not a pin")
        let feed = h.transport.recorded.compactMap(\.url).filter { $0.path.hasSuffix("/record-sync/priority") }
        XCTAssertEqual(feed.count, 2, "two pages of two")
        XCTAssertTrue(feed.allSatisfy { $0.query?.contains("family=personal_pin") == true })
        let channel = try XCTUnwrap(items.first { $0.pin.resourceType == .channel })
        XCTAssertEqual(channel.title, "one", "titles come from the local store")
        let task = try XCTUnwrap(items.first { $0.pin.resourceType == .task })
        XCTAssertNil(task.title, "a task not stored on this phone has no title yet")
        XCTAssertEqual(task.channelId, Fixtures.channel1)
        let tombstone = try await h.store.reader.pin(connectionId: h.connection.id, workspaceId: h.workspace.id, type: .document, resourceId: r.doc)
        XCTAssertEqual(tombstone?.pinned, false)
        let other = try await h.store.reader.pinnedItems(connectionId: h.connection.id, workspaceId: Fixtures.workspaceId2)
        XCTAssertTrue(other.isEmpty)

        // An expired continuation restarts the pass once instead of failing.
        h.tower.inject(.status(409, "auxiliary_cursor_invalid"), matching: "/record-sync/priority")
        await h.sync.refreshPins(h.connection, h.workspace, force: true)
        await h.idle()
        let failure = await h.error(WorkspaceSync.pinsKey(h.workspace.id))
        XCTAssertNil(failure)
    }

    func testPinWritesReplayResolveConflictsAndRefuseForbiddenTargets() async throws {
        let h = try await SurfaceHarness.make()
        let r = pinnable(h)
        func intent(_ type: PinRecord.ResourceType, _ id: String, _ pinned: Bool, expected: Int) -> WriteIntent {
            WriteIntent(kind: .pinSet, targetId: id, payload: ["resource_type": type.rawValue, "pinned": pinned, "expected_row_version": expected,
                                                                "mutation_id": UUID().uuidString.lowercased()])
        }
        // 1. Pin a thread; the reply is lost after Tower committed it. The resend carries the same mutation id and replays.
        h.tower.inject(.dropResponseAfterCommit, matching: "/me/pins/thread/\(r.thread)")
        _ = try await h.writes.submit(intent(.thread, r.thread, true, expected: 0), connection: h.connection, workspace: h.workspace)
        await h.work.settled()
        await h.writes.kick(h.connection, force: true); await h.idle()
        var pending = try await h.work.pending()
        XCTAssertTrue(pending.isEmpty, "\(pending.map { ($0.state, $0.lastError) })")
        XCTAssertEqual(h.tower.pinRows().filter { $0["resource_id"] as? String == r.thread }.first?["row_version"] as? Int, 1, "applied once")
        let thread = try await h.store.reader.pin(connectionId: h.connection.id, workspaceId: h.workspace.id, type: .thread, resourceId: r.thread)
        XCTAssertEqual(thread?.pinned, true, "acknowledged row stored")

        // 2. Another device pinned and unpinned the task meanwhile (version 2); this phone still believes version 0.
        h.tower.externalPin(type: "task", resource: r.task, pinned: true)
        h.tower.externalPin(type: "task", resource: r.task, pinned: false)
        _ = try await h.writes.submit(intent(.task, r.task, true, expected: 0), connection: h.connection, workspace: h.workspace)
        await h.work.drainWrites()
        pending = try await h.work.pending()
        XCTAssertTrue(pending.isEmpty, "conflict re-read and resent against the current version")
        let task = h.tower.pinRows().first { $0["resource_id"] as? String == r.task }
        XCTAssertEqual(task?["pinned"] as? Bool, true)
        XCTAssertEqual(task?["row_version"] as? Int, 3)

        // 3. Conflict where Tower already has the requested state: done without another write.
        h.tower.externalPin(type: "document", resource: r.doc, pinned: true)
        _ = try await h.writes.submit(intent(.document, r.doc, true, expected: 0), connection: h.connection, workspace: h.workspace)
        await h.work.drainWrites()
        XCTAssertEqual(h.tower.pinRows().first { $0["resource_id"] as? String == r.doc }?["row_version"] as? Int, 1)

        // 4. A target the viewer cannot read: refused, kept as failed for the user.
        _ = try await h.writes.submit(intent(.task, r.forbidden, true, expected: 0), connection: h.connection, workspace: h.workspace)
        await h.work.drainWrites()
        pending = try await h.work.pending()
        XCTAssertEqual(pending.map(\.state), [.failed])
        XCTAssertEqual(pending.first?.lastStatus, 403)
        XCTAssertEqual(pending.first?.lastError, "You can no longer pin this.")
        XCTAssertFalse(h.tower.pinRows().contains { $0["resource_id"] as? String == r.forbidden && $0["pinned"] as? Bool == true })
    }

    func testPinsAndToolboxAreBoundToTheirConnection() async throws {
        let h = try await SurfaceHarness.make()
        let r = pinnable(h)
        h.tower.externalPin(type: "task", resource: r.task, pinned: true)
        h.tower.seedWapp(title: "Mine", launchURL: "https://mine.example", sortOrder: 0, owner: TestKeys.npub)
        await h.sync.refreshPins(h.connection, h.workspace)
        await h.sync.refreshToolbox(h.connection, h.workspace)
        await h.idle()
        // A second connection (another origin/signer) to the same workspace id sees none of them.
        let other = try await h.store.writer.saveConnection(ConnectionRecord(origin: try TowerOrigin("https://other-tower.example"),
                                                                             signerNpub: Bech32.encode(hrp: "npub", data: Data(repeating: 0x42, count: 32)), towerNpub: nil))
        let foreignPins = try await h.store.reader.pinnedItems(connectionId: other.id, workspaceId: h.workspace.id)
        let foreignWapps = try await h.store.reader.personalWapps(connectionId: other.id, workspaceId: h.workspace.id)
        XCTAssertTrue(foreignPins.isEmpty); XCTAssertTrue(foreignWapps.isEmpty)
        let mine = try await h.store.reader.pinnedItems(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(mine.count, 1)
        // Disconnecting removes them with the connection.
        try await h.store.writer.removeConnection(id: h.connection.id)
        let afterPins = try await h.store.reader.pinnedItems(connectionId: h.connection.id, workspaceId: h.workspace.id)
        let afterWapps = try await h.store.reader.personalWapps(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertTrue(afterPins.isEmpty); XCTAssertTrue(afterWapps.isEmpty)
    }

    // MARK: Retention and isolation

    func testBuildSixStoreUpgradesToSchemaFourKeepingEverything() async throws {
        let directory = temporaryDirectory()
        do {
            let store = try LocalStore(directory: directory)
            let connection = try await store.writer.saveConnection(ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil))
            try await store.writer.replaceWorkspaces(connectionId: connection.id, [try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId, label: "Studio")))])
            try await store.writer.setState("selected.connection", connection.id)
            // Back to the build-6 layout: schema 3 without the v4 tables.
            let db = try SQLiteConnection(path: store.path, readOnly: false)
            for table in Schema.v4WorkspaceTables { try db.execute("DROP TABLE \(table)") }
            try db.execute("PRAGMA user_version = 3")
        }
        let reopened = try LocalStore(directory: directory)
        let version = try await reopened.writer.schemaVersion()
        XCTAssertEqual(version, 4)
        let connections = try await reopened.reader.connections()
        XCTAssertEqual(connections.map(\.origin), ["https://tower.example"])
        let selected = try await reopened.reader.state("selected.connection")
        XCTAssertEqual(selected, connections.first?.id)
        let pins = try await reopened.reader.pinnedItems(connectionId: connections.first!.id, workspaceId: Fixtures.workspaceId)
        XCTAssertTrue(pins.isEmpty, "new tables exist and start empty")
    }

    func testLosingAScopeOrChannelPurgesItsSurfaces() async throws {
        let h = try await SurfaceHarness.make()
        h.tower.seedComponent(scope: scope, title: "Kept until scope is lost", sortOrder: 0)
        h.tower.seedActivity(channel: Fixtures.channel2, scope: scope, thread: UUID().uuidString.lowercased(),
                             agent: TestKeys.npub, state: "working", label: "Busy")
        await h.sync.refreshContextTree(h.connection, h.workspace, scopeId: scope)
        await h.sync.refreshAgentActivity(h.connection, h.workspace, channelId: Fixtures.channel2)
        await h.idle()
        // Channel two disappears from the complete channel list (lost access).
        try await h.store.writer.upsertChannels(workspaceId: h.workspace.id, scopeId: scope,
                                                [try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: scope, name: "one")))], complete: true)
        let activity = try await h.store.reader.agentActivities(workspaceId: h.workspace.id, channelIds: nil)
        XCTAssertTrue(activity.isEmpty)
        // The whole scope disappears.
        try await h.store.writer.upsertScopes(workspaceId: h.workspace.id, [], complete: true)
        let tree = try await h.store.reader.contextTree(workspaceId: h.workspace.id, scopeId: scope)
        XCTAssertTrue(tree.isEmpty)
    }
}

/// A standard `.excalidraw` scene covering the supported subset, the listed unsupported types and a deleted element.
struct BoardSceneFixture {
    let fileId: String
    let versionId: String
    let bytes: Data

    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    static func make() -> BoardSceneFixture {
        func element(_ id: String, _ type: String, x: Double, y: Double, w: Double, h: Double, extra: [String: Any] = [:]) -> [String: Any] {
            ["id": id, "type": type, "x": x, "y": y, "width": w, "height": h, "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
             "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid", "roughness": 1, "opacity": 100, "groupIds": [], "frameId": NSNull(),
             "roundness": NSNull(), "seed": 1, "version": 3, "versionNonce": 7, "isDeleted": false, "boundElements": NSNull(), "updated": 1, "link": NSNull(),
             "locked": false].merging(extra) { _, b in b }
        }
        let elements: [[String: Any]] = [
            element("rect", "rectangle", x: 0, y: 0, w: 200, h: 100, extra: ["backgroundColor": "#a5d8ff", "fillStyle": "hachure", "roundness": ["type": 3]]),
            element("ell", "ellipse", x: 240, y: 0, w: 120, h: 80),
            element("dia", "diamond", x: 400, y: 0, w: 120, h: 80),
            element("arr", "arrow", x: 200, y: 50, w: 120, h: 40, extra: ["points": [[0, 0], [120, 40]], "startArrowhead": NSNull(), "endArrowhead": "arrow"]),
            element("lin", "line", x: 0, y: 150, w: 100, h: 0, extra: ["points": [[0, 0], [100, 0]]]),
            element("pen", "freedraw", x: 0, y: 200, w: 30, h: 30, extra: ["points": [[0, 0], [10, 20], [30, 30]], "pressures": []]),
            element("txt", "text", x: 20, y: 30, w: 160, h: 25, extra: ["text": "Tower owns records", "fontSize": 20, "fontFamily": 1, "textAlign": "center",
                                                                     "verticalAlign": "middle", "containerId": "rect", "originalText": "Tower owns records"]),
            element("img", "image", x: 300, y: 200, w: 64, h: 64, extra: ["fileId": "png1", "status": "saved", "scale": [1, 1]]),
            element("svg", "image", x: 380, y: 200, w: 64, h: 64, extra: ["fileId": "svg1"]),
            element("frm", "frame", x: -10, y: -10, w: 540, h: 300, extra: ["name": "Ownership"]),
            element("emb", "embeddable", x: 0, y: 300, w: 200, h: 120, extra: ["link": "https://example.com"]),
            element("ifr", "iframe", x: 0, y: 300, w: 200, h: 120),
            element("mag", "magicframe", x: 0, y: 300, w: 200, h: 120),
            element("old", "rectangle", x: 9000, y: 9000, w: 10, h: 10, extra: ["isDeleted": true]),
        ]
        let scene: [String: Any] = [
            "type": "excalidraw", "version": 2, "source": "wingman-ambulando", "elements": elements,
            "appState": ["viewBackgroundColor": "#fdf8f0"],
            "files": [
                "png1": ["id": "png1", "mimeType": "image/png", "dataURL": "data:image/png;base64," + png.base64EncodedString(), "created": 1],
                "svg1": ["id": "svg1", "mimeType": "image/svg+xml", "dataURL": "data:image/svg+xml;base64,PHN2Zy8+", "created": 1],
            ],
        ]
        return BoardSceneFixture(fileId: UUID().uuidString.lowercased(), versionId: UUID().uuidString.lowercased(),
                                 bytes: try! JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys]))
    }
}
