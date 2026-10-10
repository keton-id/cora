#!/usr/bin/env sh
# Install script for cora (`cr`).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/keton-id/cora/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/keton-id/cora/main/install.sh | sh -s -- --bindir ~/.local/bin
#
# Flags:
#   --version <X.Y.Z|vX.Y.Z>            pin a stable release
#   --bindir <path>                      default: /usr/local/bin (sudo) or ~/.local/bin
#   --no-verify                          skip SHA256 verification (NOT recommended)
#
# Downloads the host's archive from the unified stable vX.Y.Z release and
# verifies it against the per-asset .sha256 file before extracting.

set -eu

REPO="keton-id/cora"
PIN_VERSION=""
BINDIR=""
NO_VERIFY="0"

while [ $# -gt 0 ]; do
    case "$1" in
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

# Returns the OS slice from a target like `aarch64-macos` -> `macos`.
target_os() {
    printf '%s' "${1#*-}"
}

resolve_tag() {
    if [ -n "$PIN_VERSION" ]; then
        case "$PIN_VERSION" in
            v*) printf '%s' "$PIN_VERSION" ;;
            *)  printf 'v%s' "$PIN_VERSION" ;;
        esac
        return
    fi
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | sed -n 's/.*"tag_name": *"\(v[0-9][0-9.]*\)".*/\1/p'
}

main() {
    target="$(detect_target)"
    os="$(target_os "$target")"
    tag="$(resolve_tag)"
    if ! printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "could not resolve a stable vX.Y.Z release for os='${os}'" >&2
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
