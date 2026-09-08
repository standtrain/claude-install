# Claude CLI 安装器

基于 Electron 的 Windows/Linux 图形化安装器，并提供可独立部署的 Claude CLI 与 CC Switch 安装脚本。安装流程包含下载源校验、文件大小与 SHA256 校验、原子替换、配置备份和系统命令入口创建。

## 直接下载安装（推荐 0基础请看这里）

**Release 页面提供已构建好的安装程序，无需克隆源码、无需安装 Node.js，下载即可使用：**

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Windows | `ClaudeCLIInstaller-Setup-x.x.x.exe` | NSIS 安装包，双击运行 |
| Windows | `ClaudeCLIInstaller-Portable-x.x.x.zip` | 便携版，解压即用 |
| Linux x86_64 | `ClaudeCLIInstaller-Linux-x.x.x-x86_64.AppImage.tar.gz` | AppImage（保留可执行权限） |
| Linux x86_64 | `ClaudeCLIInstaller-Linux-x.x.x-x86_64.AppImage` | 独立 AppImage |
| Linux x86_64 | `ClaudeCLIInstaller-Linux-x.x.x-x86_64.deb` | Debian/Ubuntu 安装包 |
| Linux x86_64 | `ClaudeCLIInstaller-Linux-x.x.x-x86_64.rpm` | Fedora/RHEL 安装包 |
| Linux arm64 | `ClaudeCLIInstaller-Linux-x.x.x-arm64.AppImage.tar.gz` | ARM64 AppImage（保留可执行权限） |
| Linux arm64 | `ClaudeCLIInstaller-Linux-x.x.x-arm64.deb` | ARM64 Debian/Ubuntu 安装包 |
| Linux arm64 | `ClaudeCLIInstaller-Linux-x.x.x-arm64.rpm` | ARM64 Fedora/RHEL 安装包 |

前往项目 **Release 页面**查看所有可用版本、校验和与更新日志。

### AppImage 使用说明

推荐下载 `.AppImage.tar.gz` 归档（已保留可执行权限）：

```bash
tar -xzf ClaudeCLIInstaller-Linux-0.3.5-x86_64.AppImage.tar.gz
./ClaudeCLIInstaller-Linux-0.3.5-x86_64.AppImage
```

直接下载 `.AppImage` 时需要手动添加权限；不要使用 root 运行图形界面：

```bash
chmod 755 ClaudeCLIInstaller-Linux-0.3.5-x86_64.AppImage
./ClaudeCLIInstaller-Linux-0.3.5-x86_64.AppImage
```

若系统未安装 FUSE 2，可使用 AppImage 自带的解包运行模式：

```bash
APPIMAGE_EXTRACT_AND_RUN=1 ./ClaudeCLIInstaller-Linux-0.3.5-x86_64.AppImage
```

------



## 以下是微基础内容，0基础请完全忽略

## Linux 命令行远程安装

如果只需要命令行工具（Claude CLI / CC Switch），无需下载图形安装器，一行命令即可完成远程安装。

`deploy/cc-custom.sh` 和 `deploy/ccswitch.sh` 在启动后会自动选择系统已有的 `curl` 或 `wget` 下载后续文件。

系统有 `curl` 时：

```bash
curl -fsSL https://claude.fernweh.top/ccswitch.sh | sudo sh
```

系统没有 `curl`、但有 `wget` 时：

```bash
wget -qO- https://claude.fernweh.top/ccswitch.sh | sudo sh
```

需要同一段命令自动兼容两种下载器时：

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

也可以先在 Debian/Ubuntu 安装 `curl`，再执行原命令：

```bash
sudo apt update
sudo apt install -y curl
curl -fsSL https://claude.fernweh.top/ccswitch.sh | sudo sh
```

> 当终端提示"找不到命令 curl"时，远程脚本尚未下载和执行，因此脚本不可能自行安装 `curl`。必须改用本机已有的 `wget`，或先安装 `curl`。如果两者都不存在，需要先通过系统包管理器安装其中之一。

Claude CLI 的 Linux 脚本使用方法相同，只需将 URL 改为 `https://claude.fernweh.top/cc-custom.sh`。

------



## 该项目是开源项目，如果你不是开发者请忽略以下内容

## 从源码构建（开发者）

> 普通用户无需阅读本节——直接下载 Release 中的预构建程序即可。

项目最低运行环境为 Node.js 11.9.0。

```powershell
npm ci
npm test
npm run check
npm start
```

启动 Linux 界面：

```powershell
npm run start:linux
```

### 构建命令

所有构建命令统一由 `scripts/build.js` 调度，产物写入 `dist/` 或 `linux-installer/dist/`。
依赖统一由根目录的 `package-lock.json` 管理，Linux 子项目不维护重复锁文件。

```powershell
npm run dist          # Windows：NSIS 安装包和便携版
npm run dist:portable # Windows：仅便携版
npm run dist:nsis     # Windows：仅 NSIS 安装包
npm run dist:linux    # Linux：全部目标
npm run dist:appimage # Linux：仅 AppImage
npm run dist:deb      # Linux：仅 deb
npm run dist:rpm      # Linux：仅 rpm
```

需要指定架构时可直接使用统一入口，例如：`node scripts/build.js linux AppImage arm64`。

## 目录结构

```text
├─ src/main/          Windows Electron 主进程
├─ src/renderer/      Windows 渲染层
├─ linux-installer/   Linux Electron 安装器
├─ deploy/            HTTPS 部署脚本与服务器配置示例
├─ scripts/           构建和静态检查入口
├─ tests/             行为与脚本契约测试
├─ build/             可选构建资源（图标等，可为空）
└─ dist/              Windows 构建产物（不提交 Git）
```

## 下载与安装逻辑

- 下载 URL 使用 HTTPS 白名单；发生重定向时会重新校验协议和目标主机。
- 下载写入临时文件，并限制超时、响应大小和重定向次数；校验通过后才原子替换目标文件。
- Windows Git 固定为当前已验证的 2.55.0.windows.3，并在官方、清华 TUNA、阿里系 npmmirror 与华为云镜像间自动测速。
- Claude CLI 二进制优先从 npmmirror（阿里云）npm 平台子包镜像下载（国内大文件更快更稳），官方 GCS（`storage.googleapis.com`）作为兜底；版本号与 manifest 仍取自官方 GCS，官方版本服务不可达时改用脚本内置固定版本（v2.1.263，附带各平台文件大小与 SHA256）。镜像只承担传输，下载的二进制仍须匹配文件大小、ELF/文件头与 SHA256（npmmirror 平台包内二进制经离线核验与官方逐字节一致）。
- Git、Claude CLI 和 CC Switch 安装包按已知文件大小与 SHA256 校验，Linux 二进制还会检查 ELF 文件头。
- 图形安装器只执行安装包内置且 SHA256 固定的部署脚本，不从远程选择脚本源。
- CC Switch 固定为经过离线审查的 v3.18.0 元数据，并在 GitHub、ghproxy.net、gh-proxy.com 与 ghfast.top 间回退；镜像只承担传输，文件仍须匹配固定大小和 SHA256。
- Linux Claude CLI 安装到 `/opt/claude`，通过 `/usr/local/bin/claude` 提供全局命令；CC Switch 安装到 `/opt/cc-switch`，通过 `/usr/local/bin/cc-switch` 提供命令。
- Ubuntu 26 x86_64 的 VMware Wayland 会话会通过受保护启动器隔离冲突的 GIO 模块，并在解析路径、所有者和权限校验通过后预加载系统 `libwayland-client.so.0`，用于处理 AppImage 与宿主 EGL/Wayland 的 ABI 冲突。兼容层不修改 CC Switch 数据库，可用 `CC_SWITCH_LINUX_COMPAT=off` 关闭，或用 `CC_SWITCH_LINUX_COMPAT=force` 手动启用。
- Windows 系统级安装目录为 `%ProgramData%\claude`，PATH 变更写入系统环境变量。

## 权限与配置安全

- 系统级安装步骤才请求管理员或 root 权限，业务程序不应以管理员或 root 身份长期运行。
- Linux 图形界面以普通用户运行，Git、Claude CLI 和 CC Switch 的系统写入分别通过 `pkexec` 单次授权。
- Linux 安装目录由 root 管理且普通用户只读；命令通过 `/usr/local/bin` 中的符号链接公开，无需修改系统或用户的 shell 启动文件。
- Linux 配置写入发起 `sudo` 的真实用户家目录，而不是默认写入 `/root`。`.claude.json` 及其备份权限固定为 `600`，仅文件所有者可读写。
- 配置更新先解析并保留已有字段；配置损坏、用户身份无法确认或目标为异常符号链接时会停止，不覆盖原文件。
- 日志不记录密码、令牌等敏感值，下载和子进程参数不通过 Shell 字符串拼接。

自建脚本源的部署、调用和权限设置见 `deploy/README.md`。
