param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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

$proofGatePath = Join-Path $RepoRoot "Scripts/verify-windows-webrtc-proof.ps1"
$rustProofCliPath = Join-Path $RepoRoot "Scripts/verify-rust-webrtc-proof-cli.ps1"
$proofSchemaPath = Join-Path $RepoRoot "docs/windows-webrtc-proof-schema.md"
Assert-True -Condition (Test-Path -LiteralPath $proofGatePath) -Message "Missing Windows WebRTC proof gate: $proofGatePath"
Assert-True -Condition (Test-Path -LiteralPath $rustProofCliPath) -Message "Missing Rust WebRTC proof CLI gate: $rustProofCliPath"
Assert-True -Condition (Test-Path -LiteralPath $proofSchemaPath) -Message "Missing Windows WebRTC proof schema: $proofSchemaPath"

$expectedDeviceId = "mac-1"
$expectedFingerprint = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-webrtc-proof-smoke-" + [guid]::NewGuid().ToString("N"))
$proofPath = Join-Path $tempRoot "proof.json"

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $proof = [ordered]@{
        helperName = "schema-smoke-webrtc-helper"
        peerDeviceId = $expectedDeviceId
        peerPublicKeyFingerprint = $expectedFingerprint
        dataChannelOpen = $true
        sbf1EchoVerified = $true
        sbf1FrameMagic = "SBF1"
        adapterBinding = "verified webrtc datachannel helper"
        localEndpoint = "windows.lan:5443"
        remoteEndpoint = "mac.lan:5443"
        selectedCandidatePair = "webrtc/dtls/sctp/local=host:windows.lan:5443;remote=host:mac.lan:5443;path=same-lan"
        transportSecretFingerprintHex = "6666666666666666666666666666666666666666666666666666666666666666"
        capabilityDigestHex = "7777777777777777777777777777777777777777777777777777777777777777"
        relayId = "relay-helper"
        timestampWindowMs = 15000
        capturedAtUnixMs = ([DateTimeOffset]::UtcNow).ToUnixTimeMilliseconds()
    }

    $proofJson = $proof | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($proofPath, $proofJson, [System.Text.UTF8Encoding]::new($false))

    & $proofGatePath `
        -RepoRoot $RepoRoot `
        -ProofPath $proofPath `
        -ExpectedDeviceId $expectedDeviceId `
        -ExpectedFingerprint $expectedFingerprint `
        -MaxProofAgeMs 60000

    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Windows WebRTC proof schema smoke failed."

    & $rustProofCliPath `
        -RepoRoot $RepoRoot `
        -ProofPath $proofPath `
        -ExpectedDeviceId $expectedDeviceId `
        -ExpectedFingerprint $expectedFingerprint `
        -MaxProofAgeMs 60000

    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Rust WebRTC proof CLI schema smoke failed."
    Write-Output "windows-webrtc-proof-smoke: ok proof=$proofPath schema=$proofSchemaPath"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTempRoot = (Resolve-Path -LiteralPath $tempRoot).Path
        $resolvedTempParent = (Resolve-Path -LiteralPath $tempParent).Path.TrimEnd('\')
        $leaf = Split-Path -Leaf $resolvedTempRoot
        $isOwnedSmokeDir = $resolvedTempRoot.StartsWith(
            $resolvedTempParent,
            [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith(
            "skybridge-win-webrtc-proof-smoke-",
            [StringComparison]::Ordinal)

        Assert-True -Condition $isOwnedSmokeDir -Message "Refusing to remove unexpected temp directory: $resolvedTempRoot"
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}
