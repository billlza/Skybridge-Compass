param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [double]$MinimumLineCoverage = 90.0,
    [switch]$IncludeRustCliCoverage,
    [switch]$IncludeNativeDnsSdAcceptance,
    [switch]$CheckOnlineStackFreshness,
    [switch]$CiMode,
    [switch]$ProbeMacSsh,
    [switch]$IncludeWinUiAutomationSmoke,
    [switch]$RequireMacSshReady,
    [switch]$RequireMacDirectLan,
    [switch]$RequireMacRustCliSmoke,
    [switch]$RequireMacWebRtcInterop,
    [switch]$RequireNativeDnsSdPeer,
    [string]$ExpectedDeviceId = "",
    [string]$ExpectedFingerprint = "",
    [string]$SearchText = "",
    [string]$MacHostName = "192.168.0.102",
    [string[]]$MacAlternateHostNames = @("LzadeMacBook-Pro.local"),
    [int]$MacPort = 22,
    [string[]]$MacUserNames = @("bill", "Lza"),
    [string]$MacSshKeyPath = (Join-Path $env:USERPROFILE ".ssh\skybridge_mac_debug_ed25519"),
    [string]$MacKnownHostsPath = (Join-Path $env:TEMP "skybridge_mac_debug_known_hosts"),
    [string]$MacExpectedHostAddress = "192.168.0.102",
    [string]$MacDirectSourceAddress = "",
    [string]$MacRemoteRepoRoot = "",
    [string]$MacWebRtcProofPath = "",
    [ValidateRange(1, 600000)]
    [ulong]$MacWebRtcProofMaxAgeMs = 60000,
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
    $LASTEXITCODE = 0
    & $scriptPath @Parameters
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Smoke gate failed: $Name exitCode=$LASTEXITCODE"
    Write-Output "windows-portability-smoke: passed $Name"
}

$gitRemoteParameters = @{
    RepoRoot = $RepoRoot
}
if (-not $CiMode) {
    $gitRemoteParameters.RequireConfiguredSshCommand = $true
    $gitRemoteParameters.RequireKnownHosts = $true
    $gitRemoteParameters.RequireCredentialHelperReset = $true
}
else {
    Write-Output "windows-portability-smoke: CI mode keeps the SSH-only remote check but skips workstation-specific SSH key, known_hosts, and credential-helper requirements."
}
if ($RequireGitRemoteAccess) {
    $gitRemoteParameters.RequireRemoteAccess = $true
}

Invoke-SmokeGate `
    -Name "git-ssh-remote" `
    -RelativeScriptPath "Scripts/verify-git-ssh-remote.ps1" `
    -Parameters $gitRemoteParameters

Invoke-SmokeGate `
    -Name "windows-ci-workflow" `
    -RelativeScriptPath "Scripts/verify-windows-ci-workflow.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

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
    -Name "windows-ui-parity-matrix" `
    -RelativeScriptPath "Scripts/verify-windows-ui-parity-matrix.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

if ($IncludeWinUiAutomationSmoke) {
    Invoke-SmokeGate `
        -Name "windows-ui-automation-smoke" `
        -RelativeScriptPath "Scripts/verify-windows-ui-automation-smoke.ps1" `
        -Parameters @{ RepoRoot = $RepoRoot }
}
else {
    Write-Output "windows-portability-smoke: skipped windows-ui-automation-smoke; pass -IncludeWinUiAutomationSmoke on an interactive Windows desktop to verify live WinUI navigation, anchors, layout, and File Transfer QR preview."
}

Invoke-SmokeGate `
    -Name "windows-startup-state" `
    -RelativeScriptPath "Scripts/verify-windows-startup-state.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-command-gates" `
    -RelativeScriptPath "Scripts/verify-windows-command-gates.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-file-transfer-qr" `
    -RelativeScriptPath "Scripts/verify-windows-file-transfer-qr.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-native-runtime-profile" `
    -RelativeScriptPath "Scripts/verify-windows-native-runtime-profile.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Invoke-SmokeGate `
    -Name "windows-connection-launch" `
    -RelativeScriptPath "Scripts/verify-windows-connection-launch.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

if ($ProbeMacSsh -or $RequireMacSshReady -or $RequireMacDirectLan -or $RequireMacRustCliSmoke) {
    $macSshParameters = @{
        HostName = $MacHostName
        AlternateHostNames = $MacAlternateHostNames
        Port = $MacPort
        UserNames = $MacUserNames
        KeyPath = $MacSshKeyPath
        KnownHostsPath = $MacKnownHostsPath
        ExpectedHostAddress = $MacExpectedHostAddress
    }

    if (-not [string]::IsNullOrWhiteSpace($MacDirectSourceAddress)) {
        $macSshParameters.DirectSourceAddress = $MacDirectSourceAddress
    }

    if ($RequireMacSshReady) {
        $macSshParameters.RequireReady = $true
    }

    if ($RequireMacDirectLan) {
        $macSshParameters.RequireDirectLan = $true
    }

    if ($RequireMacRustCliSmoke) {
        $macSshParameters.RequireReady = $true
        $macSshParameters.RequireRustCliSmoke = $true
        $macSshParameters.RemoteRepoRoot = $MacRemoteRepoRoot
    }

    Invoke-SmokeGate `
        -Name "mac-ssh-readiness" `
        -RelativeScriptPath "Scripts/probe-mac-ssh.ps1" `
        -Parameters $macSshParameters
}
else {
    Write-Output "windows-portability-smoke: skipped mac-ssh-readiness; pass -ProbeMacSsh for diagnostics, -RequireMacSshReady before Rust CLI co-debugging, -RequireMacDirectLan to reject proxy/TUN routes, or -RequireMacRustCliSmoke -MacRemoteRepoRoot <path> for a Mac-side CLI smoke."
}

if ($RequireMacWebRtcInterop) {
    Invoke-SmokeGate `
        -Name "windows-mac-webrtc-interop" `
        -RelativeScriptPath "Scripts/verify-windows-mac-webrtc-interop.ps1" `
        -Parameters @{
            RepoRoot = $RepoRoot
            MacHostName = $MacHostName
            MacAlternateHostNames = $MacAlternateHostNames
            MacPort = $MacPort
            MacUserNames = $MacUserNames
            MacSshKeyPath = $MacSshKeyPath
            MacKnownHostsPath = $MacKnownHostsPath
            MacExpectedHostAddress = $MacExpectedHostAddress
            MacDirectSourceAddress = $MacDirectSourceAddress
            MacRemoteRepoRoot = $MacRemoteRepoRoot
            WebRtcProofPath = $MacWebRtcProofPath
            ExpectedDeviceId = $ExpectedDeviceId
            ExpectedFingerprint = $ExpectedFingerprint
            SearchText = $SearchText
            ExtendedSearchSeconds = $ExtendedSearchSeconds
            WebRtcProofMaxAgeMs = $MacWebRtcProofMaxAgeMs
        }
}
else {
    Write-Output "windows-portability-smoke: skipped windows-mac-webrtc-interop; pass -RequireMacWebRtcInterop -MacRemoteRepoRoot <path> -MacWebRtcProofPath <path> -ExpectedDeviceId <id> -ExpectedFingerprint <hex> after direct LAN and helper proof are ready. That local gate composes probe-mac-ssh.ps1, verify-windows-native-dns-sd-acceptance.ps1, verify-windows-webrtc-proof.ps1, and verify-windows-connection-launch.ps1."
}

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
