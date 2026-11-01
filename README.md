# EyeBreak

Menu bar app for the 20-20-20 rule: every 20 minutes (adjustable) of screen time, a popup asks you to look ~6 m (20 ft) away for 20 seconds. Helps with eye strain and dry eyes.

- Countdown popup with Skip / Snooze 5m; doesn't steal keyboard focus
- Timer only counts while you're at the screen: locking the screen, sleep, or 5+ min without input (unless a video is playing) restarts it
- Break interval setting: presets 10–60 min or any custom 1–240 min (default 20), sound, daily break counter, pause (30 min / 1 h / until resumed), start at login

## Install

```sh
brew install --cask jasurito/tap/eyebreak
```

Requires macOS 13 or later, Apple Silicon or Intel. Update with `brew upgrade --cask eyebreak`, remove with `brew uninstall --cask eyebreak` (turn off "Start at Login" in the menu first).

The app is open source but not notarized by Apple (no paid developer account), so the cask removes the macOS quarantine flag after install. Without that, macOS would refuse the first launch. If you download the zip from [Releases](https://github.com/Jasurito/EyeBreak/releases) manually, try opening the app once, then allow it in System Settings → Privacy & Security → Open Anyway.

## Build from source

Needs only the Xcode Command Line Tools.

```sh
make run        # build and launch build/EyeBreak.app (never registers as a login item)
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
