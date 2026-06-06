# Releasing Cora

Cora is built and distributed per-OS — macOS, Linux, Windows — but versioned
in lockstep against a single upstream `v*` tag. release-please owns the
upstream version; a post-release "mirror-tag" step fans out `cora-{os}-v*`
tags for the OSes that actually need to rebuild. Each mirror tag drives its
own GitHub Release, brew/scoop publish, and npm subpackage publish, so a
Windows-only fix does not spend CI minutes on a macOS runner.

This document covers the day-to-day flow and the rarer overrides.

## TL;DR

| Want to release… | What you do |
| --- | --- |
| Whatever release-please proposes | Merge the release-please PR on `main`. |
| Only the affected OS(es), not all three | Nothing — the mirror-tag step auto-detects which OS(s) the diff touched and fans out tags only to those. |
| All three OS regardless of diff | Re-run the `release-please.yml` workflow's `mirror-tags` job manually, or push the three `cora-{os}-v<version>` tags by hand. |
| A specific version (e.g. promote to 1.0.0) | Add `Release-As: 1.0.0` to your commit footer. release-please honors it for the next bump. |
| A stable promotion from a prerelease tag | Trigger the `release` workflow manually with `channel=release` and `source_tag=cora-<os>-v<X.Y.Z>-alpha.N`. |
| An npm cut | Stable mirror tags publish subpackages + re-publish the meta automatically. The meta version is monotonic and decoupled from the upstream `v*` version. |

## Tag and version model

- **One upstream tag, three mirror tags.** release-please cuts a single
  semver tag (`v0.9.2`). A workflow step then pushes
  `cora-{macos,linux,windows}-v0.9.2` mirrors at the same commit, but
  only for the OS(es) whose files changed since the previous `v*` tag.
- **Single version source-of-truth.** `build.zig.zon`'s `.version` is
  the only version field. `build.zig` reads it via `@embedFile` and bakes
  the value into the binary. There is no per-OS version drift: every OS
  that ships at `v0.9.2` ships the same code at the same version.
- **Per-OS GitHub Releases.** `release.yml` listens for
  `cora-{os}-v*` tag pushes; each mirror tag produces its own release
  shell titled `Cora <OS> v<X.Y.Z>` with the matching tarballs / zips
  attached. README badges and the `Current versions` table in
  `CHANGELOG.md` read those releases live.

## How the mirror-tag step decides which OS(s) ship

After release-please opens its release, the `mirror-tags` job in
`release-please.yml` iterates `macos / linux / windows`. For each OS:

1. **`Release-Os:` footer override.** If any commit in the range
   between the previous `v*` and the new `v*` carries a
   `Release-Os: <os>[,<os>...]` footer, only the listed OSes get a
   mirror tag. The diff classifier is skipped.
2. **First-ever mirror tag** for this OS → tag (bootstrap case).
3. **Diff vs this OS's own last mirror tag.** Use the OS's own last
   `cora-<os>-v*` tag as the baseline (not the previous upstream
   `v*`), so an OS that skipped a release still catches up the next
   time something relevant changes.
4. Run `git diff --name-only <prev_os_tag>..<new_v_tag>` through
   `grep -qE -f .github/release-paths/<os>.txt`. If any changed
   path matches any pattern in that file, push the mirror tag.

The path patterns live in plain text files version-controlled at
[`.github/release-paths/`](.github/release-paths/) — one per OS,
documented in
[`.github/release-paths/README.md`](.github/release-paths/README.md).
Edit them directly when a new file class needs to land in a release.

OS-exclusive paths:

- `src/identity/macos.zig` → macOS only.
- `src/identity/linux.zig` → Linux only.
- `src/identity/windows.zig`, `src/service/pipe_windows.zig`,
  `src/service/spawn_windows.zig` → Windows only.

Shared paths appear in all three regex files; bookkeeping paths
(`build.zig.zon`, `CHANGELOG.md`, top-level docs, PR/issue templates,
release-please config) appear in none — release-please modifies them
every release but the binary output does not change.

### `Release-Os:` footer

Use the footer in any commit's body to restrict the next release
explicitly:

```
fix(crypto): tighten nonce derivation for Windows pipe handshake

The bug only manifests on Windows because <…>.

Release-Os: windows
```

Multiple OSes go comma-separated (`Release-Os: macos,linux`). The
footer is case-insensitive. Unknown tokens (e.g. typos like
`Release-Os: windws`) hard-fail the workflow — a green release that
ships zero binaries is the worst possible outcome here.

**Scope: the footer applies to the whole release window**, not just
to its own commit. The fan-out step scans every commit in
`previous-v..new-v` for `Release-Os:` footers and takes the union; if
any footer is present, the diff classifier is skipped entirely. So
if commit A carries `Release-Os: windows` and commit B in the same
range silently touches macOS-only code, **macOS is suppressed for
this release** — the per-OS catch-up on the next release will pick it
up, because the diff baseline for each OS is its own last mirror tag,
not the upstream `v*`.

Use `Release-Os:` when the diff would over-fire — e.g. you touched
shared code only to land fixtures or types but the runtime behavior is
windows-only.

### Forcing all three despite a narrow diff

Either:

- Push the three mirror tags by hand on the upstream commit, or
- Re-run the `release-please.yml` workflow's `mirror-tags` job
  manually after editing
  `.github/release-paths/<os>.txt` (e.g. add a temporary `^README\.md$`
  if you want the docs commit to fan out anyway).

## How release-please decides what to bump

`release-please.yml` runs on every push to `main` against
[`.github/release-please-config.json`](./.github/release-please-config.json),
a single-component config. Conventional Commits map to changelog
sections; `feat:` / `fix:` / `perf:` / `security:` bump the version
(per release-please's standard rules). The result is one floating PR
titled `chore(main): release v…`.

### Forcing a specific version

The standard release-please escape hatch is the plain-semver `Release-As:`
footer:

```
chore: bump to 1.0.0

Release-As: 1.0.0
```

release-please will open its next release at that version. This is **a
single semver** — not a tag name and not per-OS. With our model that is
fine: the mirror-tag step still independently fans out only to affected
OSes.

There is no way to make release-please open a release that bumps fewer
than all paths in the single component; the per-OS scoping happens
downstream in `mirror-tags`.

### Forcing a single-OS ship even when shared code changed

Use the `Release-Os:` footer described above. The mirror-tag classifier
checks the footer before consulting the diff, so a `Release-Os: macos`
footer ships only the macOS mirror tag regardless of what the diff
touched.

## Workflow walkthrough

1. **Commit** Conventional Commits on `main`.
2. **release-please** opens / updates a single PR titled
   `chore(main): release v…`. It edits `build.zig.zon`,
   `CHANGELOG.md`, and the manifest.
3. **Merge the PR.** release-please creates the upstream `v0.9.2` tag.
4. **mirror-tags** (in `release-please.yml`) diffs `v0.9.2` against the
   previous `v*` tag, classifies the changed files, and pushes up to
   three `cora-{os}-v0.9.2` tags.
5. **`release.yml`** fires per mirror tag:
   - Build matrix scoped to that OS only.
   - GitHub Release titled `Cora <OS> v0.9.2`, with the tarball / zip
     and `SHA256SUMS`.
   - Stable-only distribution:
     - `cora-macos-v*` → updates [`keton-id/homebrew-tap`](https://github.com/keton-id/homebrew-tap).
     - `cora-windows-v*` → updates [`keton-id/scoop-bucket`](https://github.com/keton-id/scoop-bucket).
     - `cora-linux-v*` → GitHub release only (AUR/snap deferred).
     - Every stable mirror tag publishes its two npm subpackages
       (`@keton-id/cora-<platform>-<arch>`) and re-publishes the meta
       `@keton-id/cora` (see "npm meta semantics" below).
6. **`changelog-stable.yml`** fires on stable GitHub releases,
   generates contributor-enriched notes via the GitHub API, and opens
   a PR updating `CHANGELOG.md` (one file shared across all OS — the
   per-OS previous-stable lookup still scopes the generated notes to
   the right baseline) and the release body.

## Promoting an alpha to stable

Pre-1.0 work ships as `cora-{os}-v…-alpha.N`. To cut the corresponding
stable for a specific OS:

1. Open the GitHub Actions tab → **release** workflow → **Run workflow**.
2. Inputs:
   - `release_channel = release`
   - `source_tag = cora-<os>-v<X.Y.Z>-alpha.N`
3. The workflow strips the `-alpha.N` suffix, tags the same commit as
   `cora-<os>-v<X.Y.Z>`, builds, publishes, and runs the matching
   distribution jobs.

For a coordinated 3-OS stable promotion, run the workflow three times
(once per OS source tag) — or just merge a `Release-As: <X.Y.Z>` commit
through release-please and let mirror-tags fan out.

## npm meta semantics

The meta `@keton-id/cora` is a tiny ESM launcher with up to six
`optionalDependencies` (one per `<platform>-<arch>`). At install time,
npm uses each subpackage's `os` and `cpu` fields to skip the five that
don't match the host. The launcher (`bin/cr.js`) resolves the surviving
subpackage at runtime and `spawnSync`s its prebuilt `cr` binary.

- **Subpackage version** = the version of the mirror tag that produced
  it (e.g. `cora-windows-v0.9.2` publishes
  `@keton-id/cora-win32-x64@0.9.2`).
- **Meta version** = the upstream release semver (e.g. `0.9.2`) for
  the first publisher of that release. A coordinated multi-OS stable
  (e.g. `1.0.0` fanning out to all three mirror tags) fires three
  parallel meta publishes against the same `@keton-id/cora@1.0.0`;
  the concurrency group serializes them and the bump-on-conflict
  loop in `prepare-meta.mjs` handles the rest: identical pins → the
  losing run no-ops idempotently; different pins → the loser
  republishes at the next patch (e.g. `1.0.1`). The published
  version therefore *can* be a patch ahead of the release semver in
  these cases — `@latest` still points at the freshest pin map, but
  pinning to `@1.0.0` exactly may resolve to slightly older pins
  than `@1.0.1`.
- **`optionalDependencies` pins** are queried live from the npm registry
  for each of the six `@keton-id/cora-<platform>-<arch>` packages
  (`npm view ... dist-tags.latest`). An out-of-step OS release ships
  cleanly because every other OS keeps its existing registry version in
  the pin map; only the OSes that just published this release have
  their pin advance.
- **Concurrency.** `publish-npm-meta` is in a workflow concurrency group
  (`npm-meta`, `cancel-in-progress: false`). GitHub may cancel a queued
  run if a third is queued behind it; that is OK here because
  `prepare-meta.mjs` reads npm state at execution time — the surviving
  run reflects every completed subpackage publish, including those of
  any cancelled-but-already-done runs.
- **First-ever publish.** If no subpackage exists on the registry yet,
  the meta publish refuses (the `no subpackages published yet` guard in
  `prepare-meta.mjs`); push a full-3-OS stable first.

## Re-running a failed release

Tags created by release-please and by `mirror-tags` are part of the
release history — **do not delete them** to retry. To re-run after a
failure:

1. Open the **release** workflow → **Run workflow**.
2. `release_channel = prerelease` (or `release` to derive a stable
   from an alpha), `source_tag = <the failed mirror tag>`.
3. Build / publish steps are idempotent: GitHub releases are upserted,
   `npm publish` returns 409 if the exact version already exists (bump
   the meta is automatic; bump a subpackage requires a new mirror tag).

## Linux package-manager publish (deferred)

AUR and snap are not wired up yet. The `publish-linux` job in
`release.yml` is a no-op stub that exists so future work can drop into
the existing per-OS gating without restructuring the workflow.
