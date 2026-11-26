import Foundation
import Testing
@testable import AmbulandoCore

/// Goals: the shared `ambulando.goal` v1 format, expectation-checked edits, the compare-and-swap save loop against an
/// in-memory File store, and the rule that decides whether a channel may hold someone's goals.
@Suite struct GoalsTests {
    static func goal() throws -> Goal {
        var g = try Goal.create(name: "Ship the beta", description: "Get the beta to ten people.", startDate: "2026-12-01", targetDate: "2026-12-18")
        g.checkpoints = [GoalCheckpoint(id: "a", title: "Invite list"), GoalCheckpoint(id: "b", title: "Build", date: "2026-12-10"), GoalCheckpoint(id: "c", title: "Ship")]
        g.links = [GoalLink(type: .task, recordId: UUID().uuidString), GoalLink(type: .chat, recordId: UUID().uuidString, channelId: UUID().uuidString)]
        return g
    }

    // MARK: Format

    /// The same bytes are asserted by `scripts/tests/goals-lib.test.mjs`, so every client writes one canonical form.
    static let canonical = #"{"future":{"a":[1,2.5]},"schema":"ambulando.goal","schema_version":1,"name":"Ship the beta","description":"Get the beta to ten people.","start_date":"2026-12-01","target_date":"2026-12-18","status":"active","checkpoints":[{"id":"a","title":"Invite list","reached":true},{"id":"b","title":"Build","date":"2026-12-10","description":"Ready to ship","reached":false}],"links":[{"type":"task","record_id":"11111111-1111-4111-8111-111111111111"},{"type":"chat","record_id":"22222222-2222-4222-8222-222222222222","channel_id":"11111111-1111-4111-8111-111111111111"}]}"#

    @Test func writesTheSameCanonicalBytesAsTheOtherClients() throws {
        let goal = try Goal.parse(Data(Self.canonical.utf8))
        #expect(String(decoding: goal.encode(), as: UTF8.self) == Self.canonical)
        #expect(goal.checkpoints.map(\.reached) == [true, false] && goal.links.count == 2 && goal.links[1].channelId != nil)
    }

    @Test func roundTripsAndKeepsUnknownFields() throws {
        let json = """
        {"future":{"a":[1,2.50]},"schema":"ambulando.goal","schema_version":1,"name":"N","description":"D","status":"active",
         "checkpoints":[{"id":"x","title":"T","reached":true,"colour":"red"}],
         "links":[{"type":"doc","record_id":"\(UUID().uuidString)","note":"keep"}]}
        """
        let goal = try Goal.parse(Data(json.utf8))
        let text = String(decoding: goal.encode(), as: UTF8.self)
        #expect(text.contains("\"future\":{\"a\":[1,2.50]}"))
        #expect(text.contains("\"colour\":\"red\"") && text.contains("\"note\":\"keep\""))
        #expect(try Goal.parse(goal.encode()) == goal)
    }

    @Test func refusesUnsupportedAndMalformed() throws {
        let newer = #"{"schema":"ambulando.goal","schema_version":2,"name":"N","description":"D","status":"active"}"#
        #expect(throws: GoalError.unsupported) { try Goal.parse(Data(newer.utf8)) }
        #expect(throws: GoalError.self) { try Goal.parse(Data("[]".utf8)) }
        #expect(throws: GoalError.self) { try Goal.parse(Data(#"{"schema":"other","schema_version":1}"#.utf8)) }
        let badStatus = #"{"schema":"ambulando.goal","schema_version":1,"name":"N","description":"D","status":"paused"}"#
        #expect(throws: GoalError.self) { try Goal.parse(Data(badStatus.utf8)) }
    }

    @Test func validatesRules() throws {
        #expect(throws: GoalError.invalid("A goal needs a name.")) { try Goal.create(name: "  ", description: "d") }
        #expect(throws: GoalError.invalid("A goal needs a description.")) { try Goal.create(name: "n", description: "") }
        #expect(throws: GoalError.invalid("The target date is before the start date.")) { try Goal.create(name: "n", description: "d", startDate: "2026-12-18", targetDate: "2026-12-01") }
        #expect(throws: GoalError.self) { try Goal.create(name: "n", description: "d", startDate: "2026-02-30") }
        #expect(throws: GoalError.self) { try Goal.create(name: "n", description: "d", targetDate: "18/12/2026") }
        #expect(throws: GoalError.self) { try Goal.create(name: "n", description: "d", targetDate: "2026-1-5") }
        #expect(try Goal.create(name: "n", description: "d", startDate: " ", targetDate: nil).startDate == nil)
        var g = try Self.goal()
        g.checkpoints.append(GoalCheckpoint(id: "a", title: "dup"))
        #expect(throws: GoalError.invalid("Checkpoint identities repeat.")) { try g.validated() }
        var h = try Self.goal(); h.links.append(h.links[0])
        #expect(throws: GoalError.invalid("A record is linked twice.")) { try h.validated() }
    }

    @Test func progressIsCheckpointsReached() throws {
        var g = try Self.goal()
        #expect(g.reachedCount == 0 && g.nextCheckpointId == "a")
        g.checkpoints[0].reached = true
        #expect(g.reachedCount == 1 && g.nextCheckpointId == "b")
        g.status = .completed
        #expect(g.nextCheckpointId == nil)
    }

    // MARK: Edits

    @Test func editsRequireTheValuesTheEditorSaw() throws {
        let g = try Self.goal()
        #expect(try GoalEdit.setName(expected: "Ship the beta", value: " Ship v1 ").apply(to: g).name == "Ship v1")
        #expect(throws: GoalError.conflict("The name was changed elsewhere.")) { try GoalEdit.setName(expected: "Old name", value: "X").apply(to: g) }
        // Already in effect: accepted without error.
        #expect(try GoalEdit.setName(expected: "Old name", value: "Ship the beta").apply(to: g) == g)
        #expect(try GoalEdit.setTargetDate(expected: "2026-12-18", value: nil).apply(to: g).targetDate == nil)
        #expect(throws: GoalError.self) { try GoalEdit.setTargetDate(expected: "2026-12-18", value: "2026-11-01").apply(to: g) }
    }

    @Test func reachingAndReordering() throws {
        let g = try Self.goal()
        let reached = try GoalEdit.setReached(id: "b", expected: false, reached: true).apply(to: g)
        #expect(reached.checkpoints.map(\.reached) == [false, true, false])
        // A boolean is either the wanted value (already in effect) or the one expected, so reaching never conflicts.
        #expect(try GoalEdit.setReached(id: "b", expected: true, reached: false).apply(to: g) == g)
        #expect(throws: GoalError.conflict("That checkpoint was removed elsewhere.")) { try GoalEdit.setReached(id: "gone", expected: false, reached: true).apply(to: g) }
        #expect(try GoalEdit.setReached(id: "b", expected: false, reached: false).apply(to: g) == g)
        let moved = try GoalEdit.moveCheckpoint(id: "c", toIndex: 0).apply(to: g)
        #expect(moved.checkpoints.map(\.id) == ["c", "a", "b"])
        #expect(try GoalEdit.moveCheckpoint(id: "a", toIndex: 99).apply(to: g).checkpoints.map(\.id) == ["b", "c", "a"])
        let added = try GoalEdit.addCheckpoint(GoalCheckpoint(id: "n", title: "New"), afterId: "a").apply(to: g)
        #expect(added.checkpoints.map(\.id) == ["a", "n", "b", "c"])
        #expect(try GoalEdit.addCheckpoint(GoalCheckpoint(id: "n", title: "New"), afterId: "gone").apply(to: g).checkpoints.last?.id == "n")
        #expect(try GoalEdit.removeCheckpoint(id: "a").apply(to: g).checkpoints.map(\.id) == ["b", "c"])
    }

    @Test func updatingACheckpointKeepsReachedAndDetectsConflict() throws {
        var g = try Self.goal(); g.checkpoints[1].reached = true
        let expected = g.checkpoints[1]
        var value = expected; value.title = "Build it"; value.reached = false
        let updated = try GoalEdit.updateCheckpoint(id: "b", expected: expected, value: value).apply(to: g)
        #expect(updated.checkpoints[1].title == "Build it" && updated.checkpoints[1].reached)
        var stale = expected; stale.title = "Something older"
        #expect(throws: GoalError.self) { try GoalEdit.updateCheckpoint(id: "b", expected: stale, value: value).apply(to: g) }
        #expect(throws: GoalError.conflict("That checkpoint was removed elsewhere.")) {
            try GoalEdit.updateCheckpoint(id: "zz", expected: expected, value: value).apply(to: g)
        }
    }

    @Test func linkingIsByReferenceAndUnlinkingTouchesNothingElse() throws {
        let g = try Self.goal()
        let doc = GoalLink(type: .doc, recordId: UUID().uuidString)
        let linked = try GoalEdit.link(doc).apply(to: g)
        #expect(linked.links.count == 3)
        #expect(try GoalEdit.link(doc).apply(to: linked) == linked)
        // The same record can sit in other goals; one goal removing it changes only its own list.
        let unlinked = try GoalEdit.unlink(.doc, recordId: doc.recordId.uppercased()).apply(to: linked)
        #expect(unlinked == g)
        #expect(throws: GoalError.self) { try GoalEdit.link(GoalLink(type: .file, recordId: "not-a-uuid")).apply(to: g) }
    }

    @Test func completeArchiveAndRestore() throws {
        let g = try Self.goal()
        let done = try GoalEdit.setStatus(expected: .active, value: .completed).apply(to: g)
        #expect(done.status == .completed && done.checkpoints == g.checkpoints && done.links == g.links)
        let archived = try GoalEdit.setStatus(expected: .completed, value: .archived).apply(to: done)
        #expect(throws: GoalError.self) { try GoalEdit.setName(expected: g.name, value: "x").apply(to: archived) }
        #expect(throws: GoalError.self) { try GoalEdit.link(GoalLink(type: .doc, recordId: UUID().uuidString)).apply(to: archived) }
        #expect(try GoalEdit.setStatus(expected: .archived, value: .active).apply(to: archived).links == g.links)
        #expect(throws: GoalError.conflict("This goal was archived elsewhere.")) { try GoalEdit.setStatus(expected: .active, value: .completed).apply(to: archived) }
    }

    // MARK: Save loop

    /// An in-memory File: versions are immutable, a save needs the current head or it conflicts.
    actor Store {
        var versions: [(id: String, bytes: Data)]
        var saves = 0
        /// Runs once just before the next save is evaluated, to let "another device" win the race.
        var interject: (@Sendable (Store) async -> Void)?
        let file: FileRecord

        init(_ goal: Goal) {
            versions = [(UUID().uuidString.lowercased(), goal.encode())]
            file = FileRecord(workspaceId: UUID().uuidString.lowercased(), id: UUID().uuidString.lowercased(), scopeId: nil, channelId: UUID().uuidString.lowercased(),
                              folderId: nil, storageObjectId: nil, displayName: "g.goal.json", contentType: Goal.mime, sizeBytes: nil, sha256: nil, createdAt: "", updatedAt: "")
        }
        func setInterject(_ f: (@Sendable (Store) async -> Void)?) { interject = f }
        func head() -> (id: String, bytes: Data) { versions.last! }
        func save(base: String, bytes: Data) async -> GoalSaveOutcome {
            if let f = interject { interject = nil; await f(self) }
            guard versions.last!.id == base else { return .conflict }
            let id = UUID().uuidString.lowercased()
            versions.append((id, bytes)); saves += 1
            return .saved(versionId: id)
        }
        func force(_ edits: [GoalEdit]) throws {
            let next = try GoalEdit.applyAll(edits, to: Goal.parse(versions.last!.bytes))
            versions.append((UUID().uuidString.lowercased(), next.encode()))
        }
        func current() throws -> Goal { try Goal.parse(versions.last!.bytes) }
        func transport() -> GoalTransport {
            let file = file
            return GoalTransport(
                read: { _ in let h = await self.head(); return GoalDocument(file: file, versionId: h.id, goal: try Goal.parse(h.bytes)) },
                save: { _, base, bytes, _ in await self.save(base: base, bytes: bytes) })
        }
    }

    @Test func independentEditsFromTwoClientsBothSurvive() async throws {
        let store = Store(try Self.goal())
        // Another device renames the goal between our read and our save.
        await store.setInterject { s in try? await s.force([.setName(expected: "Ship the beta", value: "Ship the beta v2")]) }
        let doc = try await GoalEditor.edit(await store.transport(), fileId: store.file.id, edits: [.setReached(id: "a", expected: false, reached: true)])
        let saved = try await store.current()
        #expect(saved.name == "Ship the beta v2" && saved.checkpoints[0].reached)
        #expect(doc.goal == saved)
        #expect(await store.versions.count == 3)
    }

    @Test func aContradictingEditSavesNothing() async throws {
        // A real contradiction: someone else already changed the same field.
        let s2 = Store(try Self.goal())
        await s2.setInterject { s in try? await s.force([.setName(expected: "Ship the beta", value: "Theirs")]) }
        await #expect(throws: GoalError.conflict("The name was changed elsewhere.")) {
            try await GoalEditor.edit(await s2.transport(), fileId: s2.file.id, edits: [.setName(expected: "Ship the beta", value: "Mine")])
        }
        #expect(try await s2.current().name == "Theirs")
    }

    @Test func noChangeWritesNoVersionAndRepeatedRacesStop() async throws {
        let store = Store(try Self.goal())
        _ = try await GoalEditor.edit(await store.transport(), fileId: store.file.id, edits: [.setName(expected: "Ship the beta", value: "Ship the beta")])
        #expect(await store.versions.count == 1)
        let always = GoalTransport(read: { _ in let h = await store.head(); return GoalDocument(file: store.file, versionId: h.id, goal: try Goal.parse(h.bytes)) },
                                   save: { _, _, _, _ in .conflict })
        await #expect(throws: GoalSaveFailed.self) { try await GoalEditor.edit(always, fileId: store.file.id, edits: [.setReached(id: "a", expected: false, reached: true)], attempts: 3) }
    }

    @Test func deniedAndOfflineSavesAreReportedWithoutChange() async throws {
        let store = Store(try Self.goal())
        func transport(_ outcome: GoalSaveOutcome) -> GoalTransport {
            GoalTransport(read: { _ in let h = await store.head(); return GoalDocument(file: store.file, versionId: h.id, goal: try Goal.parse(h.bytes)) }, save: { _, _, _, _ in outcome })
        }
        do { _ = try await GoalEditor.edit(transport(.denied("no")), fileId: store.file.id, edits: [.setReached(id: "a", expected: false, reached: true)]); Issue.record("expected failure") }
        catch let e as GoalSaveFailed { #expect(!e.retryable && e.message == "no") }
        do { _ = try await GoalEditor.edit(transport(.retryable("offline")), fileId: store.file.id, edits: [.setReached(id: "a", expected: false, reached: true)]); Issue.record("expected failure") }
        catch let e as GoalSaveFailed { #expect(e.retryable) }
        #expect(await store.versions.count == 1)
    }

    // MARK: Goal files and the Goals space

    @Test func onlyCurrentGoalFilesAreGoals() throws {
        func file(type: String?, meta: [String: Any]?, state: String? = nil) throws -> FileRecord {
            var o: [String: Any] = ["id": UUID().uuidString, "workspace_id": UUID().uuidString, "channel_id": UUID().uuidString, "display_name": "x"]
            if let type { o["content_type"] = type }
            if let meta { o["metadata"] = meta }
            if let state { o["record_state"] = state }
            return try FileRecord(raw: JSONSerialization.data(withJSONObject: o))
        }
        #expect(GoalFiles.isGoal(try file(type: Goal.mime + "; charset=utf-8", meta: GoalFiles.metadata)))
        #expect(!GoalFiles.isGoal(try file(type: "application/json", meta: GoalFiles.metadata)))
        #expect(!GoalFiles.isGoal(try file(type: Goal.mime, meta: nil)))
        #expect(!GoalFiles.isGoal(try file(type: Goal.mime, meta: ["goal": ["schema_version": 2]])))
        #expect(!GoalFiles.isGoal(try file(type: Goal.mime, meta: GoalFiles.metadata, state: "deleted")))
        #expect(!GoalFiles.isGoal(try file(type: Goal.mime, meta: GoalFiles.metadata, state: "archived")))
        #expect(GoalFiles.fileName(try Goal.create(name: "a/b\\c\n", description: "d")) == "a b c.goal.json")
    }

    static let owner = "npub1" + String(repeating: "q", count: 58)
    static let ownerActor = UUID().uuidString.lowercased(), agentActor = UUID().uuidString.lowercased(), otherActor = UUID().uuidString.lowercased()

    static func members(workspace: String) -> [MemberRecord] {
        [MemberRecord(workspaceId: workspace, actorId: ownerActor, npub: owner, kind: "human", displayName: "Pete"),
         MemberRecord(workspaceId: workspace, actorId: agentActor, npub: "npub1" + String(repeating: "p", count: 58), kind: "agent", displayName: "Rick"),
         MemberRecord(workspaceId: workspace, actorId: otherActor, npub: "npub1" + String(repeating: "z", count: 58), kind: "human", displayName: "Sam")]
    }

    static func channel(owner: String?, scope: String = UUID().uuidString.lowercased(), extra: [String: Any] = [:]) throws -> ChannelRecord {
        var o: [String: Any] = ["id": UUID().uuidString.lowercased(), "workspace_id": UUID().uuidString.lowercased(), "scope_id": scope, "name": "Goals", "kind": "channel"]
        if let owner { o["metadata"] = GoalsSpace.metadata(owner: owner) }
        return try ChannelRecord(raw: JSONSerialization.data(withJSONObject: o.merging(extra) { _, n in n }))
    }

    @Test func aChannelIsOnlyTheOwnersGoalsSpaceByMetadata() throws {
        #expect(GoalsSpace.isOwnedBy(try Self.channel(owner: Self.owner), viewer: Self.owner))
        #expect(!GoalsSpace.isOwnedBy(try Self.channel(owner: "npub1" + String(repeating: "x", count: 58)), viewer: Self.owner))
        #expect(!GoalsSpace.isOwnedBy(try Self.channel(owner: nil), viewer: Self.owner))
        #expect(!GoalsSpace.isOwnedBy(try Self.channel(owner: Self.owner, extra: ["archived_at": "2026-01-01T00:00:00Z"]), viewer: Self.owner))
    }

    @Test func spaceIsUnusableWhenSharedBeyondOwnerAndAgents() throws {
        let channel = try Self.channel(owner: Self.owner)
        let members = Self.members(workspace: channel.workspaceId)
        func state(_ grants: [GoalsChannelGrant]) -> GoalsSpaceState { GoalsSpaceResolver.classify(channel: channel, grants: grants, members: members, viewer: Self.owner) }
        let ownerGrant = GoalsChannelGrant(actorId: Self.ownerActor, npub: Self.owner, isGroup: false, access: "manage")
        let agentGrant = GoalsChannelGrant(actorId: Self.agentActor, npub: nil, isGroup: false, access: "contribute")
        guard case .ready(_, let agents) = state([ownerGrant, agentGrant]) else { Issue.record("expected ready"); return }
        #expect(agents.first { $0.member.actorId == Self.agentActor }?.access == "contribute")
        #expect(agents.count == 1)
        guard case .ready(_, let none) = state([ownerGrant]) else { Issue.record("expected ready"); return }
        #expect(none.allSatisfy { $0.access == nil })
        // Another person, a group, or no owner grant: refused rather than written to.
        for bad in [[ownerGrant, GoalsChannelGrant(actorId: Self.otherActor, npub: nil, isGroup: false, access: "view")],
                    [ownerGrant, GoalsChannelGrant(actorId: UUID().uuidString.lowercased(), npub: nil, isGroup: true, access: "view")],
                    [agentGrant], []] {
            guard case .unsafe = state(bad) else { Issue.record("expected unsafe for \(bad)"); return }
        }
    }

    @Test func homeIsSuggestedOnlyWhenUnambiguous() throws {
        func scope(_ name: String, kind: String? = "project") throws -> ScopeRecord {
            try ScopeRecord(raw: JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "workspace_id": UUID().uuidString, "name": name, "kind": kind as Any]))
        }
        let home = try scope("Home")
        #expect(GoalsSpace.suggestedScope([home, try scope("Features")])?.id == home.id)
        #expect(GoalsSpace.suggestedScope([home, try scope("Home")]) == nil)
        #expect(GoalsSpace.suggestedScope([try scope("Home", kind: "dm")]) == nil)
    }
}

@Suite struct GoalFormatTests {
    @Test func datesAreCalendarDaysNotInstants() throws {
        let us = Locale(identifier: "en_US")
        #expect(GoalFormat.date("2026-12-18", locale: us) == "Dec 18, 2026")
        #expect(GoalFormat.date("2026-02-30") == nil && GoalFormat.date(nil) == nil)
        let today = GoalFormat.controlDate("2026-06-15")!
        #expect(GoalFormat.short("2026-12-18", today: today, locale: us) == "Dec 18")
        #expect(GoalFormat.short("2027-01-02", today: today, locale: us) == "Jan 2, 2027")
        for zone in ["Pacific/Auckland", "America/Los_Angeles", "Australia/Perth"] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
            #expect(GoalFormat.string(from: GoalFormat.controlDate("2026-12-18", calendar: calendar)!, calendar: calendar) == "2026-12-18")
        }
    }

    @Test func progressIsCountedNotInvented() throws {
        var goal = try Goal.create(name: "n", description: "d")
        #expect(GoalFormat.progress(goal) == "No checkpoints yet")
        goal.checkpoints = [GoalCheckpoint(id: "a", title: "A", reached: true), GoalCheckpoint(id: "b", title: "B")]
        #expect(GoalFormat.progress(goal) == "1 of 2 checkpoints reached")
        goal.checkpoints.removeLast()
        #expect(GoalFormat.progress(goal) == "1 of 1 checkpoint reached")
    }
}

/// A goal as Android writes it (docs/fixtures/goals/android-written-v1.json, shared with the JS agent tool): Swift parses,
/// edits and rewrites it with every unknown field intact (semantically; number spelling need not round-trip), and a
/// damaged known field is refused rather than erased by the next save.
@Suite struct GoalGoldenFixtureTests {
    static var fixture: Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/goals/android-written-v1.json")
        return try! Data(contentsOf: url)
    }

    static func object(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }

    @Test func androidWrittenGoalSurvivesAMacEdit() throws {
        let goal = try Goal.parse(Self.fixture)
        #expect(goal.name == "Ship the beta 🚀" && goal.startDate == "2026-12-01" && goal.targetDate == "2026-12-18")
        let edited = try GoalEdit.applyAll([.setReached(id: "cp-2", expected: false, reached: true), .link(GoalLink(type: .file, recordId: "55555555-5555-4555-8555-555555555555"))], to: goal)
        let written = try Self.object(edited.encode()), original = try Self.object(Self.fixture)
        #expect((written["future_top"] as? NSDictionary) == (original["future_top"] as? NSDictionary))
        let cps = written["checkpoints"] as! [[String: Any]], originalCps = original["checkpoints"] as! [[String: Any]]
        #expect(cps[0] as NSDictionary == originalCps[0] as NSDictionary)
        #expect(cps[1]["reached"] as? Bool == true && (cps[1]["owner"] as? NSDictionary) == (originalCps[1]["owner"] as? NSDictionary))
        let links = written["links"] as! [[String: Any]]
        #expect(links.count == 4 && links[0]["note"] as? String == "keep me" && links[1]["channel_id"] as? String == "33333333-3333-4333-8333-333333333333")
        // The edited goal reads back as what was saved.
        #expect(try Goal.parse(edited.encode()) == edited)
    }

    /// Bytes the JS agent tool really wrote to the live Goals channel (archived, three checkpoints, one reached).
    @Test func agentWrittenLiveGoalOpensOnMac() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/goals/agent-written-live-v1.json")
        let bytes = try Data(contentsOf: url)
        let goal = try Goal.parse(bytes)
        #expect(goal.status == .archived && goal.checkpoints.map(\.id) == ["cp-a", "cp-b", "cp-c"] && goal.checkpoints[0].reached && goal.startDate == "2026-11-26")
        #expect(String(decoding: goal.encode(), as: UTF8.self) == String(decoding: bytes, as: UTF8.self))
        #expect(throws: GoalError.self) { try GoalEdit.setName(expected: goal.name, value: "x").apply(to: goal) }
        #expect(try GoalEdit.setStatus(expected: .archived, value: .active).apply(to: goal).checkpoints == goal.checkpoints)
    }

    @Test func emojiNamesAreMeasuredInUTF16LikeAndroid() throws {
        #expect(try Goal.create(name: String(repeating: "🚀", count: 60), description: "d").name.utf16.count == 120)
        #expect(throws: GoalError.invalid("The name is too long.")) { try Goal.create(name: String(repeating: "🚀", count: 61), description: "d") }
    }

    @Test func damagedKnownFieldsAreRefusedNotErased() throws {
        var base = try Self.object(Self.fixture)
        func refused(_ change: (inout [String: Any]) -> Void) {
            var o = base; change(&o)
            #expect(throws: GoalError.self) { try Goal.parse(JSONSerialization.data(withJSONObject: o)) }
        }
        refused { $0["checkpoints"] = "oops" }
        refused { $0["links"] = ["x"] }
        refused { $0["name"] = 5 }
        refused { $0["description"] = ["a"] }
        refused { $0["target_date"] = 20261218 }
        refused { $0["checkpoints"] = [["id": "a", "title": "T", "reached": "yes"]] }
        refused { $0["checkpoints"] = [["id": "a", "title": 3]] }
        refused { $0["links"] = [["type": "task", "record_id": 7]] }
        refused { $0["links"] = [["type": "task", "record_id": "11111111-1111-4111-8111-111111111111", "channel_id": 1]] }
        base["future_top"] = nil
        #expect(try Goal.parse(JSONSerialization.data(withJSONObject: base)).checkpoints.count == 2)
    }
}

/// The wire path through `TowerAPI` against Tower's response shapes as seen live (a File read carries
/// `current_version: null` plus `current_version_id`; versions come from the list route).
@Suite struct GoalWireTests {
    static let workspace = "2e5caefd-dd65-45d2-b747-ee874e8e5fc9", channel = "de618067-bf70-47d5-8cd7-8b40a40ba486"
    static let file = "3e82ab7b-98f5-47f4-ad87-4657799429c5", head = "ada5aa93-d07d-4988-96ca-85f1f547ebe5", app = "npub1hd37reqgfcnz3pvzj4grknd2nkzc94p9ercmunrxx22razr2rfxsw6dns5"

    final class Tower: @unchecked Sendable {
        let lock = NSLock()
        var bytes: Data
        var saveStatus = 201
        var recordedHash: String?
        var rowHash: String?
        var uploaded: Data?
        var completed = false
        init(_ goal: Goal) { bytes = goal.encode() }

        func fileRow() -> [String: Any] {
            ["id": GoalWireTests.file, "workspace_id": GoalWireTests.workspace, "channel_id": GoalWireTests.channel, "current_version_id": GoalWireTests.head,
             "display_name": "g.goal.json", "content_type": Goal.mime, "metadata": ["goal": ["schema_version": 1]], "row_version": 3, "record_state": "active",
             "current_version": NSNull(), "created_at": "2026-11-26T07:30:00.000Z", "updated_at": "2026-11-26T07:30:00.000Z"]
        }

        func handle(_ request: URLRequest) throws -> (Int, Any) {
            let path = request.url!.path, method = request.httpMethod ?? "GET"
            let base = "/api/v4/flightdeck-pg/workspaces/\(GoalWireTests.workspace)"
            return lock.withLock {
                switch (method, path) {
                case ("GET", base + "/channels/\(GoalWireTests.channel)/files"):
                    return (200, ["files": [fileRow(), { var r = fileRow(); r["id"] = "99999999-9999-4999-8999-999999999999"; r["content_type"] = "text/plain"; return r }()], "next_cursor": NSNull()])
                case ("GET", base + "/files/\(GoalWireTests.file)"): return (200, ["file": fileRow()])
                case ("GET", base + "/files/\(GoalWireTests.file)/versions"):
                    return (200, ["file_id": GoalWireTests.file, "current_version_id": GoalWireTests.head,
                                  "versions": [["id": GoalWireTests.head, "version_number": 4, "sha256_hex": rowHash ?? SHA256Hex.of(bytes), "size_bytes": bytes.count]]])
                case ("GET", base + "/files/\(GoalWireTests.file)/versions/\(GoalWireTests.head)/object"): return (200, bytes)
                case ("POST", base + "/storage/prepare"):
                    return (200, ["object_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "is_public": false, "upload_url": "https://tower.example/api/v4/storage/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])
                case ("PUT", "/api/v4/storage/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"):
                    let body = (try? JSONSerialization.jsonObject(with: request.bodyData)) as? [String: Any]
                    uploaded = (body?["base64_data"] as? String).flatMap { Data(base64Encoded: $0) }
                    return (200, [:])
                case ("POST", "/api/v4/storage/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/complete"): completed = true; return (200, ["completed_at": "2026-11-26T07:31:00Z"])
                case ("GET", "/api/v4/storage/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"):
                    var o: [String: Any] = ["is_public": false]
                    if completed, let uploaded { o["completed_at"] = "2026-11-26T07:31:00Z"; o["sha256_hex"] = SHA256Hex.of(uploaded); o["size_bytes"] = uploaded.count }
                    return (200, o)
                case ("POST", base + "/files/\(GoalWireTests.file)/versions"):
                    let body = (try? JSONSerialization.jsonObject(with: request.bodyData)) as? [String: Any]
                    guard body?["base_version_id"] as? String == GoalWireTests.head else { return (409, ["code": "stale_base_version"]) }
                    switch saveStatus {
                    case 201: return (201, ["version": ["id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "version_number": 5, "sha256_hex": recordedHash ?? SHA256Hex.of(uploaded ?? Data())]])
                    default: return (saveStatus, ["code": "refused"])
                    }
                default: return (404, ["code": "not_found", "path": path])
                }
            }
        }
    }

    static func api(_ tower: Tower) async throws -> TowerAPI {
        let identity = try await makeIdentity()
        return TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: StubTransport { try tower.handle($0) }, signer: identity))
    }

    @Test func listsAndReadsGoalsFromTowersShapes() async throws {
        let tower = Tower(try GoalsTests.goal())
        let api = try await Self.api(tower)
        let files = try await api.goalFiles(workspaceId: Self.workspace, appNpub: Self.app, channelId: Self.channel)
        #expect(files.map(\.id) == [Self.file])   // the plain-text file is not a goal
        let doc = try await api.readGoal(workspaceId: Self.workspace, appNpub: Self.app, file: files[0])
        #expect(doc.versionId == Self.head && doc.goal.name == "Ship the beta")
        #expect(try await api.readGoal(workspaceId: Self.workspace, appNpub: Self.app, fileId: Self.file).goal == doc.goal)
    }

    @Test func aVersionWhoseBytesDoNotMatchItsHashIsRefused() async throws {
        let tower = Tower(try GoalsTests.goal())
        tower.lock.withLock { tower.rowHash = String(repeating: "0", count: 64) }
        let api = try await Self.api(tower)
        await #expect(throws: DocumentBodyError.integrity) { try await api.readGoal(workspaceId: Self.workspace, appNpub: Self.app, fileId: Self.file) }
    }

    @Test func savingPublishesAgainstTheHeadAndReportsConflictsAndRefusals() async throws {
        let goal = try GoalsTests.goal()
        let tower = Tower(goal)
        let api = try await Self.api(tower)
        let transport = api.goalTransport(workspaceId: Self.workspace, appNpub: Self.app, requireSigner: {})
        let next = try GoalEdit.setReached(id: "a", expected: false, reached: true).apply(to: goal)
        // 201 with the hash of what we sent.
        #expect(try await transport.save(Self.file, Self.head, next.encode(), "g.goal.json") == .saved(versionId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
        #expect(tower.lock.withLock { tower.uploaded } == next.encode())
        // A stale base is a conflict, not an error.
        #expect(try await transport.save(Self.file, "cccccccc-cccc-4ccc-8ccc-cccccccccccc", next.encode(), "g.goal.json") == .conflict)
        // A recorded hash that differs from what was sent is a failed save, not a success.
        tower.lock.withLock { tower.recordedHash = String(repeating: "0", count: 64) }
        await #expect(throws: GoalSaveFailed.self) { try await transport.save(Self.file, Self.head, next.encode(), "g.goal.json") }
        tower.lock.withLock { tower.recordedHash = nil; tower.saveStatus = 403 }
        #expect(try await transport.save(Self.file, Self.head, next.encode(), "g.goal.json") == .denied("You can’t change this goal."))
        tower.lock.withLock { tower.saveStatus = 503 }
        guard case .retryable = try await transport.save(Self.file, Self.head, next.encode(), "g.goal.json") else { Issue.record("expected retryable"); return }
    }

    @Test func aLockedIdentitySavesNothing() async throws {
        let tower = Tower(try GoalsTests.goal())
        let api = try await Self.api(tower)
        let transport = api.goalTransport(workspaceId: Self.workspace, appNpub: Self.app, requireSigner: { throw BoardEditError.locked })
        await #expect(throws: BoardEditError.locked) { try await transport.save(Self.file, Self.head, Data("{}".utf8), "g.goal.json") }
        #expect(tower.lock.withLock { tower.uploaded } == nil)
    }
}

private extension URLRequest {
    var bodyData: Data { httpBody ?? httpBodyStream.map { stream in
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    } ?? Data() }
}
