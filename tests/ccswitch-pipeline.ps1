#Requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy\ccswitch.ps1'
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$scriptSource = [IO.File]::ReadAllText($scriptPath, $utf8)
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput(
    $scriptSource,
    $scriptPath,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -ne 0) {
    throw 'CCSWITCH_PARSE_FAILED'
}

$functionAst = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Invoke-VerifiedDownload'
}, $true)
if ($null -eq $functionAst) {
    throw 'CCSWITCH_FUNCTION_NOT_FOUND'
}
Invoke-Expression $functionAst.Extent.Text

$MinimumAssetSize = 1
$MaximumAssetSize = 1024
$DownloadAttempts = 1
$expectedHash = 'a' * 64
$source = [pscustomobject]@{
    ExpectedSize = [int64]16
    ExpectedSha256 = $expectedHash
}

function Remove-PrivateInstallerFile {}
function Invoke-HttpDownloadOnce {
    'INTERNAL_PATH_OUTPUT'
    throw 'SIMULATED_DOWNLOAD_FAILURE'
}
function Get-PrivateFileFingerprintWithRetry {
    throw 'FINGERPRINT_MUST_NOT_RUN'
}

$failedResult = @((Invoke-VerifiedDownload `
    -Source $source `
    -Destination 'unused.msi' `
    -PrivateDirectory 'unused') | Where-Object { $null -ne $_ })
if ($failedResult.Count -ne 0) {
    throw 'FAILED_DOWNLOAD_EMITTED_PIPELINE_OUTPUT'
}

function Invoke-HttpDownloadOnce {
    'INTERNAL_PATH_OUTPUT'
}
function Get-PrivateFileFingerprintWithRetry {
    return [pscustomobject]@{
        Length = [int64]16
        Sha256 = $expectedHash
        Identity = [pscustomobject]@{
            VolumeSerialNumber = [uint32]1
            FileIndexHigh = [uint32]2
            FileIndexLow = [uint32]3
        }
    }
}

$successfulResult = @(Invoke-VerifiedDownload `
    -Source $source `
    -Destination 'unused.msi' `
    -PrivateDirectory 'unused')
if ($successfulResult.Count -ne 1 -or $successfulResult[0].Sha256 -cne $expectedHash) {
    throw 'SUCCESSFUL_DOWNLOAD_RESULT_WAS_CONTAMINATED'
}
