# Releasing Cora

Cora publishes one stable release for all supported operating systems at
`v<X.Y.Z>`. Each release has six binary archives and one npm package:
`@keton-id/cora`.

## Release flow

1. Merge Conventional Commits to `main`.
2. `release-please` opens or updates a release PR with the version,
   changelog, and manifest changes.
3. Merge the release PR. Its `v<X.Y.Z>` tag starts
   `.github/workflows/release.yml`.
4. The workflow builds macOS, Linux, and Windows for x64 and ARM64,
   publishes one GitHub Release titled `Cora v<X.Y.Z>`, updates
   Homebrew and Scoop, and publishes `@keton-id/cora`.

The release workflow accepts stable `v<X.Y.Z>` tags only. There are no
alpha or per-OS release channels.

## Version source

`.version` in [`build.zig.zon`](build.zig.zon) is the version
source-of-truth. release-please updates it and
`.github/release-please-manifest.json`; do not bump either by hand.
Use the `Release-As: X.Y.Z` footer to request a specific next version.

## Artifacts

Each GitHub Release contains six archives, one `.sha256` sidecar per
archive, and `SHA256SUMS`. Windows targets are ZIPs; macOS and Linux
targets are tarballs. Installers, Homebrew, and Scoop use the same tag
and checksums.

## npm Trusted Publishing

Only `@keton-id/cora` is published to npmjs.org. Its postinstall script
downloads the archive for the current OS and architecture from the
matching `v<X.Y.Z>` GitHub Release and verifies the SHA256 sidecar.

Register one Trusted Publisher on npmjs.com:

- Package: `@keton-id/cora`
- Repository: `keton-id/cora`
- Workflow file: `.github/workflows/release.yml`
- Environment: `Release`

Publishing uses GitHub Actions OIDC; no `NPM_TOKEN` is required. The
GitHub Packages mirror and per-platform npm packages are not published.

## Recovering a failed release

Do not delete or move a release tag. Re-run the **release** workflow
with the existing `v<X.Y.Z>` tag. Asset uploads replace matching files,
and the npm publish job skips a package version that already exists.
The npm wrapper is checked out from `main` and its version is pinned to
the requested release tag, so a failed npm publish can be retried after
the package installer is fixed without rebuilding the tagged binary.
