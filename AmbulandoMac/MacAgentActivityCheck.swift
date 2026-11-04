#if DEBUG
import AppKit
import AmbulandoCore

/// Live agent activity in the real Mac window (sample data, `-AmbulandoFixtureAgentActivityStall`): Rick's public
/// commentary appears in the open conversation as the fixture stream delivers it, and when the 20 s lease (plus 15 s
/// grace) passes without renewal the card says "Stopped responding" — never finished. A draft typed meanwhile is kept,
/// and the harness heartbeat fails the run if the main actor stalls for 2 s.
extension MacThreadRegression {
    static func agentActivityCheck(_ window: NSWindow, model: AppModel) async throws {
        model.focusThread(ThreadFocus(workspaceId: FixtureTower.studio, channelId: FixtureTower.generalChannel, threadId: FixtureTower.threadReview))
        await settle()
        try await waitForText(window, "Ship it", "the reviewed conversation opens", seconds: 15)
        try type(window, "Draft kept while Rick works")
        try await waitForText(window, "Reading the conversation", "first public line arrives through the stream", seconds: 25)
        try require(containsText(window, "Working…"), "live header while the lease is current")
        try snapshot(window, model: model, name: "mac-activity-working")
        try await waitForText(window, "Comparing request ids across retries", "later lines append live", seconds: 20)
        try require(containsText(window, "Reading the conversation"), "earlier lines stay as history")
        try snapshot(window, model: model, name: "mac-activity-more-lines")
        let stalledAt = Date()
        try await waitForText(window, "Stopped responding", "expired lease clears working locally", seconds: 60)
        print("ACTIVITY_STOPPED_AFTER seconds=\(Int(Date().timeIntervalSince(stalledAt)))")
        try require(!containsText(window, "Working…"), "no working header after the deadline")
        try require(!containsText(window, "Earlier activity · completed"), "never shown as finished")
        try require(try textView(window).string == "Draft kept while Rick works", "live activity never touches the draft")
        try snapshot(window, model: model, name: "mac-activity-stopped")
    }

    static func waitForText(_ window: NSWindow, _ text: String, _ what: String, seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if containsText(window, text) { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw Failure(description: "Timed out: \(what)")
    }
}
#endif
