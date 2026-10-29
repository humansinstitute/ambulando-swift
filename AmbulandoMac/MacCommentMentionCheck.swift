#if DEBUG
import AppKit
import AmbulandoCore

extension MacThreadRegression {
    /// Runs only in the isolated Test app. Local stand-in Tower; no real accounts or agent dispatch.
    static func commentMentionCheck(_ window: NSWindow, model: AppModel) async throws {
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacDocumentWorkflowCheck") {
            try await documentWorkflowCheck(window, model: model); return
        }
        guard let fixture = model.fixture, let store = model.store, let workspace = model.selectedWorkspace else {
            throw Failure(description: "Missing sample environment")
        }
        model.selectContext(.home)
        try press(window, "section.tasks"); await settle()
        try await waitFor(window, "task.Write release notes for build 3", "sample task")
        try press(window, "task.Write release notes for build 3"); await settle()
        let field = try textView(window)
        try type(window, "Before @ric after ![photo](storage://sample)")
        field.setSelectedRange(NSRange(location: ("Before @ric" as NSString).length, length: 0))
        await settle()
        try require(find(window, "mention.rick") != nil, "@ric in the actual task comment opens the actor picker")
        try snapshot(window, model: model, name: "mac-task-comment-picker")
        try click(window, "mention.rick"); await settle()
        let actor = Mention(type: .agent, npub: FixtureTower.rick, label: "rick")
        try require(field.string == "Before \(actor.token)  after ![photo](storage://sample)", "full comment suffix and attachment retained")
        try require(field.selectedRange().location == ("Before \(actor.token) " as NSString).length, "caret is after picked tag and before suffix")
        try type(window, "inserted")
        await settle()
        let sent = field.string
        try require(sent == "Before \(actor.token) inserted after ![photo](storage://sample)", "typing continues at the original caret")
        try require(find(window, "mention.list") == nil, "completed token does not reopen picker")
        try press(window, "comment.send"); await settle(); await settle()
        let taskRows = try await store.reader.tasks(workspaceId: workspace.id)
        let task = try requiredId(taskRows.first { $0.title == "Write release notes for build 3" }?.id)
        let accepted = fixture.tower.work.taskComments(task)
        try checkComment(accepted.first { $0["body"] as? String == sent }, body: sent, actor: actor)
        guard let renderedTag = wikiLinks(in: window).first(where: { linkLabel($0).contains("rick") }) else {
            throw Failure(description: "Accepted task comment has no clickable actor tag")
        }
        try await performPress(renderedTag) { find(window.attachedSheet ?? window, "mention.identity.npub") != nil }
        let sheet = window.attachedSheet ?? window
        try require(find(sheet, "mention.identity.npub") != nil, "rendered actor tag opens its identity details")
        try press(sheet, "mention.identity.done"); await settle()
        try type(window, "Reopen draft @ric"); await settle()
        try press(window, "mention.rick"); await settle()
        let draft = try textView(window).string
        try press(window, "section.docs"); await settle()
        try press(window, "section.tasks"); await settle()
        try require(try textView(window).string == draft, "task draft tag survives switching away and reopening")
        try press(window, "section.docs"); await settle()
        try await waitFor(window, "doc.Native app plan", "sample doc")
        try press(window, "doc.Native app plan"); await settle()
        try type(window, "Doc @ric"); await settle()
        let docField = try textView(window)
        try require(find(window, "mention.rick") != nil, "doc comment opens same picker")
        // The real NSTextView delegate handles hardware Return/Tab while the picker is open.
        let used = docField.delegate?.textView?(docField, doCommandBy: #selector(NSResponder.insertTab(_:))) ?? false
        try require(used, "Tab selects highlighted mention rather than moving focus")
        await settle()
        let rootBody = docField.string
        try require(rootBody == "Doc \(actor.token) ", "doc keyboard pick uses same canonical identity")
        try press(window, "doccomment.send"); await settle(); await settle()
        let docs = try await store.reader.docs(workspaceId: workspace.id)
        let doc = try requiredId(docs.first { $0.title == "Native app plan" }?.id)
        let parent = fixture.tower.work.docComments(doc).first { $0["body"] as? String == rootBody.trimmingCharacters(in: .whitespacesAndNewlines) }
        try checkComment(parent, body: rootBody.trimmingCharacters(in: .whitespacesAndNewlines), actor: actor)
        let parentId = try requiredId(parent?["id"] as? String)
        try press(window, "doccomment.reply.\(parentId)"); await settle()
        try type(window, "Reply @ric"); await settle()
        try press(window, "mention.rick"); await settle()
        let replyBody = try textView(window).string.trimmingCharacters(in: .whitespacesAndNewlines)
        try press(window, "doccomment.send"); await settle(); await settle()
        let reply = fixture.tower.work.docComments(doc).first { $0["parent_comment_id"] as? String == parentId }
        try checkComment(reply, body: replyBody, actor: actor)
        try snapshot(window, model: model, name: "mac-doc-comment-reply")
        print("COMMENT_MENTIONS_PASS synthetic task/doc/reply body+structured npub, mouse+Tab, caret/suffix, draft reopen; no live agent routing exercised")
    }

    private static func requiredId(_ value: String?) throws -> String {
        guard let value else { throw Failure(description: "Missing sample record") }; return value
    }

    private static func checkComment(_ row: [String: Any]?, body: String, actor: Mention) throws {
        try require(row?["body"] as? String == body, "accepted comment preserves complete body")
        try require((row?["metadata"] as? [String: Any])?["mentions"] as? [[String: String]] == [actor.requestObject],
                    "accepted comment keeps exact selected npub and actor type")
    }
}
#endif
