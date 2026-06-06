# @keton-id/cora

> Zero-knowledge secret injection runtime for AI agents.

`cr` is a single-binary CLI that holds your secrets encrypted at rest and injects them straight into a child process's environment — without the agent ever seeing the values. Encrypted-file based (Argon2id + XChaCha20-Poly1305), portable, no infra required.

## Install

```sh
npm i -g @keton-id/cora
cr --help
```

Or one-shot via `npx`:

```sh
npx @keton-id/cora --help
```

## What's in this package

This is the **meta** package. It contains:

- a small ESM launcher (`bin/cr.js`)
- six `optionalDependencies` — one per `<platform>-<arch>` combination

npm reads the `os` and `cpu` fields on each optional dep at install time and silently skips the five that don't match your host, so only the matching prebuilt native `cr` binary lands on disk:

| platform | arch | subpackage |
| --- | --- | --- |
| macOS | x64 | `@keton-id/cora-darwin-x64` |
| macOS | arm64 | `@keton-id/cora-darwin-arm64` |
| Linux | x64 | `@keton-id/cora-linux-x64` |
| Linux | arm64 | `@keton-id/cora-linux-arm64` |
| Windows | x64 | `@keton-id/cora-win32-x64` |
| Windows | arm64 | `@keton-id/cora-win32-arm64` |

There are no postinstall scripts, no install-time downloads, and no `node_modules` runtime dependencies beyond the resolved subpackage.

Caller-identity verification is kernel-backed on every supported target — `SO_PEERCRED` on Linux, `LOCAL_PEERPID` on macOS, `GetNamedPipeClientProcessId` on Windows. See [SECURITY.md](https://github.com/keton-id/cora/blob/main/SECURITY.md) for the full trust model.

## Usage

The full CLI surface is documented at <https://github.com/keton-id/cora>. Quick orientation:

```sh
cr init                                       # create encrypted cora.zon
cr secrets set GITHUB_TOKEN                   # add a secret (prompts)
cr policy task add deploy GITHUB_TOKEN        # scope a task to that secret
cr unlock                                     # start the background service
cr exec deploy -- ./my-script.sh              # spawn with injected env
cr lock                                       # zero memory, stop service
```

Help is conventional:

```sh
cr help                       # top-level
cr --help                     # same
cr <subcommand> --help        # per-subcommand
cr help <subcommand> <action> # deep
```

## Versioning

Every Cora release ships under one upstream `v*` tag and up to three per-OS mirror tags (`cora-macos-v*`, `cora-linux-v*`, `cora-windows-v*`) — only OSes whose code actually changed get a mirror, so e.g. a Windows-only fix bumps only the win32 subpackages.

The npm packages follow that shape:

- `@keton-id/cora-<platform>-<arch>` (subpackages) — versioned to the mirror tag that produced them. A subpackage version reports the actual `cr` version on its host.
- `@keton-id/cora` (this meta) — versioned at the upstream release semver (e.g. `0.9.2`). Every publish re-pins `optionalDependencies` to whatever each subpackage's current registry version is, queried live at publish time. `@latest` therefore always pulls the freshest binary for your host, and out-of-step per-OS releases ship cleanly because each subpackage pin reflects that OS's actual current version, not whatever the upstream release shipped.

`cr version` reports the subpackage's version (the one actually running on your machine), not the meta version.

Pin a specific build with `@<version>` to keep an environment reproducible:

```sh
npm i -g @keton-id/cora@1.0.0
```

Pre-1.0 alphas remain on GitHub Releases only and are not published to npm.

## License

[AGPL-3.0-only](https://github.com/keton-id/cora/blob/main/LICENSE). Commercial license inquiries welcome.

## Links

- Source: <https://github.com/keton-id/cora>
- Security: <https://github.com/keton-id/cora/blob/main/SECURITY.md>
- Issues: <https://github.com/keton-id/cora/issues>
