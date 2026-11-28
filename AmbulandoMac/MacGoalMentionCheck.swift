#if DEBUG
import AppKit
import AmbulandoCore

enum MacGoalMentionFixture {
    static let slowFiles = MacRegressionMemory<Bool>()
    static let fileStatus = MacRegressionMemory<Int>()
}

extension MacThreadRegression {
    /// Isolated Test app only; exercises the real composer, outbox, renderer and File-to-goal navigation.
    static func goalMentionCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test",
              let tower = model.fixture?.tower.goals, let workspace = model.selectedWorkspace, let store = model.store else {
            throw Failure(description: "Goal mention check requires the isolated Goals fixture")
        }
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacInstantMentionCheck") {
            try await instantMentionCheck(window, model: model)
            return
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
    static func instantMentionCheck(_ window: NSWindow, model: AppModel) async throws {
        guard let fixture = model.fixture, let workspace = model.selectedWorkspace, let store = model.store else { throw Failure(description: "fixture required") }
        print("MENTION_FIXTURE_DIRECTORY \(fixture.directory.path)")
        let docId = fixture.tower.work.seedDoc(scope: FixtureTower.scopeAmbulando, channel: FixtureTower.generalChannel,
            title: "Immediate cached document", body: Data("# Cached lookup fixture".utf8), contentType: "text/markdown")
        let raw = try JSONSerialization.data(withJSONObject: ["id": docId, "workspace_id": workspace.id,
            "channel_id": FixtureTower.generalChannel, "title": "Immediate cached document", "row_version": 1,
            "created_at": "2026-11-28", "updated_at": "2026-11-28"])
        try await store.writer.upsertDocs(workspaceId: workspace.id, [try DocRecord(raw: raw)])
        model.selectContext(.home)
        model.openInChat(channelId: FixtureTower.generalChannel)
        try await waitFor(window, "chat.inbox.new", "inbox")
        try press(window, "chat.inbox.new")
        try await waitFor(window, "composer.field", "composer")
        await settle(); await settle()
        MacGoalMentionFixture.slowFiles.save(true)
        defer { MacGoalMentionFixture.slowFiles.save(false); fixture.offline = false }
        let field = try textView(window)
        let start = ContinuousClock.now
        try type(window, "@")
        try await waitFor(window, "mention.Ana Lima", "cached local actor", seconds: 5)
        print("MENTION_BASELINE delayedFiles3000ms firstLocalActor=\(start.duration(to: .now))")
        let bareAgent = find(window, "mention.rick") != nil
        print("MENTION_BASELINE bareAgentPresent=\(bareAgent)")
        field.selectAll(nil)
        let search = ContinuousClock.now
        try type(window, "@ric")
        try await waitFor(window, "mention.rick", "agent name search", seconds: 5)
        print("MENTION_BASELINE delayedFiles3000ms searchedAgent=\(search.duration(to: .now))")
        field.selectAll(nil)
        let cached = ContinuousClock.now
        try type(window, "@Immediate")
        try await waitFor(window, "mention.Immediate cached document", "cached record", seconds: 10)
        let elapsed = cached.duration(to: .now)
        print("MENTION_BASELINE delayedFiles3000ms cachedDocument=\(elapsed)")
        try require(bareAgent, "bare @ includes cached agents as well as people")
        try require(elapsed < .milliseconds(750), "cached records must publish before unrelated File network")
        try snapshot(window, model: model, name: "task45-local-mentions")
        // A newer query cancels a delayed File request; its result must never replace the typed agent.
        field.selectAll(nil); try type(window, "@Immediate")
        try await Task.sleep(for: .milliseconds(100))
        field.selectAll(nil); try type(window, "@ric")
        try await waitFor(window, "mention.rick", "newest rapid query", seconds: 2)
        try require(find(window, "mention.Immediate cached document") == nil, "cancelled query cannot remain visible")
        field.selectAll(nil)
        fixture.offline = true
        MacGoalMentionFixture.slowFiles.save(false)
        try type(window, "@ric")
        try await waitFor(window, "mention.rick", "offline local agent", seconds: 2)
        try press(window, "mention.rick"); await settle()
        try require(field.string == "@rick ", "selection retains native agent label")
        fixture.offline = false
        try press(window, "composer.send"); await settle(); await settle()
        let feed = try await store.reader.channelFeed(workspaceId: workspace.id, channelId: FixtureTower.generalChannel, limit: 100)
        let actor = Mention(type: .agent, npub: FixtureTower.rick, label: "rick")
        guard let sent = feed.first(where: { $0.message.body == actor.token })?.message else { throw Failure(description: "sent agent token missing") }
        var routed = false
        for _ in 0..<100 {
            if let accepted = try await store.reader.message(workspaceId: workspace.id, id: sent.id),
               let raw = try JSONSerialization.jsonObject(with: accepted.raw) as? [String: Any],
               raw["mentions"] as? [[String: String]] == [actor.requestObject] { routed = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(routed, "accepted readback retains structured agent npub routing")
        guard let personal = model.goalsModel(for: workspace), let combined = model.goalsModel(for: workspace, allAccessible: true),
              let sync = model.sync, let connection = model.connection else { throw Failure(description: "Goals fixture boundary") }
        await personal.refresh(); await combined.refresh()
        try require(!personal.goals.isEmpty && combined.goals.contains { $0.id == MacWorkspaceLinksFixture.sharedGoal }, "Home and combined Goals retain original channels")
        MacGoalMentionFixture.fileStatus.save(503)
        await combined.refresh()
        try require(combined.loaded && !combined.goals.isEmpty && combined.error != nil, "partial error keeps readable goals with warning")
        MacGoalMentionFixture.fileStatus.save(nil)
        await combined.refresh()
        fixture.offline = true
        let service = try sync.goals(connection, workspace)
        let reopened = GoalsModel(boundary: combined.boundary, service: service, allAccessible: true, isCurrent: { model.selectedWorkspaceBoundary == $0 })
        await reopened.refresh()
        try require(reopened.goals.contains { $0.id == MacWorkspaceLinksFixture.sharedGoal } && reopened.error != nil, "new model restores read-only combined cache offline")
        try press(window, "sidebar.goals")
        try await waitFor(window, "goal.row.Shared channel goal", "native workspace Goals row offline")
        try snapshot(window, model: model, name: "task45-workspace-goals-offline")
        try press(window, "sidebar.home")
        try await waitFor(window, "home", "native personal Home")
        try require(!personal.goals.contains { $0.id == MacWorkspaceLinksFixture.sharedGoal }, "Home snapshot remains personal")
        fixture.offline = false
        guard let other = model.workspaceEntries.first(where: { $0.workspace.id != workspace.id }) else { throw Failure(description: "second fixture workspace required") }
        model.openInChat(channelId: FixtureTower.generalChannel)
        // Navigation may restore the accepted conversation; its real reply composer is valid too.
        if find(window, "chat.inbox.new") != nil { try press(window, "chat.inbox.new") }
        try await waitFor(window, "composer.field", "composer before workspace switch")
        await settle(); await settle()
        MacGoalMentionFixture.slowFiles.save(true)
        try type(window, "@Immediate")
        try await waitFor(window, "mention.Immediate cached document", "local match before workspace switch")
        fixture.offline = true
        try await store.writer.upsertDocs(workspaceId: workspace.id, [], completeChannel: FixtureTower.generalChannel)
        try await waitGone(window, "mention.Immediate cached document", "revoked cached document suggestion")
        let currentField = try textView(window)
        currentField.selectAll(nil); try type(window, "@ric")
        try await waitFor(window, "mention.rick", "offline agent after document revocation")
        fixture.offline = false
        model.setWorkspaceEnabled(other, true)
        await model.activateWorkspace(other); await settle()
        try require(model.selectedWorkspace?.id == other.workspace.id, "workspace switch completed")
        try require(find(window, "mention.list") == nil, "old workspace suggestions cannot render after switch")
        await model.lock(); await settle()
        try require(find(window, "mention.list") == nil, "locked workspace hides mention suggestions")
        print("INSTANT_MENTIONS_PASS delayed/offline local agent, cached document, rapid cancellation, search/select/send structured routing, native Goals/Home partial/offline cache, revocation, workspace switch and lock")
    }

}
#endif
