import Foundation
import XCTest
@testable import AmbulandoCore

/// A composer adopts a stored draft after its own send only if the draft was written after the send (an Edit restore),
/// never a copy read before the send. That needs draft timestamps finer than a second.
final class DraftTimestampTests: XCTestCase {
    func testRestoredDraftIsWrittenAfterTheSendThatClearedIt() async throws {
        let h = try await ChatHarness.make()
        let target = h.target()
        try await h.store.writer.saveDraft(target, Draft(text: "before send", mentions: []))
        let saved = try await h.store.reader.draft(target)
        let savedAt = try XCTUnwrapValue(saved?.updatedAt)
        let sentAt = Date()
        let item = try await h.store.writer.enqueueSend(target: target, origin: h.connection.origin, signerNpub: TestKeys.npub,
                                                        appNpub: Fixtures.appNpub, body: "before send", mentions: [])
        let cleared = try await h.store.reader.draft(target)
        XCTAssertNil(cleared, "sending clears the draft in the same transaction")
        XCTAssertLessThanOrEqual(savedAt, sentAt, "the pre-send draft is not newer than the send")
        try await Task.sleep(for: .milliseconds(5))
        try await h.store.writer.discardOutbox(id: item.id, restoreDraft: true)
        let restored = try await h.store.reader.draft(target)
        XCTAssertEqual(restored?.text, "before send")
        XCTAssertGreaterThan(try XCTUnwrapValue(restored?.updatedAt), sentAt, "an Edit restore is newer than the send")
    }
}
