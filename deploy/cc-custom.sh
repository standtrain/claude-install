#!/bin/sh
# Claude Code system-wide Linux installer.

set -eu
umask 077
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

TARGET="${1:-latest}"
case "$TARGET" in
    stable|latest) ;;
    *)
        printf '%s\n' "$TARGET" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]{1,32})?$' || {
            echo "用法: $0 [stable|latest|VERSION]" >&2
            exit 1
        }
        ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "本脚本需要 root 权限：请使用 wget -qO- URL | sudo sh" >&2
    exit 1
fi
if [ "$(uname -s)" != "Linux" ]; then
    echo "本脚本仅支持 Linux" >&2
    exit 1
fi

if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    echo "系统中既没有 curl，也没有 wget。" >&2
    echo "Ubuntu/Debian 请先执行: sudo apt-get update && sudo apt-get install -y curl" >&2
    exit 1
fi

GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
# 国内镜像：npmmirror（阿里云）npm 平台子包，二进制与官方 GCS 逐字节一致（SHA256 相同）。
# 镜像仅承担传输，下载内容仍须匹配官方大小、ELF 头与 SHA256，不放宽任何完整性校验。
NPM_MIRROR_BASE="https://registry.npmmirror.com"
# 固定兜底版本：官方版本服务（GCS）不可达时使用；大小与 SHA256 取自官方 manifest 的离线审查结果。
PINNED_VERSION="2.1.263"
INSTALL_BASE="/opt/claude"
VERSIONS_DIR="$INSTALL_BASE/versions"
BIN_DIR="$INSTALL_BASE/bin"
LINK_PATH="$BIN_DIR/claude"
GLOBAL_LINK="/usr/local/bin/claude"
STATE_DIR="$INSTALL_BASE/state"
CACHE_DIR="$INSTALL_BASE/cache"
DOWNLOAD_TIMEOUT=300
MAX_BINARY_BYTES=1073741824

valid_user_name() {
    [ -n "$1" ] && [ "${#1}" -le 32 ] || return 1
    case "$1" in
        .*|-*|*[!A-Za-z0-9_.-]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_uid() {
    [ -n "$1" ] && [ "${#1}" -le 10 ] || return 1
    case "$1" in *[!0-9]*) return 1 ;; esac
    [ "$1" -le 4294967294 ] 2>/dev/null
}

lookup_passwd_record() {
    _account_selector="$1"
    _account_kind="$2"
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$_account_selector"
    elif [ "$_account_kind" = "uid" ]; then
        awk -F: -v uid="$_account_selector" '$3 == uid { print; found++ } END { exit found == 1 ? 0 : 1 }' /etc/passwd
    else
        awk -F: -v name="$_account_selector" '$1 == name { print; found++ } END { exit found == 1 ? 0 : 1 }' /etc/passwd
    fi
}

ACCOUNT_SELECTOR="root"
ACCOUNT_KIND="name"
if [ "${PKEXEC_UID+x}" = "x" ]; then
    valid_uid "$PKEXEC_UID" || { echo "PKEXEC_UID 格式无效" >&2; exit 1; }
    ACCOUNT_SELECTOR="$PKEXEC_UID"
    ACCOUNT_KIND="uid"
elif [ "${SUDO_USER+x}" = "x" ] && [ "$SUDO_USER" != "root" ]; then
    valid_user_name "$SUDO_USER" || { echo "SUDO_USER 格式无效" >&2; exit 1; }
    ACCOUNT_SELECTOR="$SUDO_USER"
fi

PASSWD_RECORD=$(lookup_passwd_record "$ACCOUNT_SELECTOR" "$ACCOUNT_KIND") || {
    echo "无法从系统账号数据库解析真实用户" >&2
    exit 1
}
[ "$(printf '%s\n' "$PASSWD_RECORD" | wc -l | tr -d '[:space:]')" = "1" ] \
    && [ "$(printf '%s\n' "$PASSWD_RECORD" | awk -F: '{ print NF }')" = "7" ] || {
    echo "系统账号记录格式无效" >&2
    exit 1
}
REAL_USER=$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f1)
REAL_UID=$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f3)
REAL_GID=$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f4)
REAL_HOME=$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f6)
valid_user_name "$REAL_USER" || { echo "系统账号名称格式无效" >&2; exit 1; }
valid_uid "$REAL_UID" && valid_uid "$REAL_GID" || {
    echo "用户 UID/GID 格式无效" >&2
    exit 1
}
if [ "$ACCOUNT_KIND" = "uid" ] && [ "$REAL_UID" -ne "$PKEXEC_UID" ]; then
    echo "PKEXEC_UID 与系统账号记录不一致" >&2
    exit 1
fi
if [ "$ACCOUNT_KIND" = "name" ] && [ "$ACCOUNT_SELECTOR" != "root" ]; then
    [ "$REAL_USER" = "$SUDO_USER" ] || { echo "SUDO_USER 与系统账号记录不一致" >&2; exit 1; }
    if [ "${SUDO_UID+x}" = "x" ]; then
        valid_uid "$SUDO_UID" && [ "$REAL_UID" -eq "$SUDO_UID" ] || {
            echo "SUDO_UID 与系统账号记录不一致" >&2
            exit 1
        }
    fi
fi
case "$REAL_HOME" in
    /*) ;;
    *) echo "用户目录必须是绝对路径" >&2; exit 1 ;;
esac
[ "${#REAL_HOME}" -le 4096 ] || { echo "用户目录路径过长" >&2; exit 1; }
[ -d "$REAL_HOME" ] && [ ! -L "$REAL_HOME" ] || {
    echo "用户目录必须是现有普通目录" >&2
    exit 1
}
CONFIG_PATH="$REAL_HOME/.claude.json"

run_as_real_user() {
    if [ "$REAL_UID" -eq 0 ]; then
        "$@"
    elif command -v setpriv >/dev/null 2>&1; then
        setpriv --reuid="$REAL_UID" --regid="$REAL_GID" --clear-groups -- "$@"
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$REAL_USER" -- "$@"
    else
        echo "缺少 setpriv/runuser，无法以普通用户权限读取现有配置" >&2
        return 126
    fi
}

case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
esac
if [ -f /lib/libc.musl-x86_64.so.1 ] || [ -f /lib/libc.musl-aarch64.so.1 ] \
    || ldd /bin/ls 2>/dev/null | grep -q musl; then
    platform="linux-${arch}-musl"
else
    platform="linux-${arch}"
fi

TMP_DIR=""
STAGED_BINARY=""
STAGED_LINK_DIR=""
CONFIG_STAGE_DIR=""
CONFIG_STAGE_ID=""
cleanup() {
    if [ -n "$STAGED_BINARY" ]; then
        case "$STAGED_BINARY" in
            "$VERSIONS_DIR"/.claude.new.*) rm -f -- "$STAGED_BINARY" ;;
        esac
    fi
    if [ -n "$STAGED_LINK_DIR" ]; then
        case "$STAGED_LINK_DIR" in
            "$BIN_DIR"/.claude-link.*|/usr/local/bin/.claude-link.*)
                rm -f -- "$STAGED_LINK_DIR/link"
                rmdir -- "$STAGED_LINK_DIR" 2>/dev/null || true
                ;;
        esac
    fi
    if [ -n "$CONFIG_STAGE_DIR" ]; then
        case "$CONFIG_STAGE_DIR" in
            "$REAL_HOME"/.claude-config.*)
                (
                    cd -- "$CONFIG_STAGE_DIR" 2>/dev/null \
                        && [ "$(stat -c '%d:%i' -- . 2>/dev/null)" = "$CONFIG_STAGE_ID" ] \
                        && rm -f -- ./claude.json
                ) || true
                rmdir -- "$CONFIG_STAGE_DIR" 2>/dev/null || true
                ;;
        esac
    fi
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        case "$TMP_DIR" in
            /tmp/claude-installer.*) rm -rf -- "$TMP_DIR" ;;
            *) echo "临时目录路径异常，已拒绝清理" >&2 ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
TMP_DIR=$(mktemp -d /tmp/claude-installer.XXXXXX)
VERSION_FILE="$TMP_DIR/version"
MANIFEST_FILE="$TMP_DIR/manifest.json"
BINARY_FILE="$TMP_DIR/claude"
META_FILE="$TMP_DIR/manifest.meta"

safe_gcs_url() {
    [ "${#1}" -le 2048 ] || return 1
    case "$1" in
        "$GCS_BUCKET"/*) _gcs_path=${1#"$GCS_BUCKET"/} ;;
        *) return 1 ;;
    esac
    [ -n "$_gcs_path" ] || return 1
    printf '%s\n' "$_gcs_path" | grep -Eq '^[A-Za-z0-9._/-]+$' || return 1
    case "/$_gcs_path/" in
        *'/../'*|*'/./'*|*'//'*) return 1 ;;
    esac
    return 0
}

downloaded_file_within_limit() {
    _checked_file="$1"
    _checked_limit="$2"
    [ -f "$_checked_file" ] && [ ! -L "$_checked_file" ] || return 1
    _checked_size=$(wc -c < "$_checked_file" | tr -d '[:space:]') || return 1
    printf '%s\n' "$_checked_size" | grep -Eq '^[0-9]+$' || return 1
    [ "$_checked_size" -le "$_checked_limit" ]
}

download_file() {
    _url="$1"
    _output="$2"
    _quiet="${3:-false}"
    _max_bytes="${4:-$MAX_BINARY_BYTES}"
    safe_gcs_url "$_url" || { echo "下载 URL 不在允许范围" >&2; return 1; }
    printf '%s\n' "$_max_bytes" | grep -Eq '^[0-9]{1,10}$' || return 1
    [ "$_max_bytes" -gt 0 ] && [ "$_max_bytes" -le "$MAX_BINARY_BYTES" ] || return 1
    _file_blocks=$(((_max_bytes + 511) / 512))
    _attempt=1
    while [ "$_attempt" -le 3 ]; do
        rm -f -- "$_output"
        if [ "$DOWNLOADER" = "curl" ]; then
            if [ "$_quiet" = "true" ]; then
                if _effective_url=$(curl -fLsS --proto '=https' --proto-redir '=https' --tlsv1.2 \
                    --connect-timeout 15 --max-time "$DOWNLOAD_TIMEOUT" --retry 2 --retry-delay 1 \
                    --max-redirs 5 --max-filesize "$_max_bytes" --write-out '%{url_effective}' \
                    -o "$_output" "$_url"); then
                    safe_gcs_url "$_effective_url" && return 0
                    echo "curl 最终下载地址不在允许范围" >&2
                fi
            else
                if _effective_url=$(curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
                    --connect-timeout 15 --max-time "$DOWNLOAD_TIMEOUT" --retry 2 --retry-delay 1 \
                    --max-redirs 5 --max-filesize "$_max_bytes" --progress-bar \
                    --write-out '%{url_effective}' -o "$_output" "$_url"); then
                    safe_gcs_url "$_effective_url" && return 0
                    echo "curl 最终下载地址不在允许范围" >&2
                fi
            fi
        else
            if [ "$_quiet" = "true" ]; then
                if (
                    ulimit -c 0 || exit 1
                    ulimit -f "$_file_blocks" || exit 1
                    wget --https-only --max-redirect=0 --timeout="$DOWNLOAD_TIMEOUT" --tries=2 \
                        -q -O "$_output" "$_url"
                ); then
                    downloaded_file_within_limit "$_output" "$_max_bytes" && return 0
                fi
            else
                if (
                    ulimit -c 0 || exit 1
                    ulimit -f "$_file_blocks" || exit 1
                    wget --https-only --max-redirect=0 --timeout="$DOWNLOAD_TIMEOUT" --tries=2 \
                        -O "$_output" "$_url"
                ); then
                    downloaded_file_within_limit "$_output" "$_max_bytes" && return 0
                fi
            fi
        fi
        echo "下载失败（第 $_attempt/3 次）" >&2
        _attempt=$((_attempt + 1))
    done
    rm -f -- "$_output"
    return 1
}

# ── 国内镜像（npmmirror）与固定版本兜底 ──

# npmmirror 平台子包归档地址；$1=版本 $2=平台。平台标识（linux-x64 等）与 npm 包后缀一致。
npm_archive_url() {
    printf '%s/@anthropic-ai/claude-code-%s/-/claude-code-%s-%s.tgz\n' \
        "$NPM_MIRROR_BASE" "$2" "$2" "$1"
}

# 固定版本的离线校验值（来源：官方 manifest），依据全局 $platform 查表。
pinned_field() {
    case "$platform:$1" in
        linux-x64:size) printf '%s\n' 215662064 ;;
        linux-x64:sha256) printf '%s\n' 26d020351e8112f4006790f3cfce43b4c9df0c1bb1d0e542364d64151b81d5ba ;;
        linux-arm64:size) printf '%s\n' 215211432 ;;
        linux-arm64:sha256) printf '%s\n' 7d25d7c8ae6c6e009cc7dae4e817f674179fd31fb7761bcd56fee4c2902b4c03 ;;
        linux-x64-musl:size) printf '%s\n' 209678288 ;;
        linux-x64-musl:sha256) printf '%s\n' b9c407e36847bcb24b953b1390f240c840ae6c99e10a76475d2fadc5d5c4adca ;;
        linux-arm64-musl:size) printf '%s\n' 208156312 ;;
        linux-arm64-musl:sha256) printf '%s\n' 9b02e81a61d54bef3e6d190b6f2f6c4a9c31e6e068468f79d520d5ffff6b0e42 ;;
        *) return 1 ;;
    esac
}

# 校验二进制/归档下载地址：官方 GCS 直链，或 npmmirror 注册表及其 302 跳转的 CDN。
is_allowed_binary_url() {
    _bu_url="$1"
    [ -n "$_bu_url" ] && [ "${#_bu_url}" -le 2048 ] || return 1
    case "$_bu_url" in
        https://*) ;;
        *) return 1 ;;
    esac
    _bu_rest=${_bu_url#https://}
    _bu_authority=${_bu_rest%%/*}
    [ "$_bu_rest" != "$_bu_authority" ] || return 1
    _bu_path=/${_bu_rest#*/}
    case "$_bu_authority" in
        storage.googleapis.com)
            _bu_gcs=${_bu_url#"$GCS_BUCKET"/}
            [ "$_bu_gcs" != "$_bu_url" ] || return 1
            printf '%s\n' "$_bu_gcs" | grep -Eq '^[A-Za-z0-9._/-]+$' || return 1
            case "/$_bu_gcs/" in
                *'/../'*|*'/./'*|*'//'*) return 1 ;;
            esac
            return 0
            ;;
        registry.npmmirror.com)
            printf '%s\n' "$_bu_path" | grep -Eq "^/@anthropic-ai/claude-code-${platform}/-/claude-code-${platform}-[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]{1,32})?\.tgz\$" || return 1
            ;;
        cdn.npmmirror.com)
            printf '%s\n' "$_bu_path" | grep -Eq "^/packages/(%40|@)anthropic-ai/claude-code-${platform}/[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]{1,32})?/claude-code-${platform}-[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]{1,32})?\.tgz\$" || return 1
            ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$_bu_path" | grep -Eq '^[A-Za-z0-9.%/_@-]+$' || return 1
    case "$_bu_path" in
        *'/../'*|*'/./'*|*'//'*) return 1 ;;
    esac
    return 0
}

get_http_status() {
    awk '
        /^[[:space:]]*HTTP\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]/ { status = $2 }
        END { if (status != "") print status }
    ' "$1"
}

get_redirect_location() {
    awk '
        {
            line = $0
            sub(/\r$/, "", line)
            if (line !~ /^[[:space:]]*[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:/) next
            sub(/^[[:space:]]*[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*/, "", line)
            sub(/[[:space:]]+\[[Ff][Oo][Ll][Ll][Oo][Ww][Ii][Nn][Gg]\][[:space:]]*$/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line != "" && !seen[line]++) { location = line; count++ }
        }
        END { if (count == 1) print location; else exit 1 }
    ' "$1"
}

# wget 不自行跟随重定向（--max-redirect=0），逐跳解析 Location 并校验白名单。
_download_artifact_wget() {
    _dw_url="$1"; _dw_output="$2"; _dw_max_bytes="$3"; _dw_quiet="$4"
    _dw_hdr=$(mktemp "$TMP_DIR/wget.hdr.XXXXXX")
    _dw_blocks=$(( (_dw_max_bytes + 511) / 512 ))
    _dw_redirs=0
    while :; do
        is_allowed_binary_url "$_dw_url" || { rm -f -- "$_dw_output" "$_dw_hdr"; return 1; }
        rm -f -- "$_dw_output"
        _dw_ok=false
        _dw_quiet_opt=""
        [ "$_dw_quiet" = "true" ] && _dw_quiet_opt="-q"
        if (
            ulimit -c 0 || exit 1
            ulimit -f "$_dw_blocks" || exit 1
            wget --https-only --server-response --max-redirect=0 \
                --connect-timeout=15 --read-timeout="$DOWNLOAD_TIMEOUT" --tries=1 \
                $_dw_quiet_opt --output-document="$_dw_output" "$_dw_url"
        ) > /dev/null 2> "$_dw_hdr"; then
            _dw_ok=true
        fi
        case "$(get_http_status "$_dw_hdr")" in
            200)
                [ "$_dw_ok" = true ] && downloaded_file_within_limit "$_dw_output" "$_dw_max_bytes" \
                    && { rm -f -- "$_dw_hdr"; return 0; }
                rm -f -- "$_dw_output" "$_dw_hdr"; return 1
                ;;
            301|302|303|307|308)
                [ "$_dw_redirs" -lt 5 ] || { rm -f -- "$_dw_output" "$_dw_hdr"; return 1; }
                _dw_loc=$(get_redirect_location "$_dw_hdr") || { rm -f -- "$_dw_output" "$_dw_hdr"; return 1; }
                case "$_dw_loc" in
                    https://*) _dw_next="$_dw_loc" ;;
                    *) _dw_next="${_dw_url%/*}/$_dw_loc" ;;
                esac
                is_allowed_binary_url "$_dw_next" || { rm -f -- "$_dw_output" "$_dw_hdr"; return 1; }
                _dw_url="$_dw_next"
                _dw_redirs=$(( _dw_redirs + 1 ))
                ;;
            *)
                rm -f -- "$_dw_output" "$_dw_hdr"; return 1
                ;;
        esac
    done
}

# 下载二进制或归档到文件；与 download_file 不同，本函数支持 npmmirror 的 302 跳转。
download_artifact() {
    _da_url="$1"; _da_output="$2"; _da_max_bytes="$3"; _da_quiet="${4:-false}"
    is_allowed_binary_url "$_da_url" || { echo "下载地址不在允许范围" >&2; return 1; }
    printf '%s\n' "$_da_max_bytes" | grep -Eq '^[0-9]{1,10}$' || return 1
    [ "$_da_max_bytes" -gt 0 ] && [ "$_da_max_bytes" -le "$MAX_BINARY_BYTES" ] || return 1
    _da_blocks=$(( (_da_max_bytes + 511) / 512 ))
    _da_attempt=1
    while [ "$_da_attempt" -le 3 ]; do
        rm -f -- "$_da_output"
        if [ "$DOWNLOADER" = "curl" ]; then
            _da_eff=$(mktemp "$TMP_DIR/eff.XXXXXX")
            _da_ok=false
            if [ "$_da_quiet" = "true" ]; then
                if (
                    ulimit -c 0 || exit 1
                    ulimit -f "$_da_blocks" || exit 1
                    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
                        --connect-timeout 15 --max-time "$DOWNLOAD_TIMEOUT" --retry 2 --retry-delay 1 \
                        --max-redirs 5 --max-filesize "$_da_max_bytes" \
                        -o "$_da_output" --write-out '%{url_effective}' "$_da_url"
                ) > "$_da_eff" 2>/dev/null; then
                    _da_ok=true
                fi
            else
                if (
                    ulimit -c 0 || exit 1
                    ulimit -f "$_da_blocks" || exit 1
                    curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
                        --connect-timeout 15 --max-time "$DOWNLOAD_TIMEOUT" --retry 2 --retry-delay 1 \
                        --max-redirs 5 --max-filesize "$_da_max_bytes" --progress-bar \
                        -o "$_da_output" --write-out '%{url_effective}' "$_da_url"
                ) > "$_da_eff"; then
                    _da_ok=true
                fi
            fi
            if [ "$_da_ok" = true ] \
                && is_allowed_binary_url "$(tr -d '[:space:]' < "$_da_eff")" \
                && downloaded_file_within_limit "$_da_output" "$_da_max_bytes"; then
                rm -f -- "$_da_eff"
                return 0
            fi
            rm -f -- "$_da_eff"
        else
            if _download_artifact_wget "$_da_url" "$_da_output" "$_da_max_bytes" "$_da_quiet"; then
                return 0
            fi
        fi
        echo "下载失败（第 $_da_attempt/3 次）" >&2
        _da_attempt=$(( _da_attempt + 1 ))
    done
    rm -f -- "$_da_output"
    return 1
}

# 从 npmmirror .tgz 归档中提取固定成员 package/claude 到目标文件。
extract_binary_from_archive() {
    _eb_archive="$1"; _eb_dest="$2"
    command -v tar >/dev/null 2>&1 || { echo "缺少 tar，无法解包镜像归档" >&2; return 1; }
    _eb_dir=$(mktemp -d "$TMP_DIR/extract.XXXXXX")
    # 仅提取写死的成员 package/claude，成员名不含路径穿越字符。
    if ! tar -xzf "$_eb_archive" -C "$_eb_dir" package/claude 2>/dev/null; then
        rm -rf -- "$_eb_dir"
        echo "镜像归档解包失败" >&2
        return 1
    fi
    _eb_inner="$_eb_dir/package/claude"
    if [ ! -f "$_eb_inner" ] || [ -L "$_eb_inner" ]; then
        rm -rf -- "$_eb_dir"
        echo "镜像归档中缺少二进制" >&2
        return 1
    fi
    mv -f -- "$_eb_inner" "$_eb_dest"
    rm -rf -- "$_eb_dir"
    return 0
}

# 下载并校验 Claude 二进制：官方 GCS 优先，npmmirror 国内镜像兜底，按序回退。
# $1=版本 $2=期望大小 $3=期望 SHA256 $4=目标文件
fetch_verified_binary() {
    _fb_version="$1"; _fb_size="$2"; _fb_sha="$3"; _fb_dest="$4"
    _fb_gcs="$GCS_BUCKET/$_fb_version/$platform/claude"
    _fb_npm=$(npm_archive_url "$_fb_version" "$platform")
    # 官方源优先：先尝试官方 GCS；连接超时或总时长超时后切换 npmmirror 国内镜像。
    # 镜像二进制与官方逐字节一致，且仍强制大小、ELF 头与 SHA256 校验。
    _fb_order="gcs npm"
    for _fb_kind in $_fb_order; do
        if [ "$_fb_kind" = "gcs" ]; then
            _fb_url="$_fb_gcs"; _fb_label="官方 GCS 源"
        else
            _fb_url="$_fb_npm"; _fb_label="npmmirror 国内镜像"
        fi
        echo "尝试下载源：$_fb_label"
        rm -f -- "$_fb_dest"
        if [ "$_fb_kind" = "gcs" ]; then
            if ! download_file "$_fb_url" "$_fb_dest" false "$_fb_size"; then
                echo "该源下载失败，尝试下一个来源" >&2
                continue
            fi
        else
            _fb_arch="$TMP_DIR/claude-archive.$$.tgz"
            rm -f -- "$_fb_arch"
            # 归档为 gzip 压缩包，体积小于二进制；用二进制期望大小作为下载上限足够宽松。
            if download_artifact "$_fb_url" "$_fb_arch" "$_fb_size" true \
                && extract_binary_from_archive "$_fb_arch" "$_fb_dest"; then
                rm -f -- "$_fb_arch"
            else
                echo "镜像源下载或解包失败，尝试下一个来源" >&2
                rm -f -- "$_fb_arch"; rm -f -- "$_fb_dest"
                continue
            fi
        fi

        _fb_actual_size=$(wc -c < "$_fb_dest" | tr -d '[:space:]')
        if [ "$_fb_actual_size" -gt "$MAX_BINARY_BYTES" ]; then
            echo "二进制超过大小限制" >&2
            rm -f -- "$_fb_dest"; continue
        fi
        if [ "$_fb_size" -gt 0 ] && [ "$_fb_actual_size" -ne "$_fb_size" ]; then
            echo "文件大小校验失败（期望 $_fb_size，实际 $_fb_actual_size），尝试下一个来源" >&2
            rm -f -- "$_fb_dest"; continue
        fi
        _fb_magic=$(od -An -tx1 -N4 "$_fb_dest" 2>/dev/null | tr -d ' \n')
        if [ "$_fb_magic" != "7f454c46" ]; then
            echo "下载内容不是有效 ELF 文件，尝试下一个来源" >&2
            rm -f -- "$_fb_dest"; continue
        fi
        if command -v sha256sum >/dev/null 2>&1; then
            _fb_actual_sha=$(sha256sum "$_fb_dest" | cut -d ' ' -f 1)
        elif command -v shasum >/dev/null 2>&1; then
            _fb_actual_sha=$(shasum -a 256 "$_fb_dest" | cut -d ' ' -f 1)
        else
            echo "缺少 sha256sum 或 shasum，无法验证安装包" >&2
            return 1
        fi
        if [ "$_fb_actual_sha" != "$_fb_sha" ]; then
            echo "SHA256 校验失败，尝试下一个来源" >&2
            rm -f -- "$_fb_dest"; continue
        fi
        echo "文件大小、ELF 头和 SHA256 校验通过（来源：$_fb_label）"
        return 0
    done
    echo "所有下载源均失败或校验未通过，未修改现有安装" >&2
    return 1
}

# PINNED_MODE=true 表示官方版本服务不可达，改用脚本内置固定版本（官方源优先、失败切镜像）。
PINNED_MODE=false
checksum=""
expected_size=0

if [ "$TARGET" = "latest" ] || [ "$TARGET" = "stable" ]; then
    echo "获取 Claude Code 最新版本…"
    version=""
    if download_file "$GCS_BUCKET/latest" "$VERSION_FILE" true 128 \
        && [ "$(wc -c < "$VERSION_FILE" | tr -d ' ')" -le 128 ]; then
        version=$(tr -d '[:space:]' < "$VERSION_FILE")
    fi
    if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]{1,32})?$' \
        || [ "${#version}" -gt 64 ]; then
        echo "无法访问官方版本服务，改用国内镜像固定版本 $PINNED_VERSION" >&2
        version="$PINNED_VERSION"
        PINNED_MODE=true
    fi
else
    version="$TARGET"
    printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]{1,32})?$' || {
        echo "版本号格式无效" >&2
        exit 1
    }
    [ "${#version}" -le 64 ] || { echo "版本号过长" >&2; exit 1; }
fi

# manifest 的下载与解析在 parse_manifest 定义之后进行，失败时回退固定版本。

parse_manifest() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -I - "$MANIFEST_FILE" "$platform" > "$META_FILE" <<'PY'
import json
import re
import sys

path, platform = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)
entry = manifest.get("platforms", {}).get(platform)
if not isinstance(entry, dict):
    raise SystemExit(1)
checksum = str(entry.get("checksum", "")).lower()
size = entry.get("size", 0)
if not re.fullmatch(r"[a-f0-9]{64}", checksum) or not isinstance(size, int):
    raise SystemExit(1)
print(checksum)
print(size)
PY
    elif command -v jq >/dev/null 2>&1; then
        jq -r --arg platform "$platform" \
            '.platforms[$platform] | .checksum, (.size // 0)' "$MANIFEST_FILE" > "$META_FILE"
    else
        checksum=$(tr -d '\n\r\t' < "$MANIFEST_FILE" \
            | sed -n "s/.*\"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"\([a-fA-F0-9][a-fA-F0-9]*\)\".*/\1/p" \
            | head -n 1 | tr 'A-F' 'a-f')
        printf '%s\n0\n' "$checksum" > "$META_FILE"
    fi
    [ "$(wc -l < "$META_FILE" | tr -d ' ')" -eq 2 ]
}
if [ "$PINNED_MODE" != "true" ]; then
    echo "版本: $version，平台: $platform，下载器: $DOWNLOADER"
    manifest_ok=false
    if download_file "$GCS_BUCKET/$version/manifest.json" "$MANIFEST_FILE" true 1048576 \
        && [ "$(wc -c < "$MANIFEST_FILE" | tr -d ' ')" -le 1048576 ] \
        && parse_manifest; then
        checksum=$(sed -n '1p' "$META_FILE" | tr 'A-F' 'a-f')
        expected_size=$(sed -n '2p' "$META_FILE")
        if [ "${#checksum}" -eq 64 ] && ! printf '%s' "$checksum" | grep -Eq '[^a-f0-9]' \
            && printf '%s\n' "$expected_size" | grep -Eq '^[0-9]{1,10}$' \
            && [ "$expected_size" -ge 1 ] && [ "$expected_size" -le "$MAX_BINARY_BYTES" ]; then
            manifest_ok=true
        fi
    fi
    if [ "$manifest_ok" != "true" ]; then
        echo "获取官方 manifest 失败，改用国内镜像固定版本 $PINNED_VERSION" >&2
        version="$PINNED_VERSION"
        PINNED_MODE=true
    fi
fi

if [ "$PINNED_MODE" = "true" ]; then
    checksum=$(pinned_field sha256) || { echo "当前平台没有可用的固定版本" >&2; exit 1; }
    expected_size=$(pinned_field size) || { echo "当前平台没有可用的固定版本" >&2; exit 1; }
    echo "固定版本: $version，平台: $platform，下载器: $DOWNLOADER（官方源优先、失败切镜像，强制校验大小与 SHA256）"
fi

BINARY_LIMIT="$MAX_BINARY_BYTES"
if [ "$expected_size" -ge 1 ]; then
    BINARY_LIMIT="$expected_size"
fi

echo "正在下载 Claude Code 二进制…"
# 官方 GCS 优先、npmmirror 国内镜像兜底；任一来源均强制大小、ELF 头与 SHA256 校验。
fetch_verified_binary "$version" "$BINARY_LIMIT" "$checksum" "$BINARY_FILE" || exit 1

secure_system_directory() {
    _directory="$1"
    [ -d "$_directory" ] && [ ! -L "$_directory" ] || return 1
    _owner=$(stat -c '%u' -- "$_directory") || return 1
    _mode=$(stat -c '%a' -- "$_directory") || return 1
    [ "$_owner" -eq 0 ] || return 1
    printf '%s\n' "$_mode" | grep -Eq '^[0-7]{3,4}$' || return 1
    [ $((0$_mode & 022)) -eq 0 ]
}

for managed_dir in "$INSTALL_BASE" "$VERSIONS_DIR" "$BIN_DIR" "$STATE_DIR" "$CACHE_DIR"; do
    if [ -L "$managed_dir" ] || { [ -e "$managed_dir" ] && [ ! -d "$managed_dir" ]; }; then
        echo "安装路径必须是普通目录: $managed_dir" >&2
        exit 1
    fi
done
mkdir -p "$VERSIONS_DIR" "$BIN_DIR" "$STATE_DIR" "$CACHE_DIR"
for managed_dir in "$INSTALL_BASE" "$VERSIONS_DIR" "$BIN_DIR" "$STATE_DIR" "$CACHE_DIR"; do
    [ -d "$managed_dir" ] && [ ! -L "$managed_dir" ] || {
        echo "安装目录创建后类型异常: $managed_dir" >&2
        exit 1
    }
    chown 0:0 -- "$managed_dir"
done
chmod 755 "$INSTALL_BASE" "$VERSIONS_DIR" "$BIN_DIR"
chmod 700 "$STATE_DIR" "$CACHE_DIR"

publish_symlink() {
    _link_target="$1"
    _link_path="$2"
    _link_parent=${_link_path%/*}
    secure_system_directory "$_link_parent" || {
        echo "链接父目录必须由 root 所有且不可被其他用户写入: $_link_parent" >&2
        return 1
    }
    if { [ -e "$_link_path" ] || [ -L "$_link_path" ]; } && [ ! -L "$_link_path" ]; then
        echo "$_link_path 已存在且不是符号链接，已拒绝覆盖" >&2
        return 1
    fi
    STAGED_LINK_DIR=$(mktemp -d "$_link_parent/.claude-link.XXXXXX")
    chmod 700 "$STAGED_LINK_DIR"
    chown 0:0 -- "$STAGED_LINK_DIR"
    ln -s -- "$_link_target" "$STAGED_LINK_DIR/link"
    mv -fT -- "$STAGED_LINK_DIR/link" "$_link_path"
    rmdir -- "$STAGED_LINK_DIR"
    STAGED_LINK_DIR=""
}

final_path="$VERSIONS_DIR/$version"
if { [ -e "$final_path" ] || [ -L "$final_path" ]; } && { [ ! -f "$final_path" ] || [ -L "$final_path" ]; }; then
    echo "目标版本路径类型异常，已拒绝覆盖" >&2
    exit 1
fi
STAGED_BINARY=$(mktemp "$VERSIONS_DIR/.claude.new.XXXXXX")
cp -- "$BINARY_FILE" "$STAGED_BINARY"
chown 0:0 -- "$STAGED_BINARY"
chmod 755 "$STAGED_BINARY"
mv -f -- "$STAGED_BINARY" "$final_path"
STAGED_BINARY=""
chown 0:0 -- "$final_path"
chmod 755 "$final_path"
publish_symlink "$final_path" "$LINK_PATH"
publish_symlink "$LINK_PATH" "$GLOBAL_LINK"

backup_config() {
    [ -f "$CONFIG_PATH" ] || return 0
    if [ -L "$STATE_DIR/backups" ] || { [ -e "$STATE_DIR/backups" ] && [ ! -d "$STATE_DIR/backups" ]; }; then
        echo "配置备份路径必须是普通目录" >&2
        return 1
    fi
    mkdir -p "$STATE_DIR/backups"
    chown 0:0 -- "$STATE_DIR/backups"
    chmod 700 "$STATE_DIR/backups"
    _backup=$(mktemp "$STATE_DIR/backups/.claude.json.XXXXXX")
    run_as_real_user cat -- "$CONFIG_PATH" > "$_backup"
    chown 0:0 -- "$_backup"
    chmod 600 "$_backup"
    echo "已备份原配置到 $_backup"
}

write_config() {
    _first_start="$1"
    if { [ -e "$CONFIG_PATH" ] || [ -L "$CONFIG_PATH" ]; } \
        && { [ ! -f "$CONFIG_PATH" ] || [ -L "$CONFIG_PATH" ]; }; then
        echo "$CONFIG_PATH 必须是普通文件且不能是符号链接" >&2
        return 1
    fi
    if [ -f "$CONFIG_PATH" ]; then
        _config_owner=$(stat -c '%u' -- "$CONFIG_PATH") || return 1
        _config_links=$(stat -c '%h' -- "$CONFIG_PATH") || return 1
        [ "$_config_owner" = "$REAL_UID" ] && [ "$_config_links" = "1" ] || {
            echo "现有配置的所有者或硬链接数异常，已拒绝覆盖" >&2
            return 1
        }
    fi
    backup_config
    _temp=$(mktemp "$TMP_DIR/claude.json.XXXXXX")
    if command -v python3 >/dev/null 2>&1; then
        CONFIG_PATH="$CONFIG_PATH" FIRST_START_TIME="$_first_start" \
            REAL_UID="$REAL_UID" REAL_GID="$REAL_GID" python3 -I - > "$_temp" <<'PY'
import json
import os
import sys

path = os.environ["CONFIG_PATH"]
uid = int(os.environ["REAL_UID"])
gid = int(os.environ["REAL_GID"])
if uid != 0:
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)
data = {}
if os.path.exists(path):
    with open(path, "r", encoding="utf-8-sig") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise SystemExit("配置顶层必须是 JSON 对象")
data["installMethod"] = "native"
data["autoUpdates"] = False
data["autoUpdatesProtectedForNative"] = True
data["hasCompletedOnboarding"] = True
data.setdefault("firstStartTime", os.environ["FIRST_START_TIME"])
encoded = (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
sys.stdout.buffer.write(encoded)
PY
    elif command -v jq >/dev/null 2>&1; then
        if [ -f "$CONFIG_PATH" ]; then
            run_as_real_user jq -e 'type == "object"' "$CONFIG_PATH" >/dev/null \
                || { echo "原配置不是有效 JSON 对象，已保留原文件" >&2; return 1; }
            run_as_real_user jq --arg first "$_first_start" \
                '. + {installMethod:"native",autoUpdates:false,autoUpdatesProtectedForNative:true,hasCompletedOnboarding:true} | .firstStartTime //= $first' \
                "$CONFIG_PATH" > "$_temp"
        else
            run_as_real_user jq -n --arg first "$_first_start" \
                '{installMethod:"native",autoUpdates:false,autoUpdatesProtectedForNative:true,hasCompletedOnboarding:true,firstStartTime:$first}' \
                > "$_temp"
        fi
    elif [ -f "$CONFIG_PATH" ]; then
        echo "缺少 python3/jq，无法安全合并现有配置" >&2
        return 1
    else
        cat > "$_temp" <<JSON
{
  "installMethod": "native",
  "autoUpdates": false,
  "autoUpdatesProtectedForNative": true,
  "hasCompletedOnboarding": true,
  "firstStartTime": "$_first_start"
}
JSON
    fi
    chmod 600 "$_temp"
    chown 0:0 -- "$_temp"

    CONFIG_STAGE_DIR=$(mktemp -d "$REAL_HOME/.claude-config.XXXXXX")
    chmod 700 "$CONFIG_STAGE_DIR"
    chown 0:0 -- "$CONFIG_STAGE_DIR"
    CONFIG_STAGE_ID=$(stat -c '%d:%i' -- "$CONFIG_STAGE_DIR")
    (
        cd -- "$CONFIG_STAGE_DIR"
        [ "$(stat -c '%d:%i' -- .)" = "$CONFIG_STAGE_ID" ] || {
            echo "配置暂存目录在发布前发生变化" >&2
            exit 1
        }
        cp -- "$_temp" ./claude.json
        chown "$REAL_UID:$REAL_GID" -- ./claude.json
        chmod 600 ./claude.json
        mv -fT -- ./claude.json "$CONFIG_PATH"
    )
    rmdir -- "$CONFIG_STAGE_DIR" 2>/dev/null || true
    CONFIG_STAGE_DIR=""
    CONFIG_STAGE_ID=""
}

write_config "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo ""
echo "============================================"
echo "  Claude Code $version 安装完成"
echo "============================================"
echo "  二进制: $final_path"
echo "  命令:   $GLOBAL_LINK"
echo "  配置:   $CONFIG_PATH (权限 600)"
