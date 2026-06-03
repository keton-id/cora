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

This npm package bundles the prebuilt `cr` binary for every supported platform and arch:

| platform | arch | tier |
| --- | --- | --- |
| macOS | x64 | Tier 1 |
| macOS | arm64 | Tier 1 |
| Linux | x64 | Tier 1 |
| Linux | arm64 | Tier 1 |
| Windows | x64 | Tier 1 |
| Windows | arm64 | Tier 1 |

Caller-identity verification is kernel-backed on every supported target — `SO_PEERCRED` on Linux, `LOCAL_PEERPID` on macOS, `GetNamedPipeClientProcessId` on Windows. See [SECURITY.md](https://github.com/keton-id/cora/blob/main/SECURITY.md) for the full trust model.

At runtime, a tiny JS shim (`bin/cr.js`) picks the matching native binary out of the bundled `vendor/` directory. There are no postinstall scripts, no install-time downloads, and no `node_modules` runtime dependencies.

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

Only **stable** releases publish to npm, matching the Homebrew and Scoop channels. Pre-1.0 alphas remain on GitHub Releases only — install them by downloading the tarball/zip directly, or via `cargo install`/`go install`-style scripts against the release URL.

Pin a specific stable build with `@<version>` to keep an environment reproducible:

```sh
npm i -g @keton-id/cora@1.0.0
```

## License

[AGPL-3.0-only](https://github.com/keton-id/cora/blob/main/LICENSE). Commercial license inquiries welcome.

## Links

- Source: <https://github.com/keton-id/cora>
- Security: <https://github.com/keton-id/cora/blob/main/SECURITY.md>
- Issues: <https://github.com/keton-id/cora/issues>
