#if DEBUG
import AppKit
import AmbulandoCore

extension MacThreadRegression {
    static func hangDiagnosticCheck() async throws {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("AmbulandoHangDiagnostics")
        try require(Bundle.main.bundleIdentifier?.hasSuffix(".test") == true, "diagnostic check requires isolated bundle")
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        await settle()
        MacHangDiagnostics.shared.mark("fixture.deliberateStall")
        func block() { Thread.sleep(forTimeInterval: 5.5) }
        block()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try require(files.count == 1, "watchdog writes once while main is blocked")
        let data = try Data(contentsOf: files[0])
        let record = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try require(data.count <= 16_384 && record["build"] as? String == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "bounded current-build evidence")
        try require((record["heartbeatDelaySeconds"] as? Double ?? 0) >= 4, "stall threshold")
        try require(record["breadcrumbStackNotHangSample"] != nil, "stack labelled honestly")
        try? await Task.sleep(for: .seconds(2))
        try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1, "no duplicate after recovery")
        print("DIAGNOSTIC_PASS blockedMain=5.5s files=1 bytes=\(data.count) heartbeatRecovered=true"); fflush(stdout)
    }

    static func dividerCheck(_ window: NSWindow, model: AppModel) async throws {
        guard let fixture = model.fixture, let workspace = model.selectedWorkspace, let store = model.store else {
            throw Failure(description: "Missing isolated fixture")
        }
        var lastPulse = ProcessInfo.processInfo.systemUptime
        var maxPulseGap = 0.0
        let pulse = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                maxPulseGap = max(maxPulseGap, now - lastPulse)
                lastPulse = now
            }
        }
        RunLoop.main.add(pulse, forMode: .common)
        RunLoop.main.add(pulse, forMode: .eventTracking)
        defer { pulse.invalidate() }
        if let entry = model.enabledWorkspaceEntries.first {
            let reference = entry.boundary.id
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<20_000 { try require(entry.id == reference, "cached exact boundary identity") }
            let cached = ProcessInfo.processInfo.systemUptime - start
            let hashing = ProcessInfo.processInfo.systemUptime
            for _ in 0..<20_000 { try require(entry.boundary.id == reference, "reference identity") }
            print("IDENTITY cachedSeconds=\(cached) rehashedSeconds=\(ProcessInfo.processInfo.systemUptime - hashing)")
        }
        model.mode = .deck
        await settle()
        func split(in view: NSView) -> NSSplitView? {
            if let value = view as? NSSplitView, value.isVertical, value.arrangedSubviews.count >= 2 { return value }
            return view.subviews.lazy.compactMap { split(in: $0) }.first
        }
        guard let divider = window.contentView.flatMap({ split(in: $0) }) else {
            throw Failure(description: "Missing actual NSSplitView")
        }
        let focus = ThreadFocus(workspaceId: workspace.id, channelId: FixtureTower.generalChannel, threadId: FixtureTower.threadReview)
        let initial = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500).count
        let updates = Task.detached {
            for n in 0..<40 {
                fixture.tower.postAsMember(channel: FixtureTower.generalChannel, body: "Divider reply \(n)", threadId: FixtureTower.threadReview)
                fixture.tower.postAsMember(channel: FixtureTower.generalChannel, body: "Divider inbox \(n)")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { updates.cancel() }
        var pausedLoads: Int?
        var panelButton: NSButton?
        var maxReleaseDelay = 0.0
        var maxDuration = 0.0
        for cycle in 0..<20 {
            if cycle == 5 { model.focusThread(focus); await settle(); try type(window, "Divider draft preserved") }
            if cycle == 6 {
                pausedLoads = MacHangDiagnostics.shared.snapshot()["deck.inbox.loaded", default: 0]
                panelButton = nativeActionsButton(window.contentView!, id: "thread.focus.actions")
                try require(panelButton != nil, "focused native menu exists")
            }
            if cycle == 12 {
                try require(MacHangDiagnostics.shared.snapshot()["deck.inbox.loaded", default: 0] == pausedLoads, "ordinary changes stay deferred")
                // Exercise the real observer exception without deleting any fixture/account data.
                await store.changes.record([ChangeKey(.access, workspace.id)])
                await settle()
                let reloaded = MacHangDiagnostics.shared.snapshot()["deck.inbox.loaded", default: 0]
                try require(reloaded > (pausedLoads ?? 0), "access invalidation reloads even behind modal")
                pausedLoads = reloaded
                print("BACKGROUND_ACCESS_INVALIDATION_PASS loaded=\(reloaded)"); fflush(stdout)
            }
            if cycle == 14 {
                try require(MacHangDiagnostics.shared.snapshot()["deck.inbox.loaded", default: 0] == pausedLoads, "ordinary background changes do not reload inactive Inbox")
                try require(nativeActionsButton(window.contentView!, id: "thread.focus.actions") === panelButton, "divider/update keeps menu identity")
                print("BACKGROUND_INBOX_PAUSE_PASS loaded=\(pausedLoads ?? -1) menuIdentity=stable"); fflush(stdout)
            }
            if cycle == 8 { try await menuAction(window, title: "Copy message", button: "thread.focus.actions") }
            if cycle == 15 {
                try press(window, "thread.focus.close"); await settle()
                try await waitForText(window, "Divider inbox", "Inbox catches up when modal closes", seconds: 15)
                try require(MacHangDiagnostics.shared.snapshot()["deck.inbox.loaded", default: 0] > (pausedLoads ?? 0), "Inbox resumes query")
            }
            window.contentView?.layoutSubtreeIfNeeded()
            let before = divider.arrangedSubviews[0].frame.width
            let point = divider.convert(NSPoint(x: divider.arrangedSubviews[0].frame.maxX + divider.dividerThickness / 2, y: divider.bounds.midY), to: nil)
            let number = window.windowNumber
            let delta: CGFloat = before < 300 ? 40 : -40
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: cycle * 100, clickCount: 1, pressure: 1)!
            // Post from another thread while NSSplitView.mouseDown owns its nested tracking loop.
            // This deliberately reaches the actual divider even under the modal's input shield.
            let upPosted = MacRegressionMemory<Double>()
            DispatchQueue.global().async {
                for step in 1...12 {
                    Thread.sleep(forTimeInterval: 0.025)
                    let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: point.x + delta * CGFloat(step) / 12, y: point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: cycle * 100 + step, clickCount: 1, pressure: 1)!
                    NSApp.postEvent(event, atStart: false)
                }
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: point.x + delta, y: point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: cycle * 100 + 13, clickCount: 1, pressure: 0)!
                upPosted.save(ProcessInfo.processInfo.systemUptime)
                NSApp.postEvent(up, atStart: false)
            }
            let start = ProcessInfo.processInfo.systemUptime
            divider.mouseDown(with: down)
            let duration = ProcessInfo.processInfo.systemUptime - start
            maxDuration = max(maxDuration, duration)
            let releaseDelay = ProcessInfo.processInfo.systemUptime - (upPosted.load() ?? start)
            maxReleaseDelay = max(maxReleaseDelay, releaseDelay)
            maxPulseGap = max(maxPulseGap, ProcessInfo.processInfo.systemUptime - lastPulse)
            let after = divider.arrangedSubviews[0].frame.width
            print("DIVIDER cycle=\(cycle) modal=\(model.focusedThread != nil) before=\(before) after=\(after) seconds=\(duration) releaseDelay=\(releaseDelay) maxTrackingHeartbeatGap=\(maxPulseGap)"); fflush(stdout)
            try require(abs(after - before) > 10, "actual divider must move")
            try require(upPosted.load() != nil && releaseDelay < 2, "divider must return within2s after posted mouseUp")
            try require(maxPulseGap < 2, "common/eventTracking heartbeat must remain responsive")
            try? await Task.sleep(for: .milliseconds(250))
        }
        await updates.value
        model.focusThread(focus)
        for _ in 0..<30 {
            model.openThread(focus.threadId, channelId: FixtureTower.generalChannel, in: workspace)
            let count = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500).count
            if count == initial + 40 { break }
            await settle()
        }
        let final = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500).count
        try require(final == initial + 40, "all incoming replies arrive through sync")
        await settle()
        try require(try textView(window).string == "Divider draft preserved", "draft survives dragging and reopen")
        try require(containsText(window, "Divider reply"), "incoming content renders")
        // Existing native action test verifies the current menu's action using its real tracking loop.
        try await menuAction(window, title: "Copy message", button: "thread.focus.actions")
        try await waitForText(window, "Stopped responding", "activity deadline remains live during dragging", seconds: 45)
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacDividerSoak") {
            let started = ProcessInfo.processInfo.systemUptime
            for tick in 0..<60 {
                fixture.tower.postAsMember(channel: FixtureTower.generalChannel, body: "Soak reply \(tick)", threadId: focus.threadId)
                fixture.tower.postAsMember(channel: FixtureTower.generalChannel, body: "Soak inbox \(tick)")
                if tick.isMultiple(of: 6) {
                    // Exercise app-local wake/foreground handling; never sleep or restart the user's machine/app.
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                    model.sceneDidBecomeActive()
                    try press(window, "thread.focus.close"); await settle()
                    try await waitForText(window, "Soak inbox", "background Inbox catches up on closing", seconds: 15)
                    model.focusThread(focus); await settle()
                    try require(try textView(window).string == "Divider draft preserved", "soak draft")
                    try await menuAction(window, title: "Copy message", button: "thread.focus.actions")
                    print("SOAK tick=\(tick) elapsed=\(ProcessInfo.processInfo.systemUptime - started) counts=\(MacHangDiagnostics.shared.snapshot())"); fflush(stdout)
                }
                try? await Task.sleep(for: .seconds(10))
                try require(maxPulseGap < 2, "soak common/eventTracking heartbeat")
            }
            model.openThread(focus.threadId, channelId: FixtureTower.generalChannel, in: workspace)
            try await waitForText(window, "Soak reply 59", "last soak reply renders", seconds: 15)
            let rows = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500)
            try require(rows.count == initial + 100, "all soak replies retained")
            print("SOAK_PASS elapsed=\(ProcessInfo.processInfo.systemUptime - started) simulatedWakeCycles=10 replies=100 inbox=100")
        }
        print("UI_COUNTS \(MacHangDiagnostics.shared.snapshot())")
        print("DIVIDER_PASS cycles=20 replies=40 inbox=40 maxSeconds=\(maxDuration) maxReleaseDelay=\(maxReleaseDelay) maxTrackingHeartbeatGap=\(maxPulseGap)"); fflush(stdout)
    }
}
#endif
