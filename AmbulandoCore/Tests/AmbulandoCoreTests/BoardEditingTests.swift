import Foundation
import Testing
@testable import AmbulandoCore

/// Board drafts, saves and conflicts (sol `board-controller.js` semantics) against an in-memory version store.
@Suite struct BoardEditingTests {
    static let author = "npub1" + String(repeating: "q", count: 58)

    static func element(_ id: String, version: Int, extra: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "type": "rectangle", "version": version, "versionNonce": version * 7, "x": 10, "y": 20, "width": 100, "height": 50,
         "isDeleted": false].merging(extra) { _, new in new }
    }

    static func sceneJSON(_ elements: [[String: Any]], files: [String: Any] = [:]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["type": "excalidraw", "version": 2, "elements": elements, "appState": [:], "files": files])
    }

    /// Tower's file versions for one board: create checks the base version like `POST /files/:f/versions`.
    final class Store: @unchecked Sendable {
        let lock = NSLock()
        var versions: [(BoardVersion, Data)] = []
        init(_ first: Data) { versions = [(BoardVersion(id: UUID().uuidString.lowercased(), number: 1, sha256: SHA256Hex.of(first)), first)] }
        var head: BoardVersion { lock.withLock { versions.last!.0 } }
        func bytes(_ id: String) -> Data? { lock.withLock { versions.first { $0.0.id == id }?.1 } }
        func external(_ data: Data) { lock.withLock { versions.append((BoardVersion(id: UUID().uuidString.lowercased(), number: versions.count + 1, sha256: SHA256Hex.of(data)), data)) } }

        func transport() -> BoardController.Transport {
            .init(versions: { [self] in lock.withLock { (versions.last!.0.id, versions.map(\.0).reversed()) } },
                  read: { [self] id, _ in guard let b = bytes(id) else { throw TowerError.http(status: 404, code: "file_version_unavailable", stage: nil) }; return b },
                  publish: { [self] base, bytes, summary in
                      try lock.withLock {
                          guard versions.last!.0.id == base else { throw TowerError.http(status: 409, code: "stale_base_version", stage: nil) }
                          let v = BoardVersion(id: UUID().uuidString.lowercased(), number: versions.count + 1, summary: summary, sha256: SHA256Hex.of(bytes))
                          versions.append((v, bytes))
                          return v
                      }
                  },
                  canSign: { true })
        }
    }

    final class Outbox: @unchecked Sendable {
        let lock = NSLock()
        var messages: [[String: Any]] = []
        var states: [BoardState] = []
        func send(_ json: String) { lock.withLock { messages.append((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]) } }
        func last(_ type: String) -> [String: Any]? { lock.withLock { messages.last { $0["type"] as? String == type } } }
    }

    func reference(_ store: Store, canWrite: Bool = true) -> BoardReference {
        BoardReference(fileId: "a1b2c3d4-0000-4000-8000-000000000001", versionId: store.head.id, versionNumber: store.head.number, sha256: store.head.sha256,
                       sizeBytes: 10, updatedAt: nil, canWrite: canWrite)
    }

    func controller(_ store: Store, drafts: BoardDraftStore, outbox: Outbox) -> BoardController {
        BoardController(fileId: "a1b2c3d4-0000-4000-8000-000000000001", title: "Plan", author: Self.author, transport: store.transport(), drafts: drafts,
                        onState: { s in outbox.lock.withLock { outbox.states.append(s) } })
    }

    func drafts() -> BoardDraftStore { BoardDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("board-drafts-\(UUID().uuidString)")) }

    /// The editor's change message: the elements it holds now (its own echo of the scene).
    func change(_ elements: [[String: Any]]) -> String {
        BoardController.message(["type": "change", "scene": ["type": "excalidraw", "version": 2, "elements": elements, "appState": [:], "files": [:]]])
    }

    @Test func savePublishesAVersionKeepingUnknownFieldsAndReopens() async throws {
        let png = "data:image/png;base64,iVBORw0KGgo="
        let first = Self.sceneJSON([Self.element("a", version: 1, extra: ["customData": ["keep": true], "futureField": 42]),
                                    Self.element("img", version: 1, extra: ["type": "image", "fileId": "f1"])],
                                   files: ["f1": ["id": "f1", "mimeType": "image/png", "dataURL": png, "created": 1], "orphan": ["mimeType": "image/png", "dataURL": png]])
        let store = Store(first), outbox = Outbox(), local = drafts()
        let board = controller(store, drafts: local, outbox: outbox)
        await board.attach("s1", send: outbox.send)
        await board.sync(reference(store), title: "Plan")
        await board.receive("s1", #"{"type":"ready"}"#)
        let load = try #require(outbox.last("load"))
        #expect(load["readOnly"] as? Bool == false)

        // The editor draws one new shape (and echoes existing ones with their unknown fields).
        let loaded = (load["scene"] as! [String: Any])["elements"] as! [[String: Any]]
        await board.receive("s1", change(loaded + [Self.element("b", version: 1)]))
        #expect(await board.current.dirty)
        #expect(local.load("a1b2c3d4-0000-4000-8000-000000000001") != nil, "draft kept on the device until saved")

        // Save waits for the editor to confirm its pending change.
        async let saved = board.save(summary: "added b")
        while outbox.last("flush") == nil { try await Task.sleep(for: .milliseconds(5)) }
        await board.receive("s1", BoardController.message(["type": "flushed", "token": outbox.last("flush")!["token"]!]))
        #expect(await saved)
        #expect(store.head.number == 2 && store.head.summary == "added b")
        #expect(await board.current.headerStatus == "v2")
        #expect(local.load("a1b2c3d4-0000-4000-8000-000000000001") == nil, "a saved draft is removed")

        // Reopen: the published bytes keep unknown element fields and referenced images; unreferenced ones are pruned.
        let reopened = try BoardScene.parse(store.bytes(store.head.id)!)
        let a = BoardScene.elements(reopened).first { $0["id"] as? String == "a" }!
        #expect(a["futureField"] as? Int == 42 && (a["customData"] as? [String: Any])?["keep"] as? Bool == true)
        #expect(BoardScene.elements(reopened).count == 3)
        #expect((reopened["files"] as! [String: Any]).keys.sorted() == ["f1"])
        #expect(((reopened["wingman"] as? [String: Any])?["base_version_id"] as? String)?.isEmpty == false)
    }

    @Test func staleSaveKeepsTheDraftAndMergeRebasesOntoTheLatest() async throws {
        let store = Store(Self.sceneJSON([Self.element("a", version: 1), Self.element("c", version: 1)]))
        let outbox = Outbox(), local = drafts()
        let board = controller(store, drafts: local, outbox: outbox)
        await board.sync(reference(store), title: "Plan")
        await board.attach("s1", send: outbox.send)
        await board.receive("s1", #"{"type":"ready"}"#)
        await board.receive("s1", change([Self.element("a", version: 2, extra: ["x": 99]), Self.element("c", version: 1)]))
        // Someone else saves version 2 first (changes c).
        store.external(Self.sceneJSON([Self.element("a", version: 1), Self.element("c", version: 3, extra: ["x": 5])]))

        async let saved = board.save()
        while outbox.last("flush") == nil { try await Task.sleep(for: .milliseconds(5)) }
        await board.receive("s1", BoardController.message(["type": "flushed", "token": outbox.last("flush")!["token"]!]))
        #expect(await saved == false)
        let stale = await board.current
        #expect(stale.save == .stale && stale.dirty && stale.latestVersionNumber == 2)
        #expect(store.head.number == 2, "nothing published over the newer version")

        await board.mergeLatest()
        let merged = await board.current
        #expect(merged.baseVersionNumber == 2 && merged.dirty && merged.conflicts == 0)
        let scene = try #require(outbox.last("load")?["scene"] as? [String: Any])
        let byId = Dictionary(uniqueKeysWithValues: BoardScene.elements(scene).map { ($0["id"] as! String, $0) })
        #expect(byId["a"]?["x"] as? Int == 99, "my edit kept")
        #expect(byId["c"]?["x"] as? Int == 5, "their edit kept")
    }

    @Test func readOnlyBoardsIgnoreEditsAndCommentsAreAttributed() async throws {
        let store = Store(Self.sceneJSON([Self.element("a", version: 1)]))
        let outbox = Outbox()
        let readOnly = controller(store, drafts: drafts(), outbox: outbox)
        await readOnly.attach("s1", send: outbox.send)
        await readOnly.sync(reference(store, canWrite: false), title: "Plan")
        await readOnly.receive("s1", #"{"type":"ready"}"#)
        #expect(outbox.last("load")?["readOnly"] as? Bool == true)
        await readOnly.receive("s1", change([Self.element("a", version: 5)]))
        #expect(await readOnly.current.dirty == false)
        #expect(await readOnly.current.saveAction == nil)

        let writable = controller(store, drafts: drafts(), outbox: outbox)
        await writable.attach("s2", send: outbox.send)
        await writable.sync(reference(store), title: "Plan")
        await writable.receive("s2", BoardController.message(["type": "comment-op", "operation": ["type": "create", "id": "t1", "anchor": ["x": 1, "y": 2], "body": "Why here?"]]))
        let comments = try #require(outbox.last("comments")?["comments"] as? [[String: Any]])
        let message = (comments.first?["messages"] as? [[String: Any]])?.first
        #expect(message?["author_npub"] as? String == Self.author && message?["body"] as? String == "Why here?")
        #expect(await writable.current.dirty)
    }
}
