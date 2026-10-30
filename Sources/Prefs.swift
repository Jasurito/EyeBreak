import Foundation

/// Settings and daily stats, stored in UserDefaults.
///
/// Intervals can be overridden for testing, e.g.
/// `open EyeBreak.app --args -workSeconds 15 -breakSeconds 5`
enum Prefs {
    private static let defaults = UserDefaults.standard

    /// Screen time between breaks.
    static var workInterval: TimeInterval {
        get { positive("workSeconds") ?? 20 * 60 }
        set { defaults.set(newValue, forKey: "workSeconds") }
    }
    static var breakDuration: Int { Int(positive("breakSeconds") ?? 20) }
    static var snoozeInterval: TimeInterval { positive("snoozeSeconds") ?? 5 * 60 }

    static var soundEnabled: Bool {
        get { defaults.object(forKey: "soundEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "soundEnabled") }
    }

    /// Set once the app has made its first-launch attempt to register as a login item,
    /// so turning "Start at Login" off later sticks.
    static var loginItemConfigured: Bool {
        get { defaults.bool(forKey: "loginItemConfigured") }
        set { defaults.set(newValue, forKey: "loginItemConfigured") }
    }

    static var breaksToday: Int {
        defaults.string(forKey: "statsDay") == today ? defaults.integer(forKey: "statsCount") : 0
    }

    static func recordBreak() {
        let count = breaksToday + 1
        defaults.set(today, forKey: "statsDay")
        defaults.set(count, forKey: "statsCount")
    }

    private static var today: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func positive(_ key: String) -> TimeInterval? {
        let value = defaults.double(forKey: key)
        return value > 0 ? value : nil
    }
}
