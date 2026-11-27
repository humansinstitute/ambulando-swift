import Foundation

/// Home's separately labelled current saved-goal facts. Each fact restates a saved date or checkpoint;
/// Rick's immutable daily analysis is read independently by BriefingService and never reconstructed here.
public enum GoalBriefing {
    public enum Fact: Equatable, Sendable {
        /// The first unreached checkpoint of a goal in focus (shown for today only).
        case next(goal: String, checkpoint: String, date: String?)
        /// A checkpoint dated on the day.
        case dated(goal: String, checkpoint: String, reached: Bool)
        /// An unreached checkpoint whose date has passed (shown for today only).
        case pastDate(goal: String, checkpoint: String, date: String)
        case targetDate(goal: String)
        case startDate(goal: String)
    }

    /// Facts for `day` (`yyyy-MM-dd`) from active goals in focus order; `focus` goals (the first three) give "next".
    public static func facts(_ goals: [some GoalFocusItem], day: String, today: String, focus: Int = 3) -> [Fact] {
        let active = GoalFocus.order(goals.filter { $0.goal.status == .active })
        var out: [Fact] = []
        if day == today {
            for item in active.prefix(focus) {
                if let id = item.goal.nextCheckpointId, let cp = item.goal.checkpoints.first(where: { $0.id == id }) {
                    out.append(.next(goal: item.goal.name, checkpoint: cp.title, date: cp.date))
                }
            }
        }
        for item in active {
            if item.goal.startDate == day { out.append(.startDate(goal: item.goal.name)) }
            if item.goal.targetDate == day { out.append(.targetDate(goal: item.goal.name)) }
            for cp in item.goal.checkpoints {
                if cp.date == day { out.append(.dated(goal: item.goal.name, checkpoint: cp.title, reached: cp.reached)) }
                else if day == today, !cp.reached, let date = cp.date, date < day { out.append(.pastDate(goal: item.goal.name, checkpoint: cp.title, date: date)) }
            }
        }
        return out
    }
}
