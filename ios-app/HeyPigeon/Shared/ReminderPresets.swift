// The "Remind me" presets — Later today (18:00), Tomorrow, This weekend,
// Next week, In a month — as dates. One place for the calendar maths so the
// Remind sheet, the Siri intent and a widget button all land on the same
// minute. Times respect a "day starts at" hour (Settings, default 09:00).

import Foundation

enum ReminderPreset: String, CaseIterable, Identifiable {
    case laterToday, tomorrow, thisWeekend, nextWeek, inAMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .laterToday: "Later today"
        case .tomorrow: "Tomorrow"
        case .thisWeekend: "This weekend"
        case .nextWeek: "Next week"
        case .inAMonth: "In a month"
        }
    }

    /// The user's "day starts at" hour; 09:00 unless Settings changed it.
    static var dayStart: Int {
        let h = UserDefaults.standard.integer(forKey: "dayStartsAtHour")
        return h == 0 ? 9 : h
    }

    /// When this preset means, from `now`. Nil for "Later today" once 18:00
    /// has passed: that row is simply not offered.
    func date(now: Date = Date(), dayStart: Int = ReminderPreset.dayStart, calendar cal: Calendar = .current) -> Date? {
        func at(_ day: Date) -> Date { cal.date(bySettingHour: dayStart, minute: 0, second: 0, of: day) ?? day }
        switch self {
        case .laterToday:
            guard let evening = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now), evening > now else { return nil }
            return evening
        case .tomorrow:
            return at(cal.date(byAdding: .day, value: 1, to: now) ?? now)
        case .thisWeekend:
            var day = now
            repeat { day = cal.date(byAdding: .day, value: 1, to: day) ?? day } while cal.component(.weekday, from: day) != 7
            return at(day)
        case .nextWeek:
            var day = now
            repeat { day = cal.date(byAdding: .day, value: 1, to: day) ?? day } while cal.component(.weekday, from: day) != 2
            return at(day)
        case .inAMonth:
            return at(cal.date(byAdding: .month, value: 1, to: now) ?? now)
        }
    }

    /// The presets worth showing right now, with their dates.
    static func available(now: Date = Date()) -> [(preset: ReminderPreset, date: Date)] {
        allCases.compactMap { p in p.date(now: now).map { (p, $0) } }
    }
}
