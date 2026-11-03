// Tests for the eye drop schedule and the server scripts. Plain asserts, so `make test` needs no Xcode.
import Foundation

var failures = 0

func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL line \(line): \(name)")
    }
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!

/// `day` is a day of October 2026: the 26th is a Monday, the 31st a Saturday.
func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 10, cal: Calendar = calendar) -> Date {
    cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

let saturday = 7
let weekend: Set<Int> = [1, saturday]
let morning = DropDose(hour: 8, minute: 0)
let noon = DropDose(hour: 12, minute: 0)
let night = DropDose(hour: 23, minute: 0)

// Fires once, at its time
check(DropSchedule.dueTimes(of: [noon], lastChecked: date(26, 11, 59), now: date(26, 12, 0), calendar: calendar)
    == [date(26, 12, 0)], "due at the scheduled minute")
check(DropSchedule.dueTimes(of: [noon], lastChecked: date(26, 11, 58), now: date(26, 11, 59), calendar: calendar)
    .isEmpty, "not due early")
check(DropSchedule.dueTimes(of: [noon], lastChecked: date(26, 12, 0), now: date(26, 12, 1), calendar: calendar)
    .isEmpty, "doesn't fire twice")

// Lid closed
check(DropSchedule.dueTimes(of: [morning, noon, night], lastChecked: date(26, 22, 0), now: date(27, 12, 30), calendar: calendar)
    == [date(26, 23, 0), date(27, 8, 0), date(27, 12, 0)], "everything missed overnight, oldest first")
check(DropSchedule.dueTimes(of: [noon], lastChecked: date(1, 9, 0), now: date(27, 13, 0), calendar: calendar)
    == [date(27, 12, 0)], "a long absence only catches up 24 hours")
check(DropSchedule.dueTimes(of: [noon], lastChecked: nil, now: date(27, 13, 0), calendar: calendar)
    .isEmpty, "first run doesn't fire past times")

// Weekdays
let weekendDose = DropDose(hour: 12, minute: 0, weekdays: weekend)
check(DropSchedule.occurrences(of: [weekendDose], after: date(26, 0, 0), through: date(30, 23, 59), calendar: calendar)
    .isEmpty, "weekend dose skips weekdays")
check(DropSchedule.occurrences(of: [weekendDose], after: date(26, 0, 0), through: date(31, 23, 59), calendar: calendar)
    == [date(31, 12, 0)], "weekend dose fires on Saturday")
check(DropSchedule.next(of: [weekendDose], after: date(26, 13, 0), calendar: calendar)
    == date(31, 12, 0), "next finds a later weekday")
check(DropSchedule.next(of: [DropDose(hour: 12, minute: 0, weekdays: [2])], after: date(26, 13, 0), calendar: calendar)
    != nil, "next finds the same weekday a week later")
check(DropSchedule.next(of: [], after: date(26, 13, 0), calendar: calendar) == nil, "no doses, no next")

// Duplicates
check(DropSchedule.occurrences(of: [noon, DropDose(hour: 12, minute: 0)], after: date(26, 11, 0), through: date(26, 13, 0), calendar: calendar)
    .count == 1, "same time counts once")

// Clock changes
var newYork = Calendar(identifier: .gregorian)
newYork.timeZone = TimeZone(identifier: "America/New_York")!
let gapDose = DropDose(hour: 2, minute: 30)  // 02:30 doesn't exist on 8 March 2026
check(DropSchedule.occurrences(of: [gapDose],
                               after: date(7, 12, 0, month: 3, cal: newYork),
                               through: date(9, 12, 0, month: 3, cal: newYork), calendar: newYork)
    .count == 2, "a time skipped by daylight saving still fires")
check(DropSchedule.dueTimes(of: [noon], lastChecked: date(27, 13, 0), now: date(27, 12, 30), calendar: calendar)
    .isEmpty, "clock set back doesn't crash or fire")

// Text
let formatter = DateFormatter()
formatter.dateFormat = "HH:mm"
formatter.timeZone = calendar.timeZone
check(DropSchedule.summary(of: [date(26, 12, 0)], now: date(26, 12, 1), formatter: formatter)
    == "Time for your eye drops", "on time wording")
check(DropSchedule.summary(of: [date(26, 12, 0)], now: date(26, 12, 10), formatter: formatter)
    == "Eye drops overdue: 12:00", "late wording")
check(DropSchedule.summary(of: [date(26, 8, 0), date(26, 12, 0)], now: date(26, 12, 0), formatter: formatter)
    == "Eye drops overdue: 08:00, 12:00", "several doses list their times")

// Saved schedules survive a round trip
let saved = try! JSONEncoder().encode([weekendDose])
check(try! JSONDecoder().decode([DropDose].self, from: saved) == [weekendDose], "doses round-trip through JSON")

// Server schedule
check(ServerSchedule.calendar(of: [DropDose(hour: 8, minute: 5, weekdays: [1, 2, 7])], timeZone: "Asia/Tashkent")
    == ["Sun,Mon,Sat 08:05:00 Asia/Tashkent"], "weekday numbers become systemd day names")
check(ServerSchedule.calendar(of: [noon, morning, DropDose(hour: 8, minute: 0)], timeZone: "UTC")
    == ["Sun,Mon,Tue,Wed,Thu,Fri,Sat 08:00:00 UTC", "Sun,Mon,Tue,Wed,Thu,Fri,Sat 12:00:00 UTC"],
      "sorted, and the same time only once")
check(ServerSchedule.calendar(of: [DropDose(hour: 8, minute: 0, weekdays: [])], timeZone: "UTC").isEmpty,
      "a dose on no days never fires")
check(ServerSchedule.calendar(of: [], timeZone: "UTC").isEmpty, "no doses, no schedule")

// Server details
func connection(host: String = "203.0.113.10", user: String = "root", port: Int = 22,
                keyPath: String = "") -> ServerConnection {
    ServerConnection(host: host, user: user, port: port, keyPath: keyPath)
}

for host in ["203.0.113.10", "example.com", "my-server", "a", "2001:db8::1", "::1"] {
    check(connection(host: host).problem == nil, "accepts \(host)")
}
for host in ["", "-oProxyCommand=touch /tmp/x", "root@example.com", "a b", "a;b", "$(reboot)", "a'b", "a\nb"] {
    check(connection(host: host).problem != nil, "rejects host \(host)")
}
for user in ["", "-x", "a b", "a;b", "a@b"] {
    check(connection(user: user).problem != nil, "rejects user \(user)")
}
check(connection(port: 0).problem != nil, "rejects port 0")
check(connection(port: 65536).problem != nil, "rejects port 65536")
check(connection(keyPath: "/no/such/key").problem != nil, "reports a missing key")
check(connection(keyPath: "/etc/hosts").problem == nil, "accepts a key that exists")

// ssh command
let plain = connection().sshArguments
check(plain.contains("BatchMode=yes"), "never waits for a password")
check(plain.suffix(3) == ["--", "203.0.113.10", ServerScript.runAsRoot], "host comes after --, script from stdin")
check(!plain.contains("-i"), "no key flag unless one is set")
let keyed = connection(keyPath: "~/.ssh/key").sshArguments
check(keyed.contains("IdentitiesOnly=yes") && !keyed.contains("~/.ssh/key"), "key path is expanded and used alone")

// Server script
let goodToken = "123456:ABC-def_0"
let times = ["Mon,Wed 08:00:00 Asia/Tashkent"]
func install(_ calendar: [String], message: String = DropMessage.standard) -> String {
    try! ServerScript.install(calendar: calendar, token: goodToken, chatID: "42", message: message)
}
func rejected(token: String = goodToken, chatID: String = "42", calendar: [String] = times) -> Bool {
    (try? ServerScript.install(calendar: calendar, token: token, chatID: chatID, message: "x")) == nil
}
check(!rejected(), "a good install is accepted")
check(!rejected(chatID: "-1001234"), "group chat IDs are accepted")
check(!rejected(chatID: "@my_channel"), "channel usernames are accepted")
check(rejected(token: "123456:abc\"; reboot; \""), "a token can't break out of the script")
check(rejected(chatID: "42\nEYEBREAK\nreboot"), "a chat ID can't break out of the script")
check(rejected(chatID: ""), "needs a chat ID")
check(!rejected(calendar: []), "the service can be set up before there's a schedule")
check(rejected(calendar: ["Mon 08:00:00 UTC'; reboot; '"]), "a schedule can't break out of the script")

let script = install(["Mon 08:00:00 UTC", "Tue 09:30:00 UTC"])
check(script.contains("OnCalendar=Mon 08:00:00 UTC\nOnCalendar=Tue 09:30:00 UTC\n"), "one timer line per time")
check(script.contains("/etc/systemd/system/eyebreak-notification.service"), "service in the agreed place")
check(script.contains("restart eyebreak-notification.timer") && !script.contains("disable --now"), "a schedule starts the timer")
let noSchedule = install([])
check(noSchedule.contains("eyebreak-notification.service") && !noSchedule.contains("OnCalendar"), "no times: service but no timetable")
check(noSchedule.contains("disable --now eyebreak-notification.timer"), "no times: an old schedule is cleared")
let lines = script.components(separatedBy: "\n")
check(lines.filter { $0.contains(goodToken) }.allSatisfy { $0.hasPrefix("url = ") }, "token only appears in curl config")
let firstWrite = script.range(of: "mkdir -p /etc/eyebreak")!.lowerBound
check(script.range(of: "getChat")!.lowerBound < firstWrite, "Telegram is checked before anything is written")

// Messages
check(DropMessage.clean("  Use Systane  ") == "Use Systane", "message is trimmed")
check(DropMessage.clean("") == DropMessage.standard, "empty message means the default")
check(DropMessage.clean(" \n ") == DropMessage.standard, "blank message means the default")
check(DropMessage.clean("one\ntwo") == "one two", "message stays on one line")
check(DropMessage.clean(String(repeating: "a", count: 500)).count == DropMessage.maxLength, "message is capped")
check(DropMessage.templates.first == DropMessage.standard, "default is first in the list")
check(DropSchedule.summary(of: [date(26, 12, 0)], now: date(26, 12, 1), message: "Use Systane", formatter: formatter)
    == "Use Systane", "custom message on time")
check(DropSchedule.summary(of: [date(26, 12, 0)], now: date(26, 13, 0), message: "Use Systane", formatter: formatter)
    == "Eye drops overdue: 12:00\nUse Systane", "custom message stays when late")

func textLine(_ script: String) -> String {
    script.components(separatedBy: "\n").first { $0.hasPrefix("data-urlencode = \"text=") } ?? ""
}
check(textLine(install(times)) == #"data-urlencode = "text=💧 Time for your eye drops""#, "default message on the server")
check(textLine(install(times, message: #"say "hi""#)) == #"data-urlencode = "text=💧 say \"hi\"""#, "quotes are escaped")
check(textLine(install(times, message: #"a\b"#)) == #"data-urlencode = "text=💧 a\\b""#, "backslashes are escaped")
check(textLine(install(times, message: "$(reboot) `reboot` 'x'")).contains("$(reboot) `reboot` 'x'"), "shell syntax is plain text")
for attack in ["x\nEYEBREAK\nreboot\n", "x\r\nEYEBREAK\r\nreboot\r\n", "\"\nurl = \"https://evil.example"] {
    let lines = install(times, message: attack).components(separatedBy: .newlines)
    check(!lines.contains("reboot") && !lines.contains { $0.hasPrefix("url = \"https://evil") },
          "a message can't break out of the script")
    check(lines.filter { $0 == "EYEBREAK" }.count == lines.filter { $0.hasSuffix("<<'EYEBREAK'") || $0.contains("<<'EYEBREAK'") }.count,
          "a message can't end the file early")
}

let oldInstall = #"{"chatID":"42","tokenChanged":false,"calendar":[],"connection":{"host":"h","user":"root","port":22,"keyPath":""}}"#
let decoded = try? JSONDecoder().decode(ServerInstall.self, from: Data(oldInstall.utf8))
check(decoded != nil && decoded?.message == nil, "an install saved before messages existed still loads")

// Progress and errors
check(ServerProgress(line: "STEP 2/5 Checking the schedule") == ServerProgress(label: "Checking the schedule", fraction: 0.2),
      "reads a step")
check(ServerProgress(line: "STEP 1/1 Sending") == ServerProgress(label: "Sending", fraction: 0), "first step starts at zero")
for line in ["", "STEP", "STEP 2/0 x", "STEP a/b x", "Welcome to Debian"] {
    check(ServerProgress(line: line) == nil, "ignores \(line)")
}

func explained(_ output: String) -> String { ServerErrors.explain(output, connection: connection(keyPath: "/k")) }
check(explained("root@203.0.113.10: Permission denied (publickey).").contains("refused"), "explains a refused key")
check(explained("ssh: Could not resolve hostname x: nodename nor servname").contains("Can't find"), "explains a bad address")
check(explained("ssh: connect to host x port 22: Connection refused").contains("port 22"), "explains a closed port")
check(explained("ssh: connect to host x port 22: Operation timed out").contains("didn't answer"), "explains a timeout")
check(explained("Host key verification failed.").contains("ssh-keygen -R"), "explains a changed host key")
check(explained("sudo: a password is required").contains("passwordless"), "explains sudo")
check(explained("sh: 1: sudo: not found").contains("Use root"), "explains missing sudo")
check(explained("first\nsomething odd\n") == "something odd", "unknown errors show their last line")
check(explained("") == "The server stopped without saying why.", "never shows a blank reason")

if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
print("all tests passed")
