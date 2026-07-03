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
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/Converters/LabelKeyToLocalizedConverter.cs"
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
    <TargetFramework>net10.0-windows10.0.22621.0</TargetFramework>
    <TargetPlatformMinVersion>10.0.19041.0</TargetPlatformMinVersion>
    <UseWinUI>true</UseWinUI>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
$compileItemText
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.WindowsAppSDK" Version="2.2.0" />
    <PackageReference Include="Microsoft.Windows.SDK.BuildTools" Version="10.0.28000.1839" PrivateAssets="all" />
    <PackageReference Include="QRCoder" Version="1.8.0" />
    <PackageReference Include="System.Security.Cryptography.ProtectedData" Version="9.0.0" />
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
var remoteDesktopClient = new TestRemoteDesktopWorkspaceClient(
    canRecommendedConnect: true,
    canAdvancedConnect: true,
    canShowPerformanceOverlay: true,
    canApplyQuality: true,
    canOpenSettings: true,
    canEnterFullScreen: true,
    canDisconnectSession: true);
var systemMonitorClient = new TestSystemMonitorWorkspaceClient(
    canStartMonitoring: true,
    canStopMonitoring: true,
    canEnableAdvancedMonitoring: true);
var settingsClient = new TestSettingsWorkspaceClient(
    canExportSettings: true,
    canImportSettings: true,
    canResetSettings: true,
    canRequestPermission: true,
    canOpenSystemPreferences: true,
    canApplySettings: true,
    canRestoreDefaults: true,
    canResetMonitorData: true);
var topBarStatusClient = new TestTopBarStatusClient(
    canOpenNotifications: true,
    canToggleTheme: true);
var coordinator = new WorkspaceCommandGateCoordinator(
    new SessionCommandStateClient(),
    new FeatureCatalogClient(),
    new WorkspaceCommandStateClient(),
    topBarStatusClient,
    new ManualConnectionClient(),
    new CrossNetworkConnectionClient(),
    fileTransferClient,
    remoteDesktopClient,
    systemMonitorClient,
    settingsClient,
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
AssertResolvedAction(
    catalog,
    details,
    preflightOnlyGates,
    WorkspaceActionSurface.DeviceDiscoveryManualConnectFinal,
    "Cancel",
    WorkspaceActionCommandId.CancelManualConnection,
    WorkspaceActionGateId.CanUseDiscoveryBrowser,
    true,
    "preflight-only manual-final Cancel");
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
AssertResolvedAction(
    catalog,
    details,
    liveGates,
    WorkspaceActionSurface.DeviceDiscoveryManualConnectFinal,
    "Cancel",
    WorkspaceActionCommandId.CancelManualConnection,
    WorkspaceActionGateId.CanUseDiscoveryBrowser,
    true,
    "live manual-final Cancel");
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

var topBarReadyState = BuildCommandState(liveReady: true);
var topBarReadyAvailability = new WorkspaceCommandAvailability(coordinator, () => topBarReadyState);
AssertEqual(true, topBarReadyAvailability.CanOpenTopBarNotifications(), "top bar WorkspaceCommandAvailability.Notifications");
AssertEqual(true, topBarReadyAvailability.CanToggleTopBarTheme(), "top bar WorkspaceCommandAvailability.Theme");
var topBarReadyGates = coordinator.BuildActionGateSnapshot(topBarReadyState);
AssertEqual(true, topBarReadyGates.CanOpenTopBarNotifications, "top bar action gate Notifications");
AssertEqual(true, topBarReadyGates.CanToggleTopBarTheme, "top bar action gate Theme");
AssertResolvedAction(
    catalog,
    details,
    topBarReadyGates,
    WorkspaceActionSurface.TopBarActions,
    "Notifications",
    WorkspaceActionCommandId.OpenTopBarNotifications,
    WorkspaceActionGateId.CanOpenTopBarNotifications,
    true,
    "top bar Notifications");
AssertResolvedAction(
    catalog,
    details,
    topBarReadyGates,
    WorkspaceActionSurface.TopBarActions,
    "Theme",
    WorkspaceActionCommandId.ToggleTopBarTheme,
    WorkspaceActionGateId.CanToggleTopBarTheme,
    true,
    "top bar Theme");

var topBarBlockedState = BuildCommandState(liveReady: true);
topBarStatusClient.CanOpenNotificationsValue = false;
topBarStatusClient.CanToggleThemeValue = false;
var topBarBlockedAvailability = new WorkspaceCommandAvailability(coordinator, () => topBarBlockedState);
AssertEqual(false, topBarBlockedAvailability.CanOpenTopBarNotifications(), "blocked top bar WorkspaceCommandAvailability.Notifications");
AssertEqual(false, topBarBlockedAvailability.CanToggleTopBarTheme(), "blocked top bar WorkspaceCommandAvailability.Theme");
var topBarBlockedGates = coordinator.BuildActionGateSnapshot(topBarBlockedState);
AssertResolvedAction(
    catalog,
    details,
    topBarBlockedGates,
    WorkspaceActionSurface.TopBarActions,
    "Notifications",
    WorkspaceActionCommandId.OpenTopBarNotifications,
    WorkspaceActionGateId.CanOpenTopBarNotifications,
    false,
    "blocked top bar Notifications");
AssertResolvedAction(
    catalog,
    details,
    topBarBlockedGates,
    WorkspaceActionSurface.TopBarActions,
    "Theme",
    WorkspaceActionCommandId.ToggleTopBarTheme,
    WorkspaceActionGateId.CanToggleTopBarTheme,
    false,
    "blocked top bar Theme");
topBarStatusClient.CanOpenNotificationsValue = true;
topBarStatusClient.CanToggleThemeValue = true;

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

var remoteDesktopReadyState = BuildCommandState(
    liveReady: true,
    selectedFeatureId: FeatureEntryId.RemoteDesktop);
var remoteDesktopReadyAvailability = new WorkspaceCommandAvailability(coordinator, () => remoteDesktopReadyState);
AssertEqual(true, remoteDesktopReadyAvailability.CanRefreshRemoteDesktop(), "remote desktop WorkspaceCommandAvailability.Refresh");
AssertEqual(true, remoteDesktopReadyAvailability.CanRecommendedRemoteDesktopConnect(), "remote desktop WorkspaceCommandAvailability.RecommendedConnect");
AssertEqual(true, remoteDesktopReadyAvailability.CanAdvancedRemoteDesktopConnect(), "remote desktop WorkspaceCommandAvailability.AdvancedConnect");
AssertEqual(true, remoteDesktopReadyAvailability.CanShowRemoteDesktopPerformanceOverlay(), "remote desktop WorkspaceCommandAvailability.PerformanceOverlay");
AssertEqual(true, remoteDesktopReadyAvailability.CanApplyRemoteDesktopQuality(), "remote desktop WorkspaceCommandAvailability.Quality");
AssertEqual(true, remoteDesktopReadyAvailability.CanOpenRemoteDesktopSettings(), "remote desktop WorkspaceCommandAvailability.Settings");
AssertEqual(true, remoteDesktopReadyAvailability.CanEnterRemoteDesktopFullScreen(), "remote desktop WorkspaceCommandAvailability.FullScreen");
AssertEqual(true, remoteDesktopReadyAvailability.CanDisconnectRemoteDesktopSession(), "remote desktop WorkspaceCommandAvailability.DisconnectSession");
var remoteDesktopReadyGates = coordinator.BuildActionGateSnapshot(remoteDesktopReadyState);
AssertEqual(true, remoteDesktopReadyGates.CanRefreshRemoteDesktop, "remote desktop action gate Refresh");
AssertEqual(true, remoteDesktopReadyGates.CanRecommendedRemoteDesktopConnect, "remote desktop action gate RecommendedConnect");
AssertEqual(true, remoteDesktopReadyGates.CanAdvancedRemoteDesktopConnect, "remote desktop action gate AdvancedConnect");
AssertEqual(true, remoteDesktopReadyGates.CanShowRemoteDesktopPerformanceOverlay, "remote desktop action gate PerformanceOverlay");
AssertEqual(true, remoteDesktopReadyGates.CanApplyRemoteDesktopQuality, "remote desktop action gate Quality");
AssertEqual(true, remoteDesktopReadyGates.CanOpenRemoteDesktopSettings, "remote desktop action gate Settings");
AssertEqual(true, remoteDesktopReadyGates.CanEnterRemoteDesktopFullScreen, "remote desktop action gate FullScreen");
AssertEqual(true, remoteDesktopReadyGates.CanDisconnectRemoteDesktopSession, "remote desktop action gate DisconnectSession");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopReadyGates,
    WorkspaceActionSurface.RemoteDesktop,
    "RecommendedConnect",
    WorkspaceActionCommandId.RecommendedRemoteDesktopConnect,
    WorkspaceActionGateId.CanRecommendedRemoteDesktopConnect,
    true,
    "remote desktop Recommended Connect");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopReadyGates,
    WorkspaceActionSurface.RemoteDesktop,
    "AdvancedConnect",
    WorkspaceActionCommandId.AdvancedRemoteDesktopConnect,
    WorkspaceActionGateId.CanAdvancedRemoteDesktopConnect,
    true,
    "remote desktop Advanced Connect");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopReadyGates,
    WorkspaceActionSurface.RemoteDesktop,
    "PerformanceOverlay",
    WorkspaceActionCommandId.ShowRemoteDesktopPerformanceOverlay,
    WorkspaceActionGateId.CanShowRemoteDesktopPerformanceOverlay,
    true,
    "remote desktop Performance Overlay");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopReadyGates,
    WorkspaceActionSurface.RemoteDesktop,
    "Quality",
    WorkspaceActionCommandId.ApplyRemoteDesktopQuality,
    WorkspaceActionGateId.CanApplyRemoteDesktopQuality,
    true,
    "remote desktop Quality");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopReadyGates,
    WorkspaceActionSurface.RemoteDesktop,
    "Settings",
    WorkspaceActionCommandId.OpenRemoteDesktopSettings,
    WorkspaceActionGateId.CanOpenRemoteDesktopSettings,
    true,
    "remote desktop Settings");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopReadyGates,
    WorkspaceActionSurface.RemoteDesktop,
    "FullScreen",
    WorkspaceActionCommandId.EnterRemoteDesktopFullScreen,
    WorkspaceActionGateId.CanEnterRemoteDesktopFullScreen,
    true,
    "remote desktop Full Screen");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopReadyGates,
    WorkspaceActionSurface.RemoteDesktop,
    "DisconnectSession",
    WorkspaceActionCommandId.DisconnectRemoteDesktopSession,
    WorkspaceActionGateId.CanDisconnectRemoteDesktopSession,
    true,
    "remote desktop Disconnect Session");

var remoteDesktopBlockedState = BuildCommandState(
    liveReady: true,
    selectedFeatureId: FeatureEntryId.RemoteDesktop);
remoteDesktopClient.CanRecommendedConnectValue = false;
remoteDesktopClient.CanAdvancedConnectValue = false;
remoteDesktopClient.CanShowPerformanceOverlayValue = false;
remoteDesktopClient.CanApplyQualityValue = false;
remoteDesktopClient.CanOpenSettingsValue = false;
remoteDesktopClient.CanEnterFullScreenValue = false;
remoteDesktopClient.CanDisconnectSessionValue = false;
var remoteDesktopBlockedAvailability = new WorkspaceCommandAvailability(coordinator, () => remoteDesktopBlockedState);
AssertEqual(true, remoteDesktopBlockedAvailability.CanRefreshRemoteDesktop(), "blocked remote desktop WorkspaceCommandAvailability.Refresh");
AssertEqual(false, remoteDesktopBlockedAvailability.CanRecommendedRemoteDesktopConnect(), "blocked remote desktop WorkspaceCommandAvailability.RecommendedConnect");
AssertEqual(false, remoteDesktopBlockedAvailability.CanAdvancedRemoteDesktopConnect(), "blocked remote desktop WorkspaceCommandAvailability.AdvancedConnect");
AssertEqual(false, remoteDesktopBlockedAvailability.CanShowRemoteDesktopPerformanceOverlay(), "blocked remote desktop WorkspaceCommandAvailability.PerformanceOverlay");
AssertEqual(false, remoteDesktopBlockedAvailability.CanApplyRemoteDesktopQuality(), "blocked remote desktop WorkspaceCommandAvailability.Quality");
AssertEqual(false, remoteDesktopBlockedAvailability.CanOpenRemoteDesktopSettings(), "blocked remote desktop WorkspaceCommandAvailability.Settings");
AssertEqual(false, remoteDesktopBlockedAvailability.CanEnterRemoteDesktopFullScreen(), "blocked remote desktop WorkspaceCommandAvailability.FullScreen");
AssertEqual(false, remoteDesktopBlockedAvailability.CanDisconnectRemoteDesktopSession(), "blocked remote desktop WorkspaceCommandAvailability.DisconnectSession");
var remoteDesktopBlockedGates = coordinator.BuildActionGateSnapshot(remoteDesktopBlockedState);
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopBlockedGates,
    WorkspaceActionSurface.RemoteDesktop,
    "RecommendedConnect",
    WorkspaceActionCommandId.RecommendedRemoteDesktopConnect,
    WorkspaceActionGateId.CanRecommendedRemoteDesktopConnect,
    false,
    "blocked remote desktop Recommended Connect");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopBlockedGates,
    WorkspaceActionSurface.RemoteDesktop,
    "AdvancedConnect",
    WorkspaceActionCommandId.AdvancedRemoteDesktopConnect,
    WorkspaceActionGateId.CanAdvancedRemoteDesktopConnect,
    false,
    "blocked remote desktop Advanced Connect");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopBlockedGates,
    WorkspaceActionSurface.RemoteDesktop,
    "PerformanceOverlay",
    WorkspaceActionCommandId.ShowRemoteDesktopPerformanceOverlay,
    WorkspaceActionGateId.CanShowRemoteDesktopPerformanceOverlay,
    false,
    "blocked remote desktop Performance Overlay");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopBlockedGates,
    WorkspaceActionSurface.RemoteDesktop,
    "Quality",
    WorkspaceActionCommandId.ApplyRemoteDesktopQuality,
    WorkspaceActionGateId.CanApplyRemoteDesktopQuality,
    false,
    "blocked remote desktop Quality");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopBlockedGates,
    WorkspaceActionSurface.RemoteDesktop,
    "Settings",
    WorkspaceActionCommandId.OpenRemoteDesktopSettings,
    WorkspaceActionGateId.CanOpenRemoteDesktopSettings,
    false,
    "blocked remote desktop Settings");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopBlockedGates,
    WorkspaceActionSurface.RemoteDesktop,
    "FullScreen",
    WorkspaceActionCommandId.EnterRemoteDesktopFullScreen,
    WorkspaceActionGateId.CanEnterRemoteDesktopFullScreen,
    false,
    "blocked remote desktop Full Screen");
AssertResolvedAction(
    catalog,
    details,
    remoteDesktopBlockedGates,
    WorkspaceActionSurface.RemoteDesktop,
    "DisconnectSession",
    WorkspaceActionCommandId.DisconnectRemoteDesktopSession,
    WorkspaceActionGateId.CanDisconnectRemoteDesktopSession,
    false,
    "blocked remote desktop Disconnect Session");

var systemMonitorReadyState = BuildCommandState(
    liveReady: true,
    selectedFeatureId: FeatureEntryId.SystemMonitor);
var systemMonitorReadyAvailability = new WorkspaceCommandAvailability(coordinator, () => systemMonitorReadyState);
AssertEqual(true, systemMonitorReadyAvailability.CanRefreshSystemMonitor(), "system monitor WorkspaceCommandAvailability.Refresh");
AssertEqual(true, systemMonitorReadyAvailability.CanStartSystemMonitoring(), "system monitor WorkspaceCommandAvailability.Monitoring");
AssertEqual(true, systemMonitorReadyAvailability.CanStopSystemMonitoring(), "system monitor WorkspaceCommandAvailability.StopMonitoring");
AssertEqual(true, systemMonitorReadyAvailability.CanEnableAdvancedSystemMonitoring(), "system monitor WorkspaceCommandAvailability.AdvancedMonitoring");
var systemMonitorReadyGates = coordinator.BuildActionGateSnapshot(systemMonitorReadyState);
AssertEqual(true, systemMonitorReadyGates.CanRefreshSystemMonitor, "system monitor action gate Refresh");
AssertEqual(true, systemMonitorReadyGates.CanStartSystemMonitoring, "system monitor action gate Monitoring");
AssertEqual(true, systemMonitorReadyGates.CanStopSystemMonitoring, "system monitor action gate StopMonitoring");
AssertEqual(true, systemMonitorReadyGates.CanEnableAdvancedSystemMonitoring, "system monitor action gate AdvancedMonitoring");
AssertResolvedAction(
    catalog,
    details,
    systemMonitorReadyGates,
    WorkspaceActionSurface.SystemMonitorControls,
    "Monitoring",
    WorkspaceActionCommandId.StartSystemMonitoring,
    WorkspaceActionGateId.CanStartSystemMonitoring,
    true,
    "system monitor Monitoring");
AssertResolvedAction(
    catalog,
    details,
    systemMonitorReadyGates,
    WorkspaceActionSurface.SystemMonitorControls,
    "StopMonitoring",
    WorkspaceActionCommandId.StopSystemMonitoring,
    WorkspaceActionGateId.CanStopSystemMonitoring,
    true,
    "system monitor Stop Monitoring");
AssertResolvedAction(
    catalog,
    details,
    systemMonitorReadyGates,
    WorkspaceActionSurface.SystemMonitorControls,
    "EnableAdvancedMonitoring",
    WorkspaceActionCommandId.EnableAdvancedSystemMonitoring,
    WorkspaceActionGateId.CanEnableAdvancedSystemMonitoring,
    true,
    "system monitor Enable Advanced Monitoring");

var systemMonitorBlockedState = BuildCommandState(
    liveReady: true,
    selectedFeatureId: FeatureEntryId.SystemMonitor);
systemMonitorClient.CanStartMonitoringValue = false;
systemMonitorClient.CanStopMonitoringValue = false;
systemMonitorClient.CanEnableAdvancedMonitoringValue = false;
var systemMonitorBlockedAvailability = new WorkspaceCommandAvailability(coordinator, () => systemMonitorBlockedState);
AssertEqual(true, systemMonitorBlockedAvailability.CanRefreshSystemMonitor(), "blocked system monitor WorkspaceCommandAvailability.Refresh");
AssertEqual(false, systemMonitorBlockedAvailability.CanStartSystemMonitoring(), "blocked system monitor WorkspaceCommandAvailability.Monitoring");
AssertEqual(false, systemMonitorBlockedAvailability.CanStopSystemMonitoring(), "blocked system monitor WorkspaceCommandAvailability.StopMonitoring");
AssertEqual(false, systemMonitorBlockedAvailability.CanEnableAdvancedSystemMonitoring(), "blocked system monitor WorkspaceCommandAvailability.AdvancedMonitoring");
var systemMonitorBlockedGates = coordinator.BuildActionGateSnapshot(systemMonitorBlockedState);
AssertResolvedAction(
    catalog,
    details,
    systemMonitorBlockedGates,
    WorkspaceActionSurface.SystemMonitorControls,
    "Monitoring",
    WorkspaceActionCommandId.StartSystemMonitoring,
    WorkspaceActionGateId.CanStartSystemMonitoring,
    false,
    "blocked system monitor Monitoring");
AssertResolvedAction(
    catalog,
    details,
    systemMonitorBlockedGates,
    WorkspaceActionSurface.SystemMonitorControls,
    "StopMonitoring",
    WorkspaceActionCommandId.StopSystemMonitoring,
    WorkspaceActionGateId.CanStopSystemMonitoring,
    false,
    "blocked system monitor Stop Monitoring");
AssertResolvedAction(
    catalog,
    details,
    systemMonitorBlockedGates,
    WorkspaceActionSurface.SystemMonitorControls,
    "EnableAdvancedMonitoring",
    WorkspaceActionCommandId.EnableAdvancedSystemMonitoring,
    WorkspaceActionGateId.CanEnableAdvancedSystemMonitoring,
    false,
    "blocked system monitor Enable Advanced Monitoring");

var settingsReadyState = BuildCommandState(
    liveReady: true,
    selectedFeatureId: FeatureEntryId.Settings);
var settingsReadyAvailability = new WorkspaceCommandAvailability(coordinator, () => settingsReadyState);
AssertEqual(true, settingsReadyAvailability.CanRefreshSettings(), "settings WorkspaceCommandAvailability.Refresh");
AssertEqual(true, settingsReadyAvailability.CanExportSettings(), "settings WorkspaceCommandAvailability.Export");
AssertEqual(true, settingsReadyAvailability.CanImportSettings(), "settings WorkspaceCommandAvailability.Import");
AssertEqual(true, settingsReadyAvailability.CanResetSettings(), "settings WorkspaceCommandAvailability.Reset");
AssertEqual(true, settingsReadyAvailability.CanRequestSettingsPermission(), "settings WorkspaceCommandAvailability.RequestPermission");
AssertEqual(true, settingsReadyAvailability.CanOpenSystemPreferences(), "settings WorkspaceCommandAvailability.OpenSystemPreferences");
AssertEqual(true, settingsReadyAvailability.CanApplySettings(), "settings WorkspaceCommandAvailability.ApplySettings");
AssertEqual(true, settingsReadyAvailability.CanRestoreDefaults(), "settings WorkspaceCommandAvailability.RestoreDefaults");
AssertEqual(true, settingsReadyAvailability.CanResetMonitorData(), "settings WorkspaceCommandAvailability.ResetMonitorData");
var settingsReadyGates = coordinator.BuildActionGateSnapshot(settingsReadyState);
AssertEqual(true, settingsReadyGates.CanRefreshSettings, "settings action gate Refresh");
AssertEqual(true, settingsReadyGates.CanExportSettings, "settings action gate Export");
AssertEqual(true, settingsReadyGates.CanImportSettings, "settings action gate Import");
AssertEqual(true, settingsReadyGates.CanResetSettings, "settings action gate Reset");
AssertEqual(true, settingsReadyGates.CanRequestSettingsPermission, "settings action gate RequestPermission");
AssertEqual(true, settingsReadyGates.CanOpenSystemPreferences, "settings action gate OpenSystemPreferences");
AssertEqual(true, settingsReadyGates.CanApplySettings, "settings action gate ApplySettings");
AssertEqual(true, settingsReadyGates.CanRestoreDefaults, "settings action gate RestoreDefaults");
AssertEqual(true, settingsReadyGates.CanResetMonitorData, "settings action gate ResetMonitorData");
AssertResolvedAction(
    catalog,
    details,
    settingsReadyGates,
    WorkspaceActionSurface.SettingsToolbar,
    "ExportSettings",
    WorkspaceActionCommandId.ExportSettings,
    WorkspaceActionGateId.CanExportSettings,
    true,
    "settings Export");
AssertResolvedAction(
    catalog,
    details,
    settingsReadyGates,
    WorkspaceActionSurface.SettingsToolbar,
    "ImportSettings",
    WorkspaceActionCommandId.ImportSettings,
    WorkspaceActionGateId.CanImportSettings,
    true,
    "settings Import");
AssertResolvedAction(
    catalog,
    details,
    settingsReadyGates,
    WorkspaceActionSurface.SettingsToolbar,
    "ResetSettings",
    WorkspaceActionCommandId.ResetSettings,
    WorkspaceActionGateId.CanResetSettings,
    true,
    "settings Reset");
AssertResolvedAction(
    catalog,
    details,
    settingsReadyGates,
    WorkspaceActionSurface.SettingsToolbar,
    "RequestPermission",
    WorkspaceActionCommandId.RequestSettingsPermission,
    WorkspaceActionGateId.CanRequestSettingsPermission,
    true,
    "settings Request Permission");
AssertResolvedAction(
    catalog,
    details,
    settingsReadyGates,
    WorkspaceActionSurface.SettingsToolbar,
    "OpenSystemPreferences",
    WorkspaceActionCommandId.OpenSystemPreferences,
    WorkspaceActionGateId.CanOpenSystemPreferences,
    true,
    "settings Open System Preferences");
AssertResolvedAction(
    catalog,
    details,
    settingsReadyGates,
    WorkspaceActionSurface.SettingsMaintenance,
    "ApplySettings",
    WorkspaceActionCommandId.ApplySettings,
    WorkspaceActionGateId.CanApplySettings,
    true,
    "settings Apply Settings");
AssertResolvedAction(
    catalog,
    details,
    settingsReadyGates,
    WorkspaceActionSurface.SettingsMaintenance,
    "RestoreDefaults",
    WorkspaceActionCommandId.RestoreDefaults,
    WorkspaceActionGateId.CanRestoreDefaults,
    true,
    "settings Restore Defaults");
AssertResolvedAction(
    catalog,
    details,
    settingsReadyGates,
    WorkspaceActionSurface.SettingsMaintenance,
    "ResetMonitorData",
    WorkspaceActionCommandId.ResetMonitorData,
    WorkspaceActionGateId.CanResetMonitorData,
    true,
    "settings Reset Monitor Data");

var settingsBlockedState = BuildCommandState(
    liveReady: true,
    selectedFeatureId: FeatureEntryId.Settings);
settingsClient.CanExportSettingsValue = false;
settingsClient.CanImportSettingsValue = false;
settingsClient.CanResetSettingsValue = false;
settingsClient.CanRequestPermissionValue = false;
settingsClient.CanOpenSystemPreferencesValue = false;
settingsClient.CanApplySettingsValue = false;
settingsClient.CanRestoreDefaultsValue = false;
settingsClient.CanResetMonitorDataValue = false;
var settingsBlockedAvailability = new WorkspaceCommandAvailability(coordinator, () => settingsBlockedState);
AssertEqual(true, settingsBlockedAvailability.CanRefreshSettings(), "blocked settings WorkspaceCommandAvailability.Refresh");
AssertEqual(false, settingsBlockedAvailability.CanExportSettings(), "blocked settings WorkspaceCommandAvailability.Export");
AssertEqual(false, settingsBlockedAvailability.CanImportSettings(), "blocked settings WorkspaceCommandAvailability.Import");
AssertEqual(false, settingsBlockedAvailability.CanResetSettings(), "blocked settings WorkspaceCommandAvailability.Reset");
AssertEqual(false, settingsBlockedAvailability.CanRequestSettingsPermission(), "blocked settings WorkspaceCommandAvailability.RequestPermission");
AssertEqual(false, settingsBlockedAvailability.CanOpenSystemPreferences(), "blocked settings WorkspaceCommandAvailability.OpenSystemPreferences");
AssertEqual(false, settingsBlockedAvailability.CanApplySettings(), "blocked settings WorkspaceCommandAvailability.ApplySettings");
AssertEqual(false, settingsBlockedAvailability.CanRestoreDefaults(), "blocked settings WorkspaceCommandAvailability.RestoreDefaults");
AssertEqual(false, settingsBlockedAvailability.CanResetMonitorData(), "blocked settings WorkspaceCommandAvailability.ResetMonitorData");
var settingsBlockedGates = coordinator.BuildActionGateSnapshot(settingsBlockedState);
AssertResolvedAction(
    catalog,
    details,
    settingsBlockedGates,
    WorkspaceActionSurface.SettingsToolbar,
    "ExportSettings",
    WorkspaceActionCommandId.ExportSettings,
    WorkspaceActionGateId.CanExportSettings,
    false,
    "blocked settings Export");
AssertResolvedAction(
    catalog,
    details,
    settingsBlockedGates,
    WorkspaceActionSurface.SettingsToolbar,
    "ImportSettings",
    WorkspaceActionCommandId.ImportSettings,
    WorkspaceActionGateId.CanImportSettings,
    false,
    "blocked settings Import");
AssertResolvedAction(
    catalog,
    details,
    settingsBlockedGates,
    WorkspaceActionSurface.SettingsToolbar,
    "ResetSettings",
    WorkspaceActionCommandId.ResetSettings,
    WorkspaceActionGateId.CanResetSettings,
    false,
    "blocked settings Reset");
AssertResolvedAction(
    catalog,
    details,
    settingsBlockedGates,
    WorkspaceActionSurface.SettingsToolbar,
    "RequestPermission",
    WorkspaceActionCommandId.RequestSettingsPermission,
    WorkspaceActionGateId.CanRequestSettingsPermission,
    false,
    "blocked settings Request Permission");
AssertResolvedAction(
    catalog,
    details,
    settingsBlockedGates,
    WorkspaceActionSurface.SettingsToolbar,
    "OpenSystemPreferences",
    WorkspaceActionCommandId.OpenSystemPreferences,
    WorkspaceActionGateId.CanOpenSystemPreferences,
    false,
    "blocked settings Open System Preferences");
AssertResolvedAction(
    catalog,
    details,
    settingsBlockedGates,
    WorkspaceActionSurface.SettingsMaintenance,
    "ApplySettings",
    WorkspaceActionCommandId.ApplySettings,
    WorkspaceActionGateId.CanApplySettings,
    false,
    "blocked settings Apply Settings");
AssertResolvedAction(
    catalog,
    details,
    settingsBlockedGates,
    WorkspaceActionSurface.SettingsMaintenance,
    "RestoreDefaults",
    WorkspaceActionCommandId.RestoreDefaults,
    WorkspaceActionGateId.CanRestoreDefaults,
    false,
    "blocked settings Restore Defaults");
AssertResolvedAction(
    catalog,
    details,
    settingsBlockedGates,
    WorkspaceActionSurface.SettingsMaintenance,
    "ResetMonitorData",
    WorkspaceActionCommandId.ResetMonitorData,
    WorkspaceActionGateId.CanResetMonitorData,
    false,
    "blocked settings Reset Monitor Data");

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

sealed class TestTopBarStatusClient : ITopBarStatusClient
{
    public TestTopBarStatusClient(
        bool canOpenNotifications,
        bool canToggleTheme)
    {
        CanOpenNotificationsValue = canOpenNotifications;
        CanToggleThemeValue = canToggleTheme;
    }

    public bool CanOpenNotificationsValue { get; set; }

    public bool CanToggleThemeValue { get; set; }

    public TopBarStatusSnapshot BuildReadOnlySnapshot(TopBarStatusRequest request) =>
        new(
            DateTimeOffset.UtcNow,
            new[]
            {
                new TopBarStatusItem(TopBarStatusSlot.Connection, "Connection", request.ConnectionStatus, "Connection"),
                new TopBarStatusItem(TopBarStatusSlot.Diagnostics, "FPS / Diagnostics", request.PerformanceStatus, "Diagnostics"),
                new TopBarStatusItem(TopBarStatusSlot.Notifications, "Notifications", "Off", "Notifications"),
                new TopBarStatusItem(TopBarStatusSlot.Theme, "Theme", "System", "Theme")
            });

    public TopBarResolvedStatusSnapshot BuildResolvedStatusSnapshot(TopBarStatusRequest request) =>
        new(DateTimeOffset.UtcNow, request.ConnectionStatus, request.PerformanceStatus, "Off", "System");

    public TopBarStatusUpdateSnapshot BuildStatusUpdate(TopBarStatusRequest request) =>
        new(
            BuildResolvedStatusSnapshot(request),
            new WorkspaceActionDetailSnapshot("Off", "System"));

    public string BuildDefaultStatusValue(TopBarStatusSlot slot) =>
        slot == TopBarStatusSlot.Notifications ? "Off" : slot == TopBarStatusSlot.Theme ? "System" : "";

    public string ResolveStatusValue(
        TopBarStatusSnapshot snapshot,
        TopBarStatusSlot slot,
        string fallback) =>
        snapshot.Items.FirstOrDefault(item => item.Slot == slot)?.Value ?? fallback;

    public WorkspaceActionDetailSnapshot BuildWorkspaceActionDetailSnapshot(
        TopBarResolvedStatusSnapshot snapshot) =>
        new(snapshot.NotificationsStatus, snapshot.ThemeStatus);

    public bool CanOpenNotifications() => CanOpenNotificationsValue;

    public bool CanToggleTheme() => CanToggleThemeValue;

    public string BuildNotificationsPendingStatus() => "Preparing notifications...";

    public string BuildThemePendingStatus() => "Preparing theme action...";

    public Task<TopBarWorkspaceActionResult> BuildNotificationsActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs top bar action readiness.");

    public Task<TopBarWorkspaceActionResult> BuildThemeActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs top bar action readiness.");
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

sealed class TestRemoteDesktopWorkspaceClient : IRemoteDesktopWorkspaceClient
{
    public TestRemoteDesktopWorkspaceClient(
        bool canRecommendedConnect,
        bool canAdvancedConnect,
        bool canShowPerformanceOverlay,
        bool canApplyQuality,
        bool canOpenSettings,
        bool canEnterFullScreen,
        bool canDisconnectSession)
    {
        CanRecommendedConnectValue = canRecommendedConnect;
        CanAdvancedConnectValue = canAdvancedConnect;
        CanShowPerformanceOverlayValue = canShowPerformanceOverlay;
        CanApplyQualityValue = canApplyQuality;
        CanOpenSettingsValue = canOpenSettings;
        CanEnterFullScreenValue = canEnterFullScreen;
        CanDisconnectSessionValue = canDisconnectSession;
    }

    public bool CanRecommendedConnectValue { get; set; }

    public bool CanAdvancedConnectValue { get; set; }

    public bool CanShowPerformanceOverlayValue { get; set; }

    public bool CanApplyQualityValue { get; set; }

    public bool CanOpenSettingsValue { get; set; }

    public bool CanEnterFullScreenValue { get; set; }

    public bool CanDisconnectSessionValue { get; set; }

    public string BuildInitialStatus() => "Ready";

    public string BuildPendingStatus() => "Refreshing...";

    public string BuildCompletedStatus(RemoteDesktopWorkspaceSnapshot snapshot) => "Snapshot";

    public string BuildCompletedStatusMessage() => "Updated";

    public bool CanStartRecommendedSession() => CanRecommendedConnectValue;

    public bool CanStartAdvancedSession() => CanAdvancedConnectValue;

    public bool CanShowPerformanceOverlay() => CanShowPerformanceOverlayValue;

    public bool CanApplyQuality() => CanApplyQualityValue;

    public bool CanOpenSettings() => CanOpenSettingsValue;

    public bool CanEnterFullScreen() => CanEnterFullScreenValue;

    public bool CanDisconnectSession() => CanDisconnectSessionValue;

    public string BuildRecommendedConnectPendingStatus() => "Preparing recommended session...";

    public string BuildAdvancedConnectPendingStatus() => "Preparing advanced session...";

    public string BuildNearFieldPendingStatus() => "Preparing near-field connection...";

    public string BuildAdvancedConnectModeStatus() => "Preparing advanced connection mode...";

    public string BuildPerformanceOverlayPendingStatus() => "Preparing performance overlay...";

    public string BuildQualityPendingStatus() => "Preparing quality controls...";

    public string BuildSettingsPendingStatus() => "Preparing remote desktop settings...";

    public string BuildFullScreenPendingStatus() => "Preparing full screen...";

    public string BuildDisconnectSessionPendingStatus() => "Preparing session disconnect...";

    public Task<RemoteDesktopWorkspaceSnapshot> BuildReadOnlySnapshotAsync(
        string bitrateProfile,
        string framerateProfile) =>
        throw new NotSupportedException("Command-gate smoke only needs remote desktop action readiness.");

    public Task<RemoteDesktopWorkspaceActionResult> BuildRecommendedConnectActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs remote desktop action readiness.");

    public Task<RemoteDesktopWorkspaceActionResult> BuildAdvancedConnectActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs remote desktop action readiness.");

    public Task<RemoteDesktopWorkspaceActionResult> BuildPerformanceOverlayActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs remote desktop action readiness.");

    public Task<RemoteDesktopWorkspaceActionResult> BuildQualityActionAsync(
        string bitrateProfile,
        string framerateProfile) =>
        throw new NotSupportedException("Command-gate smoke only needs remote desktop action readiness.");

    public Task<RemoteDesktopWorkspaceActionResult> BuildSettingsActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs remote desktop action readiness.");

    public Task<RemoteDesktopWorkspaceActionResult> BuildFullScreenActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs remote desktop action readiness.");

    public Task<RemoteDesktopWorkspaceActionResult> BuildDisconnectSessionActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs remote desktop action readiness.");
}

sealed class TestSystemMonitorWorkspaceClient : ISystemMonitorWorkspaceClient
{
    public TestSystemMonitorWorkspaceClient(
        bool canStartMonitoring,
        bool canStopMonitoring,
        bool canEnableAdvancedMonitoring)
    {
        CanStartMonitoringValue = canStartMonitoring;
        CanStopMonitoringValue = canStopMonitoring;
        CanEnableAdvancedMonitoringValue = canEnableAdvancedMonitoring;
    }

    public bool CanStartMonitoringValue { get; set; }

    public bool CanStopMonitoringValue { get; set; }

    public bool CanEnableAdvancedMonitoringValue { get; set; }

    public string BuildInitialStatus() => "Ready";

    public string BuildPendingStatus() => "Refreshing...";

    public string BuildCompletedStatus(SystemMonitorWorkspaceSnapshot snapshot) => "Snapshot";

    public string BuildCompletedStatusMessage() => "Updated";

    public bool CanStartMonitoring() => CanStartMonitoringValue;

    public bool CanStopMonitoring() => CanStopMonitoringValue;

    public bool CanEnableAdvancedMonitoring() => CanEnableAdvancedMonitoringValue;

    public string BuildStartMonitoringPendingStatus() => "Preparing monitoring...";

    public string BuildStopMonitoringPendingStatus() => "Preparing monitoring stop...";

    public string BuildAdvancedMonitoringPendingStatus() => "Preparing advanced monitoring...";

    public Task<SystemMonitorWorkspaceSnapshot> BuildReadOnlySnapshotAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs system monitor action readiness.");

    public Task<SystemMonitorWorkspaceActionResult> BuildStartMonitoringActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs system monitor action readiness.");

    public Task<SystemMonitorWorkspaceActionResult> BuildStopMonitoringActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs system monitor action readiness.");

    public Task<SystemMonitorWorkspaceActionResult> BuildAdvancedMonitoringActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs system monitor action readiness.");
}

sealed class TestSettingsWorkspaceClient : ISettingsWorkspaceClient
{
    public TestSettingsWorkspaceClient(
        bool canExportSettings,
        bool canImportSettings,
        bool canResetSettings,
        bool canRequestPermission,
        bool canOpenSystemPreferences,
        bool canApplySettings,
        bool canRestoreDefaults,
        bool canResetMonitorData)
    {
        CanExportSettingsValue = canExportSettings;
        CanImportSettingsValue = canImportSettings;
        CanResetSettingsValue = canResetSettings;
        CanRequestPermissionValue = canRequestPermission;
        CanOpenSystemPreferencesValue = canOpenSystemPreferences;
        CanApplySettingsValue = canApplySettings;
        CanRestoreDefaultsValue = canRestoreDefaults;
        CanResetMonitorDataValue = canResetMonitorData;
    }

    public bool CanExportSettingsValue { get; set; }

    public bool CanImportSettingsValue { get; set; }

    public bool CanResetSettingsValue { get; set; }

    public bool CanRequestPermissionValue { get; set; }

    public bool CanOpenSystemPreferencesValue { get; set; }

    public bool CanApplySettingsValue { get; set; }

    public bool CanRestoreDefaultsValue { get; set; }

    public bool CanResetMonitorDataValue { get; set; }

    public string BuildInitialStatus() => "Ready";

    public string BuildPendingStatus() => "Refreshing...";

    public string BuildCompletedStatus(SettingsWorkspaceSnapshot snapshot) => "Snapshot";

    public string BuildCompletedStatusMessage() => "Updated";

    public bool CanExportSettings() => CanExportSettingsValue;

    public bool CanImportSettings() => CanImportSettingsValue;

    public bool CanResetSettings() => CanResetSettingsValue;

    public bool CanRequestPermission() => CanRequestPermissionValue;

    public bool CanOpenSystemPreferences() => CanOpenSystemPreferencesValue;

    public bool CanApplySettings() => CanApplySettingsValue;

    public bool CanRestoreDefaults() => CanRestoreDefaultsValue;

    public bool CanResetMonitorData() => CanResetMonitorDataValue;

    public string BuildExportSettingsPendingStatus() => "Preparing settings export...";

    public string BuildImportSettingsPendingStatus() => "Preparing settings import...";

    public string BuildResetSettingsPendingStatus() => "Preparing settings reset...";

    public string BuildPermissionRequestPendingStatus() => "Preparing permission request...";

    public string BuildSystemPreferencesPendingStatus() => "Preparing system preferences...";

    public string BuildApplySettingsPendingStatus() => "Preparing settings apply...";

    public string BuildRestoreDefaultsPendingStatus() => "Preparing default restore...";

    public string BuildResetMonitorDataPendingStatus() => "Preparing monitor data reset...";

    public Task<SettingsWorkspaceSnapshot> BuildReadOnlySnapshotAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs settings action readiness.");

    public Task<SettingsWorkspaceActionResult> BuildExportSettingsActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs settings action readiness.");

    public Task<SettingsWorkspaceActionResult> BuildImportSettingsActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs settings action readiness.");

    public Task<SettingsWorkspaceActionResult> BuildResetSettingsActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs settings action readiness.");

    public Task<SettingsWorkspaceActionResult> BuildPermissionRequestActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs settings action readiness.");

    public Task<SettingsWorkspaceActionResult> BuildSystemPreferencesActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs settings action readiness.");

    public Task<SettingsWorkspaceActionResult> BuildApplySettingsActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs settings action readiness.");

    public Task<SettingsWorkspaceActionResult> BuildRestoreDefaultsActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs settings action readiness.");

    public Task<SettingsWorkspaceActionResult> BuildResetMonitorDataActionAsync() =>
        throw new NotSupportedException("Command-gate smoke only needs settings action readiness.");
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
