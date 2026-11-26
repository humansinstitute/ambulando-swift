import Foundation

/// Date-only presentation: a goal date is a calendar day with no time zone, so it never shifts between devices.
public enum GoalFormat {
    private static func display(_ value: String?, withYear: Bool, locale: Locale) -> String? {
        guard let value, let parts = Goal.parseDate(value) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: parts) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(withYear ? "d MMM yyyy" : "d MMM")
        return formatter.string(from: date)
    }

    public static func date(_ value: String?, locale: Locale = .current) -> String? { display(value, withYear: true, locale: locale) }

    /// Timeline dates drop the year when it matches `today`'s year.
    public static func short(_ value: String?, today: Date = Date(), locale: Locale = .current) -> String? {
        guard let value, let parts = Goal.parseDate(value) else { return nil }
        let year = Calendar(identifier: .gregorian).component(.year, from: today)
        return display(value, withYear: parts.year != year, locale: locale)
    }

    public static func progress(_ goal: Goal) -> String {
        let count = goal.checkpoints.count
        guard count > 0 else { return "No checkpoints yet" }
        return "\(goal.reachedCount) of \(count) checkpoint\(count == 1 ? "" : "s") reached"
    }

    /// The `yyyy-MM-dd` for a day picked in a date control (its calendar day in the user's own time zone).
    public static func string(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// The date control's value for a stored day, at local noon so no zone change moves it to another day.
    public static func controlDate(_ value: String?, calendar: Calendar = .current) -> Date? {
        guard let value, var parts = Goal.parseDate(value) else { return nil }
        parts.hour = 12
        return calendar.date(from: parts)
    }
}
