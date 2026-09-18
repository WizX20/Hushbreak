# Changelog

All notable changes to Hushbreak are listed here, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are [semantic](https://semver.org/).
Write new entries under **Unreleased** — the Release workflow stamps the version and date.

## [Unreleased]

### Added

- feat: VLC interface script `hushbreak` that fades the volume down during ad breaks on Triton Digital / StreamTheWorld stations (KINK and friends) and back up afterwards, driven by the station's now-playing feed
- feat: settings through `lua-config`: `duck_percent`, `min_volume` (floor), `delay`, `feed_lag`, `grace`, `retry`, `idle`, `mount`, `resync`, `feed`
- feat: polls the feed only when the current song or spot is about to end, and wakes up exactly on spot boundaries
- feat: measures VLC's accumulated lag (stalls, pauses) from its playback position and compensates; restarts the stream at startup so the lag starts from a known value
- feat: `Hushbreak calibration` extension (View menu) with *Ad block starts/ends now* and *Reconnect stream* buttons
- feat: `scripts/install.ps1` / `task install` to copy the scripts into VLC's per-user Lua folder
- feat: Scoop install on Windows — this repo doubles as its own bucket (`scoop bucket add hushbreak https://github.com/WizX20/Hushbreak; scoop install hushbreak`)
