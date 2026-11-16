# screen_doctor

A small macOS menu bar app for eye and standing reminders. The scheduler is written in Rust; a thin native AppKit layer supplies the menu bar icon, anchored popover, settings window, and macOS activity signals.

## Build and run

Requires macOS 13 or later, Rust, and the Apple command line tools. From this repository:

```sh
./package.sh
open dist/screen_doctor.dmg
```

Drag `screen_doctor.app` onto Applications in the DMG before enabling **Launch at login** in Settings. The packaging script applies a local ad hoc signature, which macOS requires for `SMAppService` registration. A build distributed to other Macs should use a Developer ID signature and notarization. The app has no Dock icon; use the menu bar eye icon to open it or quit.

Run `cargo test` to check the activity and break rules.

## How reminders work

- Default eye reminder: every **20 minutes of active computer use**. Choose **Start 20-second look** and look at something about **20 feet away**. The break finishes after 20 seconds, even if you close the popover. You can snooze or dismiss a reminder.
- Default stand reminder: every **120 active minutes** until the **60 minute daily standing goal** is reached. Start and stop standing in the popover, or snooze or dismiss a due reminder. Standing is self reported, and a session stops crediting after 30 minutes to limit accidental overcounting.
- Settings include both reminder intervals, the daily goal, snooze duration, idle threshold, media heuristic, and launch at login. The default template is `settings.toml` in this repository and in the app bundle. On first launch, the app creates `~/Library/Application Support/screen_doctor/settings.toml`; older `config.json` values are migrated. The daily timeline lives in `day.json` in the same directory.
- Use **Choose…** in Settings to load another TOML file and remember its location across launches, including launch at login. **Use Default** switches back. For a one-off launch, pass `--settings /absolute/path/to/settings.toml` to the executable or set `SCREEN_DOCTOR_SETTINGS`. That precedence is command line, environment variable, remembered path, then default. Changes saved in Settings go to the selected file.
- The eye icon is filled while tracking and slashed while paused. macOS colors it to match the menu bar appearance. Tracking pauses when the screen is locked or asleep, or input has been idle beyond the configured threshold.
- The popover header shows **Screen Doctor** with a subdued Tracking or Idle indicator. Eye and standing Snooze and Dismiss stay visible and become available when their reminders are due. Clicking outside the popover closes it.
- The popover shows a **00:00–24:00 timeline** for the current local day: teal marks minutes with observed screen activity, orange marks self-reported standing time, and pink ticks mark when an eye break was started. A thin line shows the current time. The timeline is saved locally in `day.json` and resets at midnight. Activity before this timeline feature was installed cannot be reconstructed.

Long videos often create a `PreventUserIdleDisplaySleep` macOS power assertion. With the media setting enabled, that assertion keeps tracking active while the display is awake and the user session is unlocked, even without mouse or keyboard input. This is a best effort signal: other apps can create the same assertion, and some video players do not. The app does not record keys, inspect browser tabs, or verify gaze or posture. Dismiss and snooze are deliberate overrides, so reminders can encourage the 20/20/20 rule and standing, but cannot enforce them.
