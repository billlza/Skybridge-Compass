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

$sourceFiles = @()
$sourceFiles += Get-ChildItem -LiteralPath (Join-Path $RepoRoot "windows/Skybridge.WinClient/Services") -Filter "*.cs" |
    Sort-Object Name |
    ForEach-Object { $_.FullName }
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceCommandGateCoordinator.cs"
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceCommandAvailability.cs"

foreach ($sourceFile in $sourceFiles) {
    Assert-True -Condition (Test-Path -LiteralPath $sourceFile) -Message "Missing Windows command gate source file: $sourceFile"
}

$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-command-gates-" + [guid]::NewGuid().ToString("N"))
$testProject = Join-Path $tempRoot "Skybridge.WinCommandGates.csproj"
$testProgram = Join-Path $tempRoot "Program.cs"

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $programXml = [System.Security.SecurityElement]::Escape($testProgram)
    $compileItems = @("    <Compile Include=""$programXml"" />")
    foreach ($sourceFile in $sourceFiles) {
        $sourceFileXml = [System.Security.SecurityElement]::Escape($sourceFile)
        $compileItems += "    <Compile Include=""$sourceFileXml"" />"
    }
    $compileItemText = $compileItems -join "`r`n"

    Set-Content -LiteralPath $testProject -Encoding UTF8 -Value @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
$compileItemText
  </ItemGroup>
</Project>
"@

    Set-Content -LiteralPath $testProgram -Encoding UTF8 -Value @'
using Skybridge.WinClient.Services;
using Skybridge.WinClient.ViewModels;

const string Fingerprint = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

var fileTransferClient = new TestFileTransferWorkspaceClient(
    canSelectFiles: true,
    canSelectFolder: true,
    canGenerateShareQr: true);
var coordinator = new WorkspaceCommandGateCoordinator(
    new SessionCommandStateClient(),
    new FeatureCatalogClient(),
    new WorkspaceCommandStateClient(),
    new ManualConnectionClient(),
    new CrossNetworkConnectionClient(),
    fileTransferClient,
    new TestDiscoveryClient(),
    new PairingMaterialClient(),
    new ConnectionWorkspaceStateClient());
var catalog = new WorkspaceActionCatalogClient();
var details = new WorkspaceActionDetailSnapshot("Off", "System");

var preflightOnlyState = BuildCommandState(liveReady: false);
var preflightOnlyAvailability = new WorkspaceCommandAvailability(coordinator, () => preflightOnlyState);
AssertEqual(false, preflightOnlyAvailability.CanConnect(), "preflight-only WorkspaceCommandAvailability.Connect");
var preflightOnlyGates = coordinator.BuildActionGateSnapshot(preflightOnlyState);
AssertEqual(false, preflightOnlyGates.CanConnect, "preflight-only action gate Connect");
AssertResolvedConnect(
    catalog,
    details,
    preflightOnlyGates,
    WorkspaceActionSurface.SidebarSession,
    "Connect",
    false,
    "preflight-only sidebar Connect");
AssertResolvedConnect(
    catalog,
    details,
    preflightOnlyGates,
    WorkspaceActionSurface.SessionControls,
    "Connect",
    false,
    "preflight-only session control Connect");
AssertResolvedConnect(
    catalog,
    details,
    preflightOnlyGates,
    WorkspaceActionSurface.DeviceDiscoveryManualConnectFinal,
    "Connect",
    false,
    "preflight-only manual-final Connect");

var liveState = BuildCommandState(liveReady: true);
var liveAvailability = new WorkspaceCommandAvailability(coordinator, () => liveState);
AssertEqual(true, liveAvailability.CanConnect(), "live WorkspaceCommandAvailability.Connect");
var liveGates = coordinator.BuildActionGateSnapshot(liveState);
AssertEqual(true, liveGates.CanConnect, "live action gate Connect");
AssertResolvedConnect(
    catalog,
    details,
    liveGates,
    WorkspaceActionSurface.SidebarSession,
    "Connect",
    true,
    "live sidebar Connect");
AssertResolvedConnect(
    catalog,
    details,
    liveGates,
    WorkspaceActionSurface.SessionControls,
    "Connect",
    true,
    "live session control Connect");
AssertResolvedConnect(
    catalog,
    details,
    liveGates,
    WorkspaceActionSurface.DeviceDiscoveryManualConnectFinal,
    "Connect",
    true,
    "live manual-final Connect");

var connectedState = BuildCommandState(liveReady: true, connectionState: EngineConnectionState.Connected);
var connectedAvailability = new WorkspaceCommandAvailability(coordinator, () => connectedState);
AssertEqual(false, connectedAvailability.CanConnect(), "connected WorkspaceCommandAvailability.Connect");
AssertEqual(true, connectedAvailability.CanDisconnect(), "connected WorkspaceCommandAvailability.Disconnect");
AssertEqual(true, connectedAvailability.CanSendHeartbeat(), "connected WorkspaceCommandAvailability.Heartbeat");
var connectedGates = coordinator.BuildActionGateSnapshot(connectedState);
AssertEqual(false, connectedGates.CanConnect, "connected action gate Connect");
AssertEqual(true, connectedGates.CanDisconnect, "connected action gate Disconnect");
AssertEqual(true, connectedGates.CanSendHeartbeat, "connected action gate Heartbeat");
AssertResolvedAction(
    catalog,
    details,
    connectedGates,
    WorkspaceActionSurface.SidebarSession,
    "Connect",
    WorkspaceActionCommandId.Connect,
    WorkspaceActionGateId.CanConnect,
    false,
    "connected sidebar Connect");
AssertResolvedAction(
    catalog,
    details,
    connectedGates,
    WorkspaceActionSurface.SidebarSession,
    "Disconnect",
    WorkspaceActionCommandId.Disconnect,
    WorkspaceActionGateId.CanDisconnect,
    true,
    "connected sidebar Disconnect");
AssertResolvedAction(
    catalog,
    details,
    connectedGates,
    WorkspaceActionSurface.SessionControls,
    "Heartbeat",
    WorkspaceActionCommandId.Heartbeat,
    WorkspaceActionGateId.CanSendHeartbeat,
    true,
    "connected session control Heartbeat");
AssertResolvedAction(
    catalog,
    details,
    connectedGates,
    WorkspaceActionSurface.SessionControls,
    "Disconnect",
    WorkspaceActionCommandId.Disconnect,
    WorkspaceActionGateId.CanDisconnect,
    true,
    "connected session control Disconnect");

var reconnectingState = BuildCommandState(liveReady: true, connectionState: EngineConnectionState.Reconnecting);
var reconnectingAvailability = new WorkspaceCommandAvailability(coordinator, () => reconnectingState);
AssertEqual(false, reconnectingAvailability.CanConnect(), "reconnecting WorkspaceCommandAvailability.Connect");
AssertEqual(true, reconnectingAvailability.CanDisconnect(), "reconnecting WorkspaceCommandAvailability.Disconnect");
AssertEqual(false, reconnectingAvailability.CanSendHeartbeat(), "reconnecting WorkspaceCommandAvailability.Heartbeat");
var reconnectingGates = coordinator.BuildActionGateSnapshot(reconnectingState);
AssertResolvedAction(
    catalog,
    details,
    reconnectingGates,
    WorkspaceActionSurface.SessionControls,
    "Heartbeat",
    WorkspaceActionCommandId.Heartbeat,
    WorkspaceActionGateId.CanSendHeartbeat,
    false,
    "reconnecting session control Heartbeat");
AssertResolvedAction(
    catalog,
    details,
    reconnectingGates,
    WorkspaceActionSurface.SessionControls,
    "Disconnect",
    WorkspaceActionCommandId.Disconnect,
    WorkspaceActionGateId.CanDisconnect,
    true,
    "reconnecting session control Disconnect");

var fileTransferReadyState = BuildCommandState(
    liveReady: true,
    selectedFeatureId: FeatureEntryId.FileTransfer);
var fileTransferReadyAvailability = new WorkspaceCommandAvailability(coordinator, () => fileTransferReadyState);
AssertEqual(true, fileTransferReadyAvailability.CanRefreshFileTransfer(), "file transfer WorkspaceCommandAvailability.Refresh");
AssertEqual(true, fileTransferReadyAvailability.CanSelectFileTransferFiles(), "file transfer WorkspaceCommandAvailability.SelectFiles");
AssertEqual(true, fileTransferReadyAvailability.CanSelectFileTransferFolder(), "file transfer WorkspaceCommandAvailability.SelectFolder");
AssertEqual(true, fileTransferReadyAvailability.CanGenerateFileTransferQr(), "file transfer WorkspaceCommandAvailability.GenerateQr");
var fileTransferReadyGates = coordinator.BuildActionGateSnapshot(fileTransferReadyState);
AssertEqual(true, fileTransferReadyGates.CanRefreshFileTransfer, "file transfer action gate Refresh");
AssertEqual(true, fileTransferReadyGates.CanSelectFileTransferFiles, "file transfer action gate SelectFiles");
AssertEqual(true, fileTransferReadyGates.CanSelectFileTransferFolder, "file transfer action gate SelectFolder");
AssertEqual(true, fileTransferReadyGates.CanGenerateFileTransferQr, "file transfer action gate GenerateQr");
AssertResolvedAction(
    catalog,
    details,
    fileTransferReadyGates,
    WorkspaceActionSurface.FileTransfer,
    "SelectFiles",
    WorkspaceActionCommandId.SelectFileTransferFiles,
    WorkspaceActionGateId.CanSelectFileTransferFiles,
    true,
    "file transfer Select Files");
AssertResolvedAction(
    catalog,
    details,
    fileTransferReadyGates,
    WorkspaceActionSurface.FileTransfer,
    "SelectFolder",
    WorkspaceActionCommandId.SelectFileTransferFolder,
    WorkspaceActionGateId.CanSelectFileTransferFolder,
    true,
    "file transfer Select Folder");
AssertResolvedAction(
    catalog,
    details,
    fileTransferReadyGates,
    WorkspaceActionSurface.FileTransfer,
    "GenerateQr",
    WorkspaceActionCommandId.GenerateFileTransferQr,
    WorkspaceActionGateId.CanGenerateFileTransferQr,
    true,
    "file transfer Generate QR");

var fileTransferBlockedState = BuildCommandState(
    liveReady: true,
    selectedFeatureId: FeatureEntryId.FileTransfer);
fileTransferClient.CanSelectFilesValue = false;
fileTransferClient.CanSelectFolderValue = false;
fileTransferClient.CanGenerateShareQrValue = false;
var fileTransferBlockedAvailability = new WorkspaceCommandAvailability(coordinator, () => fileTransferBlockedState);
AssertEqual(true, fileTransferBlockedAvailability.CanRefreshFileTransfer(), "blocked file transfer WorkspaceCommandAvailability.Refresh");
AssertEqual(false, fileTransferBlockedAvailability.CanSelectFileTransferFiles(), "blocked file transfer WorkspaceCommandAvailability.SelectFiles");
AssertEqual(false, fileTransferBlockedAvailability.CanSelectFileTransferFolder(), "blocked file transfer WorkspaceCommandAvailability.SelectFolder");
AssertEqual(false, fileTransferBlockedAvailability.CanGenerateFileTransferQr(), "blocked file transfer WorkspaceCommandAvailability.GenerateQr");
var fileTransferBlockedGates = coordinator.BuildActionGateSnapshot(fileTransferBlockedState);
AssertResolvedAction(
    catalog,
    details,
    fileTransferBlockedGates,
    WorkspaceActionSurface.FileTransfer,
    "SelectFiles",
    WorkspaceActionCommandId.SelectFileTransferFiles,
    WorkspaceActionGateId.CanSelectFileTransferFiles,
    false,
    "blocked file transfer Select Files");
AssertResolvedAction(
    catalog,
    details,
    fileTransferBlockedGates,
    WorkspaceActionSurface.FileTransfer,
    "SelectFolder",
    WorkspaceActionCommandId.SelectFileTransferFolder,
    WorkspaceActionGateId.CanSelectFileTransferFolder,
    false,
    "blocked file transfer Select Folder");
AssertResolvedAction(
    catalog,
    details,
    fileTransferBlockedGates,
    WorkspaceActionSurface.FileTransfer,
    "GenerateQr",
    WorkspaceActionCommandId.GenerateFileTransferQr,
    WorkspaceActionGateId.CanGenerateFileTransferQr,
    false,
    "blocked file transfer Generate QR");

Console.WriteLine("windows-command-gates: ok");

WorkspaceCommandGateState BuildCommandState(
    bool liveReady,
    EngineConnectionState connectionState = EngineConnectionState.Disconnected,
    FeatureEntryId selectedFeatureId = FeatureEntryId.DeviceDiscovery)
{
    var selectedFeature = FeatureCatalogClient.Entries.Single(entry => entry.Id == selectedFeatureId);
    return new WorkspaceCommandGateState(
        IsBusy: false,
        connectionState,
        selectedFeature,
        "192.0.2.10",
        "11550",
        "skybridge://connect/test",
        "ABC234",
        "ABC234",
        "_skybridge._udp",
        "deviceId=mac-1;pubKeyFP=" + Fingerprint + ";platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1",
        BuildPairingCode(),
        BuildValidatedState(liveReady));
}

ConnectionWorkspaceValidatedState BuildValidatedState(bool liveReady)
{
    var stateClient = new ConnectionWorkspaceStateClient();
    var peer = new DiscoveredPeer(
        CoreDiscoveryServiceKind.QuicPrimary,
        "mac-1",
        "Desk Mac",
        CorePeerPlatform.Apple,
        "macOS",
        Fingerprint,
        "apple,webrtc,tcp,relay",
        "1",
        PeerCapabilities.Apple());
    var pairingMaterial = new PairingMaterial(
        "mac-1",
        "Desk Mac",
        "macOS",
        Fingerprint,
        new byte[] { 1, 2, 3, 4, 5 },
        VerifiedAgainstDiscoveryFingerprint: true,
        "command gate smoke");
    var discoveredState = stateClient.BuildDiscoveryPeerValidatedState(peer);
    var pairedState = stateClient.BuildPairingValidatedState(discoveredState, pairingMaterial);
    return stateClient.BuildPreflightValidatedState(
        pairedState,
        new ConnectionPreflightSnapshot(
            DateTimeOffset.UnixEpoch,
            BuildPlan(liveReady),
            Array.Empty<ConnectionPreflightFact>()));
}

ConnectionPreflightPlan BuildPlan(bool liveReady) =>
    new(
        "mac-1",
        Fingerprint,
        CoreTransportKind.WebRtcDataChannel,
        CoreTransportAuditCode.WebRtcInterop,
        RelayRequired: false,
        RelayAllowed: true,
        CoreCryptoSuiteKind.XWingHybrid,
        0x0001,
        CoreCryptoSuiteAuditCode.HybridPqcPreferred,
        Sbp2Enabled: true,
        (nuint)1024,
        (nuint)20,
        DefaultChannelMappings(),
        Enumerable.Range(0, 32).Select(value => (byte)value).ToArray(),
        ConnectionLaunchAdapterKind.WebRtcDataChannel,
        liveReady,
        liveReady ? "external webrtc datachannel" : "adapter pending",
        "windows-preflight.local:443",
        "mac-1.skybridge-preflight.local:443",
        "WebRtcDataChannel/preflight-candidate",
        RelayId: null,
        TimestampWindowMs: 10_000);

IReadOnlyList<ChannelMapping> DefaultChannelMappings() =>
    new[]
    {
        new ChannelMapping(CoreChannelKind.Control, CoreReliabilityKind.ReliableOrdered, 0, CoreAdapterBindingKind.WebRtcDataChannel, true),
        new ChannelMapping(CoreChannelKind.File, CoreReliabilityKind.ReliableOrdered, 0, CoreAdapterBindingKind.WebRtcDataChannel, true),
        new ChannelMapping(CoreChannelKind.Clipboard, CoreReliabilityKind.ReliableOrdered, 0, CoreAdapterBindingKind.WebRtcDataChannel, true),
        new ChannelMapping(CoreChannelKind.Telemetry, CoreReliabilityKind.ReliableUnordered, 0, CoreAdapterBindingKind.WebRtcDataChannel, true),
        new ChannelMapping(CoreChannelKind.Realtime, CoreReliabilityKind.PartialReliable, 1, CoreAdapterBindingKind.WebRtcDataChannel, true)
    };

void AssertResolvedConnect(
    WorkspaceActionCatalogClient catalog,
    WorkspaceActionDetailSnapshot details,
    WorkspaceActionGateSnapshot gates,
    WorkspaceActionSurface surface,
    string key,
    bool expectedEnabled,
    string label)
{
    var snapshot = catalog.BuildResolvedSnapshot(
        new WorkspaceActionCatalogRequest(surface),
        gates,
        details);
    var action = snapshot.Actions.Single(item => item.Key == key);
    AssertEqual(WorkspaceActionCommandId.Connect, action.CommandId, label + " command id");
    AssertEqual(WorkspaceActionGateId.CanConnect, action.GateId, label + " gate id");
    AssertEqual(expectedEnabled, action.IsEnabled, label + " enabled");
}

void AssertResolvedAction(
    WorkspaceActionCatalogClient catalog,
    WorkspaceActionDetailSnapshot details,
    WorkspaceActionGateSnapshot gates,
    WorkspaceActionSurface surface,
    string key,
    WorkspaceActionCommandId expectedCommand,
    WorkspaceActionGateId expectedGate,
    bool expectedEnabled,
    string label)
{
    var snapshot = catalog.BuildResolvedSnapshot(
        new WorkspaceActionCatalogRequest(surface),
        gates,
        details);
    var action = snapshot.Actions.Single(item => item.Key == key);
    AssertEqual(expectedCommand, action.CommandId, label + " command id");
    AssertEqual(expectedGate, action.GateId, label + " gate id");
    AssertEqual(expectedEnabled, action.IsEnabled, label + " enabled");
}

string BuildPairingCode() =>
    "skybridge-pair:v1:" + Convert.ToBase64String(new byte[] { 1, 2, 3, 4, 5 });

void AssertEqual<T>(T expected, T actual, string label)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{label}: expected '{expected}', got '{actual}'.");
    }
}

sealed class TestDiscoveryClient : IDiscoveryClient
{
    public string BuildPendingStatus() => "Parsing...";

    public bool CanParseAdvertisement(string service, string txtRecord) =>
        !string.IsNullOrWhiteSpace(service) && !string.IsNullOrWhiteSpace(txtRecord);

    public Task<DiscoveredPeer> ParseAdvertisementAsync(string service, string txtRecord) =>
        throw new NotSupportedException("Command-gate smoke only needs parser readiness.");
}

sealed class TestFileTransferWorkspaceClient : IFileTransferWorkspaceClient
{
    public TestFileTransferWorkspaceClient(
        bool canSelectFiles,
        bool canSelectFolder,
        bool canGenerateShareQr)
    {
        CanSelectFilesValue = canSelectFiles;
        CanSelectFolderValue = canSelectFolder;
        CanGenerateShareQrValue = canGenerateShareQr;
    }

    public bool CanSelectFilesValue { get; set; }

    public bool CanSelectFolderValue { get; set; }

    public bool CanGenerateShareQrValue { get; set; }

    public string BuildInitialStatus() => "Ready";

    public string BuildPendingStatus() => "Refreshing...";

    public string BuildCompletedStatus(FileTransferWorkspaceSnapshot snapshot) => "Snapshot";

    public string BuildCompletedStatusMessage() => "Updated";

    public bool CanSelectFiles() => CanSelectFilesValue;

    public bool CanSelectFolder() => CanSelectFolderValue;

    public bool CanGenerateShareQr() => CanGenerateShareQrValue;

    public string BuildSelectFilesPendingStatus() => "Preparing file picker...";

    public string BuildSelectFolderPendingStatus() => "Preparing folder picker...";

    public string BuildShareQrPendingStatus() => "Preparing QR...";

    public Task<FileTransferWorkspaceSnapshot> BuildReadOnlySnapshotAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs file transfer action readiness.");

    public Task<FileTransferWorkspaceActionResult> BuildSelectFilesActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs file transfer action readiness.");

    public Task<FileTransferWorkspaceActionResult> BuildSelectFolderActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs file transfer action readiness.");

    public Task<FileTransferWorkspaceActionResult> BuildShareQrActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs file transfer action readiness.");
}
'@

    dotnet run --project $testProject --no-launch-profile
    if ($LASTEXITCODE -ne 0) {
        throw "windows-command-gates smoke failed with exit code $LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
