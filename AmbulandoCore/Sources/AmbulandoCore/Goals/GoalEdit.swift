import Foundation

/// One user or agent change to a goal, expressed against the values the editor was looking at. A save that loses a
/// compare-and-swap race re-applies its edits to the newest version: an edit whose expectation no longer holds throws
/// `GoalError.conflict` instead of overwriting someone else's change. Edits already in effect are accepted (idempotent).
public enum GoalEdit: Sendable, Equatable {
    case setName(expected: String, value: String)
    case setDescription(expected: String, value: String)
    case setStartDate(expected: String?, value: String?)
    case setTargetDate(expected: String?, value: String?)
    /// Completing is explicit and reversible; archiving keeps every checkpoint and link, and linked work is never touched.
    case setStatus(expected: GoalStatus, value: GoalStatus)
    /// Appended, or placed after `afterId` when that checkpoint still exists.
    case addCheckpoint(GoalCheckpoint, afterId: String? = nil)
    /// Replaces title, date and description; `reached` is never changed here.
    case updateCheckpoint(id: String, expected: GoalCheckpoint, value: GoalCheckpoint)
    case setReached(id: String, expected: Bool, reached: Bool)
    case removeCheckpoint(id: String)
    /// Moves a checkpoint to `toIndex` among the checkpoints that remain (clamped).
    case moveCheckpoint(id: String, toIndex: Int)
    case setDefaultChannel(expected: String?, value: String?)
    case pin(GoalLink)
    case unpin(GoalLinkType, recordId: String)
    case link(GoalLink)
    /// Removes only the reference; the source record, its location and its access are untouched.
    case unlink(GoalLinkType, recordId: String)
    /// Sets or clears the goal's focus rank (see `GoalFocus`); `expected` is the valid rank the editor saw, or `nil`.
    case setFocusRank(expected: String?, value: String?)

    public func apply(to goal: Goal) throws -> Goal {
        switch self {
        case .setName(let expected, let value):
            return try goal.setting("name", goal.name, expected, value.trimmingCharacters(in: .whitespacesAndNewlines)) { $0.name = $1 }
        case .setDescription(let expected, let value):
            return try goal.setting("description", goal.description, expected, value.trimmingCharacters(in: .whitespacesAndNewlines)) { $0.description = $1 }
        case .setStartDate(let expected, let value):
            return try goal.setting("start date", goal.startDate, expected, value.blankToNil) { $0.startDate = $1 }
        case .setTargetDate(let expected, let value):
            return try goal.setting("target date", goal.targetDate, expected, value.blankToNil) { $0.targetDate = $1 }
        case .setStatus(let expected, let value):
            if goal.status == value { return goal }
            guard goal.status == expected else { throw GoalError.conflict("This goal was \(goal.status.rawValue) elsewhere.") }
            var next = goal; next.status = value
            return try next.validated()
        case .addCheckpoint(let checkpoint, let afterId):
            try goal.requireEditable()
            if goal.checkpoints.contains(where: { $0.id == checkpoint.id }) { return goal }
            var next = goal
            let at = goal.checkpoints.firstIndex { $0.id == afterId }.map { $0 + 1 } ?? goal.checkpoints.count
            next.checkpoints.insert(checkpoint, at: at)
            return try next.validated()
        case .updateCheckpoint(let id, let expected, let value):
            try goal.requireEditable()
            guard let index = goal.checkpoints.firstIndex(where: { $0.id == id }) else { throw GoalError.conflict("That checkpoint was removed elsewhere.") }
            let current = goal.checkpoints[index]
            var next = current
            next.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines); next.date = value.date.blankToNil; next.description = value.description.blankToNil
            func body(_ c: GoalCheckpoint) -> [String?] { [c.title, c.date, c.description] }
            if body(current) == body(next) { return goal }
            guard body(current) == body(expected.normalizedBody) else { throw GoalError.conflict("“\(current.title)” was changed elsewhere.") }
            var out = goal; out.checkpoints[index] = next
            return try out.validated()
        case .setReached(let id, let expected, let reached):
            try goal.requireEditable()
            guard let index = goal.checkpoints.firstIndex(where: { $0.id == id }) else { throw GoalError.conflict("That checkpoint was removed elsewhere.") }
            let current = goal.checkpoints[index]
            if current.reached == reached { return goal }
            guard current.reached == expected else { throw GoalError.conflict("“\(current.title)” was changed elsewhere.") }
            var out = goal; out.checkpoints[index].reached = reached
            return out
        case .removeCheckpoint(let id):
            try goal.requireEditable()
            var out = goal; out.checkpoints.removeAll { $0.id == id }
            return out
        case .moveCheckpoint(let id, let toIndex):
            try goal.requireEditable()
            guard let item = goal.checkpoints.first(where: { $0.id == id }) else { throw GoalError.conflict("That checkpoint was removed elsewhere.") }
            var out = goal
            out.checkpoints.removeAll { $0.id == id }
            out.checkpoints.insert(item, at: min(max(toIndex, 0), out.checkpoints.count))
            return out
        case .setDefaultChannel(let expected, let value):
            return try goal.setting("default channel", goal.defaultChannelId, expected, value) { $0.defaultChannelId = $1 }
        case .pin(let link):
            try goal.requireEditable()
            if goal.pinnedRefs.contains(where: { $0.key == link.key }) { return goal }
            var out = goal; out.pinnedRefs.append(link)
            return try out.validated()
        case .unpin(let type, let recordId):
            try goal.requireEditable()
            var out = goal; out.pinnedRefs.removeAll { $0.type == type && $0.recordId == recordId }
            return out
        case .link(let link):
            try goal.requireEditable()
            if goal.links.contains(where: { $0.key == link.key }) { return goal }
            var out = goal; out.links.append(link)
            return try out.validated()
        case .unlink(let type, let recordId):
            try goal.requireEditable()
            var out = goal; out.links.removeAll { $0.type == type && $0.recordId == recordId.lowercased() }
            return out
        case .setFocusRank(let expected, let value):
            try goal.requireEditable()
            if let value, !GoalFocus.isValid(value) { throw GoalError.invalid("A focus rank is invalid.") }
            let current = GoalFocus.rank(goal)
            if current == value { return goal }
            guard current == expected else { throw GoalError.conflict("The goal order was changed elsewhere.") }
            return GoalFocus.setting(goal, value)
        }
    }

    public static func applyAll(_ edits: [GoalEdit], to goal: Goal) throws -> Goal {
        try edits.reduce(goal) { try $1.apply(to: $0) }
    }
}

private extension GoalCheckpoint {
    /// The expectation compared the way stored values are normalised.
    var normalizedBody: GoalCheckpoint {
        var c = self
        c.title = title.trimmingCharacters(in: .whitespacesAndNewlines); c.date = date.blankToNil; c.description = description.blankToNil
        return c
    }
}

private extension Goal {
    func requireEditable() throws {
        if status == .archived { throw GoalError.conflict("This goal is archived. Restore it to change it.") }
    }

    func setting<T: Equatable>(_ label: String, _ current: T, _ expected: T, _ next: T, _ write: (inout Goal, T) -> Void) throws -> Goal {
        try requireEditable()
        if current == next { return self }
        guard current == expected else { throw GoalError.conflict("The \(label) was changed elsewhere.") }
        var out = self; write(&out, next)
        return try out.validated()
    }
}
