import Foundation
import SwiftUI

/// A calendar day in the user's time zone, used to place date separators in chat.
struct ChatDay: Sendable, Hashable {
    let year: Int, month: Int, day: Int

    init?(iso: String) {
        guard let date = ChatTime.date(iso) else { return nil }
        self.init(date: date)
    }

    init(date: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        year = c.year ?? 0; month = c.month ?? 0; day = c.day ?? 0
    }

    static var today: ChatDay { ChatDay(date: Date()) }

    /// Which rows start a new day (by row id) and the day of the last row. Computed with the snapshot, off the main
    /// actor; a separator is a label above the first message of each day, never a line between messages.
    static func breaks<Row>(_ rows: [Row], id: (Row) -> String, time: (Row) -> String) -> (starts: [String: ChatDay], last: ChatDay?) {
        var starts: [String: ChatDay] = [:]
        var previous: ChatDay?
        for row in rows {
            guard let day = ChatDay(iso: time(row)) else { continue }
            if day != previous { starts[id(row)] = day }
            previous = day
        }
        return (starts, previous)
    }

    /// "Today", "Yesterday", a weekday within the last week, otherwise the date (with the year if it is not this year).
    var label: String {
        var parts = DateComponents(); parts.year = year; parts.month = month; parts.day = day
        let calendar = Calendar.current
        guard let date = calendar.date(from: parts) else { return "" }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        if days > 0 && days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if year == calendar.component(.year, from: Date()) { return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// Date label between the last message of one day and the first of the next.
struct DaySeparator: View {
    let day: ChatDay
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Amb.border).frame(height: 1)
            Text(day.label).font(.amb(.caption).weight(.semibold)).foregroundStyle(Amb.mutedForeground).fixedSize()
            Rectangle().fill(Amb.border).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("chat.day")
    }
}

/// The rule between a thread's first message and its replies (sol `.thread-message` border), labelled with the count.
struct RepliesRule: View {
    let count: Int
    var body: some View {
        HStack(spacing: 10) {
            Text("\(count) \(count == 1 ? "reply" : "replies")")
                .font(.amb(.caption).weight(.bold)).foregroundStyle(Amb.primary).fixedSize()
            Rectangle().fill(Amb.border).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("thread.repliesRule")
    }
}

/// One conversation in a channel's message list, drawn as the web's `.channel-thread-card`: a bordered panel on the
/// page surface with a gap to the next. The border, not a line under every message, separates conversations.
struct ConversationCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 4)
            .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel, style: .continuous).stroke(Amb.border, lineWidth: 1))
            .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

extension View {
    func conversationCard() -> some View { modifier(ConversationCard()) }
}
