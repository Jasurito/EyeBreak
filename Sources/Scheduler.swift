import AppKit
import IOKit.pwr_mgt

@MainActor
protocol SchedulerDelegate: AnyObject {
    func schedulerDidUpdate(_ scheduler: Scheduler)
    func schedulerShouldStartBreak(_ scheduler: Scheduler)
}

enum BreakOutcome {
    case completed, skipped, snoozed
}

/// Counts down screen time and decides when a break is due.
///
/// Time only counts while you're at the screen. Being away (screen locked, Mac asleep,
/// or no input for `idleThreshold`) for at least as long as a break counts as a rest, so
/// the countdown starts over when you come back.
@MainActor
final class Scheduler: NSObject {
    /// No keyboard or mouse input for this long means you've stepped away.
    static let idleThreshold: TimeInterval = 5 * 60

    enum State: Equatable {
        case working
        case away
        case onBreak
        case paused(until: Date?)
    }

    weak var delegate: SchedulerDelegate?
    private(set) var state: State = .working
    private(set) var remaining: TimeInterval = Prefs.workInterval

    private var timer: Timer?
    private var lastTick = Date()
    private var awaySince: Date?
    private var screenLocked = false
    private var displayAsleep = false
    private var systemAsleep = false
    private var activity: NSObjectProtocol?

    func start() {
        // A menu bar app with no windows gets App Nap'd, which would delay the timer by minutes.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "20-20-20 break timer")

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock),
                                name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenDidUnlock),
                                name: .init("com.apple.screenIsUnlocked"), object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake),
                              name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displayDidSleep),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displayDidWake),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)

        lastTick = Date()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick),
                          userInfo: nil, repeats: true)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        delegate?.schedulerDidUpdate(self)
    }

    // MARK: - Actions

    func breakNow() {
        guard state != .onBreak else { return }
        startBreak()
    }

    func finishBreak(_ outcome: BreakOutcome) {
        remaining = outcome == .snoozed ? Prefs.snoozeInterval : Prefs.workInterval
        state = .working
        lastTick = Date()
        delegate?.schedulerDidUpdate(self)
    }

    func restart() {
        remaining = Prefs.workInterval
        delegate?.schedulerDidUpdate(self)
    }

    /// Pass `nil` to pause until `resume()` is called.
    func pause(for duration: TimeInterval?) {
        guard state != .onBreak else { return }
        state = .paused(until: duration.map { Date().addingTimeInterval($0) })
        delegate?.schedulerDidUpdate(self)
    }

    func resume() {
        remaining = Prefs.workInterval
        state = .working
        awaySince = nil
        lastTick = Date()
        delegate?.schedulerDidUpdate(self)
    }

    // MARK: - Timer

    @objc private func tick() {
        let now = Date()
        let elapsed = min(now.timeIntervalSince(lastTick), 10)
        lastTick = now

        switch state {
        case .onBreak:
            return
        case .paused(let until):
            if let until, now >= until { resume() }
        case .away:
            if !isAway { comeBack(at: now) }
        case .working:
            if isAway {
                goAway(since: isLockedOrAsleep ? now : now.addingTimeInterval(-idleSeconds))
            } else {
                remaining -= elapsed
                if remaining <= 0 { startBreak() }
            }
        }
        delegate?.schedulerDidUpdate(self)
    }

    private func startBreak() {
        state = .onBreak
        delegate?.schedulerDidUpdate(self)
        delegate?.schedulerShouldStartBreak(self)
    }

    private func goAway(since: Date) {
        awaySince = since
        state = .away
    }

    private func comeBack(at now: Date) {
        if let awaySince, now.timeIntervalSince(awaySince) >= TimeInterval(Prefs.breakDuration) {
            remaining = Prefs.workInterval
        }
        awaySince = nil
        state = .working
    }

    // MARK: - Presence detection

    private var isLockedOrAsleep: Bool { screenLocked || displayAsleep || systemAsleep }

    private var isAway: Bool {
        isLockedOrAsleep || (idleSeconds >= Self.idleThreshold && !isDisplaySleepBlocked)
    }

    private var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0)!)
    }

    /// True while something (usually a video player) is keeping the display awake.
    /// You're likely watching the screen then, even without touching keyboard or mouse.
    private var isDisplaySleepBlocked: Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let dict = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (dict["PreventUserIdleDisplaySleep"] ?? 0) > 0
    }

    private func lockStateChanged() {
        if isLockedOrAsleep, state == .working {
            goAway(since: Date())
        }
        tick()
    }

    @objc private func screenDidLock(_ note: Notification) { screenLocked = true; lockStateChanged() }
    @objc private func screenDidUnlock(_ note: Notification) { screenLocked = false; lockStateChanged() }
    @objc private func systemWillSleep(_ note: Notification) { systemAsleep = true; lockStateChanged() }
    @objc private func systemDidWake(_ note: Notification) { systemAsleep = false; lockStateChanged() }
    @objc private func displayDidSleep(_ note: Notification) { displayAsleep = true; lockStateChanged() }
    @objc private func displayDidWake(_ note: Notification) { displayAsleep = false; lockStateChanged() }
}
