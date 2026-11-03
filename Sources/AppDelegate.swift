import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SchedulerDelegate, DropsSchedulerDelegate {
    private let scheduler = Scheduler()
    private let breakPanel = BreakPanelController()
    private let drops = DropsScheduler()
    private let dropsPanel = DropsPanelController()
    private let serverSync = ServerSync()
    private lazy var settingsWindow = SettingsWindowController(scheduler: scheduler, drops: drops, sync: serverSync)
    private var statusItem: NSStatusItem!

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let breaksLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let dropsLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let breakNowItem = NSMenuItem(title: "Take Break Now", action: #selector(breakNow), keyEquivalent: "b")
    private let restartItem = NSMenuItem(title: "Restart Timer", action: #selector(restart), keyEquivalent: "r")
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "Resume", action: #selector(resume), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")

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
        installMainMenu()

        registerLoginItemOnFirstLaunch()

        scheduler.delegate = self
        scheduler.start()

        dropsPanel.onDone = { [weak self] in
            SoundLibrary.shared.stop()
            self?.drops.markDone()
        }
        dropsPanel.onSnooze = { [weak self] in
            SoundLibrary.shared.stop()
            self?.drops.snooze()
        }
        drops.delegate = self
        drops.isPresent = { [weak self] in self?.scheduler.isLockedOrAsleep == false }
        scheduler.onPresenceChange = { [weak self] in self?.drops.check() }
        drops.start()
    }

    // MARK: - SchedulerDelegate

    func schedulerDidUpdate(_ scheduler: Scheduler) {
        refresh()
    }

    func schedulerShouldStartBreak(_ scheduler: Scheduler) {
        SoundLibrary.shared.play(.breakStart)
        breakPanel.show(seconds: Prefs.breakDuration) { [weak self] outcome in
            guard let self else { return }
            if outcome == .completed {
                Prefs.recordBreak()
                SoundLibrary.shared.play(.breakEnd)
            }
            self.scheduler.finishBreak(outcome)
        }
    }

    // MARK: - DropsSchedulerDelegate

    func dropsScheduler(_ scheduler: DropsScheduler, didUpdateDue times: [Date]) {
        if dropsPanel.update(times) {
            SoundLibrary.shared.play(.drops)
        }
        refresh()
    }

    // MARK: - Menu

    /// Accessory apps show no menu bar, but keys like ⌘V and ⌘W still go through this menu.
    /// Without it you couldn't paste into Settings.
    private func installMainMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let item = NSMenuItem()
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        NSApp.mainMenu = main
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        breaksLine.isEnabled = false
        dropsLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(breaksLine)
        menu.addItem(dropsLine)
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

        settingsItem.target = self
        menu.addItem(settingsItem)
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
        dropsLine.title = drops.statusLine ?? ""
        dropsLine.isHidden = drops.statusLine == nil
    }

    @objc private func breakNow() { scheduler.breakNow() }
    @objc private func restart() { scheduler.restart() }
    @objc private func resume() { scheduler.resume() }

    @objc private func pause(_ sender: NSMenuItem) {
        let duration = sender.representedObject as? Double ?? 0
        scheduler.pause(for: duration > 0 ? duration : nil)
    }

    @objc private func openSettings() {
        settingsWindow.show()
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

    // MARK: - Helpers

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
