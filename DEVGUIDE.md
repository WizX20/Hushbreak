# Developer Guide

How the pieces fit, how to run and test them, the measurements the timing rests on, and how a release gets out. For contribution conventions see [CONTRIBUTING.md](CONTRIBUTING.md).

## Layout

```
src/lua/intf/hushbreak.lua                 VLC interface script: the loop, volume, sleep, stream restart
src/lua/intf/modules/hushbreak_core.lua    pure logic, no VLC calls; carries M.VERSION
src/lua/extensions/hushbreak_calibrate.lua VLC extension: three buttons -> marker file
tests/run.lua                              dependency-free test runner
tests/hushbreak_core_test.lua              the suite
tests/fixtures/feed-kink.xml               a real feed answer (KINK, 2026-09-18, 14 entries: spots, trigger, station tail, songs)
scripts/*.ps1                              lint, test, install, pack, set-version, cut-changelog, bootstrap-github
.github/workflows/ci.yml                   lint + test on Lua 5.1, pack, release-token expiry
.github/workflows/release.yml              weekly / manual release
```

VLC finds the scripts by folder: `lua/intf/<name>.lua` is an interface script started with `--lua-intf <name>`, `lua/intf/modules/` is on the `require` path of interface scripts, `lua/extensions/` is scanned for the View menu. All three folders are searched in the per-user data dir first (`%APPDATA%\vlc\lua` on Windows), then in the program folder, so `task install` never touches `C:\Program Files`.

## Running from source

```powershell
task install                                        # copy the three files into %APPDATA%\vlc\lua
vlc --extraintf luaintf --lua-intf hushbreak KINK.pls
```

Edit, `task install` again, restart VLC (VLC reads the script once at startup). Watch Tools > Messages with verbosity 2 and filter `hushbreak`, or start VLC with `--verbose 2 --file-logging --logfile hushbreak.log` and tail the file.

### Testing the VLC layer without waiting for an ad break

Start a *second*, headless VLC that plays the stream silently, reads the fixture instead of the live feed, and thinks "now" lies inside the fixture's ad block:

```powershell
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$delay = $now - 1789729199        # a cue time inside the fixture's block (BEEQUIP FINAL)
$feed = "file:///C:/Repos/GitHub/Hushbreak/tests/fixtures/feed-kink.xml"
& 'C:\Program Files\VideoLAN\VLC\vlc.exe' -I dummy --extraintf luaintf --lua-intf hushbreak `
    --lua-config "hushbreak={delay=$delay,resync=false,feed='$feed'}" `
    --no-one-instance --aout amem --verbose 2 --file-logging --logfile hushbreak-test.log KINK.pls
```

Within a second the log shows `ad break: volume 256 -> 102 (BEEQUIP FINAL)`, then `next spot: KV WK38 ALWAYS`, `next spot: INTERPOLIS GRIPOPCYBER`, and 111 s after the last spot `ad break over: volume back to 256` — the fixture carries the song after the block (Supersonic, 114 s after the last spot), and the fade-up starts `fade_up` seconds before the listener reaches it. `--aout amem` keeps it silent, `--no-one-instance` keeps it away from the VLC you listen with. Stop it by its own PID; never kill every `vlc` process, the listener's VLC is one of them.

## Tests and lint

```powershell
task check          # both
task test           # lua tests/run.lua; `task test -- drift` filters by case name
task lint           # luacheck src tests
```

Any Lua from 5.1 up runs the suite (`scoop install lua` on Windows gives 5.5, `apt install lua5.1` on Debian/Ubuntu); CI uses 5.1 because that is the version VLC 3 embeds (`lua/intf/cli.luac` starts with `1b 4c 75 61 51` — bytecode version 0x51). The core module must therefore stay 5.1-compatible: no `goto`, no `//`, no bit operators, no `table.unpack`, and no `%d` with a non-integer float in `string.format` (5.3+ raises on that; use `%.0f`).

The runner is `tests/run.lua`: it registers cases with `test(name, fn)`, offers `assert_eq`, `assert_near`, `read_fixture`, prints one line per case and exits non-zero on failure. No busted, no luarocks — nothing to install beyond an interpreter.

## The VLC Lua API as seen from an interface script (VLC 3.0.23)

Discovered by dumping `vlc.*` from a throwaway interface script; VLC ships no README with the Windows build.

| Table | Functions |
|---|---|
| `vlc.misc` | `mdate` (µs, monotonic), `mwait(deadline_µs)`, `quit`, `version`, `copyright`, `license`, `action_id` — **no `should_die`**; VLC cancels the interface thread while it sits in `mwait`, so the main loop is `while true`. |
| `vlc.volume` | `get` / `set(0..512)` / `up` / `down`; 256 = 100 %. |
| `vlc.playlist` | `current` (item id), `gotoitem(id)` = restart that item = new connection, `status`, `play`, `pause`, `stop`, … |
| `vlc.object` | `input()` (nil when idle), `playlist`, `libvlc`, `aout`, `vout`, `find`. |
| `vlc.var` | `get(obj, name)` — `"time"` on the input is the playback position in µs. |
| `vlc.input` | `item()` → `:uri()`, `:name()`, `:metas()`; `is_playing`. |
| `vlc.config` | `userdatadir`, `datadir`, `configdir`, `cachedir`, `homedir`, `get`, `set`. |
| `vlc.stream(url)` | Opens any URL through VLC's access modules (https, file, …): `:read(n)`, `:readline()`. |
| `vlc.io` | `open` (Unicode-safe paths on Windows), `unlink`, `mkdir`, `readdir`. Plain `io`/`os` exist too. |
| `vlc.msg` | `dbg`, `info`, `warn`, `err`. |
| `config` | The Lua table given as `--lua-config "hushbreak={...}"`, keyed by script name. |

Extensions additionally get `vlc.dialog` (labels, buttons, …) and are event-driven: no loop, no timer. That is why the polling lives in an interface script and the buttons in an extension, joined by a marker file in `vlc.config.userdatadir()`.

`vlc.input.item():metas()` does **not** expose the stream's ICY `StreamTitle` on these HTTPS streams (the new HTTP stack drops it), so the in-band metadata cannot be read from inside VLC; the feed is the only source.

## Measurements (KINK, 2026-09-18)

All timing in Hushbreak comes from these; re-measure before changing a default.

- **The feed is late by 50 s.** Each entry appears in `np.tritondigital.com/public/nowplaying` about 50 s after its `cue_time_start` (11 spots measured: 49–56 s, median 51). Entries border on each other: a spot's `cue_time_start + cue_time_duration` is the next entry's start to within a few ms.
- **The stream is 47.5 s behind cue time.** A raw connection to the stream (`Icy-MetaData: 1`, reading the interleaved `StreamTitle`) shows each song title 47–48 s after the feed's cue time for that song — Triton buffers the stream for its ad insertion. Reader: `python tools/icy_watch.py https://22343.live.streamtheworld.com/KINK_SC` prints every metadata change with the wall-clock time; compare with the feed's `cue_time_start` for the same song.
- **A fresh VLC hears the stream ~5–6 s after it leaves the server** (server burst ≈ 4.7 s + 1 s `network-caching`). Hence the base `delay` of **53 s** for a freshly connected VLC. Confirmed by ear: with 53 s the fade landed on the first commercial. `--network-caching N` adds `(N − 1000)/1000` s on top.
- **A long-running VLC can be minutes behind.** Triton resumes an existing session where it left off after a stall; nothing in VLC's stats reveals the accumulated offset (the playback position only shows stalls *since the connection*, and was 26 s off while the listener was ~3 min behind). Hence `resync` at startup and the calibration buttons.
- **The insert trigger is not the end of the commercials.** After the last spot the feed carries an `ad` entry with `ad_type=insert` (title "COMMERCIAL INSERT TRIGGER …") whose `cue_time_start` equals the last spot's end. It marks the end of Triton's own spots only: in the fixture's block (13:00 CEST) it is followed by an untitled 8 s entry, an untitled 71 s entry that the listener heard as commercials, four untitled jingles (35 s), and the first titled song **114 s after the last spot**. Un-ducking on the trigger brought the volume up ~1 minute early (v0.1.1). `block_ended` therefore waits until the listener reaches the first titled song after the last spot (the song is published at cue + 50 s but heard at cue + `delay`, so the gate is on stream time, not on publication) and otherwise for `grace` (180 s, measured 114 s plus room for a longer station block and the feed's lag variance). The live feed is an 8-entry window and the block's spots scroll out of it while that tail plays, so `hushbreak.lua` merges every poll into the entries it kept (`merge_entries`). The "end" calibration button compares against that song, not against the last spot.
- **The feed server is slow at times** — 2–3 s response times and occasional 5+ s stalls, from every client. That is why a failed poll keeps the previous entry list and un-ducking never follows from missing data alone.
- **`eventType=track,ad` returns nothing**; `eventType=track` or `eventType=ad` work, and no filter returns everything. The feed URL therefore has no filter.
- The in-band `StreamTitle` is empty during commercials and jingles and carries `Artist - Title` during songs. It cannot be read from inside VLC (see above), so it is not used; a future external helper could.

Mounts seen with ad cues: `KINK`, `KINK_DNA` (the "80s" playlist), `KINK_DISTORTION`. The mount is the stream path without `_SC`.

## GitHub account: everything as WizX20

This repo is published from a machine that also has a work GitHub account logged in to `gh`. Rather than `gh auth switch` back and forth, the repo carries a [`.gitconfig`](.gitconfig) that a maintainer includes once per clone:

```powershell
task setup      # = git config --local include.path ../.gitconfig
```

From then on, inside this clone:

- commits are authored as `WizX20 <…>`;
- `git push` / `git fetch` authenticate as WizX20 — the credential helper obtains that account's token from the keyring at call time via `gh auth token --user WizX20` and hands it to `gh auth git-credential` through `GH_TOKEN` (the CLI's helper otherwise only serves the *active* account);
- `git gh <anything>` (or `task gh -- <anything>`) runs the GitHub CLI the same way: `git gh pr create`, `git gh run watch`, …

Nothing is written to disk and the active `gh` account is untouched. Plain `gh` still uses whatever account is active — use `git gh` in this repo. Contributors never need any of this; without the include the file is inert.

## Repository settings

`task github-settings` (= `scripts/bootstrap-github.ps1`) applies, idempotently: description and topics; issues and discussions on, wiki and projects off; squash merges only, branches deleted on merge; the label set (`bug`, `enhancement`, `station`, `status/planned`, `status/in-progress`, `triage`, `maintenance`, …); and the `main` ruleset described below. Run it after creating the repository and again whenever a required check is renamed.

## Release process

Releases are cut by `.github/workflows/release.yml`. It runs **once a week, Tuesday 06:00 UTC**, and on manual dispatch — nothing else triggers it:

```powershell
task release                    # release now: next patch version (or the sources' version if that was never released)
task release VERSION=1.1.0      # release now with an explicit version
```

The `check` job decides first, on `main`:

1. **Anything to release?** If `main` is exactly the commit of the latest `v*` tag, stop quietly (the weekly run is a no-op on a quiet week).
2. **Which version?** The dispatch input if given; else `M.VERSION` from `hushbreak_core.lua` when no tag for it exists yet (first release, or a bump made in a PR); else the next patch of it. For a **minor/major** bump, raise `M.VERSION` in your PR — the next release ships exactly that.
3. **Validate** — plain `x.y.z`, no such tag yet, not below the source version.
4. **Gate on CI** — the CI run of the exact commit on `main` must be `success`.

Then the `release` job:

5. **Stamp** — `scripts/set-version.ps1` writes the version into `hushbreak_core.lua` and the extension's descriptor; `scripts/cut-changelog.ps1 -FallbackFromGit` turns `## [Unreleased]` into `## [x.y.z] - <date>` and extracts that section as the release notes. An empty section is filled from the commit subjects since the last tag, so write readable subjects even when you skip the changelog.
6. **Lint + test** the stamped sources on Lua 5.1.
7. **Pack** — `scripts/pack.ps1` builds `dist/Hushbreak-x.y.z.zip` (`lua/` tree plus `LICENSE`, `NOTICE`, `README.md`) and prints its SHA256.
8. **Bump the bucket** — `bucket/hushbreak.json` gets the new `version`, `url` and `hash`, edited in place.
9. **Commit + tag** `chore: release vx.y.z` on `main` (as `github-actions[bot]`), push with the `vx.y.z` tag.
10. **GitHub Release** `vx.y.z` with the zip attached, the changelog section and the SHA256 as body.

If step 10 fails after step 9 pushed, create the release by hand with `git gh release create vx.y.z dist/Hushbreak-x.y.z.zip` from a fresh checkout of the tag — the tag check in step 3 refuses a re-run.

### First release

`bucket/hushbreak.json` ships with a placeholder hash until the first release has run; `scoop install hushbreak` fails with a hash mismatch before that. Run `task release` once the repo is on GitHub and CI is green — it ships the sources' `0.1.0`.

### Required secret: `HUSHBREAK_RELEASE_TOKEN`

`main` is protected by a ruleset (pull requests only, squash merges only, CI checks required, no force-push; only the repository admin may bypass). `GITHUB_TOKEN` cannot bypass rulesets on a user-owned repository, so the release commit is pushed with a maintainer token:

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate. Resource owner `WizX20`, repository access: only `Hushbreak`, permissions: **Contents: Read and write** (Metadata: Read is added automatically). Expiry: one year at most — note the date in the rotation issue ([#2](https://github.com/WizX20/Hushbreak/issues/2)).
2. `git gh secret set HUSHBREAK_RELEASE_TOKEN -R WizX20/Hushbreak` and paste the token.

The `check` job fails early with a clear message when the secret is missing. CI's required **release token expiry** job reads the token's real expiry from the API on every PR and push: a warning 30 days out, a failure 14 days out — so an expiring token blocks merges until it is rotated. A push with this token also triggers CI on `main` for the release commit — expected, one extra run per release.

### Branch rules (ruleset `main`)

Managed on GitHub (**Settings → Rules → Rulesets → main**) and by `task github-settings`. Pull request required, `squash` the only merge method, required checks `lint + test (Lua 5.1)`, `pack release zip` and `release token expiry`, deletion and force-push blocked; bypass list: repository admin only. Direct pushes to `main` are therefore impossible for everyone but the owner, and a PR cannot be squash-merged before CI is green.

### Repo visibility

Scoop fetches release assets over unauthenticated HTTPS. `WizX20/Hushbreak` must stay **public** for `scoop install` to work.

## Scoop bucket maintenance

- Manifest: `bucket/hushbreak.json`. The release workflow bumps `version`/`url`/`hash`; `checkver: github` + `autoupdate` let `scoop update` find new releases.
- Users subscribe to the bucket straight from this repo: `scoop bucket add hushbreak https://github.com/WizX20/Hushbreak`. The bucket name is a local alias for the repo URL — Scoop keys buckets by that alias, one repo each, so this project needs its own alias next to `psworktree` and ActionsMonitor's `wizx20`. A shared `WizX20/scoop-bucket` is tracked in PSWorktree #8; until then, per-repo buckets keep each release self-contained.
- Scoop unpacks the zip into `~/scoop/apps/hushbreak/current` (the `lua/` tree, LICENSE, NOTICE, README) and `post_install` copies the three scripts into `%APPDATA%lc\lua\`, because VLC only loads scripts from its own folders. `post_install` also runs on `scoop update`, so an update refreshes the copies; `post_uninstall` deletes them and leaves VLC's preferences alone.
- To try a manifest change before a release, test the hook script on its own: load `bucket/hushbreak.json`, `[scriptblock]::Create($m.post_install -join "`r`n")`, and invoke it with `$dir` set to a folder that holds a `lua/` tree.

## winget

Not yet. winget has no notion of VLC add-ons; publishing means wrapping the scripts in an installer that copies them into `%APPDATA%lc\lua`. Tracked in issue #4 — the README says so.

## Conventions

- **Changelog** — add a line under `## [Unreleased]` for user-visible changes; the release workflow stamps the version. Never edit released sections.
- **Settings** — documented in the script header, the README table and the defaults table. Change all three.
- **Commits** — new commits, no amends of published commits, no skipped hooks.
- **Timing constants** — measurements, with the method written down here. Re-measure, then change.
