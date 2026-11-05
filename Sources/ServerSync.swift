import Foundation

/// Keeps the notification service on your server in step with the Mac, over SSH.
///
/// The Mac only sets things up here: once saved, the server's systemd timer sends the
/// alerts on its own, whether or not the Mac is awake.
@MainActor
final class ServerSync: ObservableObject {
    enum State: Equatable {
        case idle
        case running(ServerProgress)
        case done(String)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    /// True after a failed removal, so a server that's gone for good can be let go.
    @Published private(set) var canForget = false

    var readToken: @Sendable () -> String? = { TelegramToken.read() }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var installed: ServerInstall? { Prefs.serverInstalled }

    /// True when Telegram alerts on the server no longer match the Mac's settings.
    var hasUnsavedChanges: Bool {
        guard Prefs.telegramSender == .server else { return false }
        if let installed {
            return installed.calendar != wantedCalendar
                || installed.chatID != Prefs.telegramChatID
                || (installed.message ?? DropMessage.standard) != Prefs.dropMessage
                || installed.tokenChanged
        }
        return !Prefs.serverConnection.host.isEmpty && !wantedCalendar.isEmpty
    }

    private var wantedCalendar: [String] {
        guard Prefs.dropsEnabled, Prefs.telegramEnabled else { return [] }
        return ServerSchedule.calendar(of: Prefs.dropDoses, timeZone: TimeZone.current.identifier)
    }

    /// Sets up the service and sends the schedule, which may still be empty.
    /// With Telegram alerts off, the service is removed instead.
    func save() {
        guard Prefs.telegramEnabled else {
            if installed != nil {
                remove()
            } else {
                state = .failed("Turn on “Send eye drop alerts to Telegram” at the top of the Telegram tab first.")
            }
            return
        }

        let calendar = wantedCalendar
        let connection = installed?.connection ?? Prefs.serverConnection
        let chatID = Prefs.telegramChatID
        let message = Prefs.dropMessage
        let readToken = self.readToken
        let done = calendar.isEmpty
            ? "Done. \(connection.host) is ready. To get alerts, turn on reminders under Eye Drops, add a time and save again."
            : "Done. \(connection.host) sends alerts on \(TimeZone.current.identifier) time."
        run(on: connection, firstStep: "Reading the bot token from your Keychain…") {
            guard let token = readToken() else { throw Telegram.Failure.noToken }
            return try ServerScript.install(calendar: calendar, token: token, chatID: chatID, message: message)
        } onSuccess: { _ in
            Prefs.serverInstalled = ServerInstall(connection: connection, calendar: calendar, chatID: chatID,
                                                  message: message)
            return .done(done)
        }
    }

    func remove() {
        guard let connection = installed?.connection else { return }
        run(on: connection, isRemoval: true) {
            ServerScript.remove
        } onSuccess: { _ in
            Prefs.serverInstalled = nil
            return .done("Done. Removed from \(connection.host).")
        }
    }

    func sendTest() {
        guard let connection = installed?.connection else { return }
        run(on: connection) {
            ServerScript.sendTest
        } onSuccess: { _ in
            .done("Done. Check Telegram.")
        }
    }

    /// Looks for anything broken on the server, without changing it or reading the Keychain.
    func check() {
        guard let installed else { return }
        let formatter = Self.alertFormatter
        run(on: installed.connection) {
            try ServerScript.check(installed)
        } onSuccess: { lines in
            let report = ServerCheckReport(lines: lines)
            let summary = report.summary(host: installed.connection.host, formatter: formatter)
            return report.isHealthy ? .done(summary) : .failed(summary)
        }
    }

    private static let alertFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// Stops tracking the server without touching it.
    func forget() {
        Prefs.serverInstalled = nil
        canForget = false
        state = .idle
    }

    /// The server still has the old token until the next save.
    func tokenChanged() {
        Prefs.serverInstalled?.tokenChanged = true
        objectWillChange.send()
    }

    /// `firstStep` is shown while `script` runs, which may be waiting on the Keychain prompt.
    /// `onSuccess` gets what the script printed besides its steps, and says how it went.
    private func run(on connection: ServerConnection, isRemoval: Bool = false, firstStep: String? = nil,
                     script: @escaping @Sendable () throws -> String,
                     onSuccess: @escaping @MainActor ([String]) -> State) {
        guard !isRunning else { return }
        canForget = false
        if let problem = connection.problem {
            state = .failed(problem)
            canForget = isRemoval
            return
        }

        let connecting = ServerProgress(label: "Connecting to \(connection.host)…", fraction: 0)
        state = .running(firstStep.map { ServerProgress(label: $0, fraction: 0) } ?? connecting)
        Task {
            do {
                // Off the main thread: reading the token can show a Keychain prompt.
                let text = try await Task.detached(operation: script).value
                state = .running(connecting)
                let lines = try await ServerSSH.run(text, on: connection) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning else { return }
                        self.state = .running(progress)
                    }
                }
                state = onSuccess(lines)
            } catch {
                state = .failed(error.localizedDescription)
                canForget = isRemoval
            }
        }
    }
}

enum ServerSSH {
    static var executable = "/usr/bin/ssh"
    /// Long enough for a slow server, and for the retries behind a test message.
    static var timeout: TimeInterval = 150

    /// Returns the lines the script printed other than `STEP` and `ERROR`.
    @discardableResult
    static func run(_ script: String, on connection: ServerConnection,
                    onProgress: @escaping @Sendable (ServerProgress) -> Void) async throws -> [String] {
        try await Task.detached {
            try runBlocking(script, on: connection, onProgress: onProgress)
        }.value
    }

    private static func runBlocking(_ script: String, on connection: ServerConnection,
                                     onProgress: (ServerProgress) -> Void) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = connection.sshArguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // Without this, a server hanging up before reading the script would kill the app.
        signal(SIGPIPE, SIG_IGN)
        try process.run()

        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try? input.fileHandleForWriting.close()

        // Read on the side, so a long error message can't block ssh while we wait on stdout.
        var errorData = Data()
        let errorsRead = DispatchGroup()
        DispatchQueue.global().async(group: errorsRead) {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
        }

        var reason: String?
        var lines: [String] = []
        var pending = Data()
        while case let chunk = output.fileHandleForReading.availableData, !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                if let progress = ServerProgress(line: line) {
                    onProgress(progress)
                } else if line.hasPrefix("ERROR ") {
                    reason = String(line.dropFirst("ERROR ".count))
                } else {
                    lines.append(line)
                }
            }
        }

        errorsRead.wait()
        process.waitUntilExit()
        watchdog.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw ServerFailure("\(connection.host) took too long to answer.")
        }
        if process.terminationStatus != 0 {
            let text = String(decoding: errorData, as: UTF8.self)
            throw ServerFailure(reason ?? ServerErrors.explain(text, connection: connection))
        }
        return lines
    }
}
