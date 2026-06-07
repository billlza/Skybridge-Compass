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
$discoveryBrowserPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/DiscoveryBrowserClient.cs"
$manualConnectionPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/ManualConnectionClient.cs"
$crossNetworkPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/CrossNetworkConnectionClient.cs"
$pairingPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/PairingMaterialClient.cs"
$connectionPreflightPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/ConnectionPreflightClient.cs"
$connectionWorkspaceStatePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/ConnectionWorkspaceStateClient.cs"
$usbManagementPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/UsbManagementWorkspaceClient.cs"
$coreDiagnosticsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/CoreDiagnosticsClient.cs"
$fileTransferPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/FileTransferWorkspaceClient.cs"
$workspaceActionCatalogPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/WorkspaceActionCatalogClient.cs"
$remoteDesktopPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/RemoteDesktopWorkspaceClient.cs"
$systemMonitorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/SystemMonitorWorkspaceClient.cs"
$settingsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/SettingsWorkspaceClient.cs"
$dashboardMetricsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/DashboardMetricsClient.cs"
$topBarStatusPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/TopBarStatusClient.cs"
$interfacePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/IEngineClient.cs"
$mainWindowPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/MainWindow.xaml.cs"
$architecturePath = Join-Path $RepoRoot "docs/windows-architecture.md"

foreach ($path in @($clientPath, $coreBridgePath, $discoveryClientPath, $discoveryBrowserPath, $manualConnectionPath, $crossNetworkPath, $pairingPath, $connectionPreflightPath, $connectionWorkspaceStatePath, $usbManagementPath, $coreDiagnosticsPath, $fileTransferPath, $workspaceActionCatalogPath, $remoteDesktopPath, $systemMonitorPath, $settingsPath, $dashboardMetricsPath, $topBarStatusPath, $interfacePath, $mainWindowPath, $architecturePath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing FFI client file: $path"
}

$client = Get-Content -Raw -LiteralPath $clientPath
$coreBridge = Get-Content -Raw -LiteralPath $coreBridgePath
$discoveryClient = Get-Content -Raw -LiteralPath $discoveryClientPath
$discoveryBrowser = Get-Content -Raw -LiteralPath $discoveryBrowserPath
$manualConnection = Get-Content -Raw -LiteralPath $manualConnectionPath
$crossNetwork = Get-Content -Raw -LiteralPath $crossNetworkPath
$pairing = Get-Content -Raw -LiteralPath $pairingPath
$connectionPreflight = Get-Content -Raw -LiteralPath $connectionPreflightPath
$connectionWorkspaceState = Get-Content -Raw -LiteralPath $connectionWorkspaceStatePath
$usbManagement = Get-Content -Raw -LiteralPath $usbManagementPath
$coreDiagnostics = Get-Content -Raw -LiteralPath $coreDiagnosticsPath
$fileTransfer = Get-Content -Raw -LiteralPath $fileTransferPath
$workspaceActionCatalog = Get-Content -Raw -LiteralPath $workspaceActionCatalogPath
$remoteDesktop = Get-Content -Raw -LiteralPath $remoteDesktopPath
$systemMonitor = Get-Content -Raw -LiteralPath $systemMonitorPath
$settings = Get-Content -Raw -LiteralPath $settingsPath
$dashboardMetrics = Get-Content -Raw -LiteralPath $dashboardMetricsPath
$topBarStatus = Get-Content -Raw -LiteralPath $topBarStatusPath
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
Assert-Contains -Text $mainWindow -Needle "var coreBridge = new CoreBridge();" -Message "MainWindow should create one explicit CoreBridge for manual Core tools."
Assert-Contains -Text $mainWindow -Needle "var discoveryClient = new CoreDiscoveryClient(coreBridge);" -Message "MainWindow should create one explicit CoreDiscoveryClient for discovery parsing and browsing."
Assert-Contains -Text $mainWindow -Needle "new WindowsDiscoveryBrowserClient(discoveryClient)" -Message "MainWindow should wire WindowsDiscoveryBrowserClient for explicit DNS-SD browse boundary snapshots."
Assert-Contains -Text $mainWindow -Needle "new ManualConnectionClient()" -Message "MainWindow should wire ManualConnectionClient for explicit manual target validation."
Assert-Contains -Text $mainWindow -Needle "new CrossNetworkConnectionClient()" -Message "MainWindow should wire CrossNetworkConnectionClient for explicit QR/code envelope validation."
Assert-Contains -Text $mainWindow -Needle "new PairingMaterialClient()" -Message "MainWindow should wire PairingMaterialClient for explicit manual pairing-code validation."
Assert-Contains -Text $mainWindow -Needle "new ConnectionPreflightClient(coreBridge)" -Message "MainWindow should wire ConnectionPreflightClient for explicit connection preflight."
Assert-Contains -Text $mainWindow -Needle "new ConnectionWorkspaceStateClient()" -Message "MainWindow should wire ConnectionWorkspaceStateClient for explicit connection state gates."
Assert-Contains -Text $mainWindow -Needle "new CoreDiagnosticsClient(coreBridge)" -Message "MainWindow should wire CoreDiagnosticsClient for explicit Quantum diagnostics."
Assert-Contains -Text $mainWindow -Needle "new FileTransferWorkspaceClient(coreBridge)" -Message "MainWindow should wire FileTransferWorkspaceClient for explicit File Transfer diagnostics."
Assert-Contains -Text $mainWindow -Needle "new WorkspaceActionCatalogClient()" -Message "MainWindow should wire WorkspaceActionCatalogClient for explicit workspace action order."
Assert-Contains -Text $mainWindow -Needle "new RemoteDesktopWorkspaceClient(coreBridge)" -Message "MainWindow should wire RemoteDesktopWorkspaceClient for explicit Remote Desktop diagnostics."
Assert-Contains -Text $mainWindow -Needle "new SystemMonitorWorkspaceClient()" -Message "MainWindow should wire SystemMonitorWorkspaceClient for explicit System Monitor diagnostics."
Assert-Contains -Text $mainWindow -Needle "new UsbManagementWorkspaceClient()" -Message "MainWindow should wire UsbManagementWorkspaceClient for explicit USB Management diagnostics."
Assert-Contains -Text $mainWindow -Needle "new SettingsWorkspaceClient()" -Message "MainWindow should wire SettingsWorkspaceClient for explicit Settings diagnostics."
Assert-Contains -Text $mainWindow -Needle "new DashboardMetricsClient()" -Message "MainWindow should wire DashboardMetricsClient for explicit dashboard metrics parity."
Assert-Contains -Text $mainWindow -Needle "new TopBarStatusClient()" -Message "MainWindow should wire TopBarStatusClient for explicit top-bar status parity."

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
    "ComputeTransportBindingDigestAsync",
    "TransportBindingMaterial",
    "NativeTransportBindingDigest",
    "skybridge_transport_binding_digest"
)) {
    Assert-Contains -Text $coreBridge -Needle $signal -Message "CoreBridge missing transport binding FFI signal: $signal"
}

Assert-Contains -Text $architecture -Needle "CoreBridge.ComputeTransportBindingDigestAsync" -Message "Architecture doc missing transport binding CoreBridge contract."

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

foreach ($signal in @(
    "public interface IDiscoveryBrowserClient",
    "public sealed class WindowsDiscoveryBrowserClient : IDiscoveryBrowserClient",
    "BuildReadOnlySnapshotAsync",
    "DiscoveryBrowserRequest",
    "DiscoveryBrowserAction",
    "Start",
    "Stop",
    "Refresh",
    "ExtendedSearch",
    "_skybridge._udp",
    "_skybridge._tcp",
    "DnsServiceBrowse",
    "DnsServiceRegister",
    "CoreDiscoveryClient",
    "pubKeyFP remains fingerprint-only"
)) {
    Assert-Contains -Text $discoveryBrowser -Needle $signal -Message "DiscoveryBrowserClient missing browse boundary signal: $signal"
}

Assert-Contains -Text $architecture -Needle "WindowsDiscoveryBrowserClient" -Message "Architecture doc missing WindowsDiscoveryBrowserClient status."

foreach ($signal in @(
    "public interface IManualConnectionClient",
    "public sealed class ManualConnectionClient : IManualConnectionClient",
    "BuildReadOnlySnapshotAsync",
    "ManualConnectionRequest",
    "ManualConnectionTarget",
    "ManualConnectionSnapshot",
    "NormalizeHost",
    "ParsePort",
    "11550",
    "_skybridge._tcp",
    "Code is routing or pairing input only; it is never treated as a peer public key.",
    "no connection started",
    "FfiEngineClient"
)) {
    Assert-Contains -Text $manualConnection -Needle $signal -Message "ManualConnectionClient missing manual boundary signal: $signal"
}

Assert-Contains -Text $architecture -Needle "ManualConnectionClient" -Message "Architecture doc missing ManualConnectionClient status."

foreach ($signal in @(
    "public interface ICrossNetworkConnectionClient",
    "public sealed class CrossNetworkConnectionClient : ICrossNetworkConnectionClient",
    "BuildReadOnlySnapshotAsync",
    "CrossNetworkConnectionAction",
    "GenerateQrCode",
    "ScanQrCode",
    "GenerateCode",
    "RegenerateCode",
    "CopyCode",
    "ConnectWithCode",
    "NormalizeConnectionCode",
    "ExtractQrPayload",
    "DecodeBase64Payload",
    "AnalyzeQrPayload",
    "AnalyzeSignedQrPayload",
    "AnalyzeDynamicQrCodeData",
    "AnalyzeCanonicalQrPayload",
    "skybridge://connect/",
    "skybridge://connect?data=",
    "SignedQRPayload",
    "DynamicQRCodeData",
    "QRCodeSignatureEnvelope",
    "QRCodeSignatureQuery",
    "sessionID",
    "deviceFingerprint",
    "publicKey",
    "signingPublicKey",
    "signature",
    "signatureTimestamp",
    "expiresAt",
    "signatureBase64",
    "publicKeyBase64",
    "publicKeyFingerprint",
    "ABCDEFGHJKLMNPQRSTUVWXYZ23456789",
    "5 minutes",
    "10 minutes",
    "sig/pk/ts/fp required",
    "QR signature verified",
    "QR payload validated",
    "Scan Error: QR code expired.",
    "P256 raw signature verified",
    "P256 canonical signature verified",
    "pending canonical verifier",
    "DSASignatureFormat.IeeeP1363FixedFieldConcatenation",
    "QrSignatureChallengeLifetimeSeconds",
    "CrossNetworkReadiness",
    "no WebRTC offerer started",
    "no WebRTC answerer started",
    "no signaling room registered",
    "FfiEngineClient"
)) {
    Assert-Contains -Text $crossNetwork -Needle $signal -Message "CrossNetworkConnectionClient missing QR/code boundary signal: $signal"
}

Assert-Contains -Text $architecture -Needle "CrossNetworkConnectionClient" -Message "Architecture doc missing CrossNetworkConnectionClient status."

foreach ($signal in @(
    "public interface IPairingMaterialClient",
    "public sealed class PairingMaterialClient : IPairingMaterialClient",
    "ParseConnectionCodeAsync",
    "skybridge-pair:v1",
    "pubKeyFP",
    "DecodeBase64Url",
    "SHA256.HashData",
    "expectedPublicKeyFingerprint",
    "Pairing code public key does not match pubKeyFP.",
    "ToPeerPublicKeyProvider",
    "StaticPeerPublicKeyProvider"
)) {
    Assert-Contains -Text $pairing -Needle $signal -Message "PairingMaterialClient missing pairing signal: $signal"
}

Assert-Contains -Text $architecture -Needle "PairingMaterialClient" -Message "Architecture doc missing PairingMaterialClient status."

foreach ($signal in @(
    "public interface IConnectionPreflightClient",
    "public sealed class ConnectionPreflightClient : IConnectionPreflightClient",
    "BuildReadOnlySnapshotAsync",
    "Pairing material must be validated against the discovered peer before connection preflight.",
    "PlanConnectionAsync",
    "ComputeTransportBindingDigestAsync",
    "TransportBindingMaterial",
    "MapChannelAsync",
    "TrafficPaddingPlan.Sbp2Fixed",
    "ToPeerPublicKeyProvider",
    "No connection attempt is started"
)) {
    Assert-Contains -Text $connectionPreflight -Needle $signal -Message "ConnectionPreflightClient missing preflight signal: $signal"
}

Assert-Contains -Text $architecture -Needle "ConnectionPreflightClient" -Message "Architecture doc missing ConnectionPreflightClient status."

foreach ($signal in @(
    "public interface IConnectionWorkspaceStateClient",
    "public sealed class ConnectionWorkspaceStateClient : IConnectionWorkspaceStateClient",
    "BuildInputResetPatch",
    "BuildErrorPatch",
    "BuildDiscoveryBrowserResultPatch",
    "BuildManualTargetPreparedPatch",
    "BuildCrossNetworkPreparedPatch",
    "BuildDiscoveryPeerValidatedPatch",
    "BuildPairingValidatedPatch",
    "BuildPreflightReadiness",
    "BuildPreflightPreparedPatch",
    "ConnectionWorkspaceResetReason",
    "ConnectionWorkspaceStatusPatch",
    "ConnectionWorkspacePreflightReadiness",
    "Parse a Core-validated discovery TXT record before connection preflight.",
    "Validate pairing material before connection preflight."
)) {
    Assert-Contains -Text $connectionWorkspaceState -Needle $signal -Message "ConnectionWorkspaceStateClient missing connection state signal: $signal"
}

Assert-Contains -Text $architecture -Needle "ConnectionWorkspaceStateClient" -Message "Architecture doc missing ConnectionWorkspaceStateClient status."
Assert-True -Condition (-not $connectionWorkspaceState.Contains("FfiEngineClient")) -Message "ConnectionWorkspaceStateClient must not call or reference FfiEngineClient."
Assert-True -Condition (-not $connectionWorkspaceState.Contains("WebRTC")) -Message "ConnectionWorkspaceStateClient must not start or own WebRTC adapters."
Assert-True -Condition (-not $connectionWorkspaceState.Contains("signaling")) -Message "ConnectionWorkspaceStateClient must not own signaling side effects."

foreach ($signal in @(
    "public interface IUsbManagementWorkspaceClient",
    "public sealed class UsbManagementWorkspaceClient : IUsbManagementWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "DriveInfo.GetDrives",
    "DriveType.Removable",
    "UsbDeviceStat",
    "UsbDeviceItem",
    "provider pending",
    "not available via DriveInfo"
)) {
    Assert-Contains -Text $usbManagement -Needle $signal -Message "UsbManagementWorkspaceClient missing Windows USB signal: $signal"
}

Assert-Contains -Text $architecture -Needle "UsbManagementWorkspaceClient" -Message "Architecture doc missing UsbManagementWorkspaceClient status."

foreach ($signal in @(
    "public interface ICoreDiagnosticsClient",
    "public sealed class CoreDiagnosticsClient : ICoreDiagnosticsClient",
    "BuildInteropSnapshotAsync",
    "PlanConnectionAsync",
    "ComputeTransportBindingDigestAsync",
    "Transport binding digest",
    "MapChannelAsync",
    "EncodeSbp2FrameAsync",
    "DecodeFrameMetadataAsync",
    "DecodeFramePayloadAsync"
)) {
    Assert-Contains -Text $coreDiagnostics -Needle $signal -Message "CoreDiagnosticsClient missing Core diagnostic signal: $signal"
}

Assert-Contains -Text $architecture -Needle "CoreDiagnosticsClient" -Message "Architecture doc missing CoreDiagnosticsClient status."

foreach ($signal in @(
    "origin/tdsc-2026-01-0318-ios-sim-fix",
    "Docs/CoreLayering.md",
    "SkyBridgeProtocolCore",
    "SkyBridgeAppleTransport",
    "Docs/ProtocolAlignmentPlan.md",
    "binary handshake path is the only wire protocol",
    "legacy JSON handshake is no longer present",
    "Docs/CrossPlatformDiscoveryDesign.md",
    "lower precedence than the ADR",
    "MsQuic v2.5.8"
)) {
    Assert-Contains -Text $architecture -Needle $signal -Message "Architecture doc missing TDSC source-hierarchy signal: $signal"
}

foreach ($signal in @(
    "public interface IFileTransferWorkspaceClient",
    "public sealed class FileTransferWorkspaceClient : IFileTransferWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "MapChannelAsync",
    "EncodeFrameAsync",
    "DecodeFrameMetadataAsync",
    "FileTransferSecurityFact",
    "HMAC",
    "Signature"
)) {
    Assert-Contains -Text $fileTransfer -Needle $signal -Message "FileTransferWorkspaceClient missing Core file-transfer signal: $signal"
}

Assert-Contains -Text $architecture -Needle "FileTransferWorkspaceClient" -Message "Architecture doc missing FileTransferWorkspaceClient status."

foreach ($signal in @(
    "public interface IWorkspaceActionCatalogClient",
    "public sealed class WorkspaceActionCatalogClient : IWorkspaceActionCatalogClient",
    "BuildReadOnlySnapshot",
    "WorkspaceActionSurface.FileTransfer",
    "WorkspaceActionCatalogRequest",
    "WorkspaceActionCatalogSnapshot",
    "WorkspaceActionItem",
    "SelectFiles",
    "Select Files",
    "SelectFolder",
    "Select Folder",
    "GenerateQr",
    "Generate QR",
    "Visible mac-parity quick action"
)) {
    Assert-Contains -Text $workspaceActionCatalog -Needle $signal -Message "WorkspaceActionCatalogClient missing action-catalog signal: $signal"
}

Assert-Contains -Text $architecture -Needle "WorkspaceActionCatalogClient" -Message "Architecture doc missing WorkspaceActionCatalogClient status."

foreach ($signal in @(
    "public interface IRemoteDesktopWorkspaceClient",
    "public sealed class RemoteDesktopWorkspaceClient : IRemoteDesktopWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "PlanConnectionAsync",
    "MapChannelAsync",
    "CoreChannelKind.Realtime",
    "CoreChannelKind.Telemetry",
    "CoreChannelKind.Control",
    "EncodeSbp2FrameAsync",
    "RemoteDesktopControlFact"
)) {
    Assert-Contains -Text $remoteDesktop -Needle $signal -Message "RemoteDesktopWorkspaceClient missing Core remote desktop signal: $signal"
}

Assert-Contains -Text $architecture -Needle "RemoteDesktopWorkspaceClient" -Message "Architecture doc missing RemoteDesktopWorkspaceClient status."

foreach ($signal in @(
    "public interface ISystemMonitorWorkspaceClient",
    "public sealed class SystemMonitorWorkspaceClient : ISystemMonitorWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "Process.GetCurrentProcess",
    "GC.GetGCMemoryInfo",
    "DriveInfo.GetDrives",
    "NetworkInterface.GetAllNetworkInterfaces",
    "RuntimeInformation",
    "SystemMonitorMetric",
    "SystemMonitorIndicator"
)) {
    Assert-Contains -Text $systemMonitor -Needle $signal -Message "SystemMonitorWorkspaceClient missing Windows diagnostics signal: $signal"
}

Assert-Contains -Text $architecture -Needle "SystemMonitorWorkspaceClient" -Message "Architecture doc missing SystemMonitorWorkspaceClient status."

foreach ($signal in @(
    "public interface ISettingsWorkspaceClient",
    "public sealed class SettingsWorkspaceClient : ISettingsWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "SettingsWorkspaceSnapshot",
    "SettingsTabItem",
    "SettingsActionItem",
    "SettingsDetailItem",
    "ExportSettings",
    "ImportSettings",
    "ResetSettings",
    "ApplyFileTransferSettings",
    "ApplyRemoteDesktopSettings",
    "RestoreDefaults",
    "ResetMonitorData",
    "ClearHistoryData",
    "defaultTransferPath",
    "maxConcurrentConnections",
    "currentConfig",
    "videoQuality",
    "refreshInterval",
    "Disabled",
    "Request Permission",
    "Open System Preferences",
    "Restore Defaults",
    "PQC policy",
    "Rust Core"
)) {
    Assert-Contains -Text $settings -Needle $signal -Message "SettingsWorkspaceClient missing Settings signal: $signal"
}

Assert-Contains -Text $architecture -Needle "SettingsWorkspaceClient" -Message "Architecture doc missing SettingsWorkspaceClient status."

foreach ($signal in @(
    "public interface IDashboardMetricsClient",
    "public sealed class DashboardMetricsClient : IDashboardMetricsClient",
    "BuildReadOnlySnapshot",
    "DashboardMetricsRequest",
    "DashboardMetricsSnapshot",
    "DashboardMetric",
    "Online Devices",
    "Active Sessions",
    "Transfer Tasks",
    "Performance"
)) {
    Assert-Contains -Text $dashboardMetrics -Needle $signal -Message "DashboardMetricsClient missing dashboard parity signal: $signal"
}

Assert-Contains -Text $architecture -Needle "DashboardMetricsClient" -Message "Architecture doc missing DashboardMetricsClient status."

foreach ($signal in @(
    "public interface ITopBarStatusClient",
    "public sealed class TopBarStatusClient : ITopBarStatusClient",
    "BuildReadOnlySnapshot",
    "TopBarStatusRequest",
    "TopBarStatusSnapshot",
    "TopBarStatusItem",
    "Connection",
    "FPS / Diagnostics",
    "Notifications",
    "Theme"
)) {
    Assert-Contains -Text $topBarStatus -Needle $signal -Message "TopBarStatusClient missing top-bar parity signal: $signal"
}

Assert-Contains -Text $architecture -Needle "TopBarStatusClient" -Message "Architecture doc missing TopBarStatusClient status."

Write-Output "windows-ffi-client: ok"
