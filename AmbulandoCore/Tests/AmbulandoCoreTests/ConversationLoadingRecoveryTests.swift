import XCTest
import SQLite3
@testable import AmbulandoCore

// Exercise the same serialized reader used by Deck and Chat. An instruction budget
// catches workspace-wide scans deterministically, without depending on host load.
private extension StoreReader {
    func recoveryChat(workspaceId: String, started: @Sendable () -> Void) throws -> Int {
        var deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        return try withUnsafeMutablePointer(to: &deadline) { end in
            sqlite3_progress_handler(db.handle, 1_000, { context in
                DispatchTime.now().uptimeNanoseconds >= context!.assumingMemoryBound(to: UInt64.self).pointee ? 1 : 0
            }, end)
            defer { sqlite3_progress_handler(db.handle, 0, nil, nil) }
            started()
            return try conversations(workspaceId: workspaceId, context: .home, viewer: TestKeys.npub).count
        }
    }

    func recoveryLoad(workspaceId: String, chat: Bool) throws -> Int {
        var remaining = 30_000
        return try withUnsafeMutablePointer(to: &remaining) { counter in
            sqlite3_progress_handler(db.handle, 1_000, { context in
                let counter = context!.assumingMemoryBound(to: Int.self)
                counter.pointee -= 1
                return counter.pointee <= 0 ? 1 : 0
            }, counter)
            defer {
                sqlite3_progress_handler(db.handle, 0, nil, nil)
                print("Recovery \(chat ? "Chat" : "Summary") SQLite instructions: \((30_000 - counter.pointee) * 1_000)")
            }
            if chat {
                return try conversations(workspaceId: workspaceId, context: .home, viewer: TestKeys.npub).count
            }
            return try channelThreads(workspaceId: workspaceId, channelId: "history-0").count
        }
    }
}

final class ConversationLoadingRecoveryTests: XCTestCase {
    func testExistingHistoryUpgradeLoadsDeckAndChatAndRetainsPendingWork() async throws {
        let h = try await ChatHarness.make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let target = h.target("history-0", thread: "discussion-0")
        let pending = try await h.store.writer.enqueueSend(target: target, origin: h.connection.origin,
            signerNpub: TestKeys.npub, appNpub: h.workspace.appNpub, body: "retained outbox", mentions: [])
        try await h.store.writer.saveDraft(target, Draft(text: "retained draft", mentions: []))
        let db = try SQLiteConnection(path: h.store.path, readOnly: false)
        // Schema10 had message FTS, branch membership and durable pending work, but
        // no thread title index. Populate that retained shape before an actual reopen.
        try db.execute("DROP TRIGGER search_threads_ai; DROP TRIGGER search_threads_au; DROP TRIGGER search_threads_ad; DELETE FROM search_index WHERE kind = 'thread'; PRAGMA user_version = 10;")
        try db.transaction {
            let channel = try db.prepare("INSERT INTO channels(workspace_id,id,scope_id,name,row_version,updated_at,raw) VALUES(?,?,'scope','History',1,'1',?)")
            for c in 0..<6 { try channel.run([.text(h.workspace.id), .text("history-\(c)"), .blob(Data("{}".utf8))]) }
            let thread = try db.prepare("INSERT INTO threads(workspace_id,id,channel_id,title,row_version,updated_at,raw) VALUES(?,?,?,'Retained discussion',1,'1',?)")
            let message = try db.prepare("INSERT INTO messages(workspace_id,id,channel_id,thread_id,body,sender_npub,created_at,updated_at,row_version,raw) VALUES(?,?,?,?,?,?,?,?,1,?)")
            for t in 0..<1_200 {
                let id = "discussion-\(t)", c = "history-\(t % 6)"
                try thread.run([.text(h.workspace.id), .text(id), .text(c), .blob(Data("{}".utf8))])
                for m in 0..<40 {
                    let stamp = String(format: "%05d-%05d", t, m)
                    try message.run([.text(h.workspace.id), .text("\(id)-\(m)"), .text(c), .text(id),
                        .text("Cached reply \(m)"), .text(t == 1 ? FixtureNpubs.other : TestKeys.npub), .text(stamp), .text(stamp), .blob(Data("{}".utf8))])
                }
            }
            // Canonical+effective duplicates count once. An inherited foreign-owner
            // message participates in summaries without moving or copying its record.
            try db.execute("INSERT INTO thread_membership VALUES('\(h.workspace.id)','discussion-0','discussion-0-0',0),('\(h.workspace.id)','discussion-0','discussion-1-0',1)")
        }
        let start = ContinuousClock.now
        let upgraded = try LocalStore(directory: h.directory.appendingPathComponent("Store"))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2), "retained-store migration must not block startup")
        var loaded = true
        for chat in [false, true] {
            do {
                let count = try await upgraded.reader.recoveryLoad(workspaceId: h.workspace.id, chat: chat)
                XCTAssertEqual(count, chat ? 1_200 : 200)
            } catch {
                loaded = false
                XCTFail("\(chat ? "Chat" : "Channel summaries") could not load retained history within SQLite work budget: \(error)")
            }
        }
        // Signal from inside the reader, so Deck is genuinely queued behind the
        // in-flight Chat read rather than winning a task scheduling race.
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let chat = Task {
            try await upgraded.reader.recoveryChat(workspaceId: h.workspace.id, started: { signal.continuation.yield(()) })
        }
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        signal.continuation.finish()
        let queued = ContinuousClock.now
        let deck = try await upgraded.reader.deckThreads(workspaceId: h.workspace.id, channelIds: nil)
        let waited = queued.duration(to: .now)
        print("Deck queued behind Chat: \(waited)")
        XCTAssertEqual(deck.count, 300, "Deck retains its normal bounded activity feed")
        XCTAssertLessThan(waited, .seconds(1.5), "Chat must not starve the actual Deck request on the shared reader")
        do {
            let count = try await chat.value
            XCTAssertEqual(count, 1_200)
        } catch {
            loaded = false
            XCTFail("Chat did not finish loading the retained history: \(error)")
        }
        guard loaded else { return }
        let summary = try await upgraded.reader.channelThreads(workspaceId: h.workspace.id, channelId: "history-0", limit: 1_200).first { $0.id == "discussion-0" }
        XCTAssertEqual(summary?.replyCount, 40, "canonical and effective memberships deduplicate")
        let participants = try await upgraded.reader.threadParticipantNpubs(workspaceId: h.workspace.id, threadId: "discussion-0")
        XCTAssertEqual(Set(participants), Set([TestKeys.npub, FixtureNpubs.other]))
        let inherited = try await upgraded.reader.message(workspaceId: h.workspace.id, id: "discussion-1-0")
        XCTAssertEqual(inherited?.threadId, "discussion-1", "effective membership preserves canonical ownership")
        let reopened = try LocalStore(directory: h.directory.appendingPathComponent("Store"))
        let version = try await reopened.writer.schemaVersion()
        let draft = try await reopened.reader.draft(target)
        let item = try await reopened.reader.outboxItem(id: pending.id)
        XCTAssertEqual(version, 11)
        XCTAssertEqual(draft?.text, "retained draft")
        XCTAssertEqual(item?.body, "retained outbox")
        let titles = try db.prepare("SELECT COUNT(*) FROM search_index WHERE search_index MATCH 'title : retained' AND kind = 'thread'")
        XCTAssertTrue(try titles.step())
        XCTAssertEqual(titles.int(0), 1_200, "title migration survives idempotent reopen")
    }
}
