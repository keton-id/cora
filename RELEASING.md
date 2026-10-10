# Releasing Cora

Cora publishes one stable release for all supported operating systems at
`v<X.Y.Z>`. The release builds six targets, attaches their archives to a
single GitHub Release titled `Cora v<X.Y.Z>`, and publishes the npm
subpackages and launcher at that version.

## Release flow

1. Merge Conventional Commits to `main`.
2. `release-please` opens or updates a release PR with the version,
   changelog, and manifest changes.
3. Merge the release PR. Its `v<X.Y.Z>` tag starts
   `.github/workflows/release.yml`.
4. The workflow builds macOS, Linux, and Windows for x64 and ARM64,
   publishes one GitHub Release, updates Homebrew and Scoop, and
   publishes all npm packages.

The release workflow accepts a plain stable `v<X.Y.Z>` tag only. Alpha
and per-OS tags are not part of the release process.

## Version source

`.version` in [`build.zig.zon`](build.zig.zon) is the version
source-of-truth. release-please updates it and
`.github/release-please-manifest.json`; do not bump either by hand.
Use the `Release-As: X.Y.Z` footer to request a specific next version.

## Artifacts

Each GitHub Release contains six archives, one `.sha256` sidecar per
archive, and `SHA256SUMS`. Windows targets are ZIPs; macOS and Linux
targets are tarballs. Installers and package-manager manifests use the
same release tag and checksums.

## npm Trusted Publishing

All seven public packages publish to npmjs.org through npm Trusted
Publishing (GitHub Actions OIDC); no `NPM_TOKEN` is used. Before the
first publish, register each package on npmjs.com with:

- Repository: `keton-id/cora`
- Workflow file: `.github/workflows/release.yml`
- Environment: `Release`

Register `@keton-id/cora` and each of its six platform packages:
`@keton-id/cora-darwin-x64`, `@keton-id/cora-darwin-arm64`,
`@keton-id/cora-linux-x64`, `@keton-id/cora-linux-arm64`,
`@keton-id/cora-win32-x64`, and `@keton-id/cora-win32-arm64`.

The GitHub Packages mirror is no longer published. npm consumers use
npmjs.org.

## Recovering a failed release

Do not delete or move a release tag. Re-run the **release** workflow
with the existing `v<X.Y.Z>` tag. Builds and asset uploads replace
matching release assets; npm publish steps skip package versions that
already exist.
