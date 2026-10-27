import XCTest
@testable import AmbulandoCore

/// The focused thread header menu's targets, against the web thread menu's reference and Autopilot rules.
final class ThreadMenuContextTests: XCTestCase {
    private let channel = "c1"
    private let thread = "t1"

    private func message(_ id: String, source: String? = "m0", updatedAt: String = "2026-10-27T07:00:00.000Z", session: String? = nil) -> MessageRecord {
        let raw = session.map { Data(#"{"metadata":{"source":"autopilot_session","session_id":"\#($0)"}}"#.utf8) } ?? Data("{}".utf8)
        return MessageRecord(workspaceId: "w", id: id, channelId: channel, threadId: thread, threadSourceId: source, body: "body \(id)",
                             createdAt: updatedAt, updatedAt: updatedAt, raw: raw)
    }

    private func record(source: String?) -> ThreadRecord {
        ThreadRecord(workspaceId: "w", id: thread, channelId: channel, sourceMessageId: source, title: "Title", updatedAt: "2026-10-27T07:00:00.000Z")
    }

    func testReferenceNamesTheThreadRootNotTheThreadRecordOrALaterReply() {
        let context = ThreadMenuContext(threadId: thread, channelId: channel, record: record(source: "m0"),
                                        history: [message("m0"), message("m1"), message("m2")], historyComplete: true)
        XCTAssertEqual(context.root?.id, "m0")
        XCTAssertEqual(context.flightDeckReference, "@[Chat thread](mention:chat:c1#m0)")
    }

    func testRootOutsideTheStoredWindowStillGivesTheCanonicalReference() {
        let replies = [message("m7"), message("m8")]
        let fromRecord = ThreadMenuContext(threadId: thread, channelId: channel, record: record(source: "m0"), history: replies, historyComplete: false)
        XCTAssertNil(fromRecord.root, "Copy message and Get it done need the stored root")
        XCTAssertEqual(fromRecord.flightDeckReference, "@[Chat thread](mention:chat:c1#m0)")
        let fromReplies = ThreadMenuContext(threadId: thread, channelId: channel, record: nil, history: replies, historyComplete: false)
        XCTAssertEqual(fromReplies.flightDeckReference, "@[Chat thread](mention:chat:c1#m0)", "a reply names its thread's source")
    }

    func testThreadStoredWithoutSourceUsesItsFirstMessageOnlyWhenHistoryIsComplete() {
        let rows = [message("m0", source: nil), message("m1", source: nil)]
        XCTAssertEqual(ThreadMenuContext(threadId: thread, channelId: channel, record: record(source: nil), history: rows, historyComplete: true).root?.id, "m0")
        let partial = ThreadMenuContext(threadId: thread, channelId: channel, record: record(source: nil), history: rows, historyComplete: false)
        XCTAssertNil(partial.root)
        XCTAssertNil(partial.flightDeckReference, "no reference is better than one naming a reply")
    }

    func testChannelComesFromTheThreadRecord() {
        let context = ThreadMenuContext(threadId: thread, channelId: "", record: record(source: "m0"), history: [], historyComplete: true)
        XCTAssertEqual(context.channelId, channel)
        XCTAssertEqual(context.flightDeckReference, "@[Chat thread](mention:chat:c1#m0)")
    }

    func testAutopilotLinkFollowsTheLatestSessionMessageInTheThread() {
        let first = "11111111-1111-4111-8111-111111111111", second = "22222222-2222-4222-8222-222222222222"
        let rows = [message("m0"), message("m1", updatedAt: "2026-10-27T07:05:00.000Z", session: first),
                    message("m2", updatedAt: "2026-10-27T07:09:00.000Z", session: second), message("m3", updatedAt: "2026-10-27T07:10:00.000Z")]
        let context = ThreadMenuContext(threadId: thread, channelId: channel, record: record(source: "m0"), history: rows, historyComplete: true)
        XCTAssertEqual(context.autopilotSource?.id, "m2")
        XCTAssertNil(ThreadMenuContext(threadId: thread, channelId: channel, record: nil, history: [message("m0")], historyComplete: true).autopilotSource)
    }
}
