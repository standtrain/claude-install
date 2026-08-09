#!/bin/sh
# CC Switch Linux installer. Downloads a pinned release with curl or wget.

set -eu
umask 077
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

INSTALL_DIR="/opt/cc-switch"
APPIMAGE_PATH="$INSTALL_DIR/cc-switch.AppImage"
LAUNCHER_PATH="$INSTALL_DIR/cc-switch-launcher"
GIO_MODULE_DIR_PATH="$INSTALL_DIR/gio-modules"
BIN_DIR="/usr/local/bin"
BIN_LINK="$BIN_DIR/cc-switch"
DESKTOP_DIR="/usr/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/cc-switch.desktop"

PINNED_VERSION="v3.18.0"
PINNED_X86_64_URL="https://github.com/farion1231/cc-switch/releases/download/v3.18.0/CC-Switch-v3.18.0-Linux-x86_64.AppImage"
PINNED_X86_64_SHA256="ba1a4009eec156ecb6b2a7b6ce638bc56682953e32a58211a3f08f37edec9634"
PINNED_X86_64_SIZE=91621880
PINNED_ARM64_URL="https://github.com/farion1231/cc-switch/releases/download/v3.18.0/CC-Switch-v3.18.0-Linux-arm64.AppImage"
PINNED_ARM64_SHA256="dd8bec9d99233ce9250b79ed1bd6b0420dcbe0b8157e8a01447a324602b957ec"
PINNED_ARM64_SIZE=89229832

DOWNLOAD_TIMEOUT=300
MAX_APPIMAGE_BYTES=104857600
MAX_REDIRECTS=5
MAX_ATTEMPTS=3

TMP_DIR=""
STAGED_APPIMAGE=""
STAGED_LAUNCHER=""
LINK_STAGE_DIR=""
STAGED_DESKTOP=""

cleanup() {
    if [ -n "$STAGED_APPIMAGE" ]; then
        case "$STAGED_APPIMAGE" in
            "$INSTALL_DIR"/.cc-switch.AppImage.*) rm -f -- "$STAGED_APPIMAGE" ;;
        esac
    fi
    if [ -n "$STAGED_LAUNCHER" ]; then
        case "$STAGED_LAUNCHER" in
            "$INSTALL_DIR"/.cc-switch-launcher.*) rm -f -- "$STAGED_LAUNCHER" ;;
        esac
    fi
    if [ -n "$LINK_STAGE_DIR" ]; then
        case "$LINK_STAGE_DIR" in
            "$BIN_DIR"/.cc-switch-link.*)
                rm -f -- "$LINK_STAGE_DIR/cc-switch"
                rmdir -- "$LINK_STAGE_DIR" 2>/dev/null || true
                ;;
        esac
    fi
    if [ -n "$STAGED_DESKTOP" ]; then
        case "$STAGED_DESKTOP" in
            "$DESKTOP_DIR"/.cc-switch.desktop.*) rm -f -- "$STAGED_DESKTOP" ;;
        esac
    fi
    if [ -n "$TMP_DIR" ]; then
        case "$TMP_DIR" in
            /tmp/ccswitch.*) rm -rf -- "$TMP_DIR" ;;
        esac
    fi
}

trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    printf '[ERROR] %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少必要命令: $1"
}

valid_sha256() {
    [ "${#1}" -eq 64 ] && ! printf '%s' "$1" | grep -Eq '[^a-f0-9]'
}

valid_size() {
    printf '%s\n' "$1" | grep -Eq '^[0-9]{7,9}$' \
        && [ "$1" -ge 10485760 ] \
        && [ "$1" -le "$MAX_APPIMAGE_BYTES" ]
}

# Only exact pinned release paths and GitHub's release-asset endpoint are valid.
# Proxy hosts remain transport fallbacks; the pinned digest authenticates data.
is_allowed_transport_url() {
    _url="$1"
    [ "${#_url}" -le 4096 ] || return 1
    if printf '%s' "$_url" | LC_ALL=C grep -Eq '[[:cntrl:][:space:]]'; then
        return 1
    fi
    case "$_url" in
        https://*) ;;
        *) return 1 ;;
    esac

    _url_rest=${_url#https://}
    _authority=${_url_rest%%/*}
    [ "$_url_rest" != "$_authority" ] || return 1
    _path=/${_url_rest#*/}

    case "$_authority" in
        github.com)
            [ "$_url" = "$PINNED_X86_64_URL" ] || [ "$_url" = "$PINNED_ARM64_URL" ]
            ;;
        release-assets.githubusercontent.com)
            case "$_path" in
                /github-production-release-asset/*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        gh-proxy.com)
            [ "$_url" = "https://gh-proxy.com/$PINNED_X86_64_URL" ] \
                || [ "$_url" = "https://gh-proxy.com/$PINNED_ARM64_URL" ]
            ;;
        ghproxy.net)
            [ "$_url" = "https://ghproxy.net/$PINNED_X86_64_URL" ] \
                || [ "$_url" = "https://ghproxy.net/$PINNED_ARM64_URL" ]
            ;;
        ghfast.top)
            [ "$_url" = "https://ghfast.top/$PINNED_X86_64_URL" ] \
                || [ "$_url" = "https://ghfast.top/$PINNED_ARM64_URL" ]
            ;;
        *) return 1 ;;
    esac
}

file_size() {
    wc -c < "$1" | tr -d '[:space:]'
}

within_size_limit() {
    _size=$(file_size "$1") || return 1
    printf '%s\n' "$_size" | grep -Eq '^[0-9]+$' || return 1
    [ "$_size" -le "$2" ]
}

download_with_curl() {
    _url="$1"
    _output="$2"
    _max_bytes="$3"
    _effective_file="$TMP_DIR/curl.effective"
    _file_blocks=$(((_max_bytes + 511) / 512))

    rm -f -- "$_output" "$_effective_file"
    if ! (
        ulimit -c 0 || exit 1
        ulimit -f "$_file_blocks" || exit 1
        curl --fail --location --show-error --progress-bar \
            --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time "$DOWNLOAD_TIMEOUT" \
            --max-redirs "$MAX_REDIRECTS" --max-filesize "$_max_bytes" \
            --output "$_output" --write-out '%{url_effective}\n' "$_url"
    ) > "$_effective_file"; then
        rm -f -- "$_output" "$_effective_file"
        return 1
    fi

    [ "$(wc -l < "$_effective_file" | tr -d '[:space:]')" -eq 1 ] || {
        rm -f -- "$_output" "$_effective_file"
        return 1
    }
    IFS= read -r _effective_url < "$_effective_file" || {
        rm -f -- "$_output" "$_effective_file"
        return 1
    }
    rm -f -- "$_effective_file"
    is_allowed_transport_url "$_effective_url" || {
        rm -f -- "$_output"
        return 1
    }
    [ -f "$_output" ] && [ ! -L "$_output" ] && within_size_limit "$_output" "$_max_bytes"
}

get_http_status() {
    awk '
        /^[[:space:]]*HTTP\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]/ { status = $2 }
        END { if (status != "") print status }
    ' "$1"
}

get_redirect_location() {
    _headers="$1"
    _locations="$TMP_DIR/wget.locations"
    awk '
        {
            line = $0
            sub(/\r$/, "", line)
            if (line !~ /^[[:space:]]*[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:/) next
            sub(/^[[:space:]]*[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*/, "", line)
            sub(/[[:space:]]+\[[Ff][Oo][Ll][Ll][Oo][Ww][Ii][Nn][Gg]\][[:space:]]*$/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line != "" && !seen[line]++) {
                location = line
                count++
            }
        }
        END {
            if (count == 1) print location
            else exit 1
        }
    ' "$_headers" > "$_locations" || return 1
    IFS= read -r REDIRECT_LOCATION < "$_locations" || return 1
    [ -n "$REDIRECT_LOCATION" ]
}

# wget never follows redirects itself. Every Location is checked first.
download_with_wget() {
    _url="$1"
    _output="$2"
    _max_bytes="$3"
    _headers="$TMP_DIR/wget.headers"
    _file_blocks=$(((_max_bytes + 511) / 512))
    _redirects=0

    while :; do
        is_allowed_transport_url "$_url" || {
            rm -f -- "$_output" "$_headers"
            return 1
        }
        rm -f -- "$_output" "$_headers"
        _wget_ok=false
        if (
            ulimit -c 0 || exit 1
            ulimit -f "$_file_blocks" || exit 1
            wget --https-only --server-response --max-redirect=0 \
                --connect-timeout=15 --read-timeout="$DOWNLOAD_TIMEOUT" \
                --tries=1 --output-document="$_output" "$_url"
        ) > /dev/null 2> "$_headers"; then
            _wget_ok=true
        fi

        _status=$(get_http_status "$_headers")
        case "$_status" in
            200)
                [ "$_wget_ok" = true ] || {
                    rm -f -- "$_output" "$_headers"
                    return 1
                }
                rm -f -- "$_headers"
                [ -f "$_output" ] && [ ! -L "$_output" ] \
                    && within_size_limit "$_output" "$_max_bytes"
                return
                ;;
            301|302|303|307|308)
                [ "$_redirects" -lt "$MAX_REDIRECTS" ] || {
                    rm -f -- "$_output" "$_headers"
                    return 1
                }
                REDIRECT_LOCATION=""
                get_redirect_location "$_headers" || {
                    rm -f -- "$_output" "$_headers"
                    return 1
                }
                is_allowed_transport_url "$REDIRECT_LOCATION" || {
                    rm -f -- "$_output" "$_headers"
                    return 1
                }
                _url=$REDIRECT_LOCATION
                _redirects=$((_redirects + 1))
                ;;
            *)
                rm -f -- "$_output" "$_headers"
                return 1
                ;;
        esac
    done
}

download_file() {
    _url="$1"
    _output="$2"
    _max_bytes="$3"

    is_allowed_transport_url "$_url" || return 1
    valid_size "$_max_bytes" || return 1

    if [ "$DOWNLOADER" = curl ]; then
        if download_with_curl "$_url" "$_output" "$_max_bytes"; then
            return 0
        fi
    elif download_with_wget "$_url" "$_output" "$_max_bytes"; then
        return 0
    fi
    rm -f -- "$_output"
    return 1
}

download_from_sources() {
    DOWNLOADED=false
    DOWNLOAD_ROUND=1
    while [ "$DOWNLOAD_ROUND" -le "$MAX_ATTEMPTS" ] && [ "$DOWNLOADED" = false ]; do
        SOURCE_INDEX=0
        for SOURCE_URL in \
            "$PINNED_URL" \
            "https://gh-proxy.com/$PINNED_URL" \
            "https://ghproxy.net/$PINNED_URL" \
            "https://ghfast.top/$PINNED_URL"
        do
            SOURCE_INDEX=$((SOURCE_INDEX + 1))
            printf '[INFO] 尝试固定版本下载源 %s/4（第 %s/%s 轮）\n' \
                "$SOURCE_INDEX" "$DOWNLOAD_ROUND" "$MAX_ATTEMPTS"
            if ! download_file "$SOURCE_URL" "$DEST" "$PINNED_SIZE"; then
                printf '[WARN] 下载失败，尝试下一个下载源\n' >&2
                continue
            fi

            ACTUAL_SIZE=$(file_size "$DEST") || fail "无法读取下载文件大小"
            if [ "$ACTUAL_SIZE" -ne "$PINNED_SIZE" ]; then
                printf '[WARN] 文件大小校验失败，尝试下一个下载源\n' >&2
                rm -f -- "$DEST"
                continue
            fi
            if ! is_expected_elf "$DEST" "$EXPECTED_MACHINE"; then
                printf '[WARN] ELF 文件类型或架构校验失败，尝试下一个下载源\n' >&2
                rm -f -- "$DEST"
                continue
            fi
            ACTUAL_SHA256=$(sha256_file "$DEST") || fail "无法计算下载文件 SHA256"
            if [ "$ACTUAL_SHA256" != "$PINNED_SHA256" ]; then
                printf '[WARN] SHA256 校验失败，尝试下一个下载源\n' >&2
                rm -f -- "$DEST"
                continue
            fi
            DOWNLOADED=true
            break
        done
        DOWNLOAD_ROUND=$((DOWNLOAD_ROUND + 1))
    done

    [ "$DOWNLOADED" = true ] && [ -f "$DEST" ]
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

is_expected_elf() {
    _file="$1"
    _expected_machine="$2"
    _magic=$(od -An -tx1 -N4 "$_file" 2>/dev/null | tr -d '[:space:]')
    _class_data=$(od -An -tx1 -j4 -N2 "$_file" 2>/dev/null | tr -d '[:space:]')
    _machine=$(od -An -tx1 -j18 -N2 "$_file" 2>/dev/null | tr -d '[:space:]')
    [ "$_magic" = 7f454c46 ] \
        && [ "$_class_data" = 0201 ] \
        && [ "$_machine" = "$_expected_machine" ]
}

ensure_secure_parent() {
    _directory="$1"
    [ -d "$_directory" ] && [ ! -L "$_directory" ] || return 1
    _owner=$(stat -c '%u' -- "$_directory") || return 1
    _mode=$(stat -c '%a' -- "$_directory") || return 1
    [ "$_owner" -eq 0 ] || return 1
    printf '%s\n' "$_mode" | grep -Eq '^[0-7]{3,4}$' || return 1
    [ $((0$_mode & 022)) -eq 0 ]
}

ensure_system_directory() {
    _directory="$1"
    if [ -L "$_directory" ]; then
        return 1
    fi
    if [ ! -e "$_directory" ]; then
        _parent=${_directory%/*}
        ensure_secure_parent "$_parent" || return 1
        mkdir -- "$_directory" || return 1
        chown root:root "$_directory" || return 1
        chmod 755 "$_directory" || return 1
    fi
    ensure_secure_parent "$_directory"
}

write_launcher() {
    _launcher_output=$1
    cat > "$_launcher_output" <<'LAUNCHER'
#!/bin/sh
set -eu

PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

APPIMAGE='/opt/cc-switch/cc-switch.AppImage'
COMPAT_GIO_MODULE_DIR='/opt/cc-switch/gio-modules'
HOST_WAYLAND_LIBRARY='/usr/lib/x86_64-linux-gnu/libwayland-client.so.0'

launcher_fail() {
    printf '[ERROR] CC Switch 启动失败: %s\n' "$1" >&2
    exit 1
}

[ "$(id -u)" -ne 0 ] || launcher_fail '请使用普通桌面用户运行，不要使用 sudo'
[ -f "$APPIMAGE" ] && [ ! -L "$APPIMAGE" ] && [ -x "$APPIMAGE" ] \
    || launcher_fail '应用文件缺失或权限异常，请重新运行安装器'

case "${CC_SWITCH_GDK_BACKEND:-}" in
    ''|x11|wayland) ;;
    *) launcher_fail 'CC_SWITCH_GDK_BACKEND 仅支持 x11 或 wayland' ;;
esac

case "${CC_SWITCH_LINUX_COMPAT:-auto}" in
    auto|off|force) ;;
    *) launcher_fail 'CC_SWITCH_LINUX_COMPAT 仅支持 auto、off 或 force' ;;
esac

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    launcher_fail '未检测到图形桌面会话'
fi

# v3.18.0 AppImage bundles libraries that conflict with Ubuntu 26's
# GIO/Wayland stack under VMware. Keep the workaround narrowly scoped.
_enable_compat=false
if [ "${CC_SWITCH_LINUX_COMPAT:-auto}" = force ]; then
    [ "$(uname -m)" = x86_64 ] \
        || launcher_fail '强制兼容模式目前仅支持 x86_64'
    _enable_compat=true
elif [ "${CC_SWITCH_LINUX_COMPAT:-auto}" = auto ] \
    && [ "$(uname -m)" = x86_64 ] \
    && [ "${XDG_SESSION_TYPE:-}" = wayland ] \
    && [ -n "${WAYLAND_DISPLAY:-}" ] \
    && [ -r /etc/os-release ] \
    && grep -Eq '^ID="?ubuntu"?$' /etc/os-release \
    && grep -Eq '^VERSION_ID="?26([.][0-9]+)?"?$' /etc/os-release \
    && [ -r /sys/class/dmi/id/product_name ] \
    && grep -Eiq '^VMware Virtual Platform[[:space:]]*$' /sys/class/dmi/id/product_name; then
    _enable_compat=true
fi

if [ "$_enable_compat" = true ]; then
    [ -d "$COMPAT_GIO_MODULE_DIR" ] && [ ! -L "$COMPAT_GIO_MODULE_DIR" ] \
        || launcher_fail '兼容模块目录缺失或权限异常，请重新运行安装器'
    _gio_owner=$(stat -c '%u' -- "$COMPAT_GIO_MODULE_DIR" 2>/dev/null) \
        || launcher_fail '无法读取兼容模块目录所有者'
    _gio_mode=$(stat -c '%a' -- "$COMPAT_GIO_MODULE_DIR" 2>/dev/null) \
        || launcher_fail '无法读取兼容模块目录权限'
    [ "$_gio_owner" -eq 0 ] 2>/dev/null \
        || launcher_fail '兼容模块目录不属于 root，拒绝使用'
    printf '%s\n' "$_gio_mode" | grep -Eq '^[0-7]{3,4}$' \
        || launcher_fail '兼容模块目录权限格式异常'
    [ $((0$_gio_mode & 022)) -eq 0 ] \
        || launcher_fail '兼容模块目录可被非 root 用户写入，拒绝使用'

    if [ -z "${CC_SWITCH_GDK_BACKEND:-}" ]; then
        CC_SWITCH_GDK_BACKEND=wayland
        export CC_SWITCH_GDK_BACKEND
    fi

    # Compat=off is the explicit opt-out, so inherited empty or conflicting
    # GIO values must not silently disable the workaround.
    GIO_MODULE_DIR=$COMPAT_GIO_MODULE_DIR
    GIO_USE_VFS=local
    export GIO_MODULE_DIR GIO_USE_VFS

    if [ "$CC_SWITCH_GDK_BACKEND" = wayland ]; then
        _resolved_library=$(readlink -f -- "$HOST_WAYLAND_LIBRARY" 2>/dev/null) \
            || launcher_fail '宿主 Wayland 库不存在，无法安全启用兼容模式'
        case "$_resolved_library" in
            /usr/lib/x86_64-linux-gnu/libwayland-client.so.*) ;;
            *) launcher_fail '宿主 Wayland 库解析到非预期路径，拒绝预加载' ;;
        esac
        [ -f "$_resolved_library" ] && [ ! -L "$_resolved_library" ] \
            || launcher_fail '宿主 Wayland 库目标不是普通文件，拒绝预加载'

        _library_directory=${_resolved_library%/*}
        _library_directory_owner=$(stat -c '%u' -- "$_library_directory" 2>/dev/null) \
            || launcher_fail '无法读取宿主 Wayland 库目录所有者'
        _library_directory_mode=$(stat -c '%a' -- "$_library_directory" 2>/dev/null) \
            || launcher_fail '无法读取宿主 Wayland 库目录权限'
        [ "$_library_directory_owner" -eq 0 ] 2>/dev/null \
            || launcher_fail '宿主 Wayland 库目录不属于 root，拒绝预加载'
        printf '%s\n' "$_library_directory_mode" | grep -Eq '^[0-7]{3,4}$' \
            || launcher_fail '宿主 Wayland 库目录权限格式异常'
        [ $((0$_library_directory_mode & 022)) -eq 0 ] \
            || launcher_fail '宿主 Wayland 库目录可被非 root 用户写入，拒绝预加载'

        _library_owner=$(stat -c '%u' -- "$_resolved_library" 2>/dev/null) \
            || launcher_fail '无法读取宿主 Wayland 库所有者'
        _library_mode=$(stat -c '%a' -- "$_resolved_library" 2>/dev/null) \
            || launcher_fail '无法读取宿主 Wayland 库权限'
        [ "$_library_owner" -eq 0 ] 2>/dev/null \
            || launcher_fail '宿主 Wayland 库不属于 root，拒绝预加载'
        printf '%s\n' "$_library_mode" | grep -Eq '^[0-7]{3,4}$' \
            || launcher_fail '宿主 Wayland 库权限格式异常'
        [ $((0$_library_mode & 022)) -eq 0 ] \
            || launcher_fail '宿主 Wayland 库可被非 root 用户写入，拒绝预加载'

        LD_PRELOAD=$_resolved_library
        export LD_PRELOAD
    fi
fi

exec "$APPIMAGE" "$@"
LAUNCHER
}

if [ "$(id -u)" -ne 0 ]; then
    fail "本脚本需要 root 权限。无 curl 时可使用: wget -qO- https://claude.fernweh.top/ccswitch.sh | sudo sh"
fi

for _command in awk chmod chown cp grep id ln mkdir mktemp mv od readlink rm rmdir sed stat tr uname wc; do
    require_command "$_command"
done

if command -v sha256sum >/dev/null 2>&1; then
    :
elif command -v shasum >/dev/null 2>&1; then
    :
else
    fail "缺少 sha256sum 或 shasum，无法验证安装包"
fi

if command -v curl >/dev/null 2>&1; then
    DOWNLOADER=curl
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER=wget
else
    fail "系统中既没有 curl，也没有 wget。请先通过系统包管理器安装其中一个"
fi

case "$(uname -m)" in
    x86_64|amd64)
        ARCH=x86_64
        EXPECTED_MACHINE=3e00
        PINNED_URL=$PINNED_X86_64_URL
        PINNED_SHA256=$PINNED_X86_64_SHA256
        PINNED_SIZE=$PINNED_X86_64_SIZE
        ;;
    arm64|aarch64)
        ARCH=arm64
        EXPECTED_MACHINE=b700
        PINNED_URL=$PINNED_ARM64_URL
        PINNED_SHA256=$PINNED_ARM64_SHA256
        PINNED_SIZE=$PINNED_ARM64_SIZE
        ;;
    *) fail "不支持的架构: $(uname -m)" ;;
esac

valid_sha256 "$PINNED_SHA256" || fail "内置 SHA256 元数据无效"
valid_size "$PINNED_SIZE" || fail "内置文件大小元数据无效"
is_allowed_transport_url "$PINNED_URL" || fail "内置下载地址无效"

TMP_DIR=$(mktemp -d /tmp/ccswitch.XXXXXX) || fail "无法创建私有临时目录"
chown root:root "$TMP_DIR"
chmod 700 "$TMP_DIR"
DEST="$TMP_DIR/CC-Switch.AppImage"

printf '[INFO] CC Switch Linux 安装器，版本: %s，架构: %s，下载器: %s\n' \
    "$PINNED_VERSION" "$ARCH" "$DOWNLOADER"

download_from_sources \
    || fail "所有固定版本下载源均失败，现有安装未被修改"

if [ -e "$BIN_LINK" ] && [ ! -L "$BIN_LINK" ]; then
    fail "$BIN_LINK 已存在且不是符号链接，拒绝覆盖"
fi
if [ -L "$DESKTOP_FILE" ] || { [ -e "$DESKTOP_FILE" ] && [ ! -f "$DESKTOP_FILE" ]; }; then
    fail "$DESKTOP_FILE 必须是普通文件，拒绝覆盖"
fi
if [ -L "$APPIMAGE_PATH" ] || { [ -e "$APPIMAGE_PATH" ] && [ ! -f "$APPIMAGE_PATH" ]; }; then
    fail "$APPIMAGE_PATH 必须是普通文件，拒绝覆盖"
fi
if [ -L "$LAUNCHER_PATH" ] || { [ -e "$LAUNCHER_PATH" ] && [ ! -f "$LAUNCHER_PATH" ]; }; then
    fail "$LAUNCHER_PATH 必须是普通文件，拒绝覆盖"
fi

ensure_system_directory "$BIN_DIR" || fail "$BIN_DIR 必须是 root 所有且不可由组或其他用户写入的普通目录"
ensure_system_directory "$DESKTOP_DIR" || fail "$DESKTOP_DIR 必须是 root 所有且不可由组或其他用户写入的普通目录"

if [ -L "$INSTALL_DIR" ] || { [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; }; then
    fail "$INSTALL_DIR 必须是普通目录，拒绝安装"
fi
if [ ! -e "$INSTALL_DIR" ]; then
    ensure_secure_parent "${INSTALL_DIR%/*}" || fail "安装目录的父目录不安全"
    mkdir -- "$INSTALL_DIR"
fi
chown root:root "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"
ensure_secure_parent "$INSTALL_DIR" || fail "无法加固安装目录权限"
ensure_system_directory "$GIO_MODULE_DIR_PATH" \
    || fail "$GIO_MODULE_DIR_PATH 必须是 root 所有且不可由组或其他用户写入的普通目录"
chown root:root "$GIO_MODULE_DIR_PATH"
chmod 755 "$GIO_MODULE_DIR_PATH"

# Prepare every artifact before publishing. Each rename stays on one filesystem.
STAGED_APPIMAGE=$(mktemp "$INSTALL_DIR/.cc-switch.AppImage.XXXXXX") \
    || fail "无法创建 AppImage 暂存文件"
cp -- "$DEST" "$STAGED_APPIMAGE"
chown root:root "$STAGED_APPIMAGE"
chmod 755 "$STAGED_APPIMAGE"

STAGED_LAUNCHER=$(mktemp "$INSTALL_DIR/.cc-switch-launcher.XXXXXX") \
    || fail "无法创建启动器暂存文件"
write_launcher "$STAGED_LAUNCHER"
chown root:root "$STAGED_LAUNCHER"
chmod 755 "$STAGED_LAUNCHER"

LINK_STAGE_DIR=$(mktemp -d "$BIN_DIR/.cc-switch-link.XXXXXX") \
    || fail "无法创建命令链接暂存目录"
chown root:root "$LINK_STAGE_DIR"
chmod 700 "$LINK_STAGE_DIR"
ln -s "$LAUNCHER_PATH" "$LINK_STAGE_DIR/cc-switch"
chown -h root:root "$LINK_STAGE_DIR/cc-switch"

STAGED_DESKTOP=$(mktemp "$DESKTOP_DIR/.cc-switch.desktop.XXXXXX") \
    || fail "无法创建桌面入口暂存文件"
cat > "$STAGED_DESKTOP" <<DESKTOP
[Desktop Entry]
Name=CC Switch
Comment=Claude Code / Codex / Gemini CLI provider manager
Exec=$LAUNCHER_PATH
TryExec=$LAUNCHER_PATH
Type=Application
Categories=Development;
Terminal=false
DESKTOP
chown root:root "$STAGED_DESKTOP"
chmod 644 "$STAGED_DESKTOP"

printf '[INFO] 校验通过，正在发布 CC Switch %s\n' "$PINNED_VERSION"
mv -fT -- "$STAGED_APPIMAGE" "$APPIMAGE_PATH"
STAGED_APPIMAGE=""
mv -fT -- "$STAGED_LAUNCHER" "$LAUNCHER_PATH"
STAGED_LAUNCHER=""
mv -fT -- "$STAGED_DESKTOP" "$DESKTOP_FILE"
STAGED_DESKTOP=""
mv -fT -- "$LINK_STAGE_DIR/cc-switch" "$BIN_LINK"
rmdir -- "$LINK_STAGE_DIR"
LINK_STAGE_DIR=""

[ -f "$APPIMAGE_PATH" ] && [ ! -L "$APPIMAGE_PATH" ] \
    && [ "$(stat -c '%u:%g:%a' -- "$APPIMAGE_PATH")" = '0:0:755' ] \
    || fail "AppImage 最终权限校验失败"
[ -f "$LAUNCHER_PATH" ] && [ ! -L "$LAUNCHER_PATH" ] \
    && [ "$(stat -c '%u:%g:%a' -- "$LAUNCHER_PATH")" = '0:0:755' ] \
    || fail "启动器最终权限校验失败"
[ -d "$GIO_MODULE_DIR_PATH" ] && [ ! -L "$GIO_MODULE_DIR_PATH" ] \
    && [ "$(stat -c '%u:%g:%a' -- "$GIO_MODULE_DIR_PATH")" = '0:0:755' ] \
    || fail "兼容模块目录最终权限校验失败"
[ -f "$DESKTOP_FILE" ] && [ ! -L "$DESKTOP_FILE" ] \
    && [ "$(stat -c '%u:%g:%a' -- "$DESKTOP_FILE")" = '0:0:644' ] \
    || fail "桌面入口最终权限校验失败"
[ -L "$BIN_LINK" ] && [ "$(stat -c '%u:%g' -- "$BIN_LINK")" = '0:0' ] \
    || fail "命令链接最终权限校验失败"

printf '[OK] CC Switch %s 安装完成\n' "$PINNED_VERSION"
printf '[OK] 命令: cc-switch\n'
