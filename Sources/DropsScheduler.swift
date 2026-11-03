import Foundation

@MainActor
protocol DropsSchedulerDelegate: AnyObject {
    /// `times` is every dose waiting for you. Empty means nothing should be showing.
    func dropsScheduler(_ scheduler: DropsScheduler, didUpdateDue times: [Date])
}

/// Fires eye drop reminders.
///
/// A dose comes due in two stages: a local Telegram alert goes out as soon as the app can run,
/// and the popup waits until you're at the Mac. Both are saved, so a dose missed with the
/// lid closed shows up right after you log in, and a Telegram alert that fails is retried.
/// When your server sends the alerts instead, see `ServerSync`, this only handles the popup.
@MainActor
final class DropsScheduler: NSObject {
    static let snoozeInterval: TimeInterval = 10 * 60
    private static let firstRetryDelay: TimeInterval = 30
    private static let maxRetryDelay: TimeInterval = 15 * 60

    weak var delegate: DropsSchedulerDelegate?
    /// False while the screen is locked or the Mac is asleep: nobody would see a popup.
    var isPresent: () -> Bool = { true }

    /// One line for the menu, or nil when eye drops are off.
    private(set) var statusLine: String?
    private(set) var lastTelegramError: String?

    private var timer: Timer?
    private var isSending = false
    private var nextSendAttempt = Date.distantPast
    private var retryDelay = firstRetryDelay

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    func start() {
        let timer = Timer(timeInterval: 5, target: self, selector: #selector(timerFired),
                          userInfo: nil, repeats: true)
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    @objc private func timerFired() {
        check()
    }

    func check() {
        let now = Date()
        if Prefs.dropsEnabled {
            let newlyDue = DropSchedule.dueTimes(of: Prefs.dropDoses, lastChecked: Prefs.dropsLastChecked, now: now)
            if !newlyDue.isEmpty {
                Prefs.dropsDue += newlyDue
                Prefs.dropsSnoozedUntil = nil
                Prefs.telegramQueue += newlyDue
            }
        }
        Prefs.dropsLastChecked = now

        if let until = Prefs.dropsSnoozedUntil, now >= until {
            Prefs.dropsSnoozedUntil = nil
            Prefs.telegramQueue = Prefs.dropsDue
        }

        if isPresent(), Prefs.dropsSnoozedUntil == nil {
            delegate?.dropsScheduler(self, didUpdateDue: Prefs.dropsDue)
        }
        updateStatusLine(now: now)
        sendTelegramAlert(now: now)
    }

    func markDone() {
        clearDue()
    }

    func snooze() {
        Prefs.dropsSnoozedUntil = Date().addingTimeInterval(Self.snoozeInterval)
        Prefs.telegramQueue = []
        delegate?.dropsScheduler(self, didUpdateDue: [])
        updateStatusLine(now: Date())
    }

    /// Call after the schedule or the on/off setting changes.
    func settingsChanged() {
        if !Prefs.dropsEnabled { clearDue() }
        updateStatusLine(now: Date())
    }

    private func clearDue() {
        Prefs.dropsDue = []
        Prefs.dropsSnoozedUntil = nil
        Prefs.telegramQueue = []
        delegate?.dropsScheduler(self, didUpdateDue: [])
        updateStatusLine(now: Date())
    }

    private func updateStatusLine(now: Date) {
        if !Prefs.dropsEnabled {
            statusLine = nil
        } else if let until = Prefs.dropsSnoozedUntil {
            statusLine = "Eye drops snoozed until \(DropSchedule.timeFormatter.string(from: until))"
        } else if !Prefs.dropsDue.isEmpty {
            statusLine = "Eye drops due"
        } else if let next = DropSchedule.next(of: Prefs.dropDoses, after: now) {
            statusLine = "Next eye drops: \(dayFormatter.string(from: next))"
        } else {
            statusLine = "No eye drop times set"
        }
    }

    private func sendTelegramAlert(now: Date) {
        let queue = Prefs.telegramQueue
        guard !queue.isEmpty else { return }
        let chatID = Prefs.telegramChatID
        guard Prefs.telegramEnabled, Prefs.telegramSender == .local, !chatID.isEmpty, TelegramToken.isSaved else {
            Prefs.telegramQueue = []
            return
        }
        guard !isSending, now >= nextSendAttempt else { return }

        isSending = true
        Task {
            do {
                guard let token = await Task.detached(operation: { TelegramToken.read() }).value else {
                    throw Telegram.Failure.noToken
                }
                let text = "💧 " + DropSchedule.summary(of: queue, now: Date(), message: Prefs.dropMessage)
                try await Telegram.send(text, token: token, chatID: chatID)
                Prefs.telegramQueue.removeAll(where: queue.contains)
                lastTelegramError = nil
                retryDelay = Self.firstRetryDelay
            } catch {
                // Usually the network isn't back yet right after waking. Backing off also
                // keeps a declined Keychain prompt from coming straight back.
                lastTelegramError = error.localizedDescription
                nextSendAttempt = Date().addingTimeInterval(retryDelay)
                retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
            }
            isSending = false
        }
    }
}
