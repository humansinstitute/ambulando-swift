import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct ArtefactChatContextTests {
    let w = "11111111-1111-4111-8111-111111111111"
    let c = "22222222-2222-4222-8222-222222222222"
    let t = "33333333-3333-4333-8333-333333333333"
    let f = "44444444-4444-4444-8444-444444444444"
    let v = "55555555-5555-4555-8555-555555555555"
    var target: ChatTarget { .init(connectionId: "local", workspaceId: w, channelId: c, threadId: t) }
    @Test func contextKeepsExactHistoricalAndSavedRevisions() throws {
        let context = ArtefactChatContext(workspaceID: w, channelID: c, threadID: t, visibleRecordID: f,
            open: [.init(kind: "file", recordID: f, revision: v, historical: true, digest: String(repeating: "a", count: 64))])
        let data = try context.encoded(for: target)
        #expect(try JSONDecoder().decode(ArtefactChatContext.self, from: data) == context)
        #expect(try ArtefactChatContext.validate(data, for: target) == data)
    }
    @Test func rejectsMalformedForeignOversizedAndDuplicateContexts() throws {
        let context = ArtefactChatContext(workspaceID: w, channelID: c, threadID: t, visibleRecordID: f,
            open: [.init(kind: "file", recordID: f, revision: v, historical: true, digest: String(repeating: "a", count: 64))])
        let data = try context.encoded(for: target)
        let foreign = ChatTarget(connectionId: "local", workspaceId: c, channelId: c, threadId: t)
        #expect(throws: (any Error).self) { try ArtefactChatContext.validate(data, for: foreign) }
        #expect(throws: (any Error).self) { try ArtefactChatContext.validate(Data(repeating: 32, count: 16385), for: target) }
        for mutate in ["version", "revision", "duplicate", "count", "digest"] {
            var o = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var refs = o["open"] as! [[String: Any]]
            if mutate == "version" { o["schemaVersion"] = 2 }
            if mutate == "revision" { refs[0]["revision"] = "latest" }
            if mutate == "duplicate" { refs += refs }
            if mutate == "digest" { refs[0]["digest"] = nil }
            if mutate == "count" { refs = Array(repeating: refs[0], count: 33) }
            o["open"] = refs
            let bad = try JSONSerialization.data(withJSONObject: o)
            #expect(throws: (any Error).self) { try ArtefactChatContext.validate(bad, for: target) }
        }
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
        #expect(saved.digest == SHA256Hex.of(try #require(store.bytes(saved.revision))))
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
