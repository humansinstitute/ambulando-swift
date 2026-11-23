#if os(macOS)
import AppKit
import WebKit
import XCTest
@testable import AmbulandoCore

@MainActor final class ArtefactHTMLWebKitTests: XCTestCase {
    func testHydratedFullDocumentsAndFragmentsUseStandardsModeInWebKit() async throws {
        _ = NSApplication.shared
        let identity = try await makeIdentity()
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: StubTransport { _ in (200, Data()) }, signer: identity))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        for source in ["<!DOCTYPE html><html><head><title>Original</title></head><body><div id='content'>Full</div></body></html>",
                       "<!--leading-->\n<!doctype html><html lang='en'><body><div id='content'>No head</div></body></html>",
                       "<div id='content'>Fragment</div>"] {
            // An unavailable asset still injects the exact production bootstrap, without any network read.
            let hydrated = try await api.hydratedArtefactHTML(source, content: ["assets": [["status": "unavailable", "name": "image"]]], workspaceId: Fixtures.workspaceId, appNpub: Fixtures.appNpub)
            let page = ArtefactHTMLDocument.insertingHeadContent("<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-inline'\">", into: hydrated)
            web.loadHTMLString(page, baseURL: nil)
            var result: [String: Any]?
            for _ in 0..<100 {
                if let value = try? await web.evaluateJavaScript("document.readyState==='complete' && !!window.wingmanAssets && !!document.getElementById('content') ? {mode:document.compatMode, text:document.getElementById('content').textContent, count:document.querySelectorAll('html').length}: null"),
                   let object = value as? [String: Any] { result = object; break }
                try await Task.sleep(for: .milliseconds(30))
            }
            let rendered = try XCTUnwrap(result)
            XCTAssertEqual(rendered["mode"] as? String, "CSS1Compat")
            XCTAssertEqual(rendered["count"] as? Int, 1)
            XCTAssertFalse((rendered["text"] as? String ?? "").isEmpty)
        }
    }
}
#endif
