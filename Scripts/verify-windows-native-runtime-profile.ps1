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
$sourceFiles += Get-ChildItem -LiteralPath (Join-Path $RepoRoot "windows/Skybridge.WinClient/Converters") -Filter "*.cs" |
    Sort-Object Name |
    ForEach-Object { $_.FullName }
$sourceFiles += (Resolve-Path -LiteralPath (Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/SessionViewModelDependencies.cs")).Path
$sourceFiles += (Resolve-Path -LiteralPath (Join-Path $RepoRoot "windows/Skybridge.WinClient/SessionViewModelDependencyFactory.cs")).Path
$sourceFiles += (Resolve-Path -LiteralPath (Join-Path $RepoRoot "windows/Skybridge.WinClient/WindowsNativeRuntimeDependencyFactory.cs")).Path

foreach ($sourceFile in $sourceFiles) {
    Assert-True -Condition (Test-Path -LiteralPath $sourceFile) -Message "Missing Windows native runtime source file: $sourceFile"
}

$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-native-runtime-profile-" + [guid]::NewGuid().ToString("N"))
$testProject = Join-Path $tempRoot "Skybridge.WinNativeRuntimeProfile.csproj"
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
    <EnableWindowsTargeting>true</EnableWindowsTargeting>
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
using System.Buffers.Binary;
using System.Net;
using System.Net.Http;
using System.Net.WebSockets;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Skybridge.WinClient;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.ViewModels;

var runtimeVariables = new[]
{
    "SKYBRIDGE_WINDOWS_RUNTIME",
    "SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER",
    "SKYBRIDGE_WINDOWS_ADAPTER_BINDING",
    "SKYBRIDGE_WINDOWS_LOCAL_ENDPOINT",
    "SKYBRIDGE_WINDOWS_REMOTE_ENDPOINT",
    "SKYBRIDGE_WINDOWS_SELECTED_CANDIDATE_PAIR",
    "SKYBRIDGE_WINDOWS_TRANSPORT_SECRET_FP_HEX",
    "SKYBRIDGE_WINDOWS_CAPABILITY_DIGEST_HEX",
    "SKYBRIDGE_WINDOWS_RELAY_ID",
    "SKYBRIDGE_WINDOWS_ADAPTER_KIND",
    "SKYBRIDGE_WINDOWS_TIMESTAMP_WINDOW_MS",
    "SKYBRIDGE_WINDOWS_WEBRTC_PROOF_PATH",
    "SKYBRIDGE_WINDOWS_WEBRTC_PROOF_MAX_AGE_MS",
    "SKYBRIDGE_WINDOWS_WEBRTC_HELPER_PATH",
    "SKYBRIDGE_WINDOWS_WEBRTC_SIGNALING_DIR",
    "SKYBRIDGE_WINDOWS_WEBRTC_PROOF_FILE",
    "SKYBRIDGE_WINDOWS_WEBRTC_OFFER_FILE",
    "SKYBRIDGE_WINDOWS_WEBRTC_ANSWER_FILE",
    "SKYBRIDGE_WINDOWS_WEBRTC_ICE_SERVERS",
    "SKYBRIDGE_WINDOWS_WEBRTC_BIND_ADDRESS",
    "SKYBRIDGE_WINDOWS_WEBRTC_ICE_INCLUDE_ALL_INTERFACES",
    "SKYBRIDGE_WINDOWS_WEBRTC_LAUNCH_TIMEOUT_SECONDS",
    "SKYBRIDGE_WINDOWS_WEBRTC_SESSION_ROLE",
    "SKYBRIDGE_WINDOWS_WEBRTC_SESSION_IPC_PORT",
    "SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE",
    "SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE_EVIDENCE_PATH",
    "SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE_TIMEOUT_SECONDS",
    "SKYBRIDGE_WINDOWS_MSQUIC_PEER_ENDPOINT",
    "SKYBRIDGE_WINDOWS_MSQUIC_ROLE",
    "SKYBRIDGE_WINDOWS_MSQUIC_LISTEN_ENDPOINT",
    "SKYBRIDGE_WINDOWS_MSQUIC_ACCEPT_TIMEOUT_MS",
    "SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES"
};

try
{
    ClearRuntimeEnvironment();
    AssertEqual(false, WindowsNativeRuntimeDependencyFactory.IsNativeRuntimeRequested(), "default native DNS-SD profile flag");
    var defaultDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<FfiEngineClient>(defaultDependencies.EngineClient, "default engine");
    AssertNestedType<PendingWindowsDnsSdBrowseClient>(defaultDependencies.DiscoveryBrowserClient, "_dnsSdBrowseClient", "default DNS-SD provider");
    AssertNestedType<PendingWindowsTransportAdapterClient>(defaultDependencies.ConnectionPreflightClient, "_transportAdapterClient", "default transport adapter");
    AssertType<SystemMonitorWorkspaceClient>(defaultDependencies.SystemMonitorClient, "default system monitor client");
    AssertEqual(true, defaultDependencies.SystemMonitorClient.CanStartMonitoring(), "default system monitor start gate");
    AssertEqual(false, defaultDependencies.SystemMonitorClient.CanStopMonitoring(), "default system monitor stop gate");
    AssertEqual(true, defaultDependencies.SystemMonitorClient.CanEnableAdvancedMonitoring(), "default system monitor advanced gate");
    var startMonitoring = await defaultDependencies.SystemMonitorClient.BuildStartMonitoringActionAsync();
    AssertEqual(SystemMonitorWorkspaceClient.DefaultStartMonitoringStartedStatus, startMonitoring.Status, "start monitoring status");
    AssertEqual(false, defaultDependencies.SystemMonitorClient.CanStartMonitoring(), "active system monitor start gate");
    AssertEqual(true, defaultDependencies.SystemMonitorClient.CanStopMonitoring(), "active system monitor stop gate");
    var activeMonitoringSnapshot = await defaultDependencies.SystemMonitorClient.BuildReadOnlySnapshotAsync();
    AssertIndicator(activeMonitoringSnapshot, "Monitoring", "Active", "active monitoring indicator");
    var stopMonitoring = await defaultDependencies.SystemMonitorClient.BuildStopMonitoringActionAsync();
    AssertEqual(SystemMonitorWorkspaceClient.DefaultStopMonitoringStoppedStatus, stopMonitoring.Status, "stop monitoring status");
    AssertEqual(true, defaultDependencies.SystemMonitorClient.CanStartMonitoring(), "stopped system monitor start gate");
    AssertEqual(false, defaultDependencies.SystemMonitorClient.CanStopMonitoring(), "stopped system monitor stop gate");
    var advancedMonitoring = await defaultDependencies.SystemMonitorClient.BuildAdvancedMonitoringActionAsync();
    AssertEqual(SystemMonitorWorkspaceClient.DefaultAdvancedMonitoringEnabledStatus, advancedMonitoring.Status, "advanced monitoring status");
    AssertEqual(SystemMonitorWorkspaceClient.DefaultAdvancedMonitoringEnabledMessage, advancedMonitoring.Message, "advanced monitoring message");
    AssertEqual(false, defaultDependencies.SystemMonitorClient.CanEnableAdvancedMonitoring(), "enabled system monitor advanced gate");
    var advancedMonitoringSnapshot = await defaultDependencies.SystemMonitorClient.BuildReadOnlySnapshotAsync();
    AssertIndicator(advancedMonitoringSnapshot, "Advanced", "Read-only", "advanced monitoring indicator");
    var repeatedAdvancedMonitoring = await defaultDependencies.SystemMonitorClient.BuildAdvancedMonitoringActionAsync();
    AssertEqual(SystemMonitorWorkspaceClient.DefaultAdvancedMonitoringBlockedStatus, repeatedAdvancedMonitoring.Status, "repeat advanced monitoring status");
    AssertType<FileTransferWorkspaceClient>(defaultDependencies.FileTransferClient, "default file transfer client");
    AssertNestedType<InMemoryFileTransferSelectionIntentClient>(defaultDependencies.FileTransferClient, "_selectionIntentClient", "default file transfer selection intent client");
    AssertEqual(true, defaultDependencies.FileTransferClient.CanSelectFiles(), "default file transfer select files gate");
    AssertEqual(true, defaultDependencies.FileTransferClient.CanSelectFolder(), "default file transfer select folder gate");
    AssertEqual(true, defaultDependencies.FileTransferClient.CanGenerateShareQr(), "default file transfer QR share gate");
    var selectFilesIntent = await defaultDependencies.FileTransferClient.BuildSelectFilesActionAsync();
    AssertEqual(FileTransferWorkspaceClient.DefaultSelectFilesIntentReadyStatus, selectFilesIntent.Status, "file transfer select files intent status");
    AssertContains(selectFilesIntent.Detail, "intent=FT-FILES-0001", "file transfer select files intent detail should include deterministic in-memory intent id.");
    AssertContains(selectFilesIntent.Detail, "no local files were read", "file transfer select files intent detail should keep file reads disabled.");
    var selectFolderIntent = await defaultDependencies.FileTransferClient.BuildSelectFolderActionAsync();
    AssertEqual(FileTransferWorkspaceClient.DefaultSelectFolderIntentReadyStatus, selectFolderIntent.Status, "file transfer select folder intent status");
    AssertContains(selectFolderIntent.Detail, "intent=FT-FOLDER-0001", "file transfer select folder intent detail should include deterministic in-memory intent id.");
    AssertContains(selectFolderIntent.Detail, "no directory was scanned", "file transfer select folder intent detail should keep directory scanning disabled.");
    var selectionIntentClient = GetNested<InMemoryFileTransferSelectionIntentClient>(
        defaultDependencies.FileTransferClient,
        "_selectionIntentClient");
    var selectionIntentSnapshot = selectionIntentClient.CaptureSnapshot();
    AssertEqual(true, selectionIntentSnapshot.HasFilesIntent, "file transfer files selection snapshot readiness");
    AssertEqual("FT-FILES-0001", selectionIntentSnapshot.FilesIntentId, "file transfer files selection snapshot id");
    AssertEqual(true, selectionIntentSnapshot.HasFolderIntent, "file transfer folder selection snapshot readiness");
    AssertEqual("FT-FOLDER-0001", selectionIntentSnapshot.FolderIntentId, "file transfer folder selection snapshot id");
    var shareQrIntent = await defaultDependencies.FileTransferClient.BuildShareQrActionAsync();
    AssertEqual(FileTransferWorkspaceClient.DefaultShareQrReadyStatus, shareQrIntent.Status, "file transfer QR share intent status");
    AssertEqual(FileTransferWorkspaceClient.DefaultShareQrReadyMessage, shareQrIntent.Message, "file transfer QR share intent message");
    AssertContains(shareQrIntent.Detail, "intent=FT-0001", "file transfer QR share intent detail should include deterministic in-memory intent id.");
    AssertContains(shareQrIntent.Detail, "no transport or signaling session was started", "file transfer QR share intent detail should keep transport/signaling disabled.");
    AssertType<SettingsWorkspaceClient>(defaultDependencies.SettingsClient, "default settings client");
    AssertNestedType<DisabledSystemPreferencesLauncher>(defaultDependencies.SettingsClient, "_systemPreferencesLauncher", "default system preferences launcher");
    AssertNestedType<InMemorySettingsExportPreviewClient>(defaultDependencies.SettingsClient, "_exportPreviewClient", "default settings export preview client");
    AssertNestedType<InMemorySettingsActionIntentClient>(defaultDependencies.SettingsClient, "_actionIntentClient", "default settings action intent client");
    AssertEqual(true, defaultDependencies.SettingsClient.CanExportSettings(), "default settings export gate");
    AssertEqual(true, defaultDependencies.SettingsClient.CanImportSettings(), "default settings import intent gate");
    AssertEqual(true, defaultDependencies.SettingsClient.CanResetSettings(), "default settings reset intent gate");
    AssertEqual(true, defaultDependencies.SettingsClient.CanRequestPermission(), "default settings permission intent gate");
    AssertEqual(false, defaultDependencies.SettingsClient.CanOpenSystemPreferences(), "default system preferences gate");
    AssertEqual(true, defaultDependencies.SettingsClient.CanApplySettings(), "default settings apply intent gate");
    AssertEqual(true, defaultDependencies.SettingsClient.CanRestoreDefaults(), "default settings restore defaults intent gate");
    AssertEqual(true, defaultDependencies.SettingsClient.CanResetMonitorData(), "default settings reset monitor data intent gate");
    var exportPreview = await defaultDependencies.SettingsClient.BuildExportSettingsActionAsync();
    AssertEqual(SettingsWorkspaceClient.DefaultExportSettingsPreviewReadyStatus, exportPreview.Status, "settings export preview status");
    AssertEqual($"{SettingsWorkspaceClient.DefaultExportSettingsPreviewReadyMessage} preview=SET-0001", exportPreview.Message, "settings export preview message");
    var importIntent = await defaultDependencies.SettingsClient.BuildImportSettingsActionAsync();
    AssertEqual(SettingsWorkspaceClient.DefaultImportSettingsIntentReadyStatus, importIntent.Status, "settings import intent status");
    AssertContains(importIntent.Message, "intent=SET-IMPORT-0001", "settings import intent message id");
    AssertContains(importIntent.Message, "no file was opened, read, or written", "settings import intent keeps file writes disabled");
    var resetIntent = await defaultDependencies.SettingsClient.BuildResetSettingsActionAsync();
    AssertEqual(SettingsWorkspaceClient.DefaultResetSettingsIntentReadyStatus, resetIntent.Status, "settings reset intent status");
    AssertContains(resetIntent.Message, "intent=SET-RESET-0002", "settings reset intent message id");
    AssertContains(resetIntent.Message, "no preference was changed", "settings reset intent keeps preference writes disabled");
    var permissionIntent = await defaultDependencies.SettingsClient.BuildPermissionRequestActionAsync();
    AssertEqual(SettingsWorkspaceClient.DefaultPermissionRequestIntentReadyStatus, permissionIntent.Status, "settings permission intent status");
    AssertContains(permissionIntent.Message, "intent=SET-PERM-0003", "settings permission intent message id");
    AssertContains(permissionIntent.Message, "no permission prompt was shown", "settings permission intent keeps prompts disabled");
    var applyIntent = await defaultDependencies.SettingsClient.BuildApplySettingsActionAsync();
    AssertEqual(SettingsWorkspaceClient.DefaultApplySettingsIntentReadyStatus, applyIntent.Status, "settings apply intent status");
    AssertContains(applyIntent.Message, "intent=SET-APPLY-0004", "settings apply intent message id");
    AssertContains(applyIntent.Message, "no runtime settings were applied", "settings apply intent keeps runtime writes disabled");
    var restoreIntent = await defaultDependencies.SettingsClient.BuildRestoreDefaultsActionAsync();
    AssertEqual(SettingsWorkspaceClient.DefaultRestoreDefaultsIntentReadyStatus, restoreIntent.Status, "settings restore defaults intent status");
    AssertContains(restoreIntent.Message, "intent=SET-DEFAULTS-0005", "settings restore defaults intent message id");
    AssertContains(restoreIntent.Message, "no defaults were restored", "settings restore defaults intent keeps default writes disabled");
    var resetMonitorIntent = await defaultDependencies.SettingsClient.BuildResetMonitorDataActionAsync();
    AssertEqual(SettingsWorkspaceClient.DefaultResetMonitorDataIntentReadyStatus, resetMonitorIntent.Status, "settings reset monitor data intent status");
    AssertContains(resetMonitorIntent.Message, "intent=SET-MONITOR-0006", "settings reset monitor data intent message id");
    AssertContains(resetMonitorIntent.Message, "no monitor data was deleted", "settings reset monitor data intent keeps deletion disabled");
    var actionIntentClient = GetNested<InMemorySettingsActionIntentClient>(
        defaultDependencies.SettingsClient,
        "_actionIntentClient");
    var actionIntentSnapshot = actionIntentClient.CaptureSnapshot();
    AssertEqual(true, actionIntentSnapshot.HasIntent, "settings action intent snapshot readiness");
    AssertEqual("ResetMonitorData", actionIntentSnapshot.ActionKey, "settings action intent snapshot latest action");
    AssertEqual("SET-MONITOR-0006", actionIntentSnapshot.IntentId, "settings action intent snapshot id");
    var settingsSnapshot = await defaultDependencies.SettingsClient.BuildReadOnlySnapshotAsync();
    AssertSettingsAction(settingsSnapshot, "ExportSettings", "Preview ready", "settings export preview action");
    AssertSettingsAction(settingsSnapshot, "ImportSettings", "Ready", "settings import intent action");
    AssertSettingsAction(settingsSnapshot, "ResetMonitorData", "Intent ready", "settings reset monitor data intent action");
    var settingsDetailSeparator = '\u00b7';
    AssertSettingsDetail(settingsSnapshot, "General", $"Data management {settingsDetailSeparator} Export settings", "SET-0001", "settings export preview detail");
    AssertSettingsDetail(settingsSnapshot, "General", $"Workspace {settingsDetailSeparator} Latest settings action", "SET-MONITOR-0006", "settings latest action intent detail");
    AssertType<TopBarStatusClient>(defaultDependencies.TopBarStatusClient, "default top-bar status client");
    AssertEqual(true, defaultDependencies.TopBarStatusClient.CanOpenNotifications(), "default top-bar notifications gate");
    AssertEqual(true, defaultDependencies.TopBarStatusClient.CanToggleTheme(), "default top-bar theme gate");
    var initialTopBarUpdate = defaultDependencies.TopBarStatusClient.BuildStatusUpdate(
        new TopBarStatusRequest("Disconnected", "Nominal", "Dashboard"));
    AssertEqual(TopBarStatusClient.DefaultNotificationsStatus, initialTopBarUpdate.ResolvedStatus.NotificationsStatus, "initial top-bar notifications status");
    AssertEqual(TopBarStatusClient.DefaultThemeStatus, initialTopBarUpdate.ResolvedStatus.ThemeStatus, "initial top-bar theme status");
    var notificationsAction = await defaultDependencies.TopBarStatusClient.BuildNotificationsActionAsync();
    AssertEqual(TopBarStatusClient.NotificationsViewedStatus, notificationsAction.Status, "top-bar notifications action status");
    AssertEqual(TopBarStatusClient.DefaultNotificationsOpenedMessage, notificationsAction.Message, "top-bar notifications action message");
    var viewedTopBarUpdate = defaultDependencies.TopBarStatusClient.BuildStatusUpdate(
        new TopBarStatusRequest("Disconnected", "Nominal", "Dashboard"));
    AssertEqual(TopBarStatusClient.NotificationsViewedStatus, viewedTopBarUpdate.ResolvedStatus.NotificationsStatus, "viewed top-bar notifications status");
    var firstThemeToggle = await defaultDependencies.TopBarStatusClient.BuildThemeActionAsync();
    AssertEqual(TopBarStatusClient.DarkThemeStatus, firstThemeToggle.Status, "first top-bar theme toggle");
    AssertEqual(TopBarStatusClient.DefaultThemeUpdatedMessage, firstThemeToggle.Message, "top-bar theme update message");
    var secondThemeToggle = await defaultDependencies.TopBarStatusClient.BuildThemeActionAsync();
    AssertEqual(TopBarStatusClient.LightThemeStatus, secondThemeToggle.Status, "second top-bar theme toggle");
    var thirdThemeToggle = await defaultDependencies.TopBarStatusClient.BuildThemeActionAsync();
    AssertEqual(TopBarStatusClient.DefaultThemeStatus, thirdThemeToggle.Status, "third top-bar theme toggle");
    var cycledTopBarUpdate = defaultDependencies.TopBarStatusClient.BuildStatusUpdate(
        new TopBarStatusRequest("Disconnected", "Nominal", "Dashboard"));
    AssertEqual(TopBarStatusClient.DefaultThemeStatus, cycledTopBarUpdate.ResolvedStatus.ThemeStatus, "cycled top-bar theme status");
    AssertType<RemoteDesktopWorkspaceClient>(defaultDependencies.RemoteDesktopClient, "default remote desktop client");
    AssertEqual(false, defaultDependencies.RemoteDesktopClient.CanStartRecommendedSession(), "default remote desktop recommended connect gate");
    AssertEqual(false, defaultDependencies.RemoteDesktopClient.CanStartAdvancedSession(), "default remote desktop advanced connect gate");
    AssertEqual(true, defaultDependencies.RemoteDesktopClient.CanShowPerformanceOverlay(), "default remote desktop overlay gate");
    AssertEqual(true, defaultDependencies.RemoteDesktopClient.CanApplyQuality(), "default remote desktop quality gate");
    AssertEqual(true, defaultDependencies.RemoteDesktopClient.CanOpenSettings(), "default remote desktop settings gate");
    AssertEqual(false, defaultDependencies.RemoteDesktopClient.CanEnterFullScreen(), "default remote desktop full screen gate");
    AssertEqual(false, defaultDependencies.RemoteDesktopClient.CanDisconnectSession(), "default remote desktop disconnect gate");
    var overlayAction = await defaultDependencies.RemoteDesktopClient.BuildPerformanceOverlayActionAsync();
    AssertEqual(RemoteDesktopWorkspaceClient.DefaultPerformanceOverlayReadyStatus, overlayAction.Status, "remote desktop overlay action status");
    var qualityAction = await defaultDependencies.RemoteDesktopClient.BuildQualityActionAsync("High", "Fps30");
    AssertEqual(RemoteDesktopWorkspaceClient.DefaultQualityAppliedStatus, qualityAction.Status, "remote desktop quality action status");
    var settingsAction = await defaultDependencies.RemoteDesktopClient.BuildSettingsActionAsync();
    AssertEqual(RemoteDesktopWorkspaceClient.DefaultSettingsReadyStatus, settingsAction.Status, "remote desktop settings action status");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "external");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_ADAPTER_BINDING is required when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER=external.");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES", "enabled");
    var systemPreferencesDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<FfiEngineClient>(systemPreferencesDependencies.EngineClient, "system preferences env engine");
    AssertNestedType<PendingWindowsDnsSdBrowseClient>(systemPreferencesDependencies.DiscoveryBrowserClient, "_dnsSdBrowseClient", "system preferences DNS-SD provider");
    AssertType<SettingsWorkspaceClient>(systemPreferencesDependencies.SettingsClient, "system preferences settings client");
    AssertNestedType<WindowsSystemPreferencesLauncher>(systemPreferencesDependencies.SettingsClient, "_systemPreferencesLauncher", "enabled system preferences launcher");
    AssertEqual(true, systemPreferencesDependencies.SettingsClient.CanOpenSystemPreferences(), "enabled system preferences gate");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    AssertEqual(true, WindowsNativeRuntimeDependencyFactory.IsNativeRuntimeRequested(), "native DNS-SD profile flag");
    var nativePendingDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<FfiEngineClient>(nativePendingDependencies.EngineClient, "native profile ffi engine");
    AssertNestedType<NativeWindowsDnsSdBrowseClient>(nativePendingDependencies.DiscoveryBrowserClient, "_dnsSdBrowseClient", "native DNS-SD provider");
    AssertNestedType<PendingWindowsTransportAdapterClient>(nativePendingDependencies.ConnectionPreflightClient, "_transportAdapterClient", "native pending adapter");

    var signalingRoot = Path.Combine(AppContext.BaseDirectory, "webrtc-signaling");
    var helperOptions = new WebRtcHelperLaunchOptions(
        Path.Combine(AppContext.BaseDirectory, "missing-helper.exe"),
        signalingRoot,
        proofFileName: "proof.json",
        offerFileName: "offer.json",
        answerFileName: "answer.json",
        bindAddress: "192.168.0.105",
        includeAllIceInterfaceAddresses: true);
    AssertEqual(Path.GetFullPath(Path.Combine(signalingRoot, "proof.json")), helperOptions.ResolveProofPath(), "WebRTC helper proof path should resolve inside signaling dir");
    AssertEqual(Path.GetFullPath(Path.Combine(signalingRoot, "offer.json")), helperOptions.ResolveOfferPath(), "WebRTC helper offer path should resolve inside signaling dir");
    AssertEqual(Path.GetFullPath(Path.Combine(signalingRoot, "answer.json")), helperOptions.ResolveAnswerPath(), "WebRTC helper answer path should resolve inside signaling dir");
    AssertEqual("192.168.0.105", helperOptions.BindAddress, "WebRTC helper bind address should be normalized");
    AssertEqual(true, helperOptions.IncludeAllIceInterfaceAddresses, "WebRTC helper all-interface ICE flag");

    ExpectThrows<InvalidOperationException>(
        () => new WebRtcHelperLaunchOptions(
            Path.Combine(AppContext.BaseDirectory, "missing-helper.exe"),
            signalingRoot,
            proofFileName: "../proof.json").ResolveProofPath(),
        "WebRTC helper signaling file names must be file names inside the configured signaling directory");

    ExpectThrows<InvalidOperationException>(
        () => new WebRtcHelperLaunchOptions(
            Path.Combine(AppContext.BaseDirectory, "missing-helper.exe"),
            signalingRoot,
            offerFileName: Path.Combine(Path.GetTempPath(), "offer.json")).ResolveOfferPath(),
        "WebRTC helper signaling file names must be file names inside the configured signaling directory");

    ExpectThrows<InvalidOperationException>(
        () => new WebRtcHelperLaunchOptions(
            Path.Combine(AppContext.BaseDirectory, "missing-helper.exe"),
            signalingRoot,
            bindAddress: "127.0.0.1"),
        "WebRTC helper bind address must be a concrete non-loopback local interface address.");

    var launchClient = new WebRtcHelperLaunchClient(helperOptions);
    await ExpectThrowsAsync<InvalidOperationException>(
        () => launchClient.LaunchSessionAsync(new WebRtcHelperSessionRequest(PreferredIpcPort: -1)),
        "WebRTC helper preferred IPC port must be 0");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => launchClient.LaunchSessionAsync(new WebRtcHelperSessionRequest(PreferredIpcPort: 65536)),
        "WebRTC helper preferred IPC port must be 0");
    VerifyWebRtcSessionSignalDocumentValidation(signalingRoot);
    await VerifyCurrentPathSignalingContractsAsync();
    await VerifyCurrentPathWebRtcHelperSignalingBridgeAsync(signalingRoot);
    await VerifySkyBridgeDataPlaneValidationAsync();
    await VerifyWebRtcProductControlContractsAsync();
    VerifyWebRtcProductHandshakeCodec();
    VerifyWebRtcProductHandshakeIdentity();
    VerifyWebRtcProductHandshakeSessionKeys();
    await VerifyWebRtcProductSecureSessionStoreAsync();
    await VerifyWebRtcProductPqcHandshakeCryptoProviderAsync();
    await VerifyWebRtcProductHandshakeDriverAsync();
    await VerifyWebRtcAppControlBootstrapClientAsync();
    VerifyWebRtcAppSecureEnvelopeCodec();

    var verifiedProofPath = WriteVerifiedWebRtcProof("webrtc-proof-valid.json");
    ConfigureVerifiedWebRtcEnvironment(verifiedProofPath);
    var verifiedDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<FfiEngineClient>(verifiedDependencies.EngineClient, "verified WebRTC engine");
    AssertNestedType<NativeWindowsDnsSdBrowseClient>(verifiedDependencies.DiscoveryBrowserClient, "_dnsSdBrowseClient", "verified WebRTC DNS-SD provider");
    var verifiedAdapter = GetNested<IWindowsTransportAdapterClient>(verifiedDependencies.ConnectionPreflightClient, "_transportAdapterClient");
    AssertType<VerifiedWebRtcDataChannelTransportAdapterClient>(verifiedAdapter, "verified WebRTC transport adapter");
    var verifiedSnapshot = await verifiedAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WebRtcDataChannel, CoreTransportAuditCode.WebRtcInterop));
    AssertEqual(true, verifiedSnapshot.IsLiveAdapterReady, "verified WebRTC adapter live readiness");
    AssertEqual(ConnectionLaunchAdapterKind.WebRtcDataChannel, verifiedSnapshot.AdapterKind, "verified WebRTC adapter kind");
    AssertEqual("verified webrtc datachannel helper", verifiedSnapshot.AdapterBinding, "verified WebRTC adapter binding");
    AssertEqual("windows.lan:5443", verifiedSnapshot.LocalEndpoint, "verified WebRTC local endpoint");
    AssertEqual("mac.lan:5443", verifiedSnapshot.RemoteEndpoint, "verified WebRTC remote endpoint");
    AssertEqual("webrtc/dtls/sctp/helper-selected", verifiedSnapshot.SelectedCandidatePair, "verified WebRTC candidate pair");
    AssertEqual("relay-helper", verifiedSnapshot.RelayId, "verified WebRTC relay id");
    AssertEqual((ulong)15000, verifiedSnapshot.TimestampWindowMs, "verified WebRTC timestamp window");
    AssertEqual(32, verifiedSnapshot.TransportSecretFingerprint.Length, "verified WebRTC transport secret length");
    AssertEqual(32, verifiedSnapshot.CapabilityDigest.Length, "verified WebRTC capability digest length");
    AssertEqual("relay-helper", verifiedSnapshot.BuildTransportBindingMaterial(CoreTransportKind.WebRtcDataChannel).RelayId, "verified WebRTC binding relay id");
    AssertContains(verifiedSnapshot.Facts[0].Detail, "SBF1", "verified WebRTC proof fact should mention SBF1");

    await ExpectThrowsAsync<InvalidOperationException>(
        () => verifiedAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.AppleNative, CoreTransportAuditCode.AppleNativeDefault)),
        "Windows verified WebRTC adapter must not select AppleNative");

    ConfigureVerifiedWebRtcEnvironment(WriteVerifiedWebRtcProof("webrtc-proof-stale.json", capturedAtUnixMs: DateTimeOffset.UtcNow.AddMinutes(-2).ToUnixTimeMilliseconds()), maxAgeMs: "1000");
    var staleAdapter = GetNested<IWindowsTransportAdapterClient>(SessionViewModelDependencyFactory.CreateConfigured().ConnectionPreflightClient, "_transportAdapterClient");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => staleAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WebRtcDataChannel, CoreTransportAuditCode.WebRtcInterop)),
        "Windows verified WebRTC adapter proof is stale or from the future.");

    ConfigureVerifiedWebRtcEnvironment(WriteVerifiedWebRtcProof("webrtc-proof-fingerprint-mismatch.json", fingerprint: new string('f', 64)));
    var mismatchProofAdapter = GetNested<IWindowsTransportAdapterClient>(SessionViewModelDependencyFactory.CreateConfigured().ConnectionPreflightClient, "_transportAdapterClient");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => mismatchProofAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WebRtcDataChannel, CoreTransportAuditCode.WebRtcInterop)),
        "Windows verified WebRTC adapter proof fingerprint does not match pairing material.");

    ConfigureVerifiedWebRtcEnvironment(WriteVerifiedWebRtcProof("webrtc-proof-no-sbf1.json", sbf1EchoVerified: false));
    var missingSbf1Adapter = GetNested<IWindowsTransportAdapterClient>(SessionViewModelDependencyFactory.CreateConfigured().ConnectionPreflightClient, "_transportAdapterClient");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => missingSbf1Adapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WebRtcDataChannel, CoreTransportAuditCode.WebRtcInterop)),
        "Windows verified WebRTC adapter proof must confirm an SBF1 echo frame.");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-verified");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_WEBRTC_PROOF_PATH is required when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER=webrtc-verified.");

    ConfigureVerifiedWebRtcEnvironment(verifiedProofPath, maxAgeMs: "0");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_WEBRTC_PROOF_MAX_AGE_MS must be a positive unsigned integer.");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-session");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_HELPER_PATH", Path.Combine(AppContext.BaseDirectory, "missing-session-helper.exe"));
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_SIGNALING_DIR", Path.Combine(AppContext.BaseDirectory, "webrtc-session-signaling"));
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_SESSION_ROLE", "offer");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TIMESTAMP_WINDOW_MS", "15000");
    var sessionDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<WebRtcSessionEngineClient>(sessionDependencies.EngineClient, "WebRTC session engine");
    AssertNestedType<NativeWindowsDnsSdBrowseClient>(sessionDependencies.DiscoveryBrowserClient, "_dnsSdBrowseClient", "WebRTC session DNS-SD provider");
    var sessionAdapter = GetNested<IWindowsTransportAdapterClient>(sessionDependencies.ConnectionPreflightClient, "_transportAdapterClient");
    AssertType<WebRtcSessionTransportAdapterClient>(sessionAdapter, "WebRTC session transport adapter");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => sessionAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.AppleNative, CoreTransportAuditCode.AppleNativeDefault)),
        "Windows WebRTC session adapter must not select AppleNative");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => sessionAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WindowsNativeMsQuic, CoreTransportAuditCode.WindowsNativeMsQuicSameLan)),
        "Windows WebRTC session adapter requires the Core-selected transport to be WebRtcDataChannel.");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => sessionAdapter.PrepareAsync(BuildAdapterRequest(
            CoreTransportKind.WebRtcDataChannel,
            CoreTransportAuditCode.WebRtcInterop,
            peerDeviceId: "mac-2")),
        "WebRTC session peer identity does not match pairing material.");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => sessionAdapter.PrepareAsync(BuildAdapterRequest(
            CoreTransportKind.WebRtcDataChannel,
            CoreTransportAuditCode.WebRtcInterop,
            peerFingerprint: new string('f', 64))),
        "WebRTC session discovered fingerprint does not match pairing material.");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => sessionAdapter.PrepareAsync(BuildAdapterRequest(
            CoreTransportKind.WebRtcDataChannel,
            CoreTransportAuditCode.WebRtcInterop,
            peerFingerprint: new string('A', 64),
            pairingFingerprint: new string('A', 64))),
        "WebRTC session requires a 64 lowercase hex peer public key fingerprint.");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => sessionAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WebRtcDataChannel, CoreTransportAuditCode.WebRtcInterop)),
        "WebRTC helper executable was not found");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-session");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_SESSION_ROLE", "relay");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_WEBRTC_SESSION_ROLE must be offer or answer when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER=webrtc-session.");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-session");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_SESSION_IPC_PORT", "65536");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_WEBRTC_SESSION_IPC_PORT must be 0");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-session");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_LAUNCH_TIMEOUT_SECONDS", "0");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_WEBRTC_LAUNCH_TIMEOUT_SECONDS must be a positive integer");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-session");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_ICE_SERVERS", "turn:turn.example:3478|user|pass");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_WEBRTC_ICE_SERVERS must not include TURN credentials");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-session");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE", "clipboard");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE must be 'control'");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-session");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE", "control");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE_TIMEOUT_SECONDS", "0");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE_TIMEOUT_SECONDS must be a positive integer.");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-session");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_BIND_ADDRESS", "not-an-ip-address");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "WebRTC helper bind address must be a valid IP address.");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-product-control");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_HELPER_PATH", Path.Combine(AppContext.BaseDirectory, "missing-product-control-helper.exe"));
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_SIGNALING_DIR", Path.Combine(AppContext.BaseDirectory, "webrtc-product-control-signaling"));
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_SESSION_ROLE", "offer");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TIMESTAMP_WINDOW_MS", "15000");
    var productControlDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<WebRtcProductControlEngineClient>(productControlDependencies.EngineClient, "WebRTC product-control engine");
    AssertNestedType<NativeWindowsDnsSdBrowseClient>(productControlDependencies.DiscoveryBrowserClient, "_dnsSdBrowseClient", "WebRTC product-control DNS-SD provider");
    var productControlAdapter = GetNested<IWindowsTransportAdapterClient>(productControlDependencies.ConnectionPreflightClient, "_transportAdapterClient");
    AssertType<WebRtcProductControlTransportAdapterClient>(productControlAdapter, "WebRTC product-control transport adapter");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => productControlAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.AppleNative, CoreTransportAuditCode.AppleNativeDefault)),
        "WebRTC product-control transport requires Core-selected WebRtcDataChannel transport.");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => productControlAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WindowsNativeMsQuic, CoreTransportAuditCode.WindowsNativeMsQuicSameLan)),
        "WebRTC product-control transport requires Core-selected WebRtcDataChannel transport.");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => productControlAdapter.PrepareAsync(BuildAdapterRequest(
            CoreTransportKind.WebRtcDataChannel,
            CoreTransportAuditCode.WebRtcInterop,
            peerDeviceId: "mac-2")),
        "WebRTC product-control peer identity does not match pairing material.");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => productControlAdapter.PrepareAsync(BuildAdapterRequest(
            CoreTransportKind.WebRtcDataChannel,
            CoreTransportAuditCode.WebRtcInterop,
            peerFingerprint: new string('f', 64))),
        "WebRTC product-control discovered fingerprint does not match pairing material.");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => productControlAdapter.PrepareAsync(BuildAdapterRequest(
            CoreTransportKind.WebRtcDataChannel,
            CoreTransportAuditCode.WebRtcInterop,
            peerFingerprint: new string('A', 64),
            pairingFingerprint: new string('A', 64))),
        "WebRTC product-control requires a 64 lowercase hex peer public key fingerprint.");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => productControlAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WebRtcDataChannel, CoreTransportAuditCode.WebRtcInterop)),
        "WebRTC helper executable was not found");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-product-control");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_SESSION_ROLE", "relay");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_WEBRTC_SESSION_ROLE must be offer or answer when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER=webrtc-product-control.");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-product-control");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_PRODUCT_SMOKE", "control");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "raw product-control smoke must not run inside the WinClient product composition.");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "carrier");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER must be external, webrtc-verified, webrtc-session, webrtc-product-control, or msquic when set.");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "msquic");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_MSQUIC_PEER_ENDPOINT is required when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER=msquic.");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "msquic");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_PEER_ENDPOINT", "192.168.0.42:5443");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TIMESTAMP_WINDOW_MS", "12000");
    var msquicDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<FfiEngineClient>(msquicDependencies.EngineClient, "msquic engine");
    AssertNestedType<NativeWindowsDnsSdBrowseClient>(msquicDependencies.DiscoveryBrowserClient, "_dnsSdBrowseClient", "msquic DNS-SD provider");
    var msquicAdapter = GetNested<IWindowsTransportAdapterClient>(msquicDependencies.ConnectionPreflightClient, "_transportAdapterClient");
    AssertType<WindowsNativeMsQuicTransportAdapterClient>(msquicAdapter, "msquic transport adapter");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => msquicAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.AppleNative, CoreTransportAuditCode.AppleNativeDefault)),
        "Windows native MsQuic adapter must not select AppleNative");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => msquicAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WebRtcDataChannel, CoreTransportAuditCode.WebRtcInterop)),
        "Windows native MsQuic adapter requires the Core-selected transport to be WindowsNativeMsQuic.");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => msquicAdapter.PrepareAsync(BuildMsQuicAdapterRequestWithoutRemoteMsQuic()),
        "Windows native MsQuic adapter requires the remote peer to advertise SupportsMsQuic");

    // Explicit dial role must resolve to the same dialer adapter as the default (unset) role.
    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "msquic");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_ROLE", "dial");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_PEER_ENDPOINT", "192.168.0.42:5443");
    var msquicDialRoleDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    var msquicDialRoleAdapter = GetNested<IWindowsTransportAdapterClient>(msquicDialRoleDependencies.ConnectionPreflightClient, "_transportAdapterClient");
    AssertType<WindowsNativeMsQuicTransportAdapterClient>(msquicDialRoleAdapter, "msquic explicit dial-role transport adapter");

    // Listen role resolves to the inbound listener adapter and shares the same contract gates as the dialer.
    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "msquic");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_ROLE", "listen");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_LISTEN_ENDPOINT", "0.0.0.0:5443");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TIMESTAMP_WINDOW_MS", "12000");
    var msquicListenDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<FfiEngineClient>(msquicListenDependencies.EngineClient, "msquic listen engine");
    AssertNestedType<NativeWindowsDnsSdBrowseClient>(msquicListenDependencies.DiscoveryBrowserClient, "_dnsSdBrowseClient", "msquic listen DNS-SD provider");
    var msquicListenAdapter = GetNested<IWindowsTransportAdapterClient>(msquicListenDependencies.ConnectionPreflightClient, "_transportAdapterClient");
    AssertType<WindowsNativeMsQuicListenerTransportAdapterClient>(msquicListenAdapter, "msquic listen transport adapter");
    // These gates fire BEFORE any UDP bind/accept, so they are safe to drive in a headless smoke (no port is opened).
    await ExpectThrowsAsync<InvalidOperationException>(
        () => msquicListenAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.AppleNative, CoreTransportAuditCode.AppleNativeDefault)),
        "Windows native MsQuic listener must not select AppleNative");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => msquicListenAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WebRtcDataChannel, CoreTransportAuditCode.WebRtcInterop)),
        "Windows native MsQuic listener requires the Core-selected transport to be WindowsNativeMsQuic.");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => msquicListenAdapter.PrepareAsync(BuildMsQuicAdapterRequestWithoutRemoteMsQuic()),
        "Windows native MsQuic listener requires the remote peer to advertise SupportsMsQuic");

    // Listen role without a listen endpoint must fail closed at construction.
    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "msquic");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_ROLE", "listen");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_MSQUIC_LISTEN_ENDPOINT is required when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER=msquic.");

    // Listen role with a bad accept timeout must fail closed.
    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "msquic");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_ROLE", "listen");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_LISTEN_ENDPOINT", "0.0.0.0:5443");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_ACCEPT_TIMEOUT_MS", "0");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_MSQUIC_ACCEPT_TIMEOUT_MS must be a positive unsigned integer.");

    // An unknown msquic role must fail closed.
    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "msquic");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_ROLE", "relay");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_PEER_ENDPOINT", "192.168.0.42:5443");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_MSQUIC_LISTEN_ENDPOINT", "0.0.0.0:5443");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_MSQUIC_ROLE must be dial or listen when SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER=msquic.");

    ConfigureExternalEnvironment();
    var externalDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<FfiEngineClient>(externalDependencies.EngineClient, "external engine");
    AssertNestedType<NativeWindowsDnsSdBrowseClient>(externalDependencies.DiscoveryBrowserClient, "_dnsSdBrowseClient", "external DNS-SD provider");
    var externalAdapter = GetNested<IWindowsTransportAdapterClient>(externalDependencies.ConnectionPreflightClient, "_transportAdapterClient");
    AssertType<ExternalWindowsTransportAdapterClient>(externalAdapter, "external transport adapter");
    var externalSnapshot = await externalAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WebRtcDataChannel, CoreTransportAuditCode.WebRtcInterop));
    AssertEqual(true, externalSnapshot.IsLiveAdapterReady, "external adapter live readiness");
    AssertEqual(ConnectionLaunchAdapterKind.WebRtcDataChannel, externalSnapshot.AdapterKind, "external adapter kind");
    AssertEqual("external webrtc datachannel", externalSnapshot.AdapterBinding, "external adapter binding");
    AssertEqual("windows.example:5443", externalSnapshot.LocalEndpoint, "external local endpoint");
    AssertEqual("mac.example:5443", externalSnapshot.RemoteEndpoint, "external remote endpoint");
    AssertEqual("webrtc/dtls/sctp-selected", externalSnapshot.SelectedCandidatePair, "external candidate pair");
    AssertEqual("relay-1", externalSnapshot.RelayId, "external relay id");
    AssertEqual((ulong)12000, externalSnapshot.TimestampWindowMs, "external timestamp window");
    AssertEqual(32, externalSnapshot.TransportSecretFingerprint.Length, "external transport secret length");
    AssertEqual(32, externalSnapshot.CapabilityDigest.Length, "external capability digest length");
    var binding = externalSnapshot.BuildTransportBindingMaterial(CoreTransportKind.WebRtcDataChannel);
    AssertEqual("relay-1", binding.RelayId, "external binding relay id");

    ConfigureExternalEnvironment(adapterKind: "WindowsNativeMsQuic");
    var mismatchDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    var mismatchAdapter = GetNested<IWindowsTransportAdapterClient>(mismatchDependencies.ConnectionPreflightClient, "_transportAdapterClient");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => mismatchAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.WebRtcDataChannel, CoreTransportAuditCode.WebRtcInterop)),
        "External Windows transport adapter kind must match the Core-selected transport.");

    ConfigureExternalEnvironment(adapterKind: null);
    var appleSelectionDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    var appleSelectionAdapter = GetNested<IWindowsTransportAdapterClient>(appleSelectionDependencies.ConnectionPreflightClient, "_transportAdapterClient");
    await ExpectThrowsAsync<InvalidOperationException>(
        () => appleSelectionAdapter.PrepareAsync(BuildAdapterRequest(CoreTransportKind.AppleNative, CoreTransportAuditCode.AppleNativeDefault)),
        "Windows external adapter must not select AppleNative");

    ConfigureExternalEnvironment(includeBinding: false);
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_ADAPTER_BINDING is required");

    ConfigureExternalEnvironment(secretHex: new string('a', 63));
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_TRANSPORT_SECRET_FP_HEX must be 64 lowercase hex characters.");

    ConfigureExternalEnvironment(secretHex: new string('A', 64));
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_TRANSPORT_SECRET_FP_HEX must be 64 lowercase hex characters.");

    ConfigureExternalEnvironment(timestampWindowMs: "0");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "SKYBRIDGE_WINDOWS_TIMESTAMP_WINDOW_MS must be a positive unsigned integer.");

    ConfigureExternalEnvironment(adapterKind: "AppleNative");
    ExpectThrows<InvalidOperationException>(
        () => SessionViewModelDependencyFactory.CreateConfigured(),
        "Windows external adapter must not select AppleNative");

    Console.WriteLine("windows-native-runtime-profile: ok");
}
finally
{
    ClearRuntimeEnvironment();
}

void VerifyWebRtcSessionSignalDocumentValidation(string signalingRoot)
{
    var type = typeof(WebRtcSignalDocument);
    var read = type.GetMethod("Read", BindingFlags.Public | BindingFlags.Static)
        ?? throw new InvalidOperationException("Missing WebRtcSignalDocument.Read.");

    var validPath = Path.Combine(signalingRoot, "valid-session-offer.json");
    File.WriteAllText(
        validPath,
        """
        {
          "type": "offer",
          "sdp": "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\na=candidate:1 1 UDP 2122260223 192.168.0.101 5443 typ host\r\n",
          "candidates": []
        }
        """);
    var valid = InvokeSignalRead(read, validPath, "offer");
    AssertEqual("AA:BB:CC", InvokeSignalString(valid, "Fingerprint"), "session signaling fingerprint");
    AssertEqual("192.168.0.101:5443", InvokeSignalString(valid, "FirstEndpoint"), "session signaling endpoint");
    AssertEqual("host-192.168.0.101:5443", InvokeSignalString(valid, "FirstCandidateLabel"), "session signaling candidate label");

    var writtenPath = Path.Combine(signalingRoot, "written-session-answer.json");
    WebRtcSignalDocument.Write(
        writtenPath,
        "answer",
        "v=0\r\na=fingerprint:sha-256 DD:EE:FF\r\n",
        new[]
        {
            new WebRtcSignalDocument.SignalCandidate
            {
                Candidate = "2 1 UDP 2122260223 192.168.0.102 5444 typ srflx generation 0",
                SdpMid = "0",
                SdpMLineIndex = 0,
                UsernameFragment = "remote-ufrag"
            }
        });
    var writtenJson = File.ReadAllText(writtenPath);
    AssertEqual(false, writtenJson.Contains("SourcePath", StringComparison.OrdinalIgnoreCase), "written signaling source path redaction");
    AssertEqual(true, writtenJson.Contains("\"sdpMid\"", StringComparison.Ordinal), "written signaling sdpMid");
    AssertEqual(true, writtenJson.Contains("\"sdpMLineIndex\"", StringComparison.Ordinal), "written signaling sdpMLineIndex");
    var written = WebRtcSignalDocument.Read(writtenPath, "answer");
    AssertEqual("DD:EE:FF", written.Fingerprint(), "written signaling fingerprint");
    AssertEqual("192.168.0.102:5444", written.FirstEndpoint(), "written signaling endpoint");
    AssertEqual("srflx-192.168.0.102:5444", written.FirstCandidateLabel(), "written signaling candidate label");
    AssertEqual("0", written.Candidates[0].SdpMid, "written signaling candidate sdpMid");
    AssertEqual((ushort)0, written.Candidates[0].SdpMLineIndex, "written signaling candidate sdpMLineIndex");
    AssertEqual("remote-ufrag", written.Candidates[0].UsernameFragment, "written signaling candidate username fragment");

    ExpectThrows<InvalidDataException>(
        () => WebRtcSignalDocument.Write(
            Path.Combine(signalingRoot, "invalid-type.json"),
            "join",
            "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\n",
            Array.Empty<WebRtcSignalDocument.SignalCandidate>()),
        "type must be offer or answer");
    ExpectThrows<InvalidDataException>(
        () => WebRtcSignalDocument.Write(
            Path.Combine(signalingRoot, "empty-sdp.json"),
            "offer",
            " ",
            Array.Empty<WebRtcSignalDocument.SignalCandidate>()),
        "must include SDP");
    ExpectThrows<InvalidDataException>(
        () => WebRtcSignalDocument.Write(
            Path.Combine(signalingRoot, "empty-candidate.json"),
            "answer",
            "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\n",
            new[] { new WebRtcSignalDocument.SignalCandidate { Candidate = " " } }),
        "ICE candidate must not be empty");
    ExpectThrows<InvalidDataException>(
        () => WebRtcSignalDocument.Write(
            Path.Combine(signalingRoot, "malformed-candidate.json"),
            "answer",
            "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\n",
            new[] { new WebRtcSignalDocument.SignalCandidate { Candidate = "candidate:malformed" } }),
        "ICE candidate is not parseable");
    ExpectThrows<InvalidDataException>(
        () => WebRtcSignalDocument.Write(
            Path.Combine(signalingRoot, "candidate-control-char.json"),
            "answer",
            "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\n",
            new[]
            {
                new WebRtcSignalDocument.SignalCandidate
                {
                    Candidate = "candidate:2 1 UDP 2122260223 192.168.0.102 5444 typ host\r\n"
                }
            }),
        "ICE candidate must not contain control characters");
    ExpectThrows<InvalidDataException>(
        () => WebRtcSignalDocument.Write(
            Path.Combine(signalingRoot, "empty-sdp-mid.json"),
            "answer",
            "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\n",
            new[]
            {
                new WebRtcSignalDocument.SignalCandidate
                {
                    Candidate = "candidate:2 1 UDP 2122260223 192.168.0.102 5444 typ host",
                    SdpMid = ""
                }
            }),
        "sdpMid must not be empty");
    ExpectThrows<InvalidDataException>(
        () => WebRtcSignalDocument.Write(
            Path.Combine(signalingRoot, "long-ufrag.json"),
            "answer",
            "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\n",
            new[]
            {
                new WebRtcSignalDocument.SignalCandidate
                {
                    Candidate = "candidate:2 1 UDP 2122260223 192.168.0.102 5444 typ host",
                    UsernameFragment = new string('u', 257)
                }
            }),
        "usernameFragment exceeds 256 characters");
    ExpectThrows<InvalidDataException>(
        () => WebRtcSignalDocument.Write(
            Path.Combine(signalingRoot, "too-many-candidates.json"),
            "answer",
            "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\n",
            Enumerable.Range(0, 257).Select(index => new WebRtcSignalDocument.SignalCandidate
            {
                Candidate = $"candidate:{index} 1 UDP 2122260223 192.168.0.102 {5000 + index} typ host"
            })),
        "more than 256 ICE candidates");

    var malformedCandidateReadPath = Path.Combine(signalingRoot, "malformed-read-candidate.json");
    File.WriteAllText(
        malformedCandidateReadPath,
        """
        {
          "type": "answer",
          "sdp": "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\n",
          "candidates": [
            { "candidate": "candidate:malformed", "sdpMid": "0", "sdpMLineIndex": 0 }
          ]
        }
        """);
    ExpectThrows<InvalidDataException>(
        () => InvokeSignalRead(read, malformedCandidateReadPath, "answer"),
        "ICE candidate is not parseable");

    var missingFingerprintPath = Path.Combine(signalingRoot, "missing-session-fingerprint.json");
    File.WriteAllText(
        missingFingerprintPath,
        """
        {
          "type": "offer",
          "sdp": "v=0\r\na=candidate:1 1 UDP 2122260223 192.168.0.101 5443 typ host\r\n",
          "candidates": []
        }
        """);
    var missingFingerprint = InvokeSignalRead(read, missingFingerprintPath, "offer");
    ExpectThrows<InvalidOperationException>(
        () => InvokeSignalString(missingFingerprint, "Fingerprint"),
        "does not contain a DTLS fingerprint");

    var missingCandidatePath = Path.Combine(signalingRoot, "missing-session-candidate.json");
    File.WriteAllText(
        missingCandidatePath,
        """
        {
          "type": "answer",
          "sdp": "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\n",
          "candidates": []
        }
        """);
    var missingCandidate = InvokeSignalRead(read, missingCandidatePath, "answer");
    ExpectThrows<InvalidOperationException>(
        () => InvokeSignalString(missingCandidate, "FirstEndpoint"),
        "does not contain a parseable ICE candidate");

    var typeMismatchPath = Path.Combine(signalingRoot, "wrong-session-type.json");
    File.WriteAllText(
        typeMismatchPath,
        """
        {
          "type": "answer",
          "sdp": "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\na=candidate:1 1 UDP 2122260223 192.168.0.101 5443 typ host\r\n",
          "candidates": []
        }
        """);
    ExpectThrows<InvalidOperationException>(
        () => InvokeSignalRead(read, typeMismatchPath, "offer"),
        "WebRTC signaling file type mismatch");

    var oversizedPath = Path.Combine(signalingRoot, "oversized-session-offer.json");
    File.WriteAllText(
        oversizedPath,
        $$"""
        {
          "type": "offer",
          "sdp": "{{new string('x', 1_048_576)}}",
          "candidates": []
        }
        """);
	    ExpectThrows<InvalidDataException>(
	        () => InvokeSignalRead(read, oversizedPath, "offer"),
	        "WebRTC signaling file exceeds the maximum size");
}

async Task VerifyCurrentPathSignalingContractsAsync()
{
    var publicKey = SequenceBytes(32, 11);
    var expectedFingerprint = ManualAuthoritativeFingerprint("Ed25519", publicKey);
    AssertEqual(
        expectedFingerprint,
        CurrentPathProtocolIdentityBinding.ComputeFingerprint(CurrentPathProtocolSigningAlgorithm.Ed25519, publicKey),
        "current-path authoritative identity fingerprint");
    var binding = new CurrentPathProtocolIdentityBinding(
        "windows-device-01",
        CurrentPathProtocolSigningAlgorithm.Ed25519,
        publicKey);
    AssertEqual(expectedFingerprint, binding.ProtocolPublicKeyFingerprint, "current-path binding computed fingerprint");
    AssertEqual("Ed25519", binding.ProtocolSigningAlgorithmWireName, "current-path signing algorithm wire name");
    ExpectThrows<InvalidDataException>(
        () => CurrentPathProtocolSigningAlgorithms.ParseWireName("P-256-ECDSA"),
        "Unsupported current-path protocol signing algorithm");
    ExpectThrows<InvalidDataException>(
        () => new CurrentPathProtocolIdentityBinding(
            "windows-device-02",
            CurrentPathProtocolSigningAlgorithm.Ed25519,
            publicKey,
            expectedFingerprint.ToUpperInvariant()),
        "64 lowercase hex");
    ExpectThrows<InvalidDataException>(
        () => new CurrentPathProtocolIdentityBinding(
            "short",
            CurrentPathProtocolSigningAlgorithm.Ed25519,
            publicKey),
        "deviceId length");
    ExpectThrows<InvalidDataException>(
        () => new CurrentPathProtocolIdentityBinding(
            "windows-device-03",
            CurrentPathProtocolSigningAlgorithm.Ed25519,
            publicKey[..31]),
        "Ed25519 current-path public key");

    AssertEqual(
        "https://api.nebula-technologies.net",
        CurrentPathOriginPolicy.CanonicalOrigin("https://api.nebula-technologies.net/"),
        "current-path canonical https origin");
    AssertEqual(
        "http://127.0.0.1:8443",
        CurrentPathOriginPolicy.CanonicalOrigin("http://127.0.0.1:8443"),
        "current-path canonical loopback http origin");
    ExpectThrows<InvalidDataException>(
        () => CurrentPathOriginPolicy.CanonicalOrigin("http://api.nebula-technologies.net"),
        "must be https");
    ExpectThrows<InvalidDataException>(
        () => CurrentPathOriginPolicy.CanonicalOrigin("https://api.nebula-technologies.net/ws"),
        "must not include a path");

    var wsUri = CurrentPathSignalingWebSocketPolicy.BuildHeaderCredentialWebSocketUri(
        "https://api.nebula-technologies.net",
        "/ws/current",
        "abc123",
        "session-token",
        "1.2.3",
        "1");
    AssertEqual(
        "wss://api.nebula-technologies.net/ws/current?shard=ABC123&cv=1.2.3&pv=1",
        wsUri.ToString(),
        "current-path websocket URI");
    AssertEqual(false, wsUri.Query.Contains("st=", StringComparison.Ordinal), "current-path websocket URI must not carry query-token auth");
    var headers = CurrentPathSignalingWebSocketPolicy.BuildHeaderCredentials("abc123", "session-token", "1.2.3", "1");
    AssertEqual("ABC123", headers[CurrentPathSignalingWebSocketPolicy.SessionIdHeader], "current-path websocket session id header");
    AssertEqual("session-token", headers[CurrentPathSignalingWebSocketPolicy.SessionTokenHeader], "current-path websocket session token header");
    ExpectThrows<InvalidDataException>(
        () => CurrentPathSignalingWebSocketPolicy.ValidateWebSocketPath("/ws/../current"),
        "unsafe segment");
    ExpectThrows<InvalidDataException>(
        () => CurrentPathSignalingWebSocketPolicy.ValidateWebSocketPath("/ws/current?st=token"),
        "websocket path is invalid");
    ExpectThrows<InvalidDataException>(
        () => CurrentPathSignalingWebSocketPolicy.BuildHeaderCredentials("abc123", "bad,token", "1.2.3", "1"),
        "invalid credential character");
    foreach (var unsafeEncodedPath in new[]
    {
        "/ws/%2e%2e/current",
        "/ws/%2e/current",
        "/ws/%2fcurrent",
        "/ws/%5ccurrent",
        "/ws/%3fcurrent",
        "/ws/%23current",
    })
    {
        ExpectThrows<InvalidDataException>(
            () => CurrentPathSignalingWebSocketPolicy.ValidateWebSocketPath(unsafeEncodedPath),
            "websocket path");
    }

    var joinEnvelope = new CurrentPathWebRtcSignalingEnvelope(
        "session-1",
        "windows-device-01",
        to: null,
        CurrentPathWebRtcSignalingMessageType.Join,
        new CurrentPathWebRtcSignalingPayload(
            protocolSigningAlgorithm: CurrentPathProtocolSigningAlgorithms.Ed25519WireName,
            protocolPublicKeyFingerprint: expectedFingerprint,
            protocolPublicKeyBytes: publicKey,
            kemPublicKeys: new[]
            {
                new CurrentPathBootstrapKemPublicKey(0x1001, new byte[] { 9, 8, 7 }),
            },
            platform: "Windows",
            osVersion: "Windows 11"),
        sentAt: 1_700_000_000d);
    var joinJson = CurrentPathSignalingFrameCodec.EncodeEnvelope(joinEnvelope);
    AssertContains(joinJson, "\"type\":\"join\"", "current-path join JSON message type");
    AssertContains(joinJson, $"\"protocolPublicKeyBytes\":\"{Convert.ToBase64String(publicKey)}\"", "current-path join JSON public key base64");
    AssertContains(joinJson, "\"publicKey\":\"CQgH\"", "current-path join JSON KEM key base64");
    var parsedJoin = CurrentPathSignalingFrameCodec.ParseInboundText(joinJson);
    AssertEqual(CurrentPathSignalingInboundMessageKind.Envelope, parsedJoin.Kind, "current-path parsed join kind");
    AssertEqual(CurrentPathWebRtcSignalingMessageType.Join, parsedJoin.Envelope!.Type, "current-path parsed join type");
    AssertEqual(expectedFingerprint, parsedJoin.Envelope.Payload!.ProtocolPublicKeyFingerprint, "current-path parsed join fingerprint");

    var offerEnvelope = new CurrentPathWebRtcSignalingEnvelope(
        "session-1",
        "windows-device-01",
        "mac-device-00001",
        CurrentPathWebRtcSignalingMessageType.Offer,
        new CurrentPathWebRtcSignalingPayload(sdp: "v=0\r\n"),
        sentAt: 1_700_000_001d);
    var answerEnvelope = new CurrentPathWebRtcSignalingEnvelope(
        "session-1",
        "windows-device-01",
        "mac-device-00001",
        CurrentPathWebRtcSignalingMessageType.Answer,
        new CurrentPathWebRtcSignalingPayload(sdp: "v=0\r\n"),
        sentAt: 1_700_000_002d);
    var iceEnvelope = new CurrentPathWebRtcSignalingEnvelope(
        "session-1",
        "windows-device-01",
        "mac-device-00001",
        CurrentPathWebRtcSignalingMessageType.IceCandidate,
        new CurrentPathWebRtcSignalingPayload(
            candidate: "candidate:1 1 udp 2122260223 192.168.0.105 54321 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0),
        sentAt: 1_700_000_003d);
    var leaveEnvelope = new CurrentPathWebRtcSignalingEnvelope(
        "session-1",
        "windows-device-01",
        "mac-device-00001",
        CurrentPathWebRtcSignalingMessageType.Leave,
        sentAt: 1_700_000_004d);
    ExpectThrows<InvalidDataException>(
        () => new CurrentPathWebRtcSignalingEnvelope(
            "session-1",
            "windows-device-01",
            "mac-device-00001",
            CurrentPathWebRtcSignalingMessageType.Leave,
            authToken: "secret-auth-token",
            sentAt: 1_700_000_004d),
        "must not carry authToken");
    AssertEqual(false, CurrentPathSignalingFrameCodec.EncodeEnvelope(leaveEnvelope).Contains("authToken", StringComparison.Ordinal), "current-path envelope JSON must not carry authToken");
    AssertEqual(false, leaveEnvelope.ToString().Contains("session-1", StringComparison.OrdinalIgnoreCase), "current-path envelope ToString must redact session id");
    AssertEqual(CurrentPathWebRtcSignalingMessageType.Offer, CurrentPathSignalingFrameCodec.DecodeEnvelope(CurrentPathSignalingFrameCodec.EncodeEnvelope(offerEnvelope)).Type, "current-path offer round trip");
    AssertEqual(CurrentPathWebRtcSignalingMessageType.Answer, CurrentPathSignalingFrameCodec.DecodeEnvelope(CurrentPathSignalingFrameCodec.EncodeEnvelope(answerEnvelope)).Type, "current-path answer round trip");
    AssertEqual(CurrentPathWebRtcSignalingMessageType.IceCandidate, CurrentPathSignalingFrameCodec.DecodeEnvelope(CurrentPathSignalingFrameCodec.EncodeEnvelope(iceEnvelope)).Type, "current-path ICE round trip");
    AssertEqual(CurrentPathWebRtcSignalingMessageType.Leave, CurrentPathSignalingFrameCodec.DecodeEnvelope(CurrentPathSignalingFrameCodec.EncodeEnvelope(leaveEnvelope)).Type, "current-path leave round trip");
    ExpectThrows<InvalidDataException>(
        () => new CurrentPathWebRtcSignalingEnvelope(
            "session-1",
            "windows-device-01",
            null,
            CurrentPathWebRtcSignalingMessageType.Offer,
            sentAt: 1_700_000_005d),
        "require non-empty SDP");
    ExpectThrows<InvalidDataException>(
        () => new CurrentPathWebRtcSignalingEnvelope(
            "session-1",
            "windows-device-01",
            null,
            CurrentPathWebRtcSignalingMessageType.IceCandidate,
            new CurrentPathWebRtcSignalingPayload(candidate: ""),
            sentAt: 1_700_000_006d),
        "non-empty candidate");
    ExpectThrows<InvalidDataException>(
        () => new CurrentPathWebRtcSignalingPayload(sdpMLineIndex: -1),
        "must not be negative");
    ExpectThrows<InvalidDataException>(
        () => new CurrentPathWebRtcSignalingPayload(protocolSigningAlgorithm: "P-256"),
        "Unsupported current-path protocol signing algorithm");
    ExpectThrows<InvalidDataException>(
        () => new CurrentPathWebRtcSignalingPayload(protocolPublicKeyFingerprint: expectedFingerprint.ToUpperInvariant()),
        "64 lowercase hex");
    ExpectThrows<JsonException>(
        () => CurrentPathSignalingFrameCodec.ParseInboundText(
            "{\"sessionId\":\"SESSION-1\",\"from\":\"windows-device-01\",\"type\":\"join\",\"sentAt\":1700000000,\"extra\":true}"),
        "could not be mapped");
    ExpectThrows<JsonException>(
        () => CurrentPathSignalingFrameCodec.ParseInboundText(
            "{\"sessionId\":\"SESSION-1\",\"from\":\"windows-device-01\",\"type\":\"join\",\"payload\":{\"protocolPublicKeyBytes\":\"not-base64\"},\"sentAt\":1700000000}"),
        "could not be converted");
    var unknownFrame = CurrentPathSignalingFrameCodec.ParseInboundText("{\"type\":\"unexpected\",\"sessionId\":\"SESSION-1\"}");
    AssertEqual(CurrentPathSignalingInboundMessageKind.Unknown, unknownFrame.Kind, "current-path unknown server frame must not be accepted as known frame");
    AssertEqual(
        CurrentPathSignalingFailureClass.TokenExpired,
        CurrentPathWebSocketSignalingClient.ClassifyServerOrCloseReason("session_token_expired"),
        "current-path token expiration failure class");
    AssertEqual(
        CurrentPathSignalingFailureClass.AuthBindRejected,
        CurrentPathWebSocketSignalingClient.ClassifyServerOrCloseReason("bind_rejected"),
        "current-path auth bind failure class");
    AssertEqual(
        CurrentPathSignalingFailureClass.InvalidShardOrSessionMismatch,
        CurrentPathWebSocketSignalingClient.ClassifyServerOrCloseReason("scope_violation"),
        "current-path scope failure class");

    var fakeTransport = new FakeCurrentPathWebSocketTransport();
    fakeTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        "{\"type\":\"bound\",\"sessionId\":\"SESSION-1\",\"role\":\"initiator\",\"clientId\":\"client-1\"}"));
    await using (var wsClient = new CurrentPathWebSocketSignalingClient(
        fakeTransport,
        new CurrentPathWebSocketSignalingClientOptions(
            "https://api.nebula-technologies.net",
            "/ws/current",
            "session-1",
            "session-token",
            "windows-device-01",
            "1.2.3",
            "1",
            TimeSpan.FromSeconds(5))))
    {
        var lifecycle = new List<CurrentPathSignalingLifecycleEvent>();
        wsClient.LifecycleChanged += lifecycle.Add;
        await ExpectThrowsAsync<CurrentPathWebSocketSignalingException>(
            () => wsClient.SendAsync(joinEnvelope),
            "must be bound");
        await wsClient.ConnectAndBindAsync();
        AssertEqual(true, wsClient.IsBound, "current-path fake websocket bound");
        AssertEqual("initiator", wsClient.BoundRole, "current-path fake websocket bound role");
        AssertEqual(CurrentPathSignalingLifecyclePhase.SocketOpen, lifecycle[1].Phase, "current-path fake websocket socket-open phase");
        AssertEqual(CurrentPathSignalingLifecyclePhase.Bound, lifecycle[^1].Phase, "current-path fake websocket bound phase");
        AssertEqual("bound", lifecycle[^1].ServerFrameType, "current-path fake websocket bound frame type");
        await wsClient.SendAsync(joinEnvelope);
        AssertEqual(1, fakeTransport.SentTexts.Count, "current-path fake websocket send count");
        AssertContains(fakeTransport.SentTexts.Single(), "\"type\":\"join\"", "current-path fake websocket sent join envelope");
    }

    var rejectedTransport = new FakeCurrentPathWebSocketTransport();
    rejectedTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        "{\"type\":\"error\",\"error\":\"session_token_expired\",\"sessionId\":\"SESSION-1\",\"reason\":\"secret-session-token\"}"));
    await using (var rejectedWsClient = new CurrentPathWebSocketSignalingClient(
        rejectedTransport,
        new CurrentPathWebSocketSignalingClientOptions(
            "https://api.nebula-technologies.net",
            "/ws/current",
            "session-1",
            "session-token",
            "windows-device-01")))
    {
        try
        {
            await rejectedWsClient.ConnectAndBindAsync();
            throw new InvalidOperationException("Expected current-path websocket bind rejection.");
        }
        catch (CurrentPathWebSocketSignalingException ex)
        {
            AssertEqual("server_rejected", ex.ErrorCode, "current-path websocket bind rejection code");
            AssertEqual(CurrentPathSignalingFailureClass.TokenExpired, ex.FailureClass, "current-path websocket bind rejection class");
            AssertEqual(false, ex.Message.Contains("secret-session-token", StringComparison.Ordinal), "current-path websocket rejection must redact server reason");
        }
    }

    var mismatchTransport = new FakeCurrentPathWebSocketTransport();
    mismatchTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        "{\"type\":\"bound\",\"sessionId\":\"OTHER-SESSION\",\"role\":\"initiator\"}"));
    await using (var mismatchWsClient = new CurrentPathWebSocketSignalingClient(
        mismatchTransport,
        new CurrentPathWebSocketSignalingClientOptions(
            "https://api.nebula-technologies.net",
            "/ws/current",
            "session-1",
            "session-token",
            "windows-device-01")))
    {
        await ExpectThrowsAsync<CurrentPathWebSocketSignalingException>(
            () => mismatchWsClient.ConnectAndBindAsync(),
            "does not match");
    }

    var challenge = new CurrentPathAdmissionChallenge(
        "challenge-1",
        "nonce-1",
        "tenant-1",
        "user-1",
        binding.DeviceId,
        "ip-hash",
        "1.2.3",
        "1",
        "issued",
        DateTimeOffset.FromUnixTimeMilliseconds(1_700_000_000_000),
        DateTimeOffset.FromUnixTimeMilliseconds(1_700_000_060_000));
    AssertEqual(
        "SkyBridge-Admission-Challenge\nchallenge-1\nnonce-1\ntenant-1\nuser-1\nwindows-device-01\n1.2.3\n1",
        Encoding.UTF8.GetString(challenge.BuildSignaturePayload()),
        "current-path admission signature payload");
    using (var generatedAdmissionSigner = MLDsa.GenerateKey(MLDsaAlgorithm.MLDsa65))
    {
        var mldsaPrivateKey = generatedAdmissionSigner.ExportMLDsaPrivateKey();
        using var currentPathSigner = CurrentPathMldsa65AdmissionSigner.ImportPrivateKey(mldsaPrivateKey);
        var mldsaBinding = currentPathSigner.CreateBinding("windows-device-02");
        AssertEqual(
            CurrentPathProtocolSigningAlgorithm.MLDsa65,
            mldsaBinding.ProtocolSigningAlgorithm,
            "current-path ML-DSA admission binding algorithm");
        AssertEqual("ML-DSA-65", mldsaBinding.ProtocolSigningAlgorithmWireName, "current-path ML-DSA admission wire algorithm");
        var mldsaChallenge = challenge with { DeviceId = mldsaBinding.DeviceId };
        var mldsaSignature = currentPathSigner.SignAdmissionChallenge(mldsaChallenge, mldsaBinding);
        using var currentPathVerifier = MLDsa.ImportMLDsaPublicKey(
            MLDsaAlgorithm.MLDsa65,
            mldsaBinding.ProtocolPublicKeyBytes.Span);
        AssertEqual(
            true,
            currentPathVerifier.VerifyData(mldsaChallenge.BuildSignaturePayload(), mldsaSignature, Array.Empty<byte>()),
            "current-path ML-DSA admission signature verifies");
        ExpectThrows<InvalidDataException>(
            () => currentPathSigner.SignAdmissionChallenge(challenge, mldsaBinding),
            "deviceId does not match");
    }

    var handler = new RecordingHttpMessageHandler();
    handler.Enqueue((request, body) =>
    {
        AssertEqual(HttpMethod.Post, request.Method, "admission challenge method");
        AssertEqual("/api/webrtc/admission/challenge", request.RequestUri?.AbsolutePath, "admission challenge path");
        AssertEqual("Bearer", request.Headers.Authorization?.Scheme, "admission challenge auth scheme");
        AssertEqual("access-token", request.Headers.Authorization?.Parameter, "admission challenge bearer token");
        AssertEqual("tenant-1", request.Headers.GetValues("X-SkyBridge-Tenant-Id").Single(), "admission challenge tenant header");
        AssertEqual("skybridge-client-v1", request.Headers.GetValues("X-API-Key").Single(), "admission challenge api key header");
        AssertContains(body, "\"deviceId\":\"windows-device-01\"", "admission challenge body device id");
        AssertContains(body, "\"protocolSigningAlgorithm\":\"Ed25519\"", "admission challenge body algorithm");
        AssertContains(body, expectedFingerprint, "admission challenge body fingerprint");
        return JsonResponse(
            """
            {
              "challengeId": "challenge-1",
              "nonce": "nonce-1",
              "tenantId": "tenant-1",
              "userId": "user-1",
              "deviceId": "windows-device-01",
              "clientIpHash": "ip-hash",
              "clientVersion": "1.2.3",
              "protocolVersion": "1",
              "state": "issued",
              "issuedAt": 1700000000000,
              "expiresAt": 1700000060000
            }
            """);
    });
    handler.Enqueue((request, body) =>
    {
        AssertEqual(HttpMethod.Post, request.Method, "complete admission method");
        AssertEqual("/api/webrtc/admission", request.RequestUri?.AbsolutePath, "complete admission path");
        AssertContains(body, "\"signature\":\"AQID\"", "complete admission signature base64");
        AssertContains(body, "\"protocolPublicKeyBytes\":\"", "complete admission public key base64");
        return JsonResponse(
            """
            {
              "admissionToken": "admission-token",
              "state": "active",
              "issuedAt": 1700000000000,
              "expiresAt": 1700000060000
            }
            """);
    });
    handler.Enqueue((request, body) =>
    {
        AssertEqual(HttpMethod.Post, request.Method, "register code method");
        AssertEqual("/api/webrtc/register-code", request.RequestUri?.AbsolutePath, "register code path");
        AssertEqual("admission-token", request.Headers.GetValues("X-SkyBridge-Admission").Single(), "register code admission header");
        AssertContains(body, "\"ttlSeconds\":60", "register code minimum ttl");
        return JsonResponse(
            """
            {
              "code": "ABC234",
              "sessionId": "session-1",
              "sessionToken": "session-token",
              "turnAdmissionToken": "turn-token",
              "mediaAdmissionToken": "media-token",
              "expiresIn": 60,
              "signalingServerOrigin": "https://api.nebula-technologies.net",
              "wsPath": "/ws/current"
            }
            """);
    });
    handler.Enqueue((request, body) =>
    {
        AssertEqual(HttpMethod.Get, request.Method, "lookup code method");
        AssertEqual("/api/webrtc/lookup/ABC234", request.RequestUri?.AbsolutePath, "lookup code path");
        AssertEqual("", body, "lookup code empty body");
        return JsonResponse(
            $$"""
            {
              "found": true,
              "sessionId": "session-1",
              "sessionToken": "session-token",
              "turnAdmissionToken": "turn-token",
              "mediaAdmissionToken": null,
              "expiresIn": 60,
              "signalingServerOrigin": "https://api.nebula-technologies.net",
              "wsPath": "/ws/current",
              "initiatorDeviceId": "windows-device-01",
              "initiatorProtocolSigningAlgorithm": "Ed25519",
              "initiatorProtocolPublicKeyFingerprint": "{{expectedFingerprint}}",
              "initiatorDeviceName": "Windows"
            }
            """);
    });
    using var httpClient = new HttpClient(handler);
    var signalClient = new CurrentPathSignalServerClient(
        httpClient,
        new CurrentPathSignalServerClientOptions(
            clientVersion: "1.2.3",
            bearerTokenProvider: _ => Task.FromResult("access-token"),
            tenantIdProvider: _ => Task.FromResult("tenant-1")));
    var receivedChallenge = await signalClient.RequestAdmissionChallengeAsync(binding);
    AssertEqual("challenge-1", receivedChallenge.ChallengeId, "received admission challenge");
    var admission = await signalClient.CompleteAdmissionAsync(receivedChallenge, binding, new byte[] { 1, 2, 3 });
    AssertEqual("admission-token", admission.Token, "received admission token");
    AssertEqual(false, admission.ToString().Contains("admission-token", StringComparison.Ordinal), "admission lease ToString must redact token");
    AssertContains(admission.ToString(), "<redacted>", "admission lease ToString redaction marker");
    var lease = await signalClient.RegisterConnectionCodeAsync(admission.Token, "Windows", TimeSpan.FromSeconds(10));
    AssertEqual("ABC234", lease.Code, "registered connection code");
    AssertEqual("/ws/current", lease.WsPath, "registered connection code ws path");
    AssertEqual(false, lease.ToString().Contains("ABC234", StringComparison.Ordinal), "connection code lease ToString must redact connection code");
    AssertEqual(false, lease.ToString().Contains("session-1", StringComparison.Ordinal), "connection code lease ToString must redact session id");
    AssertEqual(false, lease.ToString().Contains("session-token", StringComparison.Ordinal), "connection code lease ToString must redact session token");
    AssertEqual(false, lease.ToString().Contains("turn-token", StringComparison.Ordinal), "connection code lease ToString must redact turn token");
    AssertEqual(false, lease.ToString().Contains("media-token", StringComparison.Ordinal), "connection code lease ToString must redact media token");
    AssertEqual("/api/webrtc/lookup/ABC234XY", CurrentPathSignalServerClient.LookupCodePath("abc-234xy"), "preferred-length lookup code path");
    var lookup = await signalClient.LookupConnectionCodeAsync(admission.Token, "abc234");
    AssertEqual(CurrentPathProtocolSigningAlgorithm.Ed25519, lookup.InitiatorProtocolSigningAlgorithm, "lookup protocol algorithm");
    AssertEqual(expectedFingerprint, lookup.InitiatorProtocolPublicKeyFingerprint, "lookup initiator fingerprint");
    AssertEqual(false, lookup.ToString().Contains("session-1", StringComparison.Ordinal), "connection code lookup ToString must redact session id");
    AssertEqual(false, lookup.ToString().Contains("session-token", StringComparison.Ordinal), "connection code lookup ToString must redact session token");
    AssertEqual(false, lookup.ToString().Contains("turn-token", StringComparison.Ordinal), "connection code lookup ToString must redact turn token");
    handler.AssertDrained();

    var rejectedHandler = new RecordingHttpMessageHandler();
    rejectedHandler.Enqueue((_, _) => new HttpResponseMessage(HttpStatusCode.Forbidden)
    {
        Content = new StringContent(
            "{\"error\":\"auth_rejected\",\"reason\":\"secret-reason-token\",\"rejectReason\":\"secret-reject-token\",\"token\":\"secret-token-value\"}",
            Encoding.UTF8,
            "application/json")
    });
    using var rejectedClient = new HttpClient(rejectedHandler);
    var rejectedSignalClient = new CurrentPathSignalServerClient(
        rejectedClient,
        new CurrentPathSignalServerClientOptions(
            bearerTokenProvider: _ => Task.FromResult("access-token"),
            tenantIdProvider: _ => Task.FromResult("tenant-1")));
    try
    {
        await rejectedSignalClient.RegisterConnectionCodeAsync("admission-token", "Windows", TimeSpan.FromSeconds(60));
        throw new InvalidOperationException("Expected current-path server rejection.");
    }
    catch (CurrentPathSignalServerException ex)
    {
        AssertEqual(HttpStatusCode.Forbidden, ex.StatusCode, "current-path rejection status");
        AssertContains(ex.SanitizedBody, "auth_rejected", "current-path rejection sanitized safe code");
        AssertEqual(false, ex.SanitizedBody.Contains("secret-token-value", StringComparison.Ordinal), "current-path rejection must redact unknown token values");
        AssertEqual(false, ex.SanitizedBody.Contains("secret-reason-token", StringComparison.Ordinal), "current-path rejection must redact free-form reason values");
        AssertEqual(false, ex.SanitizedBody.Contains("secret-reject-token", StringComparison.Ordinal), "current-path rejection must redact free-form reject reason values");
        AssertContains(ex.SanitizedBody, "\"reason\"", "current-path rejection reason redaction key");
        AssertContains(ex.SanitizedBody, "redacted", "current-path rejection reason redaction marker");
    }

    var unknownRejectedBody = CurrentPathSignalServerException.SanitizeServerRejectedBody(
        Encoding.UTF8.GetBytes("{\"error\":\"secret-dynamic-error-token\"}"));
    AssertEqual(false, unknownRejectedBody.Contains("secret-dynamic-error-token", StringComparison.Ordinal), "unknown current-path rejection error code must be redacted");

    await ExpectThrowsAsync<InvalidDataException>(
        () => new CurrentPathSignalServerClient(
                new HttpClient(new RecordingHttpMessageHandler()),
                new CurrentPathSignalServerClientOptions(apiKey: "bad,api-key"))
            .RequestAdmissionChallengeAsync(binding),
        "invalid header character");

    var missingAuthClient = new CurrentPathSignalServerClient(
        new HttpClient(new RecordingHttpMessageHandler()),
        new CurrentPathSignalServerClientOptions(tenantIdProvider: _ => Task.FromResult("tenant-1")));
    await ExpectThrowsAsync<CurrentPathSignalServerException>(
        () => missingAuthClient.RequestAdmissionChallengeAsync(binding),
        "missing_bearer_token");

    var oversizedHandler = new RecordingHttpMessageHandler();
    oversizedHandler.Enqueue((_, _) => new HttpResponseMessage(HttpStatusCode.OK)
    {
        Content = new StringContent(new string('x', 128 * 1024 + 1), Encoding.UTF8, "application/json")
    });
    using var oversizedHttpClient = new HttpClient(oversizedHandler);
    var oversizedSignalClient = new CurrentPathSignalServerClient(
        oversizedHttpClient,
        new CurrentPathSignalServerClientOptions(
            bearerTokenProvider: _ => Task.FromResult("access-token"),
            tenantIdProvider: _ => Task.FromResult("tenant-1")));
    await ExpectThrowsAsync<InvalidDataException>(
        () => oversizedSignalClient.RequestAdmissionChallengeAsync(binding),
        "response body is too large");
}

async Task VerifyCurrentPathWebRtcHelperSignalingBridgeAsync(string signalingRoot)
{
    var localOfferPath = Path.Combine(signalingRoot, "bridge-local-offer.json");
    var remoteAnswerPath = Path.Combine(signalingRoot, "bridge-remote-answer.json");
    WebRtcSignalDocument.Write(
        localOfferPath,
        "offer",
        "v=0\r\na=fingerprint:sha-256 11:22:33\r\n",
        new[]
        {
            new WebRtcSignalDocument.SignalCandidate
            {
                Candidate = "1111 1 udp 2113937663 192.168.0.105 56176 typ host generation 0",
                SdpMid = "0",
                SdpMLineIndex = 0,
                UsernameFragment = "WIN1"
            }
        });

    var bridgeTransport = new FakeCurrentPathWebSocketTransport();
    bridgeTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        "{\"type\":\"bound\",\"sessionId\":\"BRIDGE-SESSION-1\",\"role\":\"initiator\",\"clientId\":\"client-bridge\"}"));
    bridgeTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
            "bridge-session-1",
            "mac-device-00001",
            "windows-device-01",
            CurrentPathWebRtcSignalingMessageType.IceCandidate,
            new CurrentPathWebRtcSignalingPayload(
                candidate: "2222 1 udp 2113937663 192.168.0.101 51490 typ host generation 0",
                sdpMid: "0",
                sdpMLineIndex: 0),
            sentAt: 1_700_100_001d))));
    bridgeTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
            "bridge-session-1",
            "mac-device-00001",
            "windows-device-01",
            CurrentPathWebRtcSignalingMessageType.Answer,
            new CurrentPathWebRtcSignalingPayload(sdp: "v=0\r\na=fingerprint:sha-256 44:55:66\r\n"),
            sentAt: 1_700_100_002d))));

    await using (var wsClient = new CurrentPathWebSocketSignalingClient(
        bridgeTransport,
        new CurrentPathWebSocketSignalingClientOptions(
            "https://api.nebula-technologies.net",
            "/ws/current",
            "bridge-session-1",
            "session-token",
            "windows-device-01",
            connectTimeout: TimeSpan.FromSeconds(5))))
    {
        await wsClient.ConnectAndBindAsync();
        var bridge = new CurrentPathWebRtcHelperSignalingBridge();
        var result = await bridge.ExchangeOffererAsync(
            wsClient,
            new CurrentPathWebRtcHelperSignalingBridgeOptions(
                "bridge-session-1",
                "windows-device-01",
                "mac-device-00001",
                localOfferPath,
                remoteAnswerPath,
                signalFileTimeout: TimeSpan.FromSeconds(1),
                remoteAnswerTimeout: TimeSpan.FromSeconds(5)));

        AssertEqual(1, result.LocalCandidateCount, "current-path helper bridge local candidate count");
        AssertEqual(1, result.RemoteCandidateCount, "current-path helper bridge remote candidate count");
        AssertEqual("mac-device-00001", result.RemoteDeviceId, "current-path helper bridge remote device");
        AssertEqual(3, bridgeTransport.SentTexts.Count, "current-path helper bridge outbound frame count");
        AssertContains(bridgeTransport.SentTexts[0], "\"type\":\"join\"", "current-path helper bridge sends join");
        AssertContains(bridgeTransport.SentTexts[1], "\"type\":\"offer\"", "current-path helper bridge sends offer");
        AssertContains(bridgeTransport.SentTexts[2], "\"type\":\"iceCandidate\"", "current-path helper bridge sends ICE");
        AssertEqual(false, string.Join('\n', bridgeTransport.SentTexts).Contains("authToken", StringComparison.Ordinal), "current-path helper bridge must not send authToken");

        var writtenAnswer = WebRtcSignalDocument.Read(remoteAnswerPath, "answer");
        AssertEqual("44:55:66", writtenAnswer.Fingerprint(), "current-path helper bridge answer fingerprint");
        AssertEqual("192.168.0.101:51490", writtenAnswer.FirstEndpoint(), "current-path helper bridge answer endpoint");
        AssertEqual("host-192.168.0.101:51490", writtenAnswer.FirstCandidateLabel(), "current-path helper bridge answer candidate label");
    }

    var wrongPeerAnswerPath = Path.Combine(signalingRoot, "bridge-wrong-peer-answer.json");
    var wrongPeerTransport = new FakeCurrentPathWebSocketTransport();
    wrongPeerTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        "{\"type\":\"bound\",\"sessionId\":\"BRIDGE-SESSION-2\",\"role\":\"initiator\"}"));
    wrongPeerTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
            "bridge-session-2",
            "mac-device-99999",
            "windows-device-01",
            CurrentPathWebRtcSignalingMessageType.Answer,
            new CurrentPathWebRtcSignalingPayload(sdp: "v=0\r\na=fingerprint:sha-256 77:88:99\r\n"),
            sentAt: 1_700_100_003d))));

    await using (var wrongPeerClient = new CurrentPathWebSocketSignalingClient(
        wrongPeerTransport,
        new CurrentPathWebSocketSignalingClientOptions(
            "https://api.nebula-technologies.net",
            "/ws/current",
            "bridge-session-2",
            "session-token",
            "windows-device-01",
            connectTimeout: TimeSpan.FromSeconds(5))))
    {
        await wrongPeerClient.ConnectAndBindAsync();
        var bridge = new CurrentPathWebRtcHelperSignalingBridge();
        await ExpectThrowsAsync<InvalidDataException>(
            () => bridge.ExchangeOffererAsync(
                wrongPeerClient,
                new CurrentPathWebRtcHelperSignalingBridgeOptions(
                    "bridge-session-2",
                    "windows-device-01",
                    "mac-device-00001",
                    localOfferPath,
                    wrongPeerAnswerPath,
                    signalFileTimeout: TimeSpan.FromSeconds(1),
                    remoteAnswerTimeout: TimeSpan.FromSeconds(5))),
            "unexpected peer");
        AssertEqual(false, File.Exists(wrongPeerAnswerPath), "current-path helper bridge must not write wrong-peer answer");
    }

    var noCandidateAnswerPath = Path.Combine(signalingRoot, "bridge-no-candidate-answer.json");
    var noCandidateTransport = new FakeCurrentPathWebSocketTransport();
    noCandidateTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        "{\"type\":\"bound\",\"sessionId\":\"BRIDGE-SESSION-3\",\"role\":\"initiator\"}"));
    noCandidateTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
            "bridge-session-3",
            "mac-device-00001",
            "windows-device-01",
            CurrentPathWebRtcSignalingMessageType.Answer,
            new CurrentPathWebRtcSignalingPayload(sdp: "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\n"),
            sentAt: 1_700_100_004d))));

    await using (var noCandidateClient = new CurrentPathWebSocketSignalingClient(
        noCandidateTransport,
        new CurrentPathWebSocketSignalingClientOptions(
            "https://api.nebula-technologies.net",
            "/ws/current",
            "bridge-session-3",
            "session-token",
            "windows-device-01",
            connectTimeout: TimeSpan.FromSeconds(5))))
    {
        await noCandidateClient.ConnectAndBindAsync();
        var bridge = new CurrentPathWebRtcHelperSignalingBridge();
        await ExpectThrowsAsync<InvalidDataException>(
            () => bridge.ExchangeOffererAsync(
                noCandidateClient,
                new CurrentPathWebRtcHelperSignalingBridgeOptions(
                    "bridge-session-3",
                    "windows-device-01",
                    "mac-device-00001",
                    localOfferPath,
                    noCandidateAnswerPath,
                    signalFileTimeout: TimeSpan.FromSeconds(1),
                    remoteAnswerTimeout: TimeSpan.FromSeconds(5))),
            "without parseable ICE candidate material");
        AssertEqual(false, File.Exists(noCandidateAnswerPath), "current-path helper bridge must not write no-candidate answer");
    }

    var wrongToAnswerPath = Path.Combine(signalingRoot, "bridge-wrong-to-answer.json");
    var wrongToTransport = new FakeCurrentPathWebSocketTransport();
    wrongToTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        "{\"type\":\"bound\",\"sessionId\":\"BRIDGE-SESSION-4\",\"role\":\"initiator\"}"));
    wrongToTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
            "bridge-session-4",
            "mac-device-00001",
            "windows-device-02",
            CurrentPathWebRtcSignalingMessageType.Answer,
            new CurrentPathWebRtcSignalingPayload(
                sdp: "v=0\r\na=fingerprint:sha-256 DD:EE:FF\r\na=candidate:3333 1 udp 2113937663 192.168.0.101 51491 typ host\r\n"),
            sentAt: 1_700_100_005d))));

    await using (var wrongToClient = new CurrentPathWebSocketSignalingClient(
        wrongToTransport,
        new CurrentPathWebSocketSignalingClientOptions(
            "https://api.nebula-technologies.net",
            "/ws/current",
            "bridge-session-4",
            "session-token",
            "windows-device-01",
            connectTimeout: TimeSpan.FromSeconds(5))))
    {
        await wrongToClient.ConnectAndBindAsync();
        var bridge = new CurrentPathWebRtcHelperSignalingBridge();
        await ExpectThrowsAsync<InvalidDataException>(
            () => bridge.ExchangeOffererAsync(
                wrongToClient,
                new CurrentPathWebRtcHelperSignalingBridgeOptions(
                    "bridge-session-4",
                    "windows-device-01",
                    "mac-device-00001",
                    localOfferPath,
                    wrongToAnswerPath,
                    signalFileTimeout: TimeSpan.FromSeconds(1),
                    remoteAnswerTimeout: TimeSpan.FromSeconds(5))),
            "addressed to another device");
        AssertEqual(false, File.Exists(wrongToAnswerPath), "current-path helper bridge must not write wrong-to answer");
    }

    var missingFingerprintAnswerPath = Path.Combine(signalingRoot, "bridge-missing-fingerprint-answer.json");
    var missingFingerprintTransport = new FakeCurrentPathWebSocketTransport();
    missingFingerprintTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        "{\"type\":\"bound\",\"sessionId\":\"BRIDGE-SESSION-5\",\"role\":\"initiator\"}"));
    missingFingerprintTransport.EnqueueReceive(CurrentPathWebSocketReceiveResult.TextMessage(
        CurrentPathSignalingFrameCodec.EncodeEnvelope(new CurrentPathWebRtcSignalingEnvelope(
            "bridge-session-5",
            "mac-device-00001",
            "windows-device-01",
            CurrentPathWebRtcSignalingMessageType.Answer,
            new CurrentPathWebRtcSignalingPayload(
                sdp: "v=0\r\na=candidate:4444 1 udp 2113937663 192.168.0.101 51492 typ host\r\n"),
            sentAt: 1_700_100_006d))));

    await using (var missingFingerprintClient = new CurrentPathWebSocketSignalingClient(
        missingFingerprintTransport,
        new CurrentPathWebSocketSignalingClientOptions(
            "https://api.nebula-technologies.net",
            "/ws/current",
            "bridge-session-5",
            "session-token",
            "windows-device-01",
            connectTimeout: TimeSpan.FromSeconds(5))))
    {
        await missingFingerprintClient.ConnectAndBindAsync();
        var bridge = new CurrentPathWebRtcHelperSignalingBridge();
        await ExpectThrowsAsync<InvalidOperationException>(
            () => bridge.ExchangeOffererAsync(
                missingFingerprintClient,
                new CurrentPathWebRtcHelperSignalingBridgeOptions(
                    "bridge-session-5",
                    "windows-device-01",
                    "mac-device-00001",
                    localOfferPath,
                    missingFingerprintAnswerPath,
                    signalFileTimeout: TimeSpan.FromSeconds(1),
                    remoteAnswerTimeout: TimeSpan.FromSeconds(5))),
            "does not contain a DTLS fingerprint");
        AssertEqual(false, File.Exists(missingFingerprintAnswerPath), "current-path helper bridge must not write missing-fingerprint answer");
    }
}

async Task VerifySkyBridgeDataPlaneValidationAsync()
{
    var client = new SkyBridgeDataPlaneClient(1);
    var dispatch = typeof(SkyBridgeDataPlaneClient).GetMethod("DispatchInbound", BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("Missing SkyBridgeDataPlaneClient.DispatchInbound.");

    await ExpectThrowsAsync<InvalidDataException>(
        () => client.SendAsync((DataPlaneChannel)9, Array.Empty<byte>()),
        "outbound channel");

    await ExpectThrowsAsync<InvalidDataException>(
        () => client.SendAsync(DataPlaneChannel.Control, new byte[64 * 1024 * 1024 + 1]),
        "outbound payload exceeded");

    var invalidVersion = EncodeSbf1Frame((byte)DataPlaneChannel.Control, 1, flags: 0x0002, payload: new byte[] { 0x41 });
    invalidVersion[4] = 2;
    ExpectThrows<InvalidDataException>(
        () => InvokeDispatch(dispatch, client, invalidVersion),
        "unsupported SBF1 version");

    var invalidChannel = EncodeSbf1Frame(9, 1, flags: 0x0002, payload: new byte[] { 0x41 });
    ExpectThrows<InvalidDataException>(
        () => InvokeDispatch(dispatch, client, invalidChannel),
        "unknown channel code");

    var invalidFlags = EncodeSbf1Frame((byte)DataPlaneChannel.Control, 1, flags: 0x8000, payload: new byte[] { 0x41 });
    ExpectThrows<InvalidDataException>(
        () => InvokeDispatch(dispatch, client, invalidFlags),
        "unknown SBF1 flags");

    var lengthMismatch = EncodeSbf1Frame((byte)DataPlaneChannel.Control, 1, flags: 0x0002, payload: new byte[] { 0x41 });
    BinaryPrimitives.WriteUInt32BigEndian(lengthMismatch.AsSpan(16, 4), 2);
    ExpectThrows<InvalidDataException>(
        () => InvokeDispatch(dispatch, client, lengthMismatch),
        "does not match message payload bytes");

    var fragment = EncodeSbf1Frame((byte)DataPlaneChannel.Clipboard, 1, flags: 0, payload: new byte[] { 0x41 });
    for (var i = 0; i < 1024; i++)
    {
        InvokeDispatch(dispatch, client, fragment);
    }

    ExpectThrows<InvalidDataException>(
        () => InvokeDispatch(dispatch, client, fragment),
        "exceeded 1024 fragments without END_OF_MESSAGE");
}

async Task VerifyWebRtcProductControlContractsAsync()
{
    _ = new WebRtcProductControlTransportOptions(asAnswerer: false, preferredIpcPort: 0, timestampWindowMs: 1);
    ExpectThrows<InvalidOperationException>(
        () => new WebRtcProductControlTransportOptions(asAnswerer: false, preferredIpcPort: -1, timestampWindowMs: 1),
        "preferred IPC port");
    ExpectThrows<InvalidOperationException>(
        () => new WebRtcProductControlTransportOptions(asAnswerer: false, preferredIpcPort: 0, timestampWindowMs: 0),
        "non-zero timestamp window");

    var boundaryMessage = new byte[WebRtcProductControlPlaneClient.MaxControlFrameChunkBytes];
    for (var index = 0; index < boundaryMessage.Length; index++)
    {
        boundaryMessage[index] = (byte)(index % 251);
    }

    using var stream = new MemoryStream();
    await WebRtcProductControlPlaneClient.WriteMessageAsync(stream, boundaryMessage, CancellationToken.None);
    AssertEqual(WebRtcProductControlPlaneClient.LengthPrefixBytes + boundaryMessage.Length, (int)stream.Length, "product-control IPC encoded length");
    stream.Position = 0;
    var decoded = await WebRtcProductControlPlaneClient.ReadMessageAsync(stream, CancellationToken.None)
        ?? throw new InvalidOperationException("product-control IPC decoder returned null for a complete message.");
    AssertBytesEqual(boundaryMessage, decoded, "product-control IPC boundary message round trip");

    await ExpectThrowsAsync<InvalidDataException>(
        () => WebRtcProductControlPlaneClient.WriteMessageAsync(new MemoryStream(), Array.Empty<byte>(), CancellationToken.None),
        "must not be empty");

    await ExpectThrowsAsync<InvalidDataException>(
        () => WebRtcProductControlPlaneClient.WriteMessageAsync(new MemoryStream(), new byte[WebRtcProductControlPlaneClient.MaxControlFrameChunkBytes + 1], CancellationToken.None),
        "exceeds 8192 bytes");

    var oversizedPrefix = new MemoryStream(new byte[] { 0x00, 0x00, 0x20, 0x01 });
    await ExpectThrowsAsync<InvalidDataException>(
        async () => _ = await WebRtcProductControlPlaneClient.ReadMessageAsync(oversizedPrefix, CancellationToken.None),
        "outside 1..8192");

    var midMessageEof = new MemoryStream(new byte[] { 0x00, 0x00, 0x00, 0x02, 0x41 });
    await ExpectThrowsAsync<EndOfStreamException>(
        async () => _ = await WebRtcProductControlPlaneClient.ReadMessageAsync(midMessageEof, CancellationToken.None),
        "closed mid-message");

    var cleanEof = new MemoryStream(Array.Empty<byte>());
    var eofResult = await WebRtcProductControlPlaneClient.ReadMessageAsync(cleanEof, CancellationToken.None);
    AssertEqual<byte[]?>(null, eofResult, "product-control IPC clean EOF");

    var ipcAuthToken = SequenceBytes(WebRtcProductControlPlaneClient.IpcAuthTokenBytes, 0x21);
    var ipcAuthNonce = SequenceBytes(WebRtcProductControlPlaneClient.IpcAuthNonceBytes, 0x41);
    var authRequest = WebRtcProductControlPlaneClient.BuildIpcAuthRequest(ipcAuthToken, ipcAuthNonce);
    var parsedAuthNonce = new byte[WebRtcProductControlPlaneClient.IpcAuthNonceBytes];
    WebRtcProductControlPlaneClient.ValidateIpcAuthRequest(ipcAuthToken, authRequest, parsedAuthNonce);
    AssertBytesEqual(ipcAuthNonce, parsedAuthNonce, "product-control IPC auth request nonce binding");
    var authResponse = WebRtcProductControlPlaneClient.BuildIpcAuthResponse(ipcAuthToken, parsedAuthNonce);
    WebRtcProductControlPlaneClient.ValidateIpcAuthResponse(ipcAuthToken, ipcAuthNonce, authResponse);
    var tamperedAuthRequest = authRequest.ToArray();
    tamperedAuthRequest[^1] ^= 0x01;
    ExpectThrows<InvalidDataException>(
        () => WebRtcProductControlPlaneClient.ValidateIpcAuthRequest(ipcAuthToken, tamperedAuthRequest, parsedAuthNonce),
        "MAC verification failed");
    var tamperedAuthResponse = authResponse.ToArray();
    tamperedAuthResponse[^2] ^= 0x01;
    ExpectThrows<InvalidDataException>(
        () => WebRtcProductControlPlaneClient.ValidateIpcAuthResponse(ipcAuthToken, ipcAuthNonce, tamperedAuthResponse),
        "MAC verification failed");
    ExpectThrows<InvalidDataException>(
        () => new WebRtcProductControlPlaneClient(49152, ipcAuthToken: SequenceBytes(WebRtcProductControlPlaneClient.IpcAuthTokenBytes - 1, 0x61)),
        "authentication token must be 32 bytes");

    var plane = new TestWebRtcProductControlPlane();
    var smokeEvidencePath = Path.Combine(AppContext.BaseDirectory, "product-control-smoke-evidence.json");
    var context = new LiveWebRtcProductControlContext(
        plane,
        "mac-device-1",
        new string('a', 64),
        "offer",
        WebRtcProductControlTransportProvider.TransportProfile,
        WebRtcProductControlTransportProvider.DataChannelLabel,
        "mac-product-control-v1/offer/datachannel=skybridge/ipc=127.0.0.1:49152",
        "192.168.0.105:5443",
        "192.168.0.101:5443",
        "webrtc/dtls/sctp/host-192.168.0.105:5443-host-192.168.0.101:5443/skybridge",
        new string('b', 64),
        15_000,
        WebRtcProductControlSecureSessionState.TransportOnly);
    var smoke = new WebRtcProductControlSmokeClient(
        new WebRtcProductControlSmokeOptions(TimeSpan.FromSeconds(5), smokeEvidencePath));
    await smoke.StartAsync(context);
    var smokeEvidence = File.ReadAllText(smokeEvidencePath);
    AssertContains(smokeEvidence, "\"FactoryMode\": \"webrtc-product-control\"", "product-control smoke evidence factory");
    AssertContains(smokeEvidence, "\"SecureSessionState\": \"TransportOnly\"", "product-control smoke evidence secure state");
    AssertContains(smokeEvidence, "not Mac product app handshake", "product-control smoke evidence scope");

    var unavailableKeys = new UnavailableWebRtcAppSessionKeyProvider();
    ExpectThrows<WebRtcAppSessionKeysUnavailableException>(
        () => unavailableKeys.RequireEstablishedKeys(context),
        "secure session keys are not established");
}

void VerifyWebRtcProductHandshakeCodec()
{
    var capabilities = new WebRtcProductCryptoCapabilities(
        new[] { "X25519" },
        new[] { "Ed25519" },
        new[] { "classic" },
        new[] { "AES-GCM-256" },
        pqcAvailable: false,
        platformVersion: "Windows 11",
        providerType: "CryptoKit-Classic");
    var identityPublicKey = SequenceBytes(65, 0x11);
    identityPublicKey[0] = 0x04;
    var signature = SequenceBytes(64, 0x22);
    var keyShare = new WebRtcProductHandshakeKeyShare(
        WebRtcProductHandshakeCodec.SuiteX25519Ed25519,
        SequenceBytes(32, 0x33));
    var messageA = new WebRtcProductHandshakeMessageA(
        supportedSuiteWireIds: new[] { WebRtcProductHandshakeCodec.SuiteX25519Ed25519 },
        keyShares: new[] { keyShare },
        clientNonce: SequenceBytes(32, 0x44),
        capabilities: capabilities,
        policy: WebRtcProductHandshakePolicy.Default,
        identityPublicKey: identityPublicKey,
        extensionsRaw: Array.Empty<byte>(),
        signature: signature);
    var messageAWire = messageA.Encode();
    var decodedA = WebRtcProductHandshakeCodec.DecodeMessageA(messageAWire);
    AssertEqual(WebRtcProductHandshakeCodec.ProtocolVersion, decodedA.Version, "MessageA version");
    AssertEqual(1, decodedA.SupportedSuiteWireIds.Count, "MessageA supported suite count");
    AssertEqual(WebRtcProductHandshakeCodec.SuiteX25519Ed25519, decodedA.SupportedSuiteWireIds[0], "MessageA supported suite");
    AssertEqual(1, decodedA.KeyShares.Count, "MessageA keyShare count");
    AssertBytesEqual(keyShare.ShareBytes.ToArray(), decodedA.KeyShares[0].ShareBytes.ToArray(), "MessageA keyShare round trip");
    AssertBytesEqual(messageA.SignaturePreimage(), decodedA.SignaturePreimage(), "MessageA signature preimage");

    var invalidCapabilitiesBool = new WebRtcProductCryptoCapabilities(
        Array.Empty<string>(),
        Array.Empty<string>(),
        Array.Empty<string>(),
        Array.Empty<string>(),
        pqcAvailable: false,
        platformVersion: "Windows 11",
        providerType: "CryptoKit-Classic").Encode();
    invalidCapabilitiesBool[16] = 0x02;
    ExpectThrows<WebRtcProductHandshakeCodecException>(
        () => WebRtcProductCryptoCapabilities.Decode(invalidCapabilitiesBool),
        "Deterministic bool must be encoded as 0 or 1");

    var paddedA = WebRtcProductHandshakeCodec.WrapHandshakePadding(messageAWire, messageAWire.Length + 24);
    AssertBytesEqual(messageA.SignaturePreimage(), WebRtcProductHandshakeCodec.DecodeMessageA(paddedA).SignaturePreimage(), "SBP1 MessageA unwrap");

    var trailingA = messageAWire.Concat(new byte[] { 0x00 }).ToArray();
    ExpectThrows<WebRtcProductHandshakeCodecException>(
        () => WebRtcProductHandshakeCodec.DecodeMessageA(trailingA),
        "MessageA trailing bytes");

    var invalidSbp1 = new byte[] { 0x53, 0x42, 0x50, 0x31, 0x00, 0x00, 0x00, 0x05, 0x01 };
    ExpectThrows<WebRtcProductHandshakeCodecException>(
        () => WebRtcProductHandshakeCodec.DecodeMessageA(invalidSbp1),
        "SBP1 actual length exceeds");

    var fsMessageA = new WebRtcProductHandshakeMessageA(
        supportedSuiteWireIds: new[] { WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure },
        keyShares: new[]
        {
            new WebRtcProductHandshakeKeyShare(
                WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure,
                SequenceBytes(1088, 0x55))
        },
        clientNonce: SequenceBytes(32, 0x66),
        capabilities: new WebRtcProductCryptoCapabilities(
            new[] { "ML-KEM-768-FS" },
            new[] { "ML-DSA-65" },
            new[] { "pqc" },
            new[] { "AES-GCM-256" },
            pqcAvailable: true,
            platformVersion: "macOS 26",
            providerType: "CryptoKit-PQC"),
        policy: new WebRtcProductHandshakePolicy(
            requirePqc: true,
            allowClassicFallback: false,
            minimumTier: "nativePQC",
            requireSecureEnclavePoP: false),
        identityPublicKey: SequenceBytes(2592, 0x77),
        extensionsRaw: Array.Empty<byte>(),
        signature: SequenceBytes(3309, 0x88),
        initiatorContribution: SequenceBytes(32, 0x99));
    var decodedFsMessageA = WebRtcProductHandshakeCodec.DecodeMessageA(fsMessageA.Encode());
    AssertEqual(32, decodedFsMessageA.InitiatorContribution.Length, "MessageA FS initiator contribution length");
    ExpectThrows<WebRtcProductHandshakeCodecException>(
        () => new WebRtcProductHandshakeMessageA(
            supportedSuiteWireIds: new[] { WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure },
            keyShares: new[]
            {
                new WebRtcProductHandshakeKeyShare(
                    WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure,
                    SequenceBytes(1088, 0x51))
            },
            clientNonce: SequenceBytes(32, 0x52),
            capabilities: capabilities,
            policy: WebRtcProductHandshakePolicy.Default,
            identityPublicKey: identityPublicKey,
            extensionsRaw: Array.Empty<byte>(),
            signature: signature,
            initiatorContribution: SequenceBytes(31, 0x53)),
        "v2 initiator contribution length mismatch");

    var hpke = new WebRtcProductHpkeSealedBox(
        WebRtcProductHandshakeCodec.SuiteX25519Ed25519,
        SequenceBytes(32, 0xA1),
        SequenceBytes(12, 0xA2),
        Encoding.UTF8.GetBytes("sealed-handshake-payload"),
        SequenceBytes(16, 0xA3));
    var messageB = new WebRtcProductHandshakeMessageB(
        selectedSuiteWireId: WebRtcProductHandshakeCodec.SuiteX25519Ed25519,
        responderShare: SequenceBytes(32, 0xB1),
        serverNonce: SequenceBytes(32, 0xB2),
        encryptedPayload: hpke,
        identityPublicKey: identityPublicKey,
        signature: signature);
    var messageBWire = messageB.Encode();
    var decodedB = WebRtcProductHandshakeCodec.DecodeMessageB(messageBWire);
    AssertEqual(WebRtcProductHandshakeCodec.SuiteX25519Ed25519, decodedB.SelectedSuiteWireId, "MessageB selected suite");
    AssertBytesEqual(messageB.EncodeWithoutSignature(), decodedB.EncodeWithoutSignature(), "MessageB transcript bytes");
    AssertEqual(
        true,
        messageB.SignaturePreimage(SHA256.HashData(messageA.EncodeWithoutSignature())).Length > WebRtcProductHandshakeCodec.TranscriptHashLength,
        "MessageB signature preimage includes transcript hash");

    ExpectThrows<WebRtcProductHandshakeCodecException>(
        () => new WebRtcProductHandshakeMessageB(
            selectedSuiteWireId: WebRtcProductHandshakeCodec.SuiteX25519Ed25519,
            responderShare: SequenceBytes(32, 0xC1),
            serverNonce: SequenceBytes(32, 0xC2),
            encryptedPayload: new WebRtcProductHpkeSealedBox(
                WebRtcProductHandshakeCodec.SuiteP256Ecdsa,
                SequenceBytes(65, 0xC3),
                SequenceBytes(12, 0xC4),
                Encoding.UTF8.GetBytes("wrong-suite"),
                SequenceBytes(16, 0xC5)),
            identityPublicKey: identityPublicKey,
            signature: signature),
        "HPKE payload suite does not match selected suite");
    ExpectThrows<WebRtcProductHandshakeCodecException>(
        () => new WebRtcProductHandshakeMessageB(
            selectedSuiteWireId: WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65,
            responderShare: SequenceBytes(1, 0xD1),
            serverNonce: SequenceBytes(32, 0xD2),
            encryptedPayload: new WebRtcProductHpkeSealedBox(
                WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65,
                SequenceBytes(1088, 0xD3),
                SequenceBytes(12, 0xD4),
                Encoding.UTF8.GetBytes("responder-share-mismatch"),
                SequenceBytes(16, 0xD5)),
            identityPublicKey: identityPublicKey,
            signature: signature),
        "responder share length mismatch");

    var finished = new WebRtcProductHandshakeFinished(
        WebRtcProductHandshakeFinishedDirection.InitiatorToResponder,
        SequenceBytes(32, 0xE1));
    var finishedWire = finished.Encode();
    var decodedFinished = WebRtcProductHandshakeCodec.DecodeFinished(finishedWire);
    AssertEqual(WebRtcProductHandshakeFinishedDirection.InitiatorToResponder, decodedFinished.Direction, "FIN1 direction");
    AssertBytesEqual(finished.Mac.ToArray(), decodedFinished.Mac.ToArray(), "FIN1 MAC");
    var paddedFinished = WebRtcProductHandshakeCodec.WrapHandshakePadding(finishedWire, finishedWire.Length + 8);
    AssertEqual(WebRtcProductHandshakeFinishedDirection.InitiatorToResponder, WebRtcProductHandshakeCodec.DecodeFinished(paddedFinished).Direction, "SBP1 FIN1 unwrap");
    var invalidFinished = finishedWire.ToArray();
    invalidFinished[5] = 0x7F;
	    ExpectThrows<WebRtcProductHandshakeCodecException>(
	        () => WebRtcProductHandshakeCodec.DecodeFinished(invalidFinished),
	        "Finished direction invalid");
	}

void VerifyWebRtcProductHandshakeIdentity()
{
    var ed25519PublicKey = SequenceBytes(32, 0x19);
    var identity = new WebRtcProductProtocolIdentityPublicKey(
        WebRtcProductSignatureAlgorithm.Ed25519,
        ed25519PublicKey);
    var decoded = WebRtcProductProtocolIdentityPublicKey.DecodeWithLegacyFallback(identity.Encode());
    AssertEqual(WebRtcProductSignatureAlgorithm.Ed25519, decoded.Algorithm, "Ed25519 identity algorithm");
    AssertBytesEqual(ed25519PublicKey, decoded.PublicKey.ToArray(), "Ed25519 identity public key");
    AssertEqual(
        ManualAuthoritativeFingerprint("Ed25519", ed25519PublicKey),
        decoded.AuthoritativeFingerprint,
        "Ed25519 authoritative fingerprint");

    var mlDsaPublicKey = SequenceBytes(1952, 0x29);
    var mlDsaIdentity = new WebRtcProductProtocolIdentityPublicKey(
        WebRtcProductSignatureAlgorithm.MlDsa65,
        mlDsaPublicKey);
    var decodedMlDsa = WebRtcProductProtocolIdentityPublicKey.DecodeWithLegacyFallback(mlDsaIdentity.Encode());
    AssertEqual(WebRtcProductSignatureAlgorithm.MlDsa65, decodedMlDsa.Algorithm, "ML-DSA identity algorithm");
    AssertEqual(
        ManualAuthoritativeFingerprint("ML-DSA-65", mlDsaPublicKey),
        decodedMlDsa.AuthoritativeFingerprint,
        "ML-DSA authoritative fingerprint");

    var legacyP256 = new byte[65];
    legacyP256[0] = 0x04;
    SequenceBytes(64, 0x39).CopyTo(legacyP256.AsSpan(1));
    var legacyIdentity = WebRtcProductProtocolIdentityPublicKey.DecodeWithLegacyFallback(legacyP256);
    AssertEqual(WebRtcProductSignatureAlgorithm.P256Ecdsa, legacyIdentity.Algorithm, "legacy P-256 identity algorithm");
    ExpectThrows<WebRtcProductHandshakeCodecException>(
        () => _ = legacyIdentity.AuthoritativeFingerprint,
        "legacy-only");

    ExpectThrows<WebRtcProductHandshakeCodecException>(
        () => WebRtcProductProtocolIdentityPublicKey.DecodeWithLegacyFallback(SequenceBytes(32, 0x49)),
        "not decodable");
}

async Task VerifyWebRtcProductPqcHandshakeCryptoProviderAsync()
{
    if (!MLKem.IsSupported || !MLDsa.IsSupported)
    {
        throw new PlatformNotSupportedException("Windows native runtime profile requires .NET ML-KEM and ML-DSA support for product PQC handshake validation.");
    }

    using var initiatorSigner = MLDsa.GenerateKey(MLDsaAlgorithm.MLDsa65);
    var initiatorPrivateKey = initiatorSigner.ExportMLDsaPrivateKey();
    try
    {
        using var responderPlane = new TestWebRtcProductPqcResponderPlane();
        var options = new WebRtcProductPqcHandshakeCryptoProviderOptions(
            initiatorPrivateKey,
            responderPlane.PeerKemPublicKey);
        using var provider = new WebRtcProductPqcHandshakeCryptoProvider(options);
        AssertBytesAllZero(options.LocalMlDsa65PrivateKey.ToArray(), "PQC provider options local ML-DSA private key cleared after import");
        var store = new WebRtcProductSecureSessionStore();
        var driver = new WebRtcProductHandshakeDriver(
            provider,
            store,
            new WebRtcProductHandshakeDriverOptions(TimeSpan.FromSeconds(3)));

        var established = await driver.StartInitiatorAsync(
            BuildProductHandshakeContext(responderPlane, peerFingerprint: responderPlane.ResponderIdentityFingerprint));
        AssertEqual(WebRtcProductControlSecureSessionState.Established, established.SecureSessionState, "PQC provider establishes context");
        AssertEqual(true, responderPlane.InitiatorFinishedVerified, "PQC responder verifies initiator Finished");
        var keys = store.RequireEstablishedKeys(
            established,
            WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65,
            WebRtcAppSecureRole.Initiator);
        AssertEqual(keys.SessionId, responderPlane.ResponderKeys?.SessionId, "PQC provider session id symmetry");
        AssertBytesEqual(keys.SendKey.ToArray(), responderPlane.ResponderKeys!.ReceiveKey.ToArray(), "PQC provider send key symmetry");
        AssertBytesEqual(keys.ReceiveKey.ToArray(), responderPlane.ResponderKeys.SendKey.ToArray(), "PQC provider receive key symmetry");

        ExpectThrows<InvalidOperationException>(
            () => new WebRtcProductPqcHandshakeCryptoProviderOptions(
                Array.Empty<byte>(),
                responderPlane.PeerKemPublicKey),
            "requires a local ML-DSA-65 private key");
        ExpectThrows<InvalidOperationException>(
            () => new WebRtcProductPqcHandshakeCryptoProviderOptions(
                initiatorPrivateKey,
                SequenceBytes(17, 0x59)),
            "peer ML-KEM-768 public key");
        ExpectThrows<InvalidOperationException>(
            () => new WebRtcProductPqcHandshakeCryptoProviderOptions(
                initiatorPrivateKey,
                responderPlane.PeerKemPublicKey,
                providerType: " "),
            "providerType must not be empty");

        using var tamperedResponderPlane = new TestWebRtcProductPqcResponderPlane(tamperResponderSignature: true);
        using var tamperedProvider = new WebRtcProductPqcHandshakeCryptoProvider(
            new WebRtcProductPqcHandshakeCryptoProviderOptions(
                initiatorPrivateKey,
                tamperedResponderPlane.PeerKemPublicKey));
        var tamperedDriver = new WebRtcProductHandshakeDriver(
            tamperedProvider,
            new WebRtcProductSecureSessionStore(),
            new WebRtcProductHandshakeDriverOptions(TimeSpan.FromSeconds(3)));
        await ExpectThrowsAsync<WebRtcProductHandshakeDriverException>(
            () => tamperedDriver.StartInitiatorAsync(
                BuildProductHandshakeContext(tamperedResponderPlane, peerFingerprint: tamperedResponderPlane.ResponderIdentityFingerprint)),
            "ML-DSA signature verification failed");
    }
    finally
    {
        CryptographicOperations.ZeroMemory(initiatorPrivateKey);
    }
}

void VerifyWebRtcProductHandshakeSessionKeys()
{
    var sharedSecret = SHA256.HashData(Encoding.UTF8.GetBytes("windows-mac-product-shared-secret"));
    var transcriptA = SHA256.HashData(Encoding.UTF8.GetBytes("MessageA transcript"));
    var transcriptB = SHA256.HashData(Encoding.UTF8.GetBytes("MessageB transcript"));
    var clientNonce = SequenceBytes(32, 0xA0);
    var serverNonce = SequenceBytes(32, 0xB0);

    var initiator = WebRtcProductHandshakeSessionKeys.Derive(
        sharedSecret,
        WebRtcProductHandshakeCodec.SuiteX25519Ed25519,
        transcriptA,
        transcriptB,
        clientNonce,
        serverNonce,
        WebRtcAppSecureRole.Initiator);
    var responder = WebRtcProductHandshakeSessionKeys.Derive(
        sharedSecret,
        WebRtcProductHandshakeCodec.SuiteX25519Ed25519,
        transcriptA,
        transcriptB,
        clientNonce,
        serverNonce,
        WebRtcAppSecureRole.Responder);

    AssertEqual("hs-e28b5125763fb222a4e26c7d7d337b9e", initiator.SessionId, "product handshake deterministic session id");
    AssertEqual(initiator.SessionId, responder.SessionId, "product handshake session id role symmetry");
    AssertBytesEqual(
        HexToBytes("8e4a9195b57a4be6310fe14e3c662579ecbb45bb51ac5d5cbbe3f40fff9d4a70"),
        initiator.SendKey.ToArray(),
        "product handshake I2R key vector");
    AssertBytesEqual(
        HexToBytes("739903512a85f0446a499f6181427eab439285a462e25db2621bed27311b74a9"),
        responder.SendKey.ToArray(),
        "product handshake R2I key vector");
    AssertBytesEqual(initiator.SendKey.ToArray(), responder.ReceiveKey.ToArray(), "product handshake I2R key symmetry");
    AssertBytesEqual(initiator.ReceiveKey.ToArray(), responder.SendKey.ToArray(), "product handshake R2I key symmetry");
    AssertBytesEqual(SHA256.HashData(transcriptA.Concat(transcriptB).ToArray()), initiator.TranscriptHash.ToArray(), "product handshake full transcript hash");

    var responderFinished = WebRtcProductHandshakeSessionKeys.CreateFinished(responder);
    AssertEqual(WebRtcProductHandshakeFinishedDirection.ResponderToInitiator, responderFinished.Direction, "product handshake responder Finished direction");
    AssertBytesEqual(
        HexToBytes("b77c37865c24853be1e7cc82a0d67753ab9396aee9754ee6cabb4d627bf5c3e9"),
        responderFinished.Mac.ToArray(),
        "product handshake responder Finished MAC vector");
    AssertEqual(true, WebRtcProductHandshakeSessionKeys.VerifyFinished(responderFinished, initiator, WebRtcAppSecureRole.Responder), "product handshake responder Finished verification");
    AssertEqual(false, WebRtcProductHandshakeSessionKeys.VerifyFinished(responderFinished, responder, WebRtcAppSecureRole.Responder), "product handshake Finished must use receive key");

    var initiatorFinished = WebRtcProductHandshakeSessionKeys.CreateFinished(initiator);
    AssertEqual(WebRtcProductHandshakeFinishedDirection.InitiatorToResponder, initiatorFinished.Direction, "product handshake initiator Finished direction");
    AssertBytesEqual(
        HexToBytes("b23bcad23331fb0f4d759d174c89190a6e819ce57e3d4e5283dc6277e153d21f"),
        initiatorFinished.Mac.ToArray(),
        "product handshake initiator Finished MAC vector");
    AssertEqual(true, WebRtcProductHandshakeSessionKeys.VerifyFinished(initiatorFinished, responder, WebRtcAppSecureRole.Initiator), "product handshake initiator Finished verification");
    var tamperedMac = initiatorFinished.Mac.ToArray();
    tamperedMac[0] ^= 0x01;
    AssertEqual(
        false,
        WebRtcProductHandshakeSessionKeys.VerifyFinished(
            new WebRtcProductHandshakeFinished(initiatorFinished.Direction, tamperedMac),
            responder,
            WebRtcAppSecureRole.Initiator),
        "product handshake tampered Finished rejection");

    var fsKeys = WebRtcProductHandshakeSessionKeys.Derive(
        sharedSecret,
        WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure,
        transcriptA,
        transcriptB,
        clientNonce,
        serverNonce,
        WebRtcAppSecureRole.Initiator);
    AssertEqual(false, initiator.SendKey.ToArray().SequenceEqual(fsKeys.SendKey.ToArray()), "product handshake suite composition label separation");

    ExpectThrows<InvalidDataException>(
        () => WebRtcProductHandshakeSessionKeys.Derive(
            sharedSecret.AsSpan(0, 31),
            WebRtcProductHandshakeCodec.SuiteX25519Ed25519,
            transcriptA,
            transcriptB,
            clientNonce,
            serverNonce,
            WebRtcAppSecureRole.Initiator),
        "shared secret must be exactly 32 bytes");
    ExpectThrows<WebRtcProductHandshakeCodecException>(
        () => WebRtcProductHandshakeSessionKeys.Derive(
            sharedSecret,
            0x9999,
            transcriptA,
            transcriptB,
            clientNonce,
            serverNonce,
            WebRtcAppSecureRole.Initiator),
        "Unsupported WebRTC product handshake suite");
}

async Task VerifyWebRtcProductSecureSessionStoreAsync()
{
    var context = new LiveWebRtcProductControlContext(
        new TestWebRtcProductControlPlane(),
        "mac-device-1",
        new string('a', 64),
        "offer",
        WebRtcProductControlTransportProvider.TransportProfile,
        WebRtcProductControlTransportProvider.DataChannelLabel,
        "mac-product-control-v1/offer/datachannel=skybridge/ipc=127.0.0.1:49152",
        "192.168.0.105:5443",
        "192.168.0.101:5443",
        "webrtc/dtls/sctp/host-192.168.0.105:5443-host-192.168.0.101:5443/skybridge",
        new string('b', 64),
        15_000,
        WebRtcProductControlSecureSessionState.TransportOnly);
    var keys = new WebRtcAppSecureSessionKeys(
        WebRtcAppSecureRole.Initiator,
        "hs-test-session",
        SHA256.HashData(Encoding.UTF8.GetBytes("secure store transcript")),
        SHA256.HashData(Encoding.UTF8.GetBytes("secure store send")),
        SHA256.HashData(Encoding.UTF8.GetBytes("secure store receive")));
    var store = new WebRtcProductSecureSessionStore();

    ExpectThrows<WebRtcAppSessionKeysUnavailableException>(
        () => store.RequireEstablishedKeys(context),
        "context is not Established");

	    var established = store.InstallEstablishedSession(
	        context,
	        keys,
	        WebRtcProductHandshakeCodec.SuiteX25519Ed25519);
	    AssertEqual(WebRtcProductControlSecureSessionState.Established, established.SecureSessionState, "secure session store state transition");
	    var installedKeys = store.RequireEstablishedKeys(established);
	    AssertEqual("hs-test-session", installedKeys.SessionId, "secure session store returns installed keys");
	    AssertEqual(false, installedKeys.SendKey.ToArray().All(current => current == 0), "secure session store installed send key is non-zero before clear");
	    AssertEqual("hs-test-session", store.RequireEstablishedKeys(established, WebRtcProductHandshakeCodec.SuiteX25519Ed25519, WebRtcAppSecureRole.Initiator).SessionId, "secure session store suite-role match");
    ExpectThrows<WebRtcAppSessionKeysUnavailableException>(
        () => store.RequireEstablishedKeys(established, WebRtcProductHandshakeCodec.SuiteP256Ecdsa, WebRtcAppSecureRole.Initiator),
        "suite does not match");
    ExpectThrows<WebRtcAppSessionKeysUnavailableException>(
        () => store.RequireEstablishedKeys(established, WebRtcProductHandshakeCodec.SuiteX25519Ed25519, WebRtcAppSecureRole.Responder),
        "role does not match");

    var smoke = new WebRtcProductControlSmokeClient(
        new WebRtcProductControlSmokeOptions(TimeSpan.FromSeconds(1)));
    await ExpectThrowsAsync<InvalidOperationException>(
        () => smoke.StartAsync(established),
        "raw smoke must only run before secure SBWC session establishment");

    var wrongPeer = established with { PeerDeviceId = "mac-device-2" };
    ExpectThrows<WebRtcAppSessionKeysUnavailableException>(
        () => store.RequireEstablishedKeys(wrongPeer),
        "do not match the requested peer or transport binding");

    var wrongBinding = established with { TransportBindingDigestHex = new string('c', 64) };
    ExpectThrows<WebRtcAppSessionKeysUnavailableException>(
        () => store.RequireEstablishedKeys(wrongBinding),
        "do not match the requested peer or transport binding");

	    store.Clear(established);
	    AssertEqual(false, installedKeys.TranscriptHash.ToArray().All(current => current == 0), "secure session store returns caller-owned transcript clone");
	    AssertEqual(false, installedKeys.SendKey.ToArray().All(current => current == 0), "secure session store returns caller-owned send key clone");
	    AssertEqual(false, installedKeys.ReceiveKey.ToArray().All(current => current == 0), "secure session store returns caller-owned receive key clone");
	    installedKeys.Dispose();
	    AssertEqual(true, installedKeys.TranscriptHash.ToArray().All(current => current == 0), "caller-owned secure session clone clears transcript hash on dispose");
	    AssertEqual(true, installedKeys.SendKey.ToArray().All(current => current == 0), "caller-owned secure session clone clears send key on dispose");
	    AssertEqual(true, installedKeys.ReceiveKey.ToArray().All(current => current == 0), "caller-owned secure session clone clears receive key on dispose");
	    AssertEqual(false, keys.SendKey.ToArray().All(current => current == 0), "secure session store keeps caller-owned key material outside its disposal scope");
	    ExpectThrows<WebRtcAppSessionKeysUnavailableException>(
	        () => store.RequireEstablishedKeys(established),
	        "secure session keys are not installed");

    ExpectThrows<InvalidOperationException>(
        () => store.InstallEstablishedSession(
            established,
            keys,
            WebRtcProductHandshakeCodec.SuiteX25519Ed25519),
        "requires a TransportOnly product-control context");

    var responderRoleKeys = new WebRtcAppSecureSessionKeys(
        WebRtcAppSecureRole.Responder,
        "hs-test-session-responder",
        SHA256.HashData(Encoding.UTF8.GetBytes("secure store responder transcript")),
        SHA256.HashData(Encoding.UTF8.GetBytes("secure store responder send")),
        SHA256.HashData(Encoding.UTF8.GetBytes("secure store responder receive")));
    ExpectThrows<InvalidOperationException>(
        () => store.InstallEstablishedSession(
            context,
            responderRoleKeys,
            WebRtcProductHandshakeCodec.SuiteX25519Ed25519),
        "role does not match");
}

async Task VerifyWebRtcProductHandshakeDriverAsync()
{
    var controlPlane = new TestWebRtcProductHandshakeResponderPlane();
    var context = BuildProductHandshakeContext(controlPlane, peerFingerprint: controlPlane.ResponderIdentityFingerprint);
    var cryptoProvider = new TestWebRtcProductHandshakeCryptoProvider(controlPlane.SharedSecret);
    var store = new WebRtcProductSecureSessionStore();
    var driver = new WebRtcProductHandshakeDriver(
        cryptoProvider,
        store,
        new WebRtcProductHandshakeDriverOptions(TimeSpan.FromSeconds(3)));

    var established = await driver.StartInitiatorAsync(context);
    AssertEqual(WebRtcProductControlSecureSessionState.Established, established.SecureSessionState, "product handshake driver establishes context");
    AssertEqual(1, cryptoProvider.OpenMessageBCount, "product handshake driver calls crypto provider for MessageB");
    AssertEqual(2, controlPlane.SentMessages.Count, "product handshake driver sends MessageA and initiator Finished");
    AssertEqual(true, controlPlane.InitiatorFinishedVerified, "product handshake responder verifies initiator Finished");
    var keys = store.RequireEstablishedKeys(established);
    AssertEqual(WebRtcAppSecureRole.Initiator, keys.Role, "product handshake driver installs initiator keys");
    AssertEqual(keys.SessionId, controlPlane.ResponderKeys?.SessionId, "product handshake driver session id symmetry");
    AssertBytesEqual(keys.SendKey.ToArray(), controlPlane.ResponderKeys!.ReceiveKey.ToArray(), "product handshake driver send key symmetry");
    AssertBytesEqual(keys.ReceiveKey.ToArray(), controlPlane.ResponderKeys.SendKey.ToArray(), "product handshake driver receive key symmetry");

    var unavailablePlane = new TestWebRtcProductHandshakeResponderPlane();
    var unavailableDriver = new WebRtcProductHandshakeDriver(
        new UnavailableWebRtcProductHandshakeCryptoProvider(),
        new WebRtcProductSecureSessionStore(),
        new WebRtcProductHandshakeDriverOptions(TimeSpan.FromSeconds(1)));
    await ExpectThrowsAsync<WebRtcProductHandshakeDriverException>(
        () => unavailableDriver.StartInitiatorAsync(BuildProductHandshakeContext(unavailablePlane, peerFingerprint: unavailablePlane.ResponderIdentityFingerprint)),
        "crypto provider is unavailable");
    AssertEqual(0, unavailablePlane.SentMessages.Count, "unavailable product handshake provider must not send MessageA");

    var tamperedPlane = new TestWebRtcProductHandshakeResponderPlane(tamperResponderFinished: true);
    var tamperedStore = new WebRtcProductSecureSessionStore();
    var tamperedDriver = new WebRtcProductHandshakeDriver(
        new TestWebRtcProductHandshakeCryptoProvider(tamperedPlane.SharedSecret),
        tamperedStore,
        new WebRtcProductHandshakeDriverOptions(TimeSpan.FromSeconds(3)));
    var tamperedContext = BuildProductHandshakeContext(tamperedPlane, peerFingerprint: tamperedPlane.ResponderIdentityFingerprint);
    await ExpectThrowsAsync<WebRtcProductHandshakeDriverException>(
        () => tamperedDriver.StartInitiatorAsync(tamperedContext),
        "Finished MAC verification failed");
    ExpectThrows<WebRtcAppSessionKeysUnavailableException>(
        () => tamperedStore.RequireEstablishedKeys(tamperedContext with { SecureSessionState = WebRtcProductControlSecureSessionState.Established }),
        "secure session keys are not installed");

    var earlySbwcPlane = new TestWebRtcProductHandshakeResponderPlane(sendSecureEnvelopeBeforeMessageB: true);
    var earlySbwcDriver = new WebRtcProductHandshakeDriver(
        new TestWebRtcProductHandshakeCryptoProvider(earlySbwcPlane.SharedSecret),
        new WebRtcProductSecureSessionStore(),
        new WebRtcProductHandshakeDriverOptions(TimeSpan.FromSeconds(3)));
    await ExpectThrowsAsync<WebRtcProductHandshakeDriverException>(
        () => earlySbwcDriver.StartInitiatorAsync(BuildProductHandshakeContext(earlySbwcPlane, peerFingerprint: earlySbwcPlane.ResponderIdentityFingerprint)),
        "SBWC envelope while waiting for MessageB");

    var identityMismatchPlane = new TestWebRtcProductHandshakeResponderPlane();
    var identityMismatchProvider = new TestWebRtcProductHandshakeCryptoProvider(identityMismatchPlane.SharedSecret);
    var identityMismatchDriver = new WebRtcProductHandshakeDriver(
        identityMismatchProvider,
        new WebRtcProductSecureSessionStore(),
        new WebRtcProductHandshakeDriverOptions(TimeSpan.FromSeconds(3)));
    await ExpectThrowsAsync<WebRtcProductHandshakeDriverException>(
        () => identityMismatchDriver.StartInitiatorAsync(BuildProductHandshakeContext(identityMismatchPlane)),
        "identity public key fingerprint does not match");
    AssertEqual(0, identityMismatchProvider.OpenMessageBCount, "product handshake identity mismatch must fail before MessageB open");

    var overflowPlane = new TestWebRtcProductHandshakeResponderPlane(extraMessagesBeforeMessageB: 2);
    var overflowDriver = new WebRtcProductHandshakeDriver(
        new TestWebRtcProductHandshakeCryptoProvider(overflowPlane.SharedSecret),
        new WebRtcProductSecureSessionStore(),
        new WebRtcProductHandshakeDriverOptions(TimeSpan.FromSeconds(3), maxQueuedInboundMessages: 1));
    await ExpectThrowsAsync<WebRtcProductHandshakeDriverException>(
        () => overflowDriver.StartInitiatorAsync(BuildProductHandshakeContext(overflowPlane, peerFingerprint: overflowPlane.ResponderIdentityFingerprint)),
        "inbound queue exceeded");

    var nonTransportContext = context with { SecureSessionState = WebRtcProductControlSecureSessionState.Established };
    await ExpectThrowsAsync<WebRtcProductHandshakeDriverException>(
        () => driver.StartInitiatorAsync(nonTransportContext),
        "must start from a TransportOnly");
}

async Task VerifyWebRtcAppControlBootstrapClientAsync()
{
    var controlPlane = new TestWebRtcProductHandshakeResponderPlane(wrapAppControlResponseWithTrafficPadding: true);
    var context = BuildProductHandshakeContext(controlPlane, peerFingerprint: controlPlane.ResponderIdentityFingerprint);
    var store = new WebRtcProductSecureSessionStore();
    var driver = new WebRtcProductHandshakeDriver(
        new TestWebRtcProductHandshakeCryptoProvider(controlPlane.SharedSecret),
        store,
        new WebRtcProductHandshakeDriverOptions(TimeSpan.FromSeconds(3)));
    var established = await driver.StartInitiatorAsync(context);
    var keys = store.RequireEstablishedKeys(established);

    var bootstrap = new WebRtcAppControlBootstrapClient(
        store,
        new WebRtcAppControlBootstrapOptions(TimeSpan.FromSeconds(3), maxQueuedInboundMessages: 2));
    var result = await bootstrap.ExchangePingAsync(
        established,
        WebRtcProductHandshakeCodec.SuiteX25519Ed25519);

    AssertEqual("pong", result.ReceivedMessageKind, "AppControl bootstrap receives pong");
    AssertEqual(keys.SessionId, result.SessionId, "AppControl bootstrap session id");
    AssertEqual((ulong)1, result.OutboundCounter, "AppControl bootstrap outbound counter");
    AssertEqual((ulong)1, result.InboundCounter, "AppControl bootstrap inbound counter");
    AssertEqual(WebRtcAppSecureEnvelope.SessionIdHash(keys.SessionId), result.SessionHash, "AppControl bootstrap session hash");
    AssertEqual(WebRtcAppSecureEnvelope.TranscriptPrefix(keys.TranscriptHash.Span), result.TranscriptPrefix, "AppControl bootstrap transcript prefix");
    AssertEqual(true, controlPlane.AppControlPingOpened, "AppControl bootstrap responder opens ping");
    AssertEqual(true, controlPlane.AppControlPongSent, "AppControl bootstrap responder sends pong");
    AssertEqual(result.PingId, controlPlane.ReceivedAppControlPingId!.Value, "AppControl bootstrap ping id round trip");

    await ExpectThrowsAsync<WebRtcAppSessionKeysUnavailableException>(
        () => new WebRtcAppControlBootstrapClient(new WebRtcProductSecureSessionStore())
            .ExchangePingAsync(established, WebRtcProductHandshakeCodec.SuiteX25519Ed25519),
        "secure session keys are not installed");
    await ExpectThrowsAsync<WebRtcAppSessionKeysUnavailableException>(
        () => bootstrap.ExchangePingAsync(context, WebRtcProductHandshakeCodec.SuiteX25519Ed25519),
        "context is not Established");
    await ExpectThrowsAsync<WebRtcAppSessionKeysUnavailableException>(
        () => bootstrap.ExchangePingAsync(established with { Role = "answer" }, WebRtcProductHandshakeCodec.SuiteX25519Ed25519),
        "role does not match");

    var tamperedPlane = new TestWebRtcProductHandshakeResponderPlane(tamperAppControlPongId: true);
    var tamperedStore = new WebRtcProductSecureSessionStore();
    var tamperedDriver = new WebRtcProductHandshakeDriver(
        new TestWebRtcProductHandshakeCryptoProvider(tamperedPlane.SharedSecret),
        tamperedStore,
        new WebRtcProductHandshakeDriverOptions(TimeSpan.FromSeconds(3)));
    var tamperedEstablished = await tamperedDriver.StartInitiatorAsync(
        BuildProductHandshakeContext(tamperedPlane, peerFingerprint: tamperedPlane.ResponderIdentityFingerprint));
    await ExpectThrowsAsync<WebRtcAppControlBootstrapException>(
        () => new WebRtcAppControlBootstrapClient(
                tamperedStore,
                new WebRtcAppControlBootstrapOptions(TimeSpan.FromSeconds(3)))
            .ExchangePingAsync(tamperedEstablished, WebRtcProductHandshakeCodec.SuiteX25519Ed25519),
        "pong id does not match");

    var overflowPlane = new TestWebRtcProductHandshakeResponderPlane(extraAppControlResponses: 1);
    var overflowStore = new WebRtcProductSecureSessionStore();
    var overflowDriver = new WebRtcProductHandshakeDriver(
        new TestWebRtcProductHandshakeCryptoProvider(overflowPlane.SharedSecret),
        overflowStore,
        new WebRtcProductHandshakeDriverOptions(TimeSpan.FromSeconds(3)));
    var overflowEstablished = await overflowDriver.StartInitiatorAsync(
        BuildProductHandshakeContext(overflowPlane, peerFingerprint: overflowPlane.ResponderIdentityFingerprint));
    await ExpectThrowsAsync<WebRtcAppControlBootstrapException>(
        () => new WebRtcAppControlBootstrapClient(
                overflowStore,
                new WebRtcAppControlBootstrapOptions(TimeSpan.FromSeconds(3), maxQueuedInboundMessages: 1))
            .ExchangePingAsync(overflowEstablished, WebRtcProductHandshakeCodec.SuiteX25519Ed25519),
        "inbound queue exceeded");
}

void VerifyWebRtcAppSecureEnvelopeCodec()
{
    var transcriptHash = SHA256.HashData(Encoding.UTF8.GetBytes("test transcript"));
    var initiatorSendKey = SHA256.HashData(Encoding.UTF8.GetBytes("initiator send key"));
    var responderSendKey = SHA256.HashData(Encoding.UTF8.GetBytes("responder send key"));
    var initiator = new WebRtcAppSecureSessionKeys(
        WebRtcAppSecureRole.Initiator,
        "session-123",
        transcriptHash,
        initiatorSendKey,
        responderSendKey);
    var responder = new WebRtcAppSecureSessionKeys(
        WebRtcAppSecureRole.Responder,
        "session-123",
        transcriptHash,
        responderSendKey,
        initiatorSendKey);

    var plaintext = Encoding.UTF8.GetBytes("skybridge mac product control payload");
    var sealedPacket = WebRtcControlChannelCodec.EncryptAppPayload(
        plaintext,
        initiator,
        WebRtcAppSecurePacketType.AppControl,
        counter: 7);
    AssertEqual(true, WebRtcControlChannelCodec.IsLikelySecureEnvelope(sealedPacket), "SBWC secure envelope marker");
    AssertEqual(WebRtcAppSecureEnvelope.OverheadBytes + plaintext.Length, sealedPacket.Length, "SBWC secure envelope size");

    var header = WebRtcAppSecureEnvelope.ParseHeader(sealedPacket);
    AssertEqual(WebRtcAppSecurePacketType.AppControl, header.PacketType, "SBWC packet type");
    AssertEqual(WebRtcAppSecureEnvelope.DirectionInitiatorToResponder, header.Direction, "SBWC direction");
    AssertEqual(WebRtcAppSecureEnvelope.SessionIdHash("session-123"), header.SessionHash, "SBWC session hash");
    AssertEqual(WebRtcAppSecureEnvelope.TranscriptPrefix(transcriptHash), header.TranscriptPrefix, "SBWC transcript prefix");
    AssertEqual((uint)0, header.Epoch, "SBWC epoch");
    AssertEqual((ulong)7, header.Counter, "SBWC counter");
    AssertEqual((uint)plaintext.Length, header.PayloadLength, "SBWC payload length");

    var opened = WebRtcControlChannelCodec.DecryptAppPayload(
        sealedPacket,
        responder,
        new[] { WebRtcAppSecurePacketType.AppControl });
    AssertBytesEqual(plaintext, opened.Payload, "SBWC decrypted payload");

    var replay = new WebRtcAppSecureReplayWindow();
    replay.ValidateAndRecord(opened);
    ExpectThrows<WebRtcAppSecureReplayException>(
        () => replay.ValidateAndRecord(opened),
        "duplicate-counter");

    var outsideWindow = new WebRtcAppSecureReplayWindow();
    outsideWindow.ValidateAndRecord(opened with { Counter = 2048 });
    ExpectThrows<WebRtcAppSecureReplayException>(
        () => outsideWindow.ValidateAndRecord(opened),
        "counter-outside-window");

    ExpectThrows<WebRtcAppSecureEnvelopeException>(
        () => WebRtcControlChannelCodec.DecryptAppPayload(
            sealedPacket,
            responder,
            new[] { WebRtcAppSecurePacketType.FileTransfer }),
        "packetType mismatch");

    ExpectThrows<WebRtcAppSecureEnvelopeException>(
        () => WebRtcControlChannelCodec.DecryptAppPayload(
            sealedPacket,
            initiator,
            new[] { WebRtcAppSecurePacketType.AppControl }),
        "direction mismatch");

    var wrongSession = new WebRtcAppSecureSessionKeys(
        WebRtcAppSecureRole.Responder,
        "session-wrong",
        transcriptHash,
        responderSendKey,
        initiatorSendKey);
    ExpectThrows<WebRtcAppSecureEnvelopeException>(
        () => WebRtcControlChannelCodec.DecryptAppPayload(
            sealedPacket,
            wrongSession,
            new[] { WebRtcAppSecurePacketType.AppControl }),
        "session mismatch");

    var tampered = sealedPacket.ToArray();
    tampered[^1] ^= 0x01;
    ExpectThrows<WebRtcAppSecureEnvelopeException>(
        () => WebRtcControlChannelCodec.DecryptAppPayload(
            tampered,
            responder,
            new[] { WebRtcAppSecurePacketType.AppControl }),
        "authentication failed");

    ExpectThrows<WebRtcAppSecureEnvelopeException>(
        () => WebRtcControlChannelCodec.EncryptAppPayload(
            plaintext,
            initiator,
            WebRtcAppSecurePacketType.AppControl,
            counter: 0),
        "invalid counter");
}

object InvokeSignalRead(MethodInfo read, string path, string expectedType)
{
    try
    {
        return read.Invoke(null, new object[] { path, expectedType })
            ?? throw new InvalidOperationException("SignalDocument.Read returned null.");
    }
    catch (TargetInvocationException ex) when (ex.InnerException is not null)
    {
        ExceptionDispatchInfo.Capture(ex.InnerException).Throw();
        throw;
    }
}

string InvokeSignalString(object signalDocument, string methodName)
{
    var method = signalDocument.GetType().GetMethod(methodName, BindingFlags.Public | BindingFlags.Instance)
        ?? throw new InvalidOperationException($"Missing SignalDocument.{methodName}.");
    try
    {
        return (string)(method.Invoke(signalDocument, Array.Empty<object>()) ?? string.Empty);
    }
    catch (TargetInvocationException ex) when (ex.InnerException is not null)
    {
        ExceptionDispatchInfo.Capture(ex.InnerException).Throw();
        throw;
    }
}

void InvokeDispatch(MethodInfo dispatch, SkyBridgeDataPlaneClient client, byte[] frame)
{
    try
    {
        dispatch.Invoke(client, new object[] { frame });
    }
    catch (TargetInvocationException ex) when (ex.InnerException is not null)
    {
        ExceptionDispatchInfo.Capture(ex.InnerException).Throw();
        throw;
    }
}

byte[] EncodeSbf1Frame(byte channel, ulong sequence, ushort flags, byte[] payload)
{
    var frame = new byte[20 + payload.Length];
    frame[0] = 0x53;
    frame[1] = 0x42;
    frame[2] = 0x46;
    frame[3] = 0x31;
    frame[4] = 1;
    frame[5] = channel;
    BinaryPrimitives.WriteUInt16BigEndian(frame.AsSpan(6, 2), flags);
    BinaryPrimitives.WriteUInt64BigEndian(frame.AsSpan(8, 8), sequence);
    BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(16, 4), (uint)payload.Length);
    payload.CopyTo(frame.AsSpan(20));
    return frame;
}

void ConfigureExternalEnvironment(
    string? adapterKind = "WebRtcDataChannel",
    string? secretHex = null,
    string? capabilityHex = null,
    string? timestampWindowMs = "12000",
    bool includeBinding = true)
{
    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "external");
    if (includeBinding)
    {
        Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_ADAPTER_BINDING", "external webrtc datachannel");
    }

    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_LOCAL_ENDPOINT", "windows.example:5443");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_REMOTE_ENDPOINT", "mac.example:5443");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_SELECTED_CANDIDATE_PAIR", "webrtc/dtls/sctp-selected");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_SECRET_FP_HEX", secretHex ?? new string('4', 64));
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_CAPABILITY_DIGEST_HEX", capabilityHex ?? new string('2', 64));
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RELAY_ID", "relay-1");
    if (adapterKind is not null)
    {
        Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_ADAPTER_KIND", adapterKind);
    }

    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TIMESTAMP_WINDOW_MS", timestampWindowMs);
}

void ConfigureVerifiedWebRtcEnvironment(string proofPath, string maxAgeMs = "60000")
{
    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER", "webrtc-verified");
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_PROOF_PATH", proofPath);
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_WEBRTC_PROOF_MAX_AGE_MS", maxAgeMs);
}

string WriteVerifiedWebRtcProof(
    string fileName,
    string? fingerprint = null,
    bool dataChannelOpen = true,
    bool sbf1EchoVerified = true,
    long? capturedAtUnixMs = null)
{
    var proofPath = Path.Combine(AppContext.BaseDirectory, fileName);
    File.WriteAllText(
        proofPath,
        $$"""
        {
          "helperName": "skybridge-webrtc-helper-smoke",
          "peerDeviceId": "mac-1",
          "peerPublicKeyFingerprint": "{{fingerprint ?? new string('0', 64)}}",
          "dataChannelOpen": {{dataChannelOpen.ToString().ToLowerInvariant()}},
          "sbf1EchoVerified": {{sbf1EchoVerified.ToString().ToLowerInvariant()}},
          "sbf1FrameMagic": "SBF1",
          "adapterBinding": "verified webrtc datachannel helper",
          "localEndpoint": "windows.lan:5443",
          "remoteEndpoint": "mac.lan:5443",
          "selectedCandidatePair": "webrtc/dtls/sctp/helper-selected",
          "transportSecretFingerprintHex": "{{new string('6', 64)}}",
          "capabilityDigestHex": "{{new string('7', 64)}}",
          "relayId": "relay-helper",
          "timestampWindowMs": 15000,
          "capturedAtUnixMs": {{capturedAtUnixMs ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}}
        }
        """);
    return proofPath;
}

void ClearRuntimeEnvironment()
{
    foreach (var variable in runtimeVariables)
    {
        Environment.SetEnvironmentVariable(variable, null);
    }
}

static WindowsTransportAdapterRequest BuildAdapterRequest(
    CoreTransportKind transportKind,
    CoreTransportAuditCode auditCode,
    string? peerDeviceId = null,
    string? peerFingerprint = null,
    string? pairingDeviceId = null,
    string? pairingFingerprint = null)
{
    var discoveredDeviceId = peerDeviceId ?? "mac-1";
    var discoveredFingerprint = peerFingerprint ?? new string('0', 64);
    var pairedDeviceId = pairingDeviceId ?? "mac-1";
    var pairedFingerprint = pairingFingerprint ?? new string('0', 64);
    var peer = new DiscoveredPeer(
        CoreDiscoveryServiceKind.QuicPrimary,
        discoveredDeviceId,
        "Desk Mac",
        CorePeerPlatform.Apple,
        "macOS",
        discoveredFingerprint,
        "apple-native,webrtc,tcp,relay",
        "1",
        PeerCapabilities.Apple());
    var pairingMaterial = new PairingMaterial(
        pairedDeviceId,
        "Desk Mac",
        "macOS",
        pairedFingerprint,
        new byte[] { 1, 2, 3, 4 },
        VerifiedAgainstDiscoveryFingerprint: true,
        "profile smoke");

    return new WindowsTransportAdapterRequest(
        peer,
        pairingMaterial,
        transportKind,
        auditCode,
        RelayRequired: false,
        RelayAllowed: true,
        PeerCapabilities.Windows(),
        peer.Capabilities,
        NetworkPath.CrossNatPath());
}

static WindowsTransportAdapterRequest BuildMsQuicAdapterRequestWithoutRemoteMsQuic()
{
    // Windows-to-Windows MsQuic transport kind/audit, but the remote peer does NOT advertise SupportsMsQuic,
    // so the adapter's capability-negotiation gate must reject the request before any QUIC dial.
    var remoteWithoutMsQuic = PeerCapabilities.Windows() with { SupportsMsQuic = false };
    var peer = new DiscoveredPeer(
        CoreDiscoveryServiceKind.QuicPrimary,
        "win-2",
        "Desk Windows",
        CorePeerPlatform.Windows,
        "Windows",
        new string('0', 64),
        "msquic,webrtc,tcp,relay",
        "1",
        remoteWithoutMsQuic);
    var pairingMaterial = new PairingMaterial(
        "win-2",
        "Desk Windows",
        "Windows",
        new string('0', 64),
        new byte[] { 1, 2, 3, 4 },
        VerifiedAgainstDiscoveryFingerprint: true,
        "profile smoke");

    return new WindowsTransportAdapterRequest(
        peer,
        pairingMaterial,
        CoreTransportKind.WindowsNativeMsQuic,
        CoreTransportAuditCode.WindowsNativeMsQuicSameLan,
        RelayRequired: false,
        RelayAllowed: false,
        PeerCapabilities.Windows(),
        remoteWithoutMsQuic,
        NetworkPath.SameLanPath());
}

static T GetNested<T>(object source, string fieldName)
{
    var field = source.GetType().GetField(fieldName, BindingFlags.Instance | BindingFlags.NonPublic);
    if (field is null)
    {
        throw new InvalidOperationException($"Missing private field '{fieldName}' on {source.GetType().Name}.");
    }

    var value = field.GetValue(source);
    if (value is not T typed)
    {
        throw new InvalidOperationException($"Expected field '{fieldName}' to be {typeof(T).Name}, got {value?.GetType().Name ?? "null"}.");
    }

    return typed;
}

static void AssertNestedType<T>(object source, string fieldName, string label)
{
    var value = GetNested<object>(source, fieldName);
    AssertType<T>(value, label);
}

static void AssertType<T>(object? value, string label)
{
    if (value?.GetType() != typeof(T))
    {
        throw new InvalidOperationException($"{label}: expected {typeof(T).Name}, got {value?.GetType().Name ?? "null"}.");
    }
}

static void ExpectThrows<T>(Action action, string messageFragment)
    where T : Exception
{
    try
    {
        action();
    }
    catch (T ex) when (ex.Message.Contains(messageFragment, StringComparison.Ordinal))
    {
        return;
    }
    catch (Exception ex)
    {
        throw new InvalidOperationException($"Expected {typeof(T).Name} containing '{messageFragment}', got {ex.GetType().Name}: {ex.Message}");
    }

    throw new InvalidOperationException($"Expected {typeof(T).Name} containing '{messageFragment}'.");
}

static async Task ExpectThrowsAsync<T>(Func<Task> action, string messageFragment)
    where T : Exception
{
    try
    {
        await action();
    }
    catch (T ex) when (ex.Message.Contains(messageFragment, StringComparison.Ordinal))
    {
        return;
    }
    catch (Exception ex)
    {
        throw new InvalidOperationException($"Expected {typeof(T).Name} containing '{messageFragment}', got {ex.GetType().Name}: {ex.Message}");
    }

    throw new InvalidOperationException($"Expected {typeof(T).Name} containing '{messageFragment}'.");
}

static HttpResponseMessage JsonResponse(string json) =>
    new(HttpStatusCode.OK)
    {
        Content = new StringContent(json, Encoding.UTF8, "application/json")
    };

static void AssertBytesEqual(byte[] expected, byte[] actual, string label)
{
    if (!expected.AsSpan().SequenceEqual(actual))
    {
        throw new InvalidOperationException($"{label}: expected sha256={Sha256Hex(expected)}, got sha256={Sha256Hex(actual)}.");
    }
}

static void AssertBytesAllZero(byte[] actual, string label)
{
    for (var index = 0; index < actual.Length; index++)
    {
        if (actual[index] != 0)
        {
            throw new InvalidOperationException($"{label}: byte {index} was not cleared.");
        }
    }
}

static string Sha256Hex(byte[] bytes) =>
    Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

static string ManualAuthoritativeFingerprint(string algorithmRawValue, byte[] publicKey)
{
    var algorithmBytes = Encoding.UTF8.GetBytes(algorithmRawValue);
    using var payload = new MemoryStream();
    Span<byte> algorithmLength = stackalloc byte[2];
    BinaryPrimitives.WriteUInt16LittleEndian(algorithmLength, checked((ushort)algorithmBytes.Length));
    payload.Write(algorithmLength);
    payload.Write(algorithmBytes);
    Span<byte> keyLength = stackalloc byte[4];
    BinaryPrimitives.WriteUInt32LittleEndian(keyLength, checked((uint)publicKey.Length));
    payload.Write(keyLength);
    payload.Write(publicKey);
    return Sha256Hex(payload.ToArray());
}

static byte[] HexToBytes(string hex)
{
    if (hex.Length % 2 != 0)
    {
        throw new InvalidOperationException("hex test vector must have an even length.");
    }

    var bytes = new byte[hex.Length / 2];
    for (var index = 0; index < bytes.Length; index++)
    {
        bytes[index] = Convert.ToByte(hex.Substring(index * 2, 2), 16);
    }

    return bytes;
}

static byte[] SequenceBytes(int count, int seed)
{
    var bytes = new byte[count];
    for (var index = 0; index < bytes.Length; index++)
    {
        bytes[index] = (byte)((seed + index) % 251);
    }

    return bytes;
}

static void AssertEqual<T>(T expected, T actual, string label)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{label}: expected '{expected}', got '{actual}'.");
    }
}

static void AssertContains(string text, string expected, string label)
{
    if (!text.Contains(expected, StringComparison.Ordinal))
    {
        throw new InvalidOperationException($"{label}: expected to find '{expected}' in '{text}'.");
    }
}

static void AssertSettingsAction(SettingsWorkspaceSnapshot snapshot, string key, string state, string assertionLabel)
{
    var action = snapshot.Actions.FirstOrDefault(item => item.Key == key);
    if (action is null)
    {
        throw new InvalidOperationException($"{assertionLabel}: missing settings action '{key}'.");
    }

    AssertEqual(state, action.State, assertionLabel);
}

static void AssertSettingsDetail(SettingsWorkspaceSnapshot snapshot, string section, string label, string value, string assertionLabel)
{
    var detail = snapshot.Details.FirstOrDefault(item => item.Section == section && item.Label == label);
    if (detail is null)
    {
        throw new InvalidOperationException($"{assertionLabel}: missing settings detail '{section}/{label}'.");
    }

    AssertEqual(value, detail.Value, assertionLabel);
}

static void AssertIndicator(SystemMonitorWorkspaceSnapshot snapshot, string label, string state, string assertionLabel)
{
    var indicator = snapshot.Indicators.FirstOrDefault(item => item.Label == label);
    if (indicator is null)
    {
        throw new InvalidOperationException($"{assertionLabel}: missing indicator '{label}'.");
    }

    AssertEqual(state, indicator.State, assertionLabel);
}

static LiveWebRtcProductControlContext BuildProductHandshakeContext(
    IWebRtcProductControlPlane controlPlane,
    WebRtcProductControlSecureSessionState state = WebRtcProductControlSecureSessionState.TransportOnly,
    string? peerFingerprint = null,
    string role = "offer") =>
    new(
        controlPlane,
        "mac-device-1",
        peerFingerprint ?? new string('a', 64),
        role,
        WebRtcProductControlTransportProvider.TransportProfile,
        WebRtcProductControlTransportProvider.DataChannelLabel,
        "mac-product-control-v1/offer/datachannel=skybridge/ipc=127.0.0.1:49152",
        "192.168.0.105:5443",
        "192.168.0.101:5443",
        "webrtc/dtls/sctp/host-192.168.0.105:5443-host-192.168.0.101:5443/skybridge",
        new string('b', 64),
        15_000,
        state);

static class ProductHandshakeTestVectors
{
    public static byte[] SequenceBytes(int count, int seed)
    {
        var bytes = new byte[count];
        for (var index = 0; index < bytes.Length; index++)
        {
            bytes[index] = (byte)((seed + index) % 251);
        }

        return bytes;
    }

	    public static void AssertEqual<T>(T expected, T actual, string label)
	    {
	        if (!EqualityComparer<T>.Default.Equals(expected, actual))
	        {
	            throw new InvalidOperationException($"{label}: expected '{expected}', got '{actual}'.");
	        }
		    }
		}

sealed class RecordingHttpMessageHandler : HttpMessageHandler
{
    private readonly Queue<Func<HttpRequestMessage, string, HttpResponseMessage>> _responders = new();

    public void Enqueue(Func<HttpRequestMessage, string, HttpResponseMessage> responder) =>
        _responders.Enqueue(responder);

    public void AssertDrained()
    {
        if (_responders.Count != 0)
        {
            throw new InvalidOperationException($"Expected all fake HTTP responders to be consumed, remaining={_responders.Count}.");
        }
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        if (_responders.Count == 0)
        {
            throw new InvalidOperationException($"Unexpected HTTP request: {request.Method} {request.RequestUri}");
        }

        var body = request.Content is null
            ? string.Empty
            : await request.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        return _responders.Dequeue()(request, body);
    }
}

sealed class FakeCurrentPathWebSocketTransport : ICurrentPathWebSocketTransport
{
    private readonly Queue<CurrentPathWebSocketReceiveResult> _receiveQueue = new();

    public bool Connected { get; private set; }

    public bool Closed { get; private set; }

    public List<string> SentTexts { get; } = new();

    public void EnqueueReceive(CurrentPathWebSocketReceiveResult result) =>
        _receiveQueue.Enqueue(result);

    public Task ConnectAsync(
        Uri uri,
        IReadOnlyDictionary<string, string> headers,
        CancellationToken cancellationToken)
    {
        RequireEqual("wss", uri.Scheme, "fake current-path websocket scheme");
        RequireEqual(false, uri.Query.Contains("st=", StringComparison.Ordinal), "fake current-path websocket query token");
        RequireEqual(true, headers.ContainsKey(CurrentPathSignalingWebSocketPolicy.SessionIdHeader), "fake current-path websocket session id header");
        RequireEqual(true, headers.ContainsKey(CurrentPathSignalingWebSocketPolicy.SessionTokenHeader), "fake current-path websocket session token header");
        Connected = true;
        return Task.CompletedTask;
    }

    public Task SendTextAsync(string text, CancellationToken cancellationToken)
    {
        if (!Connected || Closed)
        {
            throw new InvalidOperationException("Fake current-path websocket is not open.");
        }

        SentTexts.Add(text);
        return Task.CompletedTask;
    }

    public Task<CurrentPathWebSocketReceiveResult> ReceiveAsync(
        int maxMessageBytes,
        CancellationToken cancellationToken)
    {
        if (!Connected || Closed)
        {
            throw new InvalidOperationException("Fake current-path websocket is not open.");
        }

        if (_receiveQueue.Count == 0)
        {
            throw new InvalidOperationException("Fake current-path websocket receive queue is empty.");
        }

        var result = _receiveQueue.Dequeue();
        if (result.ByteCount > maxMessageBytes)
        {
            throw new InvalidDataException("Current-path WebSocket text message exceeded the configured byte limit.");
        }

        return Task.FromResult(result);
    }

    public Task CloseAsync(CancellationToken cancellationToken)
    {
        Closed = true;
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        Closed = true;
        return ValueTask.CompletedTask;
    }

    private static void RequireEqual<T>(T expected, T actual, string label)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"{label}: expected '{expected}', got '{actual}'.");
        }
    }
}

sealed class TestWebRtcProductPqcResponderPlane : IWebRtcProductControlPlane, IDisposable
{
    private static readonly byte[] EmptyMldsaContext = Array.Empty<byte>();
    private static readonly byte[] PlaceholderSignature = { 0x01 };
    private static readonly byte[] HandshakePayloadInfo = Encoding.ASCII.GetBytes("handshake-payload");

    private readonly MLDsa _responderSigner;
    private readonly MLKem _responderKem;
    private readonly bool _tamperResponderSignature;
    private bool _disposed;

    public TestWebRtcProductPqcResponderPlane(bool tamperResponderSignature = false)
    {
        _responderSigner = MLDsa.GenerateKey(MLDsaAlgorithm.MLDsa65);
        _responderKem = MLKem.GenerateKey(MLKemAlgorithm.MLKem768);
        var identity = new WebRtcProductProtocolIdentityPublicKey(
            WebRtcProductSignatureAlgorithm.MlDsa65,
            _responderSigner.ExportMLDsaPublicKey());
        ResponderIdentityPublicKey = identity.Encode();
        ResponderIdentityFingerprint = identity.AuthoritativeFingerprint;
        PeerKemPublicKey = _responderKem.ExportEncapsulationKey();
        _tamperResponderSignature = tamperResponderSignature;
    }

    public bool IsConnected => true;

    public byte[] PeerKemPublicKey { get; }

    public byte[] ResponderIdentityPublicKey { get; }

    public string ResponderIdentityFingerprint { get; }

    public WebRtcAppSecureSessionKeys? ResponderKeys { get; private set; }

    public bool InitiatorFinishedVerified { get; private set; }

    public int SentMessageCount { get; private set; }

    public event Action<byte[]>? MessageReceived;

    public Task SendAsync(ReadOnlyMemory<byte> message, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ThrowIfDisposed();
        SentMessageCount++;
        if (SentMessageCount == 1)
        {
            ReplyToMessageA(message.ToArray());
        }
        else if (SentMessageCount == 2)
        {
            VerifyInitiatorFinished(message.ToArray());
        }
        else
        {
            throw new InvalidOperationException("PQC responder plane only handles MessageA and initiator Finished.");
        }

        return Task.CompletedTask;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _responderSigner.Dispose();
        _responderKem.Dispose();
        CryptographicOperations.ZeroMemory(PeerKemPublicKey);
        CryptographicOperations.ZeroMemory(ResponderIdentityPublicKey);
    }

    private void ReplyToMessageA(byte[] outbound)
    {
        var messageA = WebRtcProductHandshakeCodec.DecodeMessageA(outbound);
        var keyShare = RequirePqcKeyShare(messageA);
        var sharedSecret = _responderKem.Decapsulate(keyShare);
        byte[]? payload = null;
        byte[]? payloadKey = null;
        byte[]? ciphertext = null;
        byte[]? tag = null;
        try
        {
            var transcriptA = SHA256.HashData(messageA.EncodeWithoutSignature());
            payload = new WebRtcProductCryptoCapabilities(
                supportedKem: new[] { "ML-KEM-768" },
                supportedSignature: new[] { "ML-DSA-65" },
                supportedAuthProfiles: new[] { "PQC" },
                supportedAead: new[] { "AES-256-GCM" },
                pqcAvailable: true,
                platformVersion: "macos-pqc-responder-smoke",
                providerType: "CryptoKit-PQC").Encode();
            payloadKey = WebRtcProductHandshakeSessionKeys.HkdfSha256(
                sharedSecret,
                transcriptA,
                HandshakePayloadInfo,
                outputLength: 32);
            var nonce = RandomNumberGenerator.GetBytes(WebRtcProductHandshakeCodec.HpkeNonceLength);
            ciphertext = new byte[payload.Length];
            tag = new byte[WebRtcProductHandshakeCodec.HpkeTagLength];
            using (var aes = new AesGcm(payloadKey, WebRtcProductHandshakeCodec.HpkeTagLength))
            {
                aes.Encrypt(nonce, payload, ciphertext, tag);
            }

            var sealedBox = new WebRtcProductHpkeSealedBox(
                WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65,
                Array.Empty<byte>(),
                nonce,
                ciphertext,
                tag);
            var serverNonce = RandomNumberGenerator.GetBytes(WebRtcProductHandshakeCodec.NonceLength);
            var unsignedMessageB = new WebRtcProductHandshakeMessageB(
                selectedSuiteWireId: WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65,
                responderShare: Array.Empty<byte>(),
                serverNonce: serverNonce,
                encryptedPayload: sealedBox,
                identityPublicKey: ResponderIdentityPublicKey,
                signature: PlaceholderSignature);
            var signature = _responderSigner.SignData(
                unsignedMessageB.SignaturePreimage(transcriptA),
                EmptyMldsaContext);
            if (_tamperResponderSignature)
            {
                signature[^1] ^= 0x01;
            }

            var messageB = new WebRtcProductHandshakeMessageB(
                selectedSuiteWireId: unsignedMessageB.SelectedSuiteWireId,
                responderShare: unsignedMessageB.ResponderShare,
                serverNonce: unsignedMessageB.ServerNonce,
                encryptedPayload: unsignedMessageB.EncryptedPayload,
                identityPublicKey: unsignedMessageB.IdentityPublicKey,
                signature: signature);
            var transcriptB = SHA256.HashData(messageB.EncodeWithoutSignature());
            ResponderKeys = WebRtcProductHandshakeSessionKeys.Derive(
                sharedSecret,
                WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65,
                transcriptA,
                transcriptB,
                messageA.ClientNonce.Span,
                messageB.ServerNonce.Span,
                WebRtcAppSecureRole.Responder);

            MessageReceived?.Invoke(messageB.Encode());
            MessageReceived?.Invoke(WebRtcProductHandshakeSessionKeys.CreateFinished(ResponderKeys).Encode());
        }
        finally
        {
            CryptographicOperations.ZeroMemory(sharedSecret);
            CryptographicOperations.ZeroMemory(keyShare);
            if (payload is not null) CryptographicOperations.ZeroMemory(payload);
            if (payloadKey is not null) CryptographicOperations.ZeroMemory(payloadKey);
            if (ciphertext is not null) CryptographicOperations.ZeroMemory(ciphertext);
            if (tag is not null) CryptographicOperations.ZeroMemory(tag);
        }
    }

    private void VerifyInitiatorFinished(byte[] outbound)
    {
        if (ResponderKeys is null)
        {
            throw new InvalidOperationException("PQC responder plane has no session keys.");
        }

        var initiatorFinished = WebRtcProductHandshakeCodec.DecodeFinished(outbound);
        InitiatorFinishedVerified = WebRtcProductHandshakeSessionKeys.VerifyFinished(
            initiatorFinished,
            ResponderKeys,
            WebRtcAppSecureRole.Initiator);
        if (!InitiatorFinishedVerified)
        {
            throw new InvalidOperationException("PQC responder plane could not verify initiator Finished.");
        }
    }

    private static byte[] RequirePqcKeyShare(WebRtcProductHandshakeMessageA messageA)
    {
        foreach (var keyShare in messageA.KeyShares)
        {
            if (keyShare.SuiteWireId == WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65)
            {
                return keyShare.ShareBytes.ToArray();
            }
        }

        throw new InvalidOperationException("PQC responder plane expected a ML-KEM-768 MessageA keyShare.");
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(TestWebRtcProductPqcResponderPlane));
        }
    }
}

sealed class TestWebRtcProductHandshakeCryptoProvider : IWebRtcProductHandshakeCryptoProvider
{
    private readonly byte[] _sharedSecret;

    public TestWebRtcProductHandshakeCryptoProvider(byte[] sharedSecret)
    {
        ProductHandshakeTestVectors.AssertEqual(WebRtcProductHandshakeSessionKeys.SharedSecretLength, sharedSecret.Length, "test product handshake shared secret length");
        _sharedSecret = sharedSecret.ToArray();
    }

    public int OpenMessageBCount { get; private set; }

    public ValueTask<WebRtcProductHandshakeMessageA> CreateInitiatorMessageAAsync(
        LiveWebRtcProductControlContext context,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        cancellationToken.ThrowIfCancellationRequested();
        var suite = WebRtcProductHandshakeCodec.SuiteX25519Ed25519;
        var messageA = new WebRtcProductHandshakeMessageA(
            supportedSuiteWireIds: new[] { suite },
            keyShares: new[]
            {
                new WebRtcProductHandshakeKeyShare(suite, ProductHandshakeTestVectors.SequenceBytes(32, 0x21))
            },
            clientNonce: ProductHandshakeTestVectors.SequenceBytes(32, 0x31),
            capabilities: new WebRtcProductCryptoCapabilities(
                supportedKem: new[] { "X25519" },
                supportedSignature: new[] { "Ed25519" },
                supportedAuthProfiles: new[] { "skybridge-product-control-v1" },
                supportedAead: new[] { "AES-256-GCM" },
                pqcAvailable: false,
                platformVersion: "windows-runtime-profile",
                providerType: "CryptoKit-Classic"),
            policy: WebRtcProductHandshakePolicy.Default,
            identityPublicKey: new WebRtcProductProtocolIdentityPublicKey(
                WebRtcProductSignatureAlgorithm.Ed25519,
                ProductHandshakeTestVectors.SequenceBytes(32, 0x41)).Encode(),
            extensionsRaw: Array.Empty<byte>(),
            signature: ProductHandshakeTestVectors.SequenceBytes(64, 0x51));
        return ValueTask.FromResult(messageA);
    }

    public ValueTask<ReadOnlyMemory<byte>> OpenResponderMessageBAsync(
        LiveWebRtcProductControlContext context,
        WebRtcProductHandshakeMessageA messageA,
        ReadOnlyMemory<byte> transcriptHashA,
        WebRtcProductHandshakeMessageB messageB,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(messageA);
        ArgumentNullException.ThrowIfNull(messageB);
        cancellationToken.ThrowIfCancellationRequested();
        ProductHandshakeTestVectors.AssertEqual(WebRtcProductHandshakeCodec.TranscriptHashLength, transcriptHashA.Length, "product handshake provider transcriptHashA length");
        ProductHandshakeTestVectors.AssertEqual(WebRtcProductHandshakeCodec.SuiteX25519Ed25519, messageB.SelectedSuiteWireId, "product handshake provider selected suite");
        ProductHandshakeTestVectors.AssertEqual(true, messageA.SupportedSuiteWireIds.Contains(messageB.SelectedSuiteWireId), "product handshake provider selected suite offered");
        OpenMessageBCount++;
        return ValueTask.FromResult<ReadOnlyMemory<byte>>(_sharedSecret.ToArray());
    }
}

	sealed class TestWebRtcProductHandshakeResponderPlane : IWebRtcProductControlPlane
	{
    private readonly bool _tamperResponderFinished;
    private readonly bool _sendSecureEnvelopeBeforeMessageB;
    private readonly int _extraMessagesBeforeMessageB;
    private readonly bool _wrapAppControlResponseWithTrafficPadding;
	    private readonly bool _tamperAppControlPongId;
	    private readonly int _extraAppControlResponses;
	    private readonly WebRtcAppSecureReplayWindow _appControlReplayWindow = new();
	    private readonly WebRtcProductProtocolIdentityPublicKey _responderIdentity = new(
	        WebRtcProductSignatureAlgorithm.Ed25519,
	        ProductHandshakeTestVectors.SequenceBytes(32, 0xB1));
	    private ulong _nextResponderAppControlCounter = 1;

    public TestWebRtcProductHandshakeResponderPlane(
        bool tamperResponderFinished = false,
        bool sendSecureEnvelopeBeforeMessageB = false,
        int extraMessagesBeforeMessageB = 0,
        bool wrapAppControlResponseWithTrafficPadding = false,
        bool tamperAppControlPongId = false,
        int extraAppControlResponses = 0)
    {
        _tamperResponderFinished = tamperResponderFinished;
        _sendSecureEnvelopeBeforeMessageB = sendSecureEnvelopeBeforeMessageB;
        _extraMessagesBeforeMessageB = extraMessagesBeforeMessageB;
        _wrapAppControlResponseWithTrafficPadding = wrapAppControlResponseWithTrafficPadding;
        _tamperAppControlPongId = tamperAppControlPongId;
        _extraAppControlResponses = extraAppControlResponses;
    }

    public bool IsConnected => true;

    public byte[] SharedSecret { get; } = SHA256.HashData(Encoding.UTF8.GetBytes("runtime profile product handshake shared secret"));

	    public byte[] ResponderIdentityPublicKey => _responderIdentity.Encode();

	    public string ResponderIdentityFingerprint => _responderIdentity.AuthoritativeFingerprint;

    public List<byte[]> SentMessages { get; } = new();

    public WebRtcAppSecureSessionKeys? ResponderKeys { get; private set; }

    public bool InitiatorFinishedVerified { get; private set; }

    public bool AppControlPingOpened { get; private set; }

    public bool AppControlPongSent { get; private set; }

    public ulong? ReceivedAppControlPingId { get; private set; }

    public event Action<byte[]>? MessageReceived;

    public Task SendAsync(ReadOnlyMemory<byte> message, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var outbound = message.ToArray();
        SentMessages.Add(outbound);
        if (SentMessages.Count == 1)
        {
            ReplyToMessageA(outbound);
        }
        else if (SentMessages.Count == 2)
        {
            VerifyInitiatorFinished(outbound);
        }
        else
        {
            ReplyToAppControl(outbound);
        }

        return Task.CompletedTask;
    }

    private void ReplyToMessageA(byte[] outbound)
    {
        var messageA = WebRtcProductHandshakeCodec.DecodeMessageA(outbound);
        if (_sendSecureEnvelopeBeforeMessageB)
        {
            MessageReceived?.Invoke(BuildLikelySecureEnvelope());
            return;
        }

        for (var index = 0; index < _extraMessagesBeforeMessageB; index++)
        {
            MessageReceived?.Invoke(Encoding.UTF8.GetBytes($"unexpected-handshake-frame-{index}"));
        }

        var suite = WebRtcProductHandshakeCodec.SuiteX25519Ed25519;
        var messageB = new WebRtcProductHandshakeMessageB(
            selectedSuiteWireId: suite,
            responderShare: ProductHandshakeTestVectors.SequenceBytes(32, 0x61),
            serverNonce: ProductHandshakeTestVectors.SequenceBytes(32, 0x71),
            encryptedPayload: new WebRtcProductHpkeSealedBox(
                suite,
                ProductHandshakeTestVectors.SequenceBytes(32, 0x81),
                ProductHandshakeTestVectors.SequenceBytes(12, 0x91),
                Encoding.UTF8.GetBytes("runtime profile responder payload"),
                ProductHandshakeTestVectors.SequenceBytes(16, 0xA1)),
            identityPublicKey: ResponderIdentityPublicKey,
            signature: ProductHandshakeTestVectors.SequenceBytes(64, 0xC1));
        var transcriptA = SHA256.HashData(messageA.EncodeWithoutSignature());
        var transcriptB = SHA256.HashData(messageB.EncodeWithoutSignature());
        ResponderKeys = WebRtcProductHandshakeSessionKeys.Derive(
            SharedSecret,
            suite,
            transcriptA,
            transcriptB,
            messageA.ClientNonce.Span,
            messageB.ServerNonce.Span,
            WebRtcAppSecureRole.Responder);

        MessageReceived?.Invoke(messageB.Encode());
        var responderFinished = WebRtcProductHandshakeSessionKeys.CreateFinished(ResponderKeys);
        var responderFinishedWire = responderFinished.Encode();
        if (_tamperResponderFinished)
        {
            responderFinishedWire[^1] ^= 0x01;
        }

        MessageReceived?.Invoke(responderFinishedWire);
    }

    private void VerifyInitiatorFinished(byte[] outbound)
    {
        if (ResponderKeys is null)
        {
            throw new InvalidOperationException("test product handshake responder has no session keys.");
        }

        var initiatorFinished = WebRtcProductHandshakeCodec.DecodeFinished(outbound);
        InitiatorFinishedVerified = WebRtcProductHandshakeSessionKeys.VerifyFinished(
            initiatorFinished,
            ResponderKeys,
            WebRtcAppSecureRole.Initiator);
        if (!InitiatorFinishedVerified)
        {
            throw new InvalidOperationException("test product handshake responder could not verify initiator Finished.");
        }
    }

    private void ReplyToAppControl(byte[] outbound)
    {
        if (ResponderKeys is null)
        {
            throw new InvalidOperationException("test product handshake responder has no AppControl session keys.");
        }

        if (!InitiatorFinishedVerified)
        {
            throw new InvalidOperationException("test product handshake responder must verify initiator Finished before AppControl.");
        }

        var opened = WebRtcControlChannelCodec.DecryptAppPayload(
            outbound,
            ResponderKeys,
            new[] { WebRtcAppSecurePacketType.AppControl });
        _appControlReplayWindow.ValidateAndRecord(opened);
        var pingId = RequirePingId(opened.Payload);
        AppControlPingOpened = true;
        ReceivedAppControlPingId = pingId;

        var responsePingId = _tamperAppControlPongId
            ? (pingId == ulong.MaxValue ? 1 : pingId + 1)
            : pingId;
        for (var index = 0; index <= _extraAppControlResponses; index++)
        {
            var sealedPong = SealPongPayload(responsePingId);
            MessageReceived?.Invoke(_wrapAppControlResponseWithTrafficPadding
                ? WrapTrafficPadding(sealedPong)
                : sealedPong);
        }

        AppControlPongSent = true;
    }

    private byte[] SealPongPayload(ulong pingId)
    {
        if (ResponderKeys is null)
        {
            throw new InvalidOperationException("test product handshake responder has no AppControl session keys.");
        }

        var payload = BuildPongPayload(pingId);
        return WebRtcControlChannelCodec.EncryptAppPayload(
            payload,
            ResponderKeys,
            WebRtcAppSecurePacketType.AppControl,
            _nextResponderAppControlCounter++);
    }

    private static ulong RequirePingId(ReadOnlySpan<byte> payload)
    {
        using var document = JsonDocument.Parse(payload.ToArray());
        if (document.RootElement.ValueKind != JsonValueKind.Object ||
            !document.RootElement.TryGetProperty("ping", out var ping) ||
            ping.ValueKind != JsonValueKind.Object ||
            !ping.TryGetProperty("id", out var id) ||
            id.ValueKind != JsonValueKind.Number ||
            !id.TryGetUInt64(out var pingId))
        {
            throw new InvalidOperationException("test product handshake responder expected a JSON AppMessage ping payload.");
        }

        return pingId;
    }

    private static byte[] BuildPongPayload(ulong pingId)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteStartObject("pong");
            writer.WriteNumber("id", pingId);
            writer.WriteEndObject();
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    private static byte[] WrapTrafficPadding(byte[] payload)
    {
        var padded = new byte[payload.Length + 24];
        padded[0] = 0x53;
        padded[1] = 0x42;
        padded[2] = 0x50;
        padded[3] = 0x32;
        BinaryPrimitives.WriteUInt32BigEndian(padded.AsSpan(4, 4), checked((uint)payload.Length));
        payload.CopyTo(padded.AsSpan(8));
        for (var index = 8 + payload.Length; index < padded.Length; index++)
        {
            padded[index] = 0xA5;
        }

        return padded;
    }

    private static byte[] BuildLikelySecureEnvelope()
    {
        var packet = new byte[WebRtcAppSecureEnvelope.OverheadBytes];
        BinaryPrimitives.WriteUInt32BigEndian(packet.AsSpan(0, 4), WebRtcAppSecureEnvelope.Magic);
        packet[4] = WebRtcAppSecureEnvelope.Version;
        packet[5] = WebRtcAppSecureEnvelope.HeaderLength;
        return packet;
    }
}

sealed class TestWebRtcProductControlPlane : IWebRtcProductControlPlane
{
    public bool IsConnected => true;

    public event Action<byte[]>? MessageReceived;

    public Task SendAsync(ReadOnlyMemory<byte> message, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        MessageReceived?.Invoke(message.ToArray());
        return Task.CompletedTask;
    }
}
'@

    & dotnet restore $testProject
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Windows native runtime profile restore failed."

    & dotnet run --project $testProject --no-restore
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Windows native runtime profile run failed."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTempRoot = (Resolve-Path -LiteralPath $tempRoot).Path
        $resolvedTempParent = (Resolve-Path -LiteralPath $tempParent).Path.TrimEnd('\')
        $leaf = Split-Path -Leaf $resolvedTempRoot
        $isOwnedSmokeDir = $resolvedTempRoot.StartsWith(
            $resolvedTempParent,
            [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith(
            "skybridge-win-native-runtime-profile-",
            [StringComparison]::Ordinal)

        Assert-True -Condition $isOwnedSmokeDir -Message "Refusing to remove unexpected temp directory: $resolvedTempRoot"
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}
