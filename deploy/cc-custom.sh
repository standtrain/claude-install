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
    echo "[ERROR] 本脚本需要 root 权限：请使用 wget -qO- URL | sudo sh" >&2
    exit 1
fi
if [ "$(uname -s)" != "Linux" ]; then
    echo "[ERROR] 本脚本仅支持 Linux" >&2
    exit 1
fi

if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    echo "[ERROR] 系统中既没有 curl，也没有 wget。" >&2
    echo "[ERROR] Ubuntu/Debian 请先执行: sudo apt-get update && sudo apt-get install -y curl" >&2
    exit 1
fi

GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
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
    valid_uid "$PKEXEC_UID" || { echo "[ERROR] PKEXEC_UID 格式无效" >&2; exit 1; }
    ACCOUNT_SELECTOR="$PKEXEC_UID"
    ACCOUNT_KIND="uid"
elif [ "${SUDO_USER+x}" = "x" ] && [ "$SUDO_USER" != "root" ]; then
    valid_user_name "$SUDO_USER" || { echo "[ERROR] SUDO_USER 格式无效" >&2; exit 1; }
    ACCOUNT_SELECTOR="$SUDO_USER"
fi

PASSWD_RECORD=$(lookup_passwd_record "$ACCOUNT_SELECTOR" "$ACCOUNT_KIND") || {
    echo "[ERROR] 无法从系统账号数据库解析真实用户" >&2
    exit 1
}
[ "$(printf '%s\n' "$PASSWD_RECORD" | wc -l | tr -d '[:space:]')" = "1" ] \
    && [ "$(printf '%s\n' "$PASSWD_RECORD" | awk -F: '{ print NF }')" = "7" ] || {
    echo "[ERROR] 系统账号记录格式无效" >&2
    exit 1
}
REAL_USER=$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f1)
REAL_UID=$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f3)
REAL_GID=$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f4)
REAL_HOME=$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f6)
valid_user_name "$REAL_USER" || { echo "[ERROR] 系统账号名称格式无效" >&2; exit 1; }
valid_uid "$REAL_UID" && valid_uid "$REAL_GID" || {
    echo "[ERROR] 用户 UID/GID 格式无效" >&2
    exit 1
}
if [ "$ACCOUNT_KIND" = "uid" ] && [ "$REAL_UID" -ne "$PKEXEC_UID" ]; then
    echo "[ERROR] PKEXEC_UID 与系统账号记录不一致" >&2
    exit 1
fi
if [ "$ACCOUNT_KIND" = "name" ] && [ "$ACCOUNT_SELECTOR" != "root" ]; then
    [ "$REAL_USER" = "$SUDO_USER" ] || { echo "[ERROR] SUDO_USER 与系统账号记录不一致" >&2; exit 1; }
    if [ "${SUDO_UID+x}" = "x" ]; then
        valid_uid "$SUDO_UID" && [ "$REAL_UID" -eq "$SUDO_UID" ] || {
            echo "[ERROR] SUDO_UID 与系统账号记录不一致" >&2
            exit 1
        }
    fi
fi
case "$REAL_HOME" in
    /*) ;;
    *) echo "[ERROR] 用户目录必须是绝对路径" >&2; exit 1 ;;
esac
[ "${#REAL_HOME}" -le 4096 ] || { echo "[ERROR] 用户目录路径过长" >&2; exit 1; }
[ -d "$REAL_HOME" ] && [ ! -L "$REAL_HOME" ] || {
    echo "[ERROR] 用户目录必须是现有普通目录" >&2
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
        echo "[ERROR] 缺少 setpriv/runuser，无法以普通用户权限读取现有配置" >&2
        return 126
    fi
}

case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "[ERROR] 不支持的架构: $(uname -m)" >&2; exit 1 ;;
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
            *) echo "[WARN] 临时目录路径异常，已拒绝清理" >&2 ;;
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
    safe_gcs_url "$_url" || { echo "[ERROR] 下载 URL 不在允许范围" >&2; return 1; }
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
                    echo "[ERROR] curl 最终下载地址不在允许范围" >&2
                fi
            else
                if _effective_url=$(curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
                    --connect-timeout 15 --max-time "$DOWNLOAD_TIMEOUT" --retry 2 --retry-delay 1 \
                    --max-redirs 5 --max-filesize "$_max_bytes" --progress-bar \
                    --write-out '%{url_effective}' -o "$_output" "$_url"); then
                    safe_gcs_url "$_effective_url" && return 0
                    echo "[ERROR] curl 最终下载地址不在允许范围" >&2
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
        echo "[WARN] 下载失败（第 $_attempt/3 次）" >&2
        _attempt=$((_attempt + 1))
    done
    rm -f -- "$_output"
    return 1
}

if [ "$TARGET" = "latest" ] || [ "$TARGET" = "stable" ]; then
    echo "[INFO] 获取 Claude Code 最新版本…"
    download_file "$GCS_BUCKET/latest" "$VERSION_FILE" true 128 || {
        echo "[ERROR] 无法访问官方版本服务，未修改现有安装" >&2
        exit 1
    }
    [ "$(wc -c < "$VERSION_FILE" | tr -d ' ')" -le 128 ] || {
        echo "[ERROR] 版本响应超过大小限制" >&2
        exit 1
    }
    version=$(tr -d '[:space:]' < "$VERSION_FILE")
else
    version="$TARGET"
fi
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]{1,32})?$' || {
    echo "[ERROR] 版本号格式无效" >&2
    exit 1
}
[ "${#version}" -le 64 ] || { echo "[ERROR] 版本号过长" >&2; exit 1; }

echo "[INFO] 版本: $version，平台: $platform，下载器: $DOWNLOADER"
download_file "$GCS_BUCKET/$version/manifest.json" "$MANIFEST_FILE" true 1048576 || {
    echo "[ERROR] 获取官方 manifest 失败，未修改现有安装" >&2
    exit 1
}
[ "$(wc -c < "$MANIFEST_FILE" | tr -d ' ')" -le 1048576 ] || {
    echo "[ERROR] manifest 超过 1 MB 大小限制" >&2
    exit 1
}

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
parse_manifest || { echo "[ERROR] manifest 缺少当前平台元数据" >&2; exit 1; }
checksum=$(sed -n '1p' "$META_FILE" | tr 'A-F' 'a-f')
expected_size=$(sed -n '2p' "$META_FILE")
[ "${#checksum}" -eq 64 ] && ! printf '%s' "$checksum" | grep -Eq '[^a-f0-9]' || {
    echo "[ERROR] manifest checksum 格式无效" >&2
    exit 1
}
printf '%s\n' "$expected_size" | grep -Eq '^[0-9]{1,10}$' || {
    echo "[ERROR] manifest size 格式无效" >&2
    exit 1
}
[ "$expected_size" -le "$MAX_BINARY_BYTES" ] || {
    echo "[ERROR] manifest 声明的文件大小超过限制" >&2
    exit 1
}
BINARY_LIMIT="$MAX_BINARY_BYTES"
if [ "$expected_size" -gt 0 ]; then
    BINARY_LIMIT="$expected_size"
fi

echo "[INFO] 正在下载 Claude Code 二进制…"
download_file "$GCS_BUCKET/$version/$platform/claude" "$BINARY_FILE" false "$BINARY_LIMIT" || {
    echo "[ERROR] 官方二进制下载失败，未修改现有安装" >&2
    exit 1
}
actual_size=$(wc -c < "$BINARY_FILE" | tr -d ' ')
[ "$actual_size" -le "$MAX_BINARY_BYTES" ] || { echo "[ERROR] 二进制超过大小限制" >&2; exit 1; }
if [ "$expected_size" -gt 0 ] && [ "$actual_size" -ne "$expected_size" ]; then
    echo "[ERROR] 文件大小校验失败" >&2
    exit 1
fi
magic=$(od -An -tx1 -N4 "$BINARY_FILE" 2>/dev/null | tr -d ' \n')
[ "$magic" = "7f454c46" ] || { echo "[ERROR] 下载内容不是有效 ELF 文件" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
    actual_checksum=$(sha256sum "$BINARY_FILE" | cut -d ' ' -f 1)
elif command -v shasum >/dev/null 2>&1; then
    actual_checksum=$(shasum -a 256 "$BINARY_FILE" | cut -d ' ' -f 1)
else
    echo "[ERROR] 缺少 sha256sum 或 shasum，无法验证安装包" >&2
    exit 1
fi
[ "$actual_checksum" = "$checksum" ] || { echo "[ERROR] SHA256 校验失败" >&2; exit 1; }
echo "[OK] 文件大小、ELF 头和 SHA256 校验通过"

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
        echo "[ERROR] 安装路径必须是普通目录: $managed_dir" >&2
        exit 1
    fi
done
mkdir -p "$VERSIONS_DIR" "$BIN_DIR" "$STATE_DIR" "$CACHE_DIR"
for managed_dir in "$INSTALL_BASE" "$VERSIONS_DIR" "$BIN_DIR" "$STATE_DIR" "$CACHE_DIR"; do
    [ -d "$managed_dir" ] && [ ! -L "$managed_dir" ] || {
        echo "[ERROR] 安装目录创建后类型异常: $managed_dir" >&2
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
        echo "[ERROR] 链接父目录必须由 root 所有且不可被其他用户写入: $_link_parent" >&2
        return 1
    }
    if { [ -e "$_link_path" ] || [ -L "$_link_path" ]; } && [ ! -L "$_link_path" ]; then
        echo "[ERROR] $_link_path 已存在且不是符号链接，已拒绝覆盖" >&2
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
    echo "[ERROR] 目标版本路径类型异常，已拒绝覆盖" >&2
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
        echo "[ERROR] 配置备份路径必须是普通目录" >&2
        return 1
    fi
    mkdir -p "$STATE_DIR/backups"
    chown 0:0 -- "$STATE_DIR/backups"
    chmod 700 "$STATE_DIR/backups"
    _backup=$(mktemp "$STATE_DIR/backups/.claude.json.XXXXXX")
    run_as_real_user cat -- "$CONFIG_PATH" > "$_backup"
    chown 0:0 -- "$_backup"
    chmod 600 "$_backup"
    echo "[INFO] 已备份原配置到 $_backup"
}

write_config() {
    _first_start="$1"
    if { [ -e "$CONFIG_PATH" ] || [ -L "$CONFIG_PATH" ]; } \
        && { [ ! -f "$CONFIG_PATH" ] || [ -L "$CONFIG_PATH" ]; }; then
        echo "[ERROR] $CONFIG_PATH 必须是普通文件且不能是符号链接" >&2
        return 1
    fi
    if [ -f "$CONFIG_PATH" ]; then
        _config_owner=$(stat -c '%u' -- "$CONFIG_PATH") || return 1
        _config_links=$(stat -c '%h' -- "$CONFIG_PATH") || return 1
        [ "$_config_owner" = "$REAL_UID" ] && [ "$_config_links" = "1" ] || {
            echo "[ERROR] 现有配置的所有者或硬链接数异常，已拒绝覆盖" >&2
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
                || { echo "[ERROR] 原配置不是有效 JSON 对象，已保留原文件" >&2; return 1; }
            run_as_real_user jq --arg first "$_first_start" \
                '. + {installMethod:"native",autoUpdates:false,autoUpdatesProtectedForNative:true,hasCompletedOnboarding:true} | .firstStartTime //= $first' \
                "$CONFIG_PATH" > "$_temp"
        else
            run_as_real_user jq -n --arg first "$_first_start" \
                '{installMethod:"native",autoUpdates:false,autoUpdatesProtectedForNative:true,hasCompletedOnboarding:true,firstStartTime:$first}' \
                > "$_temp"
        fi
    elif [ -f "$CONFIG_PATH" ]; then
        echo "[ERROR] 缺少 python3/jq，无法安全合并现有配置" >&2
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
            echo "[ERROR] 配置暂存目录在发布前发生变化" >&2
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
