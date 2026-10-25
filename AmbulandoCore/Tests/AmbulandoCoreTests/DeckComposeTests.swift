import XCTest
@testable import AmbulandoCore

final class DeckComposeTests: XCTestCase {
    func testAcknowledgedCreationResolvesOnlyItsOwnRequestAndWorkspace() async throws {
        let h = try await ChatHarness.make()
        let target = h.target()
        let queued = try await h.outbox.send(text: "Deck thread", mentions: [], target: target, connection: h.connection, workspace: h.workspace)
        let pending = try XCTUnwrap(queued)
        await h.engine.waitUntilIdle()
        let acknowledged = try await h.store.reader.sentMessage(workspaceId: target.workspaceId, clientRequestId: pending.id)
        let message = try XCTUnwrap(acknowledged)
        XCTAssertEqual(message.body, "Deck thread")
        XCTAssertNotNil(message.threadId)
        let other = try await h.store.reader.sentMessage(workspaceId: "other-workspace", clientRequestId: pending.id)
        XCTAssertNil(other)
        let missing = try await h.store.reader.sentMessage(workspaceId: target.workspaceId, clientRequestId: "missing")
        XCTAssertNil(missing)
    }
}
