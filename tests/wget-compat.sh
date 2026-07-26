#!/bin/sh
set -eu
PATH='/usr/bin:/bin'
export PATH

CUSTOM_SCRIPT='deploy/cc-custom.sh'
SWITCH_SCRIPT='deploy/ccswitch.sh'
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wget-compat.XXXXXX")
cleanup_test_dir() {
    rm -f -- \
        "$TEST_DIR/version" \
        "$TEST_DIR/oversized" \
        "$TEST_DIR/cc-switch.AppImage" \
        "$TEST_DIR/wget.headers" \
        "$TEST_DIR/wget.locations"
    rmdir -- "$TEST_DIR" 2>/dev/null || true
}
trap cleanup_test_dir EXIT HUP INT TERM

GCS_BUCKET='https://storage.googleapis.com/test/claude-code-releases'
MAX_BINARY_BYTES=1073741824
DOWNLOAD_TIMEOUT=10
DOWNLOADER=wget

eval "$(sed -n '/^safe_gcs_url() {/,/^}/p' "$CUSTOM_SCRIPT")"
eval "$(sed -n '/^downloaded_file_within_limit() {/,/^}/p' "$CUSTOM_SCRIPT")"
eval "$(sed -n '/^download_file() {/,/^if \[ "\$TARGET"/p' "$CUSTOM_SCRIPT" | sed '$d')"

ulimit() { return 0; }
wget() {
    _fake_output=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --max-filesize*) return 64 ;;
            -O) _fake_output=$2; shift 2 ;;
            --output-document=*) _fake_output=${1#*=}; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$_fake_output" ] || return 65
    printf '2.1.220\n' > "$_fake_output"
}

CUSTOM_OUTPUT="$TEST_DIR/version"
download_file "$GCS_BUCKET/latest" "$CUSTOM_OUTPUT" true 128
[ "$(cat "$CUSTOM_OUTPUT")" = '2.1.220' ]
printf '%0129d' 0 > "$TEST_DIR/oversized"
if downloaded_file_within_limit "$TEST_DIR/oversized" 128; then
    exit 67
fi

TMP_DIR="$TEST_DIR"
MAX_REDIRECTS=5
eval "$(sed -n '/^file_size() {/,/^}/p' "$SWITCH_SCRIPT")"
eval "$(sed -n '/^within_size_limit() {/,/^}/p' "$SWITCH_SCRIPT")"
eval "$(sed -n '/^get_http_status() {/,/^}/p' "$SWITCH_SCRIPT")"
eval "$(sed -n '/^get_redirect_location() {/,/^}/p' "$SWITCH_SCRIPT")"
eval "$(sed -n '/^download_with_wget() {/,/^}/p' "$SWITCH_SCRIPT")"

is_allowed_transport_url() { return 0; }
wget() {
    _fake_output=''
    _fake_url=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --max-filesize*) return 64 ;;
            --output-document=*) _fake_output=${1#*=}; shift ;;
            https://*) _fake_url=$1; shift ;;
            *) shift ;;
        esac
    done
    case "$_fake_url" in
        https://github.com/*)
            printf '  HTTP/1.1 302 Found\r\n' >&2
            printf '  Location: https://release-assets.githubusercontent.com/github-production-release-asset/test\r\n' >&2
            printf 'Location: https://release-assets.githubusercontent.com/github-production-release-asset/test [following]\n' >&2
            return 8
            ;;
        https://release-assets.githubusercontent.com/*)
            printf '  HTTP/1.1 200 OK\r\n' >&2
            printf 'trusted-payload\n' > "$_fake_output"
            ;;
        *) return 66 ;;
    esac
}

SWITCH_OUTPUT="$TEST_DIR/cc-switch.AppImage"
download_with_wget 'https://github.com/example/release' "$SWITCH_OUTPUT" 128
[ "$(cat "$SWITCH_OUTPUT")" = 'trusted-payload' ]

printf '%s\n' 'wget compatibility simulation: OK'
