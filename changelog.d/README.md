# Changelog fragments

A pull request with a user-visible change adds **one file here** instead of editing
`CHANGELOG.md`. Each pull request has its own file, so no pull request ever conflicts with
another over the changelog. The Release workflow folds the files into `CHANGELOG.md` under the
new version and deletes them (`scripts/cut-changelog.ps1`).

**Name:** `<anything>.<section>.md` — the branch name works well: `duck-on-reconnect.fixed.md`.
The section is one of Keep a Changelog's:

| Section | For |
|---|---|
| `added` | new settings, buttons, supported stations |
| `changed` | changes in existing behaviour, defaults, docs |
| `deprecated` | soon-to-be removed features |
| `removed` | removed features |
| `fixed` | bug fixes |
| `security` | vulnerabilities |

**Content:** one or more bullets, written like the entries in `CHANGELOG.md` — for listeners,
not for the code:

```markdown
- fix: the volume no longer stays down when the stream reconnects in the middle of a break
```

Two kinds of change in one pull request: two files (`x.added.md`, `x.fixed.md`).
`task lint` checks every file here (`scripts/cut-changelog.ps1 -Check`), and so does CI.
