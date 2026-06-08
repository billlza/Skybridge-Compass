param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [double]$MinimumLineCoverage = 90.0,
    [switch]$IncludeRustCliCoverage,
    [switch]$IncludeNativeDnsSdAcceptance,
    [switch]$CheckOnlineStackFreshness,
    [switch]$RequireNativeDnsSdPeer,
    [string]$ExpectedDeviceId = "",
    [string]$ExpectedFingerprint = "",
    [string]$SearchText = "",
    [ValidateRange(1, 30)]
    [int]$ExtendedSearchSeconds = 2,
    [switch]$RequireGitRemoteAccess
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-SmokeGate {
    param(
        [string]$Name,
        [string]$RelativeScriptPath,
        [hashtable]$Parameters = @{}
    )

    $scriptPath = Join-Path $RepoRoot $RelativeScriptPath
    Assert-True -Condition (Test-Path -LiteralPath $scriptPath) -Message "Missing smoke gate script: $scriptPath"

    Write-Output "windows-portability-smoke: running $Name"
    & $scriptPath @Parameters
    Write-Output "windows-portability-smoke: passed $Name"
}

$gitRemoteParameters = @{
    RepoRoot = $RepoRoot
    RequireConfiguredSshCommand = $true
    RequireKnownHosts = $true
    RequireCredentialHelperReset = $true
}
if ($RequireGitRemoteAccess) {
    $gitRemoteParameters.RequireRemoteAccess = $true
}

Invoke-SmokeGate `
    -Name "git-ssh-remote" `
    -RelativeScriptPath "Scripts/verify-git-ssh-remote.ps1" `
    -Parameters $gitRemoteParameters

$stackFreshnessParameters = @{
    RepoRoot = $RepoRoot
}
if ($CheckOnlineStackFreshness) {
    $stackFreshnessParameters.CheckOnline = $true
}

Invoke-SmokeGate `
    -Name "windows-stack-freshness" `
    -RelativeScriptPath "Scripts/verify-windows-stack-freshness.ps1" `
    -Parameters $stackFreshnessParameters

Invoke-SmokeGate `
    -Name "windows-ffi-client" `
    -RelativeScriptPath "Scripts/verify-windows-ffi-client.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-ui-parity" `
    -RelativeScriptPath "Scripts/verify-windows-ui-parity.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-ui-action-order" `
    -RelativeScriptPath "Scripts/verify-windows-ui-action-order.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-startup-state" `
    -RelativeScriptPath "Scripts/verify-windows-startup-state.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-command-gates" `
    -RelativeScriptPath "Scripts/verify-windows-command-gates.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-native-runtime-profile" `
    -RelativeScriptPath "Scripts/verify-windows-native-runtime-profile.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-connection-launch" `
    -RelativeScriptPath "Scripts/verify-windows-connection-launch.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

if ($IncludeNativeDnsSdAcceptance -or $RequireNativeDnsSdPeer) {
    $dnsSdParameters = @{
        RepoRoot = $RepoRoot
        ExtendedSearchSeconds = $ExtendedSearchSeconds
    }

    if ($RequireNativeDnsSdPeer) {
        $dnsSdParameters.RequirePeer = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedDeviceId)) {
        $dnsSdParameters.ExpectedDeviceId = $ExpectedDeviceId
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedFingerprint)) {
        $dnsSdParameters.ExpectedFingerprint = $ExpectedFingerprint
    }

    if (-not [string]::IsNullOrWhiteSpace($SearchText)) {
        $dnsSdParameters.SearchText = $SearchText
    }

    Invoke-SmokeGate `
        -Name "windows-native-dns-sd-acceptance" `
        -RelativeScriptPath "Scripts/verify-windows-native-dns-sd-acceptance.ps1" `
        -Parameters $dnsSdParameters
}
else {
    Write-Output "windows-portability-smoke: skipped windows-native-dns-sd-acceptance; pass -IncludeNativeDnsSdAcceptance or -RequireNativeDnsSdPeer for local-network acceptance."
}

if ($IncludeRustCliCoverage) {
    Invoke-SmokeGate `
        -Name "rust-cli-coverage" `
        -RelativeScriptPath "Scripts/verify-rust-cli-coverage.ps1" `
        -Parameters @{
            RepoRoot = $RepoRoot
            MinimumLineCoverage = $MinimumLineCoverage
        }
}
else {
    Write-Output "windows-portability-smoke: skipped rust-cli-coverage; pass -IncludeRustCliCoverage for the 90% Rust CLI coverage gate."
}

Write-Output "windows-portability-smoke: ok"
