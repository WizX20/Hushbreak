<!--
Thanks for the PR! Fill in the sections below — the checklist at the bottom catches the things that bounce most often in review.
-->

## What

<!-- One or two sentences on the change. -->

## Why

<!-- The listening problem or use case. Link the issue if there is one: `Fixes #123`. -->

## How it works

<!-- Brief technical note on the approach if non-obvious. Skip for trivial changes. -->

## Testing

<!-- How you verified this. -->

- [ ] `task lint` and `task test` pass locally
- [ ] Tried it in a real VLC through at least one ad break (the suite covers the pure logic in `hushbreak_core.lua`; the VLC glue is only proven by listening)
- [ ] Watched VLC's messages (`[hushbreak]` lines) for the ducking and the restore

## Checklist

- [ ] `CHANGELOG.md` has a new entry under **Unreleased** (user-visible changes only).
- [ ] The settings table in `README.md` and the header of `hushbreak.lua` are updated if a setting or default changed.
- [ ] No new dependency: the scripts stay plain Lua 5.1 that runs inside VLC 3 as-is.
- [ ] Commits follow the conventions in [CONTRIBUTING.md](../CONTRIBUTING.md) (imperative subject ≤72 chars, new commits not amends, hooks not skipped).
