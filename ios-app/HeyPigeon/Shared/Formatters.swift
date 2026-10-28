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
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        if date >= startOfToday { return "Today" }
        if date >= startOfToday.addingTimeInterval(-7 * 86_400) { return "Last 7 days" }
        return "Older"
    }

    /// Scheduled view buckets.
    static func dueGroup(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if date < cal.startOfDay(for: now) { return "Overdue" }
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if date.timeIntervalSince(now) < 7 * 86_400 { return "This week" }
        return "Later"
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
