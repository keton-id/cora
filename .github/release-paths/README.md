# Per-OS release path patterns

One file per supported OS — `macos.txt`, `linux.txt`, `windows.txt`. Each
line is a POSIX extended regular expression (ERE) that matches a path
relative to the repo root.

`.github/workflows/release-please.yml`'s mirror-tag step calls

```sh
git diff --name-only <prev_os_tag>..<sha> | grep -qE -f .github/release-paths/<os>.txt
```

to decide whether to push a `cora-{os}-v<X.Y.Z>` mirror tag for that
release. If any changed path matches any line, that OS gets a mirror
tag and downstream `release.yml` builds, packages, and publishes for
it.

## Conventions

- Anchor each pattern with `^` and end-anchor file matches with `$` —
  the input is plain `git diff --name-only` output, one path per line.
- Use directory-prefix form (`^src/crypto/`) when every file in the
  directory should match.
- Include each file's own regex file in its own list so that editing
  e.g. `macos.txt` causes a macOS-only mirror tag (this is the only
  reason `macos.txt` matches `^\.github/release-paths/macos\.txt$`).
- `grep` treats every line of the file as a pattern — **do not** add
  comment lines or blanks. Keep this README as the authoritative
  explanation instead.

## What's intentionally excluded

These paths are bookkeeping — release-please modifies them, but the
binary output does not change. Excluding them keeps the mirror-tag
classifier from fanning out to every OS on every release:

- `build.zig.zon` (release-please bumps the `.version` field here)
- `.github/release-please-config.json` / `.github/release-please-manifest.json`
- `CHANGELOG.md`
- All other top-level docs: `README.md`, `RELEASING.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, `CLAUDE.md`, `LICENSE`
- `docs/**`
- `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/**`,
  `.github/CODEOWNERS`, `.github/dependabot.yml`

## Per-OS exclusives

- `src/identity/macos.zig` → only macOS.
- `src/identity/linux.zig` → only Linux.
- `src/identity/windows.zig`, `src/service/pipe_windows.zig`,
  `src/service/spawn_windows.zig` → only Windows.

Everything else under `src/`, `build.zig`, `packaging/`, `scripts/`,
`install.sh`, and the release workflows is shared — it appears in all
three files, so a shared-code commit fans out to every OS.

## Override per commit

If a commit's body carries `Release-Os: <os>[,<os>...]` (e.g.
`Release-Os: windows`), the mirror-tag step restricts the release to
those OS(es) regardless of what the diff would otherwise match. See
[RELEASING.md](../../RELEASING.md) for the full mechanics.
