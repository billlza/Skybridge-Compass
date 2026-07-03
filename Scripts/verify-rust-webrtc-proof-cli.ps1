param(
    [string]$RepoRoot = "",
    [Parameter(Mandatory = $true)]
    [string]$ProofPath,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedFingerprint,
    [ValidateRange(1, 600000)]
    [UInt64]$MaxProofAgeMs = 60000
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

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        Split-Path -Parent $PSCommandPath
    } else {
        $PSScriptRoot
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($scriptRoot)) -Message "RepoRoot must be supplied when the script path cannot be resolved."
    $RepoRoot = (Resolve-Path (Join-Path $scriptRoot "..")).Path
} else {
    $RepoRoot = (Resolve-Path $RepoRoot).Path
}

$manifestPath = Join-Path $RepoRoot "core/skybridge-core/Cargo.toml"
$cliEntryPath = Join-Path $RepoRoot "core/skybridge-core/src/bin/skybridge.rs"
Assert-True -Condition (Test-Path -LiteralPath $manifestPath) -Message "Missing Rust Core Cargo manifest: $manifestPath"
Assert-True -Condition (Test-Path -LiteralPath $cliEntryPath) -Message "Missing Rust CLI bin entrypoint: $cliEntryPath"
Assert-True -Condition (Test-Path -LiteralPath $ProofPath) -Message "Missing WebRTC proof file: $ProofPath"
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($ExpectedDeviceId)) -Message "Rust WebRTC proof CLI requires -ExpectedDeviceId."
Assert-True -Condition ($ExpectedFingerprint -match '^[0-9a-f]{64}$') -Message "Rust WebRTC proof CLI requires -ExpectedFingerprint as 64 lowercase hex characters."

$cargoArguments = @(
    "run",
    "--manifest-path",
    $manifestPath,
    "--bin",
    "skybridge",
    "--",
    "webrtc-proof",
    "validate",
    "--proof",
    $ProofPath,
    "--expected-device-id",
    $ExpectedDeviceId,
    "--expected-fingerprint",
    $ExpectedFingerprint,
    "--max-age-ms",
    $MaxProofAgeMs.ToString()
)
$cargoCommandLabel = "webrtc-proof validate"
$captureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-rust-webrtc-proof-cli-" + [guid]::NewGuid().ToString("N"))
$stdoutPath = Join-Path $captureRoot "stdout.txt"
$stderrPath = Join-Path $captureRoot "stderr.txt"
try {
    New-Item -ItemType Directory -Path $captureRoot | Out-Null
    $process = Start-Process `
        -FilePath "cargo" `
        -ArgumentList $cargoArguments `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    $cargoExitCode = [int]$process.ExitCode

    if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -LiteralPath $stderrPath | ForEach-Object { Write-Output $_ }
    }
    if (Test-Path -LiteralPath $stdoutPath) {
        Get-Content -LiteralPath $stdoutPath | ForEach-Object { Write-Output $_ }
    }
}
finally {
    if (Test-Path -LiteralPath $captureRoot) {
        $resolvedCaptureRoot = (Resolve-Path -LiteralPath $captureRoot).Path
        $resolvedTempParent = (Resolve-Path -LiteralPath ([System.IO.Path]::GetTempPath())).Path.TrimEnd('\')
        $captureLeaf = Split-Path -Leaf $resolvedCaptureRoot
        $isOwnedCaptureDir = $resolvedCaptureRoot.StartsWith(
            $resolvedTempParent,
            [StringComparison]::OrdinalIgnoreCase) -and $captureLeaf.StartsWith(
            "skybridge-rust-webrtc-proof-cli-",
            [StringComparison]::Ordinal)

        Assert-True -Condition $isOwnedCaptureDir -Message "Refusing to remove unexpected temp directory: $resolvedCaptureRoot"
        Remove-Item -LiteralPath $captureRoot -Recurse -Force
    }
}

Assert-True -Condition ($cargoExitCode -eq 0) -Message "Rust WebRTC proof CLI validation failed: $cargoCommandLabel."
Write-Output "rust-webrtc-proof-cli: ok proof=$ProofPath"
