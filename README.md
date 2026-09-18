<p align="center">
  <a href="https://github.com/WizX20">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/wizx20.png">
      <img src="docs/wizx20-transparent.png" alt="WizX20" height="140">
    </picture>
  </a>
</p>

# Hushbreak

[![CI](https://github.com/WizX20/Hushbreak/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/WizX20/Hushbreak/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/WizX20/Hushbreak?label=release)](https://github.com/WizX20/Hushbreak/releases/latest)

A VLC add-on that hushes the ad breaks on internet radio. Listen to a Triton Digital / StreamTheWorld station such as [KINK](https://www.kink.nl) in VLC, and Hushbreak fades the volume down when the commercials start and back up when they are over. How much softer, and how soft at most, is yours to set.

It works because Triton publishes a *now-playing feed* for every station it streams: each song, jingle and ad spot appears there with a start time and a duration. Hushbreak follows that feed, works out how far behind the live feed your VLC is playing, and times the fades to what you actually hear.

Hushbreak is a small Lua add-on that runs *inside* VLC — nothing to keep running next to it — and it exists thanks to two things it builds on: [VLC media player](https://www.videolan.org/vlc/) from the [VideoLAN](https://www.videolan.org/) project, free and open source, whose Lua scripting makes add-ons like this possible, and the [StreamTheWorld](https://www.tritondigital.com/products/streaming/streamtheworld) streaming platform by [Triton Digital](https://www.tritondigital.com/), whose public now-playing feed is what makes the ad breaks predictable. Neither is affiliated with this project.

> See the [Changelog](CHANGELOG.md) for updates.

## License

This project is licensed under the [Business Source License 1.1](LICENSE) (BUSL-1.1). Free for personal, internal, academic, and non-commercial redistribution use; resale or paid commercial distribution is not permitted. Converts to Apache 2.0 on the Change Date (2030-09-01). All copies and forks must retain the [NOTICE](NOTICE) file.

## Requirements

- **VLC 3.x** — free download at [videolan.org/vlc](https://www.videolan.org/vlc/) for Windows, macOS and Linux (tested with 3.0.23 on Windows 11; the scripts are plain Lua 5.1 and should run on the Linux and macOS builds too)
- A station streamed by **[StreamTheWorld](https://www.tritondigital.com/products/streaming/streamtheworld)** (Triton Digital) — the stream URL looks like `https://<n>.live.streamtheworld.com/<MOUNT>_SC`. [KINK](https://www.kink.nl), KINK DNA and KINK Distortion are known to work; most stations on that platform publish the same feed.

## Install

### Windows — Scoop (recommended)

```powershell
scoop bucket add hushbreak https://github.com/WizX20/Hushbreak
scoop install hushbreak
```

(This repo doubles as its own Scoop bucket. The first `hushbreak` is just the local name you give that bucket; the second is the app, from `bucket/hushbreak.json`.) The install copies the three scripts into `%APPDATA%\vlc\lua\`; `scoop update hushbreak` refreshes them and `scoop uninstall hushbreak` removes them again. Then tell VLC to run Hushbreak, once — see *Run* below.

winget: later, see [#4](https://github.com/WizX20/Hushbreak/issues/4).

### Manual (any OS)

1. Download `Hushbreak-<version>.zip` from the [latest release](https://github.com/WizX20/Hushbreak/releases/latest).
2. Unpack it into VLC's per-user data folder so that the `lua` folder inside the zip lands next to `vlcrc`:
   - Windows: `%APPDATA%\vlc\` (paste that into Explorer's address bar)
   - Linux: `~/.local/share/vlc/`
   - macOS: `~/Library/Application Support/org.videolan.vlc/`

   You end up with `lua/intf/hushbreak.lua`, `lua/intf/modules/hushbreak_core.lua` and `lua/extensions/hushbreak_calibrate.lua` in that folder. No admin rights, nothing in the program folder.
3. Restart VLC.

From a checkout: `task install` (or `pwsh scripts/install.ps1`) copies the same three files; `task uninstall` removes them.

## Run

Hushbreak is a VLC *interface script*: VLC runs it alongside its normal window once you ask for it.

**One-off, from the command line:**

```
vlc --extraintf luaintf --lua-intf hushbreak KINK.pls
```

**Permanently, in VLC's preferences** (Tools > Preferences, bottom left *Show settings: All*):

- Interface > Main interfaces > *Extra interface modules*: `luaintf`
- Interface > Main interfaces > Lua > *Lua interface*: `hushbreak`
- Interface > Main interfaces > Lua > *Lua interface configuration*: your settings, see below (optional)

Save and restart VLC. From then on every stream you play in VLC is watched; on streams that are not StreamTheWorld stations Hushbreak just logs that it cannot find a feed and does nothing.

Open Tools > Messages (verbosity 2, filter `hushbreak`) to watch it work:

```
[hushbreak] Hushbreak 0.1.0 starting: duck 60%, floor 0%, base delay 53 s
[hushbreak] mount KINK (from the stream URL)
[hushbreak] delay versus the feed: 53 s (base 53 + VLC drift 0)
[hushbreak] ad break: volume 256 -> 102 (RO VUURWERK R30)
[hushbreak]   next spot: LIDL WK36 HOOFDSPOT TUINTJES R15
[hushbreak] ad break over: volume back to 256
```

## Settings

Settings travel in VLC's `lua-config` option as a Lua table named after the script. On the command line:

```
vlc --extraintf luaintf --lua-intf hushbreak --lua-config "hushbreak={duck_percent=80,min_volume=10}" KINK.pls
```

In the preferences the same text, `hushbreak={duck_percent=80,min_volume=10}`, goes into *Lua interface configuration*.

| Setting | Default | Meaning |
|---|---|---|
| `duck_percent` | `60` | How much softer during ads, in percent of the current volume. `60` turns 100 % into 40 %. |
| `min_volume` | `0` | Floor for the ducked volume, in percent of full volume. With `min_volume=25` an ad never plays below 25 %, whatever `duck_percent` says. |
| `delay` | `53` | Seconds a *freshly connected* VLC lags behind the feed's cue times. Measured for KINK: the stream leaves the server 47 s behind the cue times (Triton buffers for the ad insertion) plus ~6 s of VLC buffering. See *Calibration*. |
| `feed_lag` | `50` | Seconds between an entry's cue start and its appearance in the feed. Used to time the polls. |
| `grace` | `8` | Seconds to stay ducked after the last known spot when the feed has not confirmed the end of the block yet. Avoids pumping the volume when a poll fails. |
| `retry` | `2` | Seconds between polls while the feed is late with the next entry. |
| `idle` | `60` | Longest pause between polls. |
| `mount` | *(auto)* | Triton mount name, e.g. `KINK`. Derived from the stream URL (`.../KINK_SC`) when omitted. |
| `resync` | `true` | Restart the stream when Hushbreak starts, so the lag is known. See below. |
| `feed` | *(auto)* | Override the feed URL; `{mount}` is replaced by the mount name. For testing. |

## Calibration

Everything hinges on *how far behind the feed you are hearing the stream*. Two things move that number:

- **The session start.** Triton's server resumes an existing connection where it left off. A VLC that has been playing for hours, with a few hiccups on the way, can be minutes behind a fresh connection — and nothing in VLC tells you by how much. That is why Hushbreak restarts the stream when it starts (`resync`): a new connection lands on the base `delay`. Two seconds of silence, once.
- **Stalls and pauses while playing.** These add up too, but Hushbreak measures them from VLC's playback position and compensates automatically. The messages show `delay versus the feed: 61 s (base 53 + VLC drift 8)` when that happens.

If the fades still come early or late, calibrate by ear: open View > *Hushbreak calibration* and press **Ad block ends now** at the moment you hear the last commercial end (or **Ad block starts now** at the first one). Hushbreak computes the real delay from the feed and uses it from then on; the messages confirm with `calibrated on block end: delay is now 57 s`. The *ends now* button is the reliable one: by then the feed always knows the whole block. **Reconnect stream** restarts the stream, the same thing `resync` does at startup.

For a different station the base `delay` may differ; calibrate once and pass the number as `delay=...` next time.

## How it works

- Every entry in the feed (song, jingle, spot, "commercial insert" trigger) has a start and a duration, so Hushbreak knows when the current entry ends and polls just after that moment instead of on a fixed interval — once per song, once per spot. Ad blocks are made of contiguous spots; the *insert* trigger sits exactly at the end of a block and serves as the end marker.
- Volume goes down and up in a short fade (six steps, ~0.7 s). If you change the volume yourself during a break, Hushbreak leaves it where you put it.
- The pure logic lives in `hushbreak_core.lua` and is covered by the test suite against a real feed answer; `hushbreak.lua` is the thin VLC layer around it. [DEVGUIDE.md](DEVGUIDE.md) has the details, including the measurements this is built on.

## Credits

- [VLC media player](https://www.videolan.org/vlc/) by the [VideoLAN](https://www.videolan.org/) project — the player, and the Lua scripting that lets Hushbreak run inside it. Download it there if you do not have it yet.
- [Triton Digital](https://www.tritondigital.com/) — the [StreamTheWorld](https://www.tritondigital.com/products/streaming/streamtheworld) platform and its public now-playing feed.
- [KINK](https://www.kink.nl) — the station this was built and measured on.

Hushbreak is an independent project and not affiliated with or endorsed by VideoLAN, Triton Digital or KINK.

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Other stations or stream providers are the most interesting kind of contribution: open a *Station request* issue with what you know about how the stream marks its ads.
