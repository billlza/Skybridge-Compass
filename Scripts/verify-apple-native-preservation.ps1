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

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    Assert-True -Condition $Text.Contains($Needle) -Message $Message
}

function Assert-NotContains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    Assert-True -Condition (-not $Text.Contains($Needle)) -Message $Message
}

function Invoke-SkybridgeCli {
    param([string[]]$Arguments)

    $LASTEXITCODE = 0
    $output = & cargo run --quiet --manifest-path $coreManifest --bin skybridge -- @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    Assert-True -Condition ($exitCode -eq 0) -Message "skybridge CLI command failed exitCode=$exitCode args=$($Arguments -join ' ') output=$text"
    return $text
}

$coreRoot = Join-Path $RepoRoot "core/skybridge-core"
$coreManifest = Join-Path $coreRoot "Cargo.toml"
$cliSmokePath = Join-Path $coreRoot "tests/cli_smoke.rs"
$transportSourcePath = Join-Path $coreRoot "src/transport.rs"
$connectionSourcePath = Join-Path $coreRoot "src/connection.rs"

foreach ($path in @($coreManifest, $cliSmokePath, $transportSourcePath, $connectionSourcePath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing Apple-native preservation source: $path"
}

$cliSmoke = Get-Content -Raw -LiteralPath $cliSmokePath
$transportSource = Get-Content -Raw -LiteralPath $transportSourcePath
$connectionSource = Get-Content -Raw -LiteralPath $connectionSourcePath

foreach ($signal in @(
    "cli_apple_to_apple_selects_apple_native",
    "cli_ios_to_macos_selects_apple_native",
    "cli_windows_to_ios_selects_webrtc_interop",
    "cli_apple_to_apple_connection_plan_keeps_apple_native_channels",
    "cli_windows_to_apple_same_lan_connection_plan_uses_webrtc",
    "cli_windows_to_apple_selects_webrtc_interop",
    "cli_windows_same_lan_selects_msquic"
)) {
    Assert-Contains -Text $cliSmoke -Needle $signal -Message "CLI smoke test suite missing Apple-native preservation signal: $signal"
}

foreach ($signal in @(
    "apple_peers_keep_native_transport_ahead_of_webrtc",
    "windows_to_apple_same_lan_never_uses_apple_native",
    "windows_to_apple_selects_webrtc_interop",
    "windows_same_lan_prefers_msquic_over_webrtc"
)) {
    Assert-Contains -Text $transportSource -Needle $signal -Message "Transport source missing Apple-native preservation invariant: $signal"
}

foreach ($signal in @(
    "apple_to_apple_plan_keeps_native_transport_not_webrtc",
    "windows_to_apple_plan_uses_webrtc_distinct_channels_and_pqc_suite"
)) {
    Assert-Contains -Text $connectionSource -Needle $signal -Message "Connection source missing Apple-native preservation invariant: $signal"
}

$appleTransport = Invoke-SkybridgeCli -Arguments @(
    "transport",
    "select",
    "--local",
    "macos",
    "--remote",
    "ios",
    "--path",
    "same-lan"
)
Assert-Contains -Text $appleTransport -Needle "kind=AppleNative" -Message "Apple-to-Apple transport must stay AppleNative."
Assert-Contains -Text $appleTransport -Needle "audit=AppleNativeDefault" -Message "Apple-to-Apple transport must keep AppleNativeDefault audit."
Assert-Contains -Text $appleTransport -Needle "relay_allowed=false" -Message "Apple-to-Apple transport must not require relay/WebRTC fallback by default."
Assert-NotContains -Text $appleTransport -Needle "WebRtcDataChannel" -Message "Apple-to-Apple transport must not be replaced by WebRTC."

$iosMacTransport = Invoke-SkybridgeCli -Arguments @(
    "transport",
    "select",
    "--local",
    "ios",
    "--remote",
    "macos",
    "--path",
    "same-lan"
)
Assert-Contains -Text $iosMacTransport -Needle "kind=AppleNative" -Message "iOS-to-macOS transport must stay AppleNative."
Assert-Contains -Text $iosMacTransport -Needle "audit=AppleNativeDefault" -Message "iOS-to-macOS transport must keep AppleNativeDefault audit."
Assert-NotContains -Text $iosMacTransport -Needle "WebRtcDataChannel" -Message "iOS-to-macOS transport must not be replaced by WebRTC."

$appleConnection = Invoke-SkybridgeCli -Arguments @(
    "connection",
    "plan",
    "--local",
    "macos",
    "--remote",
    "ios",
    "--path",
    "same-lan",
    "--local-caps",
    "xwing,mlkem,x25519",
    "--remote-suites",
    "0x0001,0x0101,0x1001",
    "--sbp2-fixed",
    "512"
)
Assert-Contains -Text $appleConnection -Needle "transport=AppleNative" -Message "Apple-to-Apple connection plan must stay AppleNative."
Assert-Contains -Text $appleConnection -Needle "transport_audit=AppleNativeDefault" -Message "Apple-to-Apple connection plan must keep AppleNativeDefault audit."
Assert-Contains -Text $appleConnection -Needle "channel_count=5" -Message "Apple-to-Apple plan must keep all five Core channels."
Assert-Contains -Text $appleConnection -Needle "channel.control=AppleStream:skybridge.control" -Message "Apple control channel must keep AppleStream binding."
Assert-Contains -Text $appleConnection -Needle "channel.file=AppleStream:skybridge.file" -Message "Apple file channel must keep AppleStream binding."
Assert-Contains -Text $appleConnection -Needle "channel.telemetry=AppleDatagram:skybridge.telemetry" -Message "Apple telemetry channel must keep AppleDatagram binding."
Assert-Contains -Text $appleConnection -Needle "channel.realtime=AppleDatagram:skybridge.realtime" -Message "Apple realtime channel must keep AppleDatagram binding."
Assert-NotContains -Text $appleConnection -Needle "transport=WebRtcDataChannel" -Message "Apple-to-Apple connection plan must not switch to WebRTC."

$appleCrossNatTransport = Invoke-SkybridgeCli -Arguments @(
    "transport",
    "select",
    "--local",
    "macos",
    "--remote",
    "ios",
    "--path",
    "cross-nat"
)
Assert-Contains -Text $appleCrossNatTransport -Needle "kind=AppleNative" -Message "Apple-to-Apple cross-NAT transport must stay AppleNative."
Assert-Contains -Text $appleCrossNatTransport -Needle "audit=AppleNativeDefault" -Message "Apple-to-Apple cross-NAT transport must keep AppleNativeDefault audit."
Assert-Contains -Text $appleCrossNatTransport -Needle "relay_allowed=false" -Message "Apple-to-Apple cross-NAT transport must not require WebRTC relay by default."
Assert-NotContains -Text $appleCrossNatTransport -Needle "WebRtcDataChannel" -Message "Apple-to-Apple cross-NAT transport must not be replaced by WebRTC."

$appleCrossNatConnection = Invoke-SkybridgeCli -Arguments @(
    "connection",
    "plan",
    "--local",
    "macos",
    "--remote",
    "ios",
    "--path",
    "cross-nat",
    "--local-caps",
    "xwing,mlkem,x25519",
    "--remote-suites",
    "0x0001,0x0101,0x1001",
    "--sbp2-fixed",
    "512"
)
Assert-Contains -Text $appleCrossNatConnection -Needle "transport=AppleNative" -Message "Apple-to-Apple cross-NAT connection plan must stay AppleNative."
Assert-Contains -Text $appleCrossNatConnection -Needle "transport_audit=AppleNativeDefault" -Message "Apple-to-Apple cross-NAT connection plan must keep AppleNativeDefault audit."
Assert-Contains -Text $appleCrossNatConnection -Needle "channel.control=AppleStream:skybridge.control" -Message "Apple cross-NAT control channel must keep AppleStream binding."
Assert-Contains -Text $appleCrossNatConnection -Needle "channel.telemetry=AppleDatagram:skybridge.telemetry" -Message "Apple cross-NAT telemetry channel must keep AppleDatagram binding."
Assert-NotContains -Text $appleCrossNatConnection -Needle "transport=WebRtcDataChannel" -Message "Apple-to-Apple cross-NAT connection plan must not switch to WebRTC."

$windowsAppleTransport = Invoke-SkybridgeCli -Arguments @(
    "transport",
    "select",
    "--local",
    "windows",
    "--remote",
    "macos",
    "--path",
    "same-lan"
)
Assert-Contains -Text $windowsAppleTransport -Needle "kind=WebRtcDataChannel" -Message "Windows-to-Apple transport must use WebRTC interop."
Assert-Contains -Text $windowsAppleTransport -Needle "audit=WebRtcInterop" -Message "Windows-to-Apple transport must report WebRtcInterop audit."
Assert-NotContains -Text $windowsAppleTransport -Needle "AppleNative" -Message "Windows-to-Apple transport must not claim AppleNative."

$windowsIosTransport = Invoke-SkybridgeCli -Arguments @(
    "transport",
    "select",
    "--local",
    "windows",
    "--remote",
    "ios",
    "--path",
    "same-lan"
)
Assert-Contains -Text $windowsIosTransport -Needle "kind=WebRtcDataChannel" -Message "Windows-to-iOS transport must use WebRTC interop."
Assert-Contains -Text $windowsIosTransport -Needle "audit=WebRtcInterop" -Message "Windows-to-iOS transport must report WebRtcInterop audit."
Assert-NotContains -Text $windowsIosTransport -Needle "AppleNative" -Message "Windows-to-iOS transport must not claim AppleNative."

$windowsAppleConnection = Invoke-SkybridgeCli -Arguments @(
    "connection",
    "plan",
    "--local",
    "windows",
    "--remote",
    "macos",
    "--path",
    "same-lan",
    "--local-caps",
    "xwing,mlkem,x25519",
    "--remote-suites",
    "0x0001,0x0101,0x1001",
    "--sbp2-fixed",
    "512"
)
Assert-Contains -Text $windowsAppleConnection -Needle "transport=WebRtcDataChannel" -Message "Windows-to-Apple connection plan must use WebRTC DataChannel."
Assert-Contains -Text $windowsAppleConnection -Needle "transport_audit=WebRtcInterop" -Message "Windows-to-Apple connection plan must report WebRtcInterop audit."
Assert-Contains -Text $windowsAppleConnection -Needle "channel_count=5" -Message "Windows-to-Apple plan must keep all five Core channels."
Assert-Contains -Text $windowsAppleConnection -Needle "channel.control=WebRtcDataChannel:skybridge.control" -Message "Windows-to-Apple control channel must use WebRTC DataChannel."
Assert-Contains -Text $windowsAppleConnection -Needle "channel.telemetry=WebRtcDataChannel:skybridge.telemetry" -Message "Windows-to-Apple telemetry channel must use WebRTC DataChannel."
Assert-NotContains -Text $windowsAppleConnection -Needle "AppleStream" -Message "Windows-to-Apple plan must not consume AppleStream bindings."
Assert-NotContains -Text $windowsAppleConnection -Needle "AppleDatagram" -Message "Windows-to-Apple plan must not consume AppleDatagram bindings."

$windowsAppleCrossNatTransport = Invoke-SkybridgeCli -Arguments @(
    "transport",
    "select",
    "--local",
    "windows",
    "--remote",
    "macos",
    "--path",
    "cross-nat"
)
Assert-Contains -Text $windowsAppleCrossNatTransport -Needle "kind=WebRtcDataChannel" -Message "Windows-to-Apple cross-NAT transport must use WebRTC interop."
Assert-Contains -Text $windowsAppleCrossNatTransport -Needle "audit=WebRtcInterop" -Message "Windows-to-Apple cross-NAT transport must report WebRtcInterop audit."
Assert-NotContains -Text $windowsAppleCrossNatTransport -Needle "AppleNative" -Message "Windows-to-Apple cross-NAT transport must not claim AppleNative."

$windowsAppleCrossNatConnection = Invoke-SkybridgeCli -Arguments @(
    "connection",
    "plan",
    "--local",
    "windows",
    "--remote",
    "macos",
    "--path",
    "cross-nat",
    "--local-caps",
    "xwing,mlkem,x25519",
    "--remote-suites",
    "0x0001,0x0101,0x1001",
    "--sbp2-fixed",
    "512"
)
Assert-Contains -Text $windowsAppleCrossNatConnection -Needle "transport=WebRtcDataChannel" -Message "Windows-to-Apple cross-NAT connection plan must use WebRTC DataChannel."
Assert-Contains -Text $windowsAppleCrossNatConnection -Needle "transport_audit=WebRtcInterop" -Message "Windows-to-Apple cross-NAT connection plan must report WebRtcInterop audit."
Assert-Contains -Text $windowsAppleCrossNatConnection -Needle "channel.control=WebRtcDataChannel:skybridge.control" -Message "Windows-to-Apple cross-NAT control channel must use WebRTC DataChannel."
Assert-Contains -Text $windowsAppleCrossNatConnection -Needle "channel.telemetry=WebRtcDataChannel:skybridge.telemetry" -Message "Windows-to-Apple cross-NAT telemetry channel must use WebRTC DataChannel."
Assert-NotContains -Text $windowsAppleCrossNatConnection -Needle "AppleStream" -Message "Windows-to-Apple cross-NAT plan must not consume AppleStream bindings."
Assert-NotContains -Text $windowsAppleCrossNatConnection -Needle "AppleDatagram" -Message "Windows-to-Apple cross-NAT plan must not consume AppleDatagram bindings."

$windowsTransport = Invoke-SkybridgeCli -Arguments @(
    "transport",
    "select",
    "--local",
    "windows",
    "--remote",
    "windows",
    "--path",
    "same-lan"
)
Assert-Contains -Text $windowsTransport -Needle "kind=WindowsNativeMsQuic" -Message "Windows-to-Windows same-LAN transport must prefer MSQUIC."
Assert-Contains -Text $windowsTransport -Needle "audit=WindowsNativeMsQuicSameLan" -Message "Windows-to-Windows same-LAN transport must keep MSQUIC audit."
Assert-NotContains -Text $windowsTransport -Needle "AppleNative" -Message "Windows-to-Windows transport must not claim AppleNative."

Write-Output "apple-native-preservation: ok"
