#if DEBUG
import AmbulandoCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Synthetic shape of a long Markdown DM, isolated from account content and production storage.
struct RichMessageLayoutFixture: View {
    static let opening = "Yes—the workspace documents, with a maintainer running research and checking sources, are the right starting point."
    static let bodyText = """
    **\(opening)** The extra pieces are evidence tracking, editorial rules and a bounded work queue.

    I would propose this for the sample project:

    | Piece | Purpose |
    | --- | --- |
    | **Start here document** | A readable introduction and linked guide to the subject |
    | **Topic documents** | Origins and dating; construction; ventilation and water; daily life; defensive use; later history |
    | **Source library** | Source notes with author, title, URL, publication and access dates, relevant passages and page numbers; preserved files where permitted |
    | **Claim register** | Records what supports each important claim, conflicting evidence and whether it is established, disputed or unknown |
    | **Research backlog** | Specific unanswered questions that drive the next research pass |
    | **Change log** | Shows what changed, why, and which sources prompted it |

    After the table, ordinary prose still wraps and remains selectable. Read [the reference](https://example.com/reference) and ask @[Ana](mention:person:\(FixtureTower.ana)) to review it.

    **Citation quality matters.** A reference must support the particular sentence beside it. The maintainer should read the underlying source, record the relevant passage, and distinguish direct evidence from interpretation.

    1. Select a bounded question from the backlog.
    2. Read sources and check for duplicates.
    3. Extract supported claims and disagreements.
    4. Update the affected pages and their citations.
    5. Check changes and report the result.

    \(String(repeating: "Each run needs a budget, saved progress and a clear stopping condition. One writer at a time should maintain the documents to avoid competing edits. ", count: 6))

    Final paragraph: the complete message remains reachable.
    """
    static let selectionBody = """
    First paragraph for selection.

    Second paragraph before table.

    | Name | Count |
    | --- | --- |
    | Alpha | 600 |
    | Beta | 450 |

    Final paragraph remains outside the partial selection.
    """
    private var selectionFixture: Bool { ProcessInfo.processInfo.arguments.contains("-AmbulandoChatSelectionFixture") }
    @State private var copied = ""
    @State private var large = false
    var body: some View {
        VStack(spacing: 0) {
            Text("Synthetic rich-message layout. No live account.").font(.caption)
            Button(large ? "Use normal text" : "Use larger text") { large.toggle() }
                .buttonStyle(.bordered).accessibilityIdentifier("rich.fixture.large")
            #if os(iOS)
            if selectionFixture {
                Button("Inspect copied selection") { copied = UIPasteboard.general.string ?? "Empty" }
                    .accessibilityIdentifier("rich.fixture.clipboard.read")
                Text(copied).font(.caption).lineLimit(1)
                    .accessibilityIdentifier("rich.fixture.clipboard.value")
            }
            #endif
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row("Before", "Previous ordinary message.")
                    row("Rick", selectionFixture ? Self.selectionBody : Self.bodyText)
                    row("After", "Following ordinary message.")
                }
            }.accessibilityIdentifier("rich.fixture.scroll")
        }
        .dynamicTypeSize(large ? .accessibility1 : .large)
        .background(Amb.background)
    }
    private func row(_ author: String, _ body: String) -> some View {
        MessageRow(message: MessageRecord(workspaceId: FixtureTower.studio, id: author, channelId: FixtureTower.designChannel,
                                         body: body, senderLabel: author, createdAt: "2026-01-01T07:01:00Z"), people: PeopleDirectory())
            .environment(\.richLayoutProbeEnabled, author == "Rick")
    }
}
#endif
