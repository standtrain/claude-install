"""更新 Gitee v0.3.6 Release 的说明与标题。

用法：GITEE_TOKEN=<令牌> python -I scripts/update-gitee-body.py
令牌仅从环境变量读取。
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

TOKEN = os.environ.get("GITEE_TOKEN", "").strip()
if not TOKEN:
    sys.exit("缺少环境变量 GITEE_TOKEN")

RELEASE_ID = "1185865"
OWNER_REPO = "zzpdhc/claude-install"
NAME = "v0.3.6 - 内置离线二进制升级至 Claude Code 2.1.291"

BODY = """## 本次更新

### 内置离线版本升级
- Windows 图形安装包内置的离线 claude.exe 升级到 Claude Code v2.1.291，与固定版本 pin 保持同哈希。
- Linux 固定版本表同步升级到 v2.1.291（linux-x64 / linux-arm64 / linux-x64-musl / linux-arm64-musl），校验值取自官方 manifest 并用 npmmirror 平台包交叉核验一致。

### 继承自 0.3.5 的修复
- 大文件下载改为官方 GCS 优先 + npmmirror 国内镜像兜底；Windows 采用分块 Range 下载并带看门狗：连接超时、无数据停滞、持续低速（20 秒内不足 6MB）均会在几十秒内中止当前源并自动切换，不再假死。
- 固定版本兜底时优先使用安装包内置离线副本，避免在慢/断网络上空等。
- 修复 CC Switch 安装全程无法取消的问题（下载中止信号 + taskkill 递归结束 msiexec），测速阶段也可立即取消。
- 支持先装 Claude 后单独补装 Git（已装则跳过 Claude 配置与 PATH 步骤）。
- 规范化安装日志：级别统一由输出流决定，消除双前缀问题。

## 附件说明（重要）

Gitee 单个附件上限 100MB，故完整版以分卷形式提供。

| 附件 | 大小 | 说明 |
| --- | --- | --- |
| ClaudeCLIInstaller-Portable-0.3.6-Lite.exe | 58.8 MB | 便携版·精简版，不含内置 claude.exe，联网下载安装（国内走 npmmirror 镜像） |
| ClaudeCLIInstaller-Setup-0.3.6-Lite.exe | 58.9 MB | NSIS 安装包·精简版，同上 |
| ClaudeCLIInstaller-Portable-0.3.6-Full.zip.001 | 90.0 MB | 便携版·完整版分卷 1/2 |
| ClaudeCLIInstaller-Portable-0.3.6-Full.zip.002 | 43.3 MB | 便携版·完整版分卷 2/2 |
| claude-2.1.291-win32-x64.zip.001 | 90.0 MB | 内置离线二进制分卷 1/2（可单独取用） |
| claude-2.1.291-win32-x64.zip.002 | 15.3 MB | 内置离线二进制分卷 2/2 |

完整版与精简版的区别：完整版额外内置 v2.1.291 的离线 claude.exe（约 242MB）。当官方源与国内镜像都不可用时，完整版可直接本地安装、零网络等待；精简版无此能力，必须联网下载。

如何合并分卷：把同名 .zip.001 与 .zip.002 放在同一目录，用 7-Zip 或 WinRAR 右键 .zip.001 解压即可（无需重命名）。解压后得到 .exe，双击运行。分卷缺少任何一个都无法解压，请务必全部下载。

## 校验值（SHA256）

```
ClaudeCLIInstaller-Portable-0.3.6-Lite.exe      3fde410d078801535451c023c0a2a6062a269efb3de672ae12e3a1dea3063fa3
ClaudeCLIInstaller-Setup-0.3.6-Lite.exe         b943b81f7cb437cdf810bdb30f2c06faf6cb5c3c29fe6f2eb2110a18f67f2798
ClaudeCLIInstaller-Portable-0.3.6-Full.zip.001  dbc4236324cfdd05a44bce0b24dbb68f3aaf6a05a6f8e117260ca0d016e1980d
ClaudeCLIInstaller-Portable-0.3.6-Full.zip.002  b322b5e495ff7ef5bf2e0e3a3c1ed829c9231365c6c584b5df7e54842614b118
claude-2.1.291-win32-x64.zip.001                b457789ceb2ca412224426c43c45d923acea993f10229e9bb6d754a97842401a
claude-2.1.291-win32-x64.zip.002                33d587ee3b8a60270441980efaab3006ce9e0b7e8bd4eb5a624ff90a64f45d39
```

完整版 Portable 解压后 SHA256：823584ff299bc2dc3171df435bcd0837ab35b65295f89c2f91febb77bfe31a39

## 其他说明
- 所有下载内容仍强制匹配文件大小、可执行文件头与 SHA256，镜像只承担传输。
- GitHub 侧同步发布，完整版未分卷。
"""


def main():
    data = urllib.parse.urlencode({
        "access_token": TOKEN,
        "tag_name": "v0.3.6",
        "name": NAME,
        "body": BODY,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"https://gitee.com/api/v5/repos/{OWNER_REPO}/releases/{RELEASE_ID}",
        data=data,
        method="PATCH",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            result = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        print(f"HTTP {err.code}: {err.read().decode('utf-8', 'replace')[:400]}")
        return 1
    print("更新成功，body 长度 =", len(result.get("body") or ""))
    print("发布页：https://gitee.com/%s/releases/tag/v0.3.6" % OWNER_REPO)
    return 0


if __name__ == "__main__":
    sys.exit(main())
