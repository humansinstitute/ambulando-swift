#if DEBUG
import AppKit
import SwiftUI
import AmbulandoCore

/// Real thread presentation with synthetic long prose; never runs against an everyday account.
extension MacThreadRegression {
    static func richFormattingCheck(_ window: NSWindow, model: AppModel) async throws {
        TextScale.shared.reset()
        guard let readMenu = find(window, "deck.inbox.readMenu") else { throw Failure(description: "Missing Inbox read-actions menu") }
        let menuFrame = frame(of: readMenu)
        print("INBOX_MENU_FRAME width=\(menuFrame.width) height=\(menuFrame.height)")
        try require(menuFrame.width > 0 && menuFrame.width <= 56 && menuFrame.height <= 48, "Inbox read-actions menu stays compact")
        let emphasis = InlineText.attributed(MarkdownBlocks.inline("Regular **bold** regular"))
        for run in emphasis.runs {
            let text = String(emphasis[run.range].characters)
            let bold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            try require(bold == (text == "bold"), "only marked text carries bold emphasis")
            print("RICH_EMPHASIS text=\(text) bold=\(bold)")
        }
        try press(window, "deck.inbox.new"); await settle()
        try type(window, "Native reading review: paragraphs, lists and quotations"); await settle()
        try press(window, "composer.send")
        for _ in 0..<30 { if model.focusedThread != nil { break }; await settle() }
        guard let focus = model.focusedThread, let channel = focus.channelId,
              let workspace = model.selectedWorkspace, let fixture = model.fixture, let store = model.store else {
            throw Failure(description: "Missing isolated rich thread")
        }
        // Exercise the shared reaction controls through the actual Mac window and popover.
        try press(window, "reaction.quick")
        for _ in 0..<20 where find(window, "reaction.thumbs_up") == nil { await settle() }
        try require(find(window, "reaction.thumbs_up") != nil, "quick reaction renders a persisted pill")
        try press(window, "reaction.thumbs_up")
        for _ in 0..<20 where find(window, "reaction.thumbs_up") != nil { await settle() }
        try require(find(window, "reaction.thumbs_up") == nil, "tapping your pill removes the reaction")
        for emoji in ReactionEmoji.allCases {
            try press(window, "reaction.add"); await settle()
            guard let pickerWindow = NSApp.windows.first(where: { find($0, "react.\(emoji.rawValue)") != nil }) else {
                throw Failure(description: "Missing Mac reaction picker")
            }
            try press(pickerWindow, "react.\(emoji.rawValue)")
            for _ in 0..<20 where find(window, "reaction.\(emoji.rawValue)") == nil { await settle() }
            try require(find(window, "reaction.\(emoji.rawValue)") != nil, "picker reaction renders: \(emoji.rawValue)")
        }
        print("REACTION_CONTROLS_PASS addRemove=true pickerSeven=true")
        let body = RichMessageLayoutFixture.bodyText + "\n\n" + """
        ## A clearer reading rhythm

        **With those clarifications, the next steps are straightforward.** This is a synthetic review reply with the same shape as a long conversation: connected prose, numbered recommendations, quotations and a few links. The words remain selectable and the message actions stay available.

        A second paragraph should feel like a separate thought. On a wider window the text keeps a comfortable measure; in a narrower thread it wraps within the available space, including [a descriptive reference](https://example.com/reference).

        1. **Keep the activation rule explicit.**
           Start with a verified request and keep the supporting explanation with its own list item. Wrapped lines align with the text rather than the number.

           > A signed instruction addresses this worker, comes from an authorised user and has not already been executed.
           >
           > The quote has two paragraphs, with enough room to distinguish the second thought.

           This follow-up paragraph belongs to the first recommendation. It needs more room than a line break, while staying closer to its item than the next numbered recommendation.

        2. **Keep the existing session design.**
           This item contains nested decisions as well as ordinary prose.

           - A short nested point.
           - A longer nested point that wraps over several lines when the thread is narrow, so its indentation and marker alignment can be inspected beside the surrounding paragraphs.
             1. A deeper numbered point.
             2. A second deeper point with **emphasis** and `inline code`.

           The explanation continues after the nested list without losing the surrounding item's hierarchy.

        3. **Make the remaining trade-off easy to scan.**
           An extended explanation can contain bold phrases without turning the whole message into a wall of heavy text. Native text sizes, line spacing and paragraph gaps should work together as the window changes size.

        ### Quoted context and next steps

        > Keep the existing architecture and message content intact.
        >
        > > A nested quote should still have a clear edge and wrap inside its parent.

        Ask @[Ana](mention:person:\(FixtureTower.ana)) to review the result. An unbroken identifier should also wrap safely: abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789.

        98. A list can start at a larger number.
        99. Numbers share a gutter.
        100. Three-digit markers must not push their text out of alignment.

        - [x] Review paragraph and quote spacing.
        - [ ] Verify the narrow and expanded thread.

        ```swift
        let presentation = "Content stays unchanged"
        ```

        | Surface | Review |
        | --- | --- |
        | Native Mac | Readable wrapping |
        | iPhone and iPad | Compatible shared views |

        The final paragraph remains reachable by scrolling, and an unsent reply should survive resizing and reopening.
        """
        fixture.tower.postAsMember(channel: channel, body: body, threadId: focus.threadId)
        for _ in 0..<20 {
            model.openThread(focus.threadId, channelId: channel, in: workspace); await settle()
            if containsText(window, "A clearer reading rhythm") { break }
        }
        try require(containsText(window, "A clearer reading rhythm"), "rich reply renders through normal sync")
        let rows = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500)
        try require(rows.contains { $0.body == body }, "rendering preserves the original body bytes")
        try type(window, "Unsent rich reading review")
        TextScale.shared.reset()
        for (name, size, expanded) in [
            ("normal", NSSize(width: 1100, height: 850), false),
            ("narrow", NSSize(width: 900, height: 700), false),
            ("expanded", NSSize(width: 1440, height: 1000), true)
        ] {
            window.setContentSize(size); await settle()
            if expanded { try press(window, "thread.focus.expand"); await settle() }
            try require(try textView(window).string == "Unsent rich reading review", "resize keeps the draft")
            try await captureRichPages(window, model: model, name: name)
        }
        TextScale.shared.increase(); TextScale.shared.increase()
        await settle()
        try await captureRichPages(window, model: model, name: "expanded-large-text")
        TextScale.shared.reset()
        try press(window, "thread.focus.close"); await settle()
        model.focusThread(focus); await settle(); await settle()
        try require(try textView(window).string == "Unsent rich reading review", "close and reopen keep the draft")
        try await menuAction(window, title: "FD Ref")
        try require(NSPasteboard.general.string(forType: .string)?.contains("mention:chat:") == true, "message menu remains actionable")
        try await threadMenuCheck(window, model: model)
        print("RICH_FORMATTING_PASS exactBody=true normal=1100 narrow=900 expanded=1440 scale=1.3 menus=pass threadMenu=pass draft=pass")
    }

    private static func captureRichPages(_ window: NSWindow, model: AppModel, name: String) async throws {
        guard let list = threadScrollView(window), let document = list.documentView else {
            throw Failure(description: "Missing rich thread scroll view")
        }
        try require(document.bounds.width <= list.contentView.bounds.width + 1, "thread must not overflow horizontally")
        let distance = max(0, document.bounds.height - list.contentView.bounds.height)
        for (position, fraction) in [("top", 0.0), ("middle", 0.42), ("bottom", 1.0)] {
            let y = document.isFlipped ? distance * fraction : distance * (1 - fraction)
            list.contentView.scroll(to: NSPoint(x: 0, y: y)); list.reflectScrolledClipView(list.contentView)
            await settle()
            if !ProcessInfo.processInfo.arguments.contains("-AmbulandoMacRichNoSnapshots") {
                let captureStart = ContinuousClock.now
                try snapshot(window, model: model, name: "rich-\(name)-\(position)")
                print("RICH_CAPTURE \(name)-\(position) wall=\(captureStart.duration(to: .now))"); fflush(stdout)
            }
        }
        print("RICH_GEOMETRY \(name) document=\(document.bounds) viewport=\(list.contentView.bounds)")
    }
}
#endif
