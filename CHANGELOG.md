# Changelog

All notable changes to Cora are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and uses
[Conventional Commits](https://www.conventionalcommits.org/). Entries below
are generated automatically by
[release-please](https://github.com/googleapis/release-please) — do not edit
by hand.

## Current versions

| OS      | Latest release                                                                                                                                                                              | Tag prefix         |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ |
| macOS   | [![macOS](https://img.shields.io/github/v/release/keton-id/cora?include_prereleases&filter=cora-macos-v*&label=%20&color=0db7ed)](https://github.com/keton-id/cora/releases?q=cora-macos-)     | `cora-macos-v*`    |
| Linux   | [![Linux](https://img.shields.io/github/v/release/keton-id/cora?include_prereleases&filter=cora-linux-v*&label=%20&color=fcc624)](https://github.com/keton-id/cora/releases?q=cora-linux-)     | `cora-linux-v*`    |
| Windows | [![Windows](https://img.shields.io/github/v/release/keton-id/cora?include_prereleases&filter=cora-windows-v*&label=%20&color=00a4ef)](https://github.com/keton-id/cora/releases?q=cora-windows-) | `cora-windows-v*`  |

<!--
Badges read GitHub Releases live, so this table refreshes itself whenever
release-please cuts a new per-OS tag. Versions older than the OS split
(`v0.9.1-alpha.1` and earlier) appear under the "Pre-OS-split history"
section below.
-->

Per-OS release notes are interleaved by date below. Each section header
carries the full tag (e.g. `cora-macos-v0.9.2-alpha.1`) so you can filter
visually by OS. See [RELEASING.md](./RELEASING.md) for how the per-OS
versioning works.

## Pre-OS-split history

The entries below were cut while Cora shipped as a single package under
the `v*` tag prefix. They affect every OS unless explicitly noted.

## [0.9.2-alpha.2](https://github.com/keton-id/cora/compare/v0.9.1-alpha.1...v0.9.2-alpha.2) (2026-06-06)


### Misc

* **release:** exercise per-OS release flow ([96ed461](https://github.com/keton-id/cora/commit/96ed46129304d462f327833aeed0cb1aee186659))

## [0.9.1-alpha.1](https://github.com/keton-id/cora/compare/v0.9.0-alpha.1...v0.9.1-alpha.1) (2026-06-04)


### Bug Fixes

* **ci:** align scoop manifest artifact names with build output ([ee072f2](https://github.com/keton-id/cora/commit/ee072f2840c0238a8f365ce411a53635a038e58e))

## [0.9.0](https://github.com/keton-id/cora/compare/v0.7.0...v0.9.0) (2026-06-04)

## What's Changed
* chore(changelog): enrich v0.7.0 with contributors by @github-actions[bot] in https://github.com/keton-id/cora/pull/28
* feat(windows): Tier-2 parity — Named Pipes, peer PID, daemonize by @mulhamna in https://github.com/keton-id/cora/pull/29
* chore: CODEOWNERS + collapsible install methods in README by @mulhamna in https://github.com/keton-id/cora/pull/33
* chore(main): release 0.8.0-alpha.1 by @mulhamna in https://github.com/keton-id/cora/pull/30
* fix(service): exempt mgmt ops (ping/status/lock) from caller policy by @resincode in https://github.com/keton-id/cora/pull/31
* fix: land PR #32 and #34 on main by @mulhamna in https://github.com/keton-id/cora/pull/36
* chore(main): release 0.8.1-alpha.1 by @mulhamna in https://github.com/keton-id/cora/pull/35
* fix(tui): resize, lock guard, passphrase mask, help modal by @mulhamna in https://github.com/keton-id/cora/pull/38
* fix(repo): CODEOWNERS to root + nest npm under packaging/ by @mulhamna in https://github.com/keton-id/cora/pull/41
* fix: land PR #37 and #40 on main by @mulhamna in https://github.com/keton-id/cora/pull/42
* feat(windows): cr exec stdio parity via DuplicateHandle + PATH/PATHEXT target resolve by @mulhamna in https://github.com/keton-id/cora/pull/43
* chore(main): release 0.9.0-alpha.1 by @mulhamna in https://github.com/keton-id/cora/pull/39


**Full Changelog**: https://github.com/keton-id/cora/compare/v0.7.0...v0.9.0

### Contributors

@github-actions, @mulhamna, @resincode

## [0.9.0-alpha.1](https://github.com/keton-id/cora/compare/v0.8.1-alpha.1...v0.9.0-alpha.1) (2026-06-04)


### Features

* **policy:** allowed_targets per task to block secret-leak spawn targets ([0ab8182](https://github.com/keton-id/cora/commit/0ab81827007c75ee8a6c2aafd8e264a17712b147))
* **service,cli,policy:** cr exec stdio + target whitelist on Windows ([d13310b](https://github.com/keton-id/cora/commit/d13310b19da6474a66acf6e610423507551df71e))
* **windows:** cr exec stdio parity via DuplicateHandle + PATH/PATHEXT target resolve ([5a085cd](https://github.com/keton-id/cora/commit/5a085cde53b13533147e6403b982a7699eb3704f))


### Bug Fixes

* **audit:** fall back to USERPROFILE on Windows when HOME is unset ([a9e7640](https://github.com/keton-id/cora/commit/a9e76404a378d0f53da09312b829fd46a4cf2b0e))
* land PR [#37](https://github.com/keton-id/cora/issues/37) and [#40](https://github.com/keton-id/cora/issues/40) on main ([0487126](https://github.com/keton-id/cora/commit/0487126494140bdd865cc3aee094c339c0c56773))
* **packaging:** nest npm package under packaging/ for future packagers ([da8081d](https://github.com/keton-id/cora/commit/da8081d4b1fe0d7422e9e6132c541ef2fbb8493f))
* **repo:** CODEOWNERS to root + nest npm under packaging/ ([b11ca7c](https://github.com/keton-id/cora/commit/b11ca7cdc5e6f9fdd4cd32b5c10fd14f7762985b))
* **repo:** move CODEOWNERS to repository root ([a5e0b7d](https://github.com/keton-id/cora/commit/a5e0b7db11ddee0839f91c100cc7fc00079a2822))
* **service,cli:** pass caller stdio to spawn child via SCM_RIGHTS (POSIX) ([4066647](https://github.com/keton-id/cora/commit/4066647d716d59c4f84ab0155f15fa00be88adf5))
* **service:** inherit daemon env when spawning cr exec target on Windows ([eaf8d25](https://github.com/keton-id/cora/commit/eaf8d25574a08c6e44aa6d498858041743092552))
* **service:** only quote argv entries that need it on Windows cmdline ([9cdd28f](https://github.com/keton-id/cora/commit/9cdd28ffd0082e5752062a532045e09b1b67a224))
* **service:** restrict CreateProcessW handle inheritance to explicit list ([f7e3f38](https://github.com/keton-id/cora/commit/f7e3f38165ae2a375ffea377e80dc778254eaaa7))
* **service:** reuse single named-pipe HANDLE across accept iterations ([f82358e](https://github.com/keton-id/cora/commit/f82358e2fc7f0e180af1388f8bbf0533f46b1a82))
* **tui:** add a keyboard help modal ([061bd5e](https://github.com/keton-id/cora/commit/061bd5e4069fa5461618f65240b852d75bd14a17))
* **tui:** make the dashboard grid reflow with terminal width ([0d8a168](https://github.com/keton-id/cora/commit/0d8a1689c17ee3878d605ee7dad0aece34bf430e))
* **tui:** paint immediately and survive narrow terminals ([f10dda6](https://github.com/keton-id/cora/commit/f10dda6781ef2b8cb3ec48054674ac6e1feb438c))
* **tui:** resize, lock guard, passphrase mask, help modal ([e343c33](https://github.com/keton-id/cora/commit/e343c338db594ab9e4cc5348ac40d6f4522eec90))
* **tui:** show passphrase mask characters ([054a1a1](https://github.com/keton-id/cora/commit/054a1a1a170bf25950877b9e914d6f1de83717f5))
* **tui:** skip lock modal when service is offline ([bafca2c](https://github.com/keton-id/cora/commit/bafca2c5f40c0220721f5572a9a58ef76b69e58c))
* **tui:** wire SIGWINCH so resize events reach the event loop ([69dbcb0](https://github.com/keton-id/cora/commit/69dbcb027c3fb0cb0ff9936af7b8e923d720d3fc))

## [0.8.1-alpha.1](https://github.com/keton-id/cora/compare/v0.8.0-alpha.1...v0.8.1-alpha.1) (2026-06-03)


### Bug Fixes

* **cli:** skip passphrase for `secrets list` and `policy show` when service unlocked ([5878d13](https://github.com/keton-id/cora/commit/5878d138fefc582804a6df676af704133cf65396))
* land PR [#32](https://github.com/keton-id/cora/issues/32) and [#34](https://github.com/keton-id/cora/issues/34) on main ([245dd6c](https://github.com/keton-id/cora/commit/245dd6c497ebddab04f6346b39ad13f2a5370d8a))
* **service,cli:** force lock shutdown + star-echo passphrase ([54112d4](https://github.com/keton-id/cora/commit/54112d439de26bc4bd4079e1ee983ef063d1b405))
* **service:** exempt mgmt ops (ping/status/lock) from caller policy ([29fa5a8](https://github.com/keton-id/cora/commit/29fa5a83ae53ed2830dfcaf96d56d3440b015f29))
* **service:** exempt mgmt ops from caller policy ([fd03748](https://github.com/keton-id/cora/commit/fd03748db347936c3f0d9da9230e75575f3e3394))

## [0.8.0-alpha.1](https://github.com/keton-id/cora/compare/v0.7.0-alpha.1...v0.8.0-alpha.1) (2026-06-02)


### Features

* **windows:** add Named Pipe and CreateProcessW wrappers ([8946f5e](https://github.com/keton-id/cora/commit/8946f5efd0885bf0924ddcc9e910ee671e752223))
* **windows:** daemonize cr unlock and drop preview banner ([9b050bd](https://github.com/keton-id/cora/commit/9b050bd699aaa673dc461f16700b56cbb9d78a71))
* **windows:** Tier-2 parity — Named Pipes, peer PID, daemonize ([02df367](https://github.com/keton-id/cora/commit/02df3672a13f3ada623108b78967664b02203d35))

## [0.7.0](https://github.com/keton-id/cora/compare/v0.6.1...v0.7.0) (2026-06-02)

## What's Changed
* chore(changelog): enrich v0.6.1 with contributors by @github-actions[bot] in https://github.com/keton-id/cora/pull/24
* feat(cli): add help and version flag conventions by @mulhamna in https://github.com/keton-id/cora/pull/25
* ci(release): publish @keton-id/cora to npm by @mulhamna in https://github.com/keton-id/cora/pull/27
* chore(main): release 0.7.0-alpha.1 by @mulhamna in https://github.com/keton-id/cora/pull/26


**Full Changelog**: https://github.com/keton-id/cora/compare/v0.6.1...v0.7.0

### Contributors

@github-actions, @keton-id, @mulhamna

## [0.7.0-alpha.1](https://github.com/keton-id/cora/compare/v0.6.1-alpha.1...v0.7.0-alpha.1) (2026-06-02)


### Features

* **cli:** add help and version conventions module ([170e234](https://github.com/keton-id/cora/commit/170e234e64f9742307e32b7f4d6f6983b69ec3cb))
* **cli:** add help and version flag conventions ([3df2f08](https://github.com/keton-id/cora/commit/3df2f088818d2f14adfb32ef09d45d2c6ec427b7))
* **cli:** add outPrint helper for pipe-friendly data output ([57b6739](https://github.com/keton-id/cora/commit/57b673928ee73a40648b010b43f7931fbf2514fa))
* **npm:** add @keton-id/cora package, JS launcher, and CI prepare script ([91c544c](https://github.com/keton-id/cora/commit/91c544ca143db3e03775aae4dc9b08914586d764))


### Bug Fixes

* **cli:** use proven write path in outPrint and assert stdout in tests ([e9998f7](https://github.com/keton-id/cora/commit/e9998f7fc9e98e2d830629e4d329a893d80570e8))

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
