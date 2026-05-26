# Changelog

All notable changes to this project are documented here.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
and uses [Conventional Commits](https://www.conventionalcommits.org/). Entries
below are generated automatically by
[release-please](https://github.com/googleapis/release-please) — do not edit by
hand.

## [0.3.0-alpha.1](https://github.com/keton-id/cora/compare/v0.2.0-alpha.1...v0.3.0-alpha.1) (2026-05-26)


### Features

* modernize `cr tui` with pane-based vaxis UI ([a379ab6](https://github.com/keton-id/cora/commit/a379ab68ca0d6ab65f95607e6db19d655a1c1066))
* **tui:** refactor & pane-based vaxis interface ([351ef02](https://github.com/keton-id/cora/commit/351ef02938d3d381453a706b06b9165627e9d241))

## [0.2.0-alpha.1](https://github.com/keton-id/cora/compare/v0.1.3-alpha.1...v0.2.0-alpha.1) (2026-05-26)


### Features

* **identity:** add Windows caller verification stub ([1be670a](https://github.com/keton-id/cora/commit/1be670a1ed928f5b5dc1f81eea42eda6ccb993a8))
* **windows:** gate POSIX-only paths for Windows cross-compile ([635f54c](https://github.com/keton-id/cora/commit/635f54c4478c0ccb5a505590af48f54e67b0e857))
* **windows:** Tier 1 preview support ([f32345e](https://github.com/keton-id/cora/commit/f32345ecf1cf0a686de63fe5328d244fdabafb9e))
* **windows:** wire AF_UNIX IPC and stub caller identity ([2b0757d](https://github.com/keton-id/cora/commit/2b0757d1b39a22235abcef58fd42b9ea883154af))

## [0.1.3-alpha.1](https://github.com/keton-id/cora/compare/v0.1.2-alpha.1...v0.1.3-alpha.1) (2026-05-26)


### Bug Fixes

* **identity:** use libc readlink on linux (std.fs.readLinkAbsolute removed in 0.16) ([35e3a90](https://github.com/keton-id/cora/commit/35e3a90f61cfa01138d2088e25f6c36ef1091621))

## [0.1.2-alpha.1](https://github.com/keton-id/cora/compare/v0.1.1-alpha.1...v0.1.2-alpha.1) (2026-05-26)


### Bug Fixes

* **identity:** use libc readlink on linux (std.fs.readLinkAbsolute removed in 0.16) ([35e3a90](https://github.com/keton-id/cora/commit/35e3a90f61cfa01138d2088e25f6c36ef1091621))

## [0.1.1-alpha.1](https://github.com/keton-id/cora/compare/v0.1.0-alpha.1...v0.1.1-alpha.1) (2026-05-26)


### Bug Fixes

* **identity:** use libc readlink on linux (std.fs.readLinkAbsolute removed in 0.16) ([35e3a90](https://github.com/keton-id/cora/commit/35e3a90f61cfa01138d2088e25f6c36ef1091621))

## [Unreleased]

(Entries for the next release will appear here automatically.)

## [0.1.0-alpha.1] - 2026-05-26

Initial pre-alpha release.

### Features

- Encrypted file store (`cora.zon`): XChaCha20-Poly1305 + Argon2id (t=3, m=64MB, p=4)
- `cr init` / `cr secrets set|list|delete` — interactive secret management
- `cr policy show|allow|deny` + `cr policy task add|remove` — kernel-allowlist + task scoping
- `cr unlock [--foreground]` / `cr lock` / `cr status` — background service over Unix domain socket
- `cr exec TASK -- argv...` — spawn subprocess with task-scoped secrets injected into env
- `cr audit tail|show` — JSONL audit log at `~/.cora/audit.jsonl` (no secret values, ever)
- `cr verify --pid PID` — debug binary path resolution for a process
- `cr tui` — interactive ANSI menu (status, audit tail, secrets list, lock)

### Security

- `std.crypto.secureZero` on every `SecretBuf` and key buffer release path
- Caller identity verified at kernel level: `SO_PEERCRED` (Linux) / `LOCAL_PEERPID` (macOS)
- Service socket created at `/tmp/cora-<uid>.sock` with `chmod 600`
- Audit log structurally cannot contain a secret value (no `value` field in any event variant)
- AAD on encryption binds ciphertext to `cora.zon` file header (magic + version + salt + nonce)

### Documentation

- `README.md` — pre-alpha banner, Claude Code quick-start, grep-leak verification
- `CLAUDE.md` — project context for contributors and AI assistants
- `SECURITY.md` — OSS-standard policy, AGPL §§ 15-16 warranty, known residuals, contributor checklist
