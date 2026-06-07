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

    Assert-True -Condition ($Text.Contains($Needle)) -Message $Message
}

$clientPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/FfiEngineClient.cs"
$coreBridgePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/CoreBridge.cs"
$discoveryClientPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/DiscoveryClient.cs"
$interfacePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/IEngineClient.cs"
$mainWindowPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/MainWindow.xaml.cs"
$architecturePath = Join-Path $RepoRoot "docs/windows-architecture.md"

foreach ($path in @($clientPath, $coreBridgePath, $discoveryClientPath, $interfacePath, $mainWindowPath, $architecturePath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing FFI client file: $path"
}

$client = Get-Content -Raw -LiteralPath $clientPath
$coreBridge = Get-Content -Raw -LiteralPath $coreBridgePath
$discoveryClient = Get-Content -Raw -LiteralPath $discoveryClientPath
$interface = Get-Content -Raw -LiteralPath $interfacePath
$mainWindow = Get-Content -Raw -LiteralPath $mainWindowPath
$architecture = Get-Content -Raw -LiteralPath $architecturePath

foreach ($member in @("ConnectAsync", "DisconnectAsync", "SendHeartbeatAsync")) {
    Assert-Contains -Text $interface -Needle $member -Message "IEngineClient missing member: $member"
    Assert-Contains -Text $client -Needle $member -Message "FfiEngineClient missing member: $member"
}

foreach ($entryPoint in @(
    "skybridge_engine_new",
    "skybridge_engine_free",
    "skybridge_engine_local_public_key",
    "skybridge_engine_connect",
    "skybridge_engine_send_heartbeat",
    "skybridge_engine_disconnect",
    "skybridge_engine_state"
)) {
    Assert-Contains -Text $client -Needle $entryPoint -Message "FfiEngineClient missing DllImport: $entryPoint"
}

foreach ($signal in @(
    "public sealed class FfiEngineClient : IEngineClient, IDisposable",
    "IPeerPublicKeyProvider",
    "GetPeerPublicKeyAsync",
    "Cannot connect without a peer public key from pairing.",
    "SemaphoreSlim",
    "GCHandle.Alloc",
    "GetLocalPublicKeyAsync",
    "RefreshStateFromCore",
    "ThrowOnError"
)) {
    Assert-Contains -Text $client -Needle $signal -Message "FfiEngineClient missing lifecycle signal: $signal"
}

Assert-True -Condition (-not $client.Contains("var peerPublicKey = ReadLocalPublicKey();")) -Message "FfiEngineClient must not use the local public key as the peer key."
Assert-Contains -Text $mainWindow -Needle "new DummyEngineClient()" -Message "MainWindow should keep the dummy client until native DLL deployment is explicit."
Assert-True -Condition (-not $mainWindow.Contains("new FfiEngineClient()")) -Message "MainWindow must not silently switch to FfiEngineClient before native DLL deployment."
Assert-Contains -Text $architecture -Needle "FfiEngineClient" -Message "Architecture doc missing FfiEngineClient status."

foreach ($signal in @(
    "ParseDiscoveryAdvertisementAsync",
    "skybridge_parse_discovery_advertisement",
    "DiscoveryAdvertisement",
    "NativeDiscoveryAdvertisement",
    "PeerCapabilities.FromNative"
)) {
    Assert-Contains -Text $coreBridge -Needle $signal -Message "CoreBridge missing discovery FFI signal: $signal"
}

Assert-Contains -Text $architecture -Needle "CoreBridge.ParseDiscoveryAdvertisementAsync" -Message "Architecture doc missing discovery CoreBridge contract."

foreach ($signal in @(
    "EncodeFrameAsync",
    "EncodeSbp2FrameAsync",
    "DecodeFrameMetadataAsync",
    "DecodeFramePayloadAsync",
    "FrameMetadata",
    "NativeFrameMetadata",
    "skybridge_encode_frame",
    "skybridge_encode_sbp2_frame",
    "skybridge_decode_frame_metadata",
    "skybridge_decode_frame_payload"
)) {
    Assert-Contains -Text $coreBridge -Needle $signal -Message "CoreBridge missing frame codec signal: $signal"
}

Assert-Contains -Text $architecture -Needle "CoreBridge.EncodeFrameAsync" -Message "Architecture doc missing frame CoreBridge contract."

foreach ($signal in @(
    "public interface IDiscoveryClient",
    "public sealed class CoreDiscoveryClient : IDiscoveryClient",
    "public sealed record DiscoveredPeer",
    "ParseDiscoveryAdvertisementAsync",
    "PublicKeyFingerprint",
    "PeerCapabilities"
)) {
    Assert-Contains -Text $discoveryClient -Needle $signal -Message "DiscoveryClient missing modular discovery signal: $signal"
}

Assert-True -Condition (-not $discoveryClient.Contains("GetPeerPublicKeyAsync")) -Message "DiscoveryClient must not treat pubKeyFP as the peer public key."
Assert-True -Condition (-not $discoveryClient.Contains("StaticPeerPublicKeyProvider")) -Message "DiscoveryClient must not create static peer-key providers from discovery fingerprints."
Assert-Contains -Text $architecture -Needle "CoreDiscoveryClient" -Message "Architecture doc missing CoreDiscoveryClient status."

Write-Output "windows-ffi-client: ok"
