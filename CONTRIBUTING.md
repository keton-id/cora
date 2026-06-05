# Contributing to Cora

Thanks for your interest in Cora. This document covers everything you need
to land a change: how to set up the project locally, how the PR + release
flow works, and the rules that secret-handling code must follow.

If you found a security vulnerability, **do not open a public issue**.
See [SECURITY.md](SECURITY.md) for the responsible-disclosure channel.

---

## Project status

Cora is **pre-alpha** (`0.x`, macOS + Linux + Windows, Zig 0.16). Public API
and CLI surface may change between minor versions until `v1.0.0`. We follow
[Semantic Versioning](https://semver.org/) and use
[Conventional Commits](https://www.conventionalcommits.org/) for
release-please automation — see the
[Commit conventions](#commit-conventions) section below.

Each OS (macOS, Linux, Windows) is released on its own cadence under its
own tag prefix (`cora-{os}-v…`). A Windows-only fix does not force a
macOS or Linux build. Shared code commits intentionally bump all three.
See [RELEASING.md](RELEASING.md) for the full model.

---

## Quick links

- 🐛 [Report a bug](https://github.com/keton-id/cora/issues/new?template=bug_report.yml)
- ✨ [Request a feature](https://github.com/keton-id/cora/issues/new?template=feature_request.yml)
- 🔒 [Report a vulnerability (private)](https://github.com/keton-id/cora/security/advisories/new)
- 💬 [Discussions](https://github.com/keton-id/cora/discussions)

---

## Development setup

### Requirements

- **Zig 0.16.0** (exact). The build script and standard library rely on the
  0.16 `Io` interface and ZON tooling — earlier versions will not compile.
- macOS, Linux, or Windows. All three are Tier 1: every shipped feature
  (kernel-verified caller identity, daemonization, `cr exec` stdio
  passing, target whitelist, audit log) runs the same on each platform.
  Tests run on whatever host you build from. See [`SECURITY.md`](SECURITY.md)
  for the per-OS trust model.
- Optional: `git`, `shasum`, `curl` for the install / release scripts.

Install Zig via your package manager or
[`mlugg/setup-zig`](https://github.com/mlugg/setup-zig) (used by CI).

### Build + test loop

```bash
git clone https://github.com/keton-id/cora && cd cora
zig build                       # debug build → zig-out/bin/cr
zig build test                  # full test suite (51/51 must pass)
zig build test --summary all    # verbose
zig build fmt                   # check formatting (CI runs this)
zig build run -- version        # run cr from build cache
```

The `cr` binary lands at `zig-out/bin/cr`. Use it from a scratch directory
so `cora.zon` does not litter your repo:

```bash
mkdir /tmp/cora-dev && cd /tmp/cora-dev
/path/to/corazo/zig-out/bin/cr init
```

### Layout

```
src/
├── main.zig          CLI dispatch
├── root.zig          library root + test aggregator
├── audit.zig         Event union + JSONL Logger
├── error.zig         CoraError set
├── crypto/           SecretBuf · Argon2id derive · XChaCha20-Poly1305 wrapper
├── store/            cora.zon format · encrypt/decrypt · JSON secrets codec · MemStore
├── service/          IPC proto · idle timer · service loop · client helpers
├── identity/         per-OS caller identity (SO_PEERCRED / LOCAL_PEERPID)
├── policy/           Policy struct (allowed_callers, idle_timeout_ms, tasks)
└── tui/              ANSI menu loop
```

See [CLAUDE.md](CLAUDE.md) for deeper architectural notes.

---

## Commit conventions

We use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
**CI rejects PR titles that don't match** — set the PR title even if your
local commits are messy, the squash-merge will use the PR title as the
final commit message.

| Prefix | Meaning | SemVer bump |
|--------|---------|-------------|
| `feat:` | new user-visible feature | minor |
| `fix:` | bug fix | patch |
| `perf:` | performance improvement | patch |
| `security:` | security-related fix or hardening | patch |
| `docs:` | documentation only | none |
| `refactor:` | code restructuring, no behavior change | none |
| `test:` | test-only change | none |
| `build:` / `ci:` | build system or CI changes | none |
| `chore:` | maintenance, dependency bumps, etc. | none |
| `style:` | formatting / whitespace | none |

**Breaking changes:** append `!` after the type, OR add a `BREAKING CHANGE:`
footer in the commit body. Both will trigger a major bump (or in `0.x`,
a minor bump per release-please config).

Examples:

```
feat(audit): add log rotation by size
fix(crypto): zero key on Argon2id failure path
feat(proto)!: bump frame header to v2

security: tighten LOCAL_PEERPID TOCTOU window
docs(readme): document install.sh --channel flag
```

Scopes are optional but encouraged — they group entries in the changelog.

---

## Pull request flow

1. Fork or create a branch off `main`.
2. Make changes following the [Security rules](#security-rules-mandatory)
   and [Code style](#code-style) sections.
3. Run `zig build test` and `zig build fmt` locally — both must pass.
4. Open a PR. CI runs `build + test + fmt` on Linux and macOS, plus a
   Conventional Commit lint on the PR title.
5. Wait for review. We aim for first response within a few days.
6. After merge: release-please updates a floating
   "chore(main): release …" PR covering the OS components your commit
   bumped (one to three of macOS / Linux / Windows). Maintainers merge
   that when ready, which tags the per-OS release(s) and triggers the
   matching OS-scoped builds. See [Releasing](#releasing-maintainers-only).

### Reviewer expectations

- Tests added or updated for new behavior.
- No new dependency without justification (Cora is intentionally
  dependency-light — `vaxis` is the only non-stdlib dep today).
- Public CLI / protocol changes documented in `CLAUDE.md` and `README.md`.
- Behavior-changing commits include a `feat:`, `fix:`, `perf:`, or
  `security:` prefix so they appear in the changelog.

---

## Security rules (mandatory)

These are non-negotiable for any code that touches secrets, keys, or
caller identity. CI does not catch all of these — reviewers will block
PRs that violate them.

- [ ] `defer secret.zero()` is the first line after any `SecretBuf` init.
- [ ] `defer std.crypto.secureZero(u8, &key)` after any key derivation buffer.
- [ ] `SecretBuf` must not gain a `format` method (test asserts this).
- [ ] `cora.zon` secrets block is always encrypted before write —
      `store.saveSecrets` is the only sanctioned path.
- [ ] Passphrase is used to derive a key, then zeroed; never persisted
      anywhere on disk or in long-lived heap.
- [ ] `audit.Event` variants must not contain a `value` / `secret_value`
      field. Use the secret *name* only.
- [ ] New error paths still let `defer` run (no `unreachable` or
      `@panic` before zeroing).
- [ ] Platform identity code (`src/identity/`) is reviewed for TOCTOU
      between identity check and op handling.
- [ ] No new dependency that surfaces plaintext secrets through its API.

See [SECURITY.md](SECURITY.md) for the full threat model.

---

## Code style

- `zig fmt` enforces formatting — CI runs `zig build fmt`. Do not
  hand-format.
- Snake_case for variables and fields; PascalCase for types; camelCase
  for functions (stdlib convention).
- Prefer explicit `std.mem.Allocator` parameters over hidden allocators.
- Prefer `[]const u8` slices over `[*:0]const u8` C strings; reach for
  `std.mem.span` at the boundary.
- For Zig 0.16 specifics (Io params, `DebugAllocator`, `std.process.Init`),
  see the dialect notes in [CLAUDE.md](CLAUDE.md#zig-016-dialect-notes-lessons-from-m0m7).
- One assertion per behavior in tests. Group related tests next to the
  code they exercise (test blocks inside the implementation file).

---

## Adding tests

Tests live inline at the bottom of each source file as `test "name" { … }`
blocks. The root aggregator (`src/root.zig`) imports every module so
`zig build test` picks them all up. If you add a new file:

```zig
// in src/root.zig
test {
    _ = @import("path/to/your_new_file.zig");
}
```

For integration tests that need a tmp directory, use
`std.testing.tmpDir(.{})` — see `src/store/store.zig` for examples.

---

## Releasing (maintainers only)

Cora ships as **three independent OS components** — macOS, Linux, Windows.
Each has its own version, tag, GitHub release, changelog, and (where
applicable) package-manager distribution. The full operational guide
lives in [RELEASING.md](RELEASING.md); the summary below is enough to
understand how your commits land.

1. Conventional Commits land on `main`.
2. `release-please` looks at the `include-paths` for each component
   in [`.github/release-please-config.json`](.github/release-please-config.json)
   to decide which OS(s) bump:
   - Touch `src/identity/macos.zig` → only `cora-macos` bumps.
   - Touch `src/identity/windows.zig`, `src/service/pipe_windows.zig`,
     or `src/service/spawn_windows.zig` → only `cora-windows` bumps.
   - Touch `src/identity/linux.zig` → only `cora-linux` bumps.
   - Touch any shared file (`src/crypto/**`, `src/store/**`,
     `src/service/service.zig`, `build.zig`, …) → all three bump.
3. `release-please` opens (or updates) **one** PR titled
   `chore(main): release …` that collapses every bumped component.
   It edits `.versions.json` (only the affected OS fields) and the
   matching `CHANGELOG-{os}.md`.
4. A maintainer merges that PR. `release-please` then creates between
   one and three tags: `cora-macos-v…`, `cora-linux-v…`,
   `cora-windows-v…`.
5. `release.yml` fires per tag and scopes its build matrix to the OS
   embedded in the tag prefix — a Windows-only bump never spawns a
   macOS runner.
6. Distribution is per-OS: stable `cora-macos-v*` updates Homebrew;
   stable `cora-windows-v*` updates Scoop; every stable tag publishes
   the matching npm subpackages and re-publishes the meta
   `@keton-id/cora`.

### Releasing only one OS despite touching shared code

Add a Conventional Commits footer:

```
fix(crypto): tighten nonce derivation for Windows pipe handshake

Release-As: cora-windows-v0.9.3
```

`release-please` honors `Release-As:` and skips the other components.
Document why in the commit body. For a coordinated bump across all
three OS (e.g. `1.0.0`), use three footers in one commit:

```
chore: bump to 1.0.0 across all OS

Release-As: cora-macos-v1.0.0
Release-As: cora-linux-v1.0.0
Release-As: cora-windows-v1.0.0
```

### Promoting an alpha to stable

Run the **release** workflow manually with `release_channel=release`
and `source_tag=cora-<os>-v<X.Y.Z>-alpha.N`. The workflow strips the
suffix, retags the same commit, and runs the per-OS distribution jobs.

### Per-OS version source of truth

Versions live in [`.versions.json`](./.versions.json) at the repo root,
one field per OS. `build.zig` reads it at build time and bakes the
matching version into the binary based on `-Dtarget=...`. The
`.version` field in `build.zig.zon` is pinned to `0.0.0-dev` and is
not the source of truth — leave it alone.

---

## Reporting bugs

Use the [bug report template](https://github.com/keton-id/cora/issues/new?template=bug_report.yml).
Please include:

- `cr version` output (binary, commit, build date).
- OS + arch (`uname -a`).
- Minimal reproduction (commands + observed vs expected output).
- Relevant audit log lines if applicable (redact any sensitive values).

---

## Feature requests

Open an issue using the [feature request template](https://github.com/keton-id/cora/issues/new?template=feature_request.yml).
Frame it as a user story ("As an X, I want Y so that Z"). Non-goals are
listed in [CLAUDE.md](CLAUDE.md) and SECURITY.md — features that
contradict them (e.g. MCP server, cloud sync) will be closed.

---

## License

By contributing to Cora you agree that your contributions will be
licensed under the AGPL-3.0 (the project license). See [LICENSE](LICENSE).
