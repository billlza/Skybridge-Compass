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
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/SessionViewModelDependencies.cs"
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/SessionViewModelDependencyFactory.cs"
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/WindowsNativeRuntimeDependencyFactory.cs"

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
using System.Reflection;
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
    "SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES"
};

try
{
    ClearRuntimeEnvironment();
    AssertEqual(false, WindowsNativeRuntimeDependencyFactory.IsNativeRuntimeRequested(), "default native runtime flag");
    var defaultDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<DummyEngineClient>(defaultDependencies.EngineClient, "default engine");
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
    AssertEqual(false, defaultDependencies.FileTransferClient.CanSelectFiles(), "default file transfer select files gate");
    AssertEqual(false, defaultDependencies.FileTransferClient.CanSelectFolder(), "default file transfer select folder gate");
    AssertEqual(true, defaultDependencies.FileTransferClient.CanGenerateShareQr(), "default file transfer QR share gate");
    var shareQrIntent = await defaultDependencies.FileTransferClient.BuildShareQrActionAsync();
    AssertEqual(FileTransferWorkspaceClient.DefaultShareQrReadyStatus, shareQrIntent.Status, "file transfer QR share intent status");
    AssertEqual(FileTransferWorkspaceClient.DefaultShareQrReadyMessage, shareQrIntent.Message, "file transfer QR share intent message");
    AssertContains(shareQrIntent.Detail, "intent=FT-0001", "file transfer QR share intent detail should include deterministic in-memory intent id.");
    AssertContains(shareQrIntent.Detail, "no transport or signaling session was started", "file transfer QR share intent detail should keep transport/signaling disabled.");
    AssertType<SettingsWorkspaceClient>(defaultDependencies.SettingsClient, "default settings client");
    AssertNestedType<DisabledSystemPreferencesLauncher>(defaultDependencies.SettingsClient, "_systemPreferencesLauncher", "default system preferences launcher");
    AssertNestedType<InMemorySettingsExportPreviewClient>(defaultDependencies.SettingsClient, "_exportPreviewClient", "default settings export preview client");
    AssertEqual(true, defaultDependencies.SettingsClient.CanExportSettings(), "default settings export gate");
    AssertEqual(false, defaultDependencies.SettingsClient.CanImportSettings(), "default settings import gate");
    AssertEqual(false, defaultDependencies.SettingsClient.CanResetSettings(), "default settings reset gate");
    AssertEqual(false, defaultDependencies.SettingsClient.CanOpenSystemPreferences(), "default system preferences gate");
    var exportPreview = await defaultDependencies.SettingsClient.BuildExportSettingsActionAsync();
    AssertEqual(SettingsWorkspaceClient.DefaultExportSettingsPreviewReadyStatus, exportPreview.Status, "settings export preview status");
    AssertEqual($"{SettingsWorkspaceClient.DefaultExportSettingsPreviewReadyMessage} preview=SET-0001", exportPreview.Message, "settings export preview message");
    var settingsSnapshot = await defaultDependencies.SettingsClient.BuildReadOnlySnapshotAsync();
    AssertSettingsAction(settingsSnapshot, "ExportSettings", "Preview ready", "settings export preview action");
    AssertSettingsDetail(settingsSnapshot, "General", "Export preview", "SET-0001", "settings export preview detail");
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
    var transportEnvWithoutNative = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<DummyEngineClient>(transportEnvWithoutNative.EngineClient, "transport env without native engine");
    AssertNestedType<PendingWindowsTransportAdapterClient>(transportEnvWithoutNative.ConnectionPreflightClient, "_transportAdapterClient", "transport env without native adapter");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES", "enabled");
    var systemPreferencesDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<DummyEngineClient>(systemPreferencesDependencies.EngineClient, "system preferences env without native engine");
    AssertType<SettingsWorkspaceClient>(systemPreferencesDependencies.SettingsClient, "system preferences settings client");
    AssertNestedType<WindowsSystemPreferencesLauncher>(systemPreferencesDependencies.SettingsClient, "_systemPreferencesLauncher", "enabled system preferences launcher");
    AssertEqual(true, systemPreferencesDependencies.SettingsClient.CanOpenSystemPreferences(), "enabled system preferences gate");

    ClearRuntimeEnvironment();
    Environment.SetEnvironmentVariable("SKYBRIDGE_WINDOWS_RUNTIME", "native");
    AssertEqual(true, WindowsNativeRuntimeDependencyFactory.IsNativeRuntimeRequested(), "native runtime flag");
    var nativePendingDependencies = SessionViewModelDependencyFactory.CreateConfigured();
    AssertType<FfiEngineClient>(nativePendingDependencies.EngineClient, "native engine");
    AssertNestedType<NativeWindowsDnsSdBrowseClient>(nativePendingDependencies.DiscoveryBrowserClient, "_dnsSdBrowseClient", "native DNS-SD provider");
    AssertNestedType<PendingWindowsTransportAdapterClient>(nativePendingDependencies.ConnectionPreflightClient, "_transportAdapterClient", "native pending adapter");

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

void ClearRuntimeEnvironment()
{
    foreach (var variable in runtimeVariables)
    {
        Environment.SetEnvironmentVariable(variable, null);
    }
}

static WindowsTransportAdapterRequest BuildAdapterRequest(CoreTransportKind transportKind, CoreTransportAuditCode auditCode)
{
    var peer = new DiscoveredPeer(
        CoreDiscoveryServiceKind.QuicPrimary,
        "mac-1",
        "Desk Mac",
        CorePeerPlatform.Apple,
        "macOS",
        new string('0', 64),
        "apple-native,webrtc,tcp,relay",
        "1",
        PeerCapabilities.Apple());
    var pairingMaterial = new PairingMaterial(
        "mac-1",
        "Desk Mac",
        "macOS",
        new string('0', 64),
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
