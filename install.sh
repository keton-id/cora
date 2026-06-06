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
#   --version <X.Y.Z[-suffix]|tag>     pin to a version (plain X.Y.Z is
#                                      auto-prefixed with cora-<os>-v) or
#                                      pass the full tag (e.g. cora-macos-v1.0.0).
#   --bindir <path>                    default: /usr/local/bin (sudo) or ~/.local/bin
#   --no-verify                        skip SHA256 verification (NOT recommended)
#
# Verifies the downloaded tarball against the per-asset .sha256 file before
# extracting. Refuses to install if checksum mismatches.
#
# Each OS has its own release stream: `cora-macos-v*`, `cora-linux-v*`,
# `cora-windows-v*`. This script auto-detects the host OS and queries
# only that stream so a fresh Windows release does not show up as the
# latest for Linux users (or vice versa).

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

# Returns the OS slice from a target like `aarch64-macos` -> `macos`.
target_os() {
    printf '%s' "${1#*-}"
}

resolve_tag() {
    target="$1"
    os="$(target_os "$target")"
    prefix="cora-${os}-v"

    if [ -n "$PIN_VERSION" ]; then
        case "$PIN_VERSION" in
            cora-*-v*)
                # Operator passed a fully-qualified tag; trust it.
                printf '%s' "$PIN_VERSION"
                ;;
            v*)
                # Legacy bare `vX.Y.Z` — strip the v, re-prefix for the host OS.
                printf '%s%s' "$prefix" "${PIN_VERSION#v}"
                ;;
            *)
                # Bare semver — prefix for the host OS.
                printf '%s%s' "$prefix" "$PIN_VERSION"
                ;;
        esac
        return
    fi

    # Pull the GitHub release tag stream once and try the per-OS prefix
    # first. `releases/latest` returns the most recent stable across all
    # OS streams, which is wrong for a per-OS install — so we always
    # paginate and filter ourselves.
    all_tags="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=100" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"

    pick_tag() {
        # Args: <prefix> <stable_re> <prerelease_re>
        _prefix="$1"; _stable="$2"; _pre="$3"
        case "$CHANNEL" in
            stable)
                printf '%s' "$all_tags" \
                    | grep -E -- "^${_prefix}${_stable}\$" \
                    | head -n 1
                ;;
            alpha|beta|rc)
                printf '%s' "$all_tags" \
                    | grep -E -- "^${_prefix}${_pre}" \
                    | head -n 1
                ;;
            *) echo "unknown channel: $CHANNEL" >&2; exit 1;;
        esac
    }

    # Per-OS stream first.
    tag="$(pick_tag "$prefix" "[0-9]+\.[0-9]+\.[0-9]+" "[0-9]+\.[0-9]+\.[0-9]+-${CHANNEL}\.")"
    if [ -n "$tag" ]; then
        printf '%s' "$tag"
        return
    fi

    # Fallback: legacy bare `v*` releases from before the OS-split.
    # These still ship the per-target tarballs we need (the artifact
    # filename is OS-agnostic, e.g. `cr-${version}-aarch64-macos.tar.gz`)
    # so the download path further down works either way.
    tag="$(pick_tag "v" "[0-9]+\.[0-9]+\.[0-9]+" "[0-9]+\.[0-9]+\.[0-9]+-${CHANNEL}\.")"
    if [ -n "$tag" ]; then
        echo "note: no ${prefix}* release found — falling back to legacy ${tag}" >&2
    fi
    printf '%s' "$tag"
}

main() {
    target="$(detect_target)"
    os="$(target_os "$target")"
    tag="$(resolve_tag "$target")"
    if [ -z "$tag" ]; then
        echo "could not resolve a release for os='${os}' channel='${CHANNEL}'" >&2
        exit 1
    fi
    # Strip whichever prefix the resolver returned to get the bare
    # semver used in artifact names. `${tag#cora-*-v}` removes the
    # SHORTEST `cora-*-v` prefix (not longest) so a prerelease
    # identifier containing `-v` later in the string — e.g.
    # `cora-macos-v1.0.0-vendor.1` — keeps the `vendor.1` suffix
    # intact.
    case "$tag" in
        cora-*-v*) version="${tag#cora-*-v}" ;;
        v*)        version="${tag#v}" ;;
        *)         echo "unrecognised tag shape: $tag" >&2; exit 1;;
    esac
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
