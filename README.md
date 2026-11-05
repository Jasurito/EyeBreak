# EyeBreak

Menu bar app for the 20-20-20 rule: every 20 minutes (adjustable) of screen time, a popup asks you to look ~6 m (20 ft) away for 20 seconds (also adjustable). Helps with eye strain and dry eyes.

- Countdown popup with Skip / Snooze 5m; doesn't steal keyboard focus
- Timer only counts while you're at the screen: locking the screen, sleep, or 5+ min without input (unless a video is playing) restarts it
- Eye drop schedule: set times and days, get a popup that stays until you press Done or snooze
- Reminder message: keep the default, pick a template, or write and save your own
- Missed a dose with the lid closed? The popup appears as soon as you log back in
- Optional Telegram alerts for eye drops through your own bot, sent from your server or your Mac
- Choose the sound for each event, and add or remove your own audio files
- Settings window: break interval (1–240 min, default 20), break length (5–600 s, default 20), sounds, eye drops, Telegram, start at login
- Daily break counter, pause (30 min / 1 h / until resumed)

## Install

```sh
brew install --cask jasurito/tap/eyebreak
```

Requires macOS 13 or later, Apple Silicon or Intel. Update with `brew upgrade --cask eyebreak`, remove with `brew uninstall --cask eyebreak` (turn off "Start at login" in Settings first).

The app is open source but not notarized by Apple (no paid developer account), so the cask removes the macOS quarantine flag after install. Without that, macOS would refuse the first launch. If you download the zip from [Releases](https://github.com/Jasurito/EyeBreak/releases) manually, try opening the app once, then allow it in System Settings → Privacy & Security → Open Anyway.

## Telegram alerts

Turn on eye drop reminders first: while they're off, the Telegram tab only says so, and its icon is dimmed. Then open Settings → Telegram and follow the steps there: create a bot with [@BotFather](https://t.me/BotFather), paste its token, send `/start` to the bot, then press Find Chat ID. The token is stored in your macOS Keychain.

**Expect a password prompt.** The first time EyeBreak reads the token, macOS asks for your login password: when you press Save with Server selected, or on the first test or alert with Local. Choose Always Allow. It asks once more after each upgrade, because the app isn't signed with a paid certificate and macOS treats each version as a new app.

Then choose what sends the alerts.

### Server

Your own Linux server sends alerts on time, even with the lid closed. It needs systemd and `curl` (Debian and Ubuntu are fine), and an SSH login that uses a key, as root or with passwordless sudo.

Enter the server's IP or domain and press Save. EyeBreak connects with `ssh` and shows each step in a progress bar, then Done or the reason it failed. This works before you've added any times, so you can press Send Test Message straight away. Whenever you change the schedule or message, press Save again: the server's copy is replaced. Remove from Server takes everything off again.

Check Server looks for anything broken without changing the server or asking for your Keychain password. It compares the files with what Save wrote and checks that the schedule is running and will come back after a restart. It also checks that the token file is readable only by root, that the last alert went out, and that Telegram still accepts the token and chat. You get the next alert time, or a list of problems. Save fixes most of them.

On the server this creates:

| Path | What |
| --- | --- |
| `/etc/systemd/system/eyebreak-notification.service` | Sends one message with `curl` |
| `/etc/systemd/system/eyebreak-notification.timer` | Your schedule |
| `/etc/eyebreak/telegram.curl` | Bot token, chat ID and message, readable only by root |

- The bot token is copied to your server. Checks run first, so a failed save leaves the old schedule running.
- The first connection trusts the server's SSH key and remembers it. If it changes later, EyeBreak refuses to connect.
- Times use your Mac's time zone at the moment you save. After changing time zone, press Save again.
- The server only sends the alert at the scheduled time. Done and Snooze apply to the popup on your Mac.

### Local

Your Mac sends the alerts, so nothing goes out while the lid is closed or there's no internet. Alerts go out once the Mac is awake and online, and failed ones are retried until they get through or you press Done.

## Build from source

Needs only the Xcode Command Line Tools.

```sh
make run        # build and launch build/EyeBreak.app (never registers as a login item)
make test       # eye drop schedule and server script tests
make zip VERSION=1.2.0   # universal release zip in build/
```

Test with short intervals:

```sh
open build/EyeBreak.app --args -workSeconds 10 -breakSeconds 5
```

## Releasing

Push a version tag:

```sh
git tag v1.2.0 && git push origin v1.2.0
```

GitHub Actions builds the universal app, publishes the release, and updates the cask in [Jasurito/homebrew-tap](https://github.com/Jasurito/homebrew-tap). See `.github/workflows/release.yml`.

## License

MIT
