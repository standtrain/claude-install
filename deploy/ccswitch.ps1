#Requires -Version 5.1

# CC Switch installer for Windows.
# Security checkpoints:
# - GitHub metadata, architecture, asset name, URL, size, and SHA256 are validated.
# - Only official GitHub release hosts are accepted; redirects are checked explicitly.
# - The MSI is stored only in a protected ProgramData directory with no reparse points.
# - The file is created once, hashed, identity-checked, and locked against replacement before msiexec.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw '[ERROR] 需要管理员权限。请以管理员身份打开 PowerShell 后重新执行安装命令。'
        }
    }
    finally {
        $identity.Dispose()
    }
}

Assert-Administrator

$GitHubApiUrl = 'https://api.github.com/repos/farion1231/cc-switch/releases/latest'
$PinnedVersion = 'v3.18.0'
$DownloadTimeoutSeconds = 180
$MinimumAssetSize = 1MB
$MaximumAssetSize = 512MB
$MaximumSourceUrlLength = 2048
$MaximumRedirectUrlLength = 4096
$MaximumRedirects = 5
$DownloadAttempts = 3
$PrivateDirectoryPrefix = 'ccswitch-'
$PrivateMsiName = 'CC-Switch.msi'

function Get-NativeArchitecture {
    $architectureHints = @(
        [string]$env:PROCESSOR_ARCHITEW6432,
        [string]$env:PROCESSOR_ARCHITECTURE
    )

    foreach ($hint in $architectureHints) {
        if ($hint -eq 'ARM64') {
            return 'arm64'
        }
    }

    foreach ($hint in $architectureHints) {
        if ($hint -eq 'AMD64') {
            return 'x64'
        }
    }

    return $null
}

function Assert-GitHubAssetUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$AssetName
    )

    if ($Url.Length -lt 1 -or $Url.Length -gt $MaximumSourceUrlLength) {
        throw 'INVALID_ASSET_URL'
    }

    [Uri]$uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        throw 'INVALID_ASSET_URL'
    }

    $expectedPath = "/farion1231/cc-switch/releases/download/$Tag/$AssetName"
    if (
        $uri.Scheme -cne 'https' -or
        $uri.DnsSafeHost -ine 'github.com' -or
        $uri.Port -ne 443 -or
        $uri.UserInfo.Length -ne 0 -or
        $uri.Query.Length -ne 0 -or
        $uri.Fragment.Length -ne 0 -or
        $uri.AbsolutePath -cne $expectedPath
    ) {
        throw 'INVALID_ASSET_URL'
    }

    return $uri
}

function Test-TrustedRedirectUri {
    param([Parameter(Mandatory = $true)][Uri]$Uri)

    if ($Uri.AbsoluteUri.Length -lt 1 -or $Uri.AbsoluteUri.Length -gt $MaximumRedirectUrlLength) {
        return $false
    }
    if ($Uri.Scheme -cne 'https' -or $Uri.Port -ne 443) {
        return $false
    }
    if ($Uri.UserInfo.Length -ne 0 -or $Uri.Fragment.Length -ne 0) {
        return $false
    }
    if ($Uri.AbsolutePath.Length -lt 1 -or $Uri.AbsolutePath.Length -gt 2048 -or $Uri.Query.Length -gt 2048) {
        return $false
    }

    $allowedHosts = @(
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com'
    )
    return $allowedHosts -icontains $Uri.DnsSafeHost
}

function New-PinnedSource {
    param([Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture)

    if ($Architecture -eq 'arm64') {
        $assetName = 'CC-Switch-v3.18.0-Windows-arm64.msi'
        $expectedSize = [int64]12156928
        $expectedSha256 = 'c8abd0b39cd6fe0d14637c1d1c66f39b79066aef3edf76bb7a5b3b5b57241e09'
    }
    else {
        $assetName = 'CC-Switch-v3.18.0-Windows.msi'
        $expectedSize = [int64]12849152
        $expectedSha256 = 'c4a6eaf763269396f90a81377381e91c8341538b51376912c81bab73e844612d'
    }

    $url = "https://github.com/farion1231/cc-switch/releases/download/$PinnedVersion/$assetName"
    [void](Assert-GitHubAssetUrl -Url $url -Tag $PinnedVersion -AssetName $assetName)

    return [pscustomobject]@{
        Version = $PinnedVersion
        AssetName = $assetName
        Url = $url
        ExpectedSize = $expectedSize
        ExpectedSha256 = $expectedSha256
        IsPinned = $true
    }
}

function Get-LatestGitHubSource {
    param([Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture)

    try {
        $headers = @{
            'Accept' = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        $release = Invoke-RestMethod `
            -Uri $GitHubApiUrl `
            -Headers $headers `
            -UserAgent 'CCSwitchInstaller/2.0' `
            -TimeoutSec 30 `
            -MaximumRedirection 0 `
            -ErrorAction Stop

        $tag = [string]$release.tag_name
        if ($tag.Length -lt 6 -or $tag.Length -gt 48 -or $tag -notmatch '^v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]{1,32})?$') {
            throw 'INVALID_RELEASE_TAG'
        }

        if ($Architecture -eq 'arm64') {
            $assetName = "CC-Switch-$tag-Windows-arm64.msi"
        }
        else {
            $assetName = "CC-Switch-$tag-Windows.msi"
        }

        if ($assetName.Length -gt 128) {
            throw 'INVALID_ASSET_NAME'
        }

        $asset = @($release.assets) |
            Where-Object { ([string]$_.name) -ceq $assetName } |
            Select-Object -First 1
        if ($null -eq $asset) {
            throw 'ASSET_NOT_FOUND'
        }

        [int64]$expectedSize = 0
        if (-not [int64]::TryParse(([string]$asset.size), [ref]$expectedSize)) {
            throw 'INVALID_ASSET_SIZE'
        }
        if ($expectedSize -lt $MinimumAssetSize -or $expectedSize -gt $MaximumAssetSize) {
            throw 'INVALID_ASSET_SIZE'
        }

        $digest = [string]$asset.digest
        if ($digest -notmatch '^sha256:([0-9A-Fa-f]{64})$') {
            throw 'INVALID_ASSET_DIGEST'
        }
        $expectedSha256 = $Matches[1].ToLowerInvariant()

        $url = [string]$asset.browser_download_url
        [void](Assert-GitHubAssetUrl -Url $url -Tag $tag -AssetName $assetName)

        return [pscustomobject]@{
            Version = $tag
            AssetName = $assetName
            Url = $url
            ExpectedSize = $expectedSize
            ExpectedSha256 = $expectedSha256
            IsPinned = $false
        }
    }
    catch {
        Write-Warning '[WARN] GitHub API 不可达或发布元数据无效，将使用经过固定校验的官方版本。'
        return $null
    }
}

function Invoke-HttpDownloadOnce {
    param(
        [Parameter(Mandatory = $true)][psobject]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$PrivateDirectory
    )

    Assert-PrivateInstallerFilePath -PrivateDirectory $PrivateDirectory -Path $Destination
    if ([int64]$Source.ExpectedSize -lt $MinimumAssetSize -or [int64]$Source.ExpectedSize -gt $MaximumAssetSize) {
        throw 'INVALID_ASSET_SIZE'
    }

    [Uri]$currentUri = Assert-GitHubAssetUrl `
        -Url ([string]$Source.Url) `
        -Tag ([string]$Source.Version) `
        -AssetName ([string]$Source.AssetName)

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($DownloadTimeoutSeconds)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('CCSwitchInstaller/2.0')

    $response = $null
    try {
        for ($redirectCount = 0; $redirectCount -le $MaximumRedirects; $redirectCount++) {
            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $currentUri)
            try {
                $response = $client.SendAsync(
                    $request,
                    [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                ).GetAwaiter().GetResult()
            }
            finally {
                $request.Dispose()
            }

            $statusCode = [int]$response.StatusCode
            if ($statusCode -in @(301, 302, 303, 307, 308)) {
                if ($redirectCount -eq $MaximumRedirects -or $null -eq $response.Headers.Location) {
                    throw 'TOO_MANY_REDIRECTS'
                }

                [Uri]$nextUri = $response.Headers.Location
                if (-not $nextUri.IsAbsoluteUri) {
                    $nextUri = New-Object Uri($currentUri, $nextUri)
                }
                if (-not (Test-TrustedRedirectUri -Uri $nextUri)) {
                    throw 'UNTRUSTED_REDIRECT'
                }

                $response.Dispose()
                $response = $null
                $currentUri = $nextUri
                continue
            }

            if ($statusCode -ne 200) {
                throw 'DOWNLOAD_HTTP_ERROR'
            }

            $contentLength = $response.Content.Headers.ContentLength
            if ($null -ne $contentLength -and [int64]$contentLength -ne [int64]$Source.ExpectedSize) {
                throw 'DOWNLOAD_SIZE_MISMATCH'
            }

            $inputStream = $null
            $outputStream = $null
            [int64]$totalBytes = 0
            try {
                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                Assert-PrivateInstallerFilePath -PrivateDirectory $PrivateDirectory -Path $Destination
                $outputStream = [System.IO.File]::Open(
                    $Destination,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None
                )
                $buffer = New-Object byte[] 131072
                while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $totalBytes += $bytesRead
                    if ($totalBytes -gt [int64]$Source.ExpectedSize) {
                        throw 'DOWNLOAD_SIZE_MISMATCH'
                    }
                    $outputStream.Write($buffer, 0, $bytesRead)
                }
            }
            finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                if ($null -ne $inputStream) { $inputStream.Dispose() }
            }

            if ($totalBytes -ne [int64]$Source.ExpectedSize) {
                throw 'DOWNLOAD_SIZE_MISMATCH'
            }
            Assert-PrivateInstallerFilePath -PrivateDirectory $PrivateDirectory -Path $Destination
            return
        }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-PathAttributesOrNull {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return [System.IO.File]::GetAttributes($Path)
    }
    catch [System.IO.FileNotFoundException] {
        return $null
    }
    catch [System.IO.DirectoryNotFoundException] {
        return $null
    }
}

function Assert-ExistingDirectoryWithoutReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $attributes = Get-PathAttributesOrNull -Path $Path
    if ($null -eq $attributes) {
        throw 'DIRECTORY_NOT_FOUND'
    }
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'REPARSE_POINT_REJECTED'
    }
    if (-not [System.IO.Directory]::Exists($Path)) {
        throw 'DIRECTORY_TYPE_INVALID'
    }
}

function Assert-ExistingDirectoryChainWithoutReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $currentPath = [System.IO.Path]::GetFullPath($Path)
    while ($true) {
        Assert-ExistingDirectoryWithoutReparsePoint -Path $currentPath

        $parent = [System.IO.Directory]::GetParent($currentPath)
        if ($null -eq $parent) {
            break
        }
        $currentPath = $parent.FullName
    }
}

function Get-TrustedProgramDataDirectory {
    $programDataDirectory = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonApplicationData
    )
    if ([string]::IsNullOrWhiteSpace($programDataDirectory) -or -not [System.IO.Path]::IsPathRooted($programDataDirectory)) {
        throw 'PROGRAMDATA_PATH_INVALID'
    }

    $programDataDirectory = [System.IO.Path]::GetFullPath($programDataDirectory)
    Assert-ExistingDirectoryChainWithoutReparsePoint -Path $programDataDirectory
    return $programDataDirectory
}

function New-PrivateDirectorySecurity {
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administratorsSid)
    [void]$security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $systemSid,
        $fullControl,
        $inheritanceFlags,
        $propagationFlags,
        $allow
    ))
    [void]$security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $administratorsSid,
        $fullControl,
        $inheritanceFlags,
        $propagationFlags,
        $allow
    ))
    return $security
}

function Assert-PrivateInstallerDirectory {
    param([Parameter(Mandatory = $true)][string]$DirectoryPath)

    $trustedProgramDataDirectory = Get-TrustedProgramDataDirectory
    $fullDirectoryPath = [System.IO.Path]::GetFullPath($DirectoryPath)
    $parent = [System.IO.Directory]::GetParent($fullDirectoryPath)
    if ($null -eq $parent -or -not $parent.FullName.Equals(
            $trustedProgramDataDirectory,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'PRIVATE_DIRECTORY_PARENT_INVALID'
    }

    $directoryName = [System.IO.Path]::GetFileName($fullDirectoryPath)
    if ($directoryName -notmatch ('^' + [regex]::Escape($PrivateDirectoryPrefix) + '[0-9a-f]{32}$')) {
        throw 'PRIVATE_DIRECTORY_NAME_INVALID'
    }

    Assert-ExistingDirectoryChainWithoutReparsePoint -Path $fullDirectoryPath
    $accessSections = [System.Security.AccessControl.AccessControlSections]::Access -bor `
        [System.Security.AccessControl.AccessControlSections]::Owner
    $security = [System.IO.Directory]::GetAccessControl($fullDirectoryPath, $accessSections)
    $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')

    if (-not $security.AreAccessRulesProtected) {
        throw 'PRIVATE_DIRECTORY_DACL_UNPROTECTED'
    }
    if ($security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -cne $administratorsSid.Value) {
        throw 'PRIVATE_DIRECTORY_OWNER_INVALID'
    }

    $rules = @($security.GetAccessRules(
        $true,
        $false,
        [System.Security.Principal.SecurityIdentifier]
    ))
    if ($rules.Count -ne 2) {
        throw 'PRIVATE_DIRECTORY_DACL_INVALID'
    }

    $seenSids = @{}
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($rule in $rules) {
        $sidValue = $rule.IdentityReference.Value
        if ($seenSids.ContainsKey($sidValue) -or ($sidValue -cne $systemSid.Value -and $sidValue -cne $administratorsSid.Value)) {
            throw 'PRIVATE_DIRECTORY_DACL_INVALID'
        }
        if (
            $rule.IsInherited -or
            $rule.AccessControlType -ne $allow -or
            $rule.FileSystemRights -ne $fullControl -or
            $rule.InheritanceFlags -ne $inheritanceFlags -or
            $rule.PropagationFlags -ne $propagationFlags
        ) {
            throw 'PRIVATE_DIRECTORY_DACL_INVALID'
        }
        $seenSids[$sidValue] = $true
    }

    return $fullDirectoryPath
}

function New-PrivateInstallerDirectory {
    $trustedProgramDataDirectory = Get-TrustedProgramDataDirectory
    $security = New-PrivateDirectorySecurity

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $directoryName = $PrivateDirectoryPrefix + [Guid]::NewGuid().ToString('N')
        $directoryPath = [System.IO.Path]::Combine($trustedProgramDataDirectory, $directoryName)
        if ($null -ne (Get-PathAttributesOrNull -Path $directoryPath)) {
            continue
        }

        [void][System.IO.Directory]::CreateDirectory($directoryPath, $security)
        return (Assert-PrivateInstallerDirectory -DirectoryPath $directoryPath)
    }

    throw 'PRIVATE_DIRECTORY_CREATION_FAILED'
}

function Assert-PrivateInstallerFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$PrivateDirectory,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $trustedPrivateDirectory = Assert-PrivateInstallerDirectory -DirectoryPath $PrivateDirectory
    $expectedPath = [System.IO.Path]::Combine($trustedPrivateDirectory, $PrivateMsiName)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.Equals($expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'PRIVATE_FILE_PATH_INVALID'
    }
    return $fullPath
}

function Assert-ExistingPrivateInstallerFile {
    param(
        [Parameter(Mandatory = $true)][string]$PrivateDirectory,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = Assert-PrivateInstallerFilePath -PrivateDirectory $PrivateDirectory -Path $Path
    $attributes = Get-PathAttributesOrNull -Path $fullPath
    if ($null -eq $attributes) {
        throw 'PRIVATE_FILE_NOT_FOUND'
    }
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'REPARSE_POINT_REJECTED'
    }
    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
        throw 'PRIVATE_FILE_TYPE_INVALID'
    }
    return $fullPath
}

function Remove-PrivateInstallerFile {
    param(
        [Parameter(Mandatory = $true)][string]$PrivateDirectory,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = Assert-PrivateInstallerFilePath -PrivateDirectory $PrivateDirectory -Path $Path
    $attributes = Get-PathAttributesOrNull -Path $fullPath
    if ($null -eq $attributes) {
        return
    }
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'REPARSE_POINT_REJECTED'
    }
    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
        throw 'PRIVATE_FILE_TYPE_INVALID'
    }
    [System.IO.File]::Delete($fullPath)
}

function Remove-PrivateInstallerDirectory {
    param([Parameter(Mandatory = $true)][string]$DirectoryPath)

    $trustedPrivateDirectory = Assert-PrivateInstallerDirectory -DirectoryPath $DirectoryPath
    $entries = @([System.IO.Directory]::GetFileSystemEntries($trustedPrivateDirectory))
    if ($entries.Count -ne 0) {
        throw 'PRIVATE_DIRECTORY_NOT_EMPTY'
    }
    [System.IO.Directory]::Delete($trustedPrivateDirectory, $false)
}

function Get-FileIdentityFromStream {
    param([Parameter(Mandatory = $true)][System.IO.FileStream]$Stream)

    $information = [CCSwitchNativeFileIdentity+BY_HANDLE_FILE_INFORMATION]::new()
    if (-not [CCSwitchNativeFileIdentity]::GetFileInformationByHandle($Stream.SafeFileHandle, [ref]$information)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "FILE_IDENTITY_QUERY_FAILED_$errorCode"
    }
    if (([System.IO.FileAttributes]$information.FileAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'REPARSE_POINT_REJECTED'
    }

    return [pscustomobject]@{
        VolumeSerialNumber = [uint32]$information.VolumeSerialNumber
        FileIndexHigh = [uint32]$information.FileIndexHigh
        FileIndexLow = [uint32]$information.FileIndexLow
    }
}

function Test-FileIdentity {
    param(
        [Parameter(Mandatory = $true)][psobject]$Expected,
        [Parameter(Mandatory = $true)][psobject]$Actual
    )

    return (
        [uint32]$Expected.VolumeSerialNumber -eq [uint32]$Actual.VolumeSerialNumber -and
        [uint32]$Expected.FileIndexHigh -eq [uint32]$Actual.FileIndexHigh -and
        [uint32]$Expected.FileIndexLow -eq [uint32]$Actual.FileIndexLow
    )
}

function Get-PrivateFileFingerprintWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$PrivateDirectory,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int64]$ExpectedSize
    )

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $stream = $null
        $hashAlgorithm = $null
        try {
            $fullPath = Assert-ExistingPrivateInstallerFile -PrivateDirectory $PrivateDirectory -Path $Path
            $stream = [System.IO.File]::Open(
                $fullPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read
            )
            if ($stream.Length -ne $ExpectedSize) {
                throw 'DOWNLOAD_SIZE_MISMATCH'
            }

            $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
            $hashBytes = $hashAlgorithm.ComputeHash($stream)
            if ($stream.Length -ne $ExpectedSize) {
                throw 'DOWNLOAD_SIZE_MISMATCH'
            }

            $identity = Get-FileIdentityFromStream -Stream $stream
            $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
            return [pscustomobject]@{
                Length = [int64]$stream.Length
                Sha256 = $hash
                Identity = $identity
            }
        }
        catch {
            if ($attempt -eq 10) { throw }
            Start-Sleep -Milliseconds 300
        }
        finally {
            if ($null -ne $hashAlgorithm) { $hashAlgorithm.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
}

function Open-VerifiedMsiForInstallation {
    param(
        [Parameter(Mandatory = $true)][string]$PrivateDirectory,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int64]$ExpectedSize,
        [Parameter(Mandatory = $true)][psobject]$ExpectedIdentity
    )

    $stream = $null
    try {
        $fullPath = Assert-ExistingPrivateInstallerFile -PrivateDirectory $PrivateDirectory -Path $Path
        $stream = [System.IO.File]::Open(
            $fullPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        if ($stream.Length -ne $ExpectedSize) {
            throw 'PRIVATE_FILE_CHANGED'
        }

        $actualIdentity = Get-FileIdentityFromStream -Stream $stream
        if (-not (Test-FileIdentity -Expected $ExpectedIdentity -Actual $actualIdentity)) {
            throw 'PRIVATE_FILE_CHANGED'
        }

        $streamToReturn = $stream
        $stream = $null
        return $streamToReturn
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Invoke-VerifiedDownload {
    param(
        [Parameter(Mandatory = $true)][psobject]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$PrivateDirectory
    )

    if ([int64]$Source.ExpectedSize -lt $MinimumAssetSize -or [int64]$Source.ExpectedSize -gt $MaximumAssetSize) {
        throw 'INVALID_ASSET_SIZE'
    }
    if ([string]$Source.ExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'INVALID_ASSET_DIGEST'
    }

    for ($attempt = 1; $attempt -le $DownloadAttempts; $attempt++) {
        Remove-PrivateInstallerFile -PrivateDirectory $PrivateDirectory -Path $Destination
        try {
            Invoke-HttpDownloadOnce -Source $Source -Destination $Destination -PrivateDirectory $PrivateDirectory
            $fingerprint = Get-PrivateFileFingerprintWithRetry `
                -PrivateDirectory $PrivateDirectory `
                -Path $Destination `
                -ExpectedSize ([int64]$Source.ExpectedSize)

            if ($fingerprint.Sha256 -cne ([string]$Source.ExpectedSha256).ToLowerInvariant()) {
                throw 'DOWNLOAD_HASH_MISMATCH'
            }

            return $fingerprint
        }
        catch {
            Remove-PrivateInstallerFile -PrivateDirectory $PrivateDirectory -Path $Destination
            if ($attempt -lt $DownloadAttempts) {
                Write-Warning "[WARN] 下载或完整性校验失败，正在重试 ($attempt/$DownloadAttempts)。"
                Start-Sleep -Seconds 2
            }
        }
    }

    return $null
}

# Windows PowerShell 5.1 does not always enable TLS 1.2 by default.
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
if ($null -eq ('CCSwitchNativeFileIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class CCSwitchNativeFileIdentity
{
    [StructLayout(LayoutKind.Sequential)]
    public struct BY_HANDLE_FILE_INFORMATION
    {
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

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out BY_HANDLE_FILE_INFORMATION fileInformation);
}
'@ -ErrorAction Stop
}

$temporaryDirectory = $null
$msiReadLock = $null
$scriptExitCode = 1
$failureCode = 'UNEXPECTED'
$msiExitCode = $null

try {
    $architecture = Get-NativeArchitecture
    if ($null -eq $architecture) {
        $failureCode = 'UNSUPPORTED_ARCHITECTURE'
        throw $failureCode
    }

    Write-Output '[INFO] CC Switch Windows 安装程序'
    Write-Output "[INFO] 系统架构: $architecture"
    Write-Output '[INFO] 正在读取 GitHub 官方发布元数据。'

    $source = Get-LatestGitHubSource -Architecture $architecture
    if ($null -eq $source) {
        $source = New-PinnedSource -Architecture $architecture
    }

    if ($source.IsPinned) {
        Write-Output "[INFO] 使用固定官方版本: $($source.Version)"
    }
    else {
        Write-Output "[INFO] 使用 GitHub 最新版本: $($source.Version)"
    }

    $temporaryDirectory = New-PrivateInstallerDirectory
    $msiPath = [System.IO.Path]::Combine($temporaryDirectory, $PrivateMsiName)

    Write-Output '[INFO] 正在下载并校验安装包大小与 SHA256。'
    $msiFingerprint = Invoke-VerifiedDownload `
        -Source $source `
        -Destination $msiPath `
        -PrivateDirectory $temporaryDirectory
    if ($null -eq $msiFingerprint) {
        $failureCode = 'DOWNLOAD_FAILED'
        throw $failureCode
    }
    Write-Output '[OK] 安装包完整性校验通过。'

    $msiexecPath = Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'
    if (-not (Test-Path -LiteralPath $msiexecPath -PathType Leaf)) {
        $failureCode = 'MSIEXEC_NOT_FOUND'
        throw $failureCode
    }

    try {
        # Keep a read-only handle open so the identity/length check remains valid until msiexec exits.
        $msiReadLock = Open-VerifiedMsiForInstallation `
            -PrivateDirectory $temporaryDirectory `
            -Path $msiPath `
            -ExpectedSize ([int64]$source.ExpectedSize) `
            -ExpectedIdentity $msiFingerprint.Identity
    }
    catch {
        $failureCode = 'INSTALLER_FILE_CHANGED'
        throw
    }

    Write-Output '[INFO] 正在静默安装 CC Switch。'
    $msiArguments = @(
        '/i',
        ('"{0}"' -f $msiPath),
        '/qn',
        '/norestart',
        'REBOOT=ReallySuppress'
    )
    $process = Start-Process `
        -FilePath $msiexecPath `
        -ArgumentList $msiArguments `
        -Wait `
        -PassThru `
        -NoNewWindow `
        -ErrorAction Stop
    $msiExitCode = [int]$process.ExitCode

    if ($msiExitCode -notin @(0, 1641, 3010)) {
        $failureCode = 'MSI_INSTALL_FAILED'
        throw $failureCode
    }

    if ($msiExitCode -in @(1641, 3010)) {
        Write-Warning '[WARN] 安装成功，Windows 建议稍后重启。'
    }

    $scriptExitCode = 0
}
catch {
    switch ($failureCode) {
        'UNSUPPORTED_ARCHITECTURE' {
            Write-Error '[ERROR] 仅支持 Windows x64 或 ARM64。' -ErrorAction Continue
        }
        'DOWNLOAD_FAILED' {
            Write-Error '[ERROR] 官方安装包下载失败，或大小/SHA256 校验未通过。' -ErrorAction Continue
        }
        'MSIEXEC_NOT_FOUND' {
            Write-Error '[ERROR] Windows Installer 不可用。' -ErrorAction Continue
        }
        'INSTALLER_FILE_CHANGED' {
            Write-Error '[ERROR] 安装包在校验后发生变化，已停止安装。' -ErrorAction Continue
        }
        'MSI_INSTALL_FAILED' {
            Write-Error "[ERROR] CC Switch 静默安装失败，Windows Installer 退出码: $msiExitCode" -ErrorAction Continue
        }
        default {
            Write-Error '[ERROR] CC Switch 安装未完成。' -ErrorAction Continue
        }
    }
}
finally {
    if ($null -ne $msiReadLock) {
        try {
            $msiReadLock.Dispose()
        }
        catch {
            Write-Warning '[WARN] 安装包文件句柄未能正常关闭。'
        }
    }

    if ($null -ne $temporaryDirectory) {
        try {
            $cleanupMsiPath = [System.IO.Path]::Combine($temporaryDirectory, $PrivateMsiName)
            Remove-PrivateInstallerFile -PrivateDirectory $temporaryDirectory -Path $cleanupMsiPath
            Remove-PrivateInstallerDirectory -DirectoryPath $temporaryDirectory
        }
        catch {
            Write-Warning '[WARN] 私有安装目录未能完全清理，请由管理员稍后检查 ProgramData。'
        }
    }
}

if ($scriptExitCode -ne 0) {
    exit $scriptExitCode
}

Write-Output ''
Write-Output '============================================'
Write-Output '  CC Switch 安装完成'
Write-Output '============================================'
Write-Output '  可从开始菜单或桌面快捷方式启动 CC Switch。'
Write-Output ''
