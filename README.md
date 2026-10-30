# EyeBreak

Menu bar app for the 20-20-20 rule: every 20 minutes of screen time, a popup asks you to look ~6 m (20 ft) away for 20 seconds.

- Countdown popup with Skip / Snooze 5m; doesn't steal keyboard focus
- Timer only counts while you're at the screen: locking the screen, sleep, or 5+ min without input (unless a video is playing) restarts it
- Sound, daily break counter, pause (30 min / 1 h / until resumed), start at login

## Build

Needs only the Xcode Command Line Tools (macOS 13+).

```sh
make install    # build, copy to /Applications, launch (turns on Start at Login on first run)
make run        # run the dev build from build/ (never registers as a login item)
make uninstall  # turn off "Start at Login" in the menu first
```

Test with short intervals:

```sh
open build/EyeBreak.app --args -workSeconds 10 -breakSeconds 5
```
