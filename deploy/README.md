# 自建脚本源部署指南

本目录用于通过自建 HTTPS 服务分发 Claude CLI 和 CC Switch 安装脚本。脚本只接受 HTTPS 下载源，并在替换现有安装前校验文件大小、文件格式和 SHA256。

## 文件与调用方式

| 文件 | 平台 | 用途 | 调用方式 |
| --- | --- | --- | --- |
| `cc-custom.ps1` | Windows | 安装 Claude CLI | `irm https://YOUR-DOMAIN.example/cc-custom.ps1 \| iex` |
| `cc-custom.sh` | Linux | 安装 Claude CLI | `wget -qO- https://YOUR-DOMAIN.example/cc-custom.sh \| sudo sh` |
| `ccswitch.ps1` | Windows | 安装 CC Switch | `irm https://YOUR-DOMAIN.example/ccswitch.ps1 \| iex` |
| `ccswitch.sh` | Linux | 安装 CC Switch | `wget -qO- https://YOUR-DOMAIN.example/ccswitch.sh \| sudo sh` |

Linux 脚本在开始执行后会自动选择系统已有的 `curl` 或 `wget` 下载后续文件。入口命令仍依赖用来获取脚本的本地工具：如果 `curl` 不存在，`curl ... | sudo sh` 会在脚本下载前失败，远程脚本没有机会自行安装 `curl`。

无 `curl`、有 `wget` 时直接使用：

```bash
wget -qO- https://claude.fernweh.top/ccswitch.sh | sudo sh
```

也可先下载到权限为 `600` 的随机临时文件，再执行；以下入口会自动选择已有下载器：

```bash
umask 077
installer_file=$(mktemp)
trap 'rm -f "$installer_file"' EXIT HUP INT TERM
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --proto '=https' --proto-redir '=https' --max-redirs 0 -o "$installer_file" https://claude.fernweh.top/ccswitch.sh
elif command -v wget >/dev/null 2>&1; then
  wget --https-only --max-redirect=0 -qO "$installer_file" https://claude.fernweh.top/ccswitch.sh
else
  echo '需要先安装 curl 或 wget' >&2
  exit 127
fi
sudo sh "$installer_file"
```

或者在 Debian/Ubuntu 上先安装 `curl`，再执行原命令：

```bash
sudo apt update
sudo apt install -y curl
curl -fsSL https://claude.fernweh.top/ccswitch.sh | sudo sh
```

部署其他域名或安装 Claude CLI 时，分别替换域名和脚本文件名。若 `curl`、`wget` 都不存在，必须先通过系统包管理器安装其中之一。

## 安装结果

### Windows Claude CLI

- 安装目录：`%ProgramData%\claude\bin`，供本机用户使用。
- 将命令目录加入 HKLM PATH 并广播环境变量变更。
- 合并用户 `.claude.json`，包含 `hasCompletedOnboarding: true`，不会静默覆盖损坏的 JSON。

### Linux Claude CLI

- 版本文件安装到 `/opt/claude/versions`，当前版本链接位于 `/opt/claude/bin/claude`。
- 创建 `/usr/local/bin/claude` 符号链接，因此无需修改系统或用户的 shell 启动文件。
- 配置写入发起 `sudo` 的真实用户家目录；`.claude.json` 与备份均设为 `600`。
- 系统目录由 root 管理，程序可由普通用户通过 `claude` 命令运行。

### CC Switch

- Windows 脚本安装官方 MSI；Linux 脚本将 AppImage 安装到 `/opt/cc-switch`。
- Linux 创建 `/usr/local/bin/cc-switch` 命令和桌面入口。
- Linux 脚本只安装内置元数据指定的 CC Switch v3.18.0，不读取动态 latest API。官方源与传输镜像下载的文件都必须匹配固定大小、ELF 架构和 SHA256。

## 部署步骤（Caddy）

服务器应使用独立、低权限的 `caddy` 服务账号，只开放 HTTP/HTTPS 必要端口。以下示例适用于 Debian/Ubuntu。

### 1. 安装 Caddy

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

### 2. 放置脚本并收紧权限

```bash
sudo install -d -o root -g caddy -m 750 /var/www/claude-installer
sudo install -o root -g caddy -m 640 cc-custom.ps1 cc-custom.sh ccswitch.ps1 ccswitch.sh /var/www/claude-installer/
```

脚本由 root 拥有，Caddy 只有读取权限；不要让 Web 服务账号拥有脚本写权限。

### 3. 配置 Caddy

先将 `Caddyfile.example` 中的 `YOUR-DOMAIN.example` 替换为已解析到服务器的域名，然后安装配置：

```bash
sudo install -o caddy -g caddy -m 600 Caddyfile.example /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

配置文件权限为 `600`，仅运行服务的独立账号可读写。TLS 证书由 Caddy 自动申请和续期。

### 4. 验证发布内容

```bash
curl -fsSI https://YOUR-DOMAIN.example/cc-custom.ps1
curl -fsSI https://YOUR-DOMAIN.example/cc-custom.sh
curl -fsSI https://YOUR-DOMAIN.example/ccswitch.ps1
curl -fsSI https://YOUR-DOMAIN.example/ccswitch.sh
```

应返回成功状态，并包含 `Content-Type: text/plain; charset=utf-8` 和 `X-Content-Type-Options: nosniff`。部署前应在可信环境审查脚本内容；生产环境可先下载到本地核验，再以管理员权限执行。

### 5. 更新脚本

`Cache-Control: no-cache, no-store, must-revalidate` 已在示例配置中设置。更新时重新安装四个脚本文件即可，无需修改脚本内的镜像地址：

```bash
sudo install -o root -g caddy -m 640 cc-custom.ps1 cc-custom.sh ccswitch.ps1 ccswitch.sh /var/www/claude-installer/
```

## Nginx

可参考 `nginx.conf.example`。同样必须启用 HTTPS、使用独立低权限服务账号、限制静态目录为只读，并将 Nginx 配置文件权限设为 `600`。

## 网络与安全要求

- 发布站点必须启用 HTTPS，不提供 HTTP 降级入口。
- Claude CLI 脚本需要访问 `storage.googleapis.com`；CC Switch 脚本只访问固定 GitHub Release、GitHub Release Assets 及脚本内允许的 HTTPS 传输镜像。
- 不要在脚本、Caddy/Nginx 配置或示例中写入密码、令牌、私有地址等敏感信息。
- `.claude.json` 和安装器生成的配置备份固定为 `600`，仅目标用户可读写；部署服务不得读取用户配置。
- 安装需要 root 或管理员权限，但安装后的 CLI/GUI 应由普通用户运行。
- 仅开放必要端口，并按运维策略保留至少 90 天访问与操作日志；日志中不得记录密码、令牌或其他敏感值。
