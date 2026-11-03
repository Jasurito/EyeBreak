import Foundation

/// Which machine sends the Telegram alerts.
enum TelegramSender: String {
    case server
    case local
}

/// A reason shown to the user as is.
struct ServerFailure: LocalizedError {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    var errorDescription: String? { reason }
}

/// How to reach the server over SSH.
struct ServerConnection: Codable, Equatable {
    var host = ""
    var user = "root"
    var port = 22
    /// Empty means whichever key ssh would pick on its own.
    var keyPath = ""

    private var expandedKeyPath: String {
        (keyPath as NSString).expandingTildeInPath
    }

    /// What's wrong with these details, or nil if it's worth trying to connect.
    /// The patterns also stop a value starting with `-` from reaching ssh as an option.
    var problem: String? {
        if host.isEmpty {
            return "Enter your server's IP or domain in the Telegram tab."
        }
        let isName = host.range(of: #"^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
        let isIPv6 = host.range(of: #"^[0-9A-Fa-f]*:[0-9A-Fa-f:.]*$"#, options: .regularExpression) != nil
        if !isName && !isIPv6 {
            return "“\(host)” isn't an IP address or domain. Enter only the address, with the user in its own field."
        }
        if user.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) == nil {
            return "“\(user)” isn't a valid SSH user."
        }
        if !(1...65535).contains(port) {
            return "SSH port must be between 1 and 65535."
        }
        if !keyPath.isEmpty, !FileManager.default.fileExists(atPath: expandedKeyPath) {
            return "SSH key not found at \(keyPath)."
        }
        return nil
    }

    /// `BatchMode` makes ssh fail instead of waiting for a password nobody can type.
    /// Connection sharing is off because a shared master would keep our pipes open.
    var sshArguments: [String] {
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "LogLevel=ERROR",
            "-l", user,
            "-p", String(port),
        ]
        if !keyPath.isEmpty {
            arguments += ["-i", expandedKeyPath, "-o", "IdentitiesOnly=yes"]
        }
        return arguments + ["--", host, ServerScript.runAsRoot]
    }
}

/// What was last saved to the server, to tell when the Mac has moved on from it.
struct ServerInstall: Codable, Equatable {
    var connection: ServerConnection
    var calendar: [String]
    var chatID: String
    var tokenChanged = false
    /// Optional so installs from before messages were customizable still load. Nil means the default.
    var message: String?
}

enum ServerSchedule {
    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// One systemd `OnCalendar` value per dose. Each names the Mac's time zone, because
    /// servers usually run on UTC and 08:00 should mean 08:00 where you are.
    static func calendar(of doses: [DropDose], timeZone: String) -> [String] {
        var values: [String] = []
        for dose in doses.sorted(by: { ($0.hour, $0.minute) < ($1.hour, $1.minute) }) where !dose.weekdays.isEmpty {
            let days = dose.weekdays.sorted().map { dayNames[$0 - 1] }.joined(separator: ",")
            let value = String(format: "%@ %02d:%02d:00 %@", days, dose.hour, dose.minute, timeZone)
            if !values.contains(value) { values.append(value) }
        }
        return values
    }
}

/// The scripts that run on the server. They're sent over stdin, so the bot token never
/// appears in a process list. Each prints `STEP n/total label` as it goes, and
/// `ERROR reason` before giving up.
enum ServerScript {
    /// Runs the script from stdin as root, directly or through passwordless sudo.
    static let runAsRoot = #"sh -c 'if [ "$(id -u)" = 0 ]; then exec sh -s; else exec sudo -n sh -s; fi'"#

    private static let helpers = #"""
    set -eu
    step() { echo "STEP $1"; }
    fail() { echo "ERROR $1"; exit 1; }
    """#

    /// Writes nothing until the checks pass, so a failed save leaves the old schedule running.
    /// Installing over an earlier install replaces its schedule. With no times the service
    /// is still set up, so the server and Send Test work before there's a schedule.
    static func install(calendar: [String], token: String, chatID: String, message: String) throws -> String {
        guard Telegram.isValidToken(token) else {
            throw ServerFailure("The saved bot token isn't valid. Remove it and add it again.")
        }
        guard Telegram.isValidChatID(chatID) else {
            throw ServerFailure("Find your chat ID in the Telegram tab first.")
        }
        let valuePattern = #"^[A-Za-z]{3}(,[A-Za-z]{3})* [0-9]{2}:[0-9]{2}:00 [A-Za-z0-9_+/-]+$"#
        guard calendar.allSatisfy({ $0.range(of: valuePattern, options: .regularExpression) != nil }) else {
            throw ServerFailure("The schedule can't be sent to the server.")
        }

        let quotedTimes = calendar.map { "'\($0)'" }.joined(separator: " ")
        let timerLines = calendar.map { "OnCalendar=\($0)" }.joined(separator: "\n")
        let schedule = calendar.isEmpty ? clearSchedule : #"""
        cat > /etc/systemd/system/eyebreak-notification.timer <<'EYEBREAK'
        [Unit]
        Description=EyeBreak eye drop schedule

        [Timer]
        \#(timerLines)
        AccuracySec=1s

        [Install]
        WantedBy=timers.target
        EYEBREAK

        step "5/5 Starting the schedule"
        systemctl daemon-reload
        systemctl --quiet enable eyebreak-notification.timer
        systemctl restart eyebreak-notification.timer
        systemctl is-active --quiet eyebreak-notification.timer || fail "The schedule didn't start on the server."
        """#

        return #"""
        \#(helpers)

        step "1/5 Checking the server"
        [ -d /run/systemd/system ] || fail "This server doesn't run systemd."
        [ -x /usr/bin/curl ] || fail "curl isn't installed on the server. Install it with: apt install curl"

        step "2/5 Checking the schedule"
        if command -v systemd-analyze >/dev/null; then
            for time in \#(quotedTimes); do
                systemd-analyze calendar "$time" >/dev/null 2>&1 ||
                    fail "The server can't read the time \"$time\". Its time zone data may be missing: apt install tzdata"
            done
        fi

        step "3/5 Checking Telegram from the server"
        code=$(/usr/bin/curl --silent --output /dev/null --write-out '%{http_code}' --max-time 20 --config - 2>/dev/null <<'EYEBREAK' || true
        url = "https://api.telegram.org/bot\#(token)/getChat"
        data-urlencode = "chat_id=\#(chatID)"
        EYEBREAK
        )
        case "$code" in
            200) ;;
            401|404) fail "Telegram rejected the bot token." ;;
            400|403) fail "Telegram doesn't know that chat ID. Send /start to your bot, then press Find Chat ID." ;;
            000) fail "The server can't reach api.telegram.org. Check its internet connection and firewall." ;;
            *) fail "Telegram answered with error $code." ;;
        esac

        step "4/5 Installing the service"
        umask 077
        mkdir -p /etc/eyebreak
        cat > /etc/eyebreak/telegram.curl.new <<'EYEBREAK'
        url = "https://api.telegram.org/bot\#(token)/sendMessage"
        data-urlencode = "chat_id=\#(chatID)"
        data-urlencode = "text=💧 \#(curlQuoted(message))"
        silent
        show-error
        fail
        output = "/dev/null"
        max-time = 20
        retry = 3
        retry-delay = 10
        EYEBREAK
        mv -f /etc/eyebreak/telegram.curl.new /etc/eyebreak/telegram.curl

        umask 022
        cat > /etc/systemd/system/eyebreak-notification.service <<'EYEBREAK'
        [Unit]
        Description=EyeBreak eye drop alert to Telegram
        Wants=network-online.target
        After=network-online.target

        [Service]
        Type=oneshot
        ExecStart=/usr/bin/curl --config /etc/eyebreak/telegram.curl
        NoNewPrivileges=yes
        ProtectSystem=strict
        ProtectHome=yes
        PrivateTmp=yes
        EYEBREAK

        \#(schedule)
        """#
    }

    /// Makes text safe inside a double-quoted curl config value. A newline becomes `\n`,
    /// so a message can't end the here-document it's written in and run as a command.
    private static func curlQuoted(_ text: String) -> String {
        var quoted = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": quoted += "\\\\"
            case "\"": quoted += "\\\""
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted
    }

    private static let clearSchedule = #"""
    step "5/5 Clearing the schedule"
    systemctl --quiet disable --now eyebreak-notification.timer 2>/dev/null || true
    rm -f /etc/systemd/system/eyebreak-notification.timer
    systemctl daemon-reload
    """#

    static let remove = #"""
    \#(helpers)

    step "1/2 Stopping the schedule"
    systemctl --quiet disable --now eyebreak-notification.timer 2>/dev/null || true

    step "2/2 Removing the service"
    rm -f /etc/systemd/system/eyebreak-notification.service \
          /etc/systemd/system/eyebreak-notification.timer \
          /etc/eyebreak/telegram.curl /etc/eyebreak/telegram.curl.new
    rmdir /etc/eyebreak 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed eyebreak-notification.service 2>/dev/null || true
    """#

    static let sendTest = #"""
    \#(helpers)

    step "1/1 Sending from the server"
    [ -f /etc/systemd/system/eyebreak-notification.service ] ||
        fail "The service isn't on the server. Press Save first."
    systemctl start eyebreak-notification.service ||
        fail "The server couldn't send the message. See: journalctl -u eyebreak-notification.service"
    """#
}

/// A `STEP n/total label` line from a script.
struct ServerProgress: Equatable {
    let label: String
    /// How much is finished: the current step counts once it's over.
    let fraction: Double

    init(label: String, fraction: Double) {
        self.label = label
        self.fraction = fraction
    }

    init?(line: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "STEP" else { return nil }
        let numbers = parts[1].split(separator: "/").compactMap { Int($0) }
        guard numbers.count == 2, numbers[1] > 0 else { return nil }
        self.init(label: parts[2], fraction: Double(numbers[0] - 1) / Double(numbers[1]))
    }
}

/// Turns what ssh printed into a reason someone can act on.
enum ServerErrors {
    static func explain(_ output: String, connection: ServerConnection) -> String {
        let host = connection.host
        func says(_ text: String) -> Bool {
            output.range(of: text, options: .caseInsensitive) != nil
        }

        if says("IDENTIFICATION HAS CHANGED") || says("Host key verification failed") {
            return "The server's SSH identity has changed, so EyeBreak won't connect: someone could be intercepting the connection. If you reinstalled the server, run this on your Mac: ssh-keygen -R \(host)"
        }
        if says("UNPROTECTED PRIVATE KEY") {
            return "macOS won't use an SSH key that others can read. Run this on your Mac: chmod 600 \(connection.keyPath)"
        }
        if says("Permission denied") {
            return "The server refused the SSH login for \(connection.user). EyeBreak only logs in with keys, not passwords. If your key has a passphrase, run ssh-add in Terminal first."
        }
        if says("Could not resolve hostname") {
            return "Can't find \(host). Check the address and your internet connection."
        }
        if says("Connection refused") {
            return "\(host) isn't accepting SSH on port \(connection.port)."
        }
        if says("timed out") {
            return "\(host) didn't answer on port \(connection.port). Check the address, port and firewall."
        }
        if says("No route to host") || says("Network is unreachable") {
            return "Can't reach \(host). Check your internet connection."
        }
        if says("password is required") || says("terminal is required") {
            return "\(connection.user) can't use sudo without a password. Use root, or allow passwordless sudo for this user."
        }
        if says("sudo: not found") || says("sudo: command not found") {
            return "\(connection.user) isn't root and the server has no sudo. Use root instead."
        }
        let lastLine = output.split(whereSeparator: \.isNewline).last.map(String.init)
        return lastLine ?? "The server stopped without saying why."
    }
}
