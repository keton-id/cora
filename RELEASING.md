# Releasing Cora

Cora ships as **three independent OS components** — macOS, Linux, Windows — each with its own version, tag, GitHub release, changelog, and (where applicable) package-manager distribution. Shared code lives in one tree but a shared-code commit semantically affects every OS, so by default it bumps all three.

This document covers the day-to-day release flow and the rarer overrides.

## TL;DR

| Want to release… | What you do |
| --- | --- |
| Whatever release-please proposes | Merge the release-please PR on `main`. |
| Only one OS, even though you touched shared code | Add `Release-As: cora-<os>-v<x.y.z>` to your commit footer. |
| All three OS at the same version (e.g. 1.0.0) | One commit with three `Release-As:` footers. |
| A stable promotion from a prerelease tag | Trigger the `release` workflow manually with `channel=release` and `source_tag=<the alpha tag>`. |
| An npm cut that pins to today's three OS versions | Stable per-OS releases publish subpackages automatically; the meta `@keton-id/cora` is re-published after each. To force a meta-only refresh, re-run `release.yml` with the latest stable tag of any OS. |

## Tag and version model

- Tag format: `cora-{macos,linux,windows}-v{semver}`. Examples:
  - `cora-macos-v0.9.2-alpha.1` — prerelease
  - `cora-linux-v1.0.0` — stable
- Per-OS versions live in [`.versions.json`](./.versions.json) at the repo root. release-please updates the field for each component it bumps.
- `build.zig` reads `.versions.json` at build time and bakes the matching version into the binary based on `-Dtarget=...`. `cr version` reports the per-OS version of the binary you're running.
- `build.zig.zon`'s `.version` is pinned to `0.0.0-dev` and is not the source of truth. It is never read at runtime.

## How release-please decides what to bump

[`.github/release-please-config.json`](./.github/release-please-config.json) defines three packages, one per OS. Each has an `include-paths` list:

- **OS-exclusive** paths (e.g. `src/identity/macos.zig`) only feed that component.
- **Shared** paths (`src/crypto/**`, `src/store/**`, `src/service/service.zig`, `build.zig`, …) appear in **all three** components. A shared commit bumps every component.

The "shared bumps all" rule is intentional: a fix in `src/crypto/aead.zig` changes behavior for every OS, so every OS should see a release.

### Escape hatch: `Release-As:` footer

When you want to bump fewer than three components despite touching shared paths, add a Conventional Commits footer:

```
fix(crypto): tighten nonce derivation for Windows pipe handshake

The bug only manifests on Windows because <…>.

Release-Targets: windows-only

Release-As: cora-windows-v0.9.3
```

release-please honors `Release-As:` and skips the other components. Document the reasoning in the commit body so future readers understand why only one OS bumped.

### Releasing all three at once (e.g. 1.0.0)

```
chore: bump to 1.0.0 across all OS

Coordinated stable release to mark <…>.

Release-As: cora-macos-v1.0.0
Release-As: cora-linux-v1.0.0
Release-As: cora-windows-v1.0.0
```

release-please supports multiple `Release-As:` footers per commit.

## Workflow walkthrough

1. **Commit & push** to `main` (directly via merged PR).
2. **release-please** opens (or updates) **one PR** titled `chore(main): release …` that collapses all bumped components. The PR edits:
   - `.versions.json` (only the bumped OS fields)
   - the unified `CHANGELOG.md` (every component shares the same file
     so all three OS streams are visible at a glance, ordered by date)
   - `.github/release-please-manifest.json`
3. **Merge the release-please PR.** release-please creates the appropriate tags (one to three of: `cora-macos-v…`, `cora-linux-v…`, `cora-windows-v…`).
4. **`release.yml`** fires on each new tag:
   - Resolves OS from the tag prefix → builds a matrix scoped to that OS only (2 targets).
   - Packages `cr` (or `cr.exe`) into a tarball / zip, uploads to a GitHub Release.
   - Pre-release iff the version contains a `-` (e.g. `-alpha.1`).
   - Stable-only distribution:
     - `cora-macos-v*` → updates [`keton-id/homebrew-tap`](https://github.com/keton-id/homebrew-tap).
     - `cora-windows-v*` → updates [`keton-id/scoop-bucket`](https://github.com/keton-id/scoop-bucket).
     - `cora-linux-v*` → GitHub release tarballs only (no package-manager publish yet; AUR/snap deferred).
     - All stable tags also publish two npm subpackages (`@keton-id/cora-<platform>-<arch>`) and re-publish the meta `@keton-id/cora` with `optionalDependencies` pinned to the latest per-OS versions from `.versions.json`.
5. **`changelog-stable.yml`** fires on stable GitHub releases, generates contributor-enriched notes via the GitHub API, and opens a PR updating `CHANGELOG.md` (the per-OS previous-stable lookup still scopes the generated notes to the right baseline) and the release body.

## Promoting an alpha to stable

Pre-1.0 work ships as `cora-{os}-v…-alpha.N`. To cut the corresponding stable:

1. Open the GitHub Actions tab → **release** workflow → **Run workflow**.
2. Inputs:
   - `release_channel = release`
   - `source_tag = cora-<os>-v<x.y.z>-alpha.N`
3. The workflow strips the `-alpha.N` suffix, tags the same commit as `cora-<os>-v<x.y.z>`, builds, publishes, and runs the matching distribution jobs.

`release-please` will reconcile the manifest on the next merge.

## npm meta semantics

The meta `@keton-id/cora` is a tiny ESM launcher with six `optionalDependencies` (one per `<platform>-<arch>`). At install time, npm uses each subpackage's `os` and `cpu` fields to skip the five that don't match the host. The launcher (`bin/cr.js`) resolves the surviving subpackage at runtime and `spawnSync`s its prebuilt `cr` binary.

- **Subpackage version** = the per-OS version of the tag that produced it.
- **Meta version** = `max(macos, linux, windows)` from `.versions.json` at publish time.
- This means an isolated bump on one OS still re-publishes the meta with the updated `optionalDependencies` map. `npm i -g @keton-id/cora@latest` always pulls the freshest binary available for the host.
- Meta publishes are serialized via a workflow `concurrency: { group: npm-meta, cancel-in-progress: false }` so two simultaneous OS releases can't race a non-monotonic version onto the registry.

## Re-running a failed release

Tags created by release-please are part of its manifest invariant — do **not** delete them. To re-run after a failure:

1. Open the **release** workflow → **Run workflow**.
2. `release_channel = prerelease` (or `release` to derive a stable from an alpha), `source_tag = <the failed tag>`.
3. The build/publish steps are idempotent: GitHub releases are upserted, npm publishes will 409 if the exact version already exists (re-run with a bumped version if you need to overwrite).

## Linux package-manager publish (deferred)

AUR and snap are not wired up yet. The `publish-linux` job in `release.yml` is a no-op stub that exists so future work can drop into the existing per-OS gating without restructuring the workflow.
