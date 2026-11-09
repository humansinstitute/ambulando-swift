import XCTest
@testable import AmbulandoCore

final class ChatSelectionTests: XCTestCase {
    static let message = """
    ## Selection example

    First **bold** paragraph with emoji 🪴 and [reference](https://example.com/ref?a=1&b=2).

    Second paragraph before the table.

    | Contributor | Quantity | Date |
    | --- | --- | --- |
    | Batch A | **600** | 30 June |
    | Catch-up B | 450 | 31 July |
    | Total | 1,050 | Mixed |

    After table paragraph with @[Ana](mention:person:abc).

    > Quoted paragraph.
    >
    > Another quoted paragraph.

    1. First list item
    2. Second list item

    ```swift
    let value = "<hello>"
    print(value)
    ```

    Final paragraph remains reachable.
    """
    func testSemanticMessageAndExportFixture() throws {
        let html = ChatSelectionHTML.blocks(MarkdownBlocks.parse(Self.message))
        XCTAssertTrue(html.contains("<h2>Selection example</h2>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<th scope=col>Contributor</th>"))
        XCTAssertTrue(html.contains("<td><strong>600</strong></td>"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<ol start=\"1\">"))
        XCTAssertTrue(html.contains("<pre><code>let value = &quot;&lt;hello&gt;&quot;"))
        XCTAssertTrue(html.contains("ambulando-mention://open?kind=person&amp;id=abc"))
        XCTAssertTrue(html.contains("https://example.com/ref?a=1&amp;b=2"))
        if let path = ProcessInfo.processInfo.environment["CHAT_SELECTION_FIXTURE"] {
            try html.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    func testUntrustedTextAndUnsafeLinksCannotBecomeActiveContent() {
        var run = InlineRun(text: "<script>alert('x')</script>\" & text")
        run.link = "javascript:alert(1)"
        let html = ChatSelectionHTML.runs([run])
        XCTAssertFalse(html.contains("<script>")); XCTAssertFalse(html.contains("href="))
        XCTAssertTrue(html.contains("&lt;script&gt;")); XCTAssertTrue(html.contains("&quot; &amp;"))
        run.link = "data:text/html,evil"
        XCTAssertFalse(ChatSelectionHTML.runs([run]).contains("href="))
        run.link = "/canvas.html?workspace=w&id=c"
        XCTAssertTrue(ChatSelectionHTML.runs([run]).contains("href=\"/canvas.html?workspace=w&amp;id=c\""))
    }
    func testImagesNeverFetchRemoteContentAndStoredImagesKeepIdentity() {
        let id = "f1c70000-0000-4000-8000-0000000000a1"
        let html = ChatSelectionHTML.blocks([.image(alt: "A \"picture\"", source: "storage://" + id), .image(alt: "Remote", source: "https://example.com/tracking.png")])
        XCTAssertTrue(html.contains("data-object=\"\(id)\""))
        XCTAssertTrue(html.contains("alt=\"A &quot;picture&quot;\""))
        XCTAssertFalse(html.contains("src=\"https:"))
        XCTAssertTrue(html.contains("web image (not loaded)"))
    }
}
