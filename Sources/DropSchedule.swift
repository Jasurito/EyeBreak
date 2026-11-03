import Foundation

/// One scheduled eye drop time.
struct DropDose: Codable, Identifiable, Equatable {
    var id = UUID()
    var hour: Int
    var minute: Int
    /// Calendar weekdays: 1 is Sunday, 7 is Saturday.
    var weekdays: Set<Int> = Set(1...7)
}

/// What an eye drop reminder says.
enum DropMessage {
    static let standard = "Time for your eye drops"
    static let templates = [
        standard,
        "Don't forget your eye drops",
        "Eye drops now, please",
        "Eye drops, then rest your eyes for a minute",
    ]
    static let maxLength = 200

    /// One line of sensible length, or the default if nothing is left.
    static func clean(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? standard : String(line.prefix(maxLength))
    }
}

/// Works out when eye drops are due. Nothing here depends on the app running on time:
/// comparing against the last check is what lets doses missed during sleep catch up.
enum DropSchedule {
    /// A reminder older than this isn't worth showing, however long the Mac was closed.
    static let catchUpWindow: TimeInterval = 24 * 60 * 60

    /// A reminder within this long of its scheduled time counts as on time.
    private static let onTimeTolerance: TimeInterval = 2 * 60

    /// Doses that came due since the last check. `lastChecked` is nil on the very first run,
    /// so times earlier today don't fire the moment a schedule is created.
    static func dueTimes(of doses: [DropDose], lastChecked: Date?, now: Date,
                         calendar: Calendar = .current) -> [Date] {
        guard let lastChecked else { return [] }
        let start = max(lastChecked, now.addingTimeInterval(-catchUpWindow))
        return occurrences(of: doses, after: start, through: now, calendar: calendar)
    }

    /// The first dose after `date`, looking a week ahead so every weekday is covered.
    static func next(of doses: [DropDose], after date: Date, calendar: Calendar = .current) -> Date? {
        let end = date.addingTimeInterval(8 * 24 * 60 * 60)
        return occurrences(of: doses, after: date, through: end, calendar: calendar).first
    }

    /// Scheduled times after `start`, up to and including `end`, oldest first.
    /// Doses at the same time count once.
    static func occurrences(of doses: [DropDose], after start: Date, through end: Date,
                            calendar: Calendar = .current) -> [Date] {
        guard start < end else { return [] }
        var times = Set<Date>()
        var day = calendar.startOfDay(for: start)
        while day <= end {
            let weekday = calendar.component(.weekday, from: day)
            for dose in doses where dose.weekdays.contains(weekday) {
                if let time = calendar.date(bySettingHour: dose.hour, minute: dose.minute, second: 0, of: day),
                   time > start, time <= end {
                    times.insert(time)
                }
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        return times.sorted()
    }

    /// Reminder text for the popup and Telegram. Late reminders list the missed times,
    /// and keep a custom message underneath because it may say which drops to use.
    static func summary(of times: [Date], now: Date, message: String = DropMessage.standard,
                        formatter: DateFormatter = timeFormatter) -> String {
        if times.count == 1, now.timeIntervalSince(times[0]) < onTimeTolerance {
            return message
        }
        let overdue = "Eye drops overdue: " + times.map { formatter.string(from: $0) }.joined(separator: ", ")
        return message == DropMessage.standard ? overdue : "\(overdue)\n\(message)"
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
