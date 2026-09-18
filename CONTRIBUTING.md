# Contributing

Thanks for taking the time to contribute to Hushbreak.

This document covers how to file issues, propose changes, and get a pull request merged. For running from source, the tests, and the release pipeline, see [DEVGUIDE.md](DEVGUIDE.md).

By participating in this project you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting bugs

Open a [GitHub issue](https://github.com/WizX20/Hushbreak/issues/new/choose) with:

- The station and stream URL, and how you started VLC (command line or the preference values)
- What you expected
- What happened — the `[hushbreak]` lines from VLC's messages (Tools > Messages, verbosity 2, filter `hushbreak`) around that moment, as text
- Your VLC version and operating system, and how you installed Hushbreak

If you can reproduce on the [latest release](https://github.com/WizX20/Hushbreak/releases/latest), say so.

## Suggesting features

Open an issue describing the use case before writing code. Small fixes can go straight to a PR, but anything that changes *when* the volume moves (detection, timing, the grace rules) benefits from a short design discussion first so the PR doesn't bounce on that. Support for another station or stream provider starts with a *Station request* issue: what the stream publishes about its ads decides what is possible.

## Security issues

Do **not** open a public issue for security-sensitive bugs. Use GitHub's [private security advisory](https://github.com/WizX20/Hushbreak/security/advisories/new) on this repo instead.

## Submitting a pull request

1. Fork the repo and create a topic branch off `main`.
2. Make your change. Keep the diff focused — one concern per PR.
3. Run `task check` (luacheck + the Lua suite). Add or extend a test in `tests/hushbreak_core_test.lua` for behaviour you changed; the fixture in `tests/fixtures/` is a real feed answer, add another one if your change needs a different shape of data.
4. Try it in a real VLC through at least one ad break. The VLC layer (`hushbreak.lua`) is not covered by the suite; DEVGUIDE.md shows how to test it in a headless VLC against the fixture without waiting for a real break.
5. Update [`CHANGELOG.md`](CHANGELOG.md) — add a line under **Unreleased** for any user-visible change. Never edit released sections.
6. If a setting or default changed, update the header of `hushbreak.lua` and the settings table in the README.
7. Push and open a PR against `main`. Reference any related issue (`Fixes #123`).

CI runs lint + tests on Lua 5.1 (the version VLC 3 embeds) for every PR — make sure it passes before requesting review.

### Branch naming

- `feature/<short-description>` — new functionality
- `fix/<short-description>` — bug fixes
- `chore/<short-description>` — refactors, build/CI, docs, dependency bumps

### Commit messages

- Imperative subject, ≤72 characters, no trailing period (`Add min_volume floor`, not `Added min_volume floor.`).
- Optional `feat:` / `fix:` / `chore:` prefix when it adds clarity — match the existing `git log` style.
- Body (when needed): wrap at 72 columns, explain **why** more than what.
- Create new commits — do not amend or force-push published commits.
- Do not skip hooks (`--no-verify`) or signing.

### Code style

- Plain Lua 5.1: VLC 3 embeds that version. No `goto`, no integer division, no `table.unpack`, no `%d` with floats in `string.format`.
- Logic without VLC calls goes in `hushbreak_core.lua` and gets a test; only `hushbreak.lua` and the extension talk to `vlc.*`.
- No dependencies: the three files must work when copied into VLC's Lua folder as they are.
- Comments explain *why*, not what; keep them terse. Everything in English.
- 4-space indentation, `snake_case` for locals and functions, `UPPER_CASE` for constants. `task lint` must stay clean; per-file globals live in `.luacheckrc` with a reason each.
- Log through `vlc.msg.info` with the `[hushbreak]` prefix for things a user would want to see in Tools > Messages, `vlc.msg.warn` for problems, `vlc.msg.dbg` for the rest.

## Releasing

Maintainers only. See [DEVGUIDE.md → Release process](DEVGUIDE.md#release-process).

## Licence

By contributing you agree that your contribution is licensed under the [Business Source License 1.1](LICENSE) (BUSL-1.1), and that the [NOTICE](NOTICE) file is preserved in any redistribution.
