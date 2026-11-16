# screen_doctor

A small macOS menu bar app for eye and standing reminders. The scheduler is written in Rust; a thin native AppKit layer supplies the menu bar icon, anchored popover, settings window, and macOS activity signals.

## Build and run

Requires macOS 13 or later, Rust, and the Apple command line tools. From this repository:

```sh
./package.sh
open dist/screen_doctor.app
```

Move `screen_doctor.app` to `/Applications` before enabling **Launch at login** in Settings. The packaging script applies a local ad hoc signature, which macOS requires for `SMAppService` registration. A distributed build should use a Developer ID signature and notarization. The app has no Dock icon; use the menu bar eye icon to open it or quit.

Run `cargo test` to check the activity and break rules.

## How reminders work

- Default eye reminder: every **20 minutes of active computer use**. Choose **Start 20-second look** and look at something about **20 feet away**. The break finishes after 20 seconds, even if you close the popover. You can snooze or dismiss a reminder.
- Default stand reminder: every **60 active minutes** until the **60 minute daily standing goal** is reached. Start and stop standing in the popover. Standing is self reported, and a session stops crediting after 30 minutes to limit accidental overcounting.
- Settings include both reminder intervals, the daily goal, snooze duration, idle threshold, media heuristic, and launch at login. Settings and daily standing totals live in `~/Library/Application Support/screen_doctor/`.
- The eye icon is filled and green while tracking, and slashed and gray while paused. It pauses when the screen is locked or asleep, or input has been idle beyond the configured threshold.

Long videos often create a `PreventUserIdleDisplaySleep` macOS power assertion. With the media setting enabled, that assertion keeps tracking active while the display is awake and the user session is unlocked, even without mouse or keyboard input. This is a best effort signal: other apps can create the same assertion, and some video players do not. The app does not record keys, inspect browser tabs, or verify gaze or posture. Dismiss and snooze are deliberate overrides, so reminders can encourage the 20/20/20 rule and standing, but cannot enforce them.
