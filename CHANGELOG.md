# Changelog

All notable changes to this project are documented here.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
and uses [Conventional Commits](https://www.conventionalcommits.org/). Entries
below are generated automatically by
[release-please](https://github.com/googleapis/release-please) — do not edit by
hand.

## [0.6.1](https://github.com/keton-id/cora/compare/v0.6.0...v0.6.1) (2026-05-29)

## What's Changed
* fix(ci): insert stable CHANGELOG heading when missing by @mulhamna in https://github.com/keton-id/cora/pull/22
* chore(main): release 0.6.1-alpha.1 by @mulhamna in https://github.com/keton-id/cora/pull/23


**Full Changelog**: https://github.com/keton-id/cora/compare/v0.6.0...v0.6.1

### Contributors

@mulhamna

## [0.6.1-alpha.1](https://github.com/keton-id/cora/compare/v0.6.0-alpha.1...v0.6.1-alpha.1) (2026-05-29)


### Bug Fixes

* **ci:** insert stable CHANGELOG heading when missing ([fa043c0](https://github.com/keton-id/cora/commit/fa043c08c4fe1b66875033ed795f0e8ab61a7bff))
* **ci:** insert stable CHANGELOG heading when missing, pass prev/repo ([cb18d89](https://github.com/keton-id/cora/commit/cb18d89b231f0f69858ab11d9d184e024ee5848a))

## [0.6.0-alpha.1](https://github.com/keton-id/cora/compare/v0.5.1-alpha.1...v0.6.0-alpha.1) (2026-05-29)


### Features

* **cli:** preview-mode warning banner on sensitive subcommands ([53b1b8c](https://github.com/keton-id/cora/commit/53b1b8c9b01705d41e1a63bf4d2fdb00aa0d91b2))
* **service:** refuse to start on Windows if socket path escapes LOCALAPPDATA\cora ([ef6dc56](https://github.com/keton-id/cora/commit/ef6dc56bb6b7527232936bc0f28f00d3e50b28c6))


### Bug Fixes

* **cli:** mask secret prompt on Windows via SetConsoleMode, fail closed ([2f4d10a](https://github.com/keton-id/cora/commit/2f4d10a2cdcc43cd61d293e8662d4ad942d1eae5))
* **windows:** cr.exe basename in integration opts + track audit log offset locally ([b45796a](https://github.com/keton-id/cora/commit/b45796afb8e3ee9a8b13d56dba556e5184c50e26))

## [0.5.1-alpha.1](https://github.com/keton-id/cora/compare/v0.5.0-alpha.1...v0.5.1-alpha.1) (2026-05-28)


### Bug Fixes

* **ci:** use matching-refs API for exact tag check in release workflow ([0c49168](https://github.com/keton-id/cora/commit/0c49168eebfef15804d353fc523b474f2e7154b5))
* **ci:** use matching-refs API for exact tag check in release workflow ([b472398](https://github.com/keton-id/cora/commit/b4723981e7040c44e6edc41a40a49126f182d795))

## [0.5.0-alpha.1](https://github.com/keton-id/cora/compare/v0.4.0-alpha.1...v0.5.0-alpha.1) (2026-05-28)


### Features

* **ci:** allow workflow_dispatch to promote prerelease to stable ([16a5fe7](https://github.com/keton-id/cora/commit/16a5fe71e04ed5bce31a0eee64ba41f6c5308ac9))
* **ci:** publish homebrew formula on stable release ([4e649ce](https://github.com/keton-id/cora/commit/4e649cee61dbdac8390aaff2f486c82b79412843))
* **ci:** publish scoop manifest on stable release ([460c5a3](https://github.com/keton-id/cora/commit/460c5a37ed5cc180265375ac2a0e423c8778bb07))
* **cli:** mask passphrase and secret-value input via termios ([d55126e](https://github.com/keton-id/cora/commit/d55126ed8fa1b56576fd26836d3c017a2c55b15d))
* **identity:** add Windows caller verification stub ([1be670a](https://github.com/keton-id/cora/commit/1be670a1ed928f5b5dc1f81eea42eda6ccb993a8))
* modernize `cr tui` with pane-based vaxis UI ([a379ab6](https://github.com/keton-id/cora/commit/a379ab68ca0d6ab65f95607e6db19d655a1c1066))
* **tui:** refactor & pane-based vaxis interface ([351ef02](https://github.com/keton-id/cora/commit/351ef02938d3d381453a706b06b9165627e9d241))
* **windows:** gate POSIX-only paths for Windows cross-compile ([635f54c](https://github.com/keton-id/cora/commit/635f54c4478c0ccb5a505590af48f54e67b0e857))
* **windows:** Tier 1 preview support ([f32345e](https://github.com/keton-id/cora/commit/f32345ecf1cf0a686de63fe5328d244fdabafb9e))
* **windows:** wire AF_UNIX IPC and stub caller identity ([2b0757d](https://github.com/keton-id/cora/commit/2b0757d1b39a22235abcef58fd42b9ea883154af))


### Bug Fixes

* **audit:** only emit secret_injected for actually injected secrets ([eaa5f5a](https://github.com/keton-id/cora/commit/eaa5f5af400847217fa6d731411e286f9b23286c))
* **ci:** use cora as package name for tap and bucket ([f9fe258](https://github.com/keton-id/cora/commit/f9fe2587de9c865431b0cef4668ee83ba1d23437))
* **cli:** scope readSecret termios block to POSIX ([acbe394](https://github.com/keton-id/cora/commit/acbe3944c34abe6af3c71f1ec6433b96328174bd))
* **cli:** scope readSecret termios block to POSIX paths only ([ffbab38](https://github.com/keton-id/cora/commit/ffbab388dc02b9375936d1297d550e64fa07ce6d))
* **identity:** use libc readlink on linux (std.fs.readLinkAbsolute removed in 0.16) ([35e3a90](https://github.com/keton-id/cora/commit/35e3a90f61cfa01138d2088e25f6c36ef1091621))
* **policy:** preserve tasks on policy allow/deny ([cbbbe9b](https://github.com/keton-id/cora/commit/cbbbe9b60f33c244c506cf66c12eadde937e7362))
* **secrets:** preserve policy on secrets set/delete ([a59d3e6](https://github.com/keton-id/cora/commit/a59d3e675393a0e1229cf3056073692edad17b17))
* **service:** chmod UDS socket to 0600 after bind ([c5dd945](https://github.com/keton-id/cora/commit/c5dd945568a0a555ae918db038e085d54affce45))
* **store:** atomic write of cora.zon via temp + rename ([1e6c795](https://github.com/keton-id/cora/commit/1e6c795bc92e068b2759aeaef93e80680ccde7a8))
* **test:** use Io.File.stat for cross-platform mode check ([e97501c](https://github.com/keton-id/cora/commit/e97501c0ae15946e3063b5914e0275470f40f5f5))

## [0.4.0-alpha.1](https://github.com/keton-id/cora/compare/v0.3.0-alpha.1...v0.4.0-alpha.1) (2026-05-28)


### Features

* **ci:** allow workflow_dispatch to promote prerelease to stable ([16a5fe7](https://github.com/keton-id/cora/commit/16a5fe71e04ed5bce31a0eee64ba41f6c5308ac9))
* **ci:** publish homebrew formula on stable release ([4e649ce](https://github.com/keton-id/cora/commit/4e649cee61dbdac8390aaff2f486c82b79412843))
* **ci:** publish scoop manifest on stable release ([460c5a3](https://github.com/keton-id/cora/commit/460c5a37ed5cc180265375ac2a0e423c8778bb07))
* **cli:** mask passphrase and secret-value input via termios ([d55126e](https://github.com/keton-id/cora/commit/d55126ed8fa1b56576fd26836d3c017a2c55b15d))


### Bug Fixes

* **audit:** only emit secret_injected for actually injected secrets ([eaa5f5a](https://github.com/keton-id/cora/commit/eaa5f5af400847217fa6d731411e286f9b23286c))
* **ci:** use cora as package name for tap and bucket ([f9fe258](https://github.com/keton-id/cora/commit/f9fe2587de9c865431b0cef4668ee83ba1d23437))
* **policy:** preserve tasks on policy allow/deny ([cbbbe9b](https://github.com/keton-id/cora/commit/cbbbe9b60f33c244c506cf66c12eadde937e7362))
* **secrets:** preserve policy on secrets set/delete ([a59d3e6](https://github.com/keton-id/cora/commit/a59d3e675393a0e1229cf3056073692edad17b17))
* **service:** chmod UDS socket to 0600 after bind ([c5dd945](https://github.com/keton-id/cora/commit/c5dd945568a0a555ae918db038e085d54affce45))
* **store:** atomic write of cora.zon via temp + rename ([1e6c795](https://github.com/keton-id/cora/commit/1e6c795bc92e068b2759aeaef93e80680ccde7a8))
* **test:** use Io.File.stat for cross-platform mode check ([e97501c](https://github.com/keton-id/cora/commit/e97501c0ae15946e3063b5914e0275470f40f5f5))

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
