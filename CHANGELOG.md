# Changelog

All notable changes to Hushbreak are listed here, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are [semantic](https://semver.org/).
Write new entries under **Unreleased** — the Release workflow stamps the version and date.

## [Unreleased]

### Fixed

- fix: the volume came back up about a minute too early, while commercials were still playing. The feed's "commercial insert" trigger marks the end of Triton's own spots, not of the break — on KINK about 80 s of station commercials and jingles follow it — so it no longer counts as the end marker. Un-ducking now waits for a titled song after the last spot, or for `grace` (raised from 120 s to 180 s: measured 114 s from the last spot to the song)

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

