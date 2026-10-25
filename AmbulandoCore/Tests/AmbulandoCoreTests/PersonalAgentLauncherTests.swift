import Foundation
import XCTest
@testable import AmbulandoCore

final class PersonalAgentLauncherTests: XCTestCase {
    func testActorSettingsOrderDeduplicationAndLaunchPolicy() throws {
        let data = try JSONSerialization.data(withJSONObject: ["settings": ["autopilot_agents": [
            ["agent_npub": TestKeys.npub, "url": "https://browser.sample.invalid/agent"],
            ["agent_npub": TestKeys.npub, "url": "https://duplicate.invalid"],
            ["agent_npub": "invalid", "url": "https://invalid.invalid"]
        ]]])
        let rows = try PersonalAgentLauncher.decode(data)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.safeURL?.host, "browser.sample.invalid")
        let unsafe = try JSONSerialization.data(withJSONObject: ["settings": ["autopilot_agents": [["agent_npub": TestKeys.npub, "url": "http://insecure.invalid"]]]])
        XCTAssertNil(try PersonalAgentLauncher.decode(unsafe).first?.safeURL)
        XCTAssertThrowsError(try PersonalAgentLauncher.decode(Data("{}".utf8)))
        XCTAssertNotEqual(WorkspaceSync.personalAgentsKey("first", "workspace"), WorkspaceSync.personalAgentsKey("second", "workspace"))
    }
}
