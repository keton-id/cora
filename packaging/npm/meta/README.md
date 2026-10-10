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

Every stable Cora release uses one `v<X.Y.Z>` tag and publishes all six
platform subpackages at that version.

- `@keton-id/cora-<platform>-<arch>` contains that release's platform
  binary.
- `@keton-id/cora` tracks the same release semver and pins each
  `optionalDependency` to the matching subpackage version.

The full release process is documented in
[`RELEASING.md`](https://github.com/keton-id/cora/blob/main/RELEASING.md).

`cr version` reports the subpackage's version (the one actually running on your machine), not the meta version.

Pin a specific build with `@<version>` to keep an environment reproducible:

```sh
npm i -g @keton-id/cora@1.0.0
```


## License

[AGPL-3.0-only](https://github.com/keton-id/cora/blob/main/LICENSE). Commercial license inquiries welcome.

## Links

- Source: <https://github.com/keton-id/cora>
- Security: <https://github.com/keton-id/cora/blob/main/SECURITY.md>
- Issues: <https://github.com/keton-id/cora/issues>
