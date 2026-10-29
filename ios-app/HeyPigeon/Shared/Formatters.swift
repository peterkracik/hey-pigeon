// Date presentation, mirroring fmtTime / fmtFull and the desktop day groups.

import Foundation

enum Formatters {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Row time: "10:42", "Yesterday", "Mon", "Oct 3".
    static func rowTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if now.timeIntervalSince(date) < 7 * 86_400 { return weekday.string(from: date) }
        return monthDay.string(from: date)
    }

    static func fullDate(_ date: Date) -> String { full.string(from: date) }

    /// Section header for the day groups — the desktop's buckets exactly:
    /// Today · Last 7 days · Older.
    static func dayGroup(_ date: Date, now: Date = Date()) -> String {
        dayGrouper(now: now)(date)
    }

    /// `dayGroup` for a whole list: the day boundaries are worked out once,
    /// not per row (Calendar maths per row on every render added up).
    static func dayGrouper(now: Date = Date()) -> (Date) -> String {
        let startOfToday = Calendar.current.startOfDay(for: now)
        let weekAgo = startOfToday.addingTimeInterval(-7 * 86_400)
        return { date in
            if date >= startOfToday { return "Today" }
            if date >= weekAgo { return "Last 7 days" }
            return "Older"
        }
    }

    /// Scheduled view buckets.
    static func dueGroup(_ date: Date, now: Date = Date()) -> String {
        dueGrouper(now: now)(date)
    }

    /// `dueGroup` for a whole list, boundaries computed once.
    static func dueGrouper(now: Date = Date()) -> (Date) -> String {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(86_400)
        let startOfDayAfter = cal.date(byAdding: .day, value: 2, to: startOfToday) ?? startOfTomorrow.addingTimeInterval(86_400)
        let weekAhead = now.addingTimeInterval(7 * 86_400)
        return { date in
            if date < startOfToday { return "Overdue" }
            if date < startOfTomorrow { return "Today" }
            if date < startOfDayAfter { return "Tomorrow" }
            if date < weekAhead { return "This week" }
            return "Later"
        }
    }

    /// "Tomorrow 09:00", "Sat 18:00", "Oct 30, 09:00" — reminder badges.
    static func reminder(_ date: Date) -> String {
        let cal = Calendar.current
        let t = time.string(from: date)
        if cal.isDateInToday(date) { return t }
        if cal.isDateInTomorrow(date) { return "Tomorrow \(t)" }
        if date.timeIntervalSinceNow < 7 * 86_400 { return "\(weekday.string(from: date)) \(t)" }
        return "\(monthDay.string(from: date)), \(t)"
    }
}
