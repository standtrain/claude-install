#!/bin/sh
set -eu

PATH='/usr/bin:/bin'
export PATH

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SWITCH_SCRIPT="$ROOT_DIR/deploy/ccswitch.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ccswitch-launcher.XXXXXX")

cleanup() {
    rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_not_contains() {
    _needle=$1
    _file=$2
    if grep -F -- "$_needle" "$_file" >/dev/null 2>&1; then
        fail "unexpected text in $_file: $_needle"
    fi
}

LAUNCHER_FUNCTION=$(
    sed -n '/^write_launcher() {/,/^LAUNCHER$/p' "$SWITCH_SCRIPT"
    printf '%s\n' '}'
)
[ -n "$LAUNCHER_FUNCTION" ] || fail 'write_launcher function is missing'
eval "$LAUNCHER_FUNCTION"

GENERATED_LAUNCHER="$TEST_DIR/cc-switch-launcher.generated"
write_launcher "$GENERATED_LAUNCHER"
chmod 755 "$GENERATED_LAUNCHER"
[ -f "$GENERATED_LAUNCHER" ] && [ -x "$GENERATED_LAUNCHER" ] \
    || fail 'write_launcher did not create an executable regular file'

# The launcher is an unprivileged GUI boundary. Never mutate application data
# or add unrelated Electron flags while recovering from a Tauri rendering bug.
assert_not_contains 'cc-switch.db' "$GENERATED_LAUNCHER"
assert_not_contains 'sqlite' "$GENERATED_LAUNCHER"
assert_not_contains '--no-sandbox' "$GENERATED_LAUNCHER"
assert_not_contains '--disable-gpu' "$GENERATED_LAUNCHER"
assert_not_contains 'LIBGL_ALWAYS_SOFTWARE' "$GENERATED_LAUNCHER"

grep -F 'id -u' "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher does not prohibit root execution'
grep -F 'CC_SWITCH_GDK_BACKEND' "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher does not validate the supported backend override'
grep -F 'CC_SWITCH_LINUX_COMPAT' "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher does not expose the compatibility opt-out'
grep -F 'VERSION_ID="?26([.][0-9]+)?"?' "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher compatibility is not scoped to Ubuntu 26'
grep -F 'VMware Virtual Platform' "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher compatibility is not scoped to VMware'
grep -F "HOST_WAYLAND_LIBRARY='/usr/lib/x86_64-linux-gnu/libwayland-client.so.0'" \
    "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher does not use the Ubuntu x86_64 Wayland library path'
grep -F 'readlink -f -- "$HOST_WAYLAND_LIBRARY"' "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher does not resolve the Wayland library target'
grep -F '/usr/lib/x86_64-linux-gnu/libwayland-client.so.*' \
    "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher does not constrain the resolved Wayland library path'
grep -F '[ -f "$_resolved_library" ] && [ ! -L "$_resolved_library" ]' \
    "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher does not require a resolved regular Wayland library'
grep -F '0$_library_mode & 022' "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher does not reject a writable preload library'
grep -F 'GIO_MODULE_DIR=$COMPAT_GIO_MODULE_DIR' "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher does not isolate incompatible GIO modules'
grep -F 'LD_PRELOAD=$_resolved_library' "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher does not preload the verified Wayland library'
grep -F 'exec "$APPIMAGE" "$@"' "$GENERATED_LAUNCHER" >/dev/null \
    || fail 'launcher does not preserve AppImage arguments and exit status'

grep -F 'Exec=$LAUNCHER_PATH' "$SWITCH_SCRIPT" >/dev/null \
    || fail 'desktop entry does not use the compatibility launcher'
grep -F 'TryExec=$LAUNCHER_PATH' "$SWITCH_SCRIPT" >/dev/null \
    || fail 'desktop entry TryExec does not use the compatibility launcher'
grep -F 'ln -s "$LAUNCHER_PATH"' "$SWITCH_SCRIPT" >/dev/null \
    || fail 'global command does not point to the compatibility launcher'

FAKE_APPIMAGE="$TEST_DIR/fake-cc-switch.AppImage"
cat > "$FAKE_APPIMAGE" <<'FAKE_APP'
#!/bin/sh
set -eu
printf '%s\n' invoked >> "$LAUNCHER_CALLS"
{
    printf 'backend=%s\n' "${CC_SWITCH_GDK_BACKEND-<unset>}"
    printf 'display=%s\n' "${DISPLAY-<unset>}"
    printf 'wayland=%s\n' "${WAYLAND_DISPLAY-<unset>}"
    printf 'preload=%s\n' "${LD_PRELOAD-<unset>}"
    printf 'gio_modules=%s\n' "${GIO_MODULE_DIR-<unset>}"
    printf 'gio_vfs=%s\n' "${GIO_USE_VFS-<unset>}"
    printf 'sentinel=%s\n' "${LAUNCHER_TEST_SENTINEL-<unset>}"
    printf 'argc=%s\n' "$#"
    for _argument do
        printf 'arg=%s\n' "$_argument"
    done
} > "$LAUNCHER_CAPTURE"
exit "${LAUNCHER_TEST_EXIT_CODE:-0}"
FAKE_APP
chmod 755 "$FAKE_APPIMAGE"

FAKE_GIO_DIR="$TEST_DIR/gio-modules"
FAKE_RELEASE="$TEST_DIR/os-release"
FAKE_PRODUCT="$TEST_DIR/product-name"
FAKE_WAYLAND_LIBRARY="$TEST_DIR/libwayland-client.so.0.test"
mkdir "$FAKE_GIO_DIR"
chmod 755 "$FAKE_GIO_DIR"
printf '%s\n' 'ID=ubuntu' 'VERSION_ID="26.04"' > "$FAKE_RELEASE"
printf '%s\n' 'VMware Virtual Platform' > "$FAKE_PRODUCT"

SYSTEM_WAYLAND_LIBRARY='/usr/lib/x86_64-linux-gnu/libwayland-client.so.0'
if [ -r "$SYSTEM_WAYLAND_LIBRARY" ]; then
    cp -- "$(readlink -f -- "$SYSTEM_WAYLAND_LIBRARY")" "$FAKE_WAYLAND_LIBRARY"
else
    : > "$FAKE_WAYLAND_LIBRARY"
fi
chmod 644 "$FAKE_WAYLAND_LIBRARY"

TEST_LAUNCHER="$TEST_DIR/cc-switch-launcher"
sed \
    -e "s|^APPIMAGE='/opt/cc-switch/cc-switch.AppImage'$|APPIMAGE='$FAKE_APPIMAGE'|" \
    -e "s|^COMPAT_GIO_MODULE_DIR='/opt/cc-switch/gio-modules'$|COMPAT_GIO_MODULE_DIR='$FAKE_GIO_DIR'|" \
    -e "s|^HOST_WAYLAND_LIBRARY='/usr/lib/x86_64-linux-gnu/libwayland-client.so.0'$|HOST_WAYLAND_LIBRARY='$FAKE_WAYLAND_LIBRARY'|" \
    -e "s|/usr/lib/x86_64-linux-gnu/libwayland-client.so\.\*|$TEST_DIR/libwayland-client.so.*|" \
    -e "s|/etc/os-release|$FAKE_RELEASE|g" \
    -e "s|/sys/class/dmi/id/product_name|$FAKE_PRODUCT|g" \
    "$GENERATED_LAUNCHER" > "$TEST_LAUNCHER"
chmod 755 "$TEST_LAUNCHER"
grep -F "APPIMAGE='$FAKE_APPIMAGE'" "$TEST_LAUNCHER" >/dev/null \
    || fail 'test could not replace the fixed AppImage path'

RUN_DIR="$TEST_DIR/run"
mkdir "$RUN_DIR"
CAPTURE="$RUN_DIR/capture"
CALLS="$RUN_DIR/calls"

if [ "$(id -u)" -eq 0 ]; then
    set +e
    "$GENERATED_LAUNCHER" >"$RUN_DIR/root.stdout" 2>"$RUN_DIR/root.stderr"
    ROOT_STATUS=$?
    set -e
    [ "$ROOT_STATUS" -ne 0 ] || fail 'launcher accepted root execution'
    grep -F '请使用普通桌面用户运行，不要使用 sudo' "$RUN_DIR/root.stderr" >/dev/null \
        || fail 'root execution did not fail at the explicit root guard'

    if [ "$(uname -m)" != x86_64 ] \
        || ! command -v runuser >/dev/null 2>&1 \
        || [ ! -r "$SYSTEM_WAYLAND_LIBRARY" ]; then
        printf '%s\n' 'CC Switch launcher compatibility (root guard only): OK'
        exit 0
    fi

    chmod 755 "$TEST_DIR"
    chmod 777 "$RUN_DIR"
    runuser -u nobody -- env \
        HOME="$RUN_DIR" \
        DISPLAY=:77 \
        WAYLAND_DISPLAY=wayland-test \
        XDG_SESSION_TYPE=wayland \
        CC_SWITCH_LINUX_COMPAT=auto \
        GIO_MODULE_DIR= \
        GIO_USE_VFS= \
        LD_PRELOAD= \
        LAUNCHER_CAPTURE="$CAPTURE" \
        LAUNCHER_CALLS="$CALLS" \
        LAUNCHER_TEST_SENTINEL='environment-passed' \
        "$TEST_LAUNCHER" '--label' 'two words'

    RESOLVED_FAKE_LIBRARY=$(readlink -f -- "$FAKE_WAYLAND_LIBRARY")
    grep -Fx 'backend=wayland' "$CAPTURE" >/dev/null || fail 'auto mode did not select Wayland'
    grep -Fx "preload=$RESOLVED_FAKE_LIBRARY" "$CAPTURE" >/dev/null \
        || fail 'auto mode did not preload the resolved Wayland library'
    grep -Fx "gio_modules=$FAKE_GIO_DIR" "$CAPTURE" >/dev/null \
        || fail 'auto mode did not isolate GIO modules'
    grep -Fx 'gio_vfs=local' "$CAPTURE" >/dev/null \
        || fail 'auto mode did not force the local GIO backend'
    grep -Fx 'sentinel=environment-passed' "$CAPTURE" >/dev/null \
        || fail 'auto mode dropped an unrelated environment variable'
    grep -Fx 'argc=2' "$CAPTURE" >/dev/null || fail 'auto mode changed the argument count'
    grep -Fx 'arg=two words' "$CAPTURE" >/dev/null || fail 'auto mode changed a spaced argument'

    rm -f -- "$CAPTURE" "$CALLS"
    chmod 777 "$FAKE_GIO_DIR"
    set +e
    runuser -u nobody -- env \
        HOME="$RUN_DIR" DISPLAY=:77 WAYLAND_DISPLAY=wayland-test XDG_SESSION_TYPE=wayland \
        CC_SWITCH_LINUX_COMPAT=auto LAUNCHER_CAPTURE="$CAPTURE" LAUNCHER_CALLS="$CALLS" \
        "$TEST_LAUNCHER" >"$RUN_DIR/insecure.stdout" 2>"$RUN_DIR/insecure.stderr"
    INSECURE_STATUS=$?
    set -e
    [ "$INSECURE_STATUS" -ne 0 ] || fail 'launcher accepted a writable GIO module directory'
    [ ! -e "$CALLS" ] || fail 'AppImage ran after compatibility permission validation failed'
    grep -F '兼容模块目录可被非 root 用户写入' "$RUN_DIR/insecure.stderr" >/dev/null \
        || fail 'writable GIO module directory did not produce the expected error'
    chmod 755 "$FAKE_GIO_DIR"

    printf '%s\n' 'CC Switch launcher compatibility: OK'
    exit 0
fi

LAUNCHER_CAPTURE="$CAPTURE" \
LAUNCHER_CALLS="$CALLS" \
LAUNCHER_TEST_SENTINEL='environment-passed' \
CC_SWITCH_LINUX_COMPAT=off \
CC_SWITCH_GDK_BACKEND=wayland \
DISPLAY=:77 \
WAYLAND_DISPLAY=wayland-test \
XDG_RUNTIME_DIR="$TEST_DIR/runtime" \
    "$TEST_LAUNCHER" '--label' 'two words'

grep -Fx 'backend=wayland' "$CAPTURE" >/dev/null || fail 'backend override was not passed'
grep -Fx 'display=:77' "$CAPTURE" >/dev/null || fail 'DISPLAY was not passed'
grep -Fx 'wayland=wayland-test' "$CAPTURE" >/dev/null || fail 'WAYLAND_DISPLAY was not passed'
grep -Fx 'preload=<unset>' "$CAPTURE" >/dev/null || fail 'compatibility opt-out injected LD_PRELOAD'
grep -Fx 'gio_modules=<unset>' "$CAPTURE" >/dev/null || fail 'compatibility opt-out changed GIO_MODULE_DIR'
grep -Fx 'gio_vfs=<unset>' "$CAPTURE" >/dev/null || fail 'compatibility opt-out changed GIO_USE_VFS'
grep -Fx 'sentinel=environment-passed' "$CAPTURE" >/dev/null \
    || fail 'ordinary environment variable was not passed'
grep -Fx 'argc=2' "$CAPTURE" >/dev/null || fail 'argument count changed'
grep -Fx 'arg=--label' "$CAPTURE" >/dev/null || fail 'first argument changed'
grep -Fx 'arg=two words' "$CAPTURE" >/dev/null || fail 'spaced argument changed'
[ "$(wc -l < "$CALLS" | tr -d '[:space:]')" -eq 1 ] \
    || fail 'launcher invoked the AppImage more than once'

# Leaving the official backend override unset must preserve upstream behavior.
rm -f -- "$CAPTURE" "$CALLS"
(
    unset CC_SWITCH_GDK_BACKEND XDG_SESSION_TYPE WAYLAND_DISPLAY
    DISPLAY=:77 \
    CC_SWITCH_LINUX_COMPAT=off \
    LAUNCHER_CAPTURE="$CAPTURE" \
    LAUNCHER_CALLS="$CALLS" \
        "$TEST_LAUNCHER"
)
grep -Fx 'backend=<unset>' "$CAPTURE" >/dev/null \
    || fail 'launcher changed the default upstream graphics backend'

SENSITIVE_MARKER='launcher-sensitive-value-123456'
ERROR_HOME="$TEST_DIR/error-home"
mkdir -p "$ERROR_HOME"
rm -f -- "$CAPTURE" "$CALLS"
set +e
HOME="$ERROR_HOME" \
XDG_STATE_HOME="$ERROR_HOME/.local/state" \
DISPLAY= WAYLAND_DISPLAY= \
CC_SWITCH_LINUX_COMPAT=off \
CC_SWITCH_GDK_BACKEND="invalid-$SENSITIVE_MARKER" \
ANTHROPIC_API_KEY="$SENSITIVE_MARKER" \
LAUNCHER_CAPTURE="$CAPTURE" \
LAUNCHER_CALLS="$CALLS" \
    "$TEST_LAUNCHER" "ccswitch://import?token=$SENSITIVE_MARKER" \
    >"$TEST_DIR/invalid.stdout" 2>"$TEST_DIR/invalid.stderr"
INVALID_STATUS=$?
set -e
[ "$INVALID_STATUS" -ne 0 ] || fail 'invalid backend was accepted'
[ ! -e "$CAPTURE" ] || fail 'AppImage ran after preflight validation failed'
assert_not_contains "$SENSITIVE_MARKER" "$TEST_DIR/invalid.stdout"
assert_not_contains "$SENSITIVE_MARKER" "$TEST_DIR/invalid.stderr"
if grep -R -F -- "$SENSITIVE_MARKER" "$ERROR_HOME" >/dev/null 2>&1; then
    fail 'launcher persisted a sensitive environment value in diagnostics'
fi

TEST_HOME="$TEST_DIR/home"
mkdir -p "$TEST_HOME/.cc-switch"
printf '%s\n' 'database-schema-and-user-data-sentinel' > "$TEST_HOME/.cc-switch/cc-switch.db"
cp -- "$TEST_HOME/.cc-switch/cc-switch.db" "$TEST_DIR/database.before"

set +e
HOME="$TEST_HOME" \
DISPLAY=:77 \
CC_SWITCH_LINUX_COMPAT=off \
CC_SWITCH_GDK_BACKEND=x11 \
LAUNCHER_CAPTURE="$CAPTURE" \
LAUNCHER_CALLS="$CALLS" \
LAUNCHER_TEST_EXIT_CODE=73 \
    "$TEST_LAUNCHER" >"$TEST_DIR/app.stdout" 2>"$TEST_DIR/app.stderr"
APP_STATUS=$?
set -e
[ "$APP_STATUS" -eq 73 ] || fail 'launcher did not preserve AppImage exit status'
cmp "$TEST_DIR/database.before" "$TEST_HOME/.cc-switch/cc-switch.db" >/dev/null \
    || fail 'launcher modified the application database after a launch failure'
[ "$(wc -l < "$CALLS" | tr -d '[:space:]')" -eq 1 ] \
    || fail 'launcher automatically retried the failed AppImage'

printf '%s\n' 'CC Switch launcher compatibility: OK'
