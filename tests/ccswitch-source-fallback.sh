#!/bin/sh

set -eu
PATH='/usr/bin:/bin'
export PATH

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SWITCH_SCRIPT="$ROOT_DIR/deploy/ccswitch.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ccswitch-fallback.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' 0 HUP INT TERM

eval "$(sed -n '/^download_from_sources() {/,/^}/p' "$SWITCH_SCRIPT")"

PINNED_URL='https://github.com/example/project/releases/download/v1/asset.AppImage'
PINNED_SIZE=16
PINNED_SHA256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
EXPECTED_MACHINE=3e00
MAX_ATTEMPTS=3
DEST="$TEST_DIR/CC-Switch.AppImage"
ATTEMPT_LOG="$TEST_DIR/attempts"
EXPECTED_LOG="$TEST_DIR/expected"

file_size() { printf '%s\n' "$PINNED_SIZE"; }
is_expected_elf() { return 0; }
sha256_file() { printf '%s\n' "$PINNED_SHA256"; }

download_file() {
    printf '%s\n' "$1" >> "$ATTEMPT_LOG"
    case "$1" in
        https://gh-proxy.com/*)
            : > "$2"
            return 0
            ;;
        *) return 1 ;;
    esac
}

download_from_sources > /dev/null 2> /dev/null
cat > "$EXPECTED_LOG" <<EOF
$PINNED_URL
https://gh-proxy.com/$PINNED_URL
EOF
cmp "$EXPECTED_LOG" "$ATTEMPT_LOG"

: > "$ATTEMPT_LOG"
download_file() {
    printf '%s\n' "$1" >> "$ATTEMPT_LOG"
    return 1
}
if download_from_sources > /dev/null 2> /dev/null; then
    exit 1
fi

: > "$EXPECTED_LOG"
ROUND=1
while [ "$ROUND" -le "$MAX_ATTEMPTS" ]; do
    printf '%s\n' \
        "$PINNED_URL" \
        "https://gh-proxy.com/$PINNED_URL" \
        "https://ghproxy.net/$PINNED_URL" \
        "https://ghfast.top/$PINNED_URL" >> "$EXPECTED_LOG"
    ROUND=$((ROUND + 1))
done
cmp "$EXPECTED_LOG" "$ATTEMPT_LOG"

printf '%s\n' 'CC Switch source fallback simulation: OK'
