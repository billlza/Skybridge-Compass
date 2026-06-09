param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [double]$MinimumLineCoverage = 90.0
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

function Get-LineCoverage {
    param(
        [string]$CoverageText,
        [string]$RowName
    )

    $line = ($CoverageText -split "\r?\n") |
        Where-Object { $_ -match "^\s*$([regex]::Escape($RowName))\s+" } |
        Select-Object -First 1
    Assert-True -Condition ($null -ne $line) -Message "Coverage row missing: $RowName"

    $matches = [regex]::Matches($line, "([0-9]+(?:\.[0-9]+)?)%")
    Assert-True -Condition ($matches.Count -ge 3) -Message "Coverage row does not include line coverage: $line"
    return [double]::Parse($matches[2].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-NativeLibraryFileName {
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        return "skybridge_core.dll"
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        return "libskybridge_core.dylib"
    }

    return "libskybridge_core.so"
}

function Join-ProcessArguments {
    param([string[]]$Arguments)

    return ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        }
        else {
            $_
        }
    }) -join " "
}

function Invoke-NativeCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
    $startInfo.WorkingDirectory = (Get-Location).Path
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    $textParts = @()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $textParts += $stdout.TrimEnd()
    }

    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $textParts += $stderr.TrimEnd()
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Text = ($textParts -join [Environment]::NewLine)
    }
}

$coreRoot = Join-Path $RepoRoot "core/skybridge-core"
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "Cargo.toml")) -Message "Missing Rust core Cargo.toml: $coreRoot"

$cliSmokePath = Join-Path $coreRoot "tests/cli_smoke.rs"
Assert-True -Condition (Test-Path -LiteralPath $cliSmokePath) -Message "Missing CLI smoke tests: $cliSmokePath"
$cliSmoke = Get-Content -Raw -LiteralPath $cliSmokePath
$ffiLifecyclePath = Join-Path $coreRoot "tests/ffi_lifecycle.rs"
Assert-True -Condition (Test-Path -LiteralPath $ffiLifecyclePath) -Message "Missing FFI lifecycle tests: $ffiLifecyclePath"
$ffiLifecycle = Get-Content -Raw -LiteralPath $ffiLifecyclePath
$sessionPath = Join-Path $coreRoot "src/session.rs"
Assert-True -Condition (Test-Path -LiteralPath $sessionPath) -Message "Missing session core source: $sessionPath"
$session = Get-Content -Raw -LiteralPath $sessionPath
$transportPath = Join-Path $coreRoot "src/transport.rs"
Assert-True -Condition (Test-Path -LiteralPath $transportPath) -Message "Missing transport core source: $transportPath"
$transport = Get-Content -Raw -LiteralPath $transportPath

foreach ($signal in @(
    "cli_version_smoke",
    "cli_apple_to_apple_selects_apple_native",
    "cli_apple_to_apple_connection_plan_keeps_apple_native_channels",
    "cli_windows_same_lan_selects_msquic",
    "cli_windows_to_apple_selects_webrtc_interop",
    "cli_transport_bind_reports_binding_digest",
    "cli_transport_bind_accepts_relay_id",
    "cli_suite_offer_lists_provider_derived_suites",
    "cli_suite_select_prefers_pqc_suite",
    "cli_suite_select_blocks_timeout_downgrade",
    "cli_channel_profile_reports_default_reliability",
    "cli_channel_map_reports_transport_binding",
    "cli_frame_describe_accepts_plain_frame",
    "cli_frame_describe_reports_roundtrip_metadata",
    "cli_connection_plan_reports_core_contract",
    "cli_discovery_parse_accepts_mac_bonjour_txt",
    "cli_webrtc_proof_validate_accepts_schema_smoke",
    "cli_webrtc_proof_validate_rejects_missing_sbf1_smoke",
    "cli_no_args_prints_help_smoke",
    "cli_rejects_incomplete_transport_command",
    "cli_rejects_unknown_command",
    "cli_rejects_invalid_suite_id_smoke",
    "cli_rejects_bad_discovery_txt_smoke",
    "cli_rejects_too_small_sbp2_frame_smoke",
    "PurePqcPreferred",
    "flags=0x0002",
    "InvalidPublicKeyFingerprint",
    "TargetTooSmall",
    "invalid suite id: 0xzz",
    "webrtc-proof validate",
    "webrtc_proof=valid",
    "SBF1 echo frame"
)) {
    Assert-True -Condition ($cliSmoke.Contains($signal)) -Message "CLI smoke coverage missing signal: $signal"
}

foreach ($signal in @(
    "ffi_connection_plan_keeps_apple_to_apple_native",
    "ffi_connect_rejects_channel_binding_transport_mismatch",
    "SkybridgeTransportKind::AppleNative",
    "SkybridgeTransportAuditCode::AppleNativeDefault",
    "SkybridgeAdapterBindingKind::AppleStream",
    "SkybridgeAdapterBindingKind::AppleDatagram"
)) {
    Assert-True -Condition ($ffiLifecycle.Contains($signal)) -Message "FFI Apple-native coverage missing signal: $signal"
}

foreach ($signal in @(
    "is_binding_kind_valid_for_transport",
    "config_validation_rejects_transport_channel_binding_mismatch",
    "does not match WebRtcDataChannel"
)) {
    Assert-True -Condition ($session.Contains($signal)) -Message "Session transport binding validation missing signal: $signal"
}

foreach ($signal in @(
    "windows_to_apple_same_lan_never_uses_apple_native",
    "TransportAuditReason::WebRtcInterop",
    "RelayPolicy::NotNeeded"
)) {
    Assert-True -Condition ($transport.Contains($signal)) -Message "Transport Apple interop invariant missing signal: $signal"
}

Push-Location $coreRoot
try {
    $buildResult = Invoke-NativeCommand -FilePath "cargo" -Arguments @("build", "--lib")
    if (-not [string]::IsNullOrWhiteSpace($buildResult.Text)) {
        Write-Output $buildResult.Text
    }

    Assert-True -Condition ($buildResult.ExitCode -eq 0) -Message "cargo build --lib failed."
    $nativeLibraryPath = Join-Path (Join-Path $coreRoot "target/debug") (Get-NativeLibraryFileName)
    Assert-True -Condition (Test-Path -LiteralPath $nativeLibraryPath) -Message "Missing native skybridge_core library after cargo build --lib: $nativeLibraryPath"

    $testResult = Invoke-NativeCommand -FilePath "cargo" -Arguments @("test")
    if (-not [string]::IsNullOrWhiteSpace($testResult.Text)) {
        Write-Output $testResult.Text
    }

    Assert-True -Condition ($testResult.ExitCode -eq 0) -Message "cargo test failed."

    $coverageResult = Invoke-NativeCommand -FilePath "cargo" -Arguments @("llvm-cov", "--fail-under-lines", "$MinimumLineCoverage", "--summary-only")
    $coverageText = $coverageResult.Text
    Write-Output $coverageText
    Assert-True -Condition ($coverageResult.ExitCode -eq 0) -Message "cargo llvm-cov failed or total line coverage is below $MinimumLineCoverage%."

    $totalLineCoverage = Get-LineCoverage -CoverageText $coverageText -RowName "TOTAL"
    $cliLineCoverage = Get-LineCoverage -CoverageText $coverageText -RowName "cli.rs"
    Assert-True -Condition ($totalLineCoverage -ge $MinimumLineCoverage) -Message "Total line coverage $totalLineCoverage% is below $MinimumLineCoverage%."
    Assert-True -Condition ($cliLineCoverage -ge $MinimumLineCoverage) -Message "cli.rs line coverage $cliLineCoverage% is below $MinimumLineCoverage%."
}
finally {
    Pop-Location
}

Write-Output "rust-cli-coverage: ok"
