param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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

$wrapperPath = Join-Path $RepoRoot "Scripts/prepare-mac-rust-cli-codbg.ps1"
Assert-True -Condition (Test-Path -LiteralPath $wrapperPath) -Message "Missing Mac Rust CLI co-debug wrapper: $wrapperPath"

$tempParent = [System.IO.Path]::GetTempPath()
$testRoot = Join-Path $tempParent ("skybridge-codbg-wrapper-test-" + [guid]::NewGuid().ToString("N"))
$scriptsDir = Join-Path $testRoot "Scripts"
$fakeProbePath = Join-Path $scriptsDir "probe-mac-ssh.ps1"
$keyPath = Join-Path $testRoot "mac_key"
$knownHostsPath = Join-Path $testRoot "known_hosts"
$evidencePath = Join-Path $testRoot "probe-evidence.json"
$summaryPath = Join-Path $testRoot "summary.json"

try {
    New-Item -ItemType Directory -Path $scriptsDir | Out-Null
    Set-Content -LiteralPath $keyPath -Encoding ASCII -Value "fake-key"
    Set-Content -LiteralPath $fakeProbePath -Encoding UTF8 -Value @'
param(
    [string]$HostName,
    [string[]]$AlternateHostNames,
    [int]$Port,
    [string[]]$UserNames,
    [string]$KeyPath,
    [string]$KnownHostsPath,
    [switch]$RequireKnownHost,
    [string]$ExpectedHostKeyFingerprint,
    [string]$ExpectedHostAddress,
    [string]$DirectSourceAddress,
    [string]$EvidencePath,
    [int]$ConnectTimeoutSeconds,
    [switch]$RequireReady,
    [switch]$RequireDirectLan,
    [switch]$RequireRustCliSmoke,
    [string]$RemoteRepoRoot
)

if (-not $RequireKnownHost) { throw "RequireKnownHost was not passed." }
if (-not $RequireReady) { throw "RequireReady was not passed." }
if (-not $RequireDirectLan) { throw "RequireDirectLan was not passed." }
if (-not $RequireRustCliSmoke) { throw "RequireRustCliSmoke was not passed." }
if ($ExpectedHostKeyFingerprint -ne "SHA256:testfingerprint") { throw "Unexpected fingerprint: $ExpectedHostKeyFingerprint" }
if ($RemoteRepoRoot -ne "/Users/bill/Skybridge-Compass") { throw "Unexpected remote repo: $RemoteRepoRoot" }
if ($DirectSourceAddress -ne "192.168.0.55") { throw "Unexpected direct source address: $DirectSourceAddress" }

[ordered]@{
    ready = $true
    readyHostName = $HostName
    readyUserName = $UserNames[0]
    directLanLikely = $true
    proxyTunnelRouteDetected = $false
    localNameProxyResolutionDetected = $false
    sameSubnetLanCandidateDetected = $true
    routeFirstFailureDetected = $false
    hostKeyPinned = $true
    hostKeySource = "ssh-keyscan-expected-fingerprint"
    hostKeyFingerprints = @($ExpectedHostKeyFingerprint)
    rustCliSmoke = [ordered]@{
        required = $true
        status = "passed"
        name = "skybridge transport select AppleNative behavior"
        legacyTestName = "cli_apple_to_apple_selects_apple_native"
        remoteRepoRoot = $RemoteRepoRoot
        userName = $UserNames[0]
        hostName = $HostName
        command = "cargo run --quiet --manifest-path core/skybridge-core/Cargo.toml --bin skybridge -- transport select --local macos --remote ios --path same-lan"
        expectedSignals = @("kind=AppleNative", "audit=AppleNativeDefault", "relay_allowed=false")
        actualSignals = @("kind=AppleNative", "audit=AppleNativeDefault", "relay_allowed=false")
        actualOutput = "kind=AppleNative`naudit=AppleNativeDefault`nrelay_allowed=false"
        actualOutputSha256 = "0d012e33a7cb53adb94a10cf24e8766f94b4f8081faacff6d035c11b9bc198d9"
        timeoutSeconds = 120
        exitCode = 0
        detail = "fake wrapper smoke"
    }
    remediation = [ordered]@{
        status = "ready"
        reasonCodes = @()
        targetAddresses = @($HostName)
        recommendedDirectSourceAddresses = @()
        recommendedActions = @()
        nextProbeCommand = "Scripts\prepare-mac-rust-cli-codbg.ps1"
    }
} |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $EvidencePath -Encoding UTF8

Write-Output "fake-probe: ok"
'@

    $output = & $wrapperPath `
        -RepoRoot $testRoot `
        -MacHostName "192.168.0.102" `
        -MacUserNames "bill" `
        -MacSshKeyPath $keyPath `
        -MacKnownHostsPath $knownHostsPath `
        -MacExpectedHostKeyFingerprint "testfingerprint" `
        -MacDirectSourceAddress "192.168.0.55" `
        -MacRemoteRepoRoot "/Users/bill/Skybridge-Compass" `
        -EvidencePath $summaryPath `
        -ProbeEvidencePath $evidencePath `
        -RequireReady `
        -RequireDirectLan `
        -RequireRustCliSmoke

    $output | Write-Output
    Assert-True -Condition (Test-Path -LiteralPath $evidencePath) -Message "Wrapper smoke did not write probe evidence."
    Assert-True -Condition (Test-Path -LiteralPath $summaryPath) -Message "Wrapper smoke did not write summary evidence."

    $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
    Assert-True -Condition ([bool]$summary.probe.ready) -Message "Wrapper summary did not record ready=true."
    Assert-True -Condition ([bool]$summary.probe.hostKeyPinned) -Message "Wrapper summary did not record hostKeyPinned=true."
    Assert-True -Condition ([bool]$summary.probe.directLanLikely) -Message "Wrapper summary did not record directLanLikely=true."
    Assert-True -Condition ($summary.probeEvidencePath -eq $evidencePath) -Message "Wrapper summary did not record the explicit probe evidence path."
    Assert-True -Condition ($summary.macDirectSourceAddress -eq "192.168.0.55") -Message "Wrapper summary did not record the direct source address."
    Assert-True -Condition ($summary.probe.remediation.status -eq "ready") -Message "Wrapper summary did not carry remediation status."
    Assert-True -Condition ($summary.probe.rustCliSmoke.status -eq "passed") -Message "Wrapper summary did not carry passed Rust CLI smoke status."
    Assert-True -Condition ($summary.probe.rustCliSmoke.exitCode -eq 0) -Message "Wrapper summary did not carry Rust CLI smoke exitCode=0."
    Assert-True -Condition (@($summary.probe.rustCliSmoke.actualSignals).Count -eq 3) -Message "Wrapper summary did not carry Rust CLI actual signals."
    Assert-True -Condition ($summary.probe.rustCliSmoke.command -match "transport select --local macos --remote ios --path same-lan") -Message "Wrapper summary did not carry Rust CLI transport-select command."
    Assert-True -Condition ($summary.macRustCliSmoke -eq "cli_apple_to_apple_selects_apple_native") -Message "Wrapper summary missing Mac Rust CLI smoke name."
    Assert-True -Condition ($summary.nextInteropCommand -match "verify-windows-mac-webrtc-interop\.ps1") -Message "Wrapper summary missing next interop command."
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $resolvedTempParent = (Resolve-Path -LiteralPath $tempParent).Path.TrimEnd('\')
        $leaf = Split-Path -Leaf $resolvedTestRoot
        $isOwnedTestDir = $resolvedTestRoot.StartsWith(
            $resolvedTempParent,
            [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith(
            "skybridge-codbg-wrapper-test-",
            [StringComparison]::Ordinal)

        Assert-True -Condition $isOwnedTestDir -Message "Refusing to remove unexpected test directory: $resolvedTestRoot"
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

Write-Output "mac-rust-cli-codbg-wrapper: ok"
