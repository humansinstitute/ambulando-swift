import XCTest
@testable import AmbulandoCore

final class WorkspaceBoundaryTests: XCTestCase {
    func testSameKeyOnDifferentTowersAndDifferentKeysOnSameTowerRemainDistinct() throws {
        let workspace = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId, label: "Studio")))
        func boundary(_ origin: String, _ signer: String = TestKeys.npub) throws -> WorkspaceBoundary {
            try WorkspaceBoundary(connection: ConnectionRecord(origin: TowerOrigin(origin), signerNpub: signer, towerNpub: nil), workspace: workspace)
        }
        let first = try boundary("https://ONE.example:443/")
        XCTAssertEqual(first, try boundary("https://one.example"))
        XCTAssertNotEqual(first.id, try boundary("https://two.example").id)
        XCTAssertNotEqual(first.connectionNamespace, try boundary("https://one.example", "another-identity").connectionNamespace)
        XCTAssertNotEqual(WorkspaceBoundary.digest(["a:b", "c"]), WorkspaceBoundary.digest(["a", "b:c"]))
        let route = WorkspaceNavigationTarget(boundary: first, scopeId: Fixtures.scopeA, channelId: Fixtures.channel1)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceNavigationTarget.self, from: JSONEncoder().encode(route)), route)
    }

    func testEmptySelectionPersistsAndCollapseDoesNotPause() throws {
        var preferences = WorkspacePreferences()
        preferences.setEnabled("first", true)
        preferences.setEnabled("second", true)
        preferences.collapsed.insert("first")
        XCTAssertEqual(Set(preferences.enabled), ["first", "second"])
        preferences.setEnabled("first", false)
        preferences.setEnabled("second", false)
        let restored = try JSONDecoder().decode(WorkspacePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(restored.enabled.isEmpty)
        XCTAssertEqual(restored.order, ["first", "second"])
        XCTAssertTrue(restored.collapsed.contains("first"))
    }

    func testDocumentOpeningPreferenceSurvivesReopenAndIsolatesUsers() async throws {
        let directory = temporaryDirectory()
        let store = try LocalStore(directory: directory)
        try await store.writer.setState("editor.mode", "edit") // incidental old editor state
        let unset = try await DocumentOpeningMode.load(store: store, userNpub: "alice")
        XCTAssertEqual(unset, .view)
        try await DocumentOpeningMode.edit.save(store: store, userNpub: "alice")
        let reopened = try LocalStore(directory: directory)
        let alice = try await DocumentOpeningMode.load(store: reopened, userNpub: "alice")
        let bob = try await DocumentOpeningMode.load(store: reopened, userNpub: "bob")
        XCTAssertEqual(alice, .edit)
        XCTAssertEqual(bob, .view)
        try await DocumentOpeningMode.view.save(store: reopened, userNpub: "alice")
        let backToView = try await DocumentOpeningMode.load(store: store, userNpub: "alice")
        XCTAssertEqual(backToView, .view)
    }

    func testEveryContextColourHasAccessibleWhiteTextContrast() {
        func component(_ value: UInt32) -> Double {
            let s = Double(value) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        for colour in WorkspaceColour.allCases {
            let rgb = colour.rgb
            let luminance = 0.2126 * component((rgb >> 16) & 255) + 0.7152 * component((rgb >> 8) & 255) + 0.0722 * component(rgb & 255)
            XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5, colour.rawValue)
        }
    }
}
