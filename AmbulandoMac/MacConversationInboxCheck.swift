#if DEBUG
import AmbulandoCore
import AppKit
import SwiftUI

extension MacThreadRegression {
    static func conversationInboxCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", let fixture = model.fixture,
              let store = model.store, let workspace = model.selectedWorkspace, let connection = model.connection else {
            throw Failure(description: "Inbox check requires isolated fixture app")
        }
        UserDefaults.standard.removeObject(forKey: AppMode.chatPreference)
        model.focusedThread = nil
        model.mode = .chat
        model.selectContext(.home)
        await settle()
        try require(find(window, "section.chat") != nil, "Chat visible when no saved preference exists")
        try await waitFor(window, "chat.inbox.search", "conversation search")
        try require(find(window, "chat.inbox.download") == nil, "Download history banner removed")
        try require(!containsText(window, "Search covers") && !containsText(window, "Download history"), "cached-messages banner removed")
        try require(find(window, "chat.inbox.new") != nil, "floating New thread button present")
        fixture.tower.postAsMember(channel: FixtureTower.generalChannel, body: "Deployment checklist inbox regression")
        model.openChannel(FixtureTower.generalChannel, in: workspace, force: true)
        var root: MessageRecord?
        for _ in 0..<100 {
            root = try await store.reader.latestMessages(workspaceId: workspace.id, channelId: FixtureTower.generalChannel, limit: 200).first { $0.body == "Deployment checklist inbox regression" }
            if root != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let root, let thread = root.threadId else { throw Failure(description: "Seeded conversation missing") }
        fixture.tower.postAsMember(channel: root.channelId, body: "Exact older search needle", threadId: thread)
        model.openChannel(root.channelId, in: workspace, force: true)
        await settle(); await settle()
        let hit = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: thread, limit: 20).first { $0.body == "Exact older search needle" }
        guard let hit else { throw Failure(description: "Older hit missing") }
        let richStress = ProcessInfo.processInfo.arguments.contains("-AmbulandoMacConversationRichStress")
        if richStress {
        fixture.tower.postAsMember(channel: root.channelId, body: "Later message with Markdown\n\n| Chat | Markdown |\n| --- | --- |\n| Docs | Images |\n\n> Notes from the app\n\n```swift\nlet ready = true\n```", threadId: thread, count: 80)
        } else {
            fixture.tower.postAsMember(channel: root.channelId, body: "Later plain reply", threadId: thread, count: 80)
            fixture.tower.postAsMember(channel: root.channelId, body: "Markdown presentation\n\n| Chat | Markdown |\n| --- | --- |\n| Docs | Images |\n\n> Notes from the app\n\n```swift\nlet ready = true\n```", threadId: thread)
        }
        model.openChannel(root.channelId, in: workspace, force: true)
        for _ in 0..<100 {
            if try await store.reader.threadMessageIds(workspaceId: workspace.id, threadId: thread).count >= 82 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await settle()
        try await waitFor(window, "chat.conversation.\(thread)", "compact conversation row")
        try snapshot(window, model: model, name: "conversation-inbox-wide")
        // Use native field editing, so the query must travel through SwiftUI's actual binding.
        try click(window, "chat.inbox.search")
        guard let editor = window.firstResponder as? NSTextView else { throw Failure(description: "Search field has no native editor") }
        editor.selectAll(nil)
        editor.insertText("title:”deployment checklist” body:needle", replacementRange: editor.selectedRange())
        await settle(); await settle()
        try await waitFor(window, "chat.conversation.\(thread)", "combined title/body search result")
        try snapshot(window, model: model, name: "conversation-search")
        try press(window, "chat.conversation.\(thread)")
        try await waitFor(window, "chat.thread.back", "selected thread")
        await settle(); await settle()
        try require(!containsText(window, "Conversations"), "Conversations pill button removed from thread header")
        print("INBOX_STEP thread ready, checking old hit"); fflush(stdout)
        try require(containsText(window, "Exact older search needle"), "body hit opens older page outside newest 50")
        try type(window, "Unsent inbox search reply @Ana")
        await settle()
        try snapshot(window, model: model, name: "conversation-old-hit")
        let target = ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: root.channelId, threadId: thread)
        let draft = try await store.reader.draft(target)
        try require(draft?.text.contains("Unsent inbox search reply") == true, "reply draft persisted through anchored navigation")
        try click(window, "chat.thread.back"); await settle()
        try require(find(window, "chat.inbox.search") != nil, "close returns to inbox")
        try require(containsText(window, "Deployment checklist inbox regression"), "search result remains on return")
        window.setContentSize(NSSize(width: 900, height: 650)); await settle()
        try snapshot(window, model: model, name: "conversation-inbox-narrow")
        try press(window, "chat.conversation.\(thread)"); await settle(); await settle()
        try require(try textView(window).string.contains("Unsent inbox search reply"), "draft survives back and reopen")
        try snapshot(window, model: model, name: "conversation-thread-narrow")
        try press(window, "thread.newer"); await settle(); await settle()
        try require(containsText(window, richStress ? "Later message with Markdown" : "Markdown presentation"), "newer page renders mixed Markdown content")
        try snapshot(window, model: model, name: "conversation-markdown-latest")
        try click(window, "chat.thread.back"); await settle()
        try press(window, "chat.inbox.new"); await settle()
        try await waitFor(window, "deck.compose.option.\(root.channelId)", "destination chooser in Home")
        try press(window, "deck.compose.option.\(root.channelId)"); await settle()
        try type(window, "Created from Chat inbox with signed send")
        await settle()
        try press(window, "composer.send")
        try await waitFor(window, "chat.thread.back", "new conversation returned inline", seconds: 20)
        await settle()
        try require(model.focusedThread == nil, "Chat-origin send opens inline while Deck route remains independent")
        try require(containsText(window, "Created from Chat inbox with signed send"), "accepted signed message rendered inline")
        try snapshot(window, model: model, name: "conversation-created-inline")
        print("PASS conversation inbox: default visibility, actual query binding, title/body phrase search, older hit page, reply draft, back, narrow/wide UI, destination chooser and signed creation returned inline")
    }
}
#endif
