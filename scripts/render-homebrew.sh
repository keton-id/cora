#!/usr/bin/env bash
#
# Render a Homebrew formula for `cr` against a specific version of GitHub
# release artifacts. Emits the formula to stdout.
#
# Usage:
#   render-homebrew.sh <version> <dist-dir>
#
# Arguments:
#   version    Semantic version with no `v` prefix, e.g. "0.3.0".
#   dist-dir   Directory containing the downloaded release artifacts. The
#              script reads `<name>.sha256` files next to each tarball.
#
# The four macOS/Linux artifacts MUST already exist with their .sha256
# siblings under <dist-dir>:
#   cr-<version>-aarch64-macos.tar.gz(.sha256)
#   cr-<version>-x86_64-macos.tar.gz(.sha256)
#   cr-<version>-aarch64-linux.tar.gz(.sha256)
#   cr-<version>-x86_64-linux.tar.gz(.sha256)

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

SHA_AARCH64_MACOS=$(sha "cr-${VERSION}-aarch64-macos.tar.gz")
SHA_X86_64_MACOS=$(sha "cr-${VERSION}-x86_64-macos.tar.gz")
SHA_AARCH64_LINUX=$(sha "cr-${VERSION}-aarch64-linux.tar.gz")
SHA_X86_64_LINUX=$(sha "cr-${VERSION}-x86_64-linux.tar.gz")

cat <<EOF
class Cr < Formula
  desc "Zero-knowledge secret injection runtime for AI agents"
  homepage "https://github.com/keton-id/cora"
  version "${VERSION}"
  license "AGPL-3.0-only"

  on_macos do
    on_arm do
      url "https://github.com/keton-id/cora/releases/download/v${VERSION}/cr-${VERSION}-aarch64-macos.tar.gz"
      sha256 "${SHA_AARCH64_MACOS}"
    end
    on_intel do
      url "https://github.com/keton-id/cora/releases/download/v${VERSION}/cr-${VERSION}-x86_64-macos.tar.gz"
      sha256 "${SHA_X86_64_MACOS}"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/keton-id/cora/releases/download/v${VERSION}/cr-${VERSION}-aarch64-linux.tar.gz"
      sha256 "${SHA_AARCH64_LINUX}"
    end
    on_intel do
      url "https://github.com/keton-id/cora/releases/download/v${VERSION}/cr-${VERSION}-x86_64-linux.tar.gz"
      sha256 "${SHA_X86_64_LINUX}"
    end
  end

  def install
    bin.install "cr"
  end

  test do
    system "#{bin}/cr", "version"
  end
end
EOF
