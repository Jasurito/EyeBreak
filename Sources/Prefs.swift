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
    /// Length of a break, in seconds.
    static var breakDuration: Int {
        get { Int(positive("breakSeconds") ?? 20) }
        set { defaults.set(newValue, forKey: "breakSeconds") }
    }
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

    static func soundID(for event: String) -> String? {
        defaults.string(forKey: "sound.\(event)")
    }

    static func setSoundID(_ id: String, for event: String) {
        defaults.set(id, forKey: "sound.\(event)")
    }

    // MARK: - Eye drops

    static var dropsEnabled: Bool {
        get { defaults.bool(forKey: "dropsEnabled") }
        set { defaults.set(newValue, forKey: "dropsEnabled") }
    }

    static var dropDoses: [DropDose] {
        get { decoded("dropDoses") ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "dropDoses") }
    }

    /// As typed in Settings, so it can be empty mid-edit. Reminders use `dropMessage`.
    static var dropMessageText: String {
        get { defaults.string(forKey: "dropMessage") ?? DropMessage.standard }
        set { defaults.set(newValue, forKey: "dropMessage") }
    }

    static var dropMessage: String { DropMessage.clean(dropMessageText) }

    /// Messages you saved, on top of `DropMessage.templates`.
    static var messageTemplates: [String] {
        get { defaults.stringArray(forKey: "messageTemplates") ?? [] }
        set { defaults.set(newValue, forKey: "messageTemplates") }
    }

    /// Saved rather than kept in memory so doses missed while the app wasn't running
    /// (Mac off or asleep) still count.
    static var dropsLastChecked: Date? {
        get { defaults.object(forKey: "dropsLastChecked") as? Date }
        set { defaults.set(newValue, forKey: "dropsLastChecked") }
    }

    /// Doses waiting for you to press Done.
    static var dropsDue: [Date] {
        get { defaults.array(forKey: "dropsDue") as? [Date] ?? [] }
        set { defaults.set(newValue, forKey: "dropsDue") }
    }

    static var dropsSnoozedUntil: Date? {
        get { defaults.object(forKey: "dropsSnoozedUntil") as? Date }
        set { defaults.set(newValue, forKey: "dropsSnoozedUntil") }
    }

    // MARK: - Telegram (the bot token is in the Keychain, see TelegramToken)

    static var telegramEnabled: Bool {
        get { defaults.bool(forKey: "telegramEnabled") }
        set { defaults.set(newValue, forKey: "telegramEnabled") }
    }

    static var telegramChatID: String {
        get { defaults.string(forKey: "telegramChatID") ?? "" }
        set { defaults.set(newValue, forKey: "telegramChatID") }
    }

    /// Doses not yet delivered to Telegram, kept until a send succeeds.
    static var telegramQueue: [Date] {
        get { defaults.array(forKey: "telegramQueue") as? [Date] ?? [] }
        set { defaults.set(newValue, forKey: "telegramQueue") }
    }

    static var telegramSender: TelegramSender {
        get { defaults.string(forKey: "telegramSender").flatMap(TelegramSender.init) ?? .local }
        set { defaults.set(newValue.rawValue, forKey: "telegramSender") }
    }

    static var serverConnection: ServerConnection {
        get { decoded("serverConnection") ?? ServerConnection() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "serverConnection") }
    }

    /// What's on the server right now, nil if nothing is.
    static var serverInstalled: ServerInstall? {
        get { decoded("serverInstalled") }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "serverInstalled") }
    }

    // MARK: - Stats

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

    private static func decoded<Value: Decodable>(_ key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    private static func positive(_ key: String) -> TimeInterval? {
        let value = defaults.double(forKey: key)
        return value > 0 ? value : nil
    }
}
