import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SchedulerDelegate {
    private let scheduler = Scheduler()
    private let breakPanel = BreakPanelController()
    private var statusItem: NSStatusItem!

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let breaksLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let breakNowItem = NSMenuItem(title: "Take Break Now", action: #selector(breakNow), keyEquivalent: "b")
    private let restartItem = NSMenuItem(title: "Restart Timer", action: #selector(restart), keyEquivalent: "r")
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "Resume", action: #selector(resume), keyEquivalent: "")
    private let soundItem = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.menu = buildMenu()

        registerLoginItemOnFirstLaunch()

        scheduler.delegate = self
        scheduler.start()
    }

    // MARK: - SchedulerDelegate

    func schedulerDidUpdate(_ scheduler: Scheduler) {
        refresh()
    }

    func schedulerShouldStartBreak(_ scheduler: Scheduler) {
        playSound("Purr")
        breakPanel.show(seconds: Prefs.breakDuration) { [weak self] outcome in
            guard let self else { return }
            if outcome == .completed {
                Prefs.recordBreak()
                self.playSound("Glass")
            }
            self.scheduler.finishBreak(outcome)
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        breaksLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(breaksLine)
        menu.addItem(.separator())

        let pauseMenu = NSMenu()
        for (title, duration) in [("30 Minutes", 30.0 * 60), ("1 Hour", 60.0 * 60), ("Until Resumed", 0)] {
            let item = NSMenuItem(title: title, action: #selector(pause(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = duration
            pauseMenu.addItem(item)
        }
        pauseItem.submenu = pauseMenu

        for item in [breakNowItem, restartItem, pauseItem, resumeItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for item in [soundItem, loginItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit EyeBreak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let title: String

        switch scheduler.state {
        case .working:
            symbol = "eye"
            title = Self.shortTime(scheduler.remaining)
            statusLine.title = "Next break in \(Self.longTime(scheduler.remaining))"
        case .away:
            symbol = "eye"
            title = "–"
            statusLine.title = "Away – timer restarts when you're back"
        case .onBreak:
            symbol = "eye.fill"
            title = "break"
            statusLine.title = "On break"
        case .paused(let until):
            symbol = "eye.slash"
            title = ""
            statusLine.title = until.map { "Paused until \(timeFormatter.string(from: $0))" } ?? "Paused"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "20-20-20 eye break")
        image?.isTemplate = true
        button.image = image
        button.title = title.isEmpty ? "" : " \(title)"

        let isPaused: Bool
        if case .paused = scheduler.state { isPaused = true } else { isPaused = false }
        let onBreak = scheduler.state == .onBreak

        breaksLine.title = "Breaks today: \(Prefs.breaksToday)"
        breakNowItem.isEnabled = !onBreak
        restartItem.isEnabled = !onBreak && !isPaused
        pauseItem.isEnabled = !onBreak
        pauseItem.isHidden = isPaused
        resumeItem.isHidden = !isPaused
        soundItem.state = Prefs.soundEnabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func breakNow() { scheduler.breakNow() }
    @objc private func restart() { scheduler.restart() }
    @objc private func resume() { scheduler.resume() }

    @objc private func pause(_ sender: NSMenuItem) {
        let duration = sender.representedObject as? Double ?? 0
        scheduler.pause(for: duration > 0 ? duration : nil)
    }

    @objc private func toggleSound() {
        Prefs.soundEnabled.toggle()
        refresh()
    }

    // MARK: - Login item

    /// Turn on "Start at Login" the first time the app runs from an Applications folder.
    /// Skipped for builds run elsewhere, so a dev copy never ends up as the login item.
    private func registerLoginItemOnFirstLaunch() {
        guard !Prefs.loginItemConfigured,
              Bundle.main.bundlePath.contains("/Applications/") else { return }
        Prefs.loginItemConfigured = true
        try? SMAppService.mainApp.register()
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refresh()
    }

    // MARK: - Helpers

    private func playSound(_ name: String) {
        guard Prefs.soundEnabled else { return }
        NSSound(named: name)?.play()
    }

    /// "20m" down to "1m", then "59s".
    private static func shortTime(_ interval: TimeInterval) -> String {
        let seconds = Int(ceil(max(interval, 0)))
        return seconds >= 60 ? "\(Int(ceil(Double(seconds) / 60)))m" : "\(seconds)s"
    }

    private static func longTime(_ interval: TimeInterval) -> String {
        let seconds = Int(ceil(max(interval, 0)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
