#if DEBUG
import AppKit
import AmbulandoCore
import Foundation

extension MacThreadRegression {
    /// Exercises the real Mac model/window against Test-only local fixtures. No remote Tower or user credentials.
    static func multiWorkspaceCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".test") == true,
              let fixture = model.fixture,
              let output = ProcessInfo.processInfo.environment["AMBULANDO_MAC_MULTI_WORKSPACE_REPORT"],
              output.hasPrefix(FileManager.default.currentDirectoryPath + "/tmp/docs/handoffs/") else {
            throw Failure(description: "Multi-workspace check requires the separate Test app and an ignored handoff report path")
        }
        let started = ContinuousClock.now
        var checks: [String] = []
        try await multiWait("both available fixture workspaces") { model.workspaceEntries.count >= 2 }
        guard let studio = model.workspaceEntries.first(where: { $0.workspace.label == "Studio (sample)" }),
              let lab = model.workspaceEntries.first(where: { $0.workspace.label == "Lab (sample)" }) else {
            throw Failure(description: "Missing Studio and Lab sample entries")
        }
        model.sceneDidBecomeActive()
        model.setWorkspaceEnabled(studio, true)
        model.setWorkspaceEnabled(lab, true)
        try await multiWait("both workspace navigation snapshots") {
            studio.enabled && lab.enabled && studio.navigation.loaded && lab.navigation.loaded
                && !studio.navigation.groups.isEmpty && !lab.navigation.groups.isEmpty
                && studio.runtime?.validated == true && lab.runtime?.validated == true
        }
        guard let studioRuntime = studio.runtime, let labRuntime = lab.runtime,
              let studioChannel = studio.navigation.groups.flatMap(\.channels).first,
              let labChannel = lab.navigation.groups.flatMap(\.channels).first else {
            throw Failure(description: "Missing isolated runtimes and channels")
        }
        try require(studioRuntime.store.path != labRuntime.store.path, "workspace stores use distinct boundaries")
        checks.append("both enabled workspaces materialize independent navigation")
        try await multiWait("both foreground streams") {
            let first = await studioRuntime.stream.isRunning
            let second = await labRuntime.stream.isRunning
            return first && second
        }
        checks.append("both foreground fixture event streams remain live")
        let studioTarget = ChatTarget(connectionId: studio.connection.id, workspaceId: studio.workspace.id, channelId: studioChannel.id)
        let labTarget = ChatTarget(connectionId: lab.connection.id, workspaceId: lab.workspace.id, channelId: labChannel.id)
        try await studioRuntime.store.writer.saveDraft(studioTarget, Draft(text: "Studio retained sample draft", mentions: []))
        try await labRuntime.store.writer.saveDraft(labTarget, Draft(text: "Lab retained sample draft", mentions: []))
        model.openWorkspace(lab, context: WorkContext(scopeId: labChannel.scopeId, channelId: labChannel.id))
        try await multiWait("Lab exact context") { model.selectedWorkspaceBoundary == lab.boundary && model.context.channelId == labChannel.id }
        try require(studio.enabled && studioRuntime.activity.isEnabled, "viewing Lab does not pause Studio")
        let firstStream = await studioRuntime.stream.isRunning
        try require(firstStream, "offscreen Studio stream stays live")
        model.openWorkspace(studio, context: WorkContext(scopeId: studioChannel.scopeId, channelId: studioChannel.id))
        try await multiWait("Studio exact context") { model.selectedWorkspaceBoundary == studio.boundary && model.context.channelId == studioChannel.id }
        let studioDraft = try await studioRuntime.store.reader.draft(studioTarget)
        let labDraft = try await labRuntime.store.reader.draft(labTarget)
        try require(studioDraft?.text == "Studio retained sample draft" && labDraft?.text == "Lab retained sample draft", "switching preserves both captured drafts")
        checks.append("exact workspace routing preserves both drafts and offscreen live sync")
        // Deliberately overlap restores: no intermediate wait allows a stale A/B continuation to overwrite the final A.
        let studioContext = WorkContext(scopeId: studioChannel.scopeId, channelId: studioChannel.id)
        let labContext = WorkContext(scopeId: labChannel.scopeId, channelId: labChannel.id)
        model.openWorkspace(studio, context: studioContext)
        model.openWorkspace(lab, context: labContext)
        model.openWorkspace(studio, context: studioContext)
        await settle(); await settle()
        try require(model.selectedWorkspaceBoundary == studio.boundary && model.context == studioContext,
                    "rapid A→B→A switching preserves the final exact account/workspace/channel")
        checks.append("rapid A→B→A navigation rejects stale restore callbacks")
        let studioUpdate = "Studio concurrent fixture update " + UUID().uuidString
        let labUpdate = "Lab concurrent fixture update " + UUID().uuidString
        fixture.tower.postAsMember(channel: studioChannel.id, body: studioUpdate, workspaceId: studio.workspace.id)
        fixture.tower.postAsMember(channel: labChannel.id, body: labUpdate, workspaceId: lab.workspace.id)
        let updateStarted = ContinuousClock.now
        try await multiWait("both streamed fixture messages while Studio is viewed") {
            let first = try? await studioRuntime.store.reader.latestMessages(workspaceId: studio.workspace.id, channelId: studioChannel.id, limit: 30)
            let second = try? await labRuntime.store.reader.latestMessages(workspaceId: lab.workspace.id, channelId: labChannel.id, limit: 30)
            return first?.contains(where: { $0.body == studioUpdate }) == true && second?.contains(where: { $0.body == labUpdate }) == true
        }
        let updateLatency = updateStarted.duration(to: .now)
        try require(model.selectedWorkspaceBoundary == studio.boundary, "updates do not move the viewed workspace")
        checks.append("both workspace stores receive new event-driven messages while only Studio is viewed")
        model.toggleWorkspaceCollapsed(lab)
        await settle()
        try require(lab.collapsed && lab.enabled && labRuntime.activity.isEnabled, "collapse is visual")
        try require(find(window, "workspace.home.Studio (sample)") != nil, "native stacked navigation renders Studio Home")
        checks.append("native stacked navigation and visual collapse retain enabled lifecycle")
        model.toggleWorkspaceCollapsed(lab)
        model.setWorkspaceEnabled(lab, false)
        try await multiWait("Lab paused independently") {
            let stopped = !(await labRuntime.stream.isRunning)
            return stopped && !labRuntime.activity.isEnabled && studioRuntime.activity.isEnabled
        }
        try require((try await labRuntime.store.reader.draft(labTarget))?.text == "Lab retained sample draft", "pause preserves cached Lab draft")
        checks.append("pausing Lab stops only its stream and preserves its draft")
        let pausedUpdate = "Lab paused fixture update " + UUID().uuidString
        let continuingUpdate = "Studio still live fixture update " + UUID().uuidString
        fixture.tower.postAsMember(channel: labChannel.id, body: pausedUpdate, workspaceId: lab.workspace.id)
        fixture.tower.postAsMember(channel: studioChannel.id, body: continuingUpdate, workspaceId: studio.workspace.id)
        try await multiWait("Studio receives updates while Lab is paused") {
            let rows = try? await studioRuntime.store.reader.latestMessages(workspaceId: studio.workspace.id, channelId: studioChannel.id, limit: 30)
            return rows?.contains(where: { $0.body == continuingUpdate }) == true
        }
        let pausedRows = try await labRuntime.store.reader.latestMessages(workspaceId: lab.workspace.id, channelId: labChannel.id, limit: 30)
        try require(!pausedRows.contains(where: { $0.body == pausedUpdate }), "paused Lab does not apply new events")
        checks.append("paused workspace suppresses new event fetches while another continues updating")
        model.setWorkspaceEnabled(studio, false)
        try await multiWait("empty selection") { model.enabledWorkspaceEntries.isEmpty && model.selectedWorkspace == nil }
        await settle()
        try require(model.store == nil && model.writes == nil && model.outbox == nil,
                    "final pause exposes no selected store or write services")
        try require(find(window, "workspace.empty.choose") != nil, "Mac presents the workspace selection empty state")
        let catalog = try LocalStore(directory: ProductionStorage.storeDirectory(fixture.directory))
        let preferenceKey = "native.workspace-preferences.v1:" + WorkspaceBoundary.digest([studio.connection.signerNpub])
        try await multiWait("durable empty enabled list") {
            guard let encoded = try? await catalog.reader.state(preferenceKey),
                  let preferences = try? JSONDecoder().decode(WorkspacePreferences.self, from: Data(encoded.utf8)) else { return false }
            return preferences.enabled.isEmpty
        }
        checks.append("final pause shows empty state and persists an intentional empty enabled list")
        model.setWorkspaceEnabled(lab, true)
        try await multiWait("Lab resumes saved navigation") { model.selectedWorkspaceBoundary == lab.boundary && labRuntime.validated }
        let resumedDraft = try await labRuntime.store.reader.draft(labTarget)
        try require(resumedDraft?.text == "Lab retained sample draft", "resume preserves Lab draft")
        try await multiWait("Lab catches up the update emitted while paused") {
            let rows = try? await labRuntime.store.reader.latestMessages(workspaceId: lab.workspace.id, channelId: labChannel.id, limit: 30)
            return rows?.contains(where: { $0.body == pausedUpdate }) == true
        }
        checks.append("re-enable restores local navigation, validates access, catches up paused events and preserves draft")
        let elapsed = Double(started.duration(to: .now).components.attoseconds) / 1e18 + Double(started.duration(to: .now).components.seconds)
        let report: [String: Any] = ["result": "passed", "scope": "Mac Test app with in-process Tower fixtures; no live multi-Tower or device verification",
                                     "checks": checks, "elapsedSeconds": elapsed,
                                     "concurrentFixtureUpdateLatencyMs": Double(updateLatency.components.seconds) * 1000 + Double(updateLatency.components.attoseconds) / 1e15,
                                     "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        print("MULTI_WORKSPACE_REPORT \(output)")
    }

    /// Reproduces the read-validated / write-paused state produced by a locked background
    /// resume, using only the separate Test app's synthetic identity and Tower.
    static func writeResumeCheck(_ window: NSWindow, model: AppModel) async throws {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".test") == true, model.fixture != nil,
              let output = ProcessInfo.processInfo.environment["AMBULANDO_MAC_WRITE_RESUME_REPORT"],
              output.hasPrefix(FileManager.default.currentDirectoryPath + "/tmp/docs/handoffs/") else {
            throw Failure(description: "Write-resume check requires the isolated Test app and ignored report path")
        }
        try await multiWait("enabled fixture workspace") { model.enabledWorkspaceEntries.first?.runtime?.validated == true }
        guard let entry = model.enabledWorkspaceEntries.first, let runtime = entry.runtime,
              let channel = entry.navigation.groups.flatMap(\.channels).first else {
            throw Failure(description: "Missing validated fixture workspace")
        }
        try require(model.isUnlocked, "synthetic identity is unlocked")
        let target = ChatTarget(connectionId: entry.connection.id, workspaceId: entry.workspace.id, channelId: channel.id)
        let marker = "Write-resume fixture " + UUID().uuidString
        var checks: [String] = []
        // Recreate a read-only background validation: reads stay active, the write gate is closed.
        runtime.writeActivity.pause()
        let first = try await runtime.outbox.send(text: marker + " first", mentions: [], target: target,
                                                  connection: entry.connection, workspace: entry.workspace)
        let second = try await runtime.outbox.send(text: marker + " second", mentions: [], target: target,
                                                   connection: entry.connection, workspace: entry.workspace)
        await runtime.engine.waitUntilIdle()
        try require(first != nil && second != nil, "messages are durably queued")
        let pending = try await runtime.store.reader.outbox(connectionId: entry.connection.id, signerNpub: entry.connection.signerNpub)
        try require(pending.contains { $0.id == first?.id } && pending.contains { $0.id == second?.id }, "closed write gate keeps both messages")
        try require(runtime.validated && runtime.activity.isEnabled && !runtime.writeActivity.isEnabled, "read sync remains validated while sends wait")
        checks.append("both messages remain durable when write gate is closed but reads are validated")
        await model.resumeWorkspace(entry)
        try await multiWait("queued sends resume without another network event") {
            let pending = try? await runtime.store.reader.outbox(connectionId: entry.connection.id, signerNpub: entry.connection.signerNpub)
            return pending?.contains { $0.id == first?.id || $0.id == second?.id } == false
        }
        let sent = try await runtime.store.reader.latestMessages(workspaceId: entry.workspace.id, channelId: channel.id, limit: 100)
        try require(sent.filter { $0.body == marker + " first" }.count == 1 && sent.filter { $0.body == marker + " second" }.count == 1,
                    "resumed requests are acknowledged exactly once")
        checks.append("resume opens write gate and automatically acknowledges both messages once")
        let lease = try runtime.writeActivity.lease()
        await model.resumeWorkspace(entry)
        try runtime.writeActivity.check(lease)
        checks.append("already writable resume preserves the active write generation")
        // Unlock can arrive while a read-only startup is still finishing. A waiter must
        // reevaluate the write gate after startup, rather than returning unconditionally.
        runtime.writeActivity.pause()
        runtime.starting = Task { @MainActor in try? await Task.sleep(for: .milliseconds(100)) }
        let third = try await runtime.store.writer.enqueueSend(target: target, origin: entry.connection.origin,
                    signerNpub: entry.connection.signerNpub, appNpub: entry.workspace.appNpub,
                    body: marker + " after-start", mentions: [])
        await model.resumeWorkspace(entry)
        try await multiWait("write resume after awaiting read startup") {
            (try? await runtime.store.reader.outboxItem(id: third.id)) == nil
        }
        try require(runtime.writeActivity.isEnabled, "write gate reopened after startup waiter")
        checks.append("unlock waiting for startup rechecks gate and drains pending send")
        await model.lock()
        await model.resumeWorkspace(entry)
        try require(!model.isUnlocked && !runtime.writeActivity.isEnabled, "locked identity never reopens writes")
        let locked = try await runtime.store.writer.enqueueSend(target: target, origin: entry.connection.origin,
                    signerNpub: entry.connection.signerNpub, appNpub: entry.workspace.appNpub,
                    body: marker + " locked", mentions: [])
        await runtime.outbox.kick(entry.connection, force: true)
        try require(try await runtime.store.reader.outboxItem(id: locked.id) != nil, "locked send remains durable")
        await model.unlock(pin: FixtureEnvironment.pin)
        try await multiWait("explicit unlock resumes locked queue") {
            (try? await runtime.store.reader.outboxItem(id: locked.id)) == nil
        }
        checks.append("lock keeps write authority closed and explicit unlock drains its retained message")
        let report: [String: Any] = ["result": "passed", "checks": checks,
            "scope": "Shared native AppModel with isolated Mac Test fixtures; no user account or live server",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    private static func multiWait(_ description: String, condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(25)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(description: "Timed out waiting for \(description)")
    }
}
#endif
