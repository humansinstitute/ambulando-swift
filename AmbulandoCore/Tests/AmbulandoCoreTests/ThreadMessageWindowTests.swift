import XCTest
@testable import AmbulandoCore

final class ThreadMessageWindowTests: XCTestCase {
    private func history(_ count: Int) -> [MessageRecord] {
        (0..<count).map { MessageRecord(workspaceId: "w", id: String($0), channelId: "c", threadId: "t", body: "row \($0)", createdAt: String($0)) }
    }
    func testLatestAndFullHistoryPaginationStayBounded() {
        let rows = history(500)
        var page = ThreadMessageWindow(rows)
        XCTAssertEqual(page.messages.map(\.id), Array(rows.suffix(50)).map(\.id))
        var seen = Set(page.messages.map(\.id))
        while page.hasEarlier {
            page = ThreadMessageWindow(rows, anchor: rows[max(0, page.start - 50)].id)
            XCTAssertLessThanOrEqual(page.messages.count, 50)
            seen.formUnion(page.messages.map(\.id))
        }
        XCTAssertEqual(seen.count, 500)
        XCTAssertTrue(page.hasNewer)
    }
    func testSavedPositionAndNewRepliesDoNotShiftAnOlderPage() {
        let rows = history(500)
        let page = ThreadMessageWindow(rows, anchor: "123")
        XCTAssertEqual(page.messages.first?.id, "123")
        XCTAssertEqual(ThreadMessageWindow(history(510), anchor: "123").messages, page.messages)
    }
    func testDeletedAnchorKeepsNearestSurvivorAndUpdatedBodies() {
        var rows = history(500)
        let previous = ThreadMessageWindow(rows, anchor: "123")
        rows.removeAll { $0.id == "123" }
        let next = ThreadMessageWindow(rows, anchor: "123", fallback: previous.messages.map(\.id), fallbackStart: previous.start)
        XCTAssertEqual(next.messages.first?.id, "124")
        XCTAssertLessThanOrEqual(next.messages.count, 50)
        XCTAssertEqual(ThreadMessageWindow([], anchor: "gone").messages.count, 0)
    }
    func testPageTransitionThenCapacityEvictionUsesSelectedHistorySuccessor() {
        let rows = history(500)
        let previous = ThreadMessageWindow(rows, anchor: "50")
        let selected = rows[0].id
        let selectedStart = previous.order.firstIndex(of: selected)!
        let fallback = Array(previous.order.dropFirst(selectedStart))
        let rolled = Array(history(501).dropFirst())
        let page = ThreadMessageWindow(rolled, anchor: selected, fallback: fallback, fallbackStart: selectedStart)
        XCTAssertEqual(page.messages.first?.id, "1")
        XCTAssertEqual(page.messages.count, 50)
        XCTAssertTrue(page.hasNewer)
    }

}
