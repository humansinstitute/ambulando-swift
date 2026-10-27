import XCTest
@testable import AmbulandoCore

/// Deck's New thread composer preselects only an unambiguous channel and keeps a choice within the same scope.
final class DeckComposeChannelTests: XCTestCase {
    private let scopeA = WorkContext(scopeId: "scope-a")
    private let scopeB = WorkContext(scopeId: "scope-b")

    func testChannelContextPreselectsItsChannel() {
        let context = WorkContext(scopeId: "scope-a", channelId: "c2")
        XCTAssertEqual(DeckCompose.initialChannel(context: context, eligible: ["c2"]), "c2")
    }

    func testChannelNoLongerEligibleIsNotPreselected() {
        let context = WorkContext(scopeId: "scope-a", channelId: "gone")
        XCTAssertNil(DeckCompose.initialChannel(context: context, eligible: ["c1", "c2"]))
        XCTAssertEqual(DeckCompose.initialChannel(context: context, eligible: ["c1"]), "c1")
    }

    func testScopeWithSeveralChannelsAsks() {
        XCTAssertNil(DeckCompose.initialChannel(context: scopeA, eligible: ["c1", "c2"]))
        XCTAssertNil(DeckCompose.initialChannel(context: .home, eligible: ["c1", "c2", "c3"]))
    }

    func testSoleEligibleChannelIsPreselected() {
        XCTAssertEqual(DeckCompose.initialChannel(context: scopeA, eligible: ["c1"]), "c1")
        XCTAssertNil(DeckCompose.initialChannel(context: scopeA, eligible: []))
    }

    func testChoiceIsKeptWithinTheSameScope() {
        XCTAssertEqual(DeckCompose.reconcile(chosen: "c2", from: scopeA, to: scopeA, eligible: ["c1", "c2"]), "c2")
    }

    func testChoiceThatLeftTheListIsResolvedAgain() {
        XCTAssertNil(DeckCompose.reconcile(chosen: "c2", from: scopeA, to: scopeA, eligible: ["c1", "c3"]))
        XCTAssertEqual(DeckCompose.reconcile(chosen: "c2", from: scopeA, to: scopeA, eligible: ["c1"]), "c1")
    }

    func testScopeChangeStartsTheChoiceAgain() {
        // Home lists every channel, so the old choice is still eligible, but the scope changed.
        XCTAssertNil(DeckCompose.reconcile(chosen: "c1", from: scopeA, to: .home, eligible: ["c1", "c9"]))
        XCTAssertEqual(DeckCompose.reconcile(chosen: "c1", from: scopeA, to: scopeB, eligible: ["c9"]), "c9")
    }

    func testNarrowingToAChannelOfTheSameScopeFollowsIt() {
        let narrowed = WorkContext(scopeId: "scope-a", channelId: "c1")
        XCTAssertEqual(DeckCompose.reconcile(chosen: "c2", from: scopeA, to: narrowed, eligible: ["c1"]), "c1")
    }
}
