import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// The Settings window, with one toolbar tab per area.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: SettingsModel
    private var window: NSWindow?
    private let tabs = NSTabViewController()
    private static let telegramTabIndex = 3
    private var modelChanges: AnyCancellable?
    private var appearanceChanges: AnyCancellable?
    private var telegramIconFaded: Bool?

    init(scheduler: Scheduler, drops: DropsScheduler, sync: ServerSync) {
        model = SettingsModel(scheduler: scheduler, drops: drops, sync: sync)
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Commits a number still being typed, then offers to save a changed schedule: the Mac
    /// uses edits right away, but the server keeps the old one until it's told.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        guard model.sync.hasUnsavedChanges, !model.sync.isRunning else { return true }

        let alert = NSAlert()
        alert.messageText = "Save your changes to the server?"
        alert.informativeText = "Until you save, Telegram alerts keep the old schedule and message."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            tabs.selectedTabViewItemIndex = Self.telegramTabIndex
            model.sync.save()
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func makeWindow() -> NSWindow {
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab("General", symbol: "gearshape", GeneralTab(model: model)))
        tabs.addTabViewItem(tab("Sounds", symbol: "speaker.wave.2", SoundsTab()))
        tabs.addTabViewItem(tab("Eye Drops", symbol: "drop", DropsTab(model: model)))
        tabs.addTabViewItem(tab("Telegram", symbol: "paperplane", TelegramTab(model: model)))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        // objectWillChange comes before the change, so look on the next turn of the run loop.
        modelChanges = model.objectWillChange.sink { [weak self, weak window] in
            DispatchQueue.main.async {
                guard let self, let window else { return }
                self.updateTelegramIcon(in: window)
            }
        }
        // Also draws it the first time.
        appearanceChanges = window.publisher(for: \.effectiveAppearance).sink { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.telegramIconFaded = nil
            self.updateTelegramIcon(in: window)
        }
        return window
    }

    /// Faded while eye drop reminders are off, since there's nothing to send then.
    private func updateTelegramIcon(in window: NSWindow) {
        let faded = !model.dropsEnabled
        guard faded != telegramIconFaded else { return }
        telegramIconFaded = faded
        let item = tabs.tabViewItems[Self.telegramTabIndex]
        let symbol = NSImage(systemSymbolName: "paperplane", accessibilityDescription: item.label)
        let image = faded ? symbol.flatMap { Self.faded($0, for: window.effectiveAppearance) } : symbol
        item.image = image
        window.toolbar?.items.first { $0.label == item.label }?.image = image
    }

    /// Still a symbol, so it keeps the toolbar's size. The toolbar loses see-through colors,
    /// so it's a solid gray picked for the window's light or dark look, and redone when that changes.
    private static func faded(_ symbol: NSImage, for appearance: NSAppearance) -> NSImage? {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = NSColor(white: isDark ? 0.4 : 0.7, alpha: 1)
        let image = symbol.withSymbolConfiguration(.init(paletteColors: [color]))
        image?.accessibilityDescription = symbol.accessibilityDescription.map { "\($0), off" }
        return image
    }

    private func tab<Content: View>(_ title: String, symbol: String, _ content: Content) -> NSTabViewItem {
        let controller = NSHostingController(rootView: content.frame(width: 540, height: 540))
        controller.sizingOptions = .preferredContentSize
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

/// Bridges the tabs to the saved settings and to the objects that act on them.
@MainActor
final class SettingsModel: ObservableObject {
    private let scheduler: Scheduler
    private let drops: DropsScheduler
    let sync: ServerSync
    private var syncChanges: AnyCancellable?

    @Published var loginError: String?

    init(scheduler: Scheduler, drops: DropsScheduler, sync: ServerSync) {
        self.scheduler = scheduler
        self.drops = drops
        self.sync = sync
        // So the tabs, which only watch this model, follow a save as it runs.
        syncChanges = sync.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var intervalMinutes: Int {
        get { Int((Prefs.workInterval / 60).rounded()) }
        set {
            let minutes = min(max(newValue, 1), 240)
            objectWillChange.send()
            guard minutes != intervalMinutes else { return }
            Prefs.workInterval = TimeInterval(minutes * 60)
            // Changing the interval starts a fresh countdown with the new length.
            if scheduler.state == .working || scheduler.state == .away {
                scheduler.restart()
            }
        }
    }

    /// Applies from the next break.
    var breakSeconds: Int {
        get { Prefs.breakDuration }
        set {
            objectWillChange.send()
            Prefs.breakDuration = min(max(newValue, 5), 600)
        }
    }

    var soundEnabled: Bool {
        get { Prefs.soundEnabled }
        set {
            objectWillChange.send()
            Prefs.soundEnabled = newValue
        }
    }

    var startAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            let service = SMAppService.mainApp
            do {
                if newValue {
                    try service.register()
                } else {
                    try service.unregister()
                }
                loginError = nil
            } catch {
                loginError = error.localizedDescription
            }
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    var dropsEnabled: Bool {
        get { Prefs.dropsEnabled }
        set {
            objectWillChange.send()
            Prefs.dropsEnabled = newValue
            drops.settingsChanged()
        }
    }

    var doses: [DropDose] {
        get { Prefs.dropDoses }
        set {
            objectWillChange.send()
            Prefs.dropDoses = newValue.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
            drops.settingsChanged()
        }
    }

    var dropMessageText: String {
        get { Prefs.dropMessageText }
        set {
            objectWillChange.send()
            Prefs.dropMessageText = String(newValue.prefix(DropMessage.maxLength))
        }
    }

    var messageTemplates: [String] { Prefs.messageTemplates }

    /// False when the text is empty or is already in the list.
    var canSaveMessageTemplate: Bool {
        let text = Prefs.dropMessage
        return !Prefs.dropMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !DropMessage.templates.contains(text) && !Prefs.messageTemplates.contains(text)
    }

    func saveMessageTemplate() {
        guard canSaveMessageTemplate else { return }
        objectWillChange.send()
        Prefs.messageTemplates.append(Prefs.dropMessage)
    }

    func deleteMessageTemplate(_ text: String) {
        objectWillChange.send()
        Prefs.messageTemplates.removeAll { $0 == text }
    }

    var telegramEnabled: Bool {
        get { Prefs.telegramEnabled }
        set {
            objectWillChange.send()
            Prefs.telegramEnabled = newValue
        }
    }

    var telegramChatID: String {
        get { Prefs.telegramChatID }
        set {
            objectWillChange.send()
            Prefs.telegramChatID = newValue.trimmingCharacters(in: .whitespaces)
        }
    }

    var telegramSender: TelegramSender {
        get { Prefs.telegramSender }
        set {
            objectWillChange.send()
            Prefs.telegramSender = newValue
            // Whatever is queued was meant for the old route.
            Prefs.telegramQueue = []
        }
    }

    var serverConnection: ServerConnection {
        get { Prefs.serverConnection }
        set {
            objectWillChange.send()
            var connection = newValue
            connection.host = connection.host.trimmingCharacters(in: .whitespaces)
            connection.user = connection.user.trimmingCharacters(in: .whitespaces)
            connection.keyPath = connection.keyPath.trimmingCharacters(in: .whitespaces)
            Prefs.serverConnection = connection
        }
    }

    var lastTelegramError: String? { drops.lastTelegramError }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Eye breaks") {
                NumberRow(title: "Break every", value: $model.intervalMinutes, range: 1...240, step: 5, unit: "minutes")
                NumberRow(title: "Break length", value: $model.breakSeconds, range: 5...600, step: 5, unit: "seconds")
            }
            Section {
                Toggle("Play sounds", isOn: $model.soundEnabled)
                Toggle("Start at login", isOn: $model.startAtLogin)
                if let error = model.loginError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct NumberRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: $value, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
            }
        }
    }
}

// MARK: - Sounds

struct SoundsTab: View {
    @ObservedObject private var library = SoundLibrary.shared
    @State private var message: String?

    var body: some View {
        Form {
            Section("Play") {
                ForEach(SoundEvent.allCases) { event in
                    Picker(event.title, selection: selection(for: event)) {
                        ForEach(library.customSounds) { Text($0.name).tag($0.id) }
                        if !library.customSounds.isEmpty { Divider() }
                        ForEach(library.systemSounds) { Text($0.name).tag($0.id) }
                    }
                }
            }

            Section {
                if library.customSounds.isEmpty {
                    Text("Add your own MP3, WAV, AIFF or M4A files.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.customSounds) { row($0) }
                if let message {
                    Text(message).foregroundStyle(.red)
                }
            } header: {
                HStack {
                    Text("Your sounds")
                    Spacer()
                    Button("Add Sounds…", systemImage: "plus", action: addSounds)
                }
            }

            Section("System sounds") {
                ForEach(library.systemSounds) { row($0) }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ sound: Sound) -> some View {
        HStack {
            Button {
                library.preview(sound)
            } label: {
                Label("Play \(sound.name)", systemImage: "play.circle").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)

            Text(sound.name)
            Spacer()

            if sound.isCustom {
                Button {
                    remove(sound)
                } label: {
                    Label("Remove \(sound.name)", systemImage: "trash").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func selection(for event: SoundEvent) -> Binding<String> {
        Binding(get: { library.selectionID(for: event) },
                set: { library.select($0, for: event) })
    }

    private func addSounds() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }

        let rejected = library.add(panel.urls)
        message = rejected.isEmpty ? nil : "Couldn't add: \(rejected.joined(separator: ", "))"
    }

    private func remove(_ sound: Sound) {
        do {
            try library.remove(sound)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Eye drops

struct DropsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Remind me to use eye drops", isOn: $model.dropsEnabled)
            } footer: {
                Text("A popup stays on screen until you press Done. If the Mac is closed or locked at that time, it appears as soon as you log back in.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.doses.isEmpty {
                    Text("No times yet.").foregroundStyle(.secondary)
                }
                ForEach(model.doses) { dose in
                    DoseRow(dose: dose,
                            update: { updated in replace(dose, with: updated) },
                            delete: { model.doses.removeAll { $0.id == dose.id } })
                }
            } header: {
                HStack {
                    Text("Schedule")
                    Spacer()
                    Button("Add Time", systemImage: "plus", action: addDose)
                }
            }
            .disabled(!model.dropsEnabled)

            Section {
                TextField("Message", text: $model.dropMessageText, prompt: Text(DropMessage.standard))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                ForEach(DropMessage.templates, id: \.self) { MessageRow(model: model, text: $0, isYours: false) }
                ForEach(model.messageTemplates, id: \.self) { MessageRow(model: model, text: $0, isYours: true) }
            } header: {
                HStack {
                    Text("Message")
                    Spacer()
                    Button("Save as Template", systemImage: "plus", action: model.saveMessageTemplate)
                        .disabled(!model.canSaveMessageTemplate)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shown in the popup and sent to Telegram.")
                        .foregroundStyle(.secondary)
                    if model.sync.hasUnsavedChanges {
                        Label("Your server still has the old times and message. Press Save in the Telegram tab.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(!model.dropsEnabled)
        }
        .formStyle(.grouped)
    }

    private func replace(_ dose: DropDose, with updated: DropDose) {
        var doses = model.doses
        if let index = doses.firstIndex(where: { $0.id == dose.id }) {
            doses[index] = updated
            model.doses = doses
        }
    }

    /// New times start four hours after the last one, so a day fills in quickly.
    private func addDose() {
        let hour = model.doses.last.map { ($0.hour + 4) % 24 } ?? 9
        model.doses.append(DropDose(hour: hour, minute: 0))
    }
}

/// A template. Click to use it. Your own can be deleted, the built-in ones can't.
private struct MessageRow: View {
    @ObservedObject var model: SettingsModel
    let text: String
    let isYours: Bool

    private var isCurrent: Bool { Prefs.dropMessage == text }

    var body: some View {
        HStack {
            Button {
                model.dropMessageText = text
            } label: {
                HStack {
                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    Text(text)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isCurrent ? "Selected" : "")

            if text == DropMessage.standard {
                Text("Default").foregroundStyle(.secondary)
            }
            if isYours {
                Button {
                    model.deleteMessageTemplate(text)
                } label: {
                    Label("Delete \(text)", systemImage: "trash").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

private struct DoseRow: View {
    let dose: DropDose
    let update: (DropDose) -> Void
    let delete: () -> Void

    private let calendar = Calendar.current

    /// Calendar weekdays in the order your region starts the week.
    private var weekdays: [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    var body: some View {
        HStack {
            DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                .labelsHidden()

            Spacer()

            HStack(spacing: 2) {
                ForEach(weekdays, id: \.self) { day in
                    DayButton(title: calendar.veryShortWeekdaySymbols[day - 1],
                              fullName: calendar.weekdaySymbols[day - 1],
                              isOn: dose.weekdays.contains(day),
                              toggle: { toggle(day) })
                }
            }

            Button(action: delete) {
                Label("Remove", systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                calendar.date(bySettingHour: dose.hour, minute: dose.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                var updated = dose
                updated.hour = calendar.component(.hour, from: date)
                updated.minute = calendar.component(.minute, from: date)
                update(updated)
            })
    }

    /// The last selected day can't be turned off: a dose on no days would never fire.
    private func toggle(_ day: Int) {
        var updated = dose
        if !dose.weekdays.contains(day) {
            updated.weekdays.insert(day)
        } else if dose.weekdays.count > 1 {
            updated.weekdays.remove(day)
        }
        update(updated)
    }
}

/// Filled when on, outlined when off, so a glance shows which days a dose runs.
private struct DayButton: View {
    let title: String
    let fullName: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .frame(width: 24, height: 24)
                .background(isOn ? Color.accentColor : Color.clear, in: Circle())
                .overlay(Circle().strokeBorder(Color.secondary.opacity(isOn ? 0 : 0.5)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(fullName)
        .accessibilityLabel(fullName)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Telegram

struct TelegramTab: View {
    @ObservedObject var model: SettingsModel

    @State private var tokenInput = ""
    @State private var hasToken = TelegramToken.isSaved
    @State private var status: String?
    @State private var isBusy = false

    private var isConfigured: Bool { hasToken && !model.telegramChatID.isEmpty }

    var body: some View {
        if model.dropsEnabled {
            settings
        } else {
            remindersOff
        }
    }

    /// Telegram only sends eye drop alerts, so without reminders there's nothing to set up.
    private var remindersOff: some View {
        VStack(spacing: 10) {
            Image(systemName: "drop")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
            Text("Eye drop reminders are off")
                .font(.title3.weight(.semibold))
            Text("Turn them on in Eye Drops to use Telegram notifications.")
                .foregroundStyle(.secondary)

            // A server that still has times keeps sending, so offer to stop it from here.
            if let installed = model.sync.installed, !installed.calendar.isEmpty || model.sync.state != .idle {
                VStack(alignment: .leading, spacing: 10) {
                    if !installed.calendar.isEmpty {
                        Label("\(installed.connection.host) still sends alerts at the times you saved.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    ServerRow(model: model, showsAllActions: model.telegramSender == .local)
                }
                .padding(14)
                .frame(maxWidth: 440, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .multilineTextAlignment(.leading)
                .padding(.top, 20)
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settings: some View {
        Form {
            Section {
                Toggle("Send eye drop alerts to Telegram", isOn: $model.telegramEnabled)
                    .disabled(!isConfigured)
                Picker("Send from", selection: $model.telegramSender) {
                    Text("Server").tag(TelegramSender.server)
                    Text("Local").tag(TelegramSender.local)
                }
                .pickerStyle(.segmented)
            } footer: {
                if model.telegramSender == .server {
                    Text("Your server sends the alerts on time, even with the lid closed.")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Local alerts can't be sent while the lid is closed or there's no internet. They go out once the Mac is awake and online.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if model.telegramSender == .local, let installed = model.sync.installed {
                Section {
                    Label("Still installed on \(installed.connection.host), which keeps sending its own alerts.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    ServerRow(model: model, showsAllActions: true)
                }
            }

            Section("1. Bot token") {
                if hasToken {
                    LabeledContent("Token saved in your Keychain") {
                        Button("Remove", action: removeToken)
                    }
                } else {
                    Text("Message [@BotFather](https://t.me/BotFather) in Telegram, send /newbot, and paste the token it gives you.")
                    HStack {
                        SecureField("Bot token", text: $tokenInput, prompt: Text("123456:ABC-DEF…"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button("Save", action: saveToken)
                            .disabled(tokenInput.isEmpty)
                    }
                }
            }

            Section("2. Chat") {
                Text("Send /start to your bot in Telegram, then find your chat ID.")
                HStack {
                    TextField("Chat ID", text: $model.telegramChatID, prompt: Text("Chat ID"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button("Find Chat ID", action: findChatID)
                        .disabled(!hasToken || isBusy)
                }
                if model.telegramSender == .server {
                    statusRow
                }
            }

            if model.telegramSender == .server {
                Section {
                    Text("EyeBreak logs in over SSH with your key and installs a systemd service that sends the alerts. The user must be root or have passwordless sudo.")
                    serverField("IP or domain", text: $model.serverConnection.host, prompt: "203.0.113.10")
                    serverField("SSH user", text: $model.serverConnection.user, prompt: "root")
                    serverField("SSH port", text: portText, prompt: "22")
                    serverField("SSH key", text: $model.serverConnection.keyPath, prompt: "Default, or ~/.ssh/my_key")
                    if let installed = model.sync.installed {
                        Text("To use another server, remove the service from \(installed.connection.host) first.")
                            .foregroundStyle(.secondary)
                    }
                    ServerRow(model: model, showsAllActions: true)
                } header: {
                    Text("3. Server")
                } footer: {
                    KeychainNote.save
                }
            } else {
                Section {
                    Button("Send Test Message", action: sendTest)
                        .disabled(!isConfigured || isBusy)
                    statusRow
                } header: {
                    Text("3. Test")
                } footer: {
                    KeychainNote.local
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusRow: some View {
        if let status {
            Text(status).foregroundStyle(.secondary)
        } else if model.telegramSender == .local, let error = model.lastTelegramError {
            Text("Last alert failed, retrying: \(error)").foregroundStyle(.red)
        }
    }

    /// Text rather than a number field, which would only commit on Return: pressing Save
    /// right after typing would use the old port.
    private var portText: Binding<String> {
        Binding(get: { model.serverConnection.port == 0 ? "" : String(model.serverConnection.port) },
                set: { model.serverConnection.port = Int($0) ?? 0 })
    }

    /// Locked once installed, so the Mac can't lose track of the server that has the service.
    private func serverField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        TextField(title, text: text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .disabled(model.sync.installed != nil)
    }

    private func saveToken() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Telegram.isValidToken(token) else {
            status = "That doesn't look like a bot token. It should look like 123456:ABC-DEF…"
            return
        }
        guard TelegramToken.save(token) else {
            status = "Couldn't save the token to your Keychain."
            return
        }
        tokenInput = ""
        hasToken = true
        status = nil
        model.sync.tokenChanged()
    }

    private func removeToken() {
        TelegramToken.delete()
        hasToken = false
        model.telegramEnabled = false
        status = nil
    }

    private func findChatID() {
        run { token in
            let chat = try await Telegram.latestChat(token: token)
            model.telegramChatID = chat.id
            return "Found \(chat.name)."
        }
    }

    private func sendTest() {
        let chatID = model.telegramChatID
        run { token in
            try await Telegram.send("✅ EyeBreak is connected", token: token, chatID: chatID)
            return "Sent. Check Telegram."
        }
    }

    private func run(_ action: @escaping (String) async throws -> String) {
        isBusy = true
        status = nil
        Task {
            do {
                guard let token = await Task.detached(operation: { TelegramToken.read() }).value else {
                    throw Telegram.Failure.noToken
                }
                status = try await action(token)
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }
}

/// Warns about the macOS password prompt before it appears. EyeBreak isn't signed with a
/// paid certificate, so macOS asks before giving the token to each new version.
private enum KeychainNote {
    static var save: some View {
        note("Pressing Save makes macOS ask for your login password, so EyeBreak can read the bot token from your Keychain. Choose Always Allow, or it asks on every Save. It asks once more after each EyeBreak update.")
    }

    static var local: some View {
        note("The first test or alert makes macOS ask for your login password, so EyeBreak can read the bot token from your Keychain. Choose Always Allow, or each alert waits for you to type it. It asks once more after each EyeBreak update.")
    }

    private static func note(_ text: String) -> some View {
        Label(text, systemImage: "key.fill").foregroundStyle(.secondary)
    }
}

/// Save button, progress bar and result for the server.
private struct ServerRow: View {
    @ObservedObject var model: SettingsModel
    /// Also offer Send Test and Remove, which only make sense next to the server's details.
    let showsAllActions: Bool

    private var sync: ServerSync { model.sync }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if model.telegramSender == .server {
                    Button("Save", action: sync.save)
                }
                if showsAllActions, sync.installed != nil {
                    if model.telegramSender == .server {
                        Button("Send Test Message", action: sync.sendTest)
                        Button("Check Server", action: sync.check)
                            .help("Looks for anything broken on the server, without changing it")
                    }
                    Spacer()
                    if sync.canForget {
                        Button("Forget Server", action: sync.forget)
                    }
                    Button("Remove from Server", action: sync.remove)
                }
            }
            .disabled(sync.isRunning)

            // Room for the progress bar, so it can't land below the bottom of the window.
            status.frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        }
    }

    /// The last result stays up next to unsaved changes, so a check's answer isn't hidden.
    @ViewBuilder
    private var status: some View {
        if case .running(let progress) = sync.state {
            ProgressView(progress.label, value: progress.fraction)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                switch sync.state {
                case .done(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let reason):
                    Label(reason, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                case .idle, .running:
                    EmptyView()
                }
                if sync.hasUnsavedChanges {
                    Text("Unsaved changes: the server still has the old settings.")
                        .foregroundStyle(.orange)
                } else if sync.state == .idle, sync.installed == nil, model.telegramSender == .server {
                    Text("Nothing is on the server yet. Press Save to set it up.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
