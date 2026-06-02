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
| Windows | x64 | **Tier 1 preview** |
| Windows | arm64 | **Tier 1 preview** |

The Windows builds run, but the caller-identity verification path is reduced to NTFS ACL trust on the per-user data directory rather than kernel-verified peer credentials. See [SECURITY.md](https://github.com/keton-id/cora/blob/main/SECURITY.md) for the full trust model.

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

Releases follow conventional commits via release-please. Stable releases publish under the `latest` dist-tag; pre-1.0 alphas publish under `alpha`. Pin a specific build with `@<version>` to keep an environment reproducible:

```sh
npm i -g @keton-id/cora@0.6.1-alpha.1
```

## License

[AGPL-3.0-only](https://github.com/keton-id/cora/blob/main/LICENSE). Commercial license inquiries welcome.

## Links

- Source: <https://github.com/keton-id/cora>
- Security: <https://github.com/keton-id/cora/blob/main/SECURITY.md>
- Issues: <https://github.com/keton-id/cora/issues>
