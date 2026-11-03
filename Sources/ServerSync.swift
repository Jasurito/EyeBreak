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
        run(on: connection, done: done) {
            guard let token = readToken() else { throw Telegram.Failure.noToken }
            return try ServerScript.install(calendar: calendar, token: token, chatID: chatID, message: message)
        } onSuccess: {
            Prefs.serverInstalled = ServerInstall(connection: connection, calendar: calendar, chatID: chatID,
                                                  message: message)
        }
    }

    func remove() {
        guard let connection = installed?.connection else { return }
        run(on: connection, done: "Done. Removed from \(connection.host).", isRemoval: true) {
            ServerScript.remove
        } onSuccess: {
            Prefs.serverInstalled = nil
        }
    }

    func sendTest() {
        guard let connection = installed?.connection else { return }
        run(on: connection, done: "Done. Check Telegram.") {
            ServerScript.sendTest
        } onSuccess: {}
    }

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

    private func run(on connection: ServerConnection, done: String, isRemoval: Bool = false,
                     script: @escaping @Sendable () throws -> String,
                     onSuccess: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        canForget = false
        if let problem = connection.problem {
            state = .failed(problem)
            canForget = isRemoval
            return
        }

        state = .running(ServerProgress(label: "Connecting to \(connection.host)…", fraction: 0))
        Task {
            do {
                // Off the main thread: reading the token can show a Keychain prompt.
                let text = try await Task.detached(operation: script).value
                try await ServerSSH.run(text, on: connection) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning else { return }
                        self.state = .running(progress)
                    }
                }
                onSuccess()
                state = .done(done)
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

    static func run(_ script: String, on connection: ServerConnection,
                    onProgress: @escaping @Sendable (ServerProgress) -> Void) async throws {
        try await Task.detached {
            try runBlocking(script, on: connection, onProgress: onProgress)
        }.value
    }

    private static func runBlocking(_ script: String, on connection: ServerConnection,
                                     onProgress: (ServerProgress) -> Void) throws {
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
    }
}
