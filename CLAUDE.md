# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**Hushbreak** — a VLC add-on in Lua that fades the volume down during ad breaks on Triton Digital / StreamTheWorld radio streams (KINK is the reference station) and back up afterwards. It is driven by Triton's now-playing feed, not by listening to the audio. Three files under `src/lua/`:

- `intf/modules/hushbreak_core.lua` — pure logic (feed parsing, spot/block state, ducking math, poll scheduling, drift tracking, calibration). No VLC calls; the test suite runs it with a stock Lua.
- `intf/hushbreak.lua` — the VLC *interface script* (main loop, volume, sleeping, stream restart, marker file). Runs inside VLC via `--extraintf luaintf --lua-intf hushbreak`.
- `extensions/hushbreak_calibrate.lua` — a VLC *extension* with three buttons; it only writes a marker file that the interface script reads.

Read [DEVGUIDE.md](DEVGUIDE.md) for layout, tests, the measurements the timing rests on and the release pipeline; [CONTRIBUTING.md](CONTRIBUTING.md) for conventions.

## GitHub account — always WizX20

This repo is published under the **WizX20** account from a machine whose active `gh` account is a work account. Never run `gh auth switch`. Inside this clone:

- `git push` / `git fetch` already authenticate as WizX20 through the included [`.gitconfig`](.gitconfig) (`task setup` once per clone — check with `git config user.name`, it must print `WizX20`).
- Use **`git gh …`** (or `task gh -- …`) instead of `gh …` for PRs, releases, workflow runs, API calls. Plain `gh` acts as the wrong account.
- Commits must be authored as `WizX20 <nerdsonwaves@outlook.com>`; if `git config user.email` shows anything else, run `task setup` before committing.

## Commands

```powershell
task check        # lint + test — run before every push
task test         # Lua suite via tests/run.lua; `task test -- drift` filters by name
task lint         # luacheck; per-file globals in .luacheckrc
task install      # copy the three scripts into VLC's user Lua folder; `task uninstall` undoes
task pack         # dist/Hushbreak-<version>.zip + sha256
task github-settings         # (re)apply repo settings, labels, main ruleset via git gh
task release [VERSION=x.y.z] # dispatch the Release workflow now; it also runs weekly (Tuesday 06:00 UTC) and auto-bumps the patch version
```

Tools: `scoop install lua luacheck` (any Lua 5.1+ runs the suite; CI uses 5.1 because that is what VLC 3 embeds).

## Rules

- **VLC's Lua is 5.1.** No `goto`, no integer division, no `table.unpack`, no `%d` with a float in `string.format` (format floats with `%.0f`). The API available to an interface script is listed in DEVGUIDE.md — notably there is **no** `vlc.misc.should_die()`: VLC cancels the interface thread inside `mwait`.
- **Logic goes in `hushbreak_core.lua` with a test; VLC calls stay in `hushbreak.lua`.** Test against `tests/fixtures/feed-kink.xml` (a real feed answer) — add a fixture rather than hand-writing XML when a new shape of feed data matters.
- **Never poll blindly.** Every feed entry has a duration; scheduling comes from `core.next_poll` and `core.next_transition`. A failed or empty poll keeps the previous entry list — un-ducking needs the end marker or the grace period, never the mere absence of data (that pumps the volume).
- **Timing constants are measurements, not guesses.** `delay=53`, `feed_lag=50`, the 47 s stream offset: see DEVGUIDE.md → Measurements before changing any of them, and re-measure with the ICY reader described there.
- **Testing in VLC without touching the user's player:** start a separate headless instance (`-I dummy --extraintf luaintf --lua-intf hushbreak --no-one-instance --aout amem --file-logging --logfile <file> --verbose 2`) with `--lua-config "hushbreak={delay=<now - a cue time inside a past block>,resync=false,feed='file:///.../feed-kink.xml'}"`, and stop **only that PID**. Never `Get-Process vlc | Stop-Process`.
- **Changelog**: add a line under `## [Unreleased]`; the release workflow stamps the version (an empty section falls back to commit subjects, so keep subjects readable). Do not touch released sections.
- **Versions**: patch bumps are automatic. For a minor/major, raise `M.VERSION` in `hushbreak_core.lua` (and the extension's `version`) in the PR; the next release ships that version.
- **Settings are documented in three places**: the header of `hushbreak.lua`, the README table, and the defaults table in the script. Change all three.
- **Commits**: imperative subject ≤72 chars, new commits (no amend), no `--no-verify`. Branches `feature/…`, `fix/…`, `chore/…` off `main`.
- **Do not commit or push without asking**; never push to `main` directly — open a PR.
