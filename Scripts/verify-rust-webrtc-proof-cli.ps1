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

function ConvertTo-WindowsProcessArgument {
    param([string]$Value)

    if ($Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $result = '"'
    $backslashCount = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') {
            $backslashCount += 1
        } elseif ($char -eq '"') {
            $result += ('\' * (($backslashCount * 2) + 1))
            $result += '"'
            $backslashCount = 0
        } else {
            if ($backslashCount -gt 0) {
                $result += ('\' * $backslashCount)
                $backslashCount = 0
            }
            $result += $char
        }
    }
    if ($backslashCount -gt 0) {
        $result += ('\' * ($backslashCount * 2))
    }
    $result += '"'
    return $result
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

$cargoCommand = (Get-Command cargo -ErrorAction Stop).Source
$processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
$processStartInfo.FileName = $cargoCommand
$processStartInfo.Arguments = (($cargoArguments | ForEach-Object { ConvertTo-WindowsProcessArgument -Value $_ }) -join " ")
$processStartInfo.UseShellExecute = $false
$processStartInfo.RedirectStandardOutput = $true
$processStartInfo.RedirectStandardError = $true
$processStartInfo.CreateNoWindow = $true

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $processStartInfo
[void]$process.Start()
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$process.WaitForExit()
$cargoExitCode = [int]$process.ExitCode

$cargoOutput = @()
if (-not [string]::IsNullOrWhiteSpace($stderrTask.Result)) {
    $cargoOutput += ($stderrTask.Result -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
if (-not [string]::IsNullOrWhiteSpace($stdoutTask.Result)) {
    $cargoOutput += ($stdoutTask.Result -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

if ($null -ne $cargoOutput) {
    $cargoOutput | ForEach-Object { Write-Output $_ }
}

Assert-True -Condition ($cargoExitCode -eq 0) -Message "Rust WebRTC proof CLI validation failed: $cargoCommandLabel."
Write-Output "rust-webrtc-proof-cli: ok proof=$ProofPath"
