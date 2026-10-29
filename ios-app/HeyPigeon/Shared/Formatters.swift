// Date presentation, mirroring fmtTime / fmtFull and the desktop day groups.
// The formatters are built once (DateFormatter is expensive to make) and
// follow the user's locale and time zone; everything that depends on
// "today" takes a `now` so the tests can pin it.

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

    /// Row time: "10:42", "Yesterday", "Mon", "Oct 3". Every comparison is
    /// against `now` (it used to read the clock for today / yesterday and
    /// `now` only for the week, so a test's `now` was half ignored).
    static func rowTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
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

    /// "09:00" (today), "Tomorrow 09:00", "Sat 18:00", "Oct 30, 09:00" —
    /// reminder badges, relative to `now`.
    static func reminder(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let t = time.string(from: date)
        if cal.isDate(date, inSameDayAs: now) { return t }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(t)"
        }
        if date.timeIntervalSince(now) < 7 * 86_400 { return "\(weekday.string(from: date)) \(t)" }
        return "\(monthDay.string(from: date)), \(t)"
    }
}
