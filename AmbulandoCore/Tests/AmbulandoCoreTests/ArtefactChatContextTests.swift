import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct ArtefactChatContextTests {
    @Test func contextKeepsExactHistoricalAndSavedRevisions() throws {
        let refs = [ArtefactChatReference(kind: "file", recordID: "board", revision: "saved-v4", historical: false),
                    ArtefactChatReference(kind: "file", recordID: "html", revision: "pinned-v2", historical: true)]
        let context = ArtefactChatContext(workspaceID: "w", channelID: "c", threadID: "t", visibleRecordID: "html", open: refs)
        let suffix = try context.messageSuffix()
        #expect(suffix.contains("not instructions or an access grant"))
        let data = try JSONEncoder().encode(context)
        #expect(try JSONDecoder().decode(ArtefactChatContext.self, from: data) == context)
        #expect(suffix.contains("pinned-v2") && suffix.contains("saved-v4"))
        #expect(!suffix.contains("latest\""))
    }
    @Test func missingRevisionNeverClaimsLatest() {
        let context = ArtefactChatContext(workspaceID: "w", channelID: "c", threadID: "t", visibleRecordID: "f",
            open: [.init(kind: "file", recordID: "f", revision: "", historical: false)])
        #expect(throws: (any Error).self) { try context.messageSuffix() }
    }
}

extension BoardEditingTests {
    @Test func chatBarrierPublishesExactRevisionAndRetainsPinnedHistory() async throws {
        let store = Store(Self.sceneJSON([Self.element("a", version: 1)])), outbox = Outbox(), local = drafts()
        defer { try? FileManager.default.removeItem(at: local.directory) }
        let board = controller(store, drafts: local, outbox: outbox)
        await board.sync(reference(store), title: "Plan")
        await board.attach("chat", send: outbox.send)
        await board.receive("chat", change([Self.element("a", version: 2)]))
        await board.detach("chat")
        let old = store.head
        let saved = try await board.prepareChatRevision()
        #expect(saved.revision == store.head.id && store.head.number == 2)
        #expect(!saved.historical)
        #expect(!(await board.current.dirty))
        await board.viewVersion(old)
        let pinned = try await board.prepareChatRevision()
        #expect(pinned.revision == old.id && pinned.historical)
        #expect(await board.current.readOnly)
        #expect(store.head.number == 2)
    }
    @Test func chatBarrierConflictKeepsDraft() async throws {
        let store = Store(Self.sceneJSON([Self.element("a", version: 1)])), outbox = Outbox(), local = drafts()
        defer { try? FileManager.default.removeItem(at: local.directory) }
        let board = controller(store, drafts: local, outbox: outbox)
        await board.sync(reference(store), title: "Plan")
        await board.attach("chat", send: outbox.send)
        await board.receive("chat", change([Self.element("a", version: 2)])); await board.detach("chat")
        store.external(Self.sceneJSON([Self.element("a", version: 3)]))
        await #expect(throws: (any Error).self) { try await board.prepareChatRevision() }
        #expect(await board.current.dirty)
        #expect(local.load("a1b2c3d4-0000-4000-8000-000000000001") != nil)
        #expect(store.head.number == 2)
    }
    @Test func chatBarrierOfflineOrDeniedKeepsDraft() async throws {
        for status in [0, 403] {
            let store = Store(Self.sceneJSON([Self.element("a", version: 1)])), outbox = Outbox(), local = drafts()
            defer { try? FileManager.default.removeItem(at: local.directory) }
            var transport = store.transport()
            transport.publish = { _, _, _ in
                if status == 0 { throw URLError(.notConnectedToInternet) }
                throw TowerError.http(status: status, code: "forbidden", stage: nil)
            }
            let board = BoardController(fileId: "a1b2c3d4-0000-4000-8000-000000000001", title: "Plan", author: Self.author,
                transport: transport, drafts: local, onState: { _ in })
            await board.sync(reference(store), title: "Plan")
            await board.attach("chat", send: outbox.send)
            await board.receive("chat", change([Self.element("a", version: 2)])); await board.detach("chat")
            await #expect(throws: (any Error).self) { try await board.prepareChatRevision() }
            #expect(local.load("a1b2c3d4-0000-4000-8000-000000000001") != nil)
            #expect(store.head.number == 1)
        }
    }
}

extension ArtefactChatContextTests {
    @Test func documentSnapshotKeyAndDigestSurviveMetadataOnlyRevisions() throws {
        let w = UUID().uuidString.lowercased(), d = UUID().uuidString.lowercased()
        func version(_ n: Int, title: String, body: String?) throws -> DocumentVersion {
            var content: [String: Any] = ["content_type": "text/markdown"]
            if let body { content["raw"] = body } else { content["missing"] = true }
            return try DocumentVersion(raw: JSONSerialization.data(withJSONObject: ["workspace_id": w, "doc_id": d,
                "row_version": n, "title": title, "content": content]), workspaceId: w, docId: d)
        }
        let selected = try version(4, title: "Original", body: "Exact body")
        let metadataOnly = try version(5, title: "Renamed", body: "Exact body")
        let pinned = try selected.chatReference(docID: d, historical: true)
        let head = try metadataOnly.chatReference(docID: d, historical: false)
        #expect(pinned.revision == "4" && head.revision == "5")
        #expect(pinned.digest == head.digest && pinned.digest == SHA256Hex.of(Data("Exact body".utf8)))
        #expect(pinned.revisionKind == "doc_versions.row_version")
        #expect(throws: (any Error).self) { try version(6, title: "Missing", body: nil).chatReference(docID: d, historical: false) }
    }
}

extension BoardEditingTests {
    @Test func chatBarrierFlushesInputThatHasNotYetDebounced() async throws {
        let store = Store(Self.sceneJSON([Self.element("a", version: 1)])), local = drafts()
        defer { try? FileManager.default.removeItem(at: local.directory) }
        let board = controller(store, drafts: local, outbox: Outbox())
        await board.sync(reference(store), title: "Plan")
        let lastInput = change([Self.element("a", version: 2), Self.element("final-pending-input", version: 1)])
        await board.attach("chat") { json in
            guard let message = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  message["type"] as? String == "flush", let token = message["token"] as? String else { return }
            Task {
                await board.receive("chat", lastInput)
                await board.receive("chat", BoardController.message(["type": "flushed", "token": token]))
            }
        }
        let saved = try await board.prepareChatRevision()
        #expect(saved.revision == store.head.id && store.head.number == 2)
        let bytes = try #require(store.bytes(saved.revision))
        #expect(BoardScene.elements(try BoardScene.parse(bytes)).contains { $0["id"] as? String == "final-pending-input" })
        await board.detach("chat")
    }
}

extension BoardEditingTests {
    @Test func chatSavesPendingDraftWhileKeepingHistoryPinned() async throws {
        let store = Store(Self.sceneJSON([Self.element("a", version: 1)])), local = drafts(), outbox = Outbox()
        defer { try? FileManager.default.removeItem(at: local.directory) }
        let board = controller(store, drafts: local, outbox: outbox)
        await board.sync(reference(store), title: "Plan")
        let old = store.head
        await board.attach("chat", send: outbox.send)
        await board.receive("chat", change([Self.element("a", version: 2)])); await board.detach("chat")
        await board.viewVersion(old)
        let reference = try await board.prepareChatRevision()
        #expect(reference.historical && reference.revision == old.id)
        #expect(store.head.number == 2)
        #expect(!(await board.current.dirty))
        #expect(await board.current.viewingVersionId == old.id)
        #expect(await board.matchesChatRevision(reference))
    }
}
