param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$MacHostName = "192.168.0.102",
    [string[]]$MacAlternateHostNames = @("LzadeMacBook-Pro.local"),
    [int]$MacPort = 22,
    [string[]]$MacUserNames = @("bill"),
    [string]$MacSshKeyPath = (Join-Path $env:USERPROFILE ".ssh\skybridge_mac_debug_ed25519"),
    [string]$MacKnownHostsPath = (Join-Path $env:TEMP "skybridge_mac_debug_known_hosts"),
    [string]$MacExpectedHostAddress = "192.168.0.102",
    [string]$MacDirectSourceAddress = "",
    [Parameter(Mandatory = $true)]
    [string]$MacRemoteRepoRoot,
    [Parameter(Mandatory = $true)]
    [string]$WebRtcProofPath,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedFingerprint,
    [string]$SearchText = "",
    [ValidateRange(1, 30)]
    [int]$ExtendedSearchSeconds = 5,
    [ValidateRange(1, 600000)]
    [ulong]$WebRtcProofMaxAgeMs = 60000,
    [switch]$CheckOnly
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

function Invoke-InteropGate {
    param(
        [string]$Name,
        [string]$RelativeScriptPath,
        [hashtable]$Parameters
    )

    $scriptPath = Join-Path $RepoRoot $RelativeScriptPath
    Assert-True -Condition (Test-Path -LiteralPath $scriptPath) -Message "Missing Windows/mac WebRTC interop gate script: $scriptPath"

    Write-Output "windows-mac-webrtc-interop: running $Name"
    $LASTEXITCODE = 0
    & $scriptPath @Parameters
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Windows/mac WebRTC interop gate failed: $Name exitCode=$LASTEXITCODE"
    Write-Output "windows-mac-webrtc-interop: passed $Name"
}

foreach ($requiredScript in @(
    "Scripts/probe-mac-ssh.ps1",
    "Scripts/verify-windows-native-dns-sd-acceptance.ps1",
    "Scripts/verify-rust-webrtc-proof-cli.ps1",
    "Scripts/verify-windows-webrtc-proof.ps1",
    "Scripts/verify-windows-connection-launch.ps1"
)) {
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $RepoRoot $requiredScript)) -Message "Missing required interop script: $requiredScript"
}

if ($CheckOnly) {
    Write-Output "windows-mac-webrtc-interop: check ok"
    return
}

Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($MacRemoteRepoRoot)) -Message "Windows/mac WebRTC interop requires -MacRemoteRepoRoot."
Assert-True -Condition (Test-Path -LiteralPath $WebRtcProofPath) -Message "Windows/mac WebRTC interop requires a helper proof file: $WebRtcProofPath"
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($ExpectedDeviceId)) -Message "Windows/mac WebRTC interop requires -ExpectedDeviceId."
Assert-True -Condition ($ExpectedFingerprint -match '^[0-9a-f]{64}$') -Message "Windows/mac WebRTC interop requires -ExpectedFingerprint as 64 lowercase hex characters."

$macSshParameters = @{
    HostName = $MacHostName
    AlternateHostNames = $MacAlternateHostNames
    Port = $MacPort
    UserNames = $MacUserNames
    KeyPath = $MacSshKeyPath
    KnownHostsPath = $MacKnownHostsPath
    ExpectedHostAddress = $MacExpectedHostAddress
    RequireReady = $true
    RequireDirectLan = $true
    RequireRustCliSmoke = $true
    RemoteRepoRoot = $MacRemoteRepoRoot
}
if (-not [string]::IsNullOrWhiteSpace($MacDirectSourceAddress)) {
    $macSshParameters.DirectSourceAddress = $MacDirectSourceAddress
}

Invoke-InteropGate `
    -Name "mac-ssh-direct-lan-rust-cli" `
    -RelativeScriptPath "Scripts/probe-mac-ssh.ps1" `
    -Parameters $macSshParameters

$dnsSdParameters = @{
    RepoRoot = $RepoRoot
    ExtendedSearchSeconds = $ExtendedSearchSeconds
    RequirePeer = $true
    ExpectedDeviceId = $ExpectedDeviceId
    ExpectedFingerprint = $ExpectedFingerprint
}
if (-not [string]::IsNullOrWhiteSpace($SearchText)) {
    $dnsSdParameters.SearchText = $SearchText
}

Invoke-InteropGate `
    -Name "windows-native-dns-sd-peer" `
    -RelativeScriptPath "Scripts/verify-windows-native-dns-sd-acceptance.ps1" `
    -Parameters $dnsSdParameters

Invoke-InteropGate `
    -Name "rust-webrtc-proof-cli" `
    -RelativeScriptPath "Scripts/verify-rust-webrtc-proof-cli.ps1" `
    -Parameters @{
        RepoRoot = $RepoRoot
        ProofPath = $WebRtcProofPath
        ExpectedDeviceId = $ExpectedDeviceId
        ExpectedFingerprint = $ExpectedFingerprint
        MaxProofAgeMs = $WebRtcProofMaxAgeMs
    }

Invoke-InteropGate `
    -Name "windows-webrtc-proof" `
    -RelativeScriptPath "Scripts/verify-windows-webrtc-proof.ps1" `
    -Parameters @{
        RepoRoot = $RepoRoot
        ProofPath = $WebRtcProofPath
        ExpectedDeviceId = $ExpectedDeviceId
        ExpectedFingerprint = $ExpectedFingerprint
        MaxProofAgeMs = $WebRtcProofMaxAgeMs
    }

Invoke-InteropGate `
    -Name "windows-connection-launch" `
    -RelativeScriptPath "Scripts/verify-windows-connection-launch.ps1" `
    -Parameters @{ RepoRoot = $RepoRoot }

Write-Output "windows-mac-webrtc-interop: ok"
