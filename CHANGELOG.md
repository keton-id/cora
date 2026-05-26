# Changelog

All notable changes to this project are documented here.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
and uses [Conventional Commits](https://www.conventionalcommits.org/). Entries
below are generated automatically by
[release-please](https://github.com/googleapis/release-please) — do not edit by
hand.

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
