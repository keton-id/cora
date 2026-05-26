#!/usr/bin/env sh
# Install script for cora (`cr`).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/keton-id/cora/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/keton-id/cora/main/install.sh | sh -s -- --channel alpha
#   curl -fsSL https://raw.githubusercontent.com/keton-id/cora/main/install.sh | sh -s -- --bindir ~/.local/bin
#
# Flags:
#   --channel <stable|alpha|beta|rc>   default: stable (skip prereleases)
#   --version <vX.Y.Z[-tag]>           pin to a specific tag
#   --bindir <path>                    default: /usr/local/bin (sudo) or ~/.local/bin
#   --no-verify                        skip SHA256 verification (NOT recommended)
#
# Verifies the downloaded tarball against the per-asset .sha256 file before
# extracting. Refuses to install if checksum mismatches.

set -eu

REPO="keton-id/cora"
CHANNEL="stable"
PIN_VERSION=""
BINDIR=""
NO_VERIFY="0"

while [ $# -gt 0 ]; do
    case "$1" in
        --channel)  CHANNEL="$2"; shift 2;;
        --version)  PIN_VERSION="$2"; shift 2;;
        --bindir)   BINDIR="$2"; shift 2;;
        --no-verify) NO_VERIFY="1"; shift;;
        -h|--help)
            grep -E '^# ' "$0" | sed 's/^# //'
            exit 0
            ;;
        *) echo "unknown flag: $1" >&2; exit 1;;
    esac
done

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: required command '$1' not found in PATH" >&2
        exit 1
    }
}

need curl
need tar
need uname
[ "$NO_VERIFY" = "1" ] || need shasum

detect_target() {
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os" in
        Darwin)  os_tag="macos";;
        Linux)   os_tag="linux";;
        *) echo "unsupported OS: $os" >&2; exit 1;;
    esac
    case "$arch" in
        x86_64|amd64) arch_tag="x86_64";;
        arm64|aarch64) arch_tag="aarch64";;
        *) echo "unsupported arch: $arch" >&2; exit 1;;
    esac
    printf '%s' "${arch_tag}-${os_tag}"
}

resolve_version() {
    if [ -n "$PIN_VERSION" ]; then
        printf '%s' "$PIN_VERSION"
        return
    fi
    case "$CHANNEL" in
        stable)
            curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
                | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
                | head -n 1
            ;;
        alpha|beta|rc)
            curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=20" \
                | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
                | grep -E -- "-${CHANNEL}\." \
                | head -n 1
            ;;
        *) echo "unknown channel: $CHANNEL" >&2; exit 1;;
    esac
}

main() {
    target="$(detect_target)"
    tag="$(resolve_version)"
    if [ -z "$tag" ]; then
        echo "could not resolve a release for channel='$CHANNEL'" >&2
        exit 1
    fi
    version="${tag#v}"
    artifact="cr-${version}-${target}.tar.gz"
    base_url="https://github.com/${REPO}/releases/download/${tag}"

    if [ -z "$BINDIR" ]; then
        if [ "$(id -u)" = "0" ]; then
            BINDIR="/usr/local/bin"
        elif [ -w "/usr/local/bin" ]; then
            BINDIR="/usr/local/bin"
        else
            BINDIR="$HOME/.local/bin"
        fi
    fi
    mkdir -p "$BINDIR"

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT INT TERM

    echo "downloading $artifact ($tag) → $tmpdir"
    curl -fsSL "${base_url}/${artifact}" -o "${tmpdir}/${artifact}"

    if [ "$NO_VERIFY" = "1" ]; then
        echo "warning: skipping SHA256 verification (--no-verify)"
    else
        echo "fetching checksum"
        curl -fsSL "${base_url}/${artifact}.sha256" -o "${tmpdir}/${artifact}.sha256"
        expected="$(awk '{print $1}' "${tmpdir}/${artifact}.sha256")"
        actual="$(shasum -a 256 "${tmpdir}/${artifact}" | awk '{print $1}')"
        if [ "$expected" != "$actual" ]; then
            echo "SHA256 mismatch!" >&2
            echo "expected: $expected" >&2
            echo "actual:   $actual"   >&2
            exit 1
        fi
        echo "checksum ok"
    fi

    tar -xzf "${tmpdir}/${artifact}" -C "$tmpdir"
    install -m 0755 "${tmpdir}/cr" "${BINDIR}/cr"

    echo "installed $("${BINDIR}/cr" version)"
    echo "binary at: ${BINDIR}/cr"

    case ":$PATH:" in
        *":${BINDIR}:"*) ;;
        *) echo "note: ${BINDIR} is not in your PATH";;
    esac
}

main "$@"
