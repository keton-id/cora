# @keton-id/cora

> Zero-knowledge secret injection runtime for AI agents.

`cr` keeps secrets encrypted at rest and injects them into child-process environments without exposing values to the agent.

## Install

```sh
npm i -g @keton-id/cora
cr --help
```

Or use it once with `npx`:

```sh
npx @keton-id/cora --help
```

## One package, six native targets

`@keton-id/cora` is the only npm package. Its postinstall script downloads the binary matching the host and verifies the archive against the SHA256 sidecar published with the same GitHub release.

| OS | Architecture | Release asset |
| --- | --- | --- |
| macOS | x64 | `cr-X.Y.Z-x86_64-macos.tar.gz` |
| macOS | arm64 | `cr-X.Y.Z-aarch64-macos.tar.gz` |
| Linux | x64 | `cr-X.Y.Z-x86_64-linux.tar.gz` |
| Linux | arm64 | `cr-X.Y.Z-aarch64-linux.tar.gz` |
| Windows | x64 | `cr-X.Y.Z-x86_64-windows.zip` |
| Windows | arm64 | `cr-X.Y.Z-aarch64-windows.zip` |

Installation requires network access to the matching GitHub Release. Windows extraction uses PowerShell; macOS and Linux use `tar`. If npm scripts are disabled, run `npm rebuild @keton-id/cora` to install the native binary.

## Usage

```sh
cr init
cr secrets set GITHUB_TOKEN
cr policy task add deploy GITHUB_TOKEN
cr unlock
cr exec deploy -- ./my-script.sh
cr lock
```

Help is conventional:

```sh
cr help
cr --help
cr <subcommand> --help
cr help <subcommand> <action>
```

## Versioning

The npm package version matches the stable `v<X.Y.Z>` GitHub Release tag. `cr update` delegates to npm when Cora was installed from this package.

The release workflow publishes this package to npmjs.org using GitHub Actions OIDC. Its npm Trusted Publisher is configured for repository `keton-id/cora`, workflow `.github/workflows/release.yml`, and environment `Release`.

The full release process is documented in [`RELEASING.md`](https://github.com/keton-id/cora/blob/main/RELEASING.md).

## License

[AGPL-3.0-only](https://github.com/keton-id/cora/blob/main/LICENSE). Commercial license inquiries welcome.

## Links

- Source: <https://github.com/keton-id/cora>
- Security: <https://github.com/keton-id/cora/blob/main/SECURITY.md>
- Issues: <https://github.com/keton-id/cora/issues>
