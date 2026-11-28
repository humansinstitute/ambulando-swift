#if DEBUG
import AppKit
import AmbulandoCore

/// Deterministic authorized records for the isolated Test app; never used with a real account.
enum MacWorkspaceLinksFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-AmbulandoMacWorkspaceLinksCheck") }
    static let board = "f1c70000-0000-4000-8000-00000000bf01"
    static let sharedGoal = "f1c70000-0000-4000-8000-00000000bf02"
    static let version = "f1c70000-0000-4000-8000-00000000bf03"
    static let goal = try! Goal.create(name: "Shared channel goal", description: "A goal in General, outside personal Goals")
    static func row(_ id: String) -> [String: Any] {
        var row: [String: Any] = ["id": id, "workspace_id": FixtureTower.studio, "scope_id": FixtureTower.scopeAmbulando,
            "channel_id": FixtureTower.generalChannel, "display_name": id == board ? "Ambulando Scratch" : "Shared channel goal.goal.json",
            "row_version": 1, "record_state": "active", "updated_at": "2026-11-28T00:00:00Z"]
        if id == board {
            row["content_type"] = BoardScene.contentType
            row["can_write"] = true
            row["metadata"] = ["artefact": ["schema_version": 1, "format_version": 1, "type": "excalidraw", "editor_id": "builtin.excalidraw"]]
        } else {
            row["content_type"] = Goal.mime; row["metadata"] = GoalFiles.metadata
            row["current_version"] = ["id": version, "sha256_hex": SHA256Hex.of(goal.encode()), "size_bytes": goal.encode().count]
        }
        return row
    }
    static func handle(_ request: URLRequest) -> (Int, Any)? {
        guard enabled, request.httpMethod == "GET", let path = request.url?.path else { return nil }
        let base = "/api/v4/flightdeck-pg/workspaces/\(FixtureTower.studio)"
        if path == base + "/channels/\(FixtureTower.generalChannel)/files" { return (200, ["files": [row(board), row(sharedGoal)], "next_cursor": NSNull()]) }
        if path == base + "/files/\(sharedGoal)/versions/\(version)/object" { return (200, goal.encode()) }
        for id in [board, sharedGoal] where path == base + "/files/\(id)" { return (200, ["file": row(id)]) }
        return nil
    }
}

extension MacThreadRegression {
    static func workspaceLinksCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", let fixture = model.fixture,
              let workspace = model.selectedWorkspace, let store = model.store else { throw Failure(description: "isolated fixture only") }
        let f = MacWorkspaceLinksFixture.self
        fixture.tower.boards.seed(fileId: f.board, bytes: FixtureTower.sampleBoard(), canWrite: true, author: FixtureTower.ana)
        model.showWorkspaceHome(); await settle()
        try await waitFor(window, "home", "existing Home")
        try press(window, "sidebar.goals")
        try await waitFor(window, "goal.row.Shared channel goal", "shared goal outside personal channel", seconds: 25)
        try require(model.deckPath == [.workspaceGoals(workspaceId: workspace.id)], "workspace-bound Goals destination")
        try press(window, "goal.row.Shared channel goal")
        try await waitFor(window, "goal.detail", "shared goal detail")
        model.deckPath.removeLast(); await settle()
        try await waitFor(window, "goal.row.Shared channel goal", "back returns to combined list")
        try press(window, "sidebar.loops")
        try await waitFor(window, "loops.placeholder", "honest Loops placeholder")
        try require(containsText(window, "placeholder"), "Loops explicitly discloses placeholder")
        try press(window, "sidebar.home"); await settle()
        try require(model.workspaceHomeSelected, "Home restores original Home")
        guard let manager = model.manager, let connection = model.connection else { throw Failure(description: "fixture management") }
        let selfBoard = try await manager.createDirectMessage(connection, workspace, scopeId: FixtureTower.scopeDMs, participantNpub: connection.signerNpub)
        try press(window, "sidebar.reminders")
        for _ in 0..<30 {
            if model.remindersSelected { break }
            await settle()
        }
        try require(model.remindersSelected,
            "Reminders opens local assigned list; notice=\(String(describing: model.notice))")
        model.openInChat(channelId: FixtureTower.generalChannel)
        try await waitFor(window, "chat.inbox.new", "conversation inbox")
        try press(window, "chat.inbox.new")
        try await waitFor(window, "composer.field", "new conversation composer")
        await settle(); await settle()
        try press(window, "composer.mention"); try type(window, "file:Scratch")
        try await waitFor(window, "mention.Ambulando Scratch", "native File autocomplete", seconds: 25)
        try press(window, "mention.Ambulando Scratch"); await settle()
        try press(window, "composer.send"); await settle(); await settle()
        let token = Mention(type: .file, npub: f.board, label: "Ambulando Scratch").token
        let feed = try await store.reader.channelFeed(workspaceId: workspace.id, channelId: FixtureTower.generalChannel, limit: 100)
        try require(feed.contains { $0.message.body == token }, "send retains native File ID")
        let rendered = InlineText.attributed(MarkdownBlocks.inline(token)).runs.compactMap { $0.link }.compactMap(RichLinks.mentionTarget)
        try require(rendered.first?.id == f.board && rendered.first?.kind == "file", "rendered mention retains same File target")
        model.openRecord(kind: "file", id: f.board); await settle(); await settle()
        try require(model.filesPath.last == .file(workspaceId: workspace.id, fileId: f.board), "open follows same File record in workspace")
        try await waitFor(window, "board.editor", "same File opens Excalidraw editor", seconds: 25)
        let opened = try await store.reader.file(workspaceId: workspace.id, id: f.board)
        try require(opened?.id == f.board, "authorized File was read")
        print("WORKSPACE_LINKS_PASS Home, combined Goals/shared detail/back, honest Loops, existing Reminders, File autocomplete/insert/send/render/open; isolated synthetic Tower, no live MacBook claim")
    }
}
#endif
