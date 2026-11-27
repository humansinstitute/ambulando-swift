#if DEBUG
import AppKit
import AmbulandoCore

extension MacThreadRegression {
    /// Isolated Test app only; exercises the real composer, outbox, renderer and File-to-goal navigation.
    static func goalMentionCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test",
              let tower = model.fixture?.tower.goals, let workspace = model.selectedWorkspace, let store = model.store else {
            throw Failure(description: "Goal mention check requires the isolated Goals fixture")
        }
        for index in 0..<22 { tower.seed(try Goal.create(name: "Browse goal \(index)", description: "Fixture")) }
        let title = "Training sign up onboarding to Ambulando"
        let fileId = tower.seed(try Goal.create(name: title, description: "Fixture goal mention"))
        model.selectContext(.home)
        model.openInChat(channelId: FixtureTower.generalChannel)
        try await waitFor(window, "chat.inbox.new", "conversation inbox")
        try press(window, "chat.inbox.new")
        try await waitFor(window, "composer.field", "general channel composer")
        // The field appears before its asynchronous draft model is attached.
        await settle(); await settle()
        try press(window, "composer.mention")
        try type(window, "GoAl:")
        try await waitFor(window, "mention.\(title)", "goal beyond the ten-row default limit")
        try require(find(window, "mention.Browse goal 21") != nil, "all personal goals remain in the browse list")
        let field = try textView(window)
        field.selectAll(nil)
        try type(window, "@tRaInInG sign up onboarding to Ambulando")
        try await waitFor(window, "mention.\(title)", "multiword case-insensitive title lookup")
        try press(window, "mention.\(title)"); await settle()
        try require(field.string == "@\(title) ", "picked goal inserts its real title")
        try press(window, "composer.send"); await settle(); await settle()
        let rows = try await store.reader.channelFeed(workspaceId: workspace.id, channelId: FixtureTower.generalChannel, limit: 100)
        let token = Mention(type: .file, npub: fileId, label: title).token
        try require(rows.contains { $0.message.body == token }, "accepted message retains canonical goal File identity")
        // Chat groups each message into one accessibility element, so individual links are not
        // exposed to AX. Follow the same rendered-target/handler boundary as chatLinkCheck.
        let attributed = InlineText.attributed(MarkdownBlocks.inline(token))
        let targets = attributed.runs.compactMap { $0.link }.compactMap(RichLinks.mentionTarget)
        try require(targets.count == 1 && targets[0].kind == "file" && targets[0].id == fileId,
                    "rendered goal name carries the exact File route")
        try require(containsText(window, title), "accepted goal title renders in the conversation")
        model.openRecord(kind: targets[0].kind, id: targets[0].id)
        try await waitFor(window, "goal.detail", "authorized File reference opens goal detail")
        print("GOAL_MENTIONS_PASS browse beyond 10, case/spaces, insert/send canonical File token, rendered target and open handler; synthetic local Tower, no pointer activation claim")
    }
}
#endif
