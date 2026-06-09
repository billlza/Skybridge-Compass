param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [Parameter(Mandatory = $true)]
    [string]$ProofPath,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedFingerprint,
    [ValidateRange(1, 600000)]
    [ulong]$MaxProofAgeMs = 60000
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

$manifestPath = Join-Path $RepoRoot "core/skybridge-core/Cargo.toml"
Assert-True -Condition (Test-Path -LiteralPath $manifestPath) -Message "Missing Rust Core Cargo manifest: $manifestPath"
Assert-True -Condition (Test-Path -LiteralPath $ProofPath) -Message "Missing WebRTC proof file: $ProofPath"
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($ExpectedDeviceId)) -Message "Rust WebRTC proof CLI requires -ExpectedDeviceId."
Assert-True -Condition ($ExpectedFingerprint -match '^[0-9a-f]{64}$') -Message "Rust WebRTC proof CLI requires -ExpectedFingerprint as 64 lowercase hex characters."

& cargo run `
    --manifest-path $manifestPath `
    --bin skybridge `
    -- `
    webrtc-proof validate `
    --proof $ProofPath `
    --expected-device-id $ExpectedDeviceId `
    --expected-fingerprint $ExpectedFingerprint `
    --max-age-ms $MaxProofAgeMs.ToString()

Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Rust WebRTC proof CLI validation failed."
Write-Output "rust-webrtc-proof-cli: ok proof=$ProofPath"
