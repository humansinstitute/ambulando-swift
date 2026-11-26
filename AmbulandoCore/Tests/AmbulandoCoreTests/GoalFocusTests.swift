import Foundation
import Testing
@testable import AmbulandoCore

/// Focus order against docs/fixtures/goals/focus-order-v1.json, the fixture the JS agent tool and Android also assert.
@Suite struct GoalFocusTests {
    struct Item: GoalFocusItem { let id: String; let goal: Goal }

    static let fixture: JSONValue = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/goals/focus-order-v1.json")
        return try! JSONValue.parse(Data(contentsOf: url))
    }()

    static func items(_ value: JSONValue?) throws -> [Item] {
        try (value?.arrayValue ?? []).map { Item(id: $0["id"]!.stringValue!, goal: try Goal.parse($0["goal"]!.serialized())) }
    }
    static func string(_ value: JSONValue?) -> String? { value?.stringValue }
    static func goal(_ value: JSONValue?) throws -> Goal { try Goal.parse(Data(value!.stringValue!.utf8)) }
    static func text(_ goal: Goal) -> String { String(decoding: goal.encode(), as: UTF8.self) }

    @Test func alphabetValidityKeysAndRebalanceMatchTheFixture() throws {
        let f = Self.fixture
        #expect(String(decoding: GoalFocus.digits, as: UTF8.self) == f["digits"]?.stringValue)
        #expect(GoalFocus.maxLength == f["max_length"]?.intValue)
        for v in f["valid"]!.arrayValue! { #expect(GoalFocus.isValid(v.stringValue!)) }
        for v in f["invalid"]!.arrayValue! { if let s = v.stringValue { #expect(!GoalFocus.isValid(s), "\(s)") } }
        for c in f["between"]!.arrayValue! {
            #expect(try GoalFocus.key(between: Self.string(c["a"]), and: Self.string(c["b"])) == c["key"]?.stringValue)
        }
        for c in f["between_errors"]!.arrayValue! {
            #expect(throws: GoalError.self) { try GoalFocus.key(between: Self.string(c["a"]), and: Self.string(c["b"])) }
        }
        for c in f["even_keys"]!.arrayValue! {
            #expect(GoalFocus.evenKeys(c["n"]!.intValue!) == c["keys"]!.arrayValue!.map { $0.stringValue! })
        }
    }

    @Test func orderMatchesTheFixtureIncludingInvalidRanksAndTies() throws {
        let order = Self.fixture["order"]!
        #expect(GoalFocus.order(try Self.items(order["items"])).map(\.id) == order["expected"]!.arrayValue!.map { $0.stringValue! })
        // A rank of the wrong type is kept untouched and read as unranked.
        let numeric = try Self.items(order["items"]).first { $0.goal.name == "invalid rank number" }!
        #expect(GoalFocus.rank(numeric.goal) == nil && numeric.goal.extra[GoalFocus.field]?.intValue == 7)
    }

    @Test func movePlansMatchTheFixtureAndProduceTheRequestedOrder() throws {
        for m in Self.fixture["moves"]!.arrayValue! {
            let name = m["name"]!.stringValue!, id = m["id"]!.stringValue!, to = m["to_index"]!.intValue!
            let items = GoalFocus.order(try Self.items(m["items"]))
            let expected = m["writes"]!.arrayValue!.map { GoalFocus.Write(id: $0["id"]!.stringValue!, expected: Self.string($0["expected"]), value: $0["value"]!.stringValue!) }
            let writes = try GoalFocus.planMove(items, id: id, toIndex: to)
            #expect(writes == expected, "\(name)")
            var byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            for w in writes { byId[w.id] = Item(id: w.id, goal: try w.edit.apply(to: byId[w.id]!.goal)) }
            var wanted = items.filter { $0.id != id }.map(\.id)
            wanted.insert(id, at: min(to, wanted.count))
            #expect(GoalFocus.order(Array(byId.values)).map(\.id) == wanted, "\(name)")
        }
    }

    @Test func setFocusRankIsExpectationCheckedAndKeepsTheFieldInPlace() throws {
        let c = Self.fixture["canonical"]!
        func set(_ bytes: JSONValue?, _ expected: String?, _ value: String?) throws -> String {
            Self.text(try GoalEdit.setFocusRank(expected: expected, value: value).apply(to: try Self.goal(bytes)))
        }
        #expect(try set(c["before"], nil, "V") == c["set"]?["after"]?.stringValue)
        #expect(try set(c["set"]?["after"], "V", "k") == c["move"]?["after"]?.stringValue)
        #expect(try set(c["set"]?["after"], "V", nil) == c["clear"]?["after"]?.stringValue)
        let kept = try Self.goal(c["invalid_kept"]?["bytes"])
        #expect(Self.text(kept) == c["invalid_kept"]?["round_trip"]?.stringValue && GoalFocus.rank(kept) == nil)
        #expect(try set(c["invalid_kept"]?["bytes"], nil, "V") == c["invalid_kept"]?["replaced"]?.stringValue)
        #expect(throws: GoalError.conflict("The goal order was changed elsewhere.")) { try set(c["stale"]?["bytes"], "F", "k") }
        #expect(throws: GoalError.invalid("A focus rank is invalid.")) { try set(c["before"], nil, "V0") }
        var archived = try Self.goal(c["before"]); archived.status = .archived
        #expect(throws: GoalError.self) { try GoalEdit.setFocusRank(expected: nil, value: "V").apply(to: archived) }
        // Already in effect: accepted without a change, whatever was expected.
        #expect(try set(c["set"]?["after"], "F", "V") == c["set"]?["after"]?.stringValue)
    }
}

/// Home's Daily Briefing restates saved dates and checkpoints only.
@Suite struct GoalBriefingTests {
    struct Item: GoalFocusItem { let id: String; let goal: Goal }

    static let goals: [Item] = {
        var ship = Goal(name: "Ship", description: "d", startDate: "2026-11-26", targetDate: "2026-12-18", checkpoints: [
            GoalCheckpoint(id: "a", title: "Agree", date: "2026-11-26", reached: true),
            GoalCheckpoint(id: "b", title: "Android", date: "2026-12-05"),
            GoalCheckpoint(id: "c", title: "Users", date: "2026-12-18")])
        ship.extra = .object([(GoalFocus.field, .string("V"))])
        var run = Goal(name: "Run", description: "d", checkpoints: [GoalCheckpoint(id: "a", title: "10 km", date: "2026-11-20")])
        run.extra = .object([(GoalFocus.field, .string("l"))])
        let later = Goal(name: "Later", description: "d", targetDate: "2026-11-26", checkpoints: [GoalCheckpoint(id: "a", title: "Out of focus next")])
        let done = Goal(name: "Done", description: "d", targetDate: "2026-11-26", status: .completed)
        return [Item(id: "1", goal: ship), Item(id: "2", goal: run), Item(id: "3", goal: later), Item(id: "4", goal: done)]
    }()

    @Test func todayListsNextForGoalsInFocusDatedAndPastDates() {
        let facts = GoalBriefing.facts(Self.goals, day: "2026-11-26", today: "2026-11-26", focus: 2)
        #expect(facts == [
            .next(goal: "Ship", checkpoint: "Android", date: "2026-12-05"),
            .next(goal: "Run", checkpoint: "10 km", date: "2026-11-20"),
            .startDate(goal: "Ship"),
            .dated(goal: "Ship", checkpoint: "Agree", reached: true),
            .pastDate(goal: "Run", checkpoint: "10 km", date: "2026-11-20"),
            .targetDate(goal: "Later"),
        ])
    }

    @Test func anotherDayListsOnlyWhatIsDatedThatDay() {
        #expect(GoalBriefing.facts(Self.goals, day: "2026-12-05", today: "2026-11-26") == [.dated(goal: "Ship", checkpoint: "Android", reached: false)])
        #expect(GoalBriefing.facts(Self.goals, day: "2026-12-06", today: "2026-11-26").isEmpty)
    }
}

/// Saving a move plan (`GoalEditor.move`) against several goal Files with compare-and-swap versions.
@Suite struct GoalFocusMoveTests {
    struct Item: GoalFocusItem { let id: String; let goal: Goal }

    actor Files {
        var versions: [String: [(id: String, bytes: Data)]] = [:]
        var deleted: Set<String> = []
        /// (file id, base version) of every save attempt, in order.
        var attempts: [(file: String, base: String)] = []
        /// Runs once just before the first save attempt on that file, to let "another device" act.
        var before: [String: @Sendable (Files) async -> Void] = [:]

        init(_ goals: [(String, Goal)]) { for (id, g) in goals { versions[id] = [(UUID().uuidString.lowercased(), g.encode())] } }
        func setBefore(_ id: String, _ f: @escaping @Sendable (Files) async -> Void) { before[id] = f }
        func delete(_ id: String) { deleted.insert(id) }
        func force(_ id: String, _ edit: GoalEdit) throws {
            let next = try edit.apply(to: Goal.parse(versions[id]!.last!.bytes))
            versions[id]!.append((UUID().uuidString.lowercased(), next.encode()))
        }
        func goal(_ id: String) throws -> Goal { try Goal.parse(versions[id]!.last!.bytes) }
        func read(_ id: String) throws -> (String, Data) {
            guard !deleted.contains(id), let head = versions[id]?.last else { throw GoalError.conflict("This goal is no longer available to you.") }
            return head
        }
        func save(_ id: String, base: String, bytes: Data) async -> GoalSaveOutcome {
            attempts.append((id, base))
            if let f = before.removeValue(forKey: id) { await f(self) }
            if deleted.contains(id) { return .denied("This goal is no longer available to you.") }
            guard versions[id]!.last!.id == base else { return .conflict }
            let version = UUID().uuidString.lowercased()
            versions[id]!.append((version, bytes))
            return .saved(versionId: version)
        }
        nonisolated func transport() -> GoalTransport {
            GoalTransport(
                read: { id in
                    let (version, bytes) = try await self.read(id)
                    let file = FileRecord(workspaceId: "w", id: id, scopeId: nil, channelId: "c", folderId: nil, storageObjectId: nil, displayName: "g",
                                          contentType: Goal.mime, sizeBytes: nil, sha256: nil, createdAt: "", updatedAt: "")
                    return GoalDocument(file: file, versionId: version, goal: try Goal.parse(bytes))
                },
                save: { id, base, bytes, _ in await self.save(id, base: base, bytes: bytes) })
        }
    }

    static func goal(_ name: String, target: String) -> Goal { Goal(name: name, description: "d", targetDate: target) }
    static let ids = ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-000000000003"]
    static func allUnranked() -> [(String, Goal)] {
        [(ids[0], goal("one", target: "2027-01-01")), (ids[1], goal("two", target: "2027-02-01")), (ids[2], goal("three", target: "2027-03-01"))]
    }
    static func items(_ files: Files) async throws -> [Item] {
        var out: [Item] = []
        for id in ids { out.append(Item(id: id, goal: try await files.goal(id))) }
        return GoalFocus.order(out)
    }

    @Test func allUnrankedBottomToMiddleWritesThePrefixEachAgainstItsHead() async throws {
        let files = Files(Self.allUnranked())
        let plan = try GoalFocus.planMove(try await Self.items(files), id: Self.ids[2], toIndex: 1)
        #expect(plan == [GoalFocus.Write(id: Self.ids[0], expected: nil, value: "V"), GoalFocus.Write(id: Self.ids[2], expected: nil, value: "l")])
        let heads = [try await files.read(Self.ids[0]).0, try await files.read(Self.ids[2]).0]
        let saved = try await GoalEditor.move(files.transport(), writes: plan)
        #expect(saved.map(\.id) == [Self.ids[0], Self.ids[2]])
        let attempts = await files.attempts
        #expect(attempts.map(\.file) == [Self.ids[0], Self.ids[2]] && attempts.map(\.base) == heads, "one save per write, each against that goal's head")
        let order = try await Self.items(files).map(\.id)
        #expect(order == [Self.ids[0], Self.ids[2], Self.ids[1]])
    }

    @Test func aStaleRankMidBatchStopsWithoutRetryingThePlan() async throws {
        let files = Files(Self.allUnranked())
        let plan = try GoalFocus.planMove(try await Self.items(files), id: Self.ids[2], toIndex: 1)
        // Before the second write lands, another device ranks that goal.
        await files.setBefore(Self.ids[2]) { f in try? await f.force(Self.ids[2], .setFocusRank(expected: nil, value: "8")) }
        do {
            _ = try await GoalEditor.move(files.transport(), writes: plan)
            Issue.record("expected the move to stop")
        } catch let failed as GoalFocusMoveFailed {
            #expect(failed.saved.map(\.id) == [Self.ids[0]] && failed.total == 2)
            #expect(failed.errorDescription == "Saved 1 of 2 order changes. The goal order was changed elsewhere.")
        }
        // The conflicting save was re-read once (CAS), then refused by its expectation; the plan was not retried.
        let attempts = await files.attempts
        #expect(attempts.map(\.file) == [Self.ids[0], Self.ids[2]])
        let second = try await files.goal(Self.ids[2]), first = try await files.goal(Self.ids[0])
        #expect(GoalFocus.rank(second) == "8" && GoalFocus.rank(first) == "V")
    }

    @Test func aGoalDeletedMidBatchStopsTheMove() async throws {
        let files = Files(Self.allUnranked())
        let plan = try GoalFocus.planMove(try await Self.items(files), id: Self.ids[0], toIndex: 2)
        #expect(plan.count == 3)
        await files.setBefore(Self.ids[2]) { f in await f.delete(Self.ids[2]) }
        do {
            _ = try await GoalEditor.move(files.transport(), writes: plan)
            Issue.record("expected the move to stop")
        } catch let failed as GoalFocusMoveFailed {
            #expect(failed.saved.map(\.id) == [Self.ids[1]] && failed.total == 3)
            #expect(failed.errorDescription == "Saved 1 of 3 order changes. This goal is no longer available to you.")
        }
        let attempted = await files.attempts.map(\.file)
        #expect(attempted == [Self.ids[1], Self.ids[2]], "nothing after the refused write is attempted")
        let moved = try await files.goal(Self.ids[0])
        #expect(GoalFocus.rank(moved) == nil, "the moved goal is untouched")
    }

    @Test func aFirstWriteRefusalSavesNothingAndSaysWhy() async throws {
        let files = Files(Self.allUnranked())
        let plan = try GoalFocus.planMove(try await Self.items(files), id: Self.ids[2], toIndex: 0)
        await files.setBefore(Self.ids[2]) { f in try? await f.force(Self.ids[2], .setFocusRank(expected: nil, value: "z")) }
        await #expect(throws: GoalFocusMoveFailed.self) { try await GoalEditor.move(files.transport(), writes: plan) }
        do { _ = try await GoalEditor.move(files.transport(), writes: plan) }
        catch let failed as GoalFocusMoveFailed { #expect(failed.saved.isEmpty && failed.errorDescription == "The goal order was changed elsewhere.") }
    }
}
