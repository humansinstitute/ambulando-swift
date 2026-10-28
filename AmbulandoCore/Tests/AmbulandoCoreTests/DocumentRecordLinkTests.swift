import XCTest
@testable import AmbulandoCore

final class DocumentRecordLinkTests: XCTestCase {
    func testCanvasURLKeepsIdentityAndWorkspace() {
        let w = "11111111-1111-4111-8111-111111111111", c = "22222222-2222-4222-8222-222222222222"
        XCTAssertEqual(DocumentRecordLink.canvas(URL(string: "/canvas.html?workspaceid=\(w)&canvasid=\(c)")!, workspaceId: w), c)
        XCTAssertNil(DocumentRecordLink.canvas(URL(string: "https://example.test/canvas.html?workspaceid=\(w)&canvasid=\(c)")!, workspaceId: w))
        XCTAssertNil(DocumentRecordLink.canvas(URL(string: "//example.test/canvas.html?workspaceid=\(w)&canvasid=\(c)")!, workspaceId: w))
        XCTAssertNil(DocumentRecordLink.canvas(URL(string: "/canvas.html?workspaceid=other&canvasid=\(c)")!, workspaceId: w))
        XCTAssertNil(DocumentRecordLink.canvas(URL(string: "/canvas.html?workspaceid=\(w)&canvasid=missing")!, workspaceId: w))
        XCTAssertNil(DocumentRecordLink.canvas(URL(string: "/canvas.html?workspaceid=\(w)&canvasid=\(c)&canvasid=\(c)")!, workspaceId: w))
        XCTAssertNil(DocumentRecordLink.canvas(URL(string: "javascript:/canvas.html?workspaceid=\(w)&canvasid=\(c)")!, workspaceId: w))
    }
}
