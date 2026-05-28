#!/usr/bin/env bash
#
# Render a Scoop manifest for `cr` against a specific version of GitHub
# release artifacts. Emits the manifest JSON to stdout.
#
# Usage:
#   render-scoop.sh <version> <dist-dir>
#
# Arguments:
#   version    Semantic version with no `v` prefix, e.g. "0.3.0".
#   dist-dir   Directory containing the downloaded release artifacts. The
#              script reads `<name>.sha256` files next to each zip.
#
# The two Windows artifacts MUST already exist with their .sha256 siblings
# under <dist-dir>:
#   cr-<version>-x86_64-windows-preview.zip(.sha256)
#   cr-<version>-aarch64-windows-preview.zip(.sha256)

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $(basename "$0") <version> <dist-dir>" >&2
  exit 2
fi

VERSION="$1"
DIST_DIR="$2"

if [ ! -d "$DIST_DIR" ]; then
  echo "error: dist directory not found: $DIST_DIR" >&2
  exit 1
fi

sha() {
  local artifact="$1"
  local sha_file="${DIST_DIR}/${artifact}.sha256"
  if [ ! -f "$sha_file" ]; then
    echo "error: missing sha256 sibling: $sha_file" >&2
    exit 1
  fi
  awk '{print $1}' "$sha_file"
}

SHA_X86_64=$(sha "cr-${VERSION}-x86_64-windows-preview.zip")
SHA_ARM64=$(sha "cr-${VERSION}-aarch64-windows-preview.zip")

cat <<EOF
{
  "version": "${VERSION}",
  "description": "Zero-knowledge secret injection runtime for AI agents",
  "homepage": "https://github.com/keton-id/cora",
  "license": "AGPL-3.0-only",
  "architecture": {
    "64bit": {
      "url": "https://github.com/keton-id/cora/releases/download/v${VERSION}/cr-${VERSION}-x86_64-windows-preview.zip",
      "hash": "${SHA_X86_64}",
      "bin": "cr.exe"
    },
    "arm64": {
      "url": "https://github.com/keton-id/cora/releases/download/v${VERSION}/cr-${VERSION}-aarch64-windows-preview.zip",
      "hash": "${SHA_ARM64}",
      "bin": "cr.exe"
    }
  },
  "checkver": "github",
  "autoupdate": {
    "architecture": {
      "64bit": {
        "url": "https://github.com/keton-id/cora/releases/download/v\$version/cr-\$version-x86_64-windows-preview.zip"
      },
      "arm64": {
        "url": "https://github.com/keton-id/cora/releases/download/v\$version/cr-\$version-aarch64-windows-preview.zip"
      }
    }
  }
}
EOF
