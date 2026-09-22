# Changelog

All notable changes to Hushbreak are listed here, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are [semantic](https://semver.org/).
Write new entries under **Unreleased** — the Release workflow stamps the version and date.

## [Unreleased]

### Added

- feat: the volume during ad breaks is set from VLC's own menu: View > *Hushbreak* has *softer by* and *never below* with an Apply button, above the calibration buttons. The values apply at once (also to a break that is playing) and are saved to `hushbreak-settings.txt` in VLC's user data folder, which Hushbreak reads at every start; they win over `lua-config`. Any setting can be put in that file by hand. A misspelled setting, in the file or in `lua-config`, is now reported in the messages instead of silently ignored (#19)

### Fixed

- fix: a VLC started, reconnected or switched to the station in the middle of an ad break did nothing for that break. Ducking now follows the state "inside a break" instead of the start of a spot, so it kicks in at once — also in the station's own commercials and jingles after Triton's last spot (27–114 s measured), where no spot is active. The "commercial insert" trigger anchors a block whose spots have already left the feed window. A VLC far behind the feed still waits until it actually reaches the block (#18)
- fix: the time VLC spends connecting (1–5 s measured) no longer counts as drift, which made the fades of every fresh start late by that much

## [0.1.2] - 2026-09-22

### Fixed

- fix: the volume came back up about a minute too early, while commercials were still playing. The feed's "commercial insert" trigger marks the end of Triton's own spots, not of the break — on KINK about 80 s of station commercials and jingles follow it — so it no longer counts as the end marker. Un-ducking now waits until you reach the first titled song after the last spot (not until the feed publishes it — a VLC that has drifted behind would un-duck early), or for `grace` (raised from 120 s to 180 s: measured 114 s from the last spot to the song). The block's spots are remembered while its tail plays, since they scroll out of the feed's 8-entry window before the song appears
- fix: a calibration mark is now checked before it is used: one older than 60 s (left behind while VLC was closed) or one that would give an implausible delay (outside 20..600 s, i.e. pressed against the wrong block) is ignored with a reason in the messages instead of throwing the timing off for the rest of the session. The extension writes the marker atomically (#10)
- fix: the calibration button for the end of a break now measures against the first song after the break (it is labelled *Music is back now*); the last Triton spot it used before is not what you hear as the end
- fix: a stream opened more than 30 s after VLC started, or a station change, was never watched: Hushbreak now follows whatever VLC plays and derives the mount from each new item. Without a StreamTheWorld URL it waits quietly for the next item instead of spinning (#9)
- fix: when the stream dropped or was reconnected in the middle of a break, the volume stayed at the ducked level and the next break ducked from there, leaving the volume permanently lower. The volume is now restored the moment the input disappears (#8)

## [0.1.1] - 2026-09-18

### Fixed

- fix: the volume no longer comes back up in the middle of a break. Un-ducking now needs certainty — the feed's end-of-block trigger or a titled song after the last spot — and otherwise waits a long grace period (`grace`, now 120 s instead of 8): a stalled feed or an untitled promo segment between two runs of spots used to pump the volume up and down

### Changed

- feat: separate fade times, `fade_down` (0.7 s) at the start of a break and a slower `fade_up` (3 s) at the end

## [0.1.0] - 2026-09-18

### Added

- feat: VLC interface script `hushbreak` that fades the volume down during ad breaks on Triton Digital / StreamTheWorld stations (KINK and friends) and back up afterwards, driven by the station's now-playing feed
- feat: settings through `lua-config`: `duck_percent`, `min_volume` (floor), `delay`, `feed_lag`, `grace`, `retry`, `idle`, `mount`, `resync`, `feed`
- feat: polls the feed only when the current song or spot is about to end, and wakes up exactly on spot boundaries
- feat: measures VLC's accumulated lag (stalls, pauses) from its playback position and compensates; restarts the stream at startup so the lag starts from a known value
- feat: `Hushbreak calibration` extension (View menu) with *Ad block starts/ends now* and *Reconnect stream* buttons
- feat: `scripts/install.ps1` / `task install` to copy the scripts into VLC's per-user Lua folder
- feat: Scoop install on Windows — this repo doubles as its own bucket (`scoop bucket add hushbreak https://github.com/WizX20/Hushbreak; scoop install hushbreak`)

