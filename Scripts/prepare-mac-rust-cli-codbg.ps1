param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$MacHostName = "192.168.0.102",
    [string[]]$MacAlternateHostNames = @("LzadeMacBook-Pro.local", "bill.local"),
    [int]$MacPort = 22,
    [string[]]$MacUserNames = @("bill"),
    [string]$MacSshKeyPath = (Join-Path $env:USERPROFILE ".ssh\skybridge_mac_debug_ed25519"),
    [string]$MacKnownHostsPath = (Join-Path $env:TEMP "skybridge_mac_debug_known_hosts"),
    [string]$MacExpectedHostKeyFingerprint = "",
    [string]$MacExpectedHostAddress = "192.168.0.102",
    [string]$MacDirectSourceAddress = "",
    [string]$MacRemoteRepoRoot = "",
    [string]$EvidencePath = "",
    [string]$ProbeEvidencePath = "",
    [string]$SummaryPath = "",
    [int]$ConnectTimeoutSeconds = 5,
    [switch]$RequireReady,
    [switch]$RequireDirectLan,
    [switch]$RequireRustCliSmoke
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function ConvertTo-NormalizedHostKeyFingerprint {
    param([string]$Fingerprint)

    $trimmed = $Fingerprint.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return ""
    }

    if ($trimmed.StartsWith("SHA256:", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "SHA256:" + $trimmed.Substring(7)
    }

    return "SHA256:$trimmed"
}

function ConvertTo-JsonFileUtf8 {
    param(
        $Value,
        [string]$Path
    )

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = Split-Path -Parent $resolvedPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($resolvedPath, $json, [System.Text.UTF8Encoding]::new($false))
    return $resolvedPath
}

function New-DefaultEvidencePath {
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    return (Join-Path $env:TEMP "skybridge-mac-rust-cli-codbg-$stamp.json")
}

function Get-ProbeEvidenceObject {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function New-NextInteropCommand {
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add(".\Scripts\verify-windows-mac-webrtc-interop.ps1")
    $parts.Add("-MacHostName `"$MacHostName`"")
    $parts.Add("-MacPort $MacPort")
    $parts.Add("-MacUserNames $($MacUserNames -join ',')")
    $parts.Add("-MacSshKeyPath `"$MacSshKeyPath`"")
    $parts.Add("-MacKnownHostsPath `"$MacKnownHostsPath`"")
    if (-not [string]::IsNullOrWhiteSpace($MacExpectedHostKeyFingerprint)) {
        $parts.Add("-MacExpectedHostKeyFingerprint `"$MacExpectedHostKeyFingerprint`"")
    }
    if (-not [string]::IsNullOrWhiteSpace($MacExpectedHostAddress)) {
        $parts.Add("-MacExpectedHostAddress `"$MacExpectedHostAddress`"")
    }
    if (-not [string]::IsNullOrWhiteSpace($MacDirectSourceAddress)) {
        $parts.Add("-MacDirectSourceAddress `"$MacDirectSourceAddress`"")
    }
    if (-not [string]::IsNullOrWhiteSpace($MacRemoteRepoRoot)) {
        $parts.Add("-MacRemoteRepoRoot `"$MacRemoteRepoRoot`"")
    }
    else {
        $parts.Add("-MacRemoteRepoRoot <mac-repo-root>")
    }
    $parts.Add("-WebRtcProofPath <helper-proof-json>")
    $parts.Add("-ExpectedDeviceId <mac-device-id>")
    $parts.Add("-ExpectedFingerprint <64-lowercase-hex>")
    return ($parts -join " ")
}

$probeScript = Join-Path $RepoRoot "Scripts/probe-mac-ssh.ps1"
Assert-True -Condition (Test-Path -LiteralPath $probeScript) -Message "Missing Mac SSH probe script: $probeScript"
Assert-True -Condition (Test-Path -LiteralPath $MacSshKeyPath) -Message "Missing Mac SSH key: $MacSshKeyPath"

if ($RequireRustCliSmoke) {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($MacRemoteRepoRoot)) -Message "Mac Rust CLI smoke requires -MacRemoteRepoRoot."
}

$normalizedHostKeyFingerprint = ConvertTo-NormalizedHostKeyFingerprint -Fingerprint $MacExpectedHostKeyFingerprint
if ([string]::IsNullOrWhiteSpace($ProbeEvidencePath)) {
    if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
        $EvidencePath = New-DefaultEvidencePath
    }

    $ProbeEvidencePath = $EvidencePath
}
elseif (-not [string]::IsNullOrWhiteSpace($EvidencePath) -and [string]::IsNullOrWhiteSpace($SummaryPath)) {
    $SummaryPath = $EvidencePath
}

$probeParameters = @{
    HostName = $MacHostName
    AlternateHostNames = $MacAlternateHostNames
    Port = $MacPort
    UserNames = $MacUserNames
    KeyPath = $MacSshKeyPath
    KnownHostsPath = $MacKnownHostsPath
    RequireKnownHost = $true
    ExpectedHostAddress = $MacExpectedHostAddress
    EvidencePath = $ProbeEvidencePath
    ConnectTimeoutSeconds = $ConnectTimeoutSeconds
}
if (-not [string]::IsNullOrWhiteSpace($normalizedHostKeyFingerprint)) {
    $probeParameters.ExpectedHostKeyFingerprint = $normalizedHostKeyFingerprint
}
if (-not [string]::IsNullOrWhiteSpace($MacDirectSourceAddress)) {
    $probeParameters.DirectSourceAddress = $MacDirectSourceAddress
}
if ($RequireReady) {
    $probeParameters.RequireReady = $true
}
if ($RequireDirectLan) {
    $probeParameters.RequireDirectLan = $true
}
if ($RequireRustCliSmoke) {
    $probeParameters.RequireReady = $true
    $probeParameters.RequireRustCliSmoke = $true
    $probeParameters.RemoteRepoRoot = $MacRemoteRepoRoot
}

$status = "passed"
$detail = ""
try {
    & $probeScript @probeParameters | Write-Output
}
catch {
    $status = "failed"
    $detail = $_.Exception.Message
}

$probeEvidence = Get-ProbeEvidenceObject -Path $ProbeEvidencePath
$summary = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    script = "prepare-mac-rust-cli-codbg.ps1"
    status = $status
    detail = $detail
    hostName = $MacHostName
    alternateHostNames = @($MacAlternateHostNames)
    port = $MacPort
    userNames = @($MacUserNames)
    keyPath = $MacSshKeyPath
    knownHostsPath = $MacKnownHostsPath
    expectedHostAddress = $MacExpectedHostAddress
    expectedHostKeyFingerprint = $normalizedHostKeyFingerprint
    directSourceAddress = $MacDirectSourceAddress
    remoteRepoRoot = $MacRemoteRepoRoot
    requireReady = [bool]$RequireReady
    requireDirectLan = [bool]$RequireDirectLan
    requireRustCliSmoke = [bool]$RequireRustCliSmoke
    macRustCliSmoke = "cli_apple_to_apple_selects_apple_native"
    probeEvidencePath = $ProbeEvidencePath
    nextInteropCommand = New-NextInteropCommand
    probe = if ($probeEvidence) {
        [ordered]@{
            ready = [bool]$probeEvidence.ready
            readyHostName = [string]$probeEvidence.readyHostName
            readyUserName = [string]$probeEvidence.readyUserName
            directLanLikely = [bool]$probeEvidence.directLanLikely
            proxyTunnelRouteDetected = [bool]$probeEvidence.proxyTunnelRouteDetected
            localNameProxyResolutionDetected = [bool]$probeEvidence.localNameProxyResolutionDetected
            sameSubnetLanCandidateDetected = [bool]$probeEvidence.sameSubnetLanCandidateDetected
            routeFirstFailureDetected = [bool]$probeEvidence.routeFirstFailureDetected
            hostKeyPinned = [bool]$probeEvidence.hostKeyPinned
            hostKeySource = [string]$probeEvidence.hostKeySource
            hostKeyFingerprints = @($probeEvidence.hostKeyFingerprints)
        }
    }
    else {
        $null
    }
}

if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
    $resolvedSummaryPath = ConvertTo-JsonFileUtf8 -Value $summary -Path $SummaryPath
    Write-Output "mac-rust-cli-codbg: summary=$resolvedSummaryPath"
}

if ($probeEvidence) {
    Write-Output "mac-rust-cli-codbg: ready=$($probeEvidence.ready) directLanLikely=$($probeEvidence.directLanLikely) hostKeyPinned=$($probeEvidence.hostKeyPinned) evidence=$ProbeEvidencePath"
}
else {
    Write-Output "mac-rust-cli-codbg: evidence=$ProbeEvidencePath"
}

Write-Output "mac-rust-cli-codbg: next-interoperability-gate=$($summary.nextInteropCommand)"

if ($status -ne "passed") {
    throw $detail
}

Write-Output "mac-rust-cli-codbg: ok"
