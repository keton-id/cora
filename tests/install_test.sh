#!/usr/bin/env sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin"

cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env sh
set -eu
url=""
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
if [ "$url" = "https://api.github.com/repos/keton-id/cora/releases/latest" ]; then
    printf '{"tag_name":"v1.2.3"}\n'
    exit 0
fi
printf '%s\n' "$url" >> "$CURL_LOG"
printf 'stub archive\n' > "$out"
MOCK

cat > "$tmp/bin/uname" <<'MOCK'
#!/usr/bin/env sh
case "$1" in
    -s) printf 'Darwin\n' ;;
    -m) printf 'arm64\n' ;;
    *) exit 1 ;;
esac
MOCK

cat > "$tmp/bin/tar" <<'MOCK'
#!/usr/bin/env sh
set -eu
[ "$1" = "-xzf" ]
[ "$3" = "-C" ]
printf '#!/usr/bin/env sh\nprintf "cr 1.2.3\\n"\n' > "$4/cr"
chmod +x "$4/cr"
MOCK

chmod +x "$tmp/bin/curl" "$tmp/bin/uname" "$tmp/bin/tar"
export PATH="$tmp/bin:/usr/bin:/bin"
export CURL_LOG="$tmp/curl.log"

"$repo/install.sh" --no-verify --bindir "$tmp/latest"
grep -qx 'https://github.com/keton-id/cora/releases/download/v1.2.3/cr-1.2.3-aarch64-macos.tar.gz' "$CURL_LOG"
"$tmp/latest/cr" version | grep -qx 'cr 1.2.3'

: > "$CURL_LOG"
"$repo/install.sh" --version 2.0.0 --no-verify --bindir "$tmp/pinned"
grep -qx 'https://github.com/keton-id/cora/releases/download/v2.0.0/cr-2.0.0-aarch64-macos.tar.gz' "$CURL_LOG"

if "$repo/install.sh" --channel alpha --no-verify --bindir "$tmp/alpha" >/dev/null 2>&1; then
    echo 'legacy prerelease channel unexpectedly accepted' >&2
    exit 1
fi

printf '%s\n' 'installer release-tag smoke passed'
