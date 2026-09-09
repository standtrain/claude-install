#Requires -Version 5.1

param(
    [Parameter(Position=0)]
    [ValidateLength(1, 48)]
    [ValidatePattern('^(stable|latest|\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]{1,32})?)$')]
    [string]$Target = "latest"
)

# ---------------------------------------------------------------
# cc-custom.ps1 —— 基于 daheiai/cc.ps1 的魔改版
#
# 与官方脚本的差异：
#   1. INSTALL_BASE / BIN_DIR / LOCKS_DIR / CACHE_DIR / DOWNLOADS_DIR
#      均改为 $env:PROGRAMDATA\claude 下，供所有用户共享
#   2. .claude.json 追加写入 hasCompletedOnboarding = $true
#   3. 安装完成后主动追加 $env:PROGRAMDATA\claude\bin 到 HKLM PATH
#   4. 重建并验证精确 ACL，Users 仅可读取共享程序目录，防止目录接管
#
# 说明：本脚本以 `irm URL | iex` 和安装器内置 UTF-8 加载器为执行入口。
# 通过 iex 调用时 $Target 采用默认值 "latest"；指定版本时应以严格 UTF-8
# 读取脚本，再通过 ScriptBlock.Create 调用，具体命令见 deploy/README.md。
# ---------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "[ERROR] 需要管理员权限。请以管理员身份打开 PowerShell 后重新执行安装命令。"
        }
    }
    finally {
        $identity.Dispose()
    }
}

Assert-Administrator

[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path variable:Target)) { $Target = "latest" }

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error "Claude Code 不支持 32 位 Windows，请使用 64 位系统。"
    exit 1
}

$GCS_BUCKET = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
# 国内镜像：npmmirror（阿里云）以 npm 平台子包分发同一二进制，经离线核验与官方 GCS 逐字节一致（SHA256 相同）。
# 镜像只承担传输，下载内容仍须匹配官方大小与 SHA256，不放宽任何完整性校验。
$NPM_MIRROR_BASE = "https://registry.npmmirror.com"
# 允许的下载主机：官方 GCS、npmmirror 注册表，以及注册表 302 跳转的 CDN。
$ALLOWED_DOWNLOAD_HOSTS = @(
    "storage.googleapis.com",
    "registry.npmmirror.com",
    "cdn.npmmirror.com"
)
# 固定兜底版本：官方版本服务（GCS）不可达时使用；大小与 SHA256 取自官方 manifest 的离线审查结果。
$PINNED_FALLBACK_VERSION = "2.1.263"
$PINNED_FALLBACKS = @{
    "win32-x64" = @{
        Size = [int64]218746016
        Sha256 = "0b35df94c1307004f07b738390bfef8dfca5e9af29aaf6517f305bf086b95b03"
    }
    "win32-arm64" = @{
        Size = [int64]209795744
        Sha256 = "2ca14d6f61a39c3ad5d72424f4e347d5a570a58036ab1afe14c5e3eb668e9540"
    }
}

function Assert-DownloadUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    if ($Url.Length -lt 1 -or $Url.Length -gt 2048) {
        throw "无效的下载地址"
    }

    [Uri]$uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        throw "无效的下载地址"
    }

    if (
        $uri.Scheme -cne "https" -or
        -not ($ALLOWED_DOWNLOAD_HOSTS -ccontains $uri.DnsSafeHost.ToLowerInvariant()) -or
        $uri.Port -ne 443 -or
        $uri.UserInfo.Length -ne 0 -or
        $uri.Query.Length -ne 0 -or
        $uri.Fragment.Length -ne 0
    ) {
        throw "无效的下载地址"
    }

    $hostName = $uri.DnsSafeHost.ToLowerInvariant()
    $path = $uri.AbsolutePath
    $gcsPrefix = "/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/"
    # npm 平台包后缀与本脚本平台标识一致（win32-x64 / win32-arm64）；第二处用反向引用强制相同。
    $npmPlatformGroup = 'claude-code-(win32-x64|win32-arm64)'
    $npmPlatformSame = 'claude-code-\1'
    $versionTail = '[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]{1,32})?'

    if ($hostName -ceq "storage.googleapis.com") {
        if (-not $path.StartsWith($gcsPrefix, [StringComparison]::Ordinal)) {
            throw "无效的下载地址"
        }
        return
    }

    if ($hostName -ceq "registry.npmmirror.com") {
        # 形如 /@anthropic-ai/claude-code-<平台>/-/claude-code-<平台>-<版本>.tgz
        $pattern = '^/(?:@|%40)anthropic-ai/' + $npmPlatformGroup + '/-/' + $npmPlatformSame + '-' + $versionTail + '\.tgz$'
        if ($path -cnotmatch $pattern) {
            throw "无效的下载地址"
        }
        return
    }

    if ($hostName -ceq "cdn.npmmirror.com") {
        # 注册表 302 跳转目标：/packages/%40anthropic-ai/claude-code-<平台>/<版本>/claude-code-<平台>-<版本>.tgz
        $pattern = '^/packages/(?:@|%40)anthropic-ai/' + $npmPlatformGroup + '/' + $versionTail + '/' + $npmPlatformSame + '-' + $versionTail + '\.tgz$'
        if ($path -cnotmatch $pattern) {
            throw "无效的下载地址"
        }
        return
    }

    throw "无效的下载地址"
}

# ── 定制目录（ProgramData 全局共享） ──
# 不信任可被调用进程覆盖的 PROGRAMDATA 环境变量；从系统已知目录取得路径。
$PROGRAM_DATA_ROOT = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
if ([string]::IsNullOrWhiteSpace($PROGRAM_DATA_ROOT)) {
    throw "无法确定系统 ProgramData 目录"
}
$INSTALL_BASE   = Join-Path $PROGRAM_DATA_ROOT "claude"
$VERSIONS_DIR   = "$INSTALL_BASE\versions"
$BIN_DIR        = "$INSTALL_BASE\bin"
$LINK_PATH      = "$BIN_DIR\claude.exe"
$LOCKS_DIR      = "$INSTALL_BASE\state\locks"
$CACHE_DIR      = "$INSTALL_BASE\cache\staging"
$DOWNLOADS_DIR  = "$INSTALL_BASE\downloads"
$BACKUPS_DIR    = "$INSTALL_BASE\backups"

# .claude.json 保持每用户独立；不信任可被调用进程覆盖的 USERPROFILE。
$USER_PROFILE_ROOT = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
if ([string]::IsNullOrWhiteSpace($USER_PROFILE_ROOT)) {
    throw "无法确定当前用户目录"
}
$CONFIG_PATH    = Join-Path $USER_PROFILE_ROOT ".claude.json"

function ConvertTo-ShallowHashtable {
    param([Parameter(Mandatory = $true)][object]$InputObject)

    $result = @{}
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = $InputObject[$key]
        }
        return $result
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Get-UniqueBackupPath {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffffffZ")
    return Join-Path $BACKUPS_DIR "$FileName.backup.$timestamp.$([Guid]::NewGuid().ToString('N'))"
}

function Backup-ConfigFile {
    param([Parameter(Mandatory = $true)][string]$SourcePath)

    [void](Assert-RegularConfigFile -Path $SourcePath)
    Assert-SafeDirectory -Path $BACKUPS_DIR
    $backupPath = Get-UniqueBackupPath -FileName ".claude.json"
    $sourceStream = $null
    $temporaryBackupPath = Join-Path $BACKUPS_DIR ".claude.json.backup.$([Guid]::NewGuid().ToString('N')).tmp"
    $backupStream = $null
    try {
        $sourceStream = New-Object System.IO.FileStream(
            $SourcePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        Assert-SafeDirectory -Path $BACKUPS_DIR
        $backupStream = New-Object System.IO.FileStream(
            $temporaryBackupPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $sourceStream.CopyTo($backupStream)
        $backupStream.Flush($true)
        $backupStream.Dispose()
        $backupStream = $null
        Assert-SafeDirectory -Path $BACKUPS_DIR
        [void](Assert-RegularSingleLinkFile -Path $temporaryBackupPath)
        if ($null -ne (Get-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue)) {
            throw "备份目标已存在"
        }
        [System.IO.File]::Move($temporaryBackupPath, $backupPath)
        [void](Assert-RegularSingleLinkFile -Path $backupPath)
        Set-ExactFileAcl -Path $backupPath -AllowUsersReadExecute $false
        return $backupPath
    }
    finally {
        if ($null -ne $backupStream) { $backupStream.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        Remove-SafeTemporaryFile -Path $temporaryBackupPath
    }
}

function Assert-RegularConfigFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Assert-RegularSingleLinkFile -Path $Path
}

function Write-Config {
    param(
        [string]$ConfigPath,
        [string]$FirstStartTime
    )

    $fullConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $configDirectory = [System.IO.Path]::GetDirectoryName($fullConfigPath)
    Assert-SafeDirectory -Path $configDirectory

    $data = @{}
    $configItem = Get-Item -LiteralPath $fullConfigPath -Force -ErrorAction SilentlyContinue
    $configExists = $null -ne $configItem
    if ($configExists) {
        $configFile = Assert-RegularConfigFile -Path $fullConfigPath
        $invalidReason = $null
        try {
            if ($configFile.Length -gt 1MB) {
                throw "配置文件超过 1 MiB 上限"
            }
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $existingJson = [System.IO.File]::ReadAllText($fullConfigPath, $strictUtf8)
            $existingObject = $existingJson | ConvertFrom-Json -ErrorAction Stop
            if (
                $null -eq $existingObject -or
                ($existingObject -isnot [System.Collections.IDictionary] -and
                 $existingObject -isnot [System.Management.Automation.PSCustomObject])
            ) {
                throw "配置根节点必须是 JSON 对象"
            }
            $data = ConvertTo-ShallowHashtable -InputObject $existingObject
        }
        catch {
            $invalidReason = $_.Exception.Message
        }

        if ($null -ne $invalidReason) {
            [void](Backup-ConfigFile -SourcePath $fullConfigPath)
            throw "现有配置无效，已安全备份；原文件未修改。"
        }
    }

    $data["installMethod"] = "native"
    $data["autoUpdates"] = $false
    $data["autoUpdatesProtectedForNative"] = $true
    $data["hasCompletedOnboarding"] = $true
    if (-not $data.ContainsKey("firstStartTime")) {
        $data["firstStartTime"] = $FirstStartTime
    }

    $json = $data | ConvertTo-Json -Depth 10 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $tempPath = Join-Path $configDirectory ".$([System.IO.Path]::GetFileName($fullConfigPath)).$([Guid]::NewGuid().ToString('N')).tmp"
    $tempStream = $null
    try {
        Assert-SafeDirectory -Path $configDirectory
        $bytes = $utf8NoBom.GetBytes($json)
        $tempStream = New-Object System.IO.FileStream(
            $tempPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $tempStream.Write($bytes, 0, $bytes.Length)
        $tempStream.Flush($true)
        $tempStream.Dispose()
        $tempStream = $null
        [void](Assert-RegularSingleLinkFile -Path $tempPath)

        if ($configExists) {
            [void](Assert-RegularConfigFile -Path $fullConfigPath)
            [void](Backup-ConfigFile -SourcePath $fullConfigPath)
            Assert-SafeDirectory -Path $configDirectory
            [void](Assert-RegularConfigFile -Path $fullConfigPath)
            [void](Assert-RegularSingleLinkFile -Path $tempPath)
            [System.IO.File]::Replace($tempPath, $fullConfigPath, $null, $true)
        } else {
            Assert-SafeDirectory -Path $configDirectory
            if ($null -ne (Get-Item -LiteralPath $fullConfigPath -Force -ErrorAction SilentlyContinue)) {
                throw "配置目标在写入期间已出现"
            }
            [System.IO.File]::Move($tempPath, $fullConfigPath)
        }
    }
    finally {
        if ($null -ne $tempStream) { $tempStream.Dispose() }
        Remove-SafeTemporaryFile -Path $tempPath
    }
}

function Get-HttpsResponse {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutMs = 60000
    )

    $currentUrl = $Url
    for ($redirectCount = 0; $redirectCount -le 5; $redirectCount++) {
        Assert-DownloadUrl -Url $currentUrl
        $request = [System.Net.HttpWebRequest]::Create($currentUrl)
        $request.Method = "GET"
        $request.AllowAutoRedirect = $false
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.UserAgent = "cc-custom-installer"
        $response = $null
        try {
            $response = $request.GetResponse()
        }
        catch [System.Net.WebException] {
            if ($null -eq $_.Exception.Response) { throw }
            $response = $_.Exception.Response
        }

        $statusCode = [int]$response.StatusCode
        if ($statusCode -eq 200) {
            return $response
        }

        if ($statusCode -in @(301, 302, 303, 307, 308)) {
            $location = $response.Headers[[System.Net.HttpResponseHeader]::Location]
            $response.Dispose()
            if ([string]::IsNullOrWhiteSpace($location) -or $location.Length -gt 2048) {
                throw "重定向地址无效"
            }
            try {
                $currentUrl = (New-Object System.Uri((New-Object System.Uri($currentUrl)), $location)).AbsoluteUri
            }
            catch {
                throw "重定向地址无效"
            }
            Assert-DownloadUrl -Url $currentUrl
            continue
        }

        $response.Dispose()
        throw "下载请求返回 HTTP $statusCode"
    }
    throw "重定向次数超过上限"
}

function Read-BoundedResponseBytes {
    param(
        [Parameter(Mandatory = $true)][System.Net.WebResponse]$Response,
        [Parameter(Mandatory = $true)][int64]$MaxBytes
    )

    if ($Response.ContentLength -gt $MaxBytes) {
        throw "远程内容超过允许的大小上限"
    }

    $inputStream = $null
    $memoryStream = New-Object System.IO.MemoryStream
    try {
        $inputStream = $Response.GetResponseStream()
        $buffer = New-Object byte[] 8192
        [int64]$total = 0
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaxBytes) {
                throw "远程内容超过允许的大小上限"
            }
            $memoryStream.Write($buffer, 0, $read)
        }
        return $memoryStream.ToArray()
    }
    finally {
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        $memoryStream.Dispose()
    }
}

function Get-RemoteText {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][int64]$MaxBytes
    )

    $response = $null
    try {
        $response = Get-HttpsResponse -Url $Url
        $bytes = Read-BoundedResponseBytes -Response $response -MaxBytes $MaxBytes
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $strictUtf8.GetString($bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            $text = $text.Substring(1)
        }
        return $text
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Get-NpmArchiveUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Platform
    )
    # npmmirror 平台子包命名与 GCS 平台标识一致（win32-x64 / win32-arm64）。
    return "$NPM_MIRROR_BASE/@anthropic-ai/claude-code-$Platform/-/claude-code-$Platform-$Version.tgz"
}

# 解析大文件最终地址：用 Range 0-0 逐跳跟随 302（npmmirror 注册表跳到 CDN），每一跳都重新做白名单校验。
# 不直接 GET 全量，避免只为拿最终 URL 就触发整文件传输。
function Resolve-FinalDownloadUrl {
    param([Parameter(Mandatory = $true)][string]$StartUrl)

    $currentUrl = $StartUrl
    for ($redirectCount = 0; $redirectCount -le 5; $redirectCount++) {
        Assert-DownloadUrl -Url $currentUrl
        $request = [System.Net.HttpWebRequest]::Create($currentUrl)
        $request.Method = "GET"
        $request.AllowAutoRedirect = $false
        $request.Timeout = 15000
        $request.ReadWriteTimeout = 15000
        $request.AddRange(0, 0) | Out-Null

        $response = $null
        try {
            $response = $request.GetResponse()
            $statusCode = [int]$response.StatusCode
            if ($statusCode -in @(301, 302, 303, 307, 308)) {
                $location = $response.Headers[[System.Net.HttpResponseHeader]::Location]
                $response.Close()
                if ([string]::IsNullOrWhiteSpace($location) -or $location.Length -gt 2048) {
                    throw "重定向地址无效"
                }
                $currentUrl = (New-Object System.Uri((New-Object System.Uri($currentUrl)), $location)).AbsoluteUri
                continue
            }
            $response.Close()
            return $currentUrl
        }
        finally {
            if ($null -ne $response) { try { $response.Close() } catch { } }
        }
    }
    throw "重定向次数超过上限"
}

# 分块 Range 下载 + 硬看门狗：
#  - 8MB 一块，每块是独立请求；连接超时 15s，首块读超时 45s（容忍 CDN 回源冷启动），其余块 25s。
#    完全停滞（无字节）时最多 25~45s 即抛错，由上层切换下载源，不再无限等待。
#  - 首字节到达后启用滑动速度窗口：每 20s 必须收到至少 6MB（约 300KB/s），持续低速立即判慢切源。
#  - 总时长 15 分钟封顶，并强制不超过 HardMaxBytes。
# 官方裸二进制传 ExactSize 做精确大小校验；镜像归档（.tgz，体积更小）传 ExactSize=0，仅做上限与解包后校验。
function Save-ChunkedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int64]$HardMaxBytes,
        [int64]$ExactSize = 0
    )

    Assert-DownloadUrl -Url $Url
    $destinationDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Destination))
    Assert-SafeDirectory -Path $destinationDirectory
    if ($null -ne (Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue)) {
        throw "下载临时文件已存在"
    }

    $chunkSize = [int64]8 * 1024 * 1024
    $connectMs = 15000
    $firstChunkReadMs = 45000
    $chunkReadMs = 25000
    $speedWindowMs = 20000
    $speedWindowBytes = [int64]6 * 1024 * 1024
    $totalDeadlineMs = 900000

    $finalUrl = Resolve-FinalDownloadUrl -StartUrl $Url
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $outputStream = $null
    try {
        $outputStream = New-Object System.IO.FileStream(
            $Destination,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        [int64]$total = 0
        [int64]$start = 0
        [bool]$firstChunk = $true
        [bool]$firstByteSeen = $false
        [int64]$windowAnchorMs = 0
        [int64]$windowAnchorBytes = 0
        $buffer = New-Object byte[] 65536
        $done = $false

        while (-not $done) {
            [int64]$end = $start + $chunkSize - 1
            $request = [System.Net.HttpWebRequest]::Create($finalUrl)
            $request.Method = "GET"
            $request.AllowAutoRedirect = $false
            $request.Timeout = $connectMs
            if ($firstChunk) { $request.ReadWriteTimeout = $firstChunkReadMs }
            else { $request.ReadWriteTimeout = $chunkReadMs }
            $request.AddRange($start, $end) | Out-Null

            $response = $null
            [int64]$thisChunk = 0
            try {
                $response = $request.GetResponse()
                $statusCode = [int]$response.StatusCode
                # 206=分块；200=服务器忽略 Range 返回全量，则读完这一响应即结束。
                $fullEntity = ($statusCode -eq 200)
                if ($statusCode -ne 206 -and -not $fullEntity) {
                    throw "下载请求返回 HTTP $statusCode"
                }
                $inputStream = $response.GetResponseStream()
                while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $outputStream.Write($buffer, 0, $read)
                    $total += $read
                    $thisChunk += $read
                    if ($total -gt $HardMaxBytes) { throw "下载文件超过大小上限" }
                    $elapsed = $watch.ElapsedMilliseconds
                    if ($elapsed -gt $totalDeadlineMs) { throw "下载总时长超过上限" }

                    if (-not $firstByteSeen) {
                        # 首个字节之前（CDN 回源冷启动）不做低速判定，只靠首块读超时兜底。
                        $firstByteSeen = $true
                        $windowAnchorMs = $elapsed
                        $windowAnchorBytes = $total
                    }
                    elseif ($elapsed - $windowAnchorMs -ge $speedWindowMs) {
                        if (($total - $windowAnchorBytes) -lt $speedWindowBytes) {
                            throw "下载速度持续过低，切换下载源"
                        }
                        $windowAnchorMs = $elapsed
                        $windowAnchorBytes = $total
                    }
                }
            }
            finally {
                if ($null -ne $response) { try { $response.Close() } catch { } }
            }

            if ($thisChunk -le 0) { throw "下载未收到数据" }
            if ($fullEntity) { $done = $true; break }
            $start += $thisChunk
            if ($thisChunk -lt $chunkSize) { $done = $true; break }
            $firstChunk = $false
        }

        $outputStream.Flush($true)
    }
    catch {
        if ($null -ne $outputStream) { try { $outputStream.Dispose() } catch { } }
        Remove-SafeTemporaryFile -Path $Destination
        throw
    }
    finally {
        if ($null -ne $outputStream) { try { $outputStream.Dispose() } catch { } }
    }

    $actualSize = (Get-Item -LiteralPath $Destination -Force -ErrorAction Stop).Length
    if ($actualSize -le 0) {
        Remove-SafeTemporaryFile -Path $Destination
        throw "下载内容为空"
    }
    if ($ExactSize -gt 0 -and $actualSize -ne $ExactSize) {
        Remove-SafeTemporaryFile -Path $Destination
        throw "下载文件大小校验失败"
    }
    [void](Assert-RegularSingleLinkFile -Path $Destination)
    Set-ExactFileAcl -Path $Destination -AllowUsersReadExecute $true
}

function Save-NpmArchiveBinary {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int64]$ExpectedSize
    )

    Assert-DownloadUrl -Url $Url
    $destinationDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Destination))
    Assert-SafeDirectory -Path $destinationDirectory

    $archive = "$Destination.tgz"
    $extractDir = Join-Path $destinationDirectory (".npm-extract-" + [Guid]::NewGuid().ToString("N"))
    try {
        # 归档为 gzip 压缩包，体积小于二进制；用二进制预期大小作为下载上限，精确大小在解包后校验。
        if (Test-Path -LiteralPath $archive) { Remove-SafeTemporaryFile -Path $archive }
        Save-ChunkedFile -Url $Url -Destination $archive -HardMaxBytes $ExpectedSize

        # Windows 10 1803+ / Windows 11 自带 bsdtar（System32\tar.exe），支持解包 .tgz。
        $tarExe = Join-Path $env:SystemRoot "System32\tar.exe"
        if (-not (Test-Path -LiteralPath $tarExe -PathType Leaf)) {
            throw "未找到系统 tar.exe，无法解包镜像归档"
        }
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        # 仅解包固定成员 package/claude.exe；成员名写死，不含路径穿越字符。
        & $tarExe -xzf $archive -C $extractDir "package/claude.exe" 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "镜像归档解包失败（tar 退出码 $LASTEXITCODE）"
        }
        $inner = Join-Path $extractDir "package\claude.exe"
        if (-not (Test-Path -LiteralPath $inner -PathType Leaf)) {
            throw "镜像归档中缺少 claude.exe"
        }
        $innerSize = (Get-Item -LiteralPath $inner -Force).Length
        if ($innerSize -ne $ExpectedSize) {
            throw "解包二进制大小校验失败"
        }
        Move-Item -LiteralPath $inner -Destination $Destination -Force
        [void](Assert-RegularSingleLinkFile -Path $Destination)
        Set-ExactFileAcl -Path $Destination -AllowUsersReadExecute $true
    }
    catch {
        Remove-SafeTemporaryFile -Path $Destination
        throw
    }
    finally {
        try { Remove-SafeTemporaryFile -Path $archive } catch { }
        try {
            if (Test-Path -LiteralPath $extractDir) {
                Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}

function Save-ClaudeBinaryWithSources {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][int64]$ExpectedSize,
        [Parameter(Mandatory = $true)][string]$ExpectedSha,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $gcsSource = [pscustomobject]@{
        Kind = 'gcs'
        Name = '官方 GCS 源'
        Url  = "$GCS_BUCKET/$Version/$Platform/claude.exe"
    }
    $npmSource = [pscustomobject]@{
        Kind = 'npm'
        Name = 'npmmirror 国内镜像'
        Url  = (Get-NpmArchiveUrl -Version $Version -Platform $Platform)
    }
    # 官方源优先：先尝试官方 GCS。分块下载器对每个源做连接超时、无数据超时与持续低速判定，
    # 官方源不可达或速度持续过低时会在几十秒内自动切换到 npmmirror 国内镜像（二进制逐字节一致、仍强制 SHA256）。
    $sources = @($gcsSource, $npmSource)

    $lastError = $null
    foreach ($source in $sources) {
        try {
            Write-Output "[INFO] 尝试下载源：$($source.Name)"
            if (Test-Path -LiteralPath $Destination) {
                Remove-SafeTemporaryFile -Path $Destination
            }
            if ($source.Kind -eq 'gcs') {
                Save-ChunkedFile -Url $source.Url -Destination $Destination -HardMaxBytes $ExpectedSize -ExactSize $ExpectedSize
            } else {
                Save-NpmArchiveBinary -Url $source.Url -Destination $Destination -ExpectedSize $ExpectedSize
            }

            $actualChecksum = Get-FileHashWithRetry -Path $Destination -Algorithm SHA256
            if ($actualChecksum -cne $ExpectedSha.ToLowerInvariant()) {
                throw "SHA256 校验失败"
            }
            Write-Output "[OK] 已从$($source.Name)下载，文件大小与 SHA256 校验通过"
            return
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Warning "[WARN] $($source.Name) 下载或校验失败：$lastError，尝试下一来源"
            try { Remove-SafeTemporaryFile -Path $Destination } catch { }
        }
    }
    throw "所有下载源均失败：$lastError"
}

# 安装包内置离线二进制（最终兜底）：仅当图形安装器通过 CLAUDE_BUNDLED_BINARY 传入、
# 且文件大小与 SHA256 与当前平台固定版本完全一致时才复制使用；任何不匹配一律拒绝。
# 安全锚点是 SHA256：即使路径异常，内容哈希不符也不会安装。
function Try-CopyBundledBinary {
    param([Parameter(Mandatory = $true)][string]$Destination)

    $bundled = [string]$env:CLAUDE_BUNDLED_BINARY
    if ([string]::IsNullOrWhiteSpace($bundled) -or $bundled.Length -gt 32767) { return $false }
    if ($bundled.IndexOfAny([char[]](0..31 + 127)) -ge 0) { return $false }

    $full = $null
    try {
        $full = [System.IO.Path]::GetFullPath($bundled)
        if (-not [System.IO.Path]::IsPathRooted($full)) { return $false }
    } catch { return $false }

    $fallback = $PINNED_FALLBACKS[$platform]
    if ($null -eq $fallback) { return $false }

    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not ($item -is [System.IO.FileInfo]) `
        -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return $false
    }
    if ($item.Length -ne [int64]$fallback.Size) { return $false }

    $actual = Get-FileHashWithRetry -Path $full -Algorithm SHA256
    if ($actual -cne ([string]$fallback.Sha256).ToLowerInvariant()) { return $false }

    if (Test-Path -LiteralPath $Destination) { Remove-SafeTemporaryFile -Path $Destination }
    Copy-Item -LiteralPath $full -Destination $Destination -Force
    [void](Assert-RegularSingleLinkFile -Path $Destination)
    Set-ExactFileAcl -Path $Destination -AllowUsersReadExecute $true
    return $true
}

function Install-PinnedFallback {
    Write-Warning "[WARN] 最新版本不可用，回退到固定版本（官方源优先，低速自动切镜像）"
    $fallback = $PINNED_FALLBACKS[$platform]
    if ($null -eq $fallback) {
        Write-Error "当前平台没有可用的固定版本"
        exit 1
    }
    Write-Output "[INFO] 版本: $PINNED_FALLBACK_VERSION（固定版本，强制校验大小与 SHA256）"

    $binaryPath = Join-Path $DOWNLOADS_DIR ".claude-$PINNED_FALLBACK_VERSION-$platform.$([Guid]::NewGuid().ToString('N')).part"
    try {
        # 进入固定版本兜底意味着官方版本服务已不可达；内置副本与固定版本同版本、同哈希，
        # 优先直接使用本地内置版本，避免在慢/断网络上空等下载。
        if (Try-CopyBundledBinary -Destination $binaryPath) {
            Write-Output "[INFO] 使用安装包内置离线版本 $PINNED_FALLBACK_VERSION（已通过大小与 SHA256 校验），跳过网络下载"
        } else {
            # 无内置副本（如 ARM64 或远程脚本）时才走网络：官方源优先、低速切镜像。
            try {
                Save-ClaudeBinaryWithSources -Version $PINNED_FALLBACK_VERSION -Platform $platform `
                    -ExpectedSize ([int64]$fallback.Size) -ExpectedSha ([string]$fallback.Sha256) `
                    -Destination $binaryPath
            } catch {
                # 官方源与国内镜像均失败（含低速中止）时，最后再尝试安装包内置离线二进制。
                Write-Warning "[WARN] 网络下载源均失败：$($_.Exception.Message)"
                if (-not (Try-CopyBundledBinary -Destination $binaryPath)) { throw }
                Write-Warning "[WARN] 已改用安装包内置离线版本 $PINNED_FALLBACK_VERSION"
            }
        }

        $finalPath = "$VERSIONS_DIR\$PINNED_FALLBACK_VERSION.exe"
        Publish-VerifiedBinary -SourcePath $binaryPath -DestinationPath $finalPath -ExpectedChecksum ([string]$fallback.Sha256)
        Publish-VerifiedBinary -SourcePath $finalPath -DestinationPath $LINK_PATH -ExpectedChecksum ([string]$fallback.Sha256)

        $firstStartTime = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        Write-Config -ConfigPath $CONFIG_PATH -FirstStartTime $firstStartTime

        Add-MachinePath -Dir $BIN_DIR

        Write-Output ""
        Write-Output "Claude Code 安装成功！（固定版本）"
        Write-Output "版本：$PINNED_FALLBACK_VERSION（固定版本）"
        Write-Output "位置：$LINK_PATH"
        Write-Output "已配置系统 PATH：$BIN_DIR"
    } catch {
        Write-Error "固定版本下载或完整性校验失败：$($_.Exception.Message)"
        try { Remove-SafeTemporaryFile -Path $binaryPath } catch { }
        exit 1
    } finally {
        try { Remove-SafeTemporaryFile -Path $binaryPath } catch { }
    }
}

function Add-MachinePath {
    param([string]$Dir)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (-not $current) { $current = '' }
    $parts = $current.Split(';') | Where-Object { $_ -and $_.Trim() -ne '' }
    if ($parts -icontains $Dir) {
        Write-Output "系统 PATH 已包含 $Dir，跳过"
        return
    }
    $newPath = ($parts + $Dir) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
    Write-Output "已把 $Dir 追加到系统 PATH"

    # 广播 WM_SETTINGCHANGE，让新终端立即生效
    $sig = @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int Msg, IntPtr wParam, string lParam, int fuFlags, int uTimeout, out IntPtr lpdwResult);
'@
    try {
        $type = Add-Type -MemberDefinition $sig -Namespace Win32 -Name NativeMethods -PassThru -ErrorAction Stop
        [IntPtr]$r = [IntPtr]::Zero
        [void]$type::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, "Environment", 2, 5000, [ref]$r)
    } catch {
        Write-Warning "PATH 广播失败（下次登录会自动生效）"
    }
}

function Assert-SafeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $directory = New-Object System.IO.DirectoryInfo([System.IO.Path]::GetFullPath($Path))
    while ($null -ne $directory) {
        $item = Get-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            throw "目录路径无效：$($directory.FullName)"
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "目录路径不能包含重解析点：$($directory.FullName)"
        }
        $directory = $directory.Parent
    }
}

$ADMINISTRATORS_SID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$SYSTEM_SID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
$USERS_SID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-545")

function Get-CcCustomNative {
    $nativeType = "CcCustom.Native" -as [type]
    if ($null -ne $nativeType) {
        return $nativeType
    }

    $nativeDefinition = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CcCustom {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        public struct BY_HANDLE_FILE_INFORMATION {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out BY_HANDLE_FILE_INFORMATION fileInformation);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool MoveFileEx(
            string existingFileName,
            string newFileName,
            uint flags);
    }
}
'@
    [void](Add-Type -TypeDefinition $nativeDefinition -ErrorAction Stop)
    $nativeType = "CcCustom.Native" -as [type]
    if ($null -eq $nativeType) {
        throw "无法初始化文件安全检查"
    }
    return $nativeType
}

function Get-FileLinkInformation {
    param([Parameter(Mandatory = $true)][string]$Path)

    $native = Get-CcCustomNative
    $handle = $null
    try {
        $handle = $native::CreateFile(
            $Path,
            [uint32]2147483648,
            [uint32]1,
            [IntPtr]::Zero,
            [uint32]3,
            [uint32]0x00200000,
            [IntPtr]::Zero
        )
        if ($null -eq $handle -or $handle.IsInvalid) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "无法安全打开文件，Win32 错误：$errorCode"
        }
        return Get-HandleFileInformation -Handle $handle
    }
    finally {
        if ($null -ne $handle) { $handle.Dispose() }
    }
}

function Get-HandleFileInformation {
    param([Parameter(Mandatory = $true)][object]$Handle)

    $native = Get-CcCustomNative
    $informationType = "CcCustom.Native+BY_HANDLE_FILE_INFORMATION" -as [type]
    $information = [Activator]::CreateInstance($informationType)
    if (-not $native::GetFileInformationByHandle($Handle, [ref]$information)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "无法读取文件链接信息，Win32 错误：$errorCode"
    }
    return $information
}

function Open-SafeDirectoryHandle {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    Assert-SafeDirectory -Path ([System.IO.Path]::GetDirectoryName($fullPath))
    $native = Get-CcCustomNative
    $handle = $null
    try {
        # 不共享 DELETE，避免在 ACL 重置和验证期间将已检查目录替换为联接点。
        $handle = $native::CreateFile(
            $fullPath,
            [uint32]2147483648,
            [uint32]3,
            [IntPtr]::Zero,
            [uint32]3,
            [uint32]0x02200000,
            [IntPtr]::Zero
        )
        if ($null -eq $handle -or $handle.IsInvalid) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "无法安全打开目录，Win32 错误：$errorCode"
        }
        $information = Get-HandleFileInformation -Handle $handle
        if (
            ($information.FileAttributes -band [uint32]0x10) -eq 0 -or
            ($information.FileAttributes -band [uint32]0x400) -ne 0
        ) {
            throw "目录路径不能是重解析点或普通文件：$fullPath"
        }
        $result = $handle
        $handle = $null
        return $result
    }
    finally {
        if ($null -ne $handle) { $handle.Dispose() }
    }
}

function Assert-RegularSingleLinkFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parentPath = [System.IO.Path]::GetDirectoryName($fullPath)
    Assert-SafeDirectory -Path $parentPath
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "文件路径不能是目录：$fullPath"
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "文件路径不能是重解析点：$fullPath"
    }

    $information = Get-FileLinkInformation -Path $fullPath
    if (($information.FileAttributes -band [uint32]0x400) -ne 0) {
        throw "文件路径不能是重解析点：$fullPath"
    }
    if ($information.NumberOfLinks -ne 1) {
        throw "文件路径不能是硬链接：$fullPath"
    }
    return $item
}

function Get-ExpectedAclSignature {
    param(
        [Parameter(Mandatory = $true)][System.Security.Principal.SecurityIdentifier]$Sid,
        [Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemRights]$Rights,
        [Parameter(Mandatory = $true)][System.Security.AccessControl.InheritanceFlags]$InheritanceFlags
    )

    return "$($Sid.Value)|$([int]$Rights)|$([int]$InheritanceFlags)|0|0"
}

function Assert-ExactFileSystemAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$IsDirectory,
        [Parameter(Mandatory = $true)][bool]$AllowUsersReadExecute
    )

    $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor `
        [System.Security.AccessControl.AccessControlSections]::Owner
    if ($IsDirectory) {
        Assert-SafeDirectory -Path $Path
        $security = [System.IO.Directory]::GetAccessControl($Path, $sections)
        $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [void](Assert-RegularSingleLinkFile -Path $Path)
        $security = [System.IO.File]::GetAccessControl($Path, $sections)
        $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::None
    }

    if (-not $security.AreAccessRulesProtected) {
        throw "ACL 仍在继承父目录权限：$Path"
    }
    $owner = $security.GetOwner([System.Security.Principal.SecurityIdentifier])
    if ($owner.Value -ne $ADMINISTRATORS_SID.Value) {
        throw "ACL 所有者不是 Administrators：$Path"
    }

    $expected = @{}
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    # .NET 会为允许型文件系统 ACE 自动补充 Synchronize；按落盘后的规范化掩码校验。
    $readExecute = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor `
        [System.Security.AccessControl.FileSystemRights]::Synchronize
    $expected[(Get-ExpectedAclSignature -Sid $ADMINISTRATORS_SID -Rights $fullControl -InheritanceFlags $inheritanceFlags)] = 1
    $expected[(Get-ExpectedAclSignature -Sid $SYSTEM_SID -Rights $fullControl -InheritanceFlags $inheritanceFlags)] = 1
    if ($AllowUsersReadExecute) {
        $expected[(Get-ExpectedAclSignature -Sid $USERS_SID -Rights $readExecute -InheritanceFlags $inheritanceFlags)] = 1
    }

    $rules = @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne $expected.Count) {
        throw "ACL 包含未预期的访问控制项：$Path"
    }
    foreach ($rule in $rules) {
        if ($rule.IsInherited -or $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            throw "ACL 包含未预期的访问控制项：$Path"
        }
        $signature = "$($rule.IdentityReference.Value)|$([int]$rule.FileSystemRights)|$([int]$rule.InheritanceFlags)|$([int]$rule.PropagationFlags)|$([int]$rule.AccessControlType)"
        if (-not $expected.ContainsKey($signature) -or $expected[$signature] -ne 1) {
            throw "ACL 包含未预期的访问控制项：$Path"
        }
        $expected[$signature] = 0
    }
    foreach ($signature in $expected.Keys) {
        if ($expected[$signature] -ne 0) {
            throw "ACL 缺少必要的访问控制项：$Path"
        }
    }
}

function Set-ExactDirectoryAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$AllowUsersReadExecute
    )

    Assert-SafeDirectory -Path $Path
    $directoryHandle = Open-SafeDirectoryHandle -Path $Path
    try {
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetAccessRuleProtection($true, $false)
        $security.SetOwner($ADMINISTRATORS_SID)
        $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
        [void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $ADMINISTRATORS_SID,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritanceFlags,
            $propagationFlags,
            [System.Security.AccessControl.AccessControlType]::Allow
        )))
        [void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $SYSTEM_SID,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritanceFlags,
            $propagationFlags,
            [System.Security.AccessControl.AccessControlType]::Allow
        )))
        if ($AllowUsersReadExecute) {
            [void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $USERS_SID,
                [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
                $inheritanceFlags,
                $propagationFlags,
                [System.Security.AccessControl.AccessControlType]::Allow
            )))
        }
        [System.IO.Directory]::SetAccessControl($Path, $security)
        Assert-ExactFileSystemAcl -Path $Path -IsDirectory $true -AllowUsersReadExecute $AllowUsersReadExecute
    }
    finally {
        $directoryHandle.Dispose()
    }
}

function Set-ExactFileAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$AllowUsersReadExecute
    )

    [void](Assert-RegularSingleLinkFile -Path $Path)
    $security = New-Object System.Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($ADMINISTRATORS_SID)
    $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::None
    $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
    [void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $ADMINISTRATORS_SID,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritanceFlags,
        $propagationFlags,
        [System.Security.AccessControl.AccessControlType]::Allow
    )))
    [void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $SYSTEM_SID,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritanceFlags,
        $propagationFlags,
        [System.Security.AccessControl.AccessControlType]::Allow
    )))
    if ($AllowUsersReadExecute) {
        [void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $USERS_SID,
            [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritanceFlags,
            $propagationFlags,
            [System.Security.AccessControl.AccessControlType]::Allow
        )))
    }
    [System.IO.File]::SetAccessControl($Path, $security)
    Assert-ExactFileSystemAcl -Path $Path -IsDirectory $false -AllowUsersReadExecute $AllowUsersReadExecute
}

function Test-BackupPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $backupPath = [System.IO.Path]::GetFullPath($BACKUPS_DIR).TrimEnd('\')
    return $fullPath.Equals($backupPath, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($backupPath + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Initialize-SafeProgramDataDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $programDataRoot = [System.IO.Path]::GetFullPath($PROGRAM_DATA_ROOT).TrimEnd('\')
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (
        -not $fullPath.Equals($programDataRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not $fullPath.StartsWith($programDataRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "安装路径必须位于 ProgramData 下"
    }

    Assert-SafeDirectory -Path $programDataRoot
    $currentPath = $programDataRoot
    $relativePath = $fullPath.Substring($programDataRoot.Length).TrimStart('\')
    if ($relativePath.Length -gt 0) {
        foreach ($part in $relativePath.Split('\')) {
            if ($part.Length -eq 0 -or $part -eq '.' -or $part -eq '..') {
                throw "安装路径包含无效目录段"
            }
            $currentPath = Join-Path $currentPath $part
            $currentItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $currentItem) {
                Assert-SafeDirectory -Path $currentPath
            } else {
                Assert-SafeDirectory -Path ([System.IO.Path]::GetDirectoryName($currentPath))
                [void][System.IO.Directory]::CreateDirectory($currentPath)
                Assert-SafeDirectory -Path $currentPath
            }
            # 新建或接管现有目录后立刻收紧，后续创建子目录不会继承攻击者 ACL。
            Set-ExactDirectoryAcl -Path $currentPath -AllowUsersReadExecute (-not (Test-BackupPath -Path $currentPath))
        }
    }
    Assert-SafeDirectory -Path $fullPath
}

function Set-DirectoryTreeAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$AllowUsersReadExecute
    )

    $pendingDirectories = New-Object "System.Collections.Generic.Stack[string]"
    $pendingDirectories.Push([System.IO.Path]::GetFullPath($Path))
    while ($pendingDirectories.Count -gt 0) {
        $currentPath = $pendingDirectories.Pop()
        Assert-SafeDirectory -Path $currentPath
        Set-ExactDirectoryAcl -Path $currentPath -AllowUsersReadExecute $AllowUsersReadExecute
        $children = @(Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction Stop)
        foreach ($child in $children) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "安装目录不能包含重解析点：$($child.FullName)"
            }
            if ($child.PSIsContainer) {
                $pendingDirectories.Push($child.FullName)
            } else {
                [void](Assert-RegularSingleLinkFile -Path $child.FullName)
                Set-ExactFileAcl -Path $child.FullName -AllowUsersReadExecute $AllowUsersReadExecute
            }
        }
    }
}

function Set-StrictInstallAcl {
    # 从空 DirectorySecurity/FileSecurity 重建 DACL，避免保留未知显式 ACE。
    Set-ExactDirectoryAcl -Path $INSTALL_BASE -AllowUsersReadExecute $true
    foreach ($directory in @(
        $VERSIONS_DIR,
        $BIN_DIR,
        (Join-Path $INSTALL_BASE "state"),
        $DOWNLOADS_DIR
    )) {
        Set-DirectoryTreeAcl -Path $directory -AllowUsersReadExecute $true
    }
    Set-DirectoryTreeAcl -Path $BACKUPS_DIR -AllowUsersReadExecute $false
}

function Remove-SafeTemporaryFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        [void](Assert-RegularSingleLinkFile -Path $Path)
        [System.IO.File]::Delete($Path)
    }
}

function Publish-VerifiedBinary {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedChecksum
    )

    $fullSourcePath = [System.IO.Path]::GetFullPath($SourcePath)
    $fullDestinationPath = [System.IO.Path]::GetFullPath($DestinationPath)
    $destinationDirectory = [System.IO.Path]::GetDirectoryName($fullDestinationPath)
    Assert-SafeDirectory -Path $destinationDirectory
    [void](Assert-RegularSingleLinkFile -Path $fullSourcePath)

    $stagePath = Join-Path $destinationDirectory ".$([System.IO.Path]::GetFileName($fullDestinationPath)).$([Guid]::NewGuid().ToString('N')).staging"
    $sourceStream = $null
    $stageStream = $null
    try {
        Assert-SafeDirectory -Path $destinationDirectory
        $sourceStream = New-Object System.IO.FileStream(
            $fullSourcePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        Assert-SafeDirectory -Path $destinationDirectory
        $stageStream = New-Object System.IO.FileStream(
            $stagePath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $sourceStream.CopyTo($stageStream, 65536)
        $stageStream.Flush($true)
        $stageStream.Dispose()
        $stageStream = $null
        $sourceStream.Dispose()
        $sourceStream = $null

        [void](Assert-RegularSingleLinkFile -Path $fullSourcePath)
        [void](Assert-RegularSingleLinkFile -Path $stagePath)
        Set-ExactFileAcl -Path $stagePath -AllowUsersReadExecute $true
        $stageChecksum = Get-FileHashWithRetry -Path $stagePath -Algorithm SHA256
        if ($stageChecksum -cne $ExpectedChecksum.ToLowerInvariant()) {
            throw "安装暂存文件的 SHA256 校验失败"
        }

        Assert-SafeDirectory -Path $destinationDirectory
        $existingDestination = Get-Item -LiteralPath $fullDestinationPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $existingDestination) {
            [void](Assert-RegularSingleLinkFile -Path $fullDestinationPath)
        }
        [void](Assert-RegularSingleLinkFile -Path $stagePath)
        $native = Get-CcCustomNative
        # 同目录 MOVEFILE_REPLACE_EXISTING 是目录项原子替换，不会写入既有目标的内容。
        if (-not $native::MoveFileEx($stagePath, $fullDestinationPath, [uint32]9)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "无法原子发布安装文件，Win32 错误：$errorCode"
        }
        $stagePath = $null
        [void](Assert-RegularSingleLinkFile -Path $fullDestinationPath)
        Set-ExactFileAcl -Path $fullDestinationPath -AllowUsersReadExecute $true
    }
    finally {
        if ($null -ne $stageStream) { $stageStream.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        if ($null -ne $stagePath) { Remove-SafeTemporaryFile -Path $stagePath }
    }
}

$architectureHints = @(
    [string]$env:PROCESSOR_ARCHITEW6432,
    [string]$env:PROCESSOR_ARCHITECTURE
)
if ($architectureHints -contains "ARM64") {
    $platform = "win32-arm64"
} elseif ($architectureHints -contains "AMD64") {
    $platform = "win32-x64"
} else {
    Write-Error "仅支持 Windows x64 或 ARM64。"
    exit 1
}

foreach ($dir in @($VERSIONS_DIR, $BIN_DIR, $LOCKS_DIR, $CACHE_DIR, $DOWNLOADS_DIR, $BACKUPS_DIR)) {
    Initialize-SafeProgramDataDirectory -Path $dir
}
Set-StrictInstallAcl

# Windows 上下载器关闭句柄到 Defender/搜索索引挂载中间有几百毫秒窗口期，
# 直接 Get-FileHash 会碰到 "file is being used by another process"。带重试。
function Get-FileHashWithRetry {
    param([string]$Path, [string]$Algorithm = 'SHA256', [int]$MaxRetries = 10, [int]$DelayMs = 500)
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            return (Get-FileHash -Path $Path -Algorithm $Algorithm -ErrorAction Stop).Hash.ToLower()
        } catch {
            if ($i -eq $MaxRetries) { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

# ── 尝试从 GCS 获取版本号 ──
$version = $null
if ($Target -in @("latest", "stable")) {
    try {
        $version = (Get-RemoteText -Url "$GCS_BUCKET/latest" -MaxBytes 128).ToString().Trim()
    } catch {
        Write-Warning "[WARN] 无法获取 GCS 版本号"
    }
} else {
    $version = $Target
}

if ($version -and ($version.Length -gt 48 -or $version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]{1,32})?$')) {
    Write-Warning "[WARN] 版本号格式无效，将使用固定版本"
    $version = $null
}

if ($version) {
    # ── GCS 可达：正常流程（版本 → manifest → 二进制 → SHA256 校验） ──
    try {
        $manifestText = Get-RemoteText -Url "$GCS_BUCKET/$version/manifest.json" -MaxBytes 1MB
        if ($manifestText -is [string]) {
            $manifest = $manifestText | ConvertFrom-Json
        } else {
            $manifest = $manifestText
        }
        $checksum = ([string]$manifest.platforms.$platform.checksum).ToLowerInvariant()
        [int64]$expectedSize = 0
        if (
            $checksum -notmatch '^[0-9a-f]{64}$' -or
            -not [int64]::TryParse(([string]$manifest.platforms.$platform.size), [ref]$expectedSize) -or
            $expectedSize -lt 1MB -or
            $expectedSize -gt 1GB
        ) {
            Write-Warning "[WARN] manifest 中未包含平台 $platform，回退到固定版本"
            Install-PinnedFallback
            exit 0
        }
    } catch {
        Write-Warning "[WARN] 获取 manifest 失败，回退到固定版本"
        Install-PinnedFallback
        exit 0
    }

    $binaryPath = Join-Path $DOWNLOADS_DIR ".claude-$version-$platform.$([Guid]::NewGuid().ToString('N')).part"
    Write-Output "Claude Code 版本：$version"
    Write-Output "平台：$platform"
    Write-Output "正在下载 Claude Code 二进制…"

    try {
        # 官方 GCS 优先，npmmirror 国内镜像回退；任一来源下载后均强制大小与 SHA256 校验。
        Save-ClaudeBinaryWithSources -Version $version -Platform $platform `
            -ExpectedSize $expectedSize -ExpectedSha $checksum `
            -Destination $binaryPath
    } catch {
        Write-Warning "[WARN] 当前版本所有下载源均失败，回退到固定版本"
        try { Remove-SafeTemporaryFile -Path $binaryPath } catch { }
        Install-PinnedFallback
        exit 0
    }

    # ── 安装 ──
    Write-Output "开始安装 Claude Code…"
    try {
        $finalPath = "$VERSIONS_DIR\$version.exe"
        Publish-VerifiedBinary -SourcePath $binaryPath -DestinationPath $finalPath -ExpectedChecksum $checksum
        Publish-VerifiedBinary -SourcePath $finalPath -DestinationPath $LINK_PATH -ExpectedChecksum $checksum

        $firstStartTime = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        Write-Config -ConfigPath $CONFIG_PATH -FirstStartTime $firstStartTime

        Add-MachinePath -Dir $BIN_DIR

        Write-Output ""
        Write-Output "Claude Code 安装成功！"
        Write-Output "版本：$version"
        Write-Output "位置：$LINK_PATH"
        Write-Output "已写入 hasCompletedOnboarding=true 到 $CONFIG_PATH"
        Write-Output "已配置系统 PATH：$BIN_DIR"
    }
    finally {
        try { Remove-SafeTemporaryFile -Path $binaryPath } catch { }
    }
} else {
    # ── GCS 版本服务不可达：使用固定版本，官方源优先、低速自动切镜像并强制校验 ──
    Write-Warning "[WARN] 无法获取官方版本号，使用固定版本（官方源优先，低速自动切镜像）"
    Install-PinnedFallback
}

Write-Output ""
Write-Output "$([char]0x2705) 安装完成！新开终端后可直接执行 claude"
Write-Output ""
